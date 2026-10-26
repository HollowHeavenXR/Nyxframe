-- Settings loader. Mirrors app/config.py's fallback chains (GALLERY_DB_HOST ->
-- DB_HOST -> MYSQL_HOST etc.) closely enough to work from the same .env file
-- image_gallery already uses, loaded into the container's environment via
-- docker-compose's `env_file: ../Image Gallery/.env` (unchanged from the
-- Python deployment) -- this module never reads .env itself, only
-- os.getenv(), matching how the container actually receives config.
--
-- KEY DIFFERENCE FROM app/config.py: db_port here defaults to 5432 (Postgres),
-- not 3306 (MariaDB) -- the .env file's GALLERY_DB_PORT=3306 is a leftover
-- from the still-live MariaDB config and MUST be overridden to 5432 for this
-- Lua backend via docker-compose (see final report: exact env var to add/
-- change). If GALLERY_DB_PORT is left at 3306 this backend will fail to
-- connect (Postgres does not speak the MySQL wire protocol on that port).

local function env(name, default)
  local v = os.getenv(name)
  if v == nil or v == "" then return default end
  return v
end

local function env_int(name, default)
  local v = os.getenv(name)
  if v == nil or v == "" then return default end
  return tonumber(v) or default
end

local function env_bool(name, default)
  local v = os.getenv(name)
  if v == nil or v == "" then return default end
  v = v:lower()
  return v == "1" or v == "true" or v == "yes" or v == "on"
end

local function env_csv(name)
  local raw = env(name, "")
  local out = {}
  for item in raw:gmatch("[^,]+") do
    local trimmed = item:match("^%s*(.-)%s*$")
    if trimmed ~= "" then out[#out + 1] = trimmed end
  end
  return out
end

local M = {}

function M.load()
  local db_host = env("GALLERY_DB_HOST") or env("DB_HOST") or env("MYSQL_HOST") or "127.0.0.1"
  return {
    db_host = db_host,
    -- NOTE: intentionally 5432 default (Postgres), unlike Python's 3306 default.
    db_port = env_int("GALLERY_PG_PORT", env_int("GALLERY_DB_PORT_PG", 5432)),
    db_user = env("GALLERY_DB_USER") or env("DB_USER") or env("MYSQL_USER") or "botuser",
    db_password = env("GALLERY_DB_PASSWORD") or env("DB_PASSWORD") or env("MYSQL_PASSWORD") or "bot_logins",
    db_name = env("GALLERY_DB_SCHEMA", "image_gallery"),
    -- The shared Postgres instance behind this (see the Aria/SwarmPanel
    -- migration notes) already runs ~90/150 max_connections across every
    -- Music bot (~6 each), SwarmPanel, and Aria -- 6 here keeps this
    -- backend consistent with that sibling convention rather than either
    -- starving itself (1 connection serializes ALL concurrent DB-bound
    -- requests through one socket -- see db.lua's pool) or eating into the
    -- cluster-wide budget more than its neighbors do.
    db_pool_size = math.max(1, env_int("GALLERY_DB_POOL_SIZE", 6)),

    session_secret = env("GALLERY_SESSION_SECRET", ""),
    api_token_ttl_seconds = env_int("GALLERY_API_TOKEN_TTL_SECONDS", 1209600),

    cors_allowed_origins = env_csv("GALLERY_CORS_ALLOWED_ORIGINS"),
    cors_allow_origin_regex = env("GALLERY_CORS_ALLOW_ORIGIN_REGEX", ""),
    trusted_hosts = env_csv("GALLERY_TRUSTED_HOSTS"),
    -- CIDR allow-list (comma-separated, e.g. "127.0.0.0/8,::1/128") for the
    -- ONLY peers httpd.lua will trust an incoming X-Forwarded-For header
    -- from -- everyone else's XFF is ignored and the raw TCP peer address is
    -- used instead. Was defined in .env/.env.example from the start but
    -- never actually read anywhere in this Lua backend (config.lua had no
    -- field for it) -- meaning ANY visitor could set X-Forwarded-For to
    -- whatever they liked and httpd.lua trusted it unconditionally, which
    -- silently defeated every IP-keyed rate limit (registration, login
    -- lockout, download-batch) since an attacker could just roll the header
    -- to reset their own bucket on every request. See httpd.lua's
    -- ip_in_trusted_cidrs()/client IP resolution.
    trusted_proxy_cidrs = env_csv("GALLERY_TRUSTED_PROXY_CIDRS"),
    pages_public_url = env("GALLERY_PAGES_PUBLIC_URL", "https://heavenlyxenusvr.github.io/Nyxframe/"),
    -- Backend's own public origin (the cloudflared tunnel target, same value
    -- start_live_tunnel_service.sh already reads from .env) -- used by
    -- digest.lua's background loop to build absolute thumb URLs with no real
    -- HTTP req to derive request_origin() from.
    public_origin = env("GALLERY_CLOUDFLARE_PUBLIC_URL", "http://localhost:" .. tostring(env_int("GALLERY_HTTP_PORT", 8788))),

    -- Weekly Discord stats digest: day-of-week (os.date("!*t").wday: 1=Sun
    -- .. 7=Sat) and hour (UTC) after which the loop is allowed to send. The
    -- loop wakes every 6h, so this is a ">=" gate, not an exact match --
    -- idempotency (at most one send per creator per week) comes from the
    -- digest_sends marker table, not from hitting this hour precisely.
    digest_send_weekday = env_int("GALLERY_DIGEST_SEND_WEEKDAY", 2),
    digest_send_hour = env_int("GALLERY_DIGEST_SEND_HOUR", 15),

    -- Python defaults this to ROOT_DIR/uploads (the project root that
    -- contains app/, one level above app/config.py). This Lua backend's cwd
    -- at runtime is lua/ (see main.lua's package.path setup and the
    -- Dockerfile's WORKDIR /app, which COPYs the *contents* of lua/), so the
    -- equivalent default is "../uploads" -- the sibling uploads/ directory
    -- at the project root. In a container deployment this directory must be
    -- bind-mounted (same requirement the Python backend already has) and
    -- GALLERY_UPLOADS_DIR pointed at wherever it's mounted.
    uploads_dir = env("GALLERY_UPLOADS_DIR", "../uploads"):gsub("/+$", ""),
    -- Fast-disk tier (2026-10-26). When set (a directory on fast internal
    -- storage), uploads are received and processed under <hot_dir>/staging
    -- and new originals are stored under <hot_dir>/media/... with the same
    -- relative layout as uploads_dir. Lookups check hot_dir first, then
    -- uploads_dir; a background mover shifts the oldest originals to
    -- uploads_dir once hot_dir's media passes hot_max_gb. Empty = off
    -- (everything stays in uploads_dir, as before).
    hot_dir = env("GALLERY_HOT_DIR", ""):gsub("/+$", ""),
    hot_max_gb = math.max(1, env_int("GALLERY_HOT_MAX_GB", 25)),
    hot_min_free_gb = math.max(1, env_int("GALLERY_HOT_MIN_FREE_GB", 15)),
    storage_backend = env("GALLERY_STORAGE_BACKEND", "database"),
    max_upload_bytes = env_int("GALLERY_MAX_UPLOAD_BYTES", 3 * 1024 * 1024 * 1024),
    upload_rate_limit_per_hour = math.max(1, env_int("GALLERY_UPLOAD_RATE_LIMIT_PER_HOUR", 60)),
    analyze_rate_limit_per_hour = math.max(1, env_int("GALLERY_ANALYZE_RATE_LIMIT_PER_HOUR", 120)),
    db_blob_chunk_bytes = math.max(1024 * 1024, math.min(env_int("GALLERY_DB_BLOB_CHUNK_BYTES", 8 * 1024 * 1024), 16 * 1024 * 1024)),
    media_page_limit = math.max(1, math.min(200, env_int("GALLERY_MEDIA_PAGE_LIMIT", 100))),
    max_tags_per_upload = math.max(1, math.min(50, env_int("GALLERY_MAX_TAGS_PER_UPLOAD", 12))),
    max_tag_length = math.max(8, math.min(80, env_int("GALLERY_MAX_TAG_LENGTH", 32))),
    visual_phash_max_distance = env_int("GALLERY_VISUAL_PHASH_MAX_DISTANCE", 10),
    visual_dhash_max_distance = env_int("GALLERY_VISUAL_DHASH_MAX_DISTANCE", 14),
    -- Bounds the opt-in site-wide duplicate check (find_possible_duplicates
    -- scope="site") to recent uploads only -- without this, "site-wide" would
    -- just mean "the 1500 newest uploads from anyone," which misses older
    -- duplicates and isn't meaningfully related to fingerprint similarity.
    dedup_scan_window_days = env_int("GALLERY_DEDUP_SCAN_WINDOW_DAYS", 90),

    host = env("GALLERY_HTTP_HOST", "0.0.0.0"),
    port = env_int("GALLERY_HTTP_PORT", 8788),

    db_schema = env("GALLERY_DB_SCHEMA", "image_gallery"),

    -- AI vision config. ai_metadata.lua implements the heuristic analyzer,
    -- domain-hint text matcher, and a real Gemini vision call; Ollama/
    -- OpenAI-compatible vision and the local CLIP classifier are NOT
    -- ported (see that file's header comment).
    ai_enabled = env_bool("GALLERY_AI_ENABLED", (env("GALLERY_AI_API_KEY") or env("OPENAI_API_KEY") or env("GALLERY_GEMINI_API_KEY") or env("GALLERY_OLLAMA_MODEL")) ~= nil),
    ai_provider = env("GALLERY_AI_PROVIDER", (env("GALLERY_AI_API_KEY") or env("OPENAI_API_KEY")) and "openai" or "ollama"),
    ai_api_key = env("GALLERY_AI_API_KEY") or env("OPENAI_API_KEY") or env("GALLERY_GEMINI_API_KEY") or "",
    ai_base_url = (env("GALLERY_AI_BASE_URL") or env("OPENAI_BASE_URL") or "https://api.openai.com/v1"):gsub("/+$", ""),
    ai_ollama_base_url = env("GALLERY_OLLAMA_BASE_URL", "http://127.0.0.1:11434"),
    ai_model = env("GALLERY_GEMINI_MODEL") or env("GEMINI_MODEL") or env("GALLERY_AI_MODEL", "gpt-4o-mini"),
    ai_ollama_model = env("GALLERY_OLLAMA_MODEL", "llava"),
    ai_timeout_seconds = env_int("GALLERY_AI_TIMEOUT_SECONDS", 45),

    -- Discord bot token for DM-based account verification (discord_bot.lua)
    -- -- distinct from the per-creator discord_webhook_url setting (that's
    -- outbound-only, to a channel; this is a real bot that can open a DM
    -- with any user who shares a server with it). Blank by default: every
    -- discord_bot.lua call gracefully no-ops/reports "not configured yet"
    -- until this is set.
    discord_bot_token = env("GALLERY_DISCORD_BOT_TOKEN", ""),
    ai_training_examples_limit = math.max(0, math.min(1000, env_int("GALLERY_AI_TRAINING_EXAMPLES_LIMIT", 300))),

    -- lua/src/telemetry.lua: durable telemetry_events rows (uploads, auth,
    -- background-job outcomes, media diagnostics) plus in-memory request/job
    -- stats surfaced at GET /api/admin/telemetry. Retention is enforced by a
    -- background pruner (see telemetry.lua's M.start_pruner), not by this
    -- config value directly.
    telemetry_enabled = env_bool("GALLERY_TELEMETRY_ENABLED", true),
    telemetry_retention_days = math.max(1, env_int("GALLERY_TELEMETRY_RETENTION_DAYS", 14)),

    -- routes.lua's M.start_deleted_media_purge: how long a soft-deleted
    -- post (delete_media only ever sets deleted_at, never removes the row)
    -- stays recoverable via restore_media before a daily sweep hard-deletes
    -- it and its file for good. Kill-switch matches the warmer/cleanup/
    -- reaper convention elsewhere in main.lua -- this one guards a genuinely
    -- irreversible action, not just a CPU-cost one.
    deleted_media_retention_days = math.max(1, env_int("GALLERY_DELETED_MEDIA_RETENTION_DAYS", 10)),
    deleted_media_purge_enabled = env_bool("GALLERY_ENABLE_DELETED_MEDIA_PURGE", true),

    -- routes.lua's M.start_cache_orphan_sweep: reclaims _video_cache/
    -- _original_cache/_hls_cache entries left behind when a content change
    -- (re-upload/edit) supersedes their digest key -- see that function's
    -- header comment. Same kill-switch convention as every other
    -- background loop above.
    cache_orphan_sweep_enabled = env_bool("GALLERY_ENABLE_CACHE_ORPHAN_SWEEP", true),

    -- routes.lua's M.start_media_expiry_sweep: auto-expires ephemeral/
    -- "stories" posts (finalize_upload's `expires_in_hours` option) by
    -- soft-deleting them once expires_at passes. Same kill-switch
    -- convention as every other background loop above.
    media_expiry_sweep_enabled = env_bool("GALLERY_ENABLE_MEDIA_EXPIRY_SWEEP", true),

    -- routes.lua's M.start_thumb_backfill_sweep: one-shot startup walk that
    -- prewarms thumbnails for videos uploaded before prewarm_video_thumb
    -- existed, throttled to one every 4s so draining the backlog can't
    -- itself reproduce the cache-miss-burst stall it exists to prevent.
    -- Same kill-switch convention as every other background loop above.
    thumb_backfill_sweep_enabled = env_bool("GALLERY_ENABLE_THUMB_BACKFILL_SWEEP", true),
  }
end

return M
