-- Image Gallery backend entrypoint (Lua rewrite, first pass).
-- Run with: luajit main.lua   (see Dockerfile for the containerized path)

package.path = "./lib/?.lua;./lib/?/init.lua;./src/?.lua;" .. package.path

-- Stall detector: must load before anything requires copas (see blockwatch.lua).
require("blockwatch").install()

local httpd = require("httpd")
local db = require("db")
local config = require("config")
local routes = require("routes")
local webpush = require("webpush")
local video_extras = require("video_extras")
local static = require("static")
local pages_auth = require("pages_auth")
local pages_admin = require("pages_admin")
local pages_totp = require("pages_totp")
local pages_feeds = require("pages_feeds")
local telemetry = require("telemetry")

local settings = config.load()
routes.settings = settings
-- webpush.lua is a leaf module (no require("routes"), see its own header
-- comment) -- it gets what little config it needs (where to persist the
-- generated VAPID keypair, the JWT `sub` contact claim) as plain fields,
-- same wiring style httpd.trusted_proxy_cidrs/httpd.cors already use below.
webpush.uploads_dir = settings.uploads_dir
webpush.vapid_subject = os.getenv("GALLERY_VAPID_SUBJECT") or "mailto:admin@localhost"
db.init(settings)
require("discord_bot").init(settings)

-- In-depth telemetry (lua/src/telemetry.lua): request latency/error stats,
-- background-job outcomes, uploads/auth/media-diagnostics event rows. Hooked
-- into httpd.lua via a plain settable field (M.on_request) rather than a
-- `require("telemetry")` inside httpd.lua itself, so that file stays
-- decoupled from the telemetry/db modules.
telemetry.init(settings)
httpd.on_request = telemetry.record_request

-- Only trust X-Forwarded-For from these peers (see config.lua's
-- trusted_proxy_cidrs doc comment and httpd.lua's client-IP resolution) --
-- everything else falls back to the raw TCP peer address, closing the
-- unauthenticated-XFF rate-limit bypass this previously had wide open.
httpd.trusted_proxy_cidrs = settings.trusted_proxy_cidrs

-- CORS: mirror app/main.py's allow-listed origins + regex fallback for
-- ephemeral tunnel hosts (Cloudflare/ngrok/pinggy). httpd.lua's CORS support
-- (vendored from SwarmPanel) only does exact-match against
-- M.cors.allowed_origins plus an optional M.cors.origin_suffix_matcher
-- function -- reused as-is rather than porting FastAPI's regex-based
-- CORSMiddleware line for line.
httpd.cors.allowed_origins = settings.cors_allowed_origins
if #httpd.cors.allowed_origins == 0 then
  httpd.cors.allowed_origins = {
    settings.pages_public_url:gsub("/+$", ""),
    "http://127.0.0.1:8788", "http://localhost:8788",
    "http://127.0.0.1:8000", "http://localhost:8000",
  }
end
if settings.cors_allow_origin_regex and settings.cors_allow_origin_regex ~= "" then
  -- NOT a full PCRE port of the Python regex (Lua patterns are far more
  -- limited) -- covers the common tunnel-host suffixes actually used by
  -- this deployment (trycloudflare.com, ngrok-free.dev, ngrok.io,
  -- pinggy-free.link, serveousercontent.com, lhr.life). Revisit if a new
  -- tunnel provider is added.
  --
  -- SECURITY: this used to also unconditionally allow any
  -- http://localhost:*, http://127.0.0.1:*, http://10.x.x.x, or
  -- http://192.168.x.x origin, "for local development" -- but that ran in
  -- production too, with Access-Control-Allow-Credentials: true (see
  -- httpd.lua's apply_cors), meaning any page loaded from a private-LAN
  -- address (e.g. another device on the same Wi-Fi, or malicious JS running
  -- in a LAN-hosted page) could make credentialed cross-origin requests
  -- against this gallery using the visitor's own session cookie. Removed:
  -- there's no dev-mode flag in config.lua to gate it behind, and the
  -- explicit http://127.0.0.1:8788 / http://localhost:8788 entries already
  -- seeded into httpd.cors.allowed_origins above (when
  -- GALLERY_CORS_ALLOWED_ORIGINS is unset) cover local dev against this
  -- backend's own default port without reopening the whole private
  -- address space.
  local TUNNEL_SUFFIXES = { "trycloudflare%.com", "ngrok%-free%.dev", "ngrok%.io", "pinggy%-free%.link", "serveousercontent%.com", "lhr%.life" }
  httpd.cors.origin_suffix_matcher = function(origin)
    for _, suffix in ipairs(TUNNEL_SUFFIXES) do
      if origin:match("^https://[%w%-]+%." .. suffix .. "$") then return true end
    end
    return false
  end
end

httpd.route("GET", "/api/health", routes.health)
httpd.route("GET", "/api/live/checks", routes.live_checks)
httpd.route("GET", "/api/status", routes.public_status)

httpd.route("POST", "/api/auth/register", routes.register)
httpd.route("POST", "/api/auth/login", routes.login)
httpd.route("POST", "/api/auth/2fa/verify", routes.verify_2fa)
httpd.route("POST", "/api/auth/logout", routes.logout)
httpd.route("GET", "/api/me", routes.me)
httpd.route("GET", "/api/me/media", routes.my_media)
httpd.route("GET", "/api/me/continue-watching", routes.continue_watching)
httpd.route("GET", "/api/me/on-this-day", routes.on_this_day)
httpd.route("GET", "/api/me/stats", routes.creator_stats)
httpd.route("GET", "/api/me/year-recap", routes.year_recap)
httpd.route("GET", "/api/me/likes", routes.feed_liked)
httpd.route("GET", "/api/feed/following", routes.feed_following)
httpd.route("GET", "/api/feed/signal", routes.feed_signal)
httpd.route("GET", "/api/feed/for-you", routes.feed_for_you)
httpd.route("PATCH", "/api/me/profile", routes.update_profile)
httpd.route("PATCH", "/api/me/settings", routes.update_settings)
httpd.route("POST", "/api/me/avatar", routes.update_avatar)
httpd.route("POST", "/api/me/age-verification", routes.verify_age)
httpd.route("POST", "/api/me/password", routes.change_password)
httpd.route("GET", "/api/me/export", routes.export_account)
httpd.route("GET", "/api/me/discord/verify/status", routes.discord_verify_status)
httpd.route("POST", "/api/me/discord/verify/start", routes.discord_verify_start)
httpd.route("POST", "/api/me/discord/verify/confirm", routes.discord_verify_confirm)
httpd.route("POST", "/api/me/discord/unlink", routes.discord_unlink)
httpd.route("GET", "/api/appearance/presets", routes.appearance_presets)

httpd.route("GET", "/api/categories", routes.list_categories)
httpd.route("POST", "/api/categories", routes.create_category)
httpd.route("GET", "/api/leaderboard", routes.leaderboard)

httpd.route("GET", "/api/media", routes.list_media)
httpd.route("POST", "/api/media", routes.upload_media)
-- "/bulk" and "/bulk-delete" MUST be registered before "/api/media/:media_id"
-- below (same first-match-wins ordering trap noted further down) since they
-- are literal 2nd-segment paths under /api/media/*, same shape as :media_id.
httpd.route("POST", "/api/media/bulk", routes.bulk_edit_media)
httpd.route("POST", "/api/media/bulk-delete", routes.bulk_delete_media)
httpd.route("POST", "/api/media/download-batch", routes.download_media_batch)
httpd.route("POST", "/api/media/analyze", routes.analyze_media)
httpd.route("POST", "/api/media/upload/init", routes.upload_chunk_init)
httpd.route("POST", "/api/media/upload/chunk", routes.upload_chunk_append)
httpd.route("POST", "/api/media/upload/finish", routes.upload_chunk_finish)
httpd.route("GET", "/api/media/upload/job/:job_id", routes.upload_job_status)
httpd.route("POST", "/api/media/upload/diagnostics", routes.upload_client_diagnostic)
httpd.route("GET", "/api/media/trending", routes.media_trending)
httpd.route("GET", "/api/media/random", routes.media_random)
-- ROUTE-ORDERING TRAP for future passes: httpd.lua's match_route() returns
-- the FIRST registered route whose pattern matches, with no most-specific-
-- wins logic. "/api/media/:media_id" below matches ANY single path segment
-- after "/api/media/", including literal ones like "analyze" (real Python
-- route -- see app/routers/media.py -- not yet ported here, part of the LLM
-- classification pipeline in TODO.md). Any such literal-segment route added
-- later MUST be registered BEFORE this line, or it will never be reached
-- (silently "handled" by media_detail's tonumber(...) failing and returning
-- a 404 instead of the real handler running).
httpd.route("GET", "/api/media/:media_id", routes.media_detail)
httpd.route("PATCH", "/api/media/:media_id", routes.update_media)
httpd.route("DELETE", "/api/media/:media_id", routes.delete_media)
httpd.route("POST", "/api/media/:media_id/like", routes.like_media)
httpd.route("POST", "/api/media/:media_id/viewing", routes.media_viewing_heartbeat)
httpd.route("POST", "/api/media/:media_id/bookmark", routes.bookmark_media)
httpd.route("POST", "/api/media/:media_id/comments", routes.add_comment)
httpd.route("POST", "/api/media/:media_id/react", routes.react_to_media_route)
httpd.route("GET", "/api/media/:media_id/similar", routes.similar_media)
httpd.route("GET", "/api/media/:media_id/visual-similar", routes.visual_search_from_media)
httpd.route("GET", "/api/media/:media_id/history", routes.media_edit_history)
httpd.route("PATCH", "/api/media/:media_id/controls", routes.set_media_controls)
httpd.route("POST", "/api/media/:media_id/restore", routes.restore_media)
httpd.route("POST", "/api/media/:media_id/report", routes.report_media)
httpd.route("POST", "/api/media/:media_id/ai/train", routes.train_media_ai)
httpd.route("POST", "/api/media/:media_id/diagnostics/load", routes.media_load_diagnostic)
httpd.route("POST", "/api/media/:media_id/diagnostics/playback", routes.media_playback_diagnostic)
httpd.route("GET", "/api/me/personal-tags", routes.my_personal_tags)
httpd.route("POST", "/api/media/:media_id/personal-tags", routes.add_personal_tag)
httpd.route("DELETE", "/api/media/:media_id/personal-tags/:tag", routes.remove_personal_tag)
httpd.route("DELETE", "/api/comments/:comment_id", routes.delete_comment)
httpd.route("POST", "/api/comments/:comment_id/react", routes.react_to_comment_route)

httpd.route("GET", "/api/media/:media_id/thumb", routes.serve_media_thumb)
-- Same handlers under a .webp path: Cloudflare caches .webp at its edge by
-- default, so public thumbs/previews are served near the visitor instead of
-- through the tunnel. Adult/private/expiring items answer with
-- "Cache-Control: private", which the edge never stores (2026-10-26).
httpd.route("GET", "/api/media/:media_id/thumb.webp", routes.serve_media_thumb)
httpd.route("GET", "/api/media/:media_id/preview.webp", routes.serve_media_preview)
httpd.route("GET", "/api/media/:media_id/watch-progress", routes.watch_progress)
httpd.route("POST", "/api/media/:media_id/watch-progress", routes.save_watch_progress)
httpd.route("GET", "/api/media/:media_id/file", routes.serve_media_file)
httpd.route("GET", "/api/media/:media_id/preview", routes.serve_media_preview)
httpd.route("GET", "/api/media/:media_id/hls/master.m3u8", routes.serve_hls_master)
-- ":quality/playlist.m3u8" MUST be registered before ":quality/:segment" --
-- both are 4 segments deep, and the wildcard :segment pattern would
-- otherwise greedily match the literal "playlist.m3u8" too (same
-- first-match-wins ordering trap noted above for /api/media/:media_id).
httpd.route("GET", "/api/media/:media_id/hls/:quality/playlist.m3u8", routes.serve_hls_playlist)
httpd.route("GET", "/api/media/:media_id/hls/:quality/master.m3u8", video_extras.serve_quality_master)
httpd.route("GET", "/api/media/:media_id/hls/:quality/:segment", routes.serve_hls_segment)
httpd.route("GET", "/api/media/:media_id/download", routes.download_media)

-- Optional per-video extras: seek-preview sprites and auto-generated
-- captions (src/video_extras.lua). Registered here rather than in
-- routes.lua because that file is at LuaJIT's 200-local ceiling -- see
-- its `_video_extras_api` comment. "/captions/subs.m3u8" exists only for
-- AVPlayer, which unlike a browser cannot side-load a subtitle file and
-- can only receive one through the HLS manifest.
httpd.route("GET", "/api/media/:media_id/playback-extras", video_extras.playback_extras)
httpd.route("GET", "/api/media/:media_id/sprite.jpg", video_extras.serve_sprite_sheet)
httpd.route("GET", "/api/media/:media_id/sprite.vtt", video_extras.serve_sprite_vtt)
httpd.route("GET", "/api/media/:media_id/captions/en.vtt", video_extras.serve_captions)
httpd.route("GET", "/api/media/:media_id/captions/subs.m3u8", video_extras.serve_captions_playlist)
httpd.route("GET", "/api/users/:user_id/avatar", routes.serve_user_avatar)

-- "My Other Projects" tab -- see routes.lua's download_latest_ipa doc
-- comment for why this proxies through `gh` instead of linking straight to
-- GitHub (both repos are private -- Nyxframe's own repo goes back to
-- private once this session's CI-billing workaround is no longer needed,
-- same reason Lumisound already needed this).
httpd.route("GET", "/api/projects/lumisound/download", routes.download_lumisound)
httpd.route("GET", "/api/projects/nyxframe/download", routes.download_nyxframe)

-- Public profiles, follows, friend requests/friends, search, blocks -- see
-- routes.lua's "Public profiles, follows, friend requests..." section
-- header for why these were missing (never ported) and the git-history
-- recovery this pass is based on. "/search" MUST be registered before
-- "/api/users/:username" (same first-match-wins ordering trap noted
-- elsewhere in this file), and "/api/users/:username/profile" before the
-- bare "/api/users/:username" for the same reason.
httpd.route("GET", "/api/users/search", routes.search_users)
httpd.route("GET", "/api/users/suggested", routes.suggested_users)
httpd.route("POST", "/api/search/visual", routes.visual_search)
httpd.route("GET", "/api/users/:username/profile", routes.profile_page)
httpd.route("GET", "/api/users/:username", routes.public_profile)
httpd.route("POST", "/api/users/:user_id/follow", routes.follow_user)
httpd.route("PATCH", "/api/users/:user_id/follow-mute", routes.set_follow_mute)
httpd.route("POST", "/api/users/:user_id/friend-request", routes.send_friend_request)
httpd.route("GET", "/api/friends/requests", routes.friend_requests_list)
httpd.route("POST", "/api/friends/requests/:request_id", routes.respond_friend_request)
httpd.route("GET", "/api/me/friends", routes.my_friends)
httpd.route("GET", "/api/users/:user_id/followers", routes.user_followers)
httpd.route("GET", "/api/users/:user_id/following", routes.user_following)
httpd.route("GET", "/api/users/:user_id/friends", routes.user_friends)
httpd.route("POST", "/api/users/:user_id/block", routes.block_user)
httpd.route("GET", "/api/me/blocks", routes.my_blocks)

httpd.route("GET", "/api/me/2fa/status", routes.totp_status)
httpd.route("POST", "/api/me/2fa/enroll", routes.totp_enroll)
httpd.route("POST", "/api/me/2fa/confirm", routes.totp_confirm)
httpd.route("POST", "/api/me/2fa/disable", routes.totp_disable)

httpd.route("GET", "/api/tags", routes.tag_cloud)
httpd.route("GET", "/api/site/announcement", routes.site_announcement)
httpd.route("GET", "/api/site/background", routes.site_background)
httpd.route("GET", "/api/notifications", routes.notifications_list)
httpd.route("GET", "/api/notifications/unread-count", routes.notifications_unread_count)
httpd.route("POST", "/api/notifications/read-all", routes.notifications_mark_all_read)
httpd.route("POST", "/api/notifications/:notification_id/read", routes.notifications_mark_read)
httpd.route("GET", "/api/push/vapid-public-key", routes.push_vapid_public_key)
httpd.route("POST", "/api/push/subscribe", routes.push_subscribe)
httpd.route("POST", "/api/push/unsubscribe", routes.push_unsubscribe)

-- "/threads" MUST be registered before "/api/messages/:user_id" (same
-- first-match-wins ordering trap noted above for /api/media/:media_id).
httpd.route("GET", "/api/messages/threads", routes.message_threads)
httpd.route("GET", "/api/messages/:user_id", routes.direct_messages)
httpd.route("POST", "/api/messages/:user_id", routes.send_direct_message)

-- Group messaging (see routes.lua's "Group messaging" section). Register
-- the shorter path first, matching this file's established convention.
httpd.route("GET", "/api/threads", routes.list_groups)
httpd.route("POST", "/api/threads", routes.create_group)
httpd.route("GET", "/api/threads/:group_id/messages", routes.group_messages)
httpd.route("POST", "/api/threads/:group_id/messages", routes.send_group_message)

-- "/suggestions" MUST be registered before "/api/collections/:collection_id".
httpd.route("GET", "/api/collections/suggestions", routes.collection_suggestions)
httpd.route("GET", "/api/collections", routes.list_collections)
httpd.route("POST", "/api/collections", routes.create_collection)
httpd.route("GET", "/api/collections/:collection_id", routes.collection_detail)
httpd.route("GET", "/api/collections/:collection_id/download", routes.download_collection)
httpd.route("POST", "/api/collections/:collection_id/items", routes.save_collection_item)

httpd.route("GET", "/api/saved-searches", routes.list_saved_searches)
httpd.route("POST", "/api/saved-searches", routes.create_saved_search)
httpd.route("DELETE", "/api/saved-searches/:search_id", routes.delete_saved_search)
httpd.route("PATCH", "/api/saved-searches/:search_id/mute", routes.set_saved_search_mute)

httpd.route("GET", "/api/stats", routes.admin_stats)
httpd.route("GET", "/api/admin/telemetry", routes.admin_telemetry)
httpd.route("GET", "/api/admin/reports", routes.admin_list_reports)
httpd.route("POST", "/api/admin/reports/:report_id/resolve", routes.admin_resolve_report)
httpd.route("POST", "/api/admin/users/:user_id/ban", routes.admin_ban_user)
httpd.route("POST", "/api/admin/users/:user_id/unban", routes.admin_unban_user)
httpd.route("GET", "/api/admin/audit-log", routes.admin_audit_log)
httpd.route("GET", "/api/admin/flagged-media", routes.admin_flagged_media)
httpd.route("POST", "/api/admin/flagged-media/:media_id/resolve", routes.admin_resolve_flagged_media)
httpd.route("GET", "/api/admin/storage", routes.admin_storage)
httpd.route("POST", "/api/admin/storage/purge-orphans", routes.admin_purge_storage_orphans)
httpd.route("POST", "/api/admin/incidents", routes.admin_create_incident)
httpd.route("POST", "/api/admin/incidents/:incident_id/resolve", routes.admin_resolve_incident)
httpd.route("GET", "/api/admin/tags/:tag/usage", routes.admin_tag_usage)
httpd.route("POST", "/api/admin/tags/rename", routes.admin_rename_tag)
httpd.route("PATCH", "/api/admin/site-settings", routes.admin_update_site_settings)

-- Background music (see scripts/pg_add_background_music.sql). The two
-- public routes are unauthenticated on purpose -- ambient music isn't
-- gated content, every visitor's client fetches the track list and
-- streams from it the same way it fetches media thumbnails.
httpd.route("GET", "/api/admin/background-music", routes.admin_list_background_music)
httpd.route("POST", "/api/admin/background-music", routes.admin_upload_background_music)
httpd.route("DELETE", "/api/admin/background-music/:track_id", routes.admin_delete_background_music)
httpd.route("POST", "/api/admin/background-music/import-playlist", routes.admin_import_background_music_playlist)
httpd.route("GET", "/api/background-music", routes.list_background_music)
httpd.route("GET", "/api/background-music/:track_id/file", routes.serve_background_music_file)

-- "/export" MUST be registered before a future "/api/ai/vision/training/:id"-
-- shaped route, if one is ever added (none exists today, so ordering is not
-- currently load-bearing, but keep it above /training for consistency).
httpd.route("GET", "/api/ai/vision/status", routes.ai_vision_status)
httpd.route("GET", "/api/ai/vision/training/export", routes.export_ai_training)
httpd.route("GET", "/api/ai/vision/training", routes.list_ai_training)

-- Server-rendered login/register -- see pages_auth.lua's header comment for
-- why only these two pages, and how they reuse routes.login/register/
-- verify_2fa directly instead of duplicating auth logic. Registered before
-- static.register()/the SPA fallback so these exact paths win over the
-- React app's own client-side "/login" route on a hard navigation.
httpd.route("GET", "/login", pages_auth.login_page)
httpd.route("POST", "/login", pages_auth.login_submit)
httpd.route("POST", "/login/2fa", pages_auth.twofa_submit)
httpd.route("GET", "/register", pages_auth.register_page)
httpd.route("POST", "/register", pages_auth.register_submit)

-- Server-rendered site-owner admin dashboard -- see pages_admin.lua's
-- header comment. Every /admin/actions/* route re-checks site-ownership
-- itself (pages_admin.lua's gate()), so there's no privilege gap even
-- though these are registered like any other public path.
httpd.route("GET", "/admin", pages_admin.admin_page)
httpd.route("POST", "/admin/actions/report-resolve", pages_admin.action_report_resolve)
httpd.route("POST", "/admin/actions/flagged-resolve", pages_admin.action_flagged_resolve)
httpd.route("POST", "/admin/actions/ban", pages_admin.action_ban)
httpd.route("POST", "/admin/actions/unban", pages_admin.action_unban)
httpd.route("POST", "/admin/actions/purge-orphans", pages_admin.action_purge_orphans)
httpd.route("POST", "/admin/actions/site-settings", pages_admin.action_site_settings)

-- Server-rendered 2FA enrollment -- see pages_totp.lua's header comment.
-- Any logged-in user (not site-owner-only).
httpd.route("GET", "/settings/2fa", pages_totp.settings_page)
httpd.route("POST", "/settings/2fa/start", pages_totp.start_enrollment)
httpd.route("POST", "/settings/2fa/confirm", pages_totp.confirm_enrollment)
httpd.route("POST", "/settings/2fa/disable", pages_totp.disable_totp)

-- RSS feeds + sitemap -- see pages_feeds.lua's header comment. All public/
-- unauthenticated, crawlable endpoints. ".xml" is part of the literal path
-- (not an extension httpd.lua strips), matching what feed readers expect.
httpd.route("GET", "/feed.xml", pages_feeds.site_feed)
httpd.route("GET", "/feed/category/:slug.xml", pages_feeds.category_feed)
httpd.route("GET", "/feed/user/:username.xml", pages_feeds.user_feed)
httpd.route("GET", "/feed/tag/:tag.xml", pages_feeds.tag_feed)
httpd.route("GET", "/sitemap.xml", pages_feeds.sitemap)
httpd.route("GET", "/feed/me.xml", pages_feeds.personal_feed)

-- "On this day" memories + scoped read-only API keys.
httpd.route("GET", "/api/me/memories", routes.my_memories)
httpd.route("POST", "/api/me/api-keys", routes.create_api_key)
httpd.route("GET", "/api/me/api-keys", routes.list_api_keys)
httpd.route("DELETE", "/api/me/api-keys/:key_id", routes.revoke_api_key)

-- Serves the built React SPA directly at this backend's own hostname
-- (gallery.xenusanimations.studio), the same way SwarmPanel's Lua backend
-- now renders SwarmPanel directly -- see src/static.lua. Registered after
-- every /api/* route so nothing here can shadow the ordering-sensitive
-- :media_id-shaped API routes above.
static.register()
httpd.fallback_handler = static.fallback

local ok, err = db.ping()
if ok then
  print(string.format("[nyxframe] Postgres reachable (server time: %s)", tostring(err)))
else
  print("[nyxframe] WARNING: Postgres not reachable at startup: " .. tostring(err))
end

-- The weekly digest is a process-wide singleton (it would otherwise send
-- one duplicate Discord message per worker). Now that this backend can run
-- as multiple worker processes behind proxy.lua (see that file's header
-- comment), only the worker whose GALLERY_HTTP_PORT matches
-- GALLERY_PRIMARY_WORKER_PORT (or the single-worker deployment, where this
-- is simply unset) starts it. Sub-worker instances still serve HTTP
-- requests normally -- this only skips the background singleton job.
local primary_port = tonumber(os.getenv("GALLERY_PRIMARY_WORKER_PORT"))
local is_primary_worker = not primary_port or primary_port == settings.port

-- Weekly per-creator Discord stats digest (see lua/src/digest.lua) -- runs
-- as a copas background coroutine within this same event loop.
local digest = require("digest")
if is_primary_worker then digest.start(settings) end

-- Background media warmer (see routes.lua's "Background media warmer"
-- section) -- proactively pre-transcodes every video's quality renditions
-- so a viewer's first request for a given quality is already cached. Same
-- primary-worker gate as telegram/digest above: every worker shares the
-- same on-disk cache, so running this in both would just have them race
-- each other for no benefit, not corrupt anything.
-- BUGFIX 2026-08-26: this had no off switch at all -- confirmed live on the
-- shared host this runs on: the warmer's ffmpeg jobs (nice 19/ionice as they
-- are) sustained 6-7 of the host's 8 cores for hours, pushed load average to
-- 37-54 and the system deep into swap, and starved an unrelated Discord
-- voice-bot swarm on the same box of the CPU/scheduling headroom real-time
-- audio needs -- manifesting as chronic voice disconnects with zero actual
-- network fault. On-demand transcoding (a viewer actually requesting a
-- quality) is untouched by this flag -- ensure_video_quality_cache/
-- ensure_hls_variant still run from the live request path either way; this
-- only gates the proactive whole-library sweep.
local warmer_enabled = (os.getenv("GALLERY_ENABLE_MEDIA_WARMER") or "true"):lower()
warmer_enabled = warmer_enabled == "true" or warmer_enabled == "1" or warmer_enabled == "yes"
if is_primary_worker and warmer_enabled then routes.start_media_warmer() end

-- Background stale-transcode cleanup (see routes.lua's "Sweeps _video_cache/
-- _hls_cache/_upload_tmp" section) -- periodically removes partial-encode
-- leftovers from ffmpeg jobs that died mid-run (crash, OOM-kill, a
-- restart landing mid-transcode) rather than letting them accumulate
-- forever. Same primary-worker gate and its own off-switch, same
-- reasoning as the warmer above -- a stray background loop on this box
-- has bitten this deployment hard enough once already (2026-08-26) to be
-- worth an escape hatch on every new one by default.
local transcode_cleanup_enabled = (os.getenv("GALLERY_ENABLE_TRANSCODE_CLEANUP") or "true"):lower()
transcode_cleanup_enabled = transcode_cleanup_enabled == "true" or transcode_cleanup_enabled == "1" or transcode_cleanup_enabled == "yes"
if is_primary_worker and transcode_cleanup_enabled then routes.start_stale_transcode_cleanup() end

-- HLS idle-transcode reaper (see routes.lua's M.start_hls_idle_reaper) --
-- SIGTERMs an in-progress HLS transcode once the viewer who triggered it
-- has gone quiet for 25s+, freeing one of only 2 global concurrency slots
-- instead of leaving it running (up to ~10 minutes) for nobody. Same
-- primary-worker gate and off-switch convention as the two above.
local hls_idle_reaper_enabled = (os.getenv("GALLERY_ENABLE_HLS_IDLE_REAPER") or "true"):lower()
hls_idle_reaper_enabled = hls_idle_reaper_enabled == "true" or hls_idle_reaper_enabled == "1" or hls_idle_reaper_enabled == "yes"
if is_primary_worker and hls_idle_reaper_enabled then routes.start_hls_idle_reaper() end

-- Telemetry retention pruner (see telemetry.lua's M.start_pruner) -- same
-- primary-worker gate as every other background loop above: every worker
-- would otherwise DELETE against the same shared telemetry_events table on
-- its own timer, which is harmless but pointlessly redundant.
if is_primary_worker then telemetry.start_pruner() end

-- Permanent deletion of long-soft-deleted media (see routes.lua's
-- M.start_deleted_media_purge doc comment) -- a user asked live 2026-09-14
-- how long a deleted post stays recoverable; the honest answer until now
-- was "forever". Same primary-worker gate as every background loop above.
-- Unlike the others, this one's off-switch guards a genuinely irreversible
-- action (hard-deletes the row and its file), not just a CPU-cost one --
-- settings.deleted_media_purge_enabled defaults to true (config.lua).
if is_primary_worker and settings.deleted_media_purge_enabled then routes.start_deleted_media_purge() end

-- Cache-orphan sweep for _video_cache/_original_cache/_hls_cache entries a
-- content change superseded (see routes.lua's M.start_cache_orphan_sweep
-- doc comment) -- found live 2026-10-11 reclaiming GBs from _hls_cache,
-- which previously had no cleanup path of any kind. Same primary-worker
-- gate and off-switch convention as every background loop above.
if is_primary_worker and settings.cache_orphan_sweep_enabled then routes.start_cache_orphan_sweep() end

-- Ephemeral/"stories" post expiry sweep (see routes.lua's
-- M.start_media_expiry_sweep doc comment). Same primary-worker gate and
-- off-switch convention as every background loop above.
if is_primary_worker and settings.media_expiry_sweep_enabled then routes.start_media_expiry_sweep() end

-- One-shot video-thumbnail backfill for uploads that predate
-- prewarm_video_thumb (see routes.lua's M.start_thumb_backfill_sweep doc
-- comment -- this is what drains the backlog that caused 2026-10-11's
-- 20-100s request stalls). Same primary-worker gate and off-switch
-- convention as every background loop above.
if is_primary_worker and settings.thumb_backfill_sweep_enabled then routes.start_thumb_backfill_sweep() end

-- Image rendition warmer (see routes.lua's M.start_image_rendition_warmer):
-- pre-renders grid/lightbox/detail sizes so nobody waits on a cold render.
-- Same primary-worker gate and off-switch convention as the loops above.
local image_warmer_enabled = (os.getenv("GALLERY_ENABLE_IMAGE_WARMER") or "true"):lower()
image_warmer_enabled = image_warmer_enabled == "true" or image_warmer_enabled == "1" or image_warmer_enabled == "yes"
if is_primary_worker and image_warmer_enabled then routes.start_image_rendition_warmer() end

-- Upload storage (see routes.lua's upload hand-off section): every worker
-- turns on the fast-disk tier (if GALLERY_HOT_DIR is set) and records its
-- boot id; the primary resumes upload jobs whose worker restarted and
-- keeps the fast tier under its size cap.
routes.configure_storage()
if is_primary_worker then
  routes.start_upload_job_recovery()
  routes.start_hot_tier_mover()
end

httpd.listen(settings.host, settings.port)
print(string.format("[nyxframe] listening on %s:%d", settings.host, settings.port))
httpd.run()
