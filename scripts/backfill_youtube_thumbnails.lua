-- One-off backfill for the YouTube-source-link thumbnail-override feature
-- (see routes.lua's youtube_video_id column + M.serve_media_thumb branch,
-- and youtube_thumb.lua). Needed because of a deploy-ordering accident: the
-- rolling restart that picked up the MemoryHigh guardrail happened at
-- 17:47:46 on 2026-10-22, three minutes BEFORE the commit containing this
-- feature (35d47b0, 17:50:49) was pushed -- so every post uploaded with a
-- youtu.be/youtube.com source_url between then and the next restart got its
-- source_url saved normally but never got youtube_video_id computed at all
-- (the INSERT that ran didn't even have that column in it yet). Those rows
-- also raced against prewarm_video_thumb (see its routes.lua fix the same
-- day), which cached a plain frame-grab as the 520px thumbnail before any
-- viewer ever hit the YouTube-aware path.
--
-- This script: finds every media_items row with a youtube.com/youtu.be
-- source_url but no youtube_video_id, computes it with the same
-- youtube_thumb.extract_video_id used on the live upload path, writes it
-- back, and deletes that row's cached thumbnail files (every width, both
-- the sharded-video and flat-image cache layouts) so the next viewer
-- request regenerates it through M.serve_media_thumb's YouTube branch
-- instead of serving the stale frame-grab from cache.
--
-- Run manually (same invocation style as thumb_backfill_standalone.lua),
-- from lua/, with GALLERY_UPLOADS_DIR exported to match the live service's
-- real value (check `systemctl --user show nyxframe-lua@8790.service -p
-- Environment`):
--   luajit ../scripts/backfill_youtube_thumbnails.lua
package.path = "./lib/?.lua;./lib/?/init.lua;./src/?.lua;" .. package.path

local db = require("db")
local youtube_thumb = require("youtube_thumb")

local uploads_dir = os.getenv("GALLERY_UPLOADS_DIR")
if not uploads_dir or uploads_dir == "" then
  print("[yt_backfill] GALLERY_UPLOADS_DIR is not set -- refusing to guess, see header comment")
  os.exit(1)
end
uploads_dir = uploads_dir:gsub("/+$", "")

db.init({
  db_host = os.getenv("GALLERY_DB_HOST") or "127.0.0.1",
  db_port = tonumber(os.getenv("GALLERY_DB_PORT")) or 5432,
  db_user = os.getenv("GALLERY_DB_USER"),
  db_password = os.getenv("GALLERY_DB_PASSWORD"),
  db_name = os.getenv("GALLERY_DB_SCHEMA"),
  db_pool_size = 1,
})

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Removes every cached-thumbnail file for media_id regardless of width,
-- across both cache layouts M.serve_media_thumb uses (sharded for videos,
-- flat for images) -- cheaper and more robust than recomputing exactly
-- which widths got prewarmed/requested so far.
local function clear_thumb_cache(media_id)
  local shard = string.format("%02x", media_id % 256)
  local shard_dir = uploads_dir .. "/_thumb_cache/" .. shard
  local flat_dir = uploads_dir .. "/_thumb_cache"
  os.execute("rm -f -- " .. shell_quote(shard_dir) .. "/" .. media_id .. "_*.webp*")
  os.execute("rm -f -- " .. shell_quote(flat_dir) .. "/" .. media_id .. "_*.webp*")
end

local rows, err = db.fetchall([[
  SELECT id, source_url FROM media_items
  WHERE youtube_video_id IS NULL
    AND source_url IS NOT NULL
    AND (source_url ILIKE '%youtube.com%' OR source_url ILIKE '%youtu.be%')
  ORDER BY id
]])
if err then
  print("[yt_backfill] could not list candidate rows: " .. tostring(err))
  os.exit(1)
end

local updated, no_match, failed = 0, 0, 0

for _, row in ipairs(rows) do
  local media_id = db.toint(row.id, row.id)
  local video_id = youtube_thumb.extract_video_id(row.source_url)
  if not video_id then
    no_match = no_match + 1
    print(string.format("[yt_backfill] media %d: source_url %q didn't match any known YouTube URL shape, skipping", media_id, row.source_url))
  else
    -- Also bumps updated_at -- thumb_url_for (routes.lua) keys its `v=`
    -- cache-busting query param off this column, so this is what actually
    -- makes already-cached clients fetch the regenerated thumbnail instead
    -- of replaying a week-old immutable-cached copy of the old one.
    local ok, update_err = db.execute(
      "UPDATE media_items SET youtube_video_id = %s, updated_at = now() WHERE id = %s",
      video_id, tostring(media_id)
    )
    if ok then
      clear_thumb_cache(media_id)
      updated = updated + 1
      print(string.format("[yt_backfill] media %d: youtube_video_id = %s, cache cleared", media_id, video_id))
    else
      failed = failed + 1
      print(string.format("[yt_backfill] media %d: UPDATE failed: %s", media_id, tostring(update_err)))
    end
  end
end

print(string.format(
  "[yt_backfill] done -- updated %d, no match %d, failed %d, total candidates %d",
  updated, no_match, failed, #rows
))
