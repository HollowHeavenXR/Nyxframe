-- Seek-preview sprites and auto-generated captions for video posts.
--
-- Lives in its own module rather than in routes.lua for a hard reason,
-- not a stylistic one: routes.lua's main chunk sits at 199 of LuaJIT's
-- 200 per-chunk local-variable slots (LUAI_MAXVARS -- see its own
-- comments about this), so anything with more than a single new
-- top-level local physically cannot go there. routes.lua exposes the few
-- internals needed here through one table, `routes._video_extras_api`,
-- which costs it no locals at all.
--
-- Both features share the same shape, and both of them lean on one fact
-- about this deployment: the media warmer keeps a full transcoded HLS
-- ladder on disk for every video (see start_media_warmer). That makes a
-- warm 480p rendition, not the original upload, the right source for
-- both jobs -- measured on media 693 (a 28s 4K, 104MB source):
--
--   sprite from the 4K original ......... 17.4s
--   sprite from the warm 480p rendition .. 0.4s
--
-- Same output, 41x cheaper, and it keeps this work away from the GPU
-- pipeline the real transcodes need. Captions get the same treatment:
-- decoding audio out of a small rendition is instant, and speech
-- recognition doesn't care about video resolution at all.

local M = {}

local SPRITE_COLUMNS = 10
local SPRITE_ROWS = 10
local SPRITE_TILE_WIDTH = 160
-- A fixed 10x10 grid means one bounded sprite (~50KB) regardless of
-- whether the video is 30 seconds or an hour: the interval between tiles
-- stretches with duration instead of the sheet growing. 100 previews is
-- finer granularity than a seek bar a few hundred pixels wide can even
-- address.
local SPRITE_MAX_TILES = SPRITE_COLUMNS * SPRITE_ROWS
local SPRITE_MIN_INTERVAL = 1

-- Whisper is CPU-only on this box and shares it with the Discord music
-- bots' Lavalink JVMs, which are audibly sensitive to CPU starvation
-- (there is a renice-lavalink timer on this host for exactly that
-- reason). Two threads at nice 15, one job at a time, is deliberately
-- unambitious: captions are a background nicety, and a stuttering voice
-- channel is a live user-facing failure.
local WHISPER_THREADS = 2
local CAPTION_MODEL_ENV = "GALLERY_WHISPER_MODEL"
local CAPTION_BIN_ENV = "GALLERY_WHISPER_BIN"
-- A long video is a long transcription even at ~13x realtime, and the
-- result is a nicety -- cap it rather than letting one three-hour upload
-- hold the single caption slot for a quarter of an hour.
local CAPTION_MAX_DURATION_SECONDS = 45 * 60
-- Same staleness rule the video transcodes use: a marker older than this
-- means a crashed job, not a running one.
local JOB_STALE_SECONDS = 30 * 60

local function api()
  return require("routes")._video_extras_api
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function ffmpeg_bin()
  return os.getenv("GALLERY_FFMPEG_BIN") or "ffmpeg"
end

local function ffprobe_bin()
  return os.getenv("GALLERY_FFPROBE_BIN") or "ffprobe"
end

local function whisper_bin()
  return os.getenv(CAPTION_BIN_ENV) or "whisper-cli"
end

local function whisper_model()
  return os.getenv(CAPTION_MODEL_ENV) or (os.getenv("HOME") or "/root") .. "/.cache/llm-eval/ggml-base.en.bin"
end

local function file_exists(path)
  local handle = io.open(path, "rb")
  if not handle then return false end
  handle:close()
  return true
end

local function file_mtime(path)
  local handle = io.popen("stat -c %Y " .. shell_quote(path) .. " 2>/dev/null")
  if not handle then return nil end
  local value = tonumber(handle:read("*l") or "")
  handle:close()
  return value
end

local function read_file(path)
  local handle = io.open(path, "rb")
  if not handle then return nil end
  local bytes = handle:read("*a")
  handle:close()
  return bytes
end

local function extras_dir(media_id, digest_seed)
  local sodium = require("luasodium")
  local key = sodium.sodium_bin2hex(sodium.crypto_hash_sha256(tostring(digest_seed))):sub(1, 16)
  return api().settings().uploads_dir .. "/_extras_cache/" .. tostring(media_id) .. "_" .. key
end

-- Picks the cheapest already-complete rendition to read from. Explicitly
-- prefers the SMALL end of the ladder: this is a 160px-wide sprite and a
-- 16kHz mono audio track, so decoding 1080p to make them would be pure
-- waste. Falls back to the original only when nothing is warm yet, and
-- returns nil rather than triggering a transcode -- neither of these
-- features is worth occupying a GPU slot the real player is waiting on.
local function warm_source_playlist(media_id, item)
  local helpers = api()
  local seed = helpers.digest_seed(media_id, item, nil)
  for _, quality in ipairs({ "480p", "720p", "144p", "1080p", "original" }) do
    local dir = helpers.variant_dir(media_id, quality, seed)
    if helpers.variant_ready(dir) then
      return dir .. "/playlist.m3u8"
    end
  end
  return nil
end

local function probe_duration(path)
  local handle = io.popen(string.format(
    "%s -v error -allowed_extensions ALL -show_entries format=duration -of csv=p=0 %s 2>/dev/null",
    ffprobe_bin(), shell_quote(path)
  ))
  if not handle then return nil end
  local value = tonumber(handle:read("*l") or "")
  handle:close()
  if not value or value <= 0 then return nil end
  return value
end

-- A `.pending` marker next to the output, exactly like ensure_hls_variant's:
-- it is what stops every request during a long job from launching another
-- copy of it, and a stale one (crashed job) is reclaimed on age.
-- The create is atomic (shell noclobber): several worker processes serve
-- the same video's requests, and a check-then-write let two of them start
-- the same multi-minute ffmpeg job at once (seen live: two identical
-- sprite jobs for one video saturating the CPU).
local function claim_job(marker_path)
  local existing = file_mtime(marker_path)
  if existing and (os.time() - existing) < JOB_STALE_SECONDS then return false end
  os.execute("mkdir -p " .. shell_quote(marker_path:match("^(.*)/[^/]+$") or "."))
  if existing then os.remove(marker_path) end -- stale: a crashed job's leftover
  local rc = os.execute(string.format("set -C; { printf %%s %s > %s ; } 2>/dev/null",
    tostring(os.time()), shell_quote(marker_path)))
  return rc == 0 or rc == true
end

-- ---------------------------------------------------------------------------
-- Seek-preview sprites
-- ---------------------------------------------------------------------------

local function sprite_paths(media_id, item)
  local dir = extras_dir(media_id, api().digest_seed(media_id, item, nil))
  return dir .. "/sprite.jpg", dir .. "/sprite.vtt", dir .. "/sprite.pending", dir
end

local function format_vtt_time(seconds)
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  local secs = seconds % 60
  return string.format("%02d:%02d:%06.3f", hours, minutes, secs)
end

-- The WebVTT half of the pair: one cue per tile, each pointing at a
-- rectangle of the sheet with the standard `#xywh=` media fragment. This
-- is the format every player understands, so the same two files drive the
-- web scrubber and anything else that might want them later.
local function write_sprite_vtt(path, duration, interval, tile_height)
  local lines = { "WEBVTT", "" }
  local tiles = math.min(SPRITE_MAX_TILES, math.max(1, math.ceil(duration / interval)))
  for index = 0, tiles - 1 do
    local start_time = index * interval
    local end_time = math.min(duration, start_time + interval)
    if end_time <= start_time then break end
    local column = index % SPRITE_COLUMNS
    local row = math.floor(index / SPRITE_COLUMNS)
    lines[#lines + 1] = format_vtt_time(start_time) .. " --> " .. format_vtt_time(end_time)
    lines[#lines + 1] = string.format(
      "sprite.jpg#xywh=%d,%d,%d,%d",
      column * SPRITE_TILE_WIDTH, row * tile_height, SPRITE_TILE_WIDTH, tile_height
    )
    lines[#lines + 1] = ""
  end
  local handle = io.open(path, "wb")
  if not handle then return false end
  handle:write(table.concat(lines, "\n"))
  handle:close()
  return true
end

-- Returns "ready", "pending", or nil when this video has nothing warm to
-- build from yet (the caller reports that as pending too -- the warmer
-- will get there, and a later request will start the job).
function M.ensure_sprite(media_id, item)
  local sheet, vtt, marker = sprite_paths(media_id, item)
  if file_exists(sheet) and file_exists(vtt) then return "ready" end

  local source = warm_source_playlist(media_id, item)
  if not source then return "pending" end
  local duration = probe_duration(source)
  if not duration then return "pending" end
  if not claim_job(marker) then return "pending" end

  local interval = math.max(SPRITE_MIN_INTERVAL, math.ceil(duration / SPRITE_MAX_TILES))
  -- -2 keeps the tile height even (required by most encoders) and
  -- preserves the source aspect ratio; ffprobe tells us what it actually
  -- produced rather than us assuming 16:9, because a vertical phone video
  -- would otherwise get cues describing rectangles that aren't there.
  local dir = sheet:match("^(.*)/[^/]+$")
  os.execute("mkdir -p " .. shell_quote(dir))
  local command = string.format(
    -- -skip_frame nokey: decode keyframes only (~5x faster); a tile per
    -- several seconds doesn't need every frame decoded to pick from.
    "( nice -n 15 ionice -c2 -n6 %s -nostdin -v error -allowed_extensions ALL -skip_frame nokey -i %s "
      .. "-vf %s -frames:v 1 -q:v 6 %s -y ; rm -f %s ) </dev/null >/dev/null 2>&1 &",
    ffmpeg_bin(),
    shell_quote(source),
    shell_quote(string.format("fps=1/%d,scale=%d:-2,tile=%dx%d", interval, SPRITE_TILE_WIDTH, SPRITE_COLUMNS, SPRITE_ROWS)),
    shell_quote(sheet),
    shell_quote(marker)
  )
  os.execute(command)

  -- The VTT describes a geometry ffmpeg hasn't finished producing yet, so
  -- it is written by the follow-up request that finds the sheet on disk.
  -- Storing the interval alongside means that request doesn't have to
  -- re-probe the source to know what the tiles mean.
  local meta = io.open(dir .. "/sprite.meta", "wb")
  if meta then
    meta:write(string.format("%d\n%.3f\n", interval, duration))
    meta:close()
  end
  return "pending"
end

-- Called on the read path: finishes the pair once ffmpeg has produced the
-- sheet. Split from ensure_sprite because the tile height is only knowable
-- from the finished image.
local function finalize_sprite_vtt(media_id, item)
  local sheet, vtt, _, dir = sprite_paths(media_id, item)
  if file_exists(vtt) or not file_exists(sheet) then return end
  local meta = read_file(dir .. "/sprite.meta")
  if not meta then return end
  local interval, duration = meta:match("^(%d+)%s+([%d%.]+)")
  interval, duration = tonumber(interval), tonumber(duration)
  if not interval or not duration then return end
  local handle = io.popen(string.format(
    "%s -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 %s 2>/dev/null",
    ffprobe_bin(), shell_quote(sheet)
  ))
  if not handle then return end
  local sheet_height = tonumber(handle:read("*l") or "")
  handle:close()
  if not sheet_height or sheet_height <= 0 then return end
  write_sprite_vtt(vtt, duration, interval, math.floor(sheet_height / SPRITE_ROWS))
end

-- ---------------------------------------------------------------------------
-- Auto-generated captions
-- ---------------------------------------------------------------------------

local function caption_paths(media_id, item)
  local dir = extras_dir(media_id, api().digest_seed(media_id, item, nil))
  return dir .. "/captions.vtt", dir .. "/captions.pending", dir .. "/captions.none", dir
end

function M.captions_available(media_id, item)
  local vtt = caption_paths(media_id, item)
  return file_exists(vtt)
end

-- Generates the track if it doesn't exist. Whisper runs against audio
-- pulled from a warm rendition, in one backgrounded shell pipeline so the
-- copas event loop is never blocked -- this file follows the same
-- fire-and-forget + poll-the-filesystem pattern ensure_hls_variant uses,
-- for the same reason (a single-threaded server cannot afford to sit
-- inside a multi-second os.execute).
function M.ensure_captions(media_id, item)
  local vtt, marker, none_marker, dir = caption_paths(media_id, item)
  if file_exists(vtt) then return "ready" end
  -- A video whose audio produced nothing (no speech, or a silent track)
  -- must not be retried on every single request forever.
  if file_exists(none_marker) then return "unavailable" end

  local source = warm_source_playlist(media_id, item)
  if not source then return "pending" end
  local duration = probe_duration(source)
  if duration and duration > CAPTION_MAX_DURATION_SECONDS then
    os.execute("mkdir -p " .. shell_quote(dir))
    local skip = io.open(none_marker, "wb")
    if skip then skip:write("too_long"); skip:close() end
    return "unavailable"
  end
  if not claim_job(marker) then return "pending" end

  os.execute("mkdir -p " .. shell_quote(dir))
  local wav = dir .. "/audio.wav"
  local stem = dir .. "/captions"
  -- whisper-cli writes "<stem>.vtt" itself (-of takes the path WITHOUT the
  -- extension), so the output lands exactly on `vtt`. The `.none` marker
  -- on the failure branch is what makes "this video has no captions" a
  -- cached answer rather than a job relaunched on every page view.
  local command = string.format(
    "( nice -n 15 ionice -c2 -n6 %s -nostdin -v error -allowed_extensions ALL -i %s -vn -ac 1 -ar 16000 -f wav %s -y "
      .. "&& nice -n 15 %s -m %s -f %s -ovtt -of %s -np -t %d >/dev/null 2>&1 ; "
      .. "if [ ! -s %s ]; then : > %s; fi ; rm -f %s %s ) </dev/null >/dev/null 2>&1 &",
    ffmpeg_bin(), shell_quote(source), shell_quote(wav),
    shell_quote(whisper_bin()), shell_quote(whisper_model()), shell_quote(wav), shell_quote(stem), WHISPER_THREADS,
    shell_quote(vtt), shell_quote(none_marker),
    shell_quote(wav), shell_quote(marker)
  )
  os.execute(command)
  return "pending"
end

-- ---------------------------------------------------------------------------
-- Routes
-- ---------------------------------------------------------------------------

local function access_or_error(req)
  local media_id = tonumber(req.params.media_id)
  if not media_id then return nil, 404, { detail = "Media not found." } end
  local item, status, body, publicly_cacheable = api().check_access(req, media_id)
  if not item then return nil, status, body end
  return media_id, item, publicly_cacheable
end

-- One round trip telling the player everything optional about this video:
-- whether a sprite sheet and a caption track exist yet, and kicking off
-- whichever doesn't. A single endpoint rather than the client probing two
-- URLs and interpreting 404s, and a GET with no side effects visible to
-- the caller beyond "work may now be queued".
function M.playback_extras(req)
  local media_id, item, _ = access_or_error(req)
  if not media_id then return item, _ end

  finalize_sprite_vtt(media_id, item)
  local sprite_status = M.ensure_sprite(media_id, item)
  local caption_status = M.ensure_captions(media_id, item)
  -- ensure_sprite returns before its VTT exists; only advertise the pair
  -- once both halves are actually readable, since the client needs both.
  local sheet, vtt = sprite_paths(media_id, item)
  if not (file_exists(sheet) and file_exists(vtt)) then sprite_status = "pending" end

  local qs = ""
  local access = req.query and req.query.access
  if access and access ~= "" then qs = "?access=" .. access end

  return 200, {
    sprite = {
      status = sprite_status,
      sheet_url = sprite_status == "ready" and string.format("/api/media/%d/sprite.jpg%s", media_id, qs) or nil,
      vtt_url = sprite_status == "ready" and string.format("/api/media/%d/sprite.vtt%s", media_id, qs) or nil,
    },
    captions = {
      status = caption_status,
      vtt_url = caption_status == "ready" and string.format("/api/media/%d/captions/en.vtt%s", media_id, qs) or nil,
      language = "en",
      -- Machine-generated, and the player says so: a viewer reading a
      -- mis-transcribed line should know why it's wrong.
      auto_generated = true,
    },
  }
end

function M.serve_sprite_sheet(req)
  local media_id, item, publicly_cacheable = access_or_error(req)
  if not media_id then return item, publicly_cacheable end
  local sheet = sprite_paths(media_id, item)
  local bytes = read_file(sheet)
  if not bytes then return 404, { detail = "No preview sprite for this video yet." } end
  return 200, bytes, {
    ["Content-Type"] = "image/jpeg",
    ["Cache-Control"] = publicly_cacheable and "public, max-age=604800, immutable" or "private, max-age=604800",
  }
end

function M.serve_sprite_vtt(req)
  local media_id, item, publicly_cacheable = access_or_error(req)
  if not media_id then return item, publicly_cacheable end
  finalize_sprite_vtt(media_id, item)
  local _, vtt = sprite_paths(media_id, item)
  local bytes = read_file(vtt)
  if not bytes then return 404, { detail = "No preview sprite for this video yet." } end
  return 200, bytes, {
    ["Content-Type"] = "text/vtt; charset=utf-8",
    ["Cache-Control"] = publicly_cacheable and "public, max-age=604800, immutable" or "private, max-age=604800",
  }
end

function M.serve_captions(req)
  local media_id, item, publicly_cacheable = access_or_error(req)
  if not media_id then return item, publicly_cacheable end
  local vtt = caption_paths(media_id, item)
  local bytes = read_file(vtt)
  if not bytes then return 404, { detail = "No captions for this video." } end
  return 200, bytes, {
    ["Content-Type"] = "text/vtt; charset=utf-8",
    ["Cache-Control"] = publicly_cacheable and "public, max-age=604800, immutable" or "private, max-age=604800",
  }
end

-- The subtitle half of an HLS presentation. Web attaches the VTT above
-- directly as a <track> element, which is simpler and works on both its
-- playback paths -- but AVPlayer cannot side-load a subtitle file at all,
-- so on iOS the only way captions reach the player is as a subtitle
-- rendition inside the manifest. This is that rendition: a one-cue-file
-- VOD playlist, referenced from the per-quality master below.
function M.serve_captions_playlist(req)
  local media_id, item, publicly_cacheable = access_or_error(req)
  if not media_id then return item, publicly_cacheable end
  if not M.captions_available(media_id, item) then
    return 404, { detail = "No captions for this video." }
  end
  local source = warm_source_playlist(media_id, item)
  local duration = (source and probe_duration(source)) or 3600
  local qs = ""
  local access = req.query and req.query.access
  if access and access ~= "" then qs = "?access=" .. access end
  local lines = {
    "#EXTM3U",
    "#EXT-X-VERSION:3",
    "#EXT-X-PLAYLIST-TYPE:VOD",
    "#EXT-X-TARGETDURATION:" .. tostring(math.ceil(duration)),
    "#EXT-X-MEDIA-SEQUENCE:0",
    string.format("#EXTINF:%.3f,", duration),
    string.format("/api/media/%d/captions/en.vtt%s", media_id, qs),
    "#EXT-X-ENDLIST",
  }
  return 200, table.concat(lines, "\n") .. "\n", {
    ["Content-Type"] = "application/vnd.apple.mpegurl",
    ["Cache-Control"] = publicly_cacheable and "public, max-age=3600" or "no-cache",
  }
end

-- A master playlist wrapping exactly ONE rendition, plus the subtitle
-- group when captions exist.
--
-- Deliberately not the site-wide master.m3u8 (serve_hls_master), which
-- lists the whole ladder: handing AVPlayer real ABR is what the iOS
-- client already tried once and reverted, because a cold rendition
-- stalls. This keeps the viewer's explicit quality choice exactly as it
-- is today and changes nothing about which video segments get fetched --
-- it exists purely so a player that can only receive subtitles through a
-- manifest can receive them.
function M.serve_quality_master(req)
  local media_id, item, publicly_cacheable = access_or_error(req)
  if not media_id then return item, publicly_cacheable end
  local quality = tostring(req.params.quality or "original")
  local qs = ""
  local access = req.query and req.query.access
  if access and access ~= "" then qs = "?access=" .. access end

  local lines = { "#EXTM3U", "#EXT-X-VERSION:6" }
  local has_captions = M.captions_available(media_id, item)
  if has_captions then
    lines[#lines + 1] = string.format(
      '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English (auto)",LANGUAGE="en",'
        .. 'DEFAULT=NO,AUTOSELECT=YES,FORCED=NO,URI="/api/media/%d/captions/subs.m3u8%s"',
      media_id, qs
    )
  end
  lines[#lines + 1] = "#EXT-X-STREAM-INF:BANDWIDTH=8000000" .. (has_captions and ',SUBTITLES="subs"' or "")
  lines[#lines + 1] = string.format("/api/media/%d/hls/%s/playlist.m3u8%s", media_id, quality, qs)
  return 200, table.concat(lines, "\n") .. "\n", {
    ["Content-Type"] = "application/vnd.apple.mpegurl",
    -- Short, not immutable: this document's content changes the moment
    -- captions finish generating in the background.
    ["Cache-Control"] = publicly_cacheable and "public, max-age=60" or "no-cache",
  }
end

return M
