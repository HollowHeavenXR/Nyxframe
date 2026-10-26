-- DB-backed blob storage + legacy on-disk fallback + ffmpeg-based thumbnail /
-- preview rendering, mirroring app/db/media_storage.py + the byte-serving
-- logic in app/routers/media_streaming.py.
--
-- STORAGE MODEL (confirmed against the live, April-29-restored Postgres
-- data, NOT the content-addressed-on-disk model originally assumed for this
-- task): GALLERY_STORAGE_BACKEND=database is what's actually configured, so
-- every media_items row has storage_path='db://media/<media_file_id>' and
-- its bytes live in media_files.content (bytea), chunked into
-- media_file_chunks for large uploads. The on-disk uploads/media/<hh>/<hash>
-- tree (8 files) is leftover from an earlier filesystem-backend period and
-- does not correspond to any current media_items row by content_sha256 (was
-- verified directly against the DB before writing this file) -- so
-- _legacy_upload_path below is real, faithfully-ported code that is simply
-- unreachable for all 540 rows in the current dataset (every storage_path
-- starts with "db://"). Right now media_files/media_file_chunks are BOTH
-- EMPTY (the April 29 backup/restore did not include the BLOB tables), so
-- get_media_file()/get_media_file_info() correctly return nil for all 540
-- items and callers must 404 cleanly -- this is expected, not a bug.
--
-- No PIL equivalent exists in Lua, so image/video thumbnail and preview
-- rendering shells out to ffmpeg (already required in lua/Dockerfile) for
-- both jobs instead of an image-decoding library: `ffmpeg -i <src> -vf
-- scale=... -c:v libwebp <dst>` handles a single still image exactly like a
-- 1-frame video, so the same helper serves both call sites. This blocks
-- copas' single-threaded event loop for the duration of the ffmpeg process
-- (io.popen/os.execute have no async variant without extra rocks).
--
-- Still-image thumbnails call M.render_webp/M.render_webp_from_bytes
-- synchronously below -- a small-image webp encode is cheap enough (tens of
-- ms) that this is fine at this deployment's traffic level. Video
-- thumbnails are the case that actually matters: they load the whole source
-- into memory and ffmpeg has to seek/decode into it, which can run multi-
-- second on a large upload, stalling every OTHER concurrent request on this
-- worker for that long. routes.lua's serve_media_thumb therefore does NOT
-- call M.render_webp for video -- it backgrounds M.render_webp_cmd's command
-- string via a detached shell job (the same fire-and-forget + marker-file
-- pattern video_extras.lua's ensure_sprite/ensure_captions already use) and
-- serves the existing placeholder SVG immediately; the real thumbnail takes
-- over on whichever later request finds the cache file in place.

local db = require("db")
local copas_ok, copas = pcall(require, "copas")

local M = {}

-- Streams a file through sha256 in fixed-size chunks instead of reading it
-- whole into one Lua string first -- the whole point of the disk-based
-- upload path this is used by (M.finalize_upload_from_file in routes.lua)
-- is to never hold a large upload's full bytes in GC-managed memory at
-- once. Yields to the scheduler between chunks (see save_media_file's
-- chunk-insert loop for the same rationale) so hashing a big file doesn't
-- freeze the single-threaded server for its own duration.
function M.sha256_file(path, chunk_bytes)
  local sodium = require("luasodium")
  chunk_bytes = chunk_bytes or (4 * 1024 * 1024)
  local f, ferr = io.open(path, "rb")
  if not f then return nil, ferr end
  local state = sodium.crypto_hash_sha256_init()
  while true do
    local chunk = f:read(chunk_bytes)
    if not chunk then break end
    sodium.crypto_hash_sha256_update(state, chunk)
    if copas_ok then copas.pause(0) end
  end
  f:close()
  return sodium.sodium_bin2hex(sodium.crypto_hash_sha256_final(state))
end

-- ---------------------------------------------------------------------------
-- DB blob reads (mirrors app/db/media_storage.py)
-- ---------------------------------------------------------------------------

-- Metadata only, no content -- mirrors get_media_file_info().
function M.get_media_file_info(media_id)
  local row = db.fetchone([[
    SELECT f.id, f.sha256, f.mime_type, f.original_filename, f.media_kind, f.file_size,
           octet_length(f.content) AS inline_size
    FROM media_files f
    JOIN media_items m ON m.media_file_id = f.id
    WHERE m.id = %s
  ]], media_id)
  if not row then return nil end
  row.id = db.toint(row.id, row.id)
  row.file_size = db.toint(row.file_size, 0)
  row.inline_size = db.toint(row.inline_size, 0)
  return row
end

-- Full content, assembling media_file_chunks if the row's own `content` is
-- shorter than file_size (large chunked upload) -- mirrors get_media_file().
function M.get_media_file(media_id)
  local row = db.fetchone([[
    SELECT f.id, f.sha256, f.mime_type, f.original_filename, f.media_kind, f.file_size, f.content
    FROM media_files f
    JOIN media_items m ON m.media_file_id = f.id
    WHERE m.id = %s
  ]], media_id)
  if not row then return nil end
  row.id = db.toint(row.id, row.id)
  row.file_size = db.toint(row.file_size, 0)
  local content = row.content or ""
  if #content ~= row.file_size then
    local chunks = db.fetchall(
      "SELECT content FROM media_file_chunks WHERE file_id=%s ORDER BY chunk_index ASC",
      row.id
    )
    if chunks and #chunks > 0 then
      local parts = {}
      for _, c in ipairs(chunks) do parts[#parts + 1] = c.content or "" end
      row.content = table.concat(parts)
    end
  end
  return row
end

function M.get_avatar_file(user_id)
  local row = db.fetchone([[
    SELECT f.id, f.sha256, f.mime_type, f.original_filename, f.file_size, f.content
    FROM user_avatar_files f
    JOIN users u ON u.avatar_file_id = f.id
    WHERE u.id = %s
  ]], user_id)
  if row then
    row.id = db.toint(row.id, row.id)
    row.file_size = db.toint(row.file_size, 0)
  end
  return row
end

-- ---------------------------------------------------------------------------
-- DB blob writes (mirrors save_media_file() in app/db/media_storage.py)
-- ---------------------------------------------------------------------------

-- `bytes:gsub(".", HEX_BYTE)` (the original approach here) drives the Lua
-- VM's full match/capture/replace machinery once per BYTE -- fine for a
-- small avatar, but confirmed live to fully freeze the single-threaded
-- server (no response to even /api/health) for several minutes on a
-- 250MB video, i.e. exactly the "network connection was lost" reports:
-- the client times out long before this ever returns. Rewritten with FFI
-- as a tight fixed-cost loop over a precomputed byte->hex-pair table
-- instead, which LuaJIT compiles to native code -- same output, several
-- orders of magnitude faster on multi-MB/GB input.
local ffi = require("ffi")
local bit = require("bit")

local hex_pair_lo = ffi.new("uint8_t[256]")
local hex_pair_hi = ffi.new("uint8_t[256]")
do
  local hexdigits = "0123456789abcdef"
  for b = 0, 255 do
    hex_pair_hi[b] = hexdigits:byte(bit.rshift(b, 4) + 1)
    hex_pair_lo[b] = hexdigits:byte(bit.band(b, 0xf) + 1)
  end
end

-- Postgres bytea values must travel as a plain-ASCII hex-format literal
-- (`\x4865...`) inside the single SQL string db.lua builds via
-- escape_literal -- raw binary (including NUL bytes) can't safely ride
-- inside a %-formatted SQL string otherwise. pgmoon's escape_literal only
-- quotes/escapes the resulting ASCII text, so this must happen first.
local function bytea_literal(bytes)
  local n = #bytes
  local src = ffi.cast("const uint8_t*", bytes)
  local out = ffi.new("uint8_t[?]", n * 2)
  for i = 0, n - 1 do
    local b = src[i]
    out[i * 2] = hex_pair_hi[b]
    out[i * 2 + 1] = hex_pair_lo[b]
  end
  return "\\x" .. ffi.string(out, n * 2)
end
M.bytea_literal = bytea_literal

local DEFAULT_CHUNK_BYTES = 8 * 1024 * 1024

-- Chunked insert mirroring save_media_file(): dedups by sha256 first: if a
-- media_files row already has this content, returns it with duplicate=true
-- instead of storing the bytes again. `content` must be the full blob
-- already in memory (see the multipart-parsing note in httpd.lua for why
-- this port doesn't stream multi-GB uploads to disk the way Python does).
function M.save_media_file(opts)
  local existing = db.fetchone(
    "SELECT id, sha256, mime_type, original_filename, media_kind, file_size, created_by, created_at FROM media_files WHERE sha256=%s",
    opts.sha256
  )
  if existing then
    existing.id = db.toint(existing.id, existing.id)
    existing.file_size = db.toint(existing.file_size, existing.file_size)
    existing.duplicate = true
    return existing
  end

  local content = opts.content or ""
  local total_size = opts.file_size or #content
  local chunk_bytes = math.max(1024 * 1024, math.min(opts.chunk_bytes or DEFAULT_CHUNK_BYTES, 16 * 1024 * 1024))

  local row, err = db.fetchone(
    "INSERT INTO media_files (sha256, mime_type, original_filename, media_kind, file_size, content, created_by) VALUES (%s,%s,%s,%s,%s,%s,%s) RETURNING id",
    opts.sha256, opts.mime_type:sub(1, 120), opts.original_filename:sub(1, 255), opts.media_kind, tostring(total_size), "", tostring(opts.user_id)
  )
  if not row then return nil, err end
  local media_file_id = db.toint(row.id, row.id)

  local ok, insert_err = pcall(function()
    local chunk_index = 0
    local offset = 0
    while offset < #content do
      local chunk = content:sub(offset + 1, offset + chunk_bytes)
      local ok2, chunk_err = db.execute(
        "INSERT INTO media_file_chunks (file_id, chunk_index, content) VALUES (%s,%s,%s)",
        tostring(media_file_id), tostring(chunk_index), bytea_literal(chunk)
      )
      if not ok2 then error(chunk_err or "chunk insert failed") end
      chunk_index = chunk_index + 1
      offset = offset + chunk_bytes
      -- Confirmed live: under real disk I/O contention on this host, a
      -- single blob-chunk INSERT can block on Postgres's own DataFileExtend
      -- wait for multiple seconds -- and since this Postgres driver
      -- (swarmlua.pg) talks over a plain blocking socket, not a
      -- copas-wrapped one, that block freezes the ENTIRE single-threaded
      -- server, not just this request (verified: /api/health itself went
      -- unresponsive for the whole duration of a large video's chunk-insert
      -- loop). A large video is dozens of these chunks in a row with no
      -- yield point between them. copas.pause(0) hands control back to the
      -- scheduler after each chunk so other in-flight requests get a
      -- window to run between chunks -- it doesn't make this upload faster
      -- (still bounded by real disk I/O), but it stops one big upload from
      -- taking the whole site down while it's in progress.
      if copas_ok then copas.pause(0) end
    end
  end)
  if not ok then
    db.execute("DELETE FROM media_files WHERE id=%s", tostring(media_file_id))
    return nil, insert_err
  end

  local final = db.fetchone(
    "SELECT id, sha256, mime_type, original_filename, media_kind, file_size, created_by, created_at FROM media_files WHERE id=%s",
    tostring(media_file_id)
  )
  if final then
    final.id = db.toint(final.id, final.id)
    final.file_size = db.toint(final.file_size, final.file_size)
    final.duplicate = false
  end
  return final
end

local function shell_quote_early(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Content-addressed on-disk storage: `<uploads_dir>/media/<sha[1:2]>/<sha>.<ext>`.
-- Replaces the bytea/media_file_chunks path above for new uploads --
-- confirmed live (2026-08-10) that storing multi-hundred-MB videos as
-- Postgres bytea meant every read (serving, transcoding, thumbnailing, AI
-- analysis) had to first pull the whole blob back into a Lua string, and
-- LuaJIT's GC does a stop-the-world sweep proportional to live heap size
-- (250-380ms observed with ~1.5GB resident vs ~1ms with a few MB) -- on
-- top of the plain OS memory pressure of holding it twice (once as the
-- upload's own buffer, once again as the hex-encoded INSERT payload).
-- Postgres's own docs discourage bytea for this size range for the same
-- reason: "file systems are much better equipped to handle files of that
-- magnitude." Returns a `storage_path` (relative, for media_items.storage_path
-- -- NOT a media_file_id/db:// row; resolve_media_bytes() already falls
-- back to this exact layout via legacy_upload_path(), unchanged) instead of
-- a media_files row.
-- `opts.content` (a string already in memory) or `opts.source_path` (a
-- file already fully written to disk -- e.g. a chunked upload's assembled
-- session file) work interchangeably: the source_path case is a plain
-- rename, no read/write of the actual bytes at all, which is the entire
-- point of the streaming upload path (M.finalize_upload_from_file in
-- routes.lua) that's the only caller of that branch.
function M.save_media_file_to_disk(uploads_dir, opts)
  local ext = opts.ext or (opts.original_filename or ""):match("(%.[^./\\]+)$") or ".bin"
  local prefix = opts.sha256:sub(1, 2)
  local rel_dir = "media/" .. prefix
  local rel_path = rel_dir .. "/" .. opts.sha256 .. ext
  uploads_dir = uploads_dir:gsub("/+$", "")

  -- Same content already stored (in either tier): reuse it.
  if M.legacy_upload_path(uploads_dir, rel_path) then
    if opts.source_path then os.remove(opts.source_path) end
    return { storage_path = rel_path, duplicate = true }
  end

  -- New originals go to the fast tier when one is configured; the path
  -- stored in the DB is the same relative one either way.
  local root = M.hot_root or uploads_dir
  local full_dir = root .. "/" .. rel_dir
  local full_path = root .. "/" .. rel_path

  os.execute("mkdir -p " .. shell_quote_early(full_dir))

  if opts.source_path then
    local ok, rerr = os.rename(opts.source_path, full_path)
    if not ok then
      -- Different filesystem (uploads are staged on the internal NVMe, see
      -- config.lua's upload_staging_dir): copy to a temp name next to the
      -- destination, then rename. Run through os.execute so blockwatch
      -- runs it in the background and this coroutine yields while the
      -- (slow USB) drive takes the bytes. "nice" first so blockwatch
      -- doesn't treat it as a quick inline "cp".
      local tmp_path = full_path .. ".tmp." .. tostring(math.random(100000, 999999))
      local code = os.execute(string.format("nice -n 10 cp -f %s %s && mv -f %s %s",
        shell_quote_early(opts.source_path), shell_quote_early(tmp_path),
        shell_quote_early(tmp_path), shell_quote_early(full_path)))
      if code ~= 0 and code ~= true then
        os.remove(tmp_path)
        return nil, "Could not finalize stored file: " .. tostring(rerr or "copy failed (check disk space)")
      end
      os.remove(opts.source_path)
    end
    return { storage_path = rel_path, duplicate = false }
  end

  -- Write-then-rename so a concurrent reader (or a crash mid-write) never
  -- sees a partial file at the final path.
  local tmp_path = full_path .. ".tmp." .. tostring(math.random(100000, 999999))
  local f, ferr = io.open(tmp_path, "wb")
  if not f then return nil, "Could not open destination file: " .. tostring(ferr or "unknown open failure") end
  f:write(opts.content)
  f:close()
  local ok, rerr = os.rename(tmp_path, full_path)
  if not ok then
    os.remove(tmp_path)
    return nil, "Could not finalize stored file: " .. tostring(rerr or "rename failed (check disk space / same-filesystem mount)")
  end
  return { storage_path = rel_path, duplicate = false }
end

-- POST /api/me/avatar's storage write. Mirrors app/db/account.py's
-- save_avatar_file(): unlike media_files (chunked, for potentially huge
-- video files), user_avatar_files.content is a single bytea column --
-- avatars are capped small (5MB) so chunking isn't needed. Recovered from
-- git history (9986ab5^:app/db/account.py) -- the table/columns
-- (user_avatar_files, users.avatar_file_id/avatar_path/avatar_mime_type/
-- avatar_original_filename) already existed and were already read by
-- M.serve_user_avatar (routes.lua), but nothing ever wrote to them: POST
-- /api/me/avatar was never ported, confirmed live-404ing.
function M.save_avatar_file(user_id, content, sha256, mime_type, original_filename)
  local row, err = db.fetchone(
    [[
      INSERT INTO user_avatar_files (user_id, sha256, mime_type, original_filename, file_size, content)
      VALUES (%s, %s, %s, %s, %s, %s)
      ON CONFLICT (user_id, sha256) DO UPDATE SET created_at = now()
      RETURNING id
    ]],
    tostring(user_id), sha256, mime_type:sub(1, 120), original_filename:sub(1, 255), tostring(#content), bytea_literal(content)
  )
  if not row then return nil, err end
  local file_id = db.toint(row.id, row.id)

  local ok, uerr = db.execute(
    "UPDATE users SET avatar_file_id=%s, avatar_path=%s, avatar_mime_type=%s, avatar_original_filename=%s WHERE id=%s",
    tostring(file_id), "avatar-db://" .. tostring(file_id), mime_type:sub(1, 120), original_filename:sub(1, 255), tostring(user_id)
  )
  if not ok then return nil, uerr end
  return file_id
end

-- ---------------------------------------------------------------------------
-- Legacy on-disk fallback (mirrors _legacy_upload_path in app/routers/_shared.py)
-- ---------------------------------------------------------------------------

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

-- Returns an absolute path string if `storage_path` resolves to a real file
-- strictly inside uploads_dir, else nil. storage_path values starting with
-- "db://" or "avatar-db://" are DB-backed by definition and never resolve
-- here (matches Python's early-return).
function M.legacy_upload_path(uploads_dir, storage_path)
  if not storage_path or storage_path == "" then return nil end
  if storage_path:match("^db://") or storage_path:match("^avatar%-db://") then return nil end
  local raw = storage_path:gsub("\\", "/"):gsub("^/+", "")
  if raw:match("%.%.") then return nil end -- reject any ".." path-traversal segment
  if M.hot_root then
    local hot = M.hot_root .. "/" .. raw
    if file_exists(hot) then return hot end
  end
  uploads_dir = uploads_dir:gsub("/+$", "")
  local path = uploads_dir .. "/" .. raw
  if not file_exists(path) then return nil end
  return path
end

-- Fast-disk tier root (config.lua's hot_dir), set once at startup by
-- routes.configure_storage(). nil = single-tier, everything in uploads_dir.
M.hot_root = nil

-- ---------------------------------------------------------------------------
-- ffmpeg-backed thumbnail / preview rendering
-- ---------------------------------------------------------------------------

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function write_temp_file(content, suffix)
  local path = os.tmpname() .. (suffix or "")
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
  return path
end

local function ffmpeg_bin()
  return os.getenv("GALLERY_FFMPEG_BIN") or "ffmpeg"
end

-- Every call below runs synchronously (os.execute waits for it -- unlike
-- routes.lua's detached video transcodes, these are single-frame ops:
-- thumbnails, fingerprints, watermarks, previews), so nicing it doesn't
-- speed up the request that triggered it -- it's still blocked either way.
-- What it does do is stop a burst of these (e.g. a bulk import's worth of
-- never-before-viewed thumbnails, or several visitors' cache misses
-- landing at once) from taking CPU away from the request-serving luajit
-- process and every OTHER service on this same host (SwarmPanel, the
-- Discord bots), same rationale as routes.lua's nice/ionice comment on
-- the video transcode commands.
local function ffmpeg_prefix()
  return "nice -n 15 ionice -c2 -n6 " .. ffmpeg_bin()
end
M.ffmpeg_bin = ffmpeg_bin

-- Renders `src_path` (any image OR video ffmpeg can demux -- a single still
-- image behaves like a 1-frame video for this purpose, so one helper covers
-- both serve_media_thumb's image branch and _render_video_frame_thumb) to a
-- WEBP thumbnail/preview at `dst_path`. `seek` (seconds, video only) mirrors
-- _render_video_frame_thumb's "-ss 0.35" grab-a-real-frame-not-just-frame-0
-- behavior. Returns true on success.
-- Factored out of render_webp so a caller that needs this to run detached
-- (routes.lua's async video-thumbnail path -- see serve_media_thumb) can
-- wrap the exact same ffmpeg invocation in a backgrounded shell job instead
-- of re-deriving the flags separately and risking the two copies drifting.
-- `dst_path` must end in ".webp" (not e.g. "dst..tmp"), or ffmpeg's
-- output-format auto-detection (which goes purely off the filename
-- extension) fails with "Unable to choose an output format" -- discovered
-- by actually running this against a live sample file, not assumed. "-f
-- webp" is also passed explicitly as a second safety net.
function M.render_webp_cmd(src_path, dst_path, max_edge, quality, seek)
  local seek_args = seek and (" -ss " .. tostring(seek)) or ""
  return string.format(
    "%s -y -hide_banner -loglevel error%s -i %s -frames:v 1 -vf %s -c:v libwebp -compression_level 5 -quality %d -f webp %s </dev/null >/dev/null 2>&1",
    ffmpeg_prefix(),
    seek_args,
    shell_quote(src_path),
    shell_quote(string.format("scale='min(%d,iw)':-2:flags=lanczos", max_edge)),
    math.floor(quality),
    shell_quote(dst_path)
  )
end

-- Picks a representative video thumbnail frame via ffmpeg's scene-change
-- detector instead of always grabbing whatever happens to sit at a fixed
-- 0.35s mark -- that fixed offset regularly lands on a black/fade-in frame
-- right after a video starts (eyeballed across a sample of live
-- thumbnails while auditing media loading, 2026-10-11).
--
-- Bounded to the first SCENE_SCAN_SECONDS of the source (an INPUT-side
-- `-t`, not a full decode) so this stays a cheap optimization layered on
-- top of the existing single-frame grab, not a second expensive pass over
-- the whole video. If nothing clears the scene-change threshold in that
-- window -- a static/talking-head clip, or a source shorter than the
-- window -- ffmpeg's `select` filter emits zero frames and writes nothing,
-- so `dst_path` stays empty/missing and the ORIGINAL fixed-seek command
-- runs as a fallback. Chained into ONE shell command string (not two
-- separate os.execute calls) so a caller running this inside a detached
-- background job (see routes.lua's serve_media_thumb/prewarm_video_thumb)
-- only has to wrap/clean up once, same convention render_webp_cmd's own
-- callers already rely on.
local SCENE_SCAN_SECONDS = 20
local SCENE_THRESHOLD = 0.3

function M.render_webp_scene_aware_cmd(src_path, dst_path, max_edge, quality, fallback_seek)
  local scale_filter = string.format("scale='min(%d,iw)':-2:flags=lanczos", max_edge)
  -- The comma inside `gt(scene\,N)` must be backslash-escaped -- ffmpeg's
  -- filtergraph syntax otherwise reads it as the separator between this
  -- filter and the chained `scale` filter that follows, not as part of
  -- gt()'s argument list.
  local scene_cmd = string.format(
    "%s -y -hide_banner -loglevel error -i %s -t %d -vf %s -frames:v 1 -c:v libwebp -compression_level 5 -quality %d -f webp %s </dev/null >/dev/null 2>&1",
    ffmpeg_prefix(), shell_quote(src_path), SCENE_SCAN_SECONDS,
    shell_quote(string.format("select='gt(scene\\,%g)',%s", SCENE_THRESHOLD, scale_filter)),
    math.floor(quality), shell_quote(dst_path)
  )
  local fallback_cmd = M.render_webp_cmd(src_path, dst_path, max_edge, quality, fallback_seek)
  return string.format("%s; if [ ! -s %s ]; then %s; fi", scene_cmd, shell_quote(dst_path), fallback_cmd)
end

function M.render_webp(src_path, dst_path, max_edge, quality, seek)
  local tmp_dst = dst_path .. ".tmp.webp"
  local cmd = M.render_webp_cmd(src_path, tmp_dst, max_edge, quality, seek)
  local ok = os.execute(cmd)
  -- Lua 5.1/LuaJIT's os.execute returns the raw OS exit status (0 == success);
  -- Lua 5.2+ returns (true, "exit", 0). Accept either convention.
  local success = (ok == 0 or ok == true)
  if success and file_exists(tmp_dst) then
    os.rename(tmp_dst, dst_path)
    return true
  end
  os.remove(tmp_dst)
  return false
end

-- One decode, several WEBP sizes (2026-10-26). Decoding a 4-15MB PNG/JPEG
-- is most of a render's cost, so the background rendition warmer asks for
-- the grid thumb, lightbox thumb and detail preview in a single ffmpeg run
-- (split filter) instead of three. outputs = { {dst=, max_edge=, quality=}, ... }.
-- Each dst is written via a .tmp.webp + rename, so readers never see a
-- partial file. Returns the command string (caller decides how to run it)
-- and a finish() that renames the finished temp files into place.
function M.render_webp_multi_cmd(src_path, outputs, opts)
  opts = opts or {}
  local n = #outputs
  local parts, maps = {}, {}
  local labels = {}
  for i = 1, n do labels[i] = "[s" .. i .. "]" end
  if n > 1 then
    parts[#parts + 1] = "[0:v]split=" .. n .. table.concat(labels)
  end
  for i, o in ipairs(outputs) do
    local input = n > 1 and labels[i] or "[0:v]"
    parts[#parts + 1] = string.format("%sscale='min(%d,iw)':-2:flags=lanczos[o%d]", input, o.max_edge, i)
    maps[#maps + 1] = string.format("-map '[o%d]' -frames:v 1 -c:v libwebp -compression_level %d -quality %d -f webp %s",
      i, o.compression_level or 4, math.floor(o.quality), shell_quote(o.dst .. ".tmp.webp"))
  end
  local prefix = opts.prefix or ffmpeg_prefix()
  local cmd = string.format("%s -y -hide_banner -loglevel error -i %s -filter_complex %s %s </dev/null >/dev/null 2>&1",
    prefix, shell_quote(src_path), shell_quote(table.concat(parts, ";")), table.concat(maps, " "))
  local function finish()
    local ok = {}
    for i, o in ipairs(outputs) do
      local tmp = o.dst .. ".tmp.webp"
      local f = io.open(tmp, "rb")
      local size = f and f:seek("end") or 0
      if f then f:close() end
      if size > 0 then
        ok[i] = os.rename(tmp, o.dst) and true or false
      else
        os.remove(tmp)
        ok[i] = false
      end
    end
    return ok
  end
  return cmd, finish
end

-- Render one WEBP straight from a file on disk (no Lua-side copy of the
-- original). Returns the rendered bytes or nil.
function M.render_webp_bytes_from_path(src_path, max_edge, quality)
  local dst = os.tmpname() .. ".webp"
  local ok = M.render_webp(src_path, dst, max_edge, quality, nil)
  if not ok then os.remove(dst); return nil end
  local f = io.open(dst, "rb")
  if not f then return nil end
  local bytes = f:read("*a")
  f:close()
  os.remove(dst)
  return bytes
end

-- Convenience wrapper: render a WEBP thumb/preview straight from in-memory
-- blob bytes (DB-backed content) via a scratch temp file, cleaned up after.
function M.render_webp_from_bytes(content, max_edge, quality, seek)
  local src = write_temp_file(content, "")
  local dst = os.tmpname() .. ".webp"
  local ok = M.render_webp(src, dst, max_edge, quality, seek)
  os.remove(src)
  if not ok then
    os.remove(dst)
    return nil
  end
  local f = io.open(dst, "rb")
  local bytes = f:read("*a")
  f:close()
  os.remove(dst)
  return bytes
end

-- Plain SVG placeholder for a video thumbnail when no source frame can be
-- extracted (mirrors the SVG fallback branch inside Python's own
-- _render_video_placeholder_thumb, used here as the primary implementation
-- since Lua has no PIL-equivalent to draw the fancier gradient+play-button
-- PNG Python renders first).
function M.video_placeholder_svg(width)
  width = math.floor(width or 480)
  local height = math.max(120, math.floor(width * 9 / 16))
  return string.format(
    "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d' viewBox='0 0 %d %d'>"
      .. "<rect width='100%%' height='100%%' fill='#18212d'/>"
      .. "<circle cx='50%%' cy='50%%' r='48' fill='none' stroke='rgba(255,255,255,.62)' stroke-width='4'/>"
      .. "<path d='M46%% 42%%v16l16-8z' fill='rgba(255,255,255,.72)'/></svg>",
    width, height, width, height
  )
end

-- ---------------------------------------------------------------------------
-- Perceptual image fingerprinting (average hash + difference hash), for the
-- possible-duplicate-upload warning. Mirrors app/ai_metadata.py's
-- _image_fingerprint/_average_hash/_difference_hash, but via ffmpeg instead
-- of PIL (same rationale as the thumbnail rendering above -- no PIL
-- equivalent in Lua). NOT bit-for-bit identical to Python's hashes (ffmpeg's
-- lanczos scale + its own EXIF-orientation handling differ slightly from
-- PIL's resize()+ImageOps.exif_transpose()), which only matters if directly
-- comparing a Python-computed hash against a Lua-computed one -- this
-- feature only ever compares hashes computed by the same backend that's
-- currently live, and the comparison is already fuzzy (Hamming-distance
-- threshold), so close-enough is fine for an advisory "maybe a duplicate"
-- warning.
local bit = require("bit")

local function ffprobe_bin()
  return os.getenv("GALLERY_FFPROBE_BIN") or "ffprobe"
end

-- Packs 64 0/1 bits (MSB-first) into a 16-hex-char string, matching Python's
-- f"{bits:016x}" for a 64-bit integer -- built as two 32-bit halves since
-- Lua 5.1/LuaJIT's `bit` library (and plain Lua number arithmetic) only
-- reliably handles 32 bits at a time.
local function pack_bits_hex(get_bit)
  local hi, lo = 0, 0
  for i = 0, 63 do
    local b = get_bit(i) and 1 or 0
    if i < 32 then
      hi = bit.bor(bit.lshift(hi, 1), b)
    else
      lo = bit.bor(bit.lshift(lo, 1), b)
    end
  end
  return bit.tohex(hi) .. bit.tohex(lo)
end

-- Same result as M.image_fingerprint below, but straight from a file on
-- disk and with ONE ffmpeg decode instead of three (split into the 8x8
-- gray, 9x8 gray and 8x8 rgb outputs). Decoding a 4K PNG dominates the
-- cost, so this is ~3x cheaper, and no temp copy of the bytes is made.
-- Same scale flags and pixel formats as the old three-run version, so the
-- hashes match ones already stored for older uploads (checked on 15 real
-- gallery images, 2026-10-26).
function M.image_fingerprint_from_path(src)
  local width, height
  local probe = io.popen(string.format(
    "%s -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x %s 2>/dev/null",
    ffprobe_bin(), shell_quote(src)
  ))
  if probe then
    local line = probe:read("*l")
    probe:close()
    if line then width, height = line:match("^(%d+)x(%d+)$") end
  end

  local base = os.tmpname()
  local p_path, d_path, c_path = base .. ".p.raw", base .. ".d.raw", base .. ".c.raw"
  os.remove(base)
  local cmd = string.format(
    "%s -y -hide_banner -loglevel error -i %s -filter_complex %s"
      .. " -map '[p]' -frames:v 1 -f rawvideo %s -map '[d]' -frames:v 1 -f rawvideo %s"
      .. " -map '[c]' -frames:v 1 -f rawvideo %s </dev/null >/dev/null 2>&1",
    ffmpeg_prefix(), shell_quote(src),
    shell_quote("[0:v]split=3[a][b][c0];[a]scale=8:8:flags=lanczos,format=gray[p];"
      .. "[b]scale=9:8:flags=lanczos,format=gray[d];[c0]scale=8:8:flags=lanczos,format=rgb24[c]"),
    shell_quote(p_path), shell_quote(d_path), shell_quote(c_path)
  )
  os.execute(cmd)
  local function slurp(path, want)
    local f = io.open(path, "rb")
    if not f then return nil end
    local bytes = f:read("*a")
    f:close()
    os.remove(path)
    if not bytes or #bytes ~= want then return nil end
    return bytes
  end
  local phash_pixels = slurp(p_path, 64)
  local dhash_pixels = slurp(d_path, 72)
  local rgb_pixels = slurp(c_path, 192)
  if not phash_pixels and not dhash_pixels then return nil end

  local image_phash, image_dhash, dominant_color
  if phash_pixels then
    local sum = 0
    for i = 1, #phash_pixels do sum = sum + phash_pixels:byte(i) end
    local avg = sum / #phash_pixels
    image_phash = pack_bits_hex(function(i) return phash_pixels:byte(i + 1) >= avg end)
  end
  if dhash_pixels then
    image_dhash = pack_bits_hex(function(i)
      local row, col = math.floor(i / 8), i % 8
      local offset = row * 9 + col
      return dhash_pixels:byte(offset + 1) > dhash_pixels:byte(offset + 2)
    end)
  end
  if rgb_pixels then
    local r, g, b = 0, 0, 0
    for i = 1, #rgb_pixels, 3 do
      r = r + rgb_pixels:byte(i)
      g = g + rgb_pixels:byte(i + 1)
      b = b + rgb_pixels:byte(i + 2)
    end
    dominant_color = string.format("#%02x%02x%02x", math.floor(r / 64 + 0.5), math.floor(g / 64 + 0.5), math.floor(b / 64 + 0.5))
  end
  return {
    image_phash = image_phash,
    image_dhash = image_dhash,
    image_width = width and tonumber(width) or nil,
    image_height = height and tonumber(height) or nil,
    dominant_color = dominant_color,
  }
end

-- For an MP4/MOV on disk: true when the "moov" index already comes before
-- "mdat" (the file can start playing before it has fully downloaded, so a
-- faststart remux would only copy the whole file for nothing), false when
-- it comes after, nil if the box layout couldn't be read. Only reads the
-- 8-16 byte headers of the top-level boxes.
function M.mp4_is_faststart(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local size = f:seek("end")
  local pos = 0
  local result = nil
  for _ = 1, 64 do
    if pos + 8 > size then break end
    f:seek("set", pos)
    local header = f:read(8)
    if not header or #header < 8 then break end
    local b1, b2, b3, b4 = header:byte(1, 4)
    local box_size = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
    local box_type = header:sub(5, 8)
    if box_size == 1 then
      local ext = f:read(8)
      if not ext or #ext < 8 then break end
      box_size = 0
      for i = 1, 8 do box_size = box_size * 256 + ext:byte(i) end
    elseif box_size == 0 then
      box_size = size - pos -- runs to end of file
    end
    if box_type == "moov" then result = true; break end
    if box_type == "mdat" then result = false; break end
    if box_size < 8 then break end
    pos = pos + box_size
  end
  f:close()
  return result
end

-- Returns {image_phash, image_dhash, image_width, image_height} or nil.
-- Mirrors _image_fingerprint_for_upload()'s "images only, need the bytes"
-- gate -- callers should only invoke this for in-memory image uploads.
function M.image_fingerprint(content)
  if not content or #content == 0 then return nil end
  local tmp = write_temp_file(content, "")
  local ok, result = pcall(M.image_fingerprint_from_path, tmp)
  os.remove(tmp)
  return ok and result or nil
end

-- ---------------------------------------------------------------------------
-- Media dimensions + JPEG preview, used by ai_metadata.lua's heuristic
-- analysis (landscape/portrait/4k tags) and vision-provider calls (a small
-- JPEG preview to send as the image payload). Mirrors app/ai_metadata.py's
-- _media_size/_video_size/_preview_base64/_video_preview_base64, again via
-- ffmpeg/ffprobe instead of PIL -- works uniformly for images and videos
-- (ffprobe/ffmpeg treat a still image as a 1-frame video), so one pair of
-- helpers covers both media kinds instead of Python's separate image/video
-- branches.
-- ---------------------------------------------------------------------------

-- Returns {width, height} or nil. Operates on a file already on disk --
-- no temp-file copy needed, so this is safe to call directly against a
-- large upload's real path instead of first materializing it as a Lua
-- string (see M.media_dimensions/M.jpeg_preview_base64 below, which do
-- need that copy since they only ever receive in-memory content).
function M.media_dimensions_from_path(src)
  local width, height
  local probe = io.popen(string.format(
    "%s -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x %s 2>/dev/null",
    ffprobe_bin(), shell_quote(src)
  ))
  if probe then
    local line = probe:read("*l")
    probe:close()
    if line then width, height = line:match("^(%d+)x(%d+)$") end
  end
  if not width or not height then return nil end
  return { tonumber(width), tonumber(height) }
end

-- Returns {width, height} or nil.
function M.media_dimensions(content)
  local src = write_temp_file(content, "")
  local result = M.media_dimensions_from_path(src)
  os.remove(src)
  return result
end

-- Same file-already-on-disk rationale as M.media_dimensions_from_path.
function M.jpeg_preview_base64_from_path(src)
  local sodium = require("luasodium")
  local dst = os.tmpname() .. ".jpg"
  local cmd = string.format(
    "%s -y -hide_banner -loglevel error -i %s -frames:v 1 -vf %s -q:v 3 -f mjpeg %s </dev/null >/dev/null 2>&1",
    ffmpeg_prefix(), shell_quote(src), shell_quote("scale='min(1600,iw)':'min(1600,ih)':force_original_aspect_ratio=decrease:flags=lanczos"),
    shell_quote(dst)
  )
  local ok = os.execute(cmd)
  local success = (ok == 0 or ok == true)
  if not success or not file_exists(dst) then
    os.remove(dst)
    return nil
  end
  local f = io.open(dst, "rb")
  local bytes = f:read("*a")
  f:close()
  os.remove(dst)
  if not bytes or #bytes == 0 then return nil end
  return sodium.sodium_bin2base64(bytes, sodium.sodium_base64_VARIANT_ORIGINAL)
end

-- Returns a base64-encoded JPEG preview (scaled to fit 1600x1600, matching
-- Python's preview.thumbnail((1600, 1600))), or nil on failure.
function M.jpeg_preview_base64(content)
  local src = write_temp_file(content, "")
  local result = M.jpeg_preview_base64_from_path(src)
  os.remove(src)
  return result
end

-- ---------------------------------------------------------------------------
-- Watermark overlay -- "Watermark / Signature Text" has existed as a saved
-- user_settings field with a real Settings-page input since before this
-- pass, but was never actually applied anywhere: it was pure dead data,
-- silently doing nothing after being saved. Uses ffmpeg's drawtext filter
-- (already the only image-processing tool this backend depends on -- no
-- ImageMagick binary is even installed on this host, despite being listed
-- in the NixOS deps script, so staying on ffmpeg avoids adding a real new
-- dependency for this).
-- ---------------------------------------------------------------------------

local WATERMARK_FONT = os.getenv("GALLERY_WATERMARK_FONT") or "/usr/share/fonts/noto/NotoSans-Regular.ttf"

-- Escapes a file path for use as a drawtext fontfile=/textfile= value --
-- ffmpeg's filtergraph mini-language treats ":" as the option separator
-- and "\" as its own escape character, so both need doubling/escaping even
-- though a real filesystem path (not user-controlled text -- that's the
-- textfile trick above) is very unlikely to contain either in practice.
local function ffmpeg_filter_path_escape(path)
  return (tostring(path):gsub("\\", "\\\\"):gsub(":", "\\:"))
end

local EXT_FOR_MIME = {
  ["image/png"] = "png",
  ["image/webp"] = "webp",
  ["image/jpeg"] = "jpg",
  ["image/jpg"] = "jpg",
}

-- Returns new watermarked bytes, or nil on any failure (missing font,
-- unsupported format, ffmpeg error, ...) -- callers must fail OPEN (serve
-- the original, unwatermarked bytes) rather than error the whole request,
-- since a cosmetic feature breaking should never take down file serving.
-- Disabled site-wide -- routes.lua's watermark_text call sites are all
-- hardcoded to nil for the same reason (drawtext/overlay burn-in was
-- forcing unwanted re-encodes and saturating CPU/GPU). Kept as an early
-- return rather than deleted so the feature can be flipped back on in one
-- place if that tradeoff changes.
local WATERMARKS_ENABLED = false

function M.apply_watermark(content, mime_type, watermark_text)
  if not WATERMARKS_ENABLED then return nil end
  local text = tostring(watermark_text or ""):match("^%s*(.-)%s*$")
  if text == "" or not file_exists(WATERMARK_FONT) then return nil end
  local ext = EXT_FOR_MIME[tostring(mime_type or ""):lower()]
  if not ext then return nil end

  local src = write_temp_file(content, "")
  -- textfile= (not text=) so the user-controlled string never has to be
  -- escaped into ffmpeg's filtergraph mini-language (colons/commas/quotes
  -- in drawtext's inline text= are a real footgun to escape correctly) --
  -- ffmpeg just reads the file's raw bytes as the label instead.
  local text_file = os.tmpname()
  local tf = io.open(text_file, "wb")
  if not tf then os.remove(src); return nil end
  tf:write(text:sub(1, 40))
  tf:close()
  local dst = os.tmpname() .. "." .. ext

  -- Bottom-right corner, semi-transparent white with a soft shadow so it
  -- reads against both light and dark image content; size and margin
  -- scale with image height so it looks proportional on any resolution.
  local filter = string.format(
    "drawtext=fontfile=%s:textfile=%s:fontcolor=white@0.55:fontsize=h/22:x=w-tw-(h/40+12):y=h-th-(h/40+12):shadowcolor=black@0.5:shadowx=2:shadowy=2",
    ffmpeg_filter_path_escape(WATERMARK_FONT), ffmpeg_filter_path_escape(text_file)
  )
  local cmd = string.format(
    "%s -y -hide_banner -loglevel error -i %s -vf %s -frames:v 1 %s </dev/null >/dev/null 2>&1",
    ffmpeg_prefix(), shell_quote(src), shell_quote(filter), shell_quote(dst)
  )
  local ok = os.execute(cmd)
  local success = (ok == 0 or ok == true)
  os.remove(src)
  os.remove(text_file)
  if not success or not file_exists(dst) then
    os.remove(dst)
    return nil
  end
  local f = io.open(dst, "rb")
  local bytes = f:read("*a")
  f:close()
  os.remove(dst)
  if not bytes or #bytes == 0 then return nil end
  return bytes
end

-- Video counterpart to M.apply_watermark: video encodes run as DETACHED
-- background ffmpeg processes (routes.lua's ensure_video_quality_cache/
-- ensure_hls_variant), so unlike the image path this can't write the
-- textfile, run ffmpeg, and clean up synchronously -- the text file has
-- to survive until the background process actually reads it. Returns
-- (filter_string, text_file_path) for the caller to splice into its own
-- -vf chain and background shell command (which must `rm -f` the
-- text_file_path once the encode finishes), or (nil, nil) if there's no
-- watermark text configured or the font is missing.
function M.video_watermark_filter(watermark_text)
  if not WATERMARKS_ENABLED then return nil, nil end
  local text = tostring(watermark_text or ""):match("^%s*(.-)%s*$")
  if text == "" or not file_exists(WATERMARK_FONT) then return nil, nil end

  local text_file = os.tmpname()
  local tf = io.open(text_file, "wb")
  if not tf then return nil, nil end
  tf:write(text:sub(1, 40))
  tf:close()

  local filter = string.format(
    "drawtext=fontfile=%s:textfile=%s:fontcolor=white@0.55:fontsize=h/22:x=w-tw-(h/40+12):y=h-th-(h/40+12):shadowcolor=black@0.5:shadowx=2:shadowy=2",
    ffmpeg_filter_path_escape(WATERMARK_FONT), ffmpeg_filter_path_escape(text_file)
  )
  return filter, text_file
end

return M
