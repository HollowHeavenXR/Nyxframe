-- Adds media_items.video_codecs: "<video codec>/<pixel format>[+<audio codec>]"
-- for videos (e.g. "h264/yuv420p+aac"), probed once at upload or by the
-- startup backfill. Lets the API mark videos a browser can play straight
-- from the stored file (direct_play), so the web player skips the HLS
-- "original" copy -- a full duplicate of the video on the uploads drive.
--
-- Idempotent: safe to re-run.

ALTER TABLE media_items ADD COLUMN IF NOT EXISTS video_codecs TEXT;
