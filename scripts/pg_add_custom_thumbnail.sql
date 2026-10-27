-- Adds media_items.custom_thumb_path: an uploader-chosen thumbnail image
-- for a video (lua/src/routes.lua's custom thumbnail section). Relative to
-- the uploads dir (or the fast-disk tier), e.g.
-- custom_thumbs/2a/4348_9f2c1d0b7e6a5f43.jpg. NULL = automatic thumbnail
-- (a frame from the video, or the YouTube source link's thumbnail).
--
-- Idempotent: safe to re-run.

ALTER TABLE media_items ADD COLUMN IF NOT EXISTS custom_thumb_path TEXT;
