-- Route handlers. Registered against httpd.lua's M.route(method, pattern, handler)
-- in main.lua. Each handler receives httpd.lua's `req` table and returns
-- (status, body_table_or_string, extra_headers).
--
-- Scope note (last updated 2026-08-10): this comment badly lagged reality
-- for a long time -- AI classification, Telegram, possible-duplicate
-- detection, saved-search notifications, and the admin storage/orphan-purge
-- endpoints were all already implemented below despite previously being
-- listed here as "NOT ported." Current real gaps, confirmed by actually
-- grepping for them rather than trusting this comment:
--   * Email verification/change (POST /api/me/email, /api/me/email/verify)
--     -- called by SettingsPage.jsx but never built, not even in the
--     original Python backend. Needs an email-sending decision (SMTP
--     provider) before it can be built; deliberately not guessed at.
--     Discord-based account verification (routes below, "Discord account
--     verification" section) covers the same "prove you own this account"
--     need without that dependency.
--   * Background AI learning (the periodic pass that turned curated
--     gallery metadata into new training examples) and the Ollama/
--     OpenAI-compatible vision provider backends (only Gemini is wired) --
--     both background-only, no user-facing surface; see TODO.md.

local cjson = require("cjson.safe")
local db = require("db")
-- Bare global, not `local` -- this file is already at LuaJIT's hard
-- 200-local-per-chunk ceiling (see the file's existing notes on this, e.g.
-- range_io/acquire_transcode_slot), so a new top-level local here simply
-- fails to compile. webpush.lua itself has no require("routes") anywhere
-- (it's a leaf module, see its own header comment), so there's no cycle to
-- avoid either way -- this could be a real local in a file with headroom.
webpush = require("webpush")
local gauth = require("gallery_auth")
local ratelimit = require("ratelimit")
local totp = require("totp")
local media_files = require("media_files")
local user_settings = require("user_settings")
local gallery_looks = require("gallery_looks")
local colorutil = require("colorutil")
local discord_webhook = require("discord_webhook")
local discord_bot = require("discord_bot")
local auth_lib = require("auth")
local ai_metadata = require("ai_metadata")

-- Attaches computed accent_contrast_text/accent_gradient onto a decoded
-- user's user_settings table, mirroring SwarmPanel's with_derived_accent.
-- Frontend no longer has to guess at readable text color for a user's
-- chosen accent, and always gets a sensible gradient partner even if
-- accent_secondary was never set.
local function with_derived_accent(user)
  if not user or type(user.user_settings) ~= "table" then return user end
  local accent = user.user_settings.accent_color
  if not accent or accent == "" then return user end
  local secondary = user.user_settings.accent_secondary
  if not secondary or secondary == "" then secondary = colorutil.auto_secondary(accent) end
  user.user_settings.accent_contrast_text = colorutil.contrast_text(accent)
  user.user_settings.accent_gradient = colorutil.gradient(accent, secondary)
  return user
end

-- This LuaJIT build has no table.unpack (only the global unpack()) -- same
-- shim already documented and applied in lib/swarmlua/pg.lua; needed again
-- here since list_media() below builds its parameter list dynamically.
local unpack = table.unpack or unpack

-- Forward declarations: verify_2fa (defined early, near the other auth
-- handlers, to match main.lua's route-registration reading order) calls
-- this, but its real implementation lives down in the TOTP section below
-- alongside the rest of the 2FA enroll/confirm/disable code it belongs with.
local verify_totp_or_recovery

-- Same forward-declaration need as verify_totp_or_recovery above: register/
-- login/verify_2fa/me/update_profile/update_settings/update_avatar/
-- verify_age/discord_link/discord_unlink all need to run avatar_url (and
-- site_owner) shaping on the user object they hand back to the client, but
-- with_user_urls' real definition (and request_origin, which it calls) live
-- much further down, near the other user-row-shaping helpers they were
-- ported alongside. Without this, none of those self-account endpoints ever
-- set avatar_url on the returned user -- which is why a freshly uploaded
-- avatar (or any avatar at all) never rendered in the navbar or Settings:
-- Avatar (ui.jsx) reads user.avatar_url, and every one of those endpoints
-- was returning the row with avatar_path but no avatar_url computed from it.
local request_origin
local with_user_urls

local M = {}
M.settings = nil -- set by main.lua
-- A field on the already-declared M local, not a new top-level local -- this
-- file's main chunk is already at LuaJIT's 200-local ceiling (see the
-- range_io/transcode comments further down), so `local telemetry =
-- require(...)` here would overflow it. Every instrumentation call below
-- goes through M.telemetry.* instead of a bare local.
M.telemetry = require("telemetry")

local function json_body(req)
  if req.json and next(req.json) ~= nil then return req.json end
  if req.raw_body and req.raw_body ~= "" then
    local decoded = cjson.decode(req.raw_body)
    if decoded then return decoded end
  end
  return {}
end

-- Normalizes cjson.null and Lua nil to Lua nil so `value or default` fallback
-- patterns are safe everywhere in this file (cjson's null sentinel is a
-- non-nil, non-false lightuserdata that defeats `or` otherwise).
local function nn(v)
  if v == nil or v == cjson.null then return nil end
  return v
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Watermarking is disabled site-wide (see the `watermark_text = nil --
-- WATERMARKS_ENABLED = false` sites below): the drawtext/overlay burn-in
-- it required forced a full re-encode on media that would otherwise be
-- served as-is (or from an existing cached rendition), which was
-- saturating CPU/GPU on transcodes. Every such site is hardcoded to nil
-- rather than routed through a shared helper because routes.lua's main
-- chunk is already at LuaJIT's 200-local ceiling and a new top-level
-- local (even a function) overflows it.

-- cjson can't tell an empty Lua table `{}` was meant as a JSON array `[]`
-- vs object `{}` and defaults to encoding it as `{}`  -- wrong for every
-- list-shaped API field here (media, subcategories, ...) whenever the list
-- happens to be empty, which silently breaks any frontend code that expects
-- to .map()/.forEach() the field. Use this for every such field instead of
-- a bare `{}`/`t`.
local function arr(t)
  if t == nil or next(t) == nil then return cjson.empty_array end
  return t
end

local function client_ip(req)
  return req.client_ip or "unknown"
end

-- ---------------------------------------------------------------------------
-- User row shaping (mirrors app/routers/_shared.py's _jsonable + the column
-- list app/db/account.py's get_user() selects).
-- ---------------------------------------------------------------------------

local USER_PUBLIC_COLUMNS = [[
  id, username, display_name, bio, website_url, location_label, profile_headline,
  featured_tags, profile_color,
  email, email_verified_at, avatar_path, avatar_file_id, avatar_mime_type, avatar_original_filename, public_profile,
  show_liked_count, show_collections, show_recent_uploads, show_friends,
  birthdate, age_verified_at, adult_content_consent, totp_enabled_at,
  discord_user_id, discord_username, discord_verified_at,
  user_settings, created_at, updated_at, last_seen_at,
  banned_at, banned_until, ban_reason
]]

local function decode_user(row)
  if not row then return nil end
  row.id = db.toint(row.id, row.id)
  if row.avatar_file_id then row.avatar_file_id = db.toint(row.avatar_file_id, row.avatar_file_id) end
  row.public_profile = db.tobool(row.public_profile)
  row.show_liked_count = db.tobool(row.show_liked_count)
  row.show_collections = db.tobool(row.show_collections)
  row.show_recent_uploads = db.tobool(row.show_recent_uploads)
  row.show_friends = db.tobool(row.show_friends)
  row.adult_content_consent = db.tobool(row.adult_content_consent)
  row.totp_enabled = row.totp_enabled_at ~= nil and row.totp_enabled_at ~= cjson.null
  -- arr(), not a bare `{}` fallback: cjson.encode(empty_lua_table) always
  -- serializes as a JSON object ({}), never an array ([]) -- confirmed
  -- directly (luajit -e "print(cjson.encode({}))" prints "{}"), since Lua
  -- has no distinct empty-array type for it to infer from. Any user with no
  -- featured tags (the common case) was sending featured_tags as a JSON
  -- OBJECT instead of an array, which is a strict decode failure for any
  -- client expecting an array (iOS's GalleryUser.featuredTags: [String]?
  -- throws on `{}` instead of decoding an empty list) -- and since
  -- GalleryUser is embedded in most social endpoints (profiles, followers/
  -- following, friends, blocks, search, group members), one such user
  -- anywhere in a list response corrupted the whole response's decode.
  if row.featured_tags and row.featured_tags ~= cjson.null then
    local ok, decoded = pcall(cjson.decode, row.featured_tags)
    row.featured_tags = (ok and type(decoded) == "table") and arr(decoded) or arr({})
  else
    row.featured_tags = arr({})
  end
  if row.user_settings and row.user_settings ~= cjson.null then
    row.user_settings = cjson.decode(row.user_settings) or {}
  else
    row.user_settings = {}
  end
  return row
end

-- get_user() is called 2+ times on nearly every authenticated request
-- (current_user, viewer_adult_allowed in every list endpoint, etc.) -- a
-- short-TTL in-process cache cuts that to one Postgres round trip per user
-- per TTL window instead of one per request, which matters once concurrent
-- request volume climbs (this DB is shared cluster-wide with the Discord
-- bot fleet/SwarmPanel/Aria -- see config.lua's pool-size comment). ONE
-- table (not two top-level locals) purely to stay under this file's
-- 200-local ceiling, same convention as the `transcode` table elsewhere.
--
-- Staleness risk: a few seconds of an out-of-date age_verified_at/
-- adult_content_consent/display_name/etc is no worse than the race that
-- already exists between any read and the response reaching the client.
-- The one case that DOES matter -- a request that updates its own user row
-- and then immediately re-reads it to build the response ("refreshed =
-- get_user(user.id)", 8 call sites: register/login's last_seen touch,
-- profile/settings updates, avatar upload, age verification, Discord
-- verify/unverify) -- is handled by explicit invalidation at each of those
-- sites instead of relying on the TTL alone, so a just-verified user's
-- own response always reflects the write they just made.
local user_cache = { entries = {}, ttl_seconds = 5, max_entries = 500 }

function user_cache.deep_copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = user_cache.deep_copy(v) end
  return out
end

function user_cache.invalidate(user_id)
  user_cache.entries[tostring(user_id)] = nil
end

local function get_user(user_id)
  local key = tostring(user_id)
  local now = os.time()
  local cached = user_cache.entries[key]
  if cached and (now - cached.at) < user_cache.ttl_seconds then
    -- A copy, not the stored reference: several callers add/overwrite
    -- fields on the table get_user() returns (e.g. M.me's
    -- `user.site_owner = is_site_owner(user)`, with_derived_accent's
    -- `user.user_settings.accent_gradient = ...`) -- handing out the same
    -- object to every caller within the TTL window would let one
    -- caller's addition leak into another's, so decode_user's output gets
    -- copied (deeply, since user_settings/featured_tags are nested tables
    -- some callers mutate in place too) on every read, hit or miss.
    return user_cache.deep_copy(cached.user)
  end

  local row = db.fetchone("SELECT " .. USER_PUBLIC_COLUMNS .. " FROM users WHERE id=%s", user_id)
  local decoded = decode_user(row)
  if decoded then
    -- Defensive cap, same ceiling-and-prune idea as ratelimit_mem.lua's
    -- BUCKETS_MAX: unlikely to matter at this site's scale (distinct user
    -- ids are bounded by real accounts, not attacker-controlled like an
    -- IP-keyed bucket), but cheap insurance against unbounded growth.
    local count = 0
    for _ in pairs(user_cache.entries) do count = count + 1 end
    if count >= user_cache.max_entries then
      for k, v in pairs(user_cache.entries) do
        if (now - v.at) >= user_cache.ttl_seconds then user_cache.entries[k] = nil end
      end
    end
    user_cache.entries[key] = { at = now, user = decoded }
  end
  return decoded and user_cache.deep_copy(decoded) or nil
end

-- Must exactly match the real account's stored `email` column (case-
-- insensitively, see is_site_owner() below) AND that account needs
-- email_verified_at set, or the site-owner gate silently denies everyone,
-- including the real owner -- confirmed happening in production
-- (2026-08-02): this constant didn't match the live account's actual
-- stored email, and email_verified_at was NULL, so /admin and every
-- existing admin_* API endpoint had never actually been reachable.
local SITE_OWNER_EMAIL = "uxzheavenlyyei@icloud.com"

local function is_site_owner(user)
  return user and nn(user.email_verified_at) ~= nil and tostring(user.email or ""):lower() == SITE_OWNER_EMAIL
end

local function is_actively_banned(user)
  if not user or nn(user.banned_at) == nil then return false end
  local until_ts = nn(user.banned_until)
  if not until_ts then return true end
  -- Postgres returns timestamps as "YYYY-MM-DD HH:MM:SS[.ffffff]" text; ISO-
  -- 8601 lexical order matches chronological order for this fixed format, so
  -- a plain string compare against a same-format "now" string is sufficient
  -- and avoids needing a date-parsing library for this check.
  local now_row = db.fetchone("SELECT to_char(now(), 'YYYY-MM-DD HH24:MI:SS') AS now")
  return now_row and tostring(until_ts) > now_row.now
end

local function parse_cookies(req)
  local cookie_header = req.headers["cookie"] or ""
  local cookies = {}
  for k, v in cookie_header:gmatch("([%w_%-]+)=([^;]+)") do cookies[k] = v end
  return cookies
end

-- is_online (see the profile/list queries further down: "now() -
-- last_seen_at <= interval '180 seconds'") was previously only ever true
-- for the ~3 minutes right after logging IN -- last_seen_at had exactly
-- one writer in the whole codebase, the login route itself, so an account
-- actively browsing for hours showed as offline the entire time. Called
-- from both current_user() (every mutating/write request) and
-- auth_optional() (every read-context request -- feed, media, profile,
-- ~20 call sites), so any authenticated activity keeps the account
-- looking online, not just logging in. Same staleness-throttle pattern as
-- api_keys.last_used_at above: at most one write per account per minute,
-- not one per request.
local function touch_last_seen(user_id)
  if not user_id then return end
  db.execute(
    "UPDATE users SET last_seen_at=now() WHERE id=%s AND (last_seen_at IS NULL OR last_seen_at < now() - interval '60 seconds')",
    tostring(user_id)
  )
end

-- Depends()-equivalent: returns (user, auth_payload) or (nil, nil, status, body)
-- on failure. auth_payload is the decoded token {id, username, display_name}.
local function current_user(req)
  local auth = gauth.require_auth(req.headers, parse_cookies(req), M.settings.session_secret, M.settings.api_token_ttl_seconds)
  if not auth and req.method == "GET" then
    -- Scoped read-only API keys (see M.resolve_api_key/auth_optional
    -- further down this file) may satisfy any READ request that would
    -- otherwise need a real login -- Studio, Settings, Messages, Friends,
    -- Admin dashboards, etc. -- so the account owner (or a tool acting on
    -- their explicit behalf) can view their own logged-in UI for layout/
    -- rendering checks without a real session. Gated strictly on GET: a
    -- POST/PUT/PATCH/DELETE mutation never reaches this fallback, so a
    -- key can make pages RENDER as logged in but can never actually
    -- save/delete/upload/admin-act as the user.
    local key = req.query and nn(req.query.key)
    if key then
      local user_id = M.resolve_api_key(key)
      if user_id then auth = { id = user_id } end
    end
  end
  if not auth then return nil, nil, 401, { detail = "Login required" } end
  local user = get_user(auth.id)
  if is_actively_banned(user) then
    return nil, nil, 403, { detail = (user and nn(user.ban_reason)) or "Your account has been suspended." }
  end
  touch_last_seen(auth.id)
  return user, auth, nil, nil
end

-- Exported for pages_totp.lua's server-rendered 2FA settings page -- same
-- cookie-or-bearer login check as current_user(), just reshaped to
-- (user, status, body) since callers here don't need the raw auth payload.
function M.require_login_for_page(req)
  local user, auth, status, body = current_user(req)
  return user, status, body
end

-- Falls back to a `?key=gk_...` scoped API key (see M.resolve_api_key
-- further down this file) when there's no session cookie/bearer token.
-- Deliberately only wired in here, not into current_user()/require_auth():
-- every one of auth_optional's ~20 call sites is a GET/read-context route
-- (listing, detail, media-serving, profile/follow lists) that uses the
-- resolved viewer id purely to decide what's visible to them -- nothing
-- that calls auth_optional ever performs a mutation, so a key can only
-- ever see what its owning account could already see, never act as it.
-- Mutating routes all authenticate via current_user()/gauth.require_auth
-- directly and remain cookie/bearer-only.
local function auth_optional(req)
  local auth = gauth.require_auth(req.headers, parse_cookies(req), M.settings.session_secret, M.settings.api_token_ttl_seconds)
  if auth then
    touch_last_seen(auth.id)
    return auth
  end
  local key = req.query and nn(req.query.key)
  if not key then return nil end
  local user_id = M.resolve_api_key(key)
  if not user_id then return nil end
  touch_last_seen(user_id)
  return { id = user_id }
end

-- ---------------------------------------------------------------------------
-- Health / live checks
-- ---------------------------------------------------------------------------

function M.health(req)
  return 200, {
    ok = true,
    schema = M.settings.db_schema,
    storage_backend = M.settings.storage_backend,
    max_upload_bytes = M.settings.max_upload_bytes,
    media_page_limit = M.settings.media_page_limit,
    max_tags_per_upload = M.settings.max_tags_per_upload,
    request_id = req.headers["x-request-id"] or "",
    server_time = os.date("!%Y-%m-%dT%H:%M:%S") .. "Z",
  }
end

function M.live_checks(req)
  local checks = {}
  local ok, err = db.ping()
  if not ok then
    return 200, {
      ok = false,
      status = "offline",
      backend = "image_gallery",
      checks = { { id = "db", label = "Database reachable", ok = false, severity = "error", detail = "Database is unreachable." } },
      check_map = { api = true, db = false },
      snapshot = cjson.empty_array or {},
      storage_backend = M.settings.storage_backend,
      max_upload_bytes = M.settings.max_upload_bytes,
      media_page_limit = M.settings.media_page_limit,
      server_time = os.date("!%Y-%m-%dT%H:%M:%S") .. "Z",
    }
  end
  checks[#checks + 1] = { id = "api", label = "API reachable", ok = true, detail = "Backend responded." }
  checks[#checks + 1] = { id = "db", label = "Database reachable", ok = true, detail = "Schema " .. M.settings.db_schema .. " responded." }
  local auth = auth_optional(req)
  if auth then
    local user = get_user(auth.id)
    checks[#checks + 1] = { id = "session", label = "Login session", ok = user ~= nil, detail = user and "Signed in." or "Token is invalid or account is gone." }
  end
  local check_map = {}
  for _, c in ipairs(checks) do check_map[c.id] = c.ok end
  return 200, {
    ok = true,
    status = "ok",
    backend = "image_gallery",
    checks = checks,
    check_map = check_map,
    snapshot = {},
    storage_backend = M.settings.storage_backend,
    max_upload_bytes = M.settings.max_upload_bytes,
    media_page_limit = M.settings.media_page_limit,
    server_time = os.date("!%Y-%m-%dT%H:%M:%S") .. "Z",
  }
end

-- GET /api/status -- public uptime/status page. New feature, 2026-10-11:
-- M.health/M.live_checks already exist but are shaped for the admin ops
-- panel and this project's own tooling (schema name, upload-size limits,
-- a session check) -- nothing before this gave an ordinary visitor a
-- simple "is the site healthy, has anything gone wrong lately" view.
-- Deliberately public (no current_user/require_site_owner check) and
-- narrower than live_checks' payload -- a status page shouldn't leak
-- internal config.
--
-- Incidents are a separate, human-curated table (status_incidents, see
-- pg_add_status_incidents.sql), not a dump of telemetry_events -- an
-- incident is "we know about this, here's what happened," written by the
-- site owner (M.admin_create_incident below), not an automatic event feed.
function M.public_status(req)
  local db_ok = db.ping()
  local incidents = db.fetchall(
    "SELECT id, title, description, severity, started_at, resolved_at FROM status_incidents ORDER BY started_at DESC LIMIT 20"
  ) or {}
  for _, row in ipairs(incidents) do
    row.id = db.toint(row.id, row.id)
    row.resolved = row.resolved_at ~= nil and row.resolved_at ~= cjson.null
  end
  local active_count = 0
  for _, row in ipairs(incidents) do
    if not row.resolved then active_count = active_count + 1 end
  end
  return 200, {
    ok = db_ok and active_count == 0,
    database_reachable = db_ok and true or false,
    active_incident_count = active_count,
    incidents = arr(incidents),
    server_time = os.date("!%Y-%m-%dT%H:%M:%S") .. "Z",
  }
end

-- ---------------------------------------------------------------------------
-- Auth: register / login / logout / me / 2fa verify
-- ---------------------------------------------------------------------------

local function normalize_username(u)
  return trim(u):lower():sub(1, 40)
end

local function normalize_email(e)
  e = trim(e or ""):lower()
  if e == "" then return nil end
  return e:sub(1, 255)
end

function M.register(req)
  local ok429, body429 = ratelimit.check("register:" .. client_ip(req), 10, 3600)
  if ok429 then return ok429, body429 end
  local payload = json_body(req)
  local username = normalize_username(nn(payload.username) or "")
  local password = nn(payload.password) or ""
  local email = normalize_email(nn(payload.email))
  local display_name = trim(nn(payload.display_name) or username):sub(1, 80)
  if display_name == "" then display_name = username end

  -- Character-class + length validation dropped somewhere in the Lua
  -- rewrite -- normalize_username() only trims/lowercases/truncates, so
  -- literally anything (spaces, "/", emoji, ...) was reaching the DB.
  -- Both clients still document and enforce this exact rule client-side
  -- (iOS's RegisterView.swift, web's presumed equivalent) on the
  -- assumption the server does too -- and it's not just cosmetic: username
  -- is placed directly into a URL path segment at GET /api/users/:username
  -- (main.lua), where an unrestricted value (a literal "/" in particular)
  -- would break that route's matching. (pages_og.lua/pages_admin.lua do
  -- already html.esc() every username before rendering it, so this isn't
  -- closing an XSS hole -- just the routing hazard and the client/server
  -- validation-contract mismatch.)
  if username == "" then return 400, { detail = "Username is required." } end
  if #username < 3 then return 400, { detail = "Username must be at least 3 characters." } end
  if not username:match("^[%w_.%-]+$") then
    return 400, { detail = "Username may only contain letters, numbers, \".\", \"_\", and \"-\"." }
  end
  if #password < 8 then return 400, { detail = "Password must be at least 8 characters." } end

  -- LOWER() on both sides here too: an exact-match check would let someone
  -- register "heavenlyxenusvr" today even though "HollowHeavenXR" already
  -- exists (see login's fix above for why case can differ on old
  -- accounts), creating a second, genuinely different account that a
  -- case-insensitive login could then no longer tell apart from the
  -- original. Blocking the collision at registration time is the other
  -- half of actually fixing this for good.
  local existing = db.fetchone("SELECT id FROM users WHERE LOWER(username)=%s OR (LOWER(email)=%s AND email IS NOT NULL)", username, email)
  if existing then return 409, { detail = "That username or email is already taken." } end

  local password_hash = gauth.password_hash(password)
  local row, err = db.fetchone(
    "INSERT INTO users (username, display_name, password_hash, email) VALUES (%s, %s, %s, %s) RETURNING id",
    username, display_name, password_hash, email
  )
  if not row then
    M.telemetry.record("auth", "register", "error", nil, { username = username })
    return 500, { detail = "Registration failed: " .. tostring(err) }
  end
  M.telemetry.record("auth", "register", "success", nil, { username = username })
  user_cache.invalidate(row.id)
  local user = get_user(row.id)
  local token = gauth.issue_token(M.settings.session_secret, user, M.settings.api_token_ttl_seconds)
  return 200, {
    user = with_user_urls(req, user),
    token = token,
    email_verification_sent = false,
    email_error = nil,
  }, { ["Set-Cookie"] = gauth.session_cookie(token, M.settings.api_token_ttl_seconds) }
end

function M.login(req)
  local payload = json_body(req)
  local username_raw = trim(nn(payload.username) or ""):sub(1, 80)
  local password = nn(payload.password) or ""
  local ip = client_ip(req)

  local recent = db.fetchone([[
    SELECT COUNT(*) AS n FROM auth_attempts
    WHERE successful=false AND created_at >= (now() - interval '15 minutes')
      AND (ip_address=%s OR username=%s)
  ]], ip, username_raw)
  if recent and db.toint(recent.n, 0) >= 8 then
    return 429, { detail = "Too many failed login attempts. Try again later." }
  end

  -- LOWER(username)=%s, not username=%s: normalize_username() lowercases
  -- the input, but usernames created before the Lua rewrite (or imported
  -- from the old MySQL DB) can have mixed-case stored values -- e.g. the
  -- site owner's own "HollowHeavenXR". An exact-match comparison against
  -- a lowercased input silently locked every such account out of login
  -- entirely (confirmed live 2026-08-02: real failed attempts against a
  -- correct password, not rate-limited, not banned -- just never matching
  -- the row). Case-insensitive comparison fixes both the legacy accounts
  -- and is simply more forgiving for everyone going forward.
  local username = normalize_username(username_raw)
  local row = db.fetchone("SELECT id, password_hash FROM users WHERE LOWER(username)=%s", username)
  local password_ok = row and gauth.verify_password_hash(password, row.password_hash)

  db.execute("INSERT INTO auth_attempts (username, ip_address, successful) VALUES (%s, %s, %s)",
    username_raw ~= "" and username_raw or nil, ip:sub(1, 64), password_ok and true or false)
  -- In-memory only, not a telemetry_events row: auth_attempts (just above)
  -- already durably records every attempt -- this only feeds the admin
  -- telemetry panel's live success/failure rate without a second DB write
  -- per login.
  M.telemetry.count(password_ok and "auth_login_success" or "auth_login_failure")

  if not password_ok then return 401, { detail = "Invalid username or password." } end

  db.execute("UPDATE users SET last_login_at=now(), last_seen_at=now() WHERE id=%s", row.id)
  user_cache.invalidate(row.id)
  local user = get_user(row.id)
  if is_actively_banned(user) then
    M.telemetry.count("auth_login_banned")
    return 403, { detail = nn(user.ban_reason) or "Your account has been suspended." }
  end
  if user.totp_enabled then
    local pending = gauth.issue_2fa_pending_token(M.settings.session_secret, user.id)
    return 200, { needs_2fa = true, pending_token = pending }
  end
  local token = gauth.issue_token(M.settings.session_secret, user, M.settings.api_token_ttl_seconds)
  return 200, { user = with_user_urls(req, user), token = token }, { ["Set-Cookie"] = gauth.session_cookie(token, M.settings.api_token_ttl_seconds) }
end

function M.verify_2fa(req)
  local payload = json_body(req)
  local pending_token = nn(payload.pending_token)
  local code = tostring(nn(payload.code) or "")
  local user_id = pending_token and gauth.verify_2fa_pending_token(M.settings.session_secret, pending_token)
  if not user_id then return 401, { detail = "Your sign-in attempt expired. Log in again." } end
  local ok429, body429 = ratelimit.check("2fa-verify:" .. user_id, 10, 600)
  if ok429 then return ok429, body429 end
  if not verify_totp_or_recovery(user_id, code) then
    return 400, { detail = "Invalid authentication code." }
  end
  local user = get_user(user_id)
  if not user then return 404, { detail = "Account not found." } end
  local token = gauth.issue_token(M.settings.session_secret, user, M.settings.api_token_ttl_seconds)
  return 200, { user = with_user_urls(req, user), token = token }, { ["Set-Cookie"] = gauth.session_cookie(token, M.settings.api_token_ttl_seconds) }
end

function M.logout(req)
  return 200, { ok = true }, { ["Set-Cookie"] = gauth.session_cookie("", 0) }
end

function M.me(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  user.site_owner = is_site_owner(user)
  return 200, { user = with_user_urls(req, with_derived_accent(user)) }
end

-- Port of app/routers/account.py's PATCH /api/me/profile. Previously
-- entirely missing (see this file's header comment: "first pass ... core
-- media browsing only") -- SettingsPage.jsx/ProfilePage.jsx had no working
-- server endpoint to save profile edits to against this backend.
function M.update_profile(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local ok, result = pcall(user_settings.clean_profile_updates, json_body(req))
  if not ok then return 400, { detail = tostring(result):gsub("^.-:%d+:%s*", "") } end
  db.execute(
    [[UPDATE users SET display_name=%s, bio=%s, profile_quote=%s, website_url=%s, location_label=%s,
             profile_headline=%s, featured_tags=%s, profile_color=%s,
             public_profile=%s, show_liked_count=%s, show_collections=%s,
             show_recent_uploads=%s, show_friends=%s
      WHERE id=%s]],
    result.display_name, result.bio, result.profile_quote, result.website_url, result.location_label,
    result.profile_headline, result.featured_tags, result.profile_color,
    result.public_profile, result.show_liked_count, result.show_collections,
    result.show_recent_uploads, result.show_friends, user.id
  )
  user_cache.invalidate(user.id)
  local refreshed = get_user(user.id)
  refreshed.site_owner = is_site_owner(refreshed)
  return 200, { user = with_user_urls(req, with_derived_accent(refreshed)) }
end

-- Port of app/routers/account.py's PATCH /api/me/settings + app/db/
-- account.py's update_user_settings() enum/color/url validation (see
-- user_settings.lua's header comment -- this whole endpoint, and the
-- server-side enforcement of appearance.js's CHOICES set, was missing).
function M.update_settings(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  -- exclude_unset-equivalent: only keys the client actually sent, and only
  -- non-null values (matches account.py's `if value is not None` filter).
  local filtered = {}
  for k, v in pairs(payload) do
    if v ~= nil and v ~= cjson.null then filtered[k] = v end
  end
  local ok, result = pcall(user_settings.clean_user_settings, filtered, user.user_settings or {})
  if not ok then return 400, { detail = tostring(result):gsub("^.-:%d+:%s*", "") } end
  db.execute("UPDATE users SET user_settings=%s WHERE id=%s", cjson.encode(result), user.id)
  user_cache.invalidate(user.id)
  local refreshed = get_user(user.id)
  refreshed.site_owner = is_site_owner(refreshed)
  return 200, { user = with_user_urls(req, with_derived_accent(refreshed)) }
end

-- Server-owned appearance presets (see gallery_looks.lua), mirroring
-- SwarmPanel's /api/appearance/presets.
function M.appearance_presets(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  return 200, { gallery = gallery_looks.GALLERY_LOOKS, profile = gallery_looks.PROFILE_LOOKS }
end

-- ---------------------------------------------------------------------------
-- Categories
-- ---------------------------------------------------------------------------

function M.list_categories(req)
  local categories = db.fetchall([[
    SELECT c.id, c.name, c.slug, c.media_kind, c.created_by, c.created_at,
           COUNT(m.id) AS media_count
    FROM categories c
    LEFT JOIN media_items m ON m.category_id = c.id AND m.deleted_at IS NULL
    GROUP BY c.id
    ORDER BY c.name
  ]])
  local subcategories = db.fetchall([[
    SELECT s.id, s.category_id, s.name, s.slug, s.created_by, s.created_at,
           COUNT(m.id) AS media_count
    FROM subcategories s
    LEFT JOIN media_item_subcategories ms ON ms.subcategory_id = s.id
    LEFT JOIN media_items m ON m.id = ms.media_id AND m.deleted_at IS NULL
    GROUP BY s.id
    ORDER BY s.name
  ]])
  -- pg.lua forces every bigint (oid 20) column -- id, category_id,
  -- created_by, and the COUNT(...) aggregate -- to come back as a STRING to
  -- protect Discord-snowflake-scale values from float precision loss (see
  -- db.lua's module comment). None of these particular columns ever reach
  -- that scale (small autoincrement ids, small counts), so convert them
  -- back to real numbers here to match app/db/categories.py's JSON contract
  -- (Python/aiomysql returns them as plain ints, serialized as JSON numbers,
  -- not strings) -- do this at the response boundary, not in db.lua itself,
  -- so the precision-safety default stays intact for anything that DOES
  -- need it.
  local function numify_category(row)
    row.id = db.toint(row.id, row.id)
    row.created_by = row.created_by ~= nil and db.toint(row.created_by, row.created_by) or nil
    row.media_count = db.toint(row.media_count, 0)
    return row
  end
  local grouped = {}
  for _, row in ipairs(subcategories) do
    local cid = tostring(row.category_id)
    numify_category(row)
    row.category_id = db.toint(cid, cid)
    grouped[cid] = grouped[cid] or {}
    table.insert(grouped[cid], row)
  end
  for _, row in ipairs(categories) do
    local cid = tostring(row.id)
    numify_category(row)
    row.subcategories = arr(grouped[cid] or {})
  end
  return 200, { categories = arr(categories) }
end

local MEDIA_KINDS = { image = true, video = true, mixed = true }

local function slugify(name)
  local slug = name:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if slug == "" then slug = "category" end
  return slug:sub(1, 80)
end

function M.create_category(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local rl_status, rl_body = ratelimit.check("category_create:" .. user.id, 20, 3600)
  if rl_status then return rl_status, rl_body end
  local payload = json_body(req)
  local name = trim(nn(payload.name) or ""):sub(1, 80)
  local media_kind = nn(payload.media_kind) or "mixed"
  if name == "" then return 400, { detail = "Category name is required." } end
  if not MEDIA_KINDS[media_kind] then return 400, { detail = "Category type must be image, video, or mixed." } end
  local slug = slugify(name)
  local existing = db.fetchone("SELECT * FROM categories WHERE name=%s OR slug=%s", name, slug)
  if existing then
    existing.id = db.toint(existing.id, existing.id)
    if existing.created_by then existing.created_by = db.toint(existing.created_by, existing.created_by) end
    return 200, { category = existing }
  end
  local row = db.fetchone(
    "INSERT INTO categories (name, slug, media_kind, created_by) VALUES (%s, %s, %s, %s) RETURNING *",
    name, slug, media_kind, user.id
  )
  if row then
    row.id = db.toint(row.id, row.id)
    if row.created_by then row.created_by = db.toint(row.created_by, row.created_by) end
  end
  return 200, { category = row }
end

-- ---------------------------------------------------------------------------
-- Media listing (GET /api/media) -- core browsing.
--
-- NOT YET PORTED as part of this: url/thumb_url/preview_url/download_url
-- generation (app/routers/_shared.py's _with_urls) -- those point at
-- file-serving routes (serve_media_file/thumb/preview, byte-range video
-- streaming) that this pass does not implement (see final report). This
-- returns full metadata (title, tags, counts, category, uploader) with
-- url fields left null so the contract shape matches but media bytes are
-- not yet servable through this backend.
-- ---------------------------------------------------------------------------

-- Booru-style boolean tag query: "cat dog" = has both (AND), "cat OR dog" =
-- has either, "-cat" = must NOT have. Space-separated; an OR chain binds
-- tighter than the implicit AND between groups, e.g. "cat OR dog -wet"
-- means (cat OR dog) AND NOT wet. Deliberately not a full boolean-algebra
-- parser (no parens/nesting) -- this covers the actual booru convention
-- (Danbooru/e621/Derpibooru all use exactly this flat OR-groups-ANDed-
-- together-plus-NOT shape) without building a general expression parser
-- for a feature that's a search-bar convenience, not a query language.
-- Returns (and_groups, not_tags) where and_groups is an array of arrays
-- (each inner array is an OR-group of tag strings) and not_tags is a flat
-- array of excluded tag strings.
local function parse_tag_query(input)
  local tokens = {}
  for word in tostring(input or ""):gmatch("%S+") do
    if #tokens < 40 then tokens[#tokens + 1] = word end
  end
  local and_groups, not_tags = {}, {}
  local i = 1
  while i <= #tokens do
    local tok = tokens[i]
    if tok:sub(1, 1) == "-" and #tok > 1 then
      not_tags[#not_tags + 1] = tok:sub(2):lower():sub(1, 60)
      i = i + 1
    else
      local or_group = { tok:lower():sub(1, 60) }
      i = i + 1
      while tokens[i] and tokens[i]:upper() == "OR" and tokens[i + 1] do
        or_group[#or_group + 1] = tokens[i + 1]:lower():sub(1, 60)
        i = i + 2
      end
      and_groups[#and_groups + 1] = or_group
    end
  end
  return and_groups, not_tags
end

-- Builds a Postgres text[] array literal placeholder ("ARRAY[%s,%s,...]")
-- for jsonb's `?|`/`?&` "any/all of these keys exist" operators, appending
-- one %s + one param per tag. clauses/params are mutated in place (same
-- calling convention as list_media's own clause-building loop below).
local function append_tag_array_clause(clauses, params, tags, column, negate, mode)
  local placeholders = {}
  for _, tag in ipairs(tags) do
    placeholders[#placeholders + 1] = "%s"
    params[#params + 1] = tag
  end
  local array_sql = "ARRAY[" .. table.concat(placeholders, ",") .. "]"
  local op = mode == "all" and "?&" or "?|"
  local test = string.format("(%s::jsonb %s %s)", column, op, array_sql)
  clauses[#clauses + 1] = negate and ("NOT " .. test) or test
end

local VALID_SORTS = { new = true, old = true, popular = true, views = true, downloads = true, trending = true }

-- Moved here (before M.list_media/M.upload_media) rather than kept next to
-- the rest of the collections-section helpers further down, since both
-- collections AND saved-searches (further below) AND M.upload_media's
-- saved-search-match notification hook need this -- Lua locals are only
-- visible to code appearing after their declaration in the same scope.
local SMART_FILTER_KEYS = {
  media_kind = true, category_id = true, subcategory_id = true, q = true, uploader = true,
  min_size = true, max_size = true, date_from = true, date_to = true, adult = true, sort = true,
}
local DATE_RE = "^%d%d%d%d%-%d%d%-%d%d$"

-- Mirrors _sanitize_smart_collection_filter(): validates/coerces a saved
-- smart-collection filter the same way GET /api/media's own query params
-- would be, so a bad stored value can't reach list_media unvalidated.
local function sanitize_smart_filter(filter_json)
  local cleaned = {}
  for key, value in pairs(filter_json or {}) do
    if SMART_FILTER_KEYS[key] and value ~= nil and value ~= "" and value ~= cjson.null then
      if key == "media_kind" then
        if value == "image" or value == "video" then cleaned[key] = value end
      elseif key == "category_id" or key == "subcategory_id" then
        local n = tonumber(value)
        if n then cleaned[key] = math.floor(n) end
      elseif key == "min_size" or key == "max_size" then
        local n = tonumber(value)
        if n then cleaned[key] = math.max(0, math.floor(n)) end
      elseif key == "date_from" or key == "date_to" then
        if tostring(value):match(DATE_RE) then cleaned[key] = value end
      elseif key == "adult" then
        if value == "only" or value == "hide" then cleaned[key] = value end
      elseif key == "sort" then
        if VALID_SORTS[value] then cleaned[key] = value end
      elseif key == "q" or key == "uploader" then
        cleaned[key] = tostring(value):sub(1, 80)
      end
    end
  end
  return cleaned
end

local function bounded_limit(v, default, max_limit)
  local n = tonumber(v) or default
  return math.max(1, math.min(n, max_limit or M.settings.media_page_limit))
end

local function bounded_offset(v)
  local n = tonumber(v) or 0
  return math.max(0, n)
end

-- See the identical numify comment in list_categories: these id/count
-- columns are all small in practice (never Discord-snowflake scale), so
-- convert pg.lua's precision-safety string coercion back to real JSON
-- numbers here to match app/db/media.py's contract.
local function numify_media(row)
  for _, field in ipairs({ "id", "user_id", "category_id", "subcategory_id", "file_size", "views", "downloads", "like_count", "comment_count" }) do
    if row[field] ~= nil then row[field] = db.toint(row[field], row[field]) end
  end
  return row
end

-- Mirrors app/routers/_shared.py's _append_query().
local function append_query(url, key, value)
  local sep = url:find("?", 1, true) and "&" or "?"
  return url .. sep .. key .. "=" .. value
end

-- Cache-busting thumb_url builder. The thumb endpoint sends
-- "Cache-Control: public, max-age=604800, immutable" (see M.serve_media_thumb)
-- -- great for the normal case (a thumbnail essentially never changes after
-- its first render) but it means a browser that already fetched a given
-- media_id's thumb URL will NEVER ask the server again for a week, even if
-- the cached file on disk is later regenerated (an admin repair script, a
-- YouTube-source-link backfill, etc.). Appending a `v` token derived from
-- updated_at -- same "cheap existing column as a version stamp" idiom
-- original_bytes_cache_path already uses for its own cache key (see that
-- function's header comment) -- changes the URL whenever updated_at changes,
-- so a forced re-render is automatically visible to every client without
-- needing a CDN purge or anyone hard-refreshing. Routine first-time renders
-- don't need this (the URL is new to the client either way), so nothing
-- needs to bump updated_at on every normal upload/view -- only an explicit
-- repair path (see scripts/backfill_youtube_thumbnails.lua) needs to.
function M.thumb_url_for(origin, media_id, media_kind, updated_at)
  if media_kind ~= "image" and media_kind ~= "video" then return nil end
  local url = append_query(origin .. "/api/media/" .. media_id .. "/thumb", "w", "640")
  if updated_at and updated_at ~= cjson.null then
    url = append_query(url, "v", tostring(updated_at):gsub("%D", ""))
  end
  return url
end

-- Absolute origin (scheme://host) for the request, honoring a reverse proxy's
-- X-Forwarded-Proto/Host the same way app/routers/_shared.py's
-- _api_cache_origin() does. Needed because the frontend is hosted on a
-- different origin (GitHub Pages / a tunnel domain) than the API, so
-- relative URLs in JSON responses would resolve against the WRONG origin in
-- the browser -- these must be absolute.
function request_origin(req)
  local proto = (req.headers["x-forwarded-proto"] or "http"):match("^[^,%s]+") or "http"
  local host = (req.headers["x-forwarded-host"] or req.headers["host"] or "localhost"):match("^[^,%s]+") or "localhost"
  return proto .. "://" .. host
end

local function is_gif_media(row)
  local mime = tostring(row.mime_type or ""):lower()
  local filename = tostring(row.original_filename or row.storage_path or ""):lower()
  return mime == "image/gif" or filename:sub(-4) == ".gif"
end

-- Mirrors app/routers/_shared.py's _with_urls(): fills in url/thumb_url/
-- preview_url/download_url (and user_avatar_url) pointing at THIS backend's
-- own byte-serving routes (see M.serve_media_thumb/file/preview/download
-- below), or nulls them out entirely for a locked (is_adult, viewer not
-- age-verified) row. Mutates and returns `row`.
local function with_urls(req, row, adult_allowed)
  if not row then return nil end
  local origin = request_origin(req)
  local locked = row.is_adult and not adult_allowed
  row.locked = locked
  row.viewer_can_open_adult = adult_allowed
  row.requires_adult_blur = row.is_adult and adult_allowed
  if locked then
    row.storage_path = nil
    row.url, row.preview_url, row.thumb_url, row.download_url = nil, nil, nil, nil
  else
    local media_id = row.id
    row.url = origin .. "/api/media/" .. media_id .. "/file"
    row.download_url = origin .. "/api/media/" .. media_id .. "/download"
    row.thumb_url = M.thumb_url_for(origin, media_id, row.media_kind, row.updated_at)
    if row.thumb_url then row.thumb_url = row.thumb_url:gsub("/thumb%?", "/thumb.webp?", 1) end
    if is_gif_media(row) then
      row.preview_url = row.url
    elseif row.media_kind == "image" then
      -- .webp path = edge-cacheable (see main.lua); v= busts it on edits.
      row.preview_url = origin .. "/api/media/" .. media_id .. "/preview.webp"
      if row.updated_at and row.updated_at ~= cjson.null then
        row.preview_url = append_query(row.preview_url, "v", (tostring(row.updated_at):gsub("%D", "")))
      end
    else
      row.preview_url = row.thumb_url
    end
    -- Always attach the capability token, not just for adult posts: plain
    -- <img>/<video src> tags don't send credentials cross-origin (no
    -- `crossorigin` attribute is set anywhere in the frontend, and adding
    -- one would require the media routes to send CORS headers too), so a
    -- private post's byte-serving routes never saw the owner's session
    -- cookie and 403'd even for the post's own owner viewing their own
    -- gallery. This JSON row was only handed to `row` after auth_optional's
    -- cookie check already passed (see M.list_media/M.media_detail's
    -- callers), so re-granting the same access via a URL-embedded token is
    -- not a privilege escalation -- it's carrying forward a decision
    -- already made, exactly like the pre-existing adult-content token did.
    do
      local token = gauth.media_access_token(M.settings.session_secret, media_id)
      row.url = append_query(row.url, "access", token)
      if row.preview_url then row.preview_url = append_query(row.preview_url, "access", token) end
      if row.thumb_url then row.thumb_url = append_query(row.thumb_url, "access", token) end
      row.download_url = append_query(row.download_url, "access", token)
    end
  end
  if row.user_avatar_path and row.user_avatar_path ~= cjson.null then
    row.user_avatar_url = origin .. "/api/users/" .. (row.user_id or row.id) .. "/avatar"
  end
  return row
end

-- Original-source attribution. Kept as a method on M rather than a
-- top-level local deliberately: this file sits at 199 top-level locals and
-- LuaJIT's ceiling is 200, so a new `local function` here would cost the
-- last slot for no benefit.
--
-- Returns (url, nil) on success, (nil, nil) when the field was simply not
-- supplied, and (nil, message) when it was supplied but unusable. Only
-- http/https pass: the value is rendered as a link in the UI, so accepting
-- javascript:/data:/vbscript: here would be a stored-XSS vector.
function M.normalize_source_url(value)
  local raw = value
  if raw == nil or raw == cjson.null then return nil, nil end
  raw = trim(tostring(raw))
  if raw == "" then return nil, nil end
  if #raw > 500 then return nil, "Source link must be 500 characters or fewer." end
  if raw:find("%s") or raw:find("%c") then return nil, "Source link cannot contain spaces." end
  local scheme = raw:match("^(%a[%w+.-]*):")
  if not scheme then return nil, "Source link must start with http:// or https://." end
  scheme = scheme:lower()
  if scheme ~= "http" and scheme ~= "https" then
    return nil, "Source link must start with http:// or https://."
  end
  if not raw:match("^https?://[^/]+") then
    return nil, "Source link must include a domain, like https://example.com/post/1."
  end
  return raw, nil
end

local function decode_media_row(row, viewer_can_open_adult, req)
  numify_media(row)
  row.is_adult = db.tobool(row.is_adult)
  row.adult_marked_by_user = db.tobool(row.adult_marked_by_user)
  row.adult_marked_by_ai = db.tobool(row.adult_marked_by_ai)
  row.comments_enabled = db.tobool(row.comments_enabled)
  row.downloads_enabled = db.tobool(row.downloads_enabled)
  row.public_profile = db.tobool(row.public_profile)
  row.liked_by_me = db.tobool(row.liked_by_me)
  row.bookmarked_by_me = db.tobool(row.bookmarked_by_me)
  -- arr(), not a bare `{}` fallback -- see decode_user's featured_tags
  -- comment for why: an untagged post (extremely common) would otherwise
  -- send tags as a JSON object ({}) instead of an array ([]), which is a
  -- hard decode failure for any client expecting an array there -- and
  -- since this is the per-item decoder every feed/list endpoint calls, one
  -- untagged post anywhere in a page of results corrupted that entire
  -- response's decode for API clients with a strict [String] tags field.
  if row.tags and row.tags ~= cjson.null then
    local ok, decoded = pcall(cjson.decode, row.tags)
    row.tags = (ok and type(decoded) == "table") and arr(decoded) or arr({})
  else
    row.tags = arr({})
  end
  return with_urls(req, row, viewer_can_open_adult)
end

-- ---------------------------------------------------------------------------
-- Category/subcategory find-or-create + multi-subcategory support (up to
-- MAX_MEDIA_SUBCATEGORIES per post). Mirrors app/db/categories.py's
-- create_category/create_subcategory/resolve_subcategory_ids/
-- _write_media_subcategories and app/db/helpers.py's
-- _attach_media_subcategories/app/db/_shared.py's normalize_subcategory_ids/
-- _names. Placed here (before M.list_media/M.media_detail) rather than
-- alongside the rest of the upload-section helpers further down, since both
-- of those need attach_media_subcategories. media_items.subcategory_id
-- stays as the "primary" (first) subcategory for any code still reading
-- that single column directly; the full ordered set lives in
-- media_item_subcategories.
-- ---------------------------------------------------------------------------

local function find_or_create_category(name, media_kind, user_id)
  name = trim(name or ""):sub(1, 80)
  if name == "" then return nil end
  local slug = slugify(name)
  local existing = db.fetchone("SELECT id FROM categories WHERE name=%s OR slug=%s", name, slug)
  if existing then return db.toint(existing.id, existing.id) end
  local row = db.fetchone(
    "INSERT INTO categories (name, slug, media_kind, created_by) VALUES (%s, %s, %s, %s) RETURNING id",
    name, slug, MEDIA_KINDS[media_kind] and media_kind or "mixed", tostring(user_id)
  )
  return row and db.toint(row.id, row.id) or nil
end

local function find_or_create_subcategory(category_id, name, user_id)
  name = trim(name or ""):sub(1, 80)
  if name == "" or not category_id then return nil end
  local slug = slugify(name)
  local existing = db.fetchone(
    "SELECT id FROM subcategories WHERE category_id=%s AND (name=%s OR slug=%s)",
    tostring(category_id), name, slug
  )
  if existing then return db.toint(existing.id, existing.id) end
  local row = db.fetchone(
    "INSERT INTO subcategories (category_id, name, slug, created_by) VALUES (%s, %s, %s, %s) RETURNING id",
    tostring(category_id), name, slug, tostring(user_id)
  )
  return row and db.toint(row.id, row.id) or nil
end

local MAX_MEDIA_SUBCATEGORIES = 20

local function clean_subcategory_name(value)
  return trim(tostring(value or "")):gsub("%s+", " "):sub(1, 80)
end

local function normalize_subcategory_ids(values)
  local ids, seen = {}, {}
  if type(values) == "table" then
    for _, raw in ipairs(values) do
      local id = tonumber(raw)
      if id and id > 0 and not seen[id] then
        seen[id] = true
        ids[#ids + 1] = math.floor(id)
        if #ids >= MAX_MEDIA_SUBCATEGORIES then break end
      end
    end
  end
  return ids
end

local function normalize_subcategory_names(values)
  local names, seen = {}, {}
  if type(values) == "table" then
    for _, raw in ipairs(values) do
      local cleaned = clean_subcategory_name(raw)
      if cleaned ~= "" then
        local key = cleaned:lower()
        if not seen[key] then
          seen[key] = true
          names[#names + 1] = cleaned
          if #names >= MAX_MEDIA_SUBCATEGORIES then break end
        end
      end
    end
  end
  return names
end

-- Returns (ids_list, nil) on success or (nil, error_message) on failure --
-- Lua has no exceptions worth structuring control flow around here, unlike
-- Python's ValueError.
local function resolve_subcategory_ids(category_id, subcategory_ids, subcategory_names, user_id)
  category_id = tonumber(category_id) or 0
  if category_id <= 0 then return nil, "Choose a valid category." end
  local ids = normalize_subcategory_ids(subcategory_ids)
  local names = normalize_subcategory_names(subcategory_names)

  if not db.fetchone("SELECT id FROM categories WHERE id=%s", tostring(category_id)) then
    return nil, "Category does not exist."
  end

  local validated = {}
  for _, id in ipairs(ids) do
    if not db.fetchone("SELECT id FROM subcategories WHERE id=%s AND category_id=%s", tostring(id), tostring(category_id)) then
      return nil, "Subcategory does not belong to that category."
    end
    validated[#validated + 1] = id
  end

  for _, name in ipairs(names) do
    if #validated >= MAX_MEDIA_SUBCATEGORIES then break end
    local new_id = find_or_create_subcategory(category_id, name, user_id)
    if new_id then
      local exists = false
      for _, v in ipairs(validated) do if v == new_id then exists = true; break end end
      if not exists then validated[#validated + 1] = new_id end
    end
  end

  if #validated > MAX_MEDIA_SUBCATEGORIES then
    local trimmed = {}
    for i = 1, MAX_MEDIA_SUBCATEGORIES do trimmed[i] = validated[i] end
    validated = trimmed
  end
  return validated
end

local function write_media_subcategories(media_id, subcategory_ids)
  local primary = subcategory_ids[1]
  db.execute("UPDATE media_items SET subcategory_id=%s WHERE id=%s", primary and tostring(primary) or nil, tostring(media_id))
  db.execute("DELETE FROM media_item_subcategories WHERE media_id=%s", tostring(media_id))
  for position, subcategory_id in ipairs(subcategory_ids) do
    db.execute(
      "INSERT INTO media_item_subcategories (media_id, subcategory_id, position) VALUES (%s, %s, %s)",
      tostring(media_id), tostring(subcategory_id), tostring(position)
    )
  end
end

-- Batch-attaches subcategories/subcategory_ids/subcategory_names to each row
-- in `rows` (each must have a numeric/bigint-string `id`), and overrides the
-- single subcategory_id/subcategory_name/subcategory_slug fields with the
-- primary (first) entry so single-subcategory API consumers keep working.
local function attach_media_subcategories(rows)
  if #rows == 0 then return rows end
  local id_list = {}
  for _, row in ipairs(rows) do id_list[#id_list + 1] = tostring(db.toint(row.id, row.id)) end

  local sub_rows = db.fetchall(string.format([[
    SELECT ms.media_id, ms.position, s.id, s.category_id, s.name, s.slug
    FROM media_item_subcategories ms
    JOIN subcategories s ON s.id = ms.subcategory_id
    WHERE ms.media_id IN (%s)
    ORDER BY ms.media_id ASC, ms.position ASC
  ]], table.concat(id_list, ",")))

  local grouped = {}
  for _, r in ipairs(sub_rows) do
    local mid = db.toint(r.media_id, r.media_id)
    grouped[mid] = grouped[mid] or {}
    grouped[mid][#grouped[mid] + 1] = {
      id = db.toint(r.id, r.id), category_id = db.toint(r.category_id, r.category_id),
      name = r.name, slug = r.slug,
    }
  end

  for _, row in ipairs(rows) do
    local subs = grouped[db.toint(row.id, row.id)] or {}
    row.subcategories = arr(subs)
    local sub_ids, sub_names = {}, {}
    for _, s in ipairs(subs) do
      sub_ids[#sub_ids + 1] = s.id
      sub_names[#sub_names + 1] = s.name
    end
    row.subcategory_ids = arr(sub_ids)
    row.subcategory_names = arr(sub_names)
    if #subs > 0 then
      row.subcategory_id = subs[1].id
      row.subcategory_name = subs[1].name
      row.subcategory_slug = subs[1].slug
    end
  end
  return rows
end

function M.list_media(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local viewer_can_open_adult = false
  if viewer_id then
    local viewer = get_user(viewer_id)
    viewer_can_open_adult = viewer ~= nil and nn(viewer.age_verified_at) ~= nil and viewer.adult_content_consent
  end

  local q = req.query or {}
  local media_kind = nn(q.media_kind)
  local category_id = tonumber(q.category_id)
  local subcategory_id = tonumber(q.subcategory_id)
  local query_text = trim(nn(q.q) or ""):sub(1, 80)
  local uploader = trim(nn(q.uploader) or ""):sub(1, 80)
  local min_size = tonumber(q.min_size)
  local max_size = tonumber(q.max_size)
  local date_from = nn(q.date_from)
  local date_to = nn(q.date_to)
  local adult = nn(q.adult)
  local tag_query = nn(q.tags)
  local color_hex = nn(q.color) and tostring(q.color):gsub("^#", ""):match("^(%x%x%x%x%x%x)$") or nil
  local color_tolerance = math.max(4, math.min(tonumber(q.color_tolerance) or 40, 128))
  local sort = VALID_SORTS[q.sort or ""] and q.sort or "new"
  local limit = bounded_limit(q.limit, 60)
  local offset = bounded_offset(q.offset)
  local viewer0 = viewer_id or "0"

  local clauses = {
    "m.deleted_at IS NULL",
    "(m.visibility='public' OR m.user_id=%s)",
    "(m.publish_at IS NULL OR m.publish_at <= now() OR m.user_id=%s)",
  }
  local params = { viewer0, viewer0 }

  -- Hide posts from anyone the viewer has blocked or muted -- genuinely new
  -- enforcement (see should_suppress_notification's comment further down:
  -- "mute" was storable via the block/mute endpoint and shown in Settings,
  -- but nothing ever actually filtered on it, including block itself never
  -- being applied to feed visibility, only to DMs/follows/mentions).
  if viewer_id then
    clauses[#clauses + 1] = "m.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id=%s)"
    params[#params + 1] = viewer0
  end

  if media_kind == "image" or media_kind == "video" then
    clauses[#clauses + 1] = "m.media_kind=%s"; params[#params + 1] = media_kind
  end
  if category_id then
    clauses[#clauses + 1] = "m.category_id=%s"; params[#params + 1] = tostring(category_id)
  end
  if subcategory_id then
    clauses[#clauses + 1] = "EXISTS (SELECT 1 FROM media_item_subcategories ms WHERE ms.media_id=m.id AND ms.subcategory_id=%s)"
    params[#params + 1] = tostring(subcategory_id)
  end
  if query_text ~= "" then
    -- media_items.text_search is a generated tsvector(title || ' ' ||
    -- description) column with its own GIN index
    -- (idx_media_items_text_search) that already existed on this table but
    -- was never actually queried anywhere -- title/description search ran
    -- as a plain ILIKE seq-scan-shaped pattern match instead. plainto_tsquery
    -- gets real word-boundary/stemmed matching (searching "cat" now also
    -- matches "cats"/"catlike", which a substring ILIKE never would) AND
    -- lets the GIN index actually get used. tags stays on ILIKE -- it's a
    -- JSON-encoded array column, not part of text_search, and a plain
    -- substring match across the raw JSON text is still the simplest way
    -- to catch a query that's itself a tag/tag fragment.
    clauses[#clauses + 1] = "(m.text_search @@ plainto_tsquery('english', %s) OR m.tags ILIKE %s)"
    params[#params + 1] = query_text
    params[#params + 1] = "%" .. query_text:gsub("([%%_])", "\\%1") .. "%"
  end
  if uploader ~= "" then
    clauses[#clauses + 1] = "(u.username ILIKE %s OR u.display_name ILIKE %s)"
    local needle = "%" .. uploader:gsub("([%%_])", "\\%1") .. "%"
    params[#params + 1] = needle; params[#params + 1] = needle
  end
  if min_size then clauses[#clauses + 1] = "m.file_size >= %s"; params[#params + 1] = tostring(math.max(0, min_size)) end
  if max_size then clauses[#clauses + 1] = "m.file_size <= %s"; params[#params + 1] = tostring(math.max(0, max_size)) end
  if date_from then clauses[#clauses + 1] = "m.created_at::date >= %s"; params[#params + 1] = date_from end
  if date_to then clauses[#clauses + 1] = "m.created_at::date <= %s"; params[#params + 1] = date_to end
  if not viewer_can_open_adult then
    -- Unverified/anonymous viewers never see 18+ posts at all -- not even
    -- a locked placeholder card, see with_urls -- so this overrides any
    -- adult=only/hide query param rather than layering under it: adult=only
    -- must not be usable to probe "does any 18+ content exist" via result
    -- counts for a viewer who isn't allowed to see it either way.
    clauses[#clauses + 1] = "m.is_adult=false"
  elseif adult == "only" then clauses[#clauses + 1] = "m.is_adult=true"
  elseif adult == "hide" then clauses[#clauses + 1] = "m.is_adult=false" end
  if tag_query then
    local and_groups, not_tags = parse_tag_query(tag_query)
    for _, or_group in ipairs(and_groups) do
      append_tag_array_clause(clauses, params, or_group, "m.tags", false, "any")
    end
    if #not_tags > 0 then
      append_tag_array_clause(clauses, params, not_tags, "m.tags", true, "any")
    end
  end
  if color_hex then
    -- Per-channel absolute-difference box filter (not true Euclidean
    -- distance -- avoids needing sqrt/power in SQL for what's already an
    -- approximate 8x8-average "dominant color", so extra precision here
    -- wouldn't mean much). dominant_color is stored as "#rrggbb"; extract
    -- each byte via decode(...,'hex') + get_byte rather than three
    -- separate substring/to_number calls.
    local target_r = tonumber(color_hex:sub(1, 2), 16)
    local target_g = tonumber(color_hex:sub(3, 4), 16)
    local target_b = tonumber(color_hex:sub(5, 6), 16)
    clauses[#clauses + 1] = [[
      m.dominant_color IS NOT NULL
      AND ABS(get_byte(decode(substring(m.dominant_color from 2), 'hex'), 0) - %s) <= %s
      AND ABS(get_byte(decode(substring(m.dominant_color from 2), 'hex'), 1) - %s) <= %s
      AND ABS(get_byte(decode(substring(m.dominant_color from 2), 'hex'), 2) - %s) <= %s
    ]]
    params[#params + 1] = tostring(target_r); params[#params + 1] = tostring(color_tolerance)
    params[#params + 1] = tostring(target_g); params[#params + 1] = tostring(color_tolerance)
    params[#params + 1] = tostring(target_b); params[#params + 1] = tostring(color_tolerance)
  end

  local where = "WHERE " .. table.concat(clauses, " AND ")
  local order = ({
    popular = "m.pinned_at DESC NULLS LAST, like_count DESC, m.views DESC, m.created_at DESC",
    downloads = "m.pinned_at DESC NULLS LAST, m.downloads DESC, m.created_at DESC",
    views = "m.pinned_at DESC NULLS LAST, m.views DESC, m.created_at DESC",
    old = "m.created_at ASC",
    -- Age-decayed "hot" score (views + 3x weight per like, divided by age in
    -- hours to a power) -- same idea as Reddit/HN ranking. Deliberately
    -- built from columns list_media already selects (m.views, like_count,
    -- m.created_at) rather than a media_views time-window join: that table
    -- is a per-viewer dedup set (one row per unique viewer ever, see its
    -- schema/TODO.md), not a view-event log, so a true "views in the last N
    -- days" score isn't available without a schema change. The age decay
    -- gets the same practical effect (recent posts with traction rank
    -- above old posts with high raw totals) using only existing columns.
    -- Note: can't reference the `like_count` SELECT-list alias here --
    -- Postgres only resolves output aliases when they're the *entire*
    -- ORDER BY item, not when nested inside a larger expression (confirmed
    -- live: "column \"like_count\" does not exist") -- so this repeats the
    -- like-count subquery instead.
    trending = "m.pinned_at DESC NULLS LAST, (m.views + (SELECT COUNT(DISTINCT lk.user_id) FROM media_likes lk WHERE lk.media_id = m.id) * 3) / POWER(EXTRACT(EPOCH FROM (now() - m.created_at)) / 3600 + 2, 1.5) DESC, m.created_at DESC",
    -- ts_rank against the same text_search column the WHERE clause above
    -- now actually searches.
    relevance = "ts_rank(m.text_search, plainto_tsquery('english', %s)) DESC, m.pinned_at DESC NULLS LAST, m.created_at DESC",
  })[sort] or "m.pinned_at DESC NULLS LAST, m.created_at DESC"
  -- A text search with the caller's default sort ("new"/unset) reads
  -- results ranked by relevance, not upload date -- matches what "true
  -- indexing" is actually for. An explicit sort=... still always wins.
  local effective_sort = sort
  if query_text ~= "" and (not sort or sort == "" or sort == "new") then
    effective_sort = "relevance"
    order = "ts_rank(m.text_search, plainto_tsquery('english', %s)) DESC, m.pinned_at DESC NULLS LAST, m.created_at DESC"
  end

  -- Build the full parameter list in call order: 4 leading viewer refs used
  -- by the SELECT list's CASE expressions + the 2 liked/bookmarked viewer refs, then the
  -- WHERE clause's own params (already collected above), then LIMIT/OFFSET.
  local sql_params = { viewer0, viewer0, viewer0, viewer0, viewer0, viewer0 }
  for _, p in ipairs(params) do sql_params[#sql_params + 1] = p end
  -- order's own %s (the relevance branch's ts_rank(...) call) sits
  -- textually between the WHERE clause and LIMIT/OFFSET in the final SQL
  -- -- its parameter has to land in that same position in sql_params, not
  -- appended after limit/offset.
  if effective_sort == "relevance" then sql_params[#sql_params + 1] = query_text end
  sql_params[#sql_params + 1] = tostring(limit)
  sql_params[#sql_params + 1] = tostring(offset)

  -- Per-post counts and the viewer's liked/bookmarked flags are correlated
  -- subqueries, not LEFT JOINs + GROUP BY. The joins multiplied every
  -- post's likes by its comments and forced Postgres to aggregate EVERY
  -- post matching the filters before it could sort and take one page, so
  -- each feed load cost grew with the whole gallery (measured ~2.4s on a
  -- 20k-post copy). As subqueries, sorts that don't depend on counts
  -- (new/old/views/downloads) walk the created_at index and only compute
  -- counts for the rows on the page (~60ms on the same data); the
  -- count-based sorts still look at every candidate but via index lookups
  -- instead of a joined, grouped scan. Same columns, values and order.
  local sql = string.format([[
    SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.description, m.tags,
           m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.file_size,
           m.views, m.downloads, m.created_at, m.updated_at, m.visibility,
           m.comments_enabled, m.downloads_enabled, m.pinned_at, m.is_adult,
           m.adult_marked_by_user, m.adult_marked_by_ai, m.moderation_status, m.dominant_color, m.source_url,
           c.name AS category_name, c.slug AS category_slug,
           sc.name AS subcategory_name, sc.slug AS subcategory_slug,
           u.username,
           CASE WHEN u.public_profile OR u.id::text=%%s THEN u.display_name ELSE u.username END AS display_name,
           CASE WHEN u.public_profile OR u.id::text=%%s THEN u.bio ELSE NULL END AS user_bio,
           CASE WHEN u.public_profile OR u.id::text=%%s THEN u.website_url ELSE NULL END AS user_website_url,
           CASE WHEN u.public_profile OR u.id::text=%%s THEN u.avatar_path ELSE NULL END AS user_avatar_path,
           u.profile_color, u.public_profile,
           (SELECT COUNT(DISTINCT lk.user_id) FROM media_likes lk WHERE lk.media_id = m.id) AS like_count,
           (SELECT COUNT(*) FROM media_comments cmc WHERE cmc.media_id = m.id) AS comment_count,
           CASE WHEN EXISTS (SELECT 1 FROM media_bookmarks b WHERE b.media_id = m.id AND b.user_id::text = %%s) THEN 1 ELSE 0 END AS bookmarked_by_me,
           CASE WHEN EXISTS (SELECT 1 FROM media_likes l2 WHERE l2.media_id = m.id AND l2.user_id::text = %%s) THEN 1 ELSE 0 END AS liked_by_me
    FROM media_items m
    JOIN categories c ON c.id = m.category_id
    LEFT JOIN subcategories sc ON sc.id = m.subcategory_id
    JOIN users u ON u.id = m.user_id
    %s
    ORDER BY %s
    LIMIT %%s OFFSET %%s
  ]], where, order)

  local rows, err = db.fetchall(sql, unpack(sql_params))
  if err then return 500, { detail = "Query failed: " .. tostring(err) } end
  attach_media_subcategories(rows)
  for _, row in ipairs(rows) do decode_media_row(row, viewer_can_open_adult, req) end
  return 200, { media = arr(rows), limit = limit, offset = offset, sort = effective_sort }
end

-- Shared by the three feed-shaped endpoints below (feed_following,
-- feed_liked, media_trending) -- deliberately NOT wired into list_media()
-- above (which stays exactly as already verified/live) to avoid risking a
-- regression there; this repeats list_media's SELECT/JOIN/GROUP BY shape
-- once, for these three new callers, rather than three more full copies.
-- `extra_clause`/`extra_params` is one optional additional %s-style WHERE
-- fragment (already includes its own params); `order_sql` is a trusted
-- internal literal (never user input), same convention as list_media's own
-- `order` table.
local function fetch_media_feed(req, viewer_id, extra_clause, extra_params, order_sql, limit, offset)
  local viewer_can_open_adult = false
  if viewer_id then
    local viewer = get_user(viewer_id)
    viewer_can_open_adult = viewer ~= nil and nn(viewer.age_verified_at) ~= nil and viewer.adult_content_consent
  end
  local viewer0 = viewer_id or "0"

  local clauses = {
    "m.deleted_at IS NULL",
    "(m.visibility='public' OR m.user_id=%s)",
    "(m.publish_at IS NULL OR m.publish_at <= now() OR m.user_id=%s)",
  }
  local params = { viewer0, viewer0 }
  -- Same block/mute feed-hiding as list_media (see its own comment) --
  -- applies here too since this backs the following/liked/trending feeds.
  if viewer_id then
    clauses[#clauses + 1] = "m.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id=%s)"
    params[#params + 1] = viewer0
  end
  if not viewer_can_open_adult then
    -- Same full-exclusion rule as list_media -- see its comment. This
    -- backs the following/liked/trending feeds, which have no adult=only/
    -- hide toggle to override in the first place, so this is unconditional.
    clauses[#clauses + 1] = "m.is_adult=false"
  end
  if extra_clause then
    clauses[#clauses + 1] = extra_clause
    for _, p in ipairs(extra_params or {}) do params[#params + 1] = p end
  end
  local where = "WHERE " .. table.concat(clauses, " AND ")

  local sql_params = { viewer0, viewer0, viewer0, viewer0, viewer0, viewer0 }
  for _, p in ipairs(params) do sql_params[#sql_params + 1] = p end
  sql_params[#sql_params + 1] = tostring(limit)
  sql_params[#sql_params + 1] = tostring(offset)

  local sql = string.format([[
    SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.description, m.tags,
           m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.file_size,
           m.views, m.downloads, m.created_at, m.updated_at, m.visibility,
           m.comments_enabled, m.downloads_enabled, m.pinned_at, m.is_adult,
           m.adult_marked_by_user, m.adult_marked_by_ai, m.moderation_status, m.dominant_color, m.source_url,
           c.name AS category_name, c.slug AS category_slug,
           sc.name AS subcategory_name, sc.slug AS subcategory_slug,
           u.username,
           CASE WHEN u.public_profile OR u.id::text=%%s THEN u.display_name ELSE u.username END AS display_name,
           CASE WHEN u.public_profile OR u.id::text=%%s THEN u.bio ELSE NULL END AS user_bio,
           CASE WHEN u.public_profile OR u.id::text=%%s THEN u.website_url ELSE NULL END AS user_website_url,
           CASE WHEN u.public_profile OR u.id::text=%%s THEN u.avatar_path ELSE NULL END AS user_avatar_path,
           u.profile_color, u.public_profile,
           (SELECT COUNT(DISTINCT lk.user_id) FROM media_likes lk WHERE lk.media_id = m.id) AS like_count,
           (SELECT COUNT(*) FROM media_comments cmc WHERE cmc.media_id = m.id) AS comment_count,
           CASE WHEN EXISTS (SELECT 1 FROM media_bookmarks b WHERE b.media_id = m.id AND b.user_id::text = %%s) THEN 1 ELSE 0 END AS bookmarked_by_me,
           CASE WHEN EXISTS (SELECT 1 FROM media_likes l2 WHERE l2.media_id = m.id AND l2.user_id::text = %%s) THEN 1 ELSE 0 END AS liked_by_me
    FROM media_items m
    JOIN categories c ON c.id = m.category_id
    LEFT JOIN subcategories sc ON sc.id = m.subcategory_id
    JOIN users u ON u.id = m.user_id
    %s
    ORDER BY %s
    LIMIT %%s OFFSET %%s
  ]], where, order_sql)

  local rows, err = db.fetchall(sql, unpack(sql_params))
  if err then return nil, err end
  attach_media_subcategories(rows)
  for _, row in ipairs(rows) do decode_media_row(row, viewer_can_open_adult, req) end
  return rows
end

-- GET /api/feed/signal?kind=following|liked -- a cheap "has this feed
-- actually changed" check for FeedPage.jsx's background poll
-- (useLiveRefresh, every ~20s) to call BEFORE paying for a full
-- fetch_media_feed-shaped query. That query's SELECT list costs a
-- correlated subquery per row (like_count/comment_count/bookmarked_by_me/
-- liked_by_me) and two JOINs purely to decorate rows nobody looks at again
-- if nothing actually changed since the last poll -- at N concurrent
-- pollers every ~20s, that's a steady floor of full-feed-cost queries
-- against a Postgres instance shared cluster-wide with the Discord bot
-- fleet/SwarmPanel/Aria, even when every single poll comes back identical.
--
-- Deliberately a separate, duplicated WHERE-clause build rather than a
-- factor-out of fetch_media_feed's -- same rationale fetch_media_by_id's
-- own header comment gives for not factoring out of list_media: avoids
-- risking a regression in the already-verified, already-deployed heavy
-- query for the sake of this cheap sibling.
--
-- count+MAX(created_at) catches new/removed posts (the case that actually
-- changes what a viewer sees in their feed) but NOT a like/comment landing
-- on an already-visible post, since neither touches media_items at all --
-- an accepted tradeoff: the full per-row query already only existed to
-- decorate exactly those two counts, so the one case this signal can't see
-- is also the one the audit that led to this endpoint flagged as the
-- actual cost driver. A like/comment still shows up the moment anything
-- ELSE changes the feed, or on the viewer's own next real page load.
function M.feed_signal(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local viewer0 = tostring(user.id)
  local kind = req.query and req.query.kind == "liked" and "liked" or "following"

  local viewer_can_open_adult = nn(user.age_verified_at) ~= nil and user.adult_content_consent

  local clauses = {
    "m.deleted_at IS NULL",
    "(m.visibility='public' OR m.user_id=%s)",
    "(m.publish_at IS NULL OR m.publish_at <= now() OR m.user_id=%s)",
    "m.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id=%s)",
  }
  local params = { viewer0, viewer0, viewer0 }
  if not viewer_can_open_adult then
    clauses[#clauses + 1] = "m.is_adult=false"
  end
  if kind == "liked" then
    clauses[#clauses + 1] = "EXISTS (SELECT 1 FROM media_likes ml WHERE ml.media_id=m.id AND ml.user_id=%s)"
    params[#params + 1] = viewer0
  else
    clauses[#clauses + 1] = "m.user_id IN (SELECT followed_id FROM user_follows WHERE follower_id=%s)"
    params[#params + 1] = viewer0
  end

  local sql = "SELECT COUNT(*) AS count, MAX(m.created_at) AS latest FROM media_items m WHERE "
    .. table.concat(clauses, " AND ")
  local row, err = db.fetchone(sql, unpack(params))
  if err then return 500, { detail = "Query failed: " .. tostring(err) } end
  return 200, { count = db.toint(row and row.count, 0), latest = row and nn(row.latest) }
end

-- GET /api/feed/following -- confirmed live-404ing: FeedPage.jsx (routed at
-- /following) has always called this endpoint, but it was never registered
-- in main.lua. Same "shipped in React, never ported to Lua" gap this
-- project has repeatedly found (login/register, /admin, social routes,
-- site background all had the same shape).
function M.feed_following(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local viewer0 = tostring(user.id)
  local q = req.query or {}
  local limit = bounded_limit(q.limit, 60)
  local offset = bounded_offset(q.offset)
  local rows, err = fetch_media_feed(
    req, viewer0,
    "m.user_id IN (SELECT followed_id FROM user_follows WHERE follower_id=%s)", { viewer0 },
    "m.pinned_at DESC NULLS LAST, m.created_at DESC", limit, offset
  )
  if err then return 500, { detail = "Query failed: " .. tostring(err) } end
  return 200, { media = arr(rows), limit = limit, offset = offset }
end

-- GET /api/me/likes -- same dead-endpoint shape as feed_following above:
-- FeedPage.jsx's mode="liked" variant (routed at /liked) has always called
-- this, also never registered.
function M.feed_liked(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local viewer0 = tostring(user.id)
  local q = req.query or {}
  local limit = bounded_limit(q.limit, 60)
  local offset = bounded_offset(q.offset)
  local rows, err = fetch_media_feed(
    req, viewer0,
    "EXISTS (SELECT 1 FROM media_likes ml WHERE ml.media_id=m.id AND ml.user_id=%s)", { viewer0 },
    "m.pinned_at DESC NULLS LAST, m.created_at DESC", limit, offset
  )
  if err then return 500, { detail = "Query failed: " .. tostring(err) } end
  return 200, { media = arr(rows), limit = limit, offset = offset }
end

local TRENDING_WINDOWS = { ["1"] = true, ["7"] = true, ["30"] = true }

-- GET /api/media/trending?days=N&limit=N -- same dead-endpoint shape again:
-- TrendingPage.jsx (routed at /trending) has always called this with a
-- day-window param; never registered. Distinct from list_media's own
-- `sort=trending` (added earlier this pass) -- that one is an all-time,
-- age-decayed ranking with no window; the frontend never actually calls it
-- and always expected this dedicated windowed endpoint instead, per its own
-- lede text ("ranked by views, likes, and comments within the selected
-- window") -- no age-decay needed here since the window itself bounds
-- recency.
function M.media_trending(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local q = req.query or {}
  local days = TRENDING_WINDOWS[tostring(q.days or "7")] and tostring(q.days or "7") or "7"
  local limit = bounded_limit(q.limit, 30)
  local rows, err = fetch_media_feed(
    req, viewer_id,
    "m.created_at > now() - (%s || ' days')::interval", { days },
    "(m.views + (SELECT COUNT(DISTINCT lk.user_id) FROM media_likes lk WHERE lk.media_id = m.id) * 3 + (SELECT COUNT(*) FROM media_comments cmc WHERE cmc.media_id = m.id) * 2) DESC, m.created_at DESC",
    limit, 0
  )
  if err then return 500, { detail = "Query failed: " .. tostring(err) } end
  return 200, { media = arr(rows), days = tonumber(days), limit = limit }
end

-- ---------------------------------------------------------------------------
-- GET /api/feed/for-you -- personalized ranked feed. New feature,
-- 2026-10-11: feed_following/feed_liked are plain filters (exactly the
-- people you follow / exactly what you've liked, in strict recency order)
-- and feed_signal is just a "new since last check" counter -- nothing
-- before this blended multiple signals into an actual ranking.
--
-- Two cheap pre-queries (the viewer's followed-user ids and their top
-- liked tags) feed a single ORDER BY expression on top of
-- fetch_media_feed's already-verified, already-deployed base query --
-- same division of labor list_media/media_trending/leaderboard already
-- use: Postgres does the ranking, Lua only shapes the inputs to it.
--
-- Own posts are NOT excluded: confirmed live 2026-10-11, every single
-- public post on this deployment belongs to the site owner (a one-creator
-- gallery in practice, not a populated multi-creator feed) -- excluding
-- the viewer's own posts would make this return nothing at all for the one
-- account that would ever call it. Still genuinely useful there: it
-- resurfaces older posts matching the viewer's own like/tag history
-- (rediscovery) ranked above fresher-but-less-matching ones. If/when other
-- creators' public posts exist, the follow/tag/engagement signals rank
-- those exactly the same way -- nothing here assumes a single-creator
-- library, it just doesn't special-case the self-exclusion a populated
-- multi-creator feed would usually want.
--
-- Score = (follow bonus + tag-affinity bonus + engagement) / age-in-days,
-- i.e. recency-decayed rather than a hard recency cutoff -- a post from
-- someone you follow or on a topic you like stays competitive for days,
-- not just minutes, while an old post with no signal still eventually
-- sinks below fresher ones with equal signal.
function M.feed_for_you(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local viewer0 = tostring(user.id)
  local limit = bounded_limit(req.query.limit, 30)
  local offset = bounded_offset(req.query.offset)

  local followed_rows = db.fetchall("SELECT followed_id FROM user_follows WHERE follower_id=%s", viewer0)
  local followed_ids = {}
  for _, row in ipairs(followed_rows or {}) do
    followed_ids[#followed_ids + 1] = tostring(db.toint(row.followed_id, row.followed_id))
  end
  local followed_csv = #followed_ids > 0 and table.concat(followed_ids, ",") or "-1"

  local tag_rows = db.fetchall(
    [[
      SELECT tag, COUNT(*) AS n
      FROM media_likes ml
      JOIN media_items m ON m.id = ml.media_id AND m.deleted_at IS NULL
      CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(m.tags::jsonb, '[]'::jsonb)) AS tag
      WHERE ml.user_id=%s
      GROUP BY tag
      ORDER BY n DESC
      LIMIT 8
    ]],
    viewer0
  )
  local tag_literals = {}
  for _, row in ipairs(tag_rows or {}) do
    -- Standard SQL single-quote escaping for a literal going straight into
    -- the ARRAY[...] constructor below -- tags are normalized to a narrow
    -- charset at upload time (normalize_upload_tag), but escaping
    -- defensively costs nothing and this is the one place a tag's raw text
    -- is spliced into SQL rather than bound as a query parameter.
    tag_literals[#tag_literals + 1] = "'" .. tostring(row.tag):gsub("'", "''") .. "'"
  end
  local tags_array_sql = #tag_literals > 0
    and ("ARRAY[" .. table.concat(tag_literals, ",") .. "]::text[]")
    or "ARRAY[]::text[]"

  -- NOT `like_count`/`comment_count` (fetch_media_feed's own SELECT-list
  -- aliases for these exact subqueries) -- confirmed live against this
  -- deployment's Postgres: an ORDER BY expression may reference an output
  -- column's alias only when the ENTIRE ORDER BY item is that bare
  -- identifier, not when it's embedded inside a larger expression like
  -- `like_count * 3`. Using the alias there 500s with "column ... does not
  -- exist". Re-stating both subqueries inline instead -- same fix
  -- media_trending's own ORDER BY already applies for the identical reason
  -- (see its header comment).
  local order_sql = string.format(
    [[
      ((CASE WHEN m.user_id IN (%s) THEN 50 ELSE 0 END)
        + (CASE WHEN m.tags IS NOT NULL AND m.tags::jsonb ?| %s THEN 20 ELSE 0 END)
        + (m.views * 0.05
           + (SELECT COUNT(DISTINCT lk.user_id) FROM media_likes lk WHERE lk.media_id = m.id) * 3
           + (SELECT COUNT(*) FROM media_comments cmc WHERE cmc.media_id = m.id) * 2))
      / (1 + EXTRACT(EPOCH FROM (now() - m.created_at)) / 86400.0) DESC,
      m.created_at DESC
    ]],
    followed_csv, tags_array_sql
  )

  local rows, err = fetch_media_feed(req, viewer0, nil, nil, order_sql, limit, offset)
  if err then return 500, { detail = "Query failed: " .. tostring(err) } end
  return 200, { media = arr(rows), limit = limit, offset = offset }
end

-- GET /api/leaderboard?window=7d|30d|all -- public creator ranking. Net-new
-- (no dead frontend route recovered here, unlike feed_following/feed_liked/
-- media_trending above). Ranks by the same visibility guard as list_media,
-- respecting public_profile for display name/avatar the same way
-- fetch_media_feed's SELECT list does.
local LEADERBOARD_WINDOW_DAYS = { ["7d"] = "7", ["30d"] = "30" }

function M.leaderboard(req)
  local q = req.query or {}
  local window = (q.window == "7d" or q.window == "30d" or q.window == "all") and q.window or "30d"
  local days = LEADERBOARD_WINDOW_DAYS[window]
  -- Applied identically to the main aggregate AND both like-count subqueries
  -- below, so "7-day leaderboard" consistently means "views/likes/posts from
  -- posts created in the last 7 days" rather than mixing an all-time like
  -- count into a windowed view count.
  local main_window_clause = days and "AND m.created_at > now() - (%s || ' days')::interval" or ""
  local sub_window_clause = days and "AND lm.created_at > now() - (%s || ' days')::interval" or ""

  local sql = string.format([[
    SELECT u.id, u.username,
           CASE WHEN u.public_profile THEN u.display_name ELSE u.username END AS display_name,
           CASE WHEN u.public_profile THEN u.avatar_path ELSE NULL END AS user_avatar_path,
           u.profile_color, u.public_profile,
           COALESCE(SUM(m.views), 0) AS total_views,
           COUNT(DISTINCT m.id) AS post_count,
           (SELECT COUNT(*) FROM media_likes l
            JOIN media_items lm ON lm.id = l.media_id AND lm.deleted_at IS NULL
            WHERE lm.user_id = u.id %s) AS total_likes
    FROM media_items m
    JOIN users u ON u.id = m.user_id
    WHERE m.deleted_at IS NULL AND m.visibility='public'
      AND (m.publish_at IS NULL OR m.publish_at <= now())
      %s
    GROUP BY u.id
    ORDER BY (COALESCE(SUM(m.views), 0) + (
      SELECT COUNT(*) FROM media_likes l
      JOIN media_items lm ON lm.id = l.media_id AND lm.deleted_at IS NULL
      WHERE lm.user_id = u.id %s
    ) * 3) DESC
    LIMIT 25
  ]], sub_window_clause, main_window_clause, sub_window_clause)

  local params = {}
  if days then params = { days, days, days } end
  local rows, err = db.fetchall(sql, unpack(params))
  if err then return 500, { detail = "Query failed: " .. tostring(err) } end

  local origin = request_origin(req)
  for _, row in ipairs(rows) do
    row.id = db.toint(row.id, row.id)
    row.total_views = db.toint(row.total_views, 0)
    row.post_count = db.toint(row.post_count, 0)
    row.total_likes = db.toint(row.total_likes, 0)
    row.public_profile = db.tobool(row.public_profile)
    if row.user_avatar_path and row.user_avatar_path ~= cjson.null then
      row.user_avatar_url = origin .. "/api/users/" .. row.id .. "/avatar"
    end
    row.user_avatar_path = nil
  end
  return 200, { window = window, creators = arr(rows) }
end

-- GET /api/me/media -- the Studio tab's data source. Mirrors
-- app/routers/account.py's my_media() + app/db/media.py's list_user_media()
-- (recovered from git history: 9986ab5^:app/routers/account.py +
-- app/db/media.py) -- never ported to Lua at all, confirmed live (the
-- Studio tab showed "Not found"/0 posts for an account with 15 real
-- uploads). Unlike list_media() above, this has no visibility filter at
-- all: it's the owner looking at their OWN media, so private/unlisted/
-- deleted posts are all included by design (Studio's own client-side
-- filter chips split them back out) -- only "which media_kind/adult
-- content is the viewer allowed to see" logic (decode_media_row) still
-- applies, same as everywhere else media rows get shaped.
function M.my_media(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local include_deleted = req.query.include_deleted ~= "false" and req.query.include_deleted ~= "0"
  local viewer_can_open_adult = nn(user.age_verified_at) ~= nil and user.adult_content_consent
  local viewer0 = tostring(user.id)

  local where = include_deleted and "m.user_id=%s" or "m.user_id=%s AND m.deleted_at IS NULL"
  local sql = string.format(
    [[
      SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.description, m.tags,
             m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.file_size,
             m.views, m.downloads, m.created_at, m.updated_at, m.visibility,
             m.comments_enabled, m.downloads_enabled, m.pinned_at, m.is_adult,
             m.adult_marked_by_user, m.adult_marked_by_ai, m.moderation_status, m.dominant_color, m.source_url, m.deleted_at,
             c.name AS category_name, c.slug AS category_slug,
             sc.name AS subcategory_name, sc.slug AS subcategory_slug,
             u.username, u.display_name, u.profile_color, u.public_profile,
             (SELECT COUNT(DISTINCT lk.user_id) FROM media_likes lk WHERE lk.media_id = m.id) AS like_count,
             (SELECT COUNT(*) FROM media_comments cmc WHERE cmc.media_id = m.id) AS comment_count,
             CASE WHEN EXISTS (SELECT 1 FROM media_bookmarks b WHERE b.media_id = m.id AND b.user_id::text = %%s) THEN 1 ELSE 0 END AS bookmarked_by_me,
             CASE WHEN EXISTS (SELECT 1 FROM media_likes l2 WHERE l2.media_id = m.id AND l2.user_id::text = %%s) THEN 1 ELSE 0 END AS liked_by_me
      FROM media_items m
      JOIN categories c ON c.id = m.category_id
      LEFT JOIN subcategories sc ON sc.id = m.subcategory_id
      JOIN users u ON u.id = m.user_id
      WHERE %s
      ORDER BY m.created_at DESC
      LIMIT 200
    ]],
    where
  )
  local rows, err = db.fetchall(sql, viewer0, viewer0, viewer0)
  if err then return 500, { detail = "Query failed: " .. tostring(err) } end
  attach_media_subcategories(rows)
  for _, row in ipairs(rows) do decode_media_row(row, viewer_can_open_adult, req) end
  return 200, { media = arr(rows) }
end

-- GET /api/me/on-this-day -- Studio dashboard nostalgia card: this
-- account's own posts from exactly this month/day in a previous year. No
-- visibility filter -- same "it's the owner looking at their OWN media"
-- rationale M.my_media's header comment already gives -- but DOES exclude
-- deleted posts (unlike my_media's include_deleted=true default), since
-- resurfacing something the owner deliberately deleted isn't "nostalgia,"
-- it's a bug. EXTRACT(MONTH/DAY FROM ...) rather than a date-range compare:
-- a plain `created_at::date = (now() - interval '1 year')::date` style
-- comparison would have to repeat once per year to look back more than
-- one year, where EXTRACT matches every past year in one pass. Feb 29 on
-- a non-leap "today" simply matches nothing that year, which is correct
-- (there's no Feb 29 to compare it to), not a bug to special-case around.
function M.on_this_day(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local viewer_can_open_adult = nn(user.age_verified_at) ~= nil and user.adult_content_consent
  local viewer0 = tostring(user.id)

  local sql = string.format(
    [[
      SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.description, m.tags,
             m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.file_size,
             m.views, m.downloads, m.created_at, m.updated_at, m.visibility,
             m.comments_enabled, m.downloads_enabled, m.pinned_at, m.is_adult,
             m.adult_marked_by_user, m.adult_marked_by_ai, m.moderation_status, m.dominant_color, m.source_url,
             c.name AS category_name, c.slug AS category_slug,
             sc.name AS subcategory_name, sc.slug AS subcategory_slug,
             u.username, u.display_name, u.profile_color, u.public_profile,
             (SELECT COUNT(DISTINCT lk.user_id) FROM media_likes lk WHERE lk.media_id = m.id) AS like_count,
             (SELECT COUNT(*) FROM media_comments cmc WHERE cmc.media_id = m.id) AS comment_count,
             CASE WHEN EXISTS (SELECT 1 FROM media_bookmarks b WHERE b.media_id = m.id AND b.user_id::text = %%s) THEN 1 ELSE 0 END AS bookmarked_by_me,
             CASE WHEN EXISTS (SELECT 1 FROM media_likes l2 WHERE l2.media_id = m.id AND l2.user_id::text = %%s) THEN 1 ELSE 0 END AS liked_by_me,
             EXTRACT(YEAR FROM m.created_at)::int AS years_ago_source
      FROM media_items m
      JOIN categories c ON c.id = m.category_id
      LEFT JOIN subcategories sc ON sc.id = m.subcategory_id
      JOIN users u ON u.id = m.user_id
      WHERE m.user_id=%%s AND m.deleted_at IS NULL
        AND EXTRACT(MONTH FROM m.created_at) = EXTRACT(MONTH FROM now())
        AND EXTRACT(DAY FROM m.created_at) = EXTRACT(DAY FROM now())
        AND EXTRACT(YEAR FROM m.created_at) < EXTRACT(YEAR FROM now())
      ORDER BY m.created_at DESC
      LIMIT 40
    ]]
  )
  local rows, err = db.fetchall(sql, viewer0, viewer0, viewer0)
  if err then return 500, { detail = "Query failed: " .. tostring(err) } end
  attach_media_subcategories(rows)
  local this_year = tonumber(os.date("*t").year)
  for _, row in ipairs(rows) do
    decode_media_row(row, viewer_can_open_adult, req)
    row.years_ago = this_year - db.toint(row.years_ago_source, this_year)
    row.years_ago_source = nil
  end
  return 200, { media = arr(rows) }
end

-- GET /api/me/stats -- Creator analytics dashboard data source. Two parts:
-- (1) top_posts: the creator's own non-deleted media ranked by views, same
-- join shape as M.my_media above (likes/comments/bookmarks) just re-ordered
-- and capped smaller since this is a "top N" table, not the full Studio list.
-- (2) daily_new_viewers: a day-bucketed count of media_views rows (the
-- per-viewer-ever dedup table backing the view-count-dedup fix) for the
-- last 30 days across all of this creator's media. This is "unique viewer
-- growth," NOT "total views" -- media_views has one row per viewer per
-- media item, ever (PRIMARY KEY (media_id, viewer_key)), so it can't count
-- repeat views; label it accordingly in the UI.
-- Extracted so the weekly Discord digest (digest.lua) can call this from a
-- background loop with no real HTTP `req` -- only needs a raw user id and an
-- origin string for building absolute thumb URLs (avoids depending on
-- with_urls()/request_origin(), which both require a real req.headers).
local function creator_stats_for(user_id, origin)
  local viewer0 = tostring(user_id)

  local top_posts, err1 = db.fetchall([[
    SELECT m.id, m.title, m.media_kind, m.mime_type, m.original_filename, m.storage_path,
           m.views, m.downloads, m.created_at, m.updated_at, m.visibility,
           COUNT(DISTINCT l.user_id) AS like_count,
           COUNT(DISTINCT b.user_id) AS save_count,
           COUNT(DISTINCT cm.id) AS comment_count
    FROM media_items m
    LEFT JOIN media_likes l ON l.media_id = m.id
    LEFT JOIN media_bookmarks b ON b.media_id = m.id
    LEFT JOIN media_comments cm ON cm.media_id = m.id
    WHERE m.user_id = %s AND m.deleted_at IS NULL
    GROUP BY m.id
    ORDER BY m.views DESC, m.created_at DESC
    LIMIT 20
  ]], viewer0)
  if err1 then return nil, err1 end
  for _, row in ipairs(top_posts) do
    row.id = db.toint(row.id, row.id)
    row.views = db.toint(row.views, 0)
    row.downloads = db.toint(row.downloads, 0)
    row.like_count = db.toint(row.like_count, 0)
    row.save_count = db.toint(row.save_count, 0)
    row.comment_count = db.toint(row.comment_count, 0)
    row.thumb_url = M.thumb_url_for(origin, row.id, row.media_kind, row.updated_at)
  end

  local daily_new_viewers, err2 = db.fetchall([[
    SELECT date_trunc('day', mv.created_at) AS day, COUNT(*) AS new_viewers
    FROM media_views mv
    JOIN media_items m ON m.id = mv.media_id
    WHERE m.user_id = %s AND mv.created_at > now() - interval '30 days'
    GROUP BY 1
    ORDER BY 1
  ]], viewer0)
  if err2 then return nil, err2 end
  for _, row in ipairs(daily_new_viewers) do
    row.new_viewers = db.toint(row.new_viewers, 0)
  end

  local totals = db.fetchone([[
    SELECT COALESCE(SUM(m.views), 0) AS total_views,
           COUNT(DISTINCT l.user_id || ':' || l.media_id) AS total_likes,
           COUNT(DISTINCT b.user_id || ':' || b.media_id) AS total_saves
    FROM media_items m
    LEFT JOIN media_likes l ON l.media_id = m.id
    LEFT JOIN media_bookmarks b ON b.media_id = m.id
    WHERE m.user_id = %s AND m.deleted_at IS NULL
  ]], viewer0)

  return {
    top_posts = arr(top_posts),
    daily_new_viewers = arr(daily_new_viewers),
    totals = {
      total_views = db.toint(totals and totals.total_views, 0),
      total_likes = db.toint(totals and totals.total_likes, 0),
      total_saves = db.toint(totals and totals.total_saves, 0),
    },
  }
end
M.creator_stats_for = creator_stats_for

function M.creator_stats(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local result, err = creator_stats_for(user.id, request_origin(req))
  if not result then return 500, { detail = "Query failed: " .. tostring(err) } end
  return 200, result
end

-- GET /api/me/year-recap?year=YYYY -- personalized year-in-review. New
-- feature, 2026-10-11, built on the same aggregate-query style as
-- creator_stats_for above, scoped to one calendar year and cached (see
-- pg_add_year_recap_cache.sql) since it's only worth computing once per
-- user per year, not on every view -- a past year's recap can never
-- change, so it's served from cache unconditionally; the CURRENT
-- (in-progress) year's cache is only trusted for an hour before
-- recomputing, same staleness tolerance the rest of this file's
-- request-time caching already uses (see background_candidate_rows for
-- the identical pattern).
function M.year_recap(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local current_year = tonumber(os.date("!%Y"))
  local year = tonumber(req.query.year) or current_year
  if year < 2020 or year > current_year then return 400, { detail = "Invalid year." } end
  local viewer0 = tostring(user.id)
  local year_str = tostring(year)

  local cached = db.fetchone(
    "SELECT payload, computed_at FROM user_year_recap_cache WHERE user_id=%s AND year=%s",
    viewer0, year_str
  )
  if cached then
    if year < current_year then
      return 200, cjson.decode(cached.payload)
    end
    local age_row = db.fetchone("SELECT (now() - %s::timestamp < interval '1 hour') AS fresh", cached.computed_at)
    if age_row and db.tobool(age_row.fresh) then
      return 200, cjson.decode(cached.payload)
    end
  end

  local origin = request_origin(req)

  local totals = db.fetchone(
    [[
      SELECT COUNT(*) AS post_count,
             COALESCE(SUM(m.views), 0) AS total_views,
             COUNT(DISTINCT l.user_id || ':' || l.media_id) AS total_likes_received,
             COUNT(DISTINCT cm.id) AS total_comments_received
      FROM media_items m
      LEFT JOIN media_likes l ON l.media_id = m.id
      LEFT JOIN media_comments cm ON cm.media_id = m.id
      WHERE m.user_id=%s AND m.deleted_at IS NULL AND EXTRACT(YEAR FROM m.created_at) = %s
    ]],
    viewer0, year_str
  )

  local top_post = db.fetchone(
    [[
      SELECT m.id, m.title, m.media_kind, m.views, m.updated_at,
             COUNT(DISTINCT l.user_id) AS like_count
      FROM media_items m
      LEFT JOIN media_likes l ON l.media_id = m.id
      WHERE m.user_id=%s AND m.deleted_at IS NULL AND EXTRACT(YEAR FROM m.created_at) = %s
      GROUP BY m.id
      ORDER BY like_count DESC, m.views DESC
      LIMIT 1
    ]],
    viewer0, year_str
  )

  local top_tag_rows = db.fetchall(
    [[
      SELECT tag, COUNT(*) AS n
      FROM media_items m
      CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(m.tags::jsonb, '[]'::jsonb)) AS tag
      WHERE m.user_id=%s AND m.deleted_at IS NULL AND EXTRACT(YEAR FROM m.created_at) = %s
      GROUP BY tag ORDER BY n DESC LIMIT 1
    ]],
    viewer0, year_str
  )

  local likes_given = db.fetchone(
    [[
      SELECT COUNT(*) AS n FROM media_likes l
      JOIN media_items m ON m.id = l.media_id
      WHERE l.user_id=%s AND EXTRACT(YEAR FROM l.created_at) = %s
    ]],
    viewer0, year_str
  )

  local joined_row = db.fetchone("SELECT created_at FROM users WHERE id=%s", viewer0)

  local payload = {
    year = year,
    post_count = db.toint(totals and totals.post_count, 0),
    total_views = db.toint(totals and totals.total_views, 0),
    total_likes_received = db.toint(totals and totals.total_likes_received, 0),
    total_comments_received = db.toint(totals and totals.total_comments_received, 0),
    likes_given = db.toint(likes_given and likes_given.n, 0),
    top_tag = (top_tag_rows and top_tag_rows[1] and top_tag_rows[1].tag) or cjson.null,
    member_since = (joined_row and joined_row.created_at) or cjson.null,
    top_post = cjson.null,
  }
  if top_post then
    local top_post_id = db.toint(top_post.id, top_post.id)
    payload.top_post = {
      id = top_post_id,
      title = top_post.title,
      views = db.toint(top_post.views, 0),
      like_count = db.toint(top_post.like_count, 0),
      thumb_url = M.thumb_url_for(origin, top_post_id, top_post.media_kind, top_post.updated_at),
    }
  end

  db.execute(
    [[
      INSERT INTO user_year_recap_cache (user_id, year, payload, computed_at)
      VALUES (%s, %s, %s, now())
      ON CONFLICT (user_id, year) DO UPDATE SET payload=EXCLUDED.payload, computed_at=now()
    ]],
    viewer0, year_str, cjson.encode(payload)
  )

  return 200, payload
end

-- ---------------------------------------------------------------------------
-- Single media item: detail / like / bookmark / comment / react
-- Mirrors app/routers/media.py's media_detail/like_media/bookmark_media/
-- add_comment/react_to_media + app/db/media.py's get_media/list_comments/
-- list_reactions.
-- ---------------------------------------------------------------------------

-- Single-row equivalent of list_media's own SELECT (mirrors app/db/media.py's
-- get_media()). Kept as a separate literal query rather than factored out of
-- list_media's already-verified SQL, to avoid risking a regression there.
local function fetch_media_by_id(media_id, viewer0)
  local row = db.fetchone([[
    SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.description, m.tags,
           m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.file_size,
           m.views, m.downloads, m.created_at, m.updated_at, m.visibility,
           m.comments_enabled, m.downloads_enabled, m.pinned_at, m.is_adult,
           m.adult_marked_by_user, m.adult_marked_by_ai, m.moderation_status, m.dominant_color, m.source_url,
           m.youtube_video_id,
           m.deleted_at, m.publish_at,
           c.name AS category_name, c.slug AS category_slug,
           sc.name AS subcategory_name, sc.slug AS subcategory_slug,
           u.username,
           CASE WHEN u.public_profile OR u.id::text=%s THEN u.display_name ELSE u.username END AS display_name,
           CASE WHEN u.public_profile OR u.id::text=%s THEN u.bio ELSE NULL END AS user_bio,
           CASE WHEN u.public_profile OR u.id::text=%s THEN u.website_url ELSE NULL END AS user_website_url,
           CASE WHEN u.public_profile OR u.id::text=%s THEN u.avatar_path ELSE NULL END AS user_avatar_path,
           u.profile_color, u.public_profile,
           (SELECT COUNT(DISTINCT lk.user_id) FROM media_likes lk WHERE lk.media_id = m.id) AS like_count,
           (SELECT COUNT(*) FROM media_comments cmc WHERE cmc.media_id = m.id) AS comment_count,
           CASE WHEN EXISTS (SELECT 1 FROM media_bookmarks b WHERE b.media_id = m.id AND b.user_id::text = %s) THEN 1 ELSE 0 END AS bookmarked_by_me,
           CASE WHEN EXISTS (SELECT 1 FROM media_likes l2 WHERE l2.media_id = m.id AND l2.user_id::text = %s) THEN 1 ELSE 0 END AS liked_by_me
    FROM media_items m
    JOIN categories c ON c.id = m.category_id
    LEFT JOIN subcategories sc ON sc.id = m.subcategory_id
    JOIN users u ON u.id = m.user_id
    WHERE m.id = %s
  ]], viewer0, viewer0, viewer0, viewer0, viewer0, viewer0, tostring(media_id))
  if row then attach_media_subcategories({ row }) end
  return row
end

local function viewer_adult_allowed(viewer_id)
  if not viewer_id then return false end
  local viewer = get_user(viewer_id)
  return viewer ~= nil and nn(viewer.age_verified_at) ~= nil and viewer.adult_content_consent
end

-- ---------------------------------------------------------------------------
-- Resume/continue-watching. New feature, 2026-10-11: nothing tracked
-- playback position before this -- reopening a video always started over
-- from 0.
--
-- POST /api/media/:media_id/watch-progress { position_seconds,
-- duration_seconds } -- called periodically by the player (every ~5-10s
-- while playing, and on unload/navigation-away), not on every timeupdate
-- tick, so write volume stays low regardless of how it's wired up client-
-- side.
--
-- Optimization: trivial progress is never persisted. The first 5 seconds
-- of a video isn't worth resuming into, and a near-finished watch (>=95%)
-- should fall off "continue watching" entirely rather than be saved and
-- then filtered back out on every read -- both cases DELETE any existing
-- row instead of writing a value nothing would ever show, which also
-- means a video a viewer finishes naturally stops cluttering their
-- continue-watching list without a separate cleanup pass.
function M.save_watch_progress(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local payload = json_body(req)
  local position = tonumber(payload.position_seconds)
  local duration = tonumber(payload.duration_seconds)
  if not position or position < 0 then return 400, { detail = "position_seconds is required." } end

  local near_start = position < 5
  local near_end = duration and duration > 0 and (position / duration) >= 0.95
  if near_start or near_end then
    db.execute("DELETE FROM media_watch_progress WHERE user_id=%s AND media_id=%s", user.id, tostring(media_id))
    return 200, { saved = false, cleared = true }
  end

  db.execute(
    [[
      INSERT INTO media_watch_progress (user_id, media_id, position_seconds, duration_seconds, updated_at)
      VALUES (%s, %s, %s, %s, now())
      ON CONFLICT (user_id, media_id) DO UPDATE SET
        position_seconds=EXCLUDED.position_seconds,
        duration_seconds=EXCLUDED.duration_seconds,
        updated_at=now()
    ]],
    user.id, tostring(media_id), tostring(position), duration and tostring(duration) or nil
  )
  return 200, { saved = true }
end

-- GET /api/media/:media_id/watch-progress -- the player calls this once on
-- load to decide whether to offer/jump to a resume point.
function M.watch_progress(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local row = db.fetchone(
    "SELECT position_seconds, duration_seconds, updated_at FROM media_watch_progress WHERE user_id=%s AND media_id=%s",
    user.id, tostring(media_id)
  )
  if not row then return 200, { position_seconds = cjson.null, duration_seconds = cjson.null } end
  return 200, {
    position_seconds = tonumber(row.position_seconds),
    duration_seconds = row.duration_seconds and tonumber(row.duration_seconds) or cjson.null,
    updated_at = row.updated_at,
  }
end

-- GET /api/me/continue-watching -- the "Continue Watching" rail. Reuses
-- fetch_media_by_id + decode_media_row (the exact shape every other
-- single-item view already returns -- thumbnail/category/user fields
-- included) rather than hand-rolling a second, narrower media shape just
-- for this list. A per-row lookup, not a single joined query: this list is
-- capped at a small limit and read far less often than it's written
-- (every few seconds of playback vs. once per rail view), so trading a
-- handful of extra cheap-by-primary-key queries for reusing the already-
-- correct decoration logic is the right side of that tradeoff here.
function M.continue_watching(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local viewer0 = tostring(user.id)
  local limit = bounded_limit(req.query.limit, 12, 30)
  local adult_allowed = viewer_adult_allowed(viewer0)

  local progress_rows = db.fetchall(
    [[
      SELECT wp.media_id, wp.position_seconds, wp.duration_seconds, wp.updated_at
      FROM media_watch_progress wp
      JOIN media_items m ON m.id = wp.media_id AND m.deleted_at IS NULL
      WHERE wp.user_id=%s
      ORDER BY wp.updated_at DESC
      LIMIT %s
    ]],
    viewer0, tostring(limit)
  )

  local results = {}
  for _, p in ipairs(progress_rows or {}) do
    local item = fetch_media_by_id(db.toint(p.media_id, p.media_id), viewer0)
    if item then
      decode_media_row(item, adult_allowed, req)
      item.watch_position_seconds = tonumber(p.position_seconds)
      item.watch_duration_seconds = p.duration_seconds and tonumber(p.duration_seconds) or cjson.null
      item.watch_updated_at = p.updated_at
      results[#results + 1] = item
    end
  end
  return 200, { media = results, limit = limit }
end

-- GET /api/media/random -- confirmed live-404ing: DiscoverPage.jsx's
-- "Surprise me" button has always called this, never registered/ported.
-- Picks one random id the viewer is actually allowed to see (same
-- visibility/block/adult-content rules as every other browsing surface),
-- then reuses fetch_media_by_id + decode_media_row for the response shape
-- every other single-item route already returns -- the frontend only
-- reads `data.media.id` (navigates to the detail page, which re-fetches
-- the full item itself), but returning the full decorated row costs
-- nothing extra and keeps this endpoint consistent with its siblings.
-- ORDER BY random() is a full-table sort, not an index scan -- fine at
-- this site's current scale (~3300 public rows) and simpler/more exactly
-- uniform than a two-query id-range-then-pick approach; revisit only if
-- the table grows by orders of magnitude.
function M.media_random(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local viewer0 = viewer_id or "0"
  local viewer_can_open_adult = viewer_adult_allowed(viewer_id)

  local clauses = {
    "m.deleted_at IS NULL",
    "m.visibility='public'",
    "(m.publish_at IS NULL OR m.publish_at <= now())",
  }
  local params = {}
  if viewer_id then
    clauses[#clauses + 1] = "m.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id=%s)"
    params[#params + 1] = viewer0
  end
  if not viewer_can_open_adult then
    clauses[#clauses + 1] = "m.is_adult=false"
  end

  local sql = "SELECT m.id FROM media_items m WHERE " .. table.concat(clauses, " AND ") .. " ORDER BY random() LIMIT 1"
  local row, err = db.fetchone(sql, unpack(params))
  if err then return 500, { detail = "Query failed: " .. tostring(err) } end
  if not row then return 404, { detail = "No media available." } end

  local item = fetch_media_by_id(db.toint(row.id, row.id), viewer0)
  if not item then return 404, { detail = "Media not found." } end
  return 200, { media = decode_media_row(item, viewer_can_open_adult, req) }
end

-- "Related media": scored by tag overlap (reusing the same jsonb `?|`
-- helper the boolean tag search uses) OR-ed with same-category, ranked by
-- overlap count with category match as a tiebreaker. Falls back to the
-- original category-only/newest behavior when the seed post has no tags,
-- so an untagged post still gets a non-empty related list. Deliberately
-- skips perceptual-hash comparison here -- find_possible_duplicates
-- already showed that's expensive even scoped to a single user's 1500
-- most recent uploads; not worth it for a "you might also like" widget
-- spanning every user's media.
--
-- Shared by M.media_detail (the on-page rail, limit=12/offset=0) and
-- M.similar_media (a real "More like this" paginated feed -- previously
-- a second, independently-written, slightly-worse copy of this exact
-- logic that nothing in either frontend ever actually called).
local function compute_similar_media(req, media_id, item, adult_allowed, limit, offset)
  local seed_tags = {}
  if item.tags and item.tags ~= cjson.null then
    local ok, decoded = pcall(cjson.decode, item.tags)
    if ok and type(decoded) == "table" then seed_tags = decoded end
  end

  local similar_sql, similar_params
  if #seed_tags > 0 then
    local where_tag_parts, where_tag_params = {}, {}
    append_tag_array_clause(where_tag_parts, where_tag_params, seed_tags, "m.tags", false, "any")

    local order_placeholders, order_tag_params = {}, {}
    for _, tag in ipairs(seed_tags) do
      order_placeholders[#order_placeholders + 1] = "%s"
      order_tag_params[#order_tag_params + 1] = tag
    end
    local order_tag_array_sql = "ARRAY[" .. table.concat(order_placeholders, ",") .. "]"

    similar_sql = string.format([[
      SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.media_kind, m.mime_type,
             m.original_filename, m.storage_path, m.is_adult, m.created_at, m.views
      FROM media_items m
      WHERE m.id != %%s AND m.deleted_at IS NULL AND m.visibility='public'
        AND (m.publish_at IS NULL OR m.publish_at <= now())
        AND (m.category_id = %%s OR %s)
        %s
      ORDER BY
        (CASE WHEN m.category_id = %%s THEN 1 ELSE 0 END)
        + (SELECT count(*) FROM jsonb_array_elements_text(m.tags::jsonb) t WHERE t = ANY(%s::text[])) DESC,
        m.created_at DESC
      LIMIT %%s OFFSET %%s
    ]], where_tag_parts[1], adult_allowed and "" or "AND m.is_adult=false", order_tag_array_sql)

    similar_params = { tostring(media_id), tostring(item.category_id) }
    for _, p in ipairs(where_tag_params) do similar_params[#similar_params + 1] = p end
    similar_params[#similar_params + 1] = tostring(item.category_id)
    for _, p in ipairs(order_tag_params) do similar_params[#similar_params + 1] = p end
    similar_params[#similar_params + 1] = tostring(limit)
    similar_params[#similar_params + 1] = tostring(offset)
  else
    similar_sql = string.format([[
      SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.media_kind, m.mime_type,
             m.original_filename, m.storage_path, m.is_adult, m.created_at, m.views
      FROM media_items m
      WHERE m.category_id = %%s AND m.id != %%s AND m.deleted_at IS NULL AND m.visibility='public'
        AND (m.publish_at IS NULL OR m.publish_at <= now())
        %s
      ORDER BY m.created_at DESC
      LIMIT %%s OFFSET %%s
    ]], adult_allowed and "" or "AND m.is_adult=false")
    similar_params = { tostring(item.category_id), tostring(media_id), tostring(limit), tostring(offset) }
  end
  local similar = db.fetchall(similar_sql, unpack(similar_params))
  for _, row in ipairs(similar) do
    row.id = db.toint(row.id, row.id)
    row.user_id = db.toint(row.user_id, row.user_id)
    row.category_id = db.toint(row.category_id, row.category_id)
    row.views = db.toint(row.views, 0)
    row.is_adult = db.tobool(row.is_adult)
    with_urls(req, row, adult_allowed)
  end
  attach_media_subcategories(similar)
  return similar
end

-- Mirrors _ensure_media_visible_to_viewer(): returns nil on success, or
-- (status, body) the caller should return immediately.
local function ensure_media_visible(item, viewer_id)
  if not item or nn(item.deleted_at) ~= nil then return 404, { detail = "Media not found." } end
  local owner = viewer_id and tostring(item.user_id) == tostring(viewer_id)
  if item.visibility == "private" and not owner then
    return 403, { detail = "This post is private." }
  end
  local publish_at = nn(item.publish_at)
  if publish_at and not owner then
    local row = db.fetchone("SELECT (%s::timestamp > now()) AS is_future", publish_at)
    if row and db.tobool(row.is_future) then return 404, { detail = "Media not found." } end
  end
  return nil
end

function M.media_detail(req)
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local adult_allowed = viewer_adult_allowed(viewer_id)

  local item = fetch_media_by_id(media_id, viewer_id or "0")
  local status, body = ensure_media_visible(item, viewer_id)
  if status then return status, body end
  if item.is_adult and not adult_allowed then
    return 403, { detail = "Age verification required for this 18+ post." }
  end

  -- Only credit a view the first time this viewer sees this post, ever --
  -- previously every single media_detail request incremented
  -- unconditionally (confirmed also true of the original Python backend,
  -- so not a rewrite regression, but a real reported bug either way:
  -- reopening a post, a pull-to-refresh, or the client silently retrying
  -- a request all inflated the count). viewer_key is "user:<id>" for a
  -- logged-in viewer or "ip:<address>" for an anonymous one (public posts
  -- don't require login to view, so there's no user id to key on); the
  -- media_views row's PRIMARY KEY does the actual dedup work via ON
  -- CONFLICT DO NOTHING -- views only ever increments when that INSERT
  -- actually adds a new row.
  local viewer_key = viewer_id and ("user:" .. viewer_id) or ("ip:" .. client_ip(req))
  local new_view = db.fetchone(
    "INSERT INTO media_views (media_id, viewer_key) VALUES (%s, %s) ON CONFLICT (media_id, viewer_key) DO NOTHING RETURNING media_id",
    tostring(media_id), viewer_key
  )
  if new_view then
    db.execute("UPDATE media_items SET views=views+1 WHERE id=%s", tostring(media_id))
  end

  local comments = db.fetchall([[
    SELECT cm.id, cm.media_id, cm.user_id, cm.body, cm.created_at, cm.parent_comment_id,
           u.username,
           CASE WHEN u.public_profile THEN u.display_name ELSE u.username END AS display_name,
           CASE WHEN u.public_profile THEN u.avatar_path ELSE NULL END AS user_avatar_path
    FROM media_comments cm JOIN users u ON u.id = cm.user_id
    WHERE cm.media_id = %s
    ORDER BY cm.created_at ASC
    LIMIT 80
  ]], tostring(media_id))
  for _, c in ipairs(comments) do
    c.id = db.toint(c.id, c.id)
    c.media_id = db.toint(c.media_id, c.media_id)
    c.user_id = db.toint(c.user_id, c.user_id)
    if c.parent_comment_id then c.parent_comment_id = db.toint(c.parent_comment_id, c.parent_comment_id) end
  end

  -- Per-comment reaction counts, batched as 1-2 queries total (not one per
  -- comment) -- same IN-list-over-already-fetched-ids shape
  -- attach_media_subcategories uses elsewhere in this file for the same
  -- N+1-avoidance reason.
  if #comments > 0 then
    local comment_ids, id_placeholders = {}, {}
    for i, c in ipairs(comments) do
      comment_ids[i] = tostring(c.id)
      id_placeholders[i] = "%s"
      c.reactions = { counts = {}, my_reaction = nil }
    end
    local in_list = table.concat(id_placeholders, ",")
    local cr_rows = db.fetchall(
      "SELECT comment_id, emoji, COUNT(*) AS n FROM media_comment_reactions WHERE comment_id IN (" .. in_list .. ") GROUP BY comment_id, emoji",
      unpack(comment_ids)
    )
    local counts_by_comment = {}
    for _, r in ipairs(cr_rows) do
      local cid = db.toint(r.comment_id, r.comment_id)
      counts_by_comment[cid] = counts_by_comment[cid] or {}
      counts_by_comment[cid][r.emoji] = db.toint(r.n, 0)
    end
    local mine_by_comment = {}
    if viewer_id then
      local mine_rows = db.fetchall(
        "SELECT comment_id, emoji FROM media_comment_reactions WHERE user_id=%s AND comment_id IN (" .. in_list .. ")",
        viewer_id, unpack(comment_ids)
      )
      for _, r in ipairs(mine_rows) do
        mine_by_comment[db.toint(r.comment_id, r.comment_id)] = r.emoji
      end
    end
    for _, c in ipairs(comments) do
      c.reactions.counts = counts_by_comment[c.id] or {}
      c.reactions.my_reaction = mine_by_comment[c.id]
    end
  end

  local reaction_rows = db.fetchall(
    "SELECT emoji, COUNT(*) AS n FROM media_reactions WHERE media_id=%s GROUP BY emoji ORDER BY n DESC",
    tostring(media_id)
  )
  local counts = {}
  for _, r in ipairs(reaction_rows) do counts[r.emoji] = db.toint(r.n, 0) end
  local my_reaction = nil
  if viewer_id then
    local r = db.fetchone("SELECT emoji FROM media_reactions WHERE media_id=%s AND user_id=%s", tostring(media_id), viewer_id)
    my_reaction = r and r.emoji or nil
  end

  local similar = compute_similar_media(req, media_id, item, adult_allowed, 12, 0)

  -- Personal tags (see the "Personal/private tags" section below) are
  -- private to the viewer -- only ever fetched/shown for the logged-in
  -- viewer's own tags on this post, never anyone else's, regardless of
  -- who owns the post itself.
  local personal_tags = {}
  if viewer_id then
    local rows = db.fetchall("SELECT tag FROM media_personal_tags WHERE media_id=%s AND user_id=%s ORDER BY tag", tostring(media_id), viewer_id)
    for _, row in ipairs(rows) do personal_tags[#personal_tags + 1] = row.tag end
  end

  return 200, {
    media = decode_media_row(item, adult_allowed, req),
    comments = arr(comments),
    reactions = { counts = counts, my_reaction = my_reaction },
    similar = arr(similar),
    personal_tags = arr(personal_tags),
  }
end

-- POST /api/media/:media_id/viewing -- lightweight heartbeat backing the
-- "N people viewing this now" indicator (media_active_viewers, see
-- scripts/pg_add_active_viewers.sql). Upserts this viewer's row (so a
-- repeat heartbeat from the same person/post pair updates one row instead
-- of growing one per call) and returns the current active count, where
-- "active" is a read-time age filter (last_seen_at within the last 25s --
-- a bit more than the frontend's own heartbeat interval, so a single
-- missed tick doesn't flicker someone out) rather than a separate
-- disconnect signal: closing the tab without a clean goodbye just ages
-- out on the next count instead of needing one.
function M.media_viewing_heartbeat(req)
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil

  local item = fetch_media_by_id(media_id, viewer_id or "0")
  local vstatus, vbody = ensure_media_visible(item, viewer_id)
  if vstatus then return vstatus, vbody end
  if item.is_adult and not viewer_adult_allowed(viewer_id) then
    return 403, { detail = "Age verification required for this 18+ post." }
  end

  local viewer_key = viewer_id and ("user:" .. viewer_id) or ("ip:" .. client_ip(req))
  db.execute(
    "INSERT INTO media_active_viewers (media_id, viewer_key, last_seen_at) VALUES (%s, %s, now()) ON CONFLICT (media_id, viewer_key) DO UPDATE SET last_seen_at=now()",
    tostring(media_id), viewer_key
  )

  local row = db.fetchone(
    "SELECT COUNT(*) AS n FROM media_active_viewers WHERE media_id=%s AND last_seen_at > now() - interval '25 seconds'",
    tostring(media_id)
  )
  return 200, { viewing_now = db.toint(row and row.n, 0) }
end

-- ---------------------------------------------------------------------------
-- Personal/private tags -- an idea from Romanticise (a booru-style personal
-- image database): tags visible only to the tagger, layered on top of the
-- shared public tag set, for private organization ("saw this on twitter",
-- "ref for character X") that shouldn't be public metadata on someone
-- else's (or even your own) post. Any logged-in user can personal-tag any
-- post they can already see (ensure_media_visible) -- these are private TO
-- THE TAGGER, not restricted to the post owner.
-- ---------------------------------------------------------------------------

local function clean_personal_tag(raw)
  local cleaned = trim(nn(raw) or ""):lower():gsub("%s+", " ")
  return cleaned:sub(1, 60)
end

function M.add_personal_tag(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local item = fetch_media_by_id(media_id, tostring(user.id))
  local vstatus, vbody = ensure_media_visible(item, tostring(user.id))
  if vstatus then return vstatus, vbody end

  local payload = json_body(req)
  local tag = clean_personal_tag(payload.tag)
  if tag == "" then return 400, { detail = "Tag is required." } end
  db.execute(
    "INSERT INTO media_personal_tags (media_id, user_id, tag) VALUES (%s, %s, %s) ON CONFLICT (media_id, user_id, tag) DO NOTHING",
    tostring(media_id), tostring(user.id), tag
  )
  local rows = db.fetchall("SELECT tag FROM media_personal_tags WHERE media_id=%s AND user_id=%s ORDER BY tag", tostring(media_id), tostring(user.id))
  local tags = {}
  for _, row in ipairs(rows) do tags[#tags + 1] = row.tag end
  return 200, { personal_tags = arr(tags) }
end

function M.remove_personal_tag(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local tag = clean_personal_tag(req.params.tag)
  db.execute("DELETE FROM media_personal_tags WHERE media_id=%s AND user_id=%s AND tag=%s", tostring(media_id), tostring(user.id), tag)
  local rows = db.fetchall("SELECT tag FROM media_personal_tags WHERE media_id=%s AND user_id=%s ORDER BY tag", tostring(media_id), tostring(user.id))
  local tags = {}
  for _, row in ipairs(rows) do tags[#tags + 1] = row.tag end
  return 200, { personal_tags = arr(tags) }
end

-- Lists everything the viewer has personally tagged with a given tag
-- (or, with no tag param, their full set of distinct personal tags) --
-- the "browse my own private organization" half of the feature, mirrors
-- how the public tag cloud/search work but scoped to media_personal_tags.
function M.my_personal_tags(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local tag = nn(req.query.tag)
  if tag then
    local rows = db.fetchall(
      [[
        SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.media_kind, m.mime_type,
               m.original_filename, m.storage_path, m.is_adult, m.created_at, m.views, m.visibility
        FROM media_personal_tags pt
        JOIN media_items m ON m.id = pt.media_id
        WHERE pt.user_id=%s AND pt.tag=%s AND m.deleted_at IS NULL
        ORDER BY pt.created_at DESC
        LIMIT 200
      ]],
      tostring(user.id), clean_personal_tag(tag)
    )
    local adult_allowed = viewer_adult_allowed(tostring(user.id))
    for _, row in ipairs(rows) do
      row.id = db.toint(row.id, row.id)
      row.user_id = db.toint(row.user_id, row.user_id)
      row.category_id = db.toint(row.category_id, row.category_id)
      row.views = db.toint(row.views, 0)
      row.is_adult = db.tobool(row.is_adult)
      with_urls(req, row, adult_allowed)
    end
    return 200, { media = arr(rows) }
  end
  local tag_rows = db.fetchall(
    "SELECT tag, COUNT(*) AS n FROM media_personal_tags WHERE user_id=%s GROUP BY tag ORDER BY n DESC, tag ASC",
    tostring(user.id)
  )
  for _, row in ipairs(tag_rows) do row.n = db.toint(row.n, 0) end
  return 200, { tags = arr(tag_rows) }
end

-- ---------------------------------------------------------------------------
-- "On this day" memories -- resurfaces the viewer's own uploads from
-- exactly today's month/day in a past year. Simple date-match query, no
-- background job needed (Python's/Lua's TODO.md-tracked "unported
-- background loops" are for things that need to run unattended and push
-- notifications out; this is on-demand, computed the moment a client asks).
-- ---------------------------------------------------------------------------

function M.my_memories(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local rows = db.fetchall(
    [[
      SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.media_kind, m.mime_type,
             m.original_filename, m.storage_path, m.is_adult, m.created_at, m.views, m.visibility,
             EXTRACT(YEAR FROM now())::int - EXTRACT(YEAR FROM m.created_at)::int AS years_ago
      FROM media_items m
      WHERE m.user_id=%s AND m.deleted_at IS NULL
        AND EXTRACT(MONTH FROM m.created_at) = EXTRACT(MONTH FROM now())
        AND EXTRACT(DAY FROM m.created_at) = EXTRACT(DAY FROM now())
        AND EXTRACT(YEAR FROM m.created_at) < EXTRACT(YEAR FROM now())
      ORDER BY m.created_at ASC
      LIMIT 50
    ]],
    tostring(user.id)
  )
  local adult_allowed = viewer_adult_allowed(tostring(user.id))
  for _, row in ipairs(rows) do
    row.id = db.toint(row.id, row.id)
    row.user_id = db.toint(row.user_id, row.user_id)
    row.category_id = db.toint(row.category_id, row.category_id)
    row.views = db.toint(row.views, 0)
    row.years_ago = db.toint(row.years_ago, row.years_ago)
    row.is_adult = db.tobool(row.is_adult)
    with_urls(req, row, adult_allowed)
  end
  return 200, { media = arr(rows) }
end

-- ---------------------------------------------------------------------------
-- Scoped read-only API keys -- for third-party/personal integrations (a
-- Discord bot, a personal script) that should be able to read a user's OWN
-- gallery data without handing over their real login session. Deliberately
-- NOT wired into current_user()/auth_optional() at all -- rather than
-- retrofit the entire auth stack (and risk a wiring mistake accidentally
-- granting write access through a token meant to be read-only), a key only
-- ever unlocks the small dedicated read-only surface below (right now:
-- M.my_memories-style "own media" list and the personal RSS feed in
-- pages_feeds.lua). The raw key is shown to the user exactly once, at
-- creation; only its SHA-256 hash is ever stored.
-- ---------------------------------------------------------------------------

-- Required here (not just relying on the later `local sodium =
-- require("luasodium")` further down this file, near the duplicate-
-- detection code) since these functions are defined before that point --
-- require() is cached/idempotent, so this is the same module table either
-- way, just visible from here too.
local sodium = require("luasodium")

local API_KEY_PREFIX = "gk_"

-- Exported so pages_feeds.lua's keyed personal feed can authenticate a
-- ?key= query param the same way, without duplicating the hash-and-look-up
-- logic. Returns the owning user id (string) or nil.
function M.resolve_api_key(raw_key)
  raw_key = tostring(raw_key or "")
  if raw_key:sub(1, #API_KEY_PREFIX) ~= API_KEY_PREFIX then return nil end
  local token_hash = sodium.sodium_bin2hex(sodium.crypto_hash_sha256(raw_key))
  local row = db.fetchone("SELECT id, user_id FROM api_keys WHERE token_hash=%s AND revoked_at IS NULL", token_hash)
  if not row then return nil end
  -- Now that auth_optional() (see above) resolves a key on every read-
  -- context request -- including HLS segment fetches, which can be 50-100+
  -- per video watched -- an unconditional UPDATE here would mean that many
  -- writes per video. The staleness guard keeps last_used_at meaningfully
  -- fresh (still-accurate to within a minute) while collapsing a whole
  -- streaming session down to at most one write.
  db.execute(
    "UPDATE api_keys SET last_used_at=now() WHERE id=%s AND (last_used_at IS NULL OR last_used_at < now() - interval '60 seconds')",
    tostring(db.toint(row.id, row.id))
  )
  return tostring(db.toint(row.user_id, row.user_id))
end

function M.create_api_key(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local label = trim(nn(payload.label) or "API key"):sub(1, 80)
  local raw_key = API_KEY_PREFIX .. sodium.sodium_bin2hex(sodium.randombytes_buf(24))
  local token_hash = sodium.sodium_bin2hex(sodium.crypto_hash_sha256(raw_key))
  local row, err = db.fetchone(
    "INSERT INTO api_keys (user_id, label, token_hash) VALUES (%s, %s, %s) RETURNING id, created_at",
    tostring(user.id), label, token_hash
  )
  if not row then return 500, { detail = "Could not create API key: " .. tostring(err) } end
  return 200, {
    -- Only place the raw key is ever returned -- store it now, it cannot
    -- be recovered later (only the hash persists).
    key = raw_key,
    id = db.toint(row.id, row.id),
    label = label,
    created_at = row.created_at,
  }
end

function M.list_api_keys(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local rows = db.fetchall(
    "SELECT id, label, created_at, last_used_at, revoked_at FROM api_keys WHERE user_id=%s ORDER BY created_at DESC",
    tostring(user.id)
  )
  for _, row in ipairs(rows) do row.id = db.toint(row.id, row.id) end
  return 200, { api_keys = arr(rows) }
end

function M.revoke_api_key(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local key_id = tonumber(req.params.key_id)
  if not key_id then return 404, { detail = "API key not found." } end
  db.execute("UPDATE api_keys SET revoked_at=now() WHERE id=%s AND user_id=%s AND revoked_at IS NULL", tostring(key_id), tostring(user.id))
  return 200, { ok = true }
end

function M.like_media(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local payload = json_body(req)
  local liked = payload.liked and true or false

  local item = fetch_media_by_id(media_id, tostring(user.id))
  local vstatus, vbody = ensure_media_visible(item, tostring(user.id))
  if vstatus then return vstatus, vbody end

  if liked then
    db.execute("INSERT INTO media_likes (user_id, media_id) VALUES (%s, %s) ON CONFLICT DO NOTHING", user.id, tostring(media_id))
  else
    db.execute("DELETE FROM media_likes WHERE user_id=%s AND media_id=%s", user.id, tostring(media_id))
  end
  local updated = fetch_media_by_id(media_id, tostring(user.id))
  local adult_allowed = viewer_adult_allowed(tostring(user.id))
  return 200, { media = decode_media_row(updated, adult_allowed, req) }
end

function M.bookmark_media(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local payload = json_body(req)
  local bookmarked = payload.bookmarked and true or false

  local item = fetch_media_by_id(media_id, tostring(user.id))
  local vstatus, vbody = ensure_media_visible(item, tostring(user.id))
  if vstatus then return vstatus, vbody end

  if bookmarked then
    db.execute("INSERT INTO media_bookmarks (user_id, media_id) VALUES (%s, %s) ON CONFLICT DO NOTHING", user.id, tostring(media_id))
  else
    db.execute("DELETE FROM media_bookmarks WHERE user_id=%s AND media_id=%s", user.id, tostring(media_id))
  end
  local updated = fetch_media_by_id(media_id, tostring(user.id))
  local adult_allowed = viewer_adult_allowed(tostring(user.id))
  return 200, { media = decode_media_row(updated, adult_allowed, req) }
end

-- Forward-declared: assigned further down (in the messaging section) once
-- NOTIFICATION_KINDS/user_blocks-table logic exists -- same pattern as
-- notify_matching_saved_searches above.
local create_notification, is_blocked_either_way

-- Mirrors app/routers/media.py's add_comment(): notifies the post owner and
-- parses @mentions (excluding self and blocked users) same as Python.
local MENTION_RE = "@([%w_%.%-]+)"
function M.add_comment(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local rl_status, rl_body = ratelimit.check("comment:" .. user.id, 30, 3600)
  if rl_status then return rl_status, rl_body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local payload = json_body(req)
  local text = trim(nn(payload.body) or "")
  if text == "" then return 400, { detail = "Comment cannot be empty." } end
  text = text:sub(1, 500)
  local parent_id = nn(payload.parent_comment_id)

  local item = fetch_media_by_id(media_id, tostring(user.id))
  local vstatus, vbody = ensure_media_visible(item, tostring(user.id))
  if vstatus then return vstatus, vbody end
  if not db.tobool(item.comments_enabled) then
    return 403, { detail = "Comments are disabled for this post." }
  end

  local row, err = db.fetchone(
    "INSERT INTO media_comments (media_id, user_id, body, parent_comment_id) VALUES (%s, %s, %s, %s) RETURNING *",
    tostring(media_id), user.id, text, parent_id and tostring(parent_id) or nil
  )
  if not row then return 500, { detail = "Could not add comment: " .. tostring(err) } end
  row.id = db.toint(row.id, row.id)
  row.media_id = db.toint(row.media_id, row.media_id)
  row.user_id = db.toint(row.user_id, row.user_id)
  if row.parent_comment_id then row.parent_comment_id = db.toint(row.parent_comment_id, row.parent_comment_id) end

  local kind = parent_id and "reply" or "comment"
  create_notification(item.user_id, user.id, kind, media_id, text)

  local mentions, seen_mention = {}, {}
  for _, name in (" " .. text):gmatch("([^%w_])@([%w_%.%-]+)") do
    local lowered = name:lower()
    if #name >= 3 and #name <= 40 and not seen_mention[lowered] then
      seen_mention[lowered] = true
      mentions[#mentions + 1] = lowered
      if #mentions >= 10 then break end
    end
  end
  if #mentions > 0 then
    local placeholders = {}
    for i = 1, #mentions do placeholders[i] = "%s" end
    local resolved = db.fetchall(
      "SELECT id, username FROM users WHERE LOWER(username) IN (" .. table.concat(placeholders, ", ") .. ")",
      unpack(mentions)
    )
    local notified = {}
    for _, u in ipairs(resolved) do
      local mentioned_id = db.toint(u.id, u.id)
      if mentioned_id ~= user.id and mentioned_id ~= db.toint(item.user_id, item.user_id) and not notified[mentioned_id] then
        notified[mentioned_id] = true
        if not is_blocked_either_way(user.id, mentioned_id) then
          create_notification(mentioned_id, user.id, "mention", media_id, text)
        end
      end
    end
  end

  return 200, { comment = row }
end

function M.react_to_media_route(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local payload = json_body(req)
  local emoji = trim(nn(payload.emoji) or ""):sub(1, 16)
  if emoji == "" then return 400, { detail = "An emoji is required." } end

  local item = fetch_media_by_id(media_id, tostring(user.id))
  local vstatus, vbody = ensure_media_visible(item, tostring(user.id))
  if vstatus then return vstatus, vbody end

  local existing = db.fetchone("SELECT emoji FROM media_reactions WHERE media_id=%s AND user_id=%s", tostring(media_id), user.id)
  if existing and existing.emoji == emoji then
    db.execute("DELETE FROM media_reactions WHERE media_id=%s AND user_id=%s", tostring(media_id), user.id)
  else
    db.execute([[
      INSERT INTO media_reactions (media_id, user_id, emoji) VALUES (%s, %s, %s)
      ON CONFLICT (media_id, user_id) DO UPDATE SET emoji=EXCLUDED.emoji, created_at=now()
    ]], tostring(media_id), user.id, emoji)
  end

  local reaction_rows = db.fetchall(
    "SELECT emoji, COUNT(*) AS n FROM media_reactions WHERE media_id=%s GROUP BY emoji ORDER BY n DESC",
    tostring(media_id)
  )
  local counts = {}
  for _, r in ipairs(reaction_rows) do counts[r.emoji] = db.toint(r.n, 0) end
  local r = db.fetchone("SELECT emoji FROM media_reactions WHERE media_id=%s AND user_id=%s", tostring(media_id), user.id)
  local my_reaction = r and r.emoji or nil
  if tostring(item.user_id) ~= tostring(user.id) and my_reaction then
    create_notification(item.user_id, user.id, "reaction", media_id, my_reaction)
  end
  return 200, { reactions = { counts = counts, my_reaction = my_reaction } }
end

-- Same one-emoji-per-user toggle as M.react_to_media_route above, just
-- keyed by comment_id (media_comment_reactions, see
-- scripts/pg_add_comment_reactions.sql) instead of media_id. Visibility is
-- still checked against the comment's PARENT post, not the comment row
-- itself -- a comment has no visibility/adult flag of its own, it inherits
-- whatever post it's attached to, same as every other comment action
-- (add/delete) already does.
function M.react_to_comment_route(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local comment_id = tonumber(req.params.comment_id)
  if not comment_id then return 404, { detail = "Comment not found." } end
  local payload = json_body(req)
  local emoji = trim(nn(payload.emoji) or ""):sub(1, 16)
  if emoji == "" then return 400, { detail = "An emoji is required." } end

  local comment = db.fetchone("SELECT id, media_id, user_id FROM media_comments WHERE id=%s", tostring(comment_id))
  if not comment then return 404, { detail = "Comment not found." } end
  local media_id = db.toint(comment.media_id, comment.media_id)

  local item = fetch_media_by_id(media_id, tostring(user.id))
  local vstatus, vbody = ensure_media_visible(item, tostring(user.id))
  if vstatus then return vstatus, vbody end

  local existing = db.fetchone("SELECT emoji FROM media_comment_reactions WHERE comment_id=%s AND user_id=%s", tostring(comment_id), user.id)
  if existing and existing.emoji == emoji then
    db.execute("DELETE FROM media_comment_reactions WHERE comment_id=%s AND user_id=%s", tostring(comment_id), user.id)
  else
    db.execute([[
      INSERT INTO media_comment_reactions (comment_id, user_id, emoji) VALUES (%s, %s, %s)
      ON CONFLICT (comment_id, user_id) DO UPDATE SET emoji=EXCLUDED.emoji, created_at=now()
    ]], tostring(comment_id), user.id, emoji)
  end

  local reaction_rows = db.fetchall(
    "SELECT emoji, COUNT(*) AS n FROM media_comment_reactions WHERE comment_id=%s GROUP BY emoji ORDER BY n DESC",
    tostring(comment_id)
  )
  local counts = {}
  for _, r in ipairs(reaction_rows) do counts[r.emoji] = db.toint(r.n, 0) end
  local mine = db.fetchone("SELECT emoji FROM media_comment_reactions WHERE comment_id=%s AND user_id=%s", tostring(comment_id), user.id)
  local my_reaction = mine and mine.emoji or nil

  local comment_owner_id = db.toint(comment.user_id, comment.user_id)
  if comment_owner_id ~= user.id and my_reaction then
    create_notification(comment_owner_id, user.id, "comment_reaction", media_id, my_reaction)
  end
  return 200, { comment_id = comment_id, reactions = { counts = counts, my_reaction = my_reaction } }
end

-- ---------------------------------------------------------------------------
-- Media upload (POST /api/media) -- multipart form upload -> DB blob storage
-- (media_files.save_media_file) -> media_items row. Mirrors
-- app/routers/media.py's upload_media() + app/db/media.py's add_media().
--
-- Video thumb/quality cache warmup is not queued here; serve_media_thumb
-- already renders+caches lazily on first request instead.
-- ---------------------------------------------------------------------------

-- Validates the frontend's "Schedule for later" field (a datetime-local
-- value round-tripped through JS Date#toISOString(), e.g.
-- "2026-08-10T15:30:00.000Z"). Returns nil (immediate publish) when blank,
-- the validated timestamp string when it parses and is in the future, or
-- nil + an error message otherwise. Parsing/future-check is delegated to
-- Postgres itself (a single cheap round trip) rather than hand-rolling
-- ISO8601 parsing in Lua -- avoids silently accepting a format Postgres
-- would then reject at INSERT time, after the file blob is already saved.
local function parse_publish_at(raw)
  raw = nn(raw)
  if not raw or trim(raw) == "" then return nil, nil end
  local row, err = db.fetchone("SELECT (%s::timestamp > now()) AS in_future", raw)
  if not row then return nil, "Invalid schedule date." end
  if not db.tobool(row.in_future) then return nil, "Scheduled time must be in the future." end
  return raw, nil
end

local sodium = require("luasodium")

local SAFE_EXTENSIONS = {
  [".jpg"] = true, [".jpeg"] = true, [".png"] = true, [".webp"] = true, [".gif"] = true,
  [".avif"] = true, [".bmp"] = true, [".mp4"] = true, [".webm"] = true, [".mov"] = true,
  [".m4v"] = true, [".ogg"] = true, [".flv"] = true, [".mkv"] = true,
}
local MIME_TO_EXT = {
  ["image/jpeg"] = ".jpg", ["image/png"] = ".png", ["image/webp"] = ".webp", ["image/gif"] = ".gif",
  ["image/avif"] = ".avif", ["image/bmp"] = ".bmp", ["video/mp4"] = ".mp4", ["video/webm"] = ".webm",
  ["video/quicktime"] = ".mov", ["video/x-m4v"] = ".m4v", ["video/ogg"] = ".ogg",
  ["video/x-flv"] = ".flv", ["video/x-matroska"] = ".mkv",
}

-- Mirrors app/routers/_shared.py's _sniff_magic(): content-based mime/kind
-- detection so an upload can't lie about its type via a spoofed extension or
-- declared Content-Type. Returns nil, nil on unrecognized bytes.
local function sniff_magic(content)
  local head = content:sub(1, 128)
  if head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then return "image/webp", "image" end
  if #head >= 12 and head:sub(5, 8) == "ftyp" then
    local brands = head:sub(9, 32):lower()
    if brands:find("avif", 1, true) or brands:find("avis", 1, true) then return "image/avif", "image" end
    return "video/mp4", "video"
  end
  if head:sub(1, 4) == "\x1aE\xdf\xa3" then
    local mime = content:sub(1, 256):lower():find("matroska", 1, true) and "video/x-matroska" or "video/webm"
    return mime, "video"
  end
  if head:sub(1, 3) == "\xff\xd8\xff" then return "image/jpeg", "image" end
  if head:sub(1, 8) == "\x89PNG\r\n\x1a\n" then return "image/png", "image" end
  if head:sub(1, 6) == "GIF87a" or head:sub(1, 6) == "GIF89a" then return "image/gif", "image" end
  if head:sub(1, 4) == "OggS" then return "video/ogg", "video" end
  if head:sub(1, 4) == "FLV\x01" then return "video/x-flv", "video" end
  return nil, nil
end

local function safe_extension(filename, mime_type)
  local ext = (filename or ""):match("(%.[^./\\]+)$")
  ext = ext and ext:lower() or ""
  if not SAFE_EXTENSIONS[ext] then ext = MIME_TO_EXT[mime_type] or "" end
  if not SAFE_EXTENSIONS[ext] then return nil end
  return ext == ".jpe" and ".jpg" or ext
end

-- POST /api/me/avatar, /api/me/age-verification, /api/me/password,
-- GET /api/me/export -- all four recovered from git history
-- (9986ab5^:app/routers/account.py) and confirmed live-404ing: the React
-- Settings page has always called these, but none were ever ported to Lua.
-- (email change/verify, also called by SettingsPage.jsx, never existed even
-- in the Python backend -- genuinely new work needing an email-sending
-- decision, left for a separate pass rather than guessed at here.) Placed
-- here (rather than up near update_profile/update_settings, its more
-- natural neighbors) because update_avatar needs sniff_magic/safe_extension/
-- sodium, all locals not yet in scope up there.

function M.update_avatar(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local upload = (req.files or {}).file
  if not upload or not upload.content or upload.content == "" then
    return 400, { detail = "Upload is empty." }
  end
  if #upload.content > 5 * 1024 * 1024 then
    return 413, { detail = "Avatars must be 5MB or smaller." }
  end
  local rl_status, rl_body = ratelimit.check("avatar:" .. user.id, 20, 3600)
  if rl_status then return rl_status, rl_body end

  local sniffed_mime, media_kind = sniff_magic(upload.content)
  if not sniffed_mime or media_kind ~= "image" then return 400, { detail = "Avatar must be an image." } end
  local original_filename = ((upload.filename or "avatar"):match("([^/\\]+)$") or "avatar"):sub(1, 255)
  if not safe_extension(original_filename, sniffed_mime) then
    return 400, { detail = "Unsupported file extension." }
  end
  local sha256 = sodium.sodium_bin2hex(sodium.crypto_hash_sha256(upload.content))

  local file_id, err = media_files.save_avatar_file(user.id, upload.content, sha256, sniffed_mime, original_filename)
  if not file_id then return 500, { detail = "Avatar upload failed: " .. tostring(err) } end

  user_cache.invalidate(user.id)
  local refreshed = get_user(user.id)
  refreshed.site_owner = is_site_owner(refreshed)
  return 200, { user = with_user_urls(req, with_derived_accent(refreshed)) }
end

function M.verify_age(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  if not db.tobool(payload.confirm_over_18) then
    return 400, { detail = "Confirm that you are 18 or older to continue." }
  end
  local birthdate = nn(payload.birthdate)
  if not birthdate or not tostring(birthdate):match("^%d%d%d%d%-%d%d%-%d%d$") then
    return 400, { detail = "Birthdate must use YYYY-MM-DD." }
  end
  -- Single round trip: validate + compute age in Postgres rather than
  -- hand-rolling date math in Lua.
  local row = db.fetchone(
    "SELECT (%s::date > CURRENT_DATE) AS in_future, date_part('year', age(CURRENT_DATE, %s::date)) AS age_years",
    birthdate, birthdate
  )
  if not row then return 400, { detail = "Invalid birthdate." } end
  if db.tobool(row.in_future) then return 400, { detail = "Birthdate cannot be in the future." } end
  if db.toint(row.age_years, 0) < 18 then
    return 403, { detail = "You must be 18 or older to view 18+ posts." }
  end

  db.execute(
    "UPDATE users SET birthdate=%s, age_verified_at=now(), adult_content_consent=true WHERE id=%s",
    birthdate, tostring(user.id)
  )
  user_cache.invalidate(user.id)
  local refreshed = get_user(user.id)
  refreshed.site_owner = is_site_owner(refreshed)
  return 200, { user = with_user_urls(req, with_derived_accent(refreshed)) }
end

function M.change_password(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local old_password = tostring(nn(payload.old_password) or "")
  local new_password = tostring(nn(payload.new_password) or "")
  if #new_password < 8 then
    return 400, { detail = "New password must be at least 8 characters." }
  end
  local row = db.fetchone("SELECT password_hash FROM users WHERE id=%s", user.id)
  if not row or not gauth.verify_password_hash(old_password, row.password_hash) then
    return 401, { detail = "Current password is incorrect." }
  end
  db.execute("UPDATE users SET password_hash=%s WHERE id=%s", gauth.password_hash(new_password), user.id)
  return 200, { ok = true }
end

function M.export_account(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local viewer0 = tostring(user.id)

  local profile = get_user(viewer0)
  profile.password_hash = nil
  profile.totp_secret = nil
  profile.totp_recovery_codes = nil

  local media = db.fetchall(
    "SELECT id, title, description, tags, media_kind, visibility, views, downloads, created_at FROM media_items WHERE user_id=%s ORDER BY created_at DESC",
    viewer0
  )
  local collections = db.fetchall(
    "SELECT id, name, description, is_public, is_smart, created_at FROM media_collections WHERE user_id=%s ORDER BY created_at DESC",
    viewer0
  )
  local following = db.fetchall(
    "SELECT u.id, u.username FROM user_follows f JOIN users u ON u.id = f.followed_id WHERE f.follower_id=%s",
    viewer0
  )
  local followers = db.fetchall(
    "SELECT u.id, u.username FROM user_follows f JOIN users u ON u.id = f.follower_id WHERE f.followed_id=%s",
    viewer0
  )
  local likes = db.fetchall("SELECT media_id FROM media_likes WHERE user_id=%s", viewer0)
  local bookmarks = db.fetchall("SELECT media_id FROM media_bookmarks WHERE user_id=%s", viewer0)
  local comments = db.fetchall(
    "SELECT media_id, body, created_at FROM media_comments WHERE user_id=%s ORDER BY created_at DESC",
    viewer0
  )
  local saved_searches = db.fetchall(
    "SELECT name, filter_json, created_at FROM saved_searches WHERE user_id=%s ORDER BY created_at DESC",
    viewer0
  )

  local payload = {
    exported_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    profile = profile,
    media = arr(media),
    collections = arr(collections),
    following = arr(following),
    followers = arr(followers),
    likes = arr(likes),
    bookmarks = arr(bookmarks),
    comments = arr(comments),
    saved_searches = arr(saved_searches),
  }
  return 200, cjson.encode(payload), {
    ["Content-Type"] = "application/json; charset=utf-8",
    ["Content-Disposition"] = string.format('attachment; filename="image-gallery-export-%s.json"', viewer0),
  }
end

-- ---------------------------------------------------------------------------
-- Discord account verification. Genuinely new feature (there's no email
-- verification equivalent to recover from git history -- the frontend never
-- had one either): confirms account ownership via Discord instead of email,
-- using the same CSPRNG code + hash helpers (auth_lib.verification_code()/
-- verification_token_hash()) this codebase already has (originally written
-- for a since-unbuilt email flow, per their own doc comments in auth.lua).
--
-- Two delivery methods for the same code:
--   "dm"      -- via discord_bot.lua's real bot (needs GALLERY_DISCORD_BOT_TOKEN
--                configured, and the user must share a Discord server with
--                the bot -- Discord doesn't allow bots to DM strangers).
--   "webhook" -- posts to the user's own already-configured
--                discord_webhook_url (user_settings, the same per-creator
--                setting upload notifications already use) -- works today,
--                no bot needed.
-- ---------------------------------------------------------------------------

local DISCORD_VERIFY_TTL_SECONDS = 600
local DISCORD_VERIFY_MAX_ATTEMPTS = 5

function M.discord_verify_status(req)
  local user, session, status, body = current_user(req)
  if not user then return status, body end
  local pending = db.fetchone(
    "SELECT method, expires_at, (now() > expires_at) AS is_expired FROM discord_verifications WHERE user_id=%s",
    user.id
  )
  local pending_out = nil
  if pending and not db.tobool(pending.is_expired) then
    pending_out = { method = pending.method, expires_at = pending.expires_at }
  end
  return 200, {
    verified = nn(user.discord_verified_at) ~= nil,
    discord_username = nn(user.discord_username),
    discord_user_id = nn(user.discord_user_id),
    pending = pending_out,
    dm_available = discord_bot.enabled(),
  }
end

function M.discord_verify_start(req)
  local user, session, status, body = current_user(req)
  if not user then return status, body end
  local rl_status, rl_body = ratelimit.check("discord_verify:" .. user.id, 5, 3600)
  if rl_status then return rl_status, rl_body end

  local payload = json_body(req)
  local method = nn(payload.method)
  if method ~= "dm" and method ~= "webhook" then
    return 400, { detail = 'method must be "dm" or "webhook".' }
  end

  local code = auth_lib.verification_code()
  local target

  if method == "dm" then
    if not discord_bot.enabled() then
      return 400, { detail = "Discord verification isn't configured on this server yet." }
    end
    target = tostring(nn(payload.discord_user_id) or ""):match("^%d+$")
    if not target then
      return 400, {
        detail = "Enter a valid Discord User ID (numbers only -- in Discord, enable "
          .. "Settings > Advanced > Developer Mode, then right-click your name and Copy User ID).",
      }
    end
    local send_ok, send_err = discord_bot.send_dm(
      target, "Your Nyxframe verification code is: " .. code .. "\nIt expires in 10 minutes."
    )
    if not send_ok then return 400, { detail = send_err } end
  else
    local webhook_url = user.user_settings and user.user_settings.discord_webhook_url
    if not discord_webhook.is_valid_url(webhook_url) then
      return 400, { detail = "Set a Discord webhook URL under Settings > Integrations first." }
    end
    target = webhook_url
    discord_webhook.send(webhook_url, { {
      title = "Nyxframe verification code",
      description = "Code: **" .. code .. "**\nExpires in 10 minutes. Enter it on the Settings page.",
      color = 0x37c9a7,
    } })
  end

  db.execute(
    [[
      INSERT INTO discord_verifications (user_id, code_hash, method, target, attempts, expires_at)
      VALUES (%s, %s, %s, %s, 0, now() + interval '10 minutes')
      ON CONFLICT (user_id) DO UPDATE SET
        code_hash=EXCLUDED.code_hash, method=EXCLUDED.method, target=EXCLUDED.target,
        attempts=0, expires_at=EXCLUDED.expires_at, created_at=now()
    ]],
    user.id, auth_lib.verification_token_hash(code), method, target:sub(1, 255)
  )

  return 200, { ok = true, method = method, expires_in_seconds = DISCORD_VERIFY_TTL_SECONDS }
end

function M.discord_verify_confirm(req)
  local user, session, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local code = trim(tostring(nn(payload.code) or ""))
  if code == "" then return 400, { detail = "Enter the code you received." } end

  local pending = db.fetchone(
    "SELECT method, target, code_hash, attempts, (now() > expires_at) AS is_expired FROM discord_verifications WHERE user_id=%s",
    user.id
  )
  if not pending then return 400, { detail = "No verification in progress -- start over." } end
  if db.toint(pending.attempts, 0) >= DISCORD_VERIFY_MAX_ATTEMPTS or db.tobool(pending.is_expired) then
    db.execute("DELETE FROM discord_verifications WHERE user_id=%s", user.id)
    return 400, { detail = "That code expired or had too many incorrect attempts -- start over." }
  end

  if auth_lib.verification_token_hash(code) ~= pending.code_hash then
    db.execute("UPDATE discord_verifications SET attempts=attempts+1 WHERE user_id=%s", user.id)
    return 400, { detail = "Incorrect code." }
  end

  if pending.method == "dm" then
    local discord_username = discord_bot.get_user(pending.target)
    db.execute(
      "UPDATE users SET discord_user_id=%s, discord_username=%s, discord_verified_at=now() WHERE id=%s",
      pending.target, discord_username, user.id
    )
  else
    db.execute("UPDATE users SET discord_verified_at=now() WHERE id=%s", user.id)
  end
  db.execute("DELETE FROM discord_verifications WHERE user_id=%s", user.id)

  user_cache.invalidate(user.id)
  local refreshed = get_user(user.id)
  refreshed.site_owner = is_site_owner(refreshed)
  return 200, { user = with_user_urls(req, with_derived_accent(refreshed)) }
end

function M.discord_unlink(req)
  local user, session, status, body = current_user(req)
  if not user then return status, body end
  db.execute(
    "UPDATE users SET discord_user_id=NULL, discord_username=NULL, discord_verified_at=NULL WHERE id=%s",
    user.id
  )
  db.execute("DELETE FROM discord_verifications WHERE user_id=%s", user.id)
  user_cache.invalidate(user.id)
  local refreshed = get_user(user.id)
  refreshed.site_owner = is_site_owner(refreshed)
  return 200, { user = with_user_urls(req, with_derived_accent(refreshed)) }
end

-- Mirrors _normalize_upload_tag()/_parse_tags().
local function normalize_upload_tag(value)
  local cleaned = tostring(value or ""):match("^%s*(.-)%s*$"):gsub("^#+", ""):gsub("%s+", "-")
  cleaned = cleaned:gsub("[^%w_.%-]+", "")
  return cleaned:sub(1, M.settings.max_tag_length)
end

local function parse_tags(value)
  local tags, seen = {}, {}
  for raw in (value or ""):gmatch("[^,#\n\r\t]+") do
    local tag = normalize_upload_tag(raw)
    local lowered = tag:lower()
    if tag ~= "" and not seen[lowered] then
      seen[lowered] = true
      tags[#tags + 1] = tag
      if #tags >= M.settings.max_tags_per_upload then break end
    end
  end
  return tags
end

-- Matched as whole words (see moderate_upload), not as substrings. The
-- derived forms below used to be caught for free by substring matching
-- ("sexy" via "sex") and are listed explicitly so that tightening the match
-- does not quietly weaken detection.
local ADULT_KEYWORDS = {
  "18plus", "18+", "adult", "nsfw", "not safe for work", "nude", "nudity",
  "explicit", "porn", "porno", "sex", "sexual", "hentai", "ecchi", "lewd",
  "erotic", "fetish", "onlyfans", "camgirl", "cam boy", "xxx",
  "sexy", "sexually", "nudes", "pornographic", "pornhub", "erotica",
  "fetishes", "lewds", "hardcore", "xrated",
}

-- Mirrors app/routers/media.py's _moderate_upload(). human_confirmed is
-- always treated as true here (status goes straight to "adult" rather than
-- "pending_review") since this pass has no AI-vision path that could flag
-- adult content the uploader themselves didn't check the box for.
local function moderate_upload(title, description, tags, filename, mime_type, user_marked_adult)
  local combined = table.concat({ title, description or "", table.concat(tags, " "), filename, mime_type }, " "):lower()
  -- Whole-word matching. This used to be a plain substring search, which
  -- gated any post whose text merely CONTAINED a keyword's letters: the
  -- Derpibooru tag "adorasexy" (a safe-rated tag) contains "sex", so ordinary
  -- pony wallpapers were being hidden behind the age gate. "unisex",
  -- "asexual" and "Essex" had the same problem.
  --
  -- Tags arrive slug-cased ("equestria-girls"), so punctuation is collapsed
  -- to spaces before matching and the haystack is padded, making " word " a
  -- boundary test. Keywords that are not purely alphanumeric ("18+",
  -- "cam boy", "not safe for work") would not survive that normalisation, so
  -- they keep the original substring behaviour.
  local normalized = " " .. combined:gsub("[^%w]+", " ") .. " "
  local hits = {}
  for _, word in ipairs(ADULT_KEYWORDS) do
    local matched
    if word:find("[^%w]") then
      matched = combined:find(word, 1, true) ~= nil
    else
      matched = normalized:find(" " .. word .. " ", 1, true) ~= nil
    end
    if matched then hits[#hits + 1] = word end
  end
  local adult_by_ai = #hits > 0
  local is_adult = user_marked_adult or adult_by_ai
  local reason_parts = {}
  if user_marked_adult then reason_parts[#reason_parts + 1] = "Uploader marked this post as 18+." end
  if adult_by_ai then reason_parts[#reason_parts + 1] = "Automatic moderation matched: " .. table.concat(hits, ", ") .. "." end
  local reason = #reason_parts > 0 and table.concat(reason_parts, " "):sub(1, 300) or nil
  return {
    is_adult = is_adult,
    adult_marked_by_user = user_marked_adult,
    adult_marked_by_ai = adult_by_ai,
    moderation_status = is_adult and "adult" or "clear",
    moderation_score = adult_by_ai and 0.96 or (user_marked_adult and 0.75 or 0),
    moderation_reason = reason,
  }
end

local function form_bool(value, default)
  if value == nil then return default end
  return value == "true" or value == "1" or value == "on"
end

-- ---------------------------------------------------------------------------
-- Possible-duplicate-upload warning via perceptual image hashing. Mirrors
-- app/routers/media.py's _find_possible_duplicates() + app/ai_metadata.py's
-- _hex_hamming_distance() -- the actual hash computation lives in
-- media_files.image_fingerprint() (ffmpeg-based, see that file's comment for
-- why it isn't bit-identical to Python's PIL-based hashes; irrelevant here
-- since candidates are always hashed by this same backend).
-- ---------------------------------------------------------------------------

local bit = require("bit")

-- Compares two equal-length hex hash strings 8 hex chars (32 bits) at a
-- time, since `bit` only handles 32-bit values. Returns nil if either hash
-- is missing/malformed.
local function hex_hamming_distance(a, b)
  a = tostring(a or ""):lower()
  b = tostring(b or ""):lower()
  if a == "" or b == "" or #a ~= #b or #a % 8 ~= 0 then return nil end
  local dist = 0
  for i = 1, #a, 8 do
    local ha, hb = tonumber(a:sub(i, i + 7), 16), tonumber(b:sub(i, i + 7), 16)
    if not ha or not hb then return nil end
    local x = bit.bxor(ha, hb)
    while x ~= 0 do
      dist = dist + bit.band(x, 1)
      x = bit.rshift(x, 1)
    end
  end
  return dist
end

-- Scoped to the uploader's own media (not the whole gallery) to keep the
-- comparison pool small and the result meaningful -- catching accidental
-- re-uploads, not flagging every repost. Advisory only; never blocks the
-- upload itself.
-- `scope`: "mine" (default, unchanged behavior) scopes candidates to the
-- uploader's own prior uploads. "site" widens the search to every user's
-- uploads, opt-in only (see M.upload_media's check_site_duplicates flag) --
-- bounded by dedup_scan_window_days (config.lua) rather than just the 1500-
-- row cap, since "site-wide" with no time bound would just become "the 1500
-- newest uploads from anyone," missing older duplicates and not meaningfully
-- related to fingerprint similarity.
local function find_possible_duplicates(req, user_id, fingerprint, limit, scope)
  limit = limit or 3
  if not fingerprint then return {} end
  local current_phash, current_dhash = nn(fingerprint.image_phash), nn(fingerprint.image_dhash)
  if not current_phash and not current_dhash then return {} end

  local candidates
  if scope == "site" then
    candidates = db.fetchall(string.format([[
      SELECT id, title, image_phash, image_dhash
      FROM media_items
      WHERE user_id != %%s AND deleted_at IS NULL AND media_kind='image' AND visibility='public'
        AND (image_phash IS NOT NULL OR image_dhash IS NOT NULL)
        AND created_at > now() - (%d || ' days')::interval
      ORDER BY created_at DESC
      LIMIT 1500
    ]], M.settings.dedup_scan_window_days), tostring(user_id))
  else
    candidates = db.fetchall([[
      SELECT id, title, image_phash, image_dhash
      FROM media_items
      WHERE user_id=%s AND deleted_at IS NULL AND media_kind='image'
        AND (image_phash IS NOT NULL OR image_dhash IS NOT NULL)
      ORDER BY created_at DESC
      LIMIT 1500
    ]], tostring(user_id))
  end

  local scored = {}
  for _, candidate in ipairs(candidates) do
    local pdist = current_phash and hex_hamming_distance(current_phash, candidate.image_phash) or nil
    local ddist = current_dhash and hex_hamming_distance(current_dhash, candidate.image_dhash) or nil
    if pdist and pdist > M.settings.visual_phash_max_distance then pdist = nil end
    if ddist and ddist > M.settings.visual_dhash_max_distance then ddist = nil end
    if pdist or ddist then
      local best = pdist and ddist and math.min(pdist, ddist) or (pdist or ddist)
      scored[#scored + 1] = { distance = best, candidate = candidate }
    end
  end
  table.sort(scored, function(a, b) return a.distance < b.distance end)

  local origin = request_origin(req)
  local results = {}
  for i = 1, math.min(limit, #scored) do
    local entry = scored[i]
    results[#results + 1] = {
      id = db.toint(entry.candidate.id, entry.candidate.id),
      title = entry.candidate.title,
      thumb_url = append_query(origin .. "/api/media/" .. entry.candidate.id .. "/thumb", "w", "640"),
      distance = entry.distance,
    }
  end
  return results
end

-- Reverse/visual image search: POST a query image (or reference an existing
-- post via media_id, to reuse its already-stored hash instead of re-hashing)
-- and get back every visible post whose perceptual hash is close to it.
-- Reuses exactly the same hex_hamming_distance + visual_*_max_distance
-- thresholds find_possible_duplicates already uses -- the two features are
-- the same underlying comparison, just scoped differently (one user's recent
-- uploads at upload time vs. every visible post, on demand). Unlike
-- compute_similar_media's deliberate skip of hash comparison for the "more
-- like this" rail (see its comment above), the whole point here IS the
-- hash comparison, so the cost is the feature rather than overhead on top
-- of one -- and at this site's scale (~3300 public rows, per M.media_random's
-- comment) a full scan is a few thousand cheap XOR+popcount ops, not a
-- real cost center.
-- Shared by M.visual_search (fresh upload) and M.visual_search_from_media
-- (reusing an existing post's stored hash). `exclude_media_id` keeps a
-- from-existing-post search from returning that same post as its own best
-- match.
-- Bare global, not `local`: routes.lua is already at LuaJIT's 200-local-
-- per-chunk ceiling (see webpush/push above for the established workaround).
function run_visual_search(req, fingerprint, viewer_id, adult_allowed, exclude_media_id)
  local viewer0 = viewer_id or "0"
  local current_phash, current_dhash = nn(fingerprint.image_phash), nn(fingerprint.image_dhash)

  local clauses = {
    "m.deleted_at IS NULL",
    "m.media_kind='image'",
    "(m.image_phash IS NOT NULL OR m.image_dhash IS NOT NULL)",
    "(m.visibility='public' AND (m.publish_at IS NULL OR m.publish_at <= now()) OR m.user_id=%s)",
  }
  local params = { viewer0 }
  if not adult_allowed then clauses[#clauses + 1] = "m.is_adult=false" end
  if viewer_id then
    clauses[#clauses + 1] = "m.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id=%s)"
    params[#params + 1] = viewer0
  end
  if exclude_media_id then
    clauses[#clauses + 1] = "m.id != %s"
    params[#params + 1] = tostring(exclude_media_id)
  end

  local sql = string.format([[
    SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.media_kind, m.mime_type,
           m.original_filename, m.storage_path, m.is_adult, m.created_at, m.views,
           m.image_phash, m.image_dhash
    FROM media_items m
    WHERE %s
    LIMIT 5000
  ]], table.concat(clauses, " AND "))
  local candidates = db.fetchall(sql, unpack(params))

  local scored = {}
  for _, row in ipairs(candidates) do
    local pdist = current_phash and hex_hamming_distance(current_phash, row.image_phash) or nil
    local ddist = current_dhash and hex_hamming_distance(current_dhash, row.image_dhash) or nil
    if pdist and pdist > M.settings.visual_phash_max_distance then pdist = nil end
    if ddist and ddist > M.settings.visual_dhash_max_distance then ddist = nil end
    if pdist or ddist then
      local best = pdist and ddist and math.min(pdist, ddist) or (pdist or ddist)
      row.image_phash, row.image_dhash = nil, nil
      scored[#scored + 1] = { distance = best, row = row }
    end
  end
  table.sort(scored, function(a, b) return a.distance < b.distance end)

  local results = {}
  for i = 1, math.min(60, #scored) do
    local row = scored[i].row
    row.id = db.toint(row.id, row.id)
    row.user_id = db.toint(row.user_id, row.user_id)
    row.category_id = db.toint(row.category_id, row.category_id)
    row.views = db.toint(row.views, 0)
    row.is_adult = db.tobool(row.is_adult)
    row.match_distance = scored[i].distance
    with_urls(req, row, adult_allowed)
    results[#results + 1] = row
  end
  attach_media_subcategories(results)
  return results
end

-- POST /api/search/visual -- multipart upload, the main reverse-image-search
-- entry point (a dedicated search page, not tied to any existing post).
function M.visual_search(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local adult_allowed = viewer_adult_allowed(viewer_id)

  local rl_status, rl_body = ratelimit.check("visual_search:" .. (viewer_id or client_ip(req)), 30, 3600)
  if rl_status then return rl_status, rl_body end

  local upload = (req.files or {}).file
  if not upload or not upload.content or upload.content == "" then
    return 400, { detail = "Upload an image to search with." }
  end
  if #upload.content > 15 * 1024 * 1024 then
    return 413, { detail = "Search image must be 15MB or smaller." }
  end
  local sniffed_mime, media_kind = sniff_magic(upload.content)
  if not sniffed_mime or media_kind ~= "image" then
    return 400, { detail = "That file doesn't look like an image." }
  end
  local fingerprint = media_files.image_fingerprint(upload.content)
  if not fingerprint or (not nn(fingerprint.image_phash) and not nn(fingerprint.image_dhash)) then
    return 400, { detail = "Could not read that image." }
  end

  local results = run_visual_search(req, fingerprint, viewer_id, adult_allowed, nil)
  return 200, { media = arr(results) }
end

-- GET /api/media/:media_id/visual-similar -- "find visually similar" from an
-- existing post, reusing its already-stored hash (no re-upload/re-hash).
function M.visual_search_from_media(req)
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local adult_allowed = viewer_adult_allowed(viewer_id)

  local seed = fetch_media_by_id(media_id, viewer_id or "0")
  local vstatus, vbody = ensure_media_visible(seed, viewer_id)
  if vstatus then return vstatus, vbody end
  if seed.media_kind ~= "image" then
    return 400, { detail = "That post has no visual fingerprint to search with." }
  end
  -- fetch_media_by_id's SELECT doesn't carry image_phash/image_dhash (every
  -- other caller of it has no use for them), so they're fetched separately
  -- here rather than bloating that shared query for this one route.
  local hashes = db.fetchone("SELECT image_phash, image_dhash FROM media_items WHERE id=%s", tostring(media_id))
  if not hashes or (not nn(hashes.image_phash) and not nn(hashes.image_dhash)) then
    return 400, { detail = "That post has no visual fingerprint to search with." }
  end

  local results = run_visual_search(req, { image_phash = hashes.image_phash, image_dhash = hashes.image_dhash },
    viewer_id, adult_allowed, media_id)
  return 200, { media = arr(results) }
end

-- Mirrors app/routers/media.py's _notify_discord_upload/_notify_discord_upload_async.
-- Fire-and-forget (see discord_webhook.lua): a slow/broken webhook must
-- never delay or fail the upload response.
-- Forward-declared: the actual function is assigned further down (in the
-- saved-searches section, after create_notification/is_blocked_either_way
-- exist) since Lua locals are only visible to code after their declaration
-- -- this `local` here just reserves the upvalue so M.upload_media below can
-- close over it; by the time any request actually runs, the whole module
-- has finished loading and the assignment further down has already happened.
local notify_matching_saved_searches

local function notify_discord_upload(req, uploader, item)
  local ok, err = pcall(function()
    local webhook_url = uploader.user_settings and uploader.user_settings.discord_webhook_url
    if not webhook_url or webhook_url == "" or webhook_url == cjson.null then return end
    local page_url = request_origin(req):gsub("/+$", "") .. "/media/" .. item.id
    local embed = {
      title = (nn(item.title) or "New upload"):sub(1, 256),
      url = page_url,
      color = 0x37c9a7,
      author = { name = uploader.display_name or uploader.username or "Someone" },
    }
    local description = trim(nn(item.description) or "")
    if description ~= "" then embed.description = description:sub(1, 300) end
    local image_url = nn(item.url) or nn(item.preview_url)
    if image_url and item.media_kind ~= "video" then
      embed.image = { url = image_url }
    elseif nn(item.thumb_url) then
      embed.thumbnail = { url = item.thumb_url }
    end
    discord_webhook.send(webhook_url, { embed })
  end)
  if not ok then
    print("[nyxframe] Discord upload webhook notification failed for user " .. tostring(uploader.id) .. ": " .. tostring(err))
  end
end

-- Shared by both upload paths: the normal single-request multipart upload
-- (M.upload_media, still used for anything that fits under one request --
-- the Cloudflare tunnel this deployment sits behind hard-413s any single
-- request body over ~100MB, well below what M.settings.max_upload_bytes
-- allows) and the chunked upload path (M.upload_chunk_finish) that exists
-- specifically to get large videos past that same edge limit by sending
-- them as several sub-100MB requests instead of one.
local function finalize_upload_debug_mark(label, t0)
  if os.getenv("GALLERY_UPLOAD_DEBUG_TIMING") then
    io.stdout:write(string.format("[upload-timing] %s at +%.2fs\n", label, os.time() - t0))
    io.stdout:flush()
  end
end

-- `source` is either `{content = "..."}` (already in memory -- the plain
-- multipart upload path, where httpd.lua's parser already holds the whole
-- request body as one string anyway, so there's nothing to gain by
-- treating it specially) or `{file_path = "...", file_size = N}` (a
-- chunked upload's already-fully-assembled session file, still just
-- sitting on disk). The file_path case is what actually matters: sniffing
-- reads a few hundred bytes, hashing streams the file in chunks
-- (media_files.sha256_file), AI analysis extracts one small preview frame
-- via ffmpeg reading straight from the path, and the final storage step
-- is a plain rename -- a multi-hundred-MB upload's real content is never
-- pulled into a single Lua string anywhere in this path. Confirmed live
-- (2026-08-10) that holding that much in LuaJIT's GC-managed heap was
-- itself what froze this single-threaded server, independent of raw OS
-- memory pressure: a full GC sweep is a stop-the-world pause proportional
-- to live heap size.
local function source_sniff_prefix(source)
  if source.content then return source.content:sub(1, 512) end
  local f = io.open(source.file_path, "rb")
  if not f then return "" end
  local prefix = f:read(512) or ""
  f:close()
  return prefix
end

local function source_size(source)
  return source.content and #source.content or source.file_size
end

local function source_sha256(source)
  if source.content then
    return sodium.sodium_bin2hex(sodium.crypto_hash_sha256(source.content))
  end
  return media_files.sha256_file(source.file_path)
end

-- Forward-declared: the actual function is assigned further down (after
-- shell_quote/ffmpeg_bin exist) since Lua locals are only visible to code
-- after their declaration -- this `local` here just reserves the upvalue
-- so finalize_upload below can close over it; by the time any request
-- actually runs, the whole module has finished loading and the assignment
-- further down has already happened.
local fast_start_remux_if_needed

-- `on_stage` (optional) is called with a short stage name as processing
-- moves along ("optimizing", "analyzing", "fingerprinting", "saving",
-- "finishing") -- the background job runner uses it for the status the
-- uploader sees. Second argument: the new media id (at "finishing", once
-- the row exists); third: the replacement source after a remux.
local function finalize_upload(req, user, source, original_filename, form, on_stage)
  local stage = on_stage or function() end
  local debug_t0 = os.time()
  finalize_upload_debug_mark("start", debug_t0)
  local sniffed_mime, media_kind = sniff_magic(source_sniff_prefix(source))
  finalize_upload_debug_mark("sniff_magic done", debug_t0)
  if not sniffed_mime then return 400, { detail = "Unsupported or invalid file bytes." } end
  local safe_ext = safe_extension(original_filename, sniffed_mime)
  if not safe_ext then
    return 400, { detail = "Unsupported file extension." }
  end
  -- Relocates the moov atom to the front of the file BEFORE anything else
  -- touches `source`, so AI frame sampling, sha256, and the actual on-disk
  -- save all see the fixed-up bytes. See the function's own header comment
  -- (below, after ffmpeg_bin) for why this matters.
  if media_kind == "video" then stage("optimizing") end
  local pre_remux_path = source.file_path
  source = fast_start_remux_if_needed(source, sniffed_mime)
  -- The remux replaces (and deletes) the original file: tell the job
  -- runner, so a retry or a post-restart resume reads the new one.
  if pre_remux_path and source.file_path ~= pre_remux_path then stage("optimizing", nil, source) end
  finalize_upload_debug_mark("fast_start_remux done", debug_t0)

  -- Hash + image fingerprint run in their own thread while the AI call
  -- below waits on the network (both only read the now-final bytes), so
  -- they no longer add their time on top of it. Joined before first use.
  local pre = { done = false }
  do
    local copas_ok, copas = pcall(require, "copas")
    local function compute()
      local ok, err = pcall(function()
        pre.sha256 = source_sha256(source)
        if media_kind == "image" then
          pre.fingerprint = source.file_path and media_files.image_fingerprint_from_path(source.file_path)
            or media_files.image_fingerprint(source.content)
        end
      end)
      if not ok then pre.err = err end
      pre.done = true
    end
    if copas_ok and coroutine.running() then copas.addthread(compute) else compute() end
    pre.wait = function()
      while not pre.done do copas.sleep(0.02) end
      if pre.err then error(pre.err) end
    end
  end

  local title_raw = trim(nn(form.title) or ""):sub(1, 160)
  local description_raw = trim(nn(form.description) or "")
  local source_url, source_url_err = M.normalize_source_url(form.source_url)
  if source_url_err then return 400, { detail = source_url_err } end
  -- YouTube source-link thumbnail override: detected here (cheap string
  -- matching, no network call) so it can ride along in the same INSERT as
  -- everything else; the actual fetch+render happens lazily in
  -- M.serve_media_thumb the first time this media's thumbnail is requested,
  -- same as every other thumbnail source already works.
  local youtube_video_id = source_url and require("youtube_thumb").extract_video_id(source_url) or nil
  local tags_hint = parse_tags(form.tags)
  local visibility = (nn(form.visibility) or "public"):lower()
  if visibility ~= "public" and visibility ~= "unlisted" and visibility ~= "private" then
    return 400, { detail = "Visibility must be public, unlisted, or private." }
  end
  local publish_at, publish_at_err = parse_publish_at(form.publish_at)
  if publish_at_err then return 400, { detail = publish_at_err } end
  -- Ephemeral/"stories" posts, 2026-10-11: an optional self-destruct timer
  -- rather than a new post type -- everything else about the post (kind,
  -- visibility, comments, etc.) works exactly as normal, it just stops
  -- being visible once expires_at passes. Computed as a DB-side interval
  -- add (not `os.time() + hours*3600` in Lua) so this can never drift from
  -- whatever clock Postgres's own `now()` uses -- the same clock every
  -- expiry check below compares against.
  local expires_in_hours = tonumber(form.expires_in_hours)
  local expires_at = nil
  if expires_in_hours then
    if expires_in_hours < 1 or expires_in_hours > 168 then
      return 400, { detail = "expires_in_hours must be between 1 and 168 (7 days)." }
    end
    local erow = db.fetchone("SELECT (now() + (%s || ' hours')::interval) AS ts", tostring(expires_in_hours))
    expires_at = erow and nn(erow.ts)
  end
  local comments_enabled = form_bool(form.comments_enabled, true)
  local downloads_enabled = form_bool(form.downloads_enabled, true)
  local is_adult_input = form_bool(form.is_adult, false)
  local auto_ai = form_bool(form.auto_ai, true)

  -- AI-assisted auto-fill (see ai_metadata.lua for what this does and
  -- doesn't cover): only ever fills in gaps the uploader left blank --
  -- title, tags, category/subcategory -- and is best-effort (pcall'd; a
  -- broken/unreachable AI provider must never fail the upload itself).
  local analysis = nil
  if auto_ai and M.settings.ai_enabled and (media_kind == "image" or media_kind == "video") then
    stage("analyzing")
    local telemetry_t0 = M.telemetry.now()
    local ok, result = pcall(ai_metadata.analyze_media_bytes, {
      content = source.content, file_path = source.file_path, filename = original_filename, mime_type = sniffed_mime, media_kind = media_kind,
      title_hint = title_raw, description_hint = description_raw, tags_hint = tags_hint, settings = M.settings,
    })
    M.telemetry.record("upload", "ai_analyze", ok and "success" or "error", M.telemetry.ms_since(telemetry_t0),
      { provider = M.settings.ai_provider, media_kind = media_kind, error = (not ok) and tostring(result):sub(1, 300) or nil })
    if ok then analysis = result end
  end
  finalize_upload_debug_mark("ai analysis done", debug_t0)

  -- Auto-organization (tags/subcategories) only auto-applies above this
  -- confidence -- title is left ungated below (a so-so title guess is
  -- low-stakes and the uploader notices/fixes it immediately; it isn't an
  -- "organization" decision the way tags/category are), and category
  -- itself is deliberately left ungated too, since it's the one REQUIRED
  -- field here -- gating it would turn a low-confidence guess into a new
  -- upload failure ("Category is required") for uploads that silently
  -- succeeded before this change, which is a bigger behavior change than
  -- "auto-organize with high confidence" asked for. Tags and
  -- subcategories are both optional, so gating them can only ever leave a
  -- field blank for the uploader to notice and fill in themselves --
  -- never break the upload.
  local AI_ORGANIZE_MIN_CONFIDENCE = 0.6
  local ai_organize_confident = analysis and (tonumber(analysis.confidence) or 0) >= AI_ORGANIZE_MIN_CONFIDENCE

  local title = title_raw ~= "" and title_raw or (analysis and analysis.title) or ""
  if title == "" then return 400, { detail = "Title is required." } end
  local description = description_raw ~= "" and description_raw:sub(1, 2000) or nil
  local tags = (ai_organize_confident and #analysis.tags > 0) and analysis.tags or tags_hint

  local category_id = tonumber(form.category_id)
  if not category_id or category_id <= 0 then
    local category_kind = nn(form.category_kind) or (media_kind == "video" and "video" or "image")
    local category_name = nn(form.category_name)
    if not category_name or trim(category_name) == "" then category_name = analysis and analysis.category_name or nil end
    category_id = find_or_create_category(category_name, category_kind, user.id)
    if not category_id then return 400, { detail = "Category is required." } end
  end
  -- Multi-subcategory form fields: subcategory_ids_json/subcategory_names_json
  -- are JSON-array-encoded strings (multipart forms have no native array
  -- type), mirroring app/routers/media.py's upload_media() parsing of the
  -- same field names. Falls back to the single subcategory_id/
  -- subcategory_name fields for older/simpler callers.
  local requested_ids = {}
  if nn(form.subcategory_ids_json) then
    local ok, decoded = pcall(cjson.decode, form.subcategory_ids_json)
    if ok and type(decoded) == "table" then requested_ids = decoded end
  end
  local single_id = tonumber(form.subcategory_id)
  if single_id and single_id > 0 then table.insert(requested_ids, 1, single_id) end
  requested_ids = normalize_subcategory_ids(requested_ids)

  local requested_names = {}
  if nn(form.subcategory_names_json) then
    local ok, decoded = pcall(cjson.decode, form.subcategory_names_json)
    if ok and type(decoded) == "table" then requested_names = decoded end
  end
  if nn(form.subcategory_name) and trim(form.subcategory_name) ~= "" then
    table.insert(requested_names, 1, form.subcategory_name)
  end
  if #requested_ids == 0 and #requested_names == 0 and ai_organize_confident then
    for _, name in ipairs(analysis.subcategory_names or {}) do requested_names[#requested_names + 1] = name end
  end
  requested_names = normalize_subcategory_names(requested_names)

  local resolved_subcategory_ids, subcat_err = resolve_subcategory_ids(category_id, requested_ids, requested_names, user.id)
  if not resolved_subcategory_ids then return 400, { detail = subcat_err } end
  local subcategory_id = resolved_subcategory_ids[1]

  if not pre.done then stage("fingerprinting") end
  pre.wait()
  local sha256 = pre.sha256
  finalize_upload_debug_mark("sha256 done", debug_t0)
  local moderation = moderate_upload(title, description, tags, original_filename, sniffed_mime,
    is_adult_input or (analysis and analysis.is_adult) or false)

  local fingerprint = pre.fingerprint
  local possible_duplicates = find_possible_duplicates(req, user.id, fingerprint)
  -- Site-wide check is opt-in per upload (not automatic) so the default
  -- upload response/behavior for everyone who doesn't set this flag is
  -- completely unchanged.
  local possible_site_duplicates = form_bool(form.check_site_duplicates, false)
    and find_possible_duplicates(req, user.id, fingerprint, 3, "site")
    or {}
  finalize_upload_debug_mark("moderation/fingerprint/dupes done", debug_t0)

  stage("saving")
  local media_file, save_err = media_files.save_media_file_to_disk(M.settings.uploads_dir, {
    content = source.content,
    source_path = source.file_path,
    sha256 = sha256,
    ext = safe_ext,
    original_filename = original_filename,
  })
  finalize_upload_debug_mark("save_media_file done", debug_t0)
  if not media_file then return 500, { detail = "Could not store uploaded file: " .. tostring(save_err) } end

  -- Live-diagnosing a "Could not save media: ... invalid input syntax for
  -- type bigint: \"nil\"" report: every bigint column below is nullable
  -- except these three, and they're the only ones fed through a bare
  -- tostring() with no nil-guard (every nullable bigint param uses the
  -- `X and tostring(X) or nil` pattern instead, which can't produce the
  -- literal string "nil"). Checked explicitly here so a genuinely-nil value
  -- fails with a clear message instead of a cryptic Postgres type error --
  -- and logged unconditionally (not gated behind GALLERY_UPLOAD_DEBUG_TIMING)
  -- since this is exactly the kind of value that needs to be visible on the
  -- NEXT occurrence without needing another round of forensics.
  local file_size_value = source_size(source)
  print(string.format(
    "[nyxframe] finalize_upload insert: user_id=%s category_id=%s file_size=%s media_kind=%s",
    tostring(user.id), tostring(category_id), tostring(file_size_value), tostring(media_kind)
  ))
  if not user.id then return 500, { detail = "Could not save media: user id missing." } end
  if not category_id then return 500, { detail = "Could not save media: category id missing." } end
  if not file_size_value or file_size_value <= 0 then
    return 500, { detail = "Could not save media: file size missing or invalid." }
  end

  local row, insert_err = db.fetchone(
    [[
      INSERT INTO media_items
        (user_id, category_id, subcategory_id, title, description, tags, media_kind, mime_type, original_filename,
         storage_path, file_size, media_file_id, content_sha256, visibility, comments_enabled, downloads_enabled,
         is_adult, adult_marked_by_user, adult_marked_by_ai, moderation_status, moderation_score, moderation_reason, moderated_at,
         image_phash, image_dhash, image_width, image_height, dominant_color, publish_at, source_url, expires_at,
         youtube_video_id)
      VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,now(),%s,%s,%s,%s,%s,%s,%s,%s,%s)
      RETURNING id
    ]],
    tostring(user.id), tostring(category_id), subcategory_id and tostring(subcategory_id) or nil,
    title, description, cjson.encode(arr(tags)), media_kind, sniffed_mime, original_filename,
    media_file.storage_path, tostring(file_size_value), nil, sha256,
    visibility, comments_enabled, downloads_enabled,
    moderation.is_adult, moderation.adult_marked_by_user, moderation.adult_marked_by_ai,
    moderation.moderation_status, tostring(moderation.moderation_score), moderation.moderation_reason,
    fingerprint and fingerprint.image_phash or nil, fingerprint and fingerprint.image_dhash or nil,
    fingerprint and fingerprint.image_width and tostring(fingerprint.image_width) or nil,
    fingerprint and fingerprint.image_height and tostring(fingerprint.image_height) or nil,
    fingerprint and fingerprint.dominant_color or nil, publish_at, source_url, expires_at,
    youtube_video_id
  )
  finalize_upload_debug_mark("media_items insert done", debug_t0)
  if not row then return 500, { detail = "Could not save media: " .. tostring(insert_err) } end
  local media_id = db.toint(row.id, row.id)
  write_media_subcategories(media_id, resolved_subcategory_ids)

  stage("finishing", media_id)
  local item = fetch_media_by_id(media_id, tostring(user.id))
  -- Pre-render the grid/lightbox/detail image sizes right away rather than
  -- waiting for the warmer's next round, so the uploader's first look at
  -- the post (usually seconds from now) is already warm. Own thread, so
  -- this response never waits on it.
  if media_kind == "image" and item then
    local warm_row = {
      id = media_id, media_kind = "image", mime_type = item.mime_type, original_filename = item.original_filename,
      storage_path = item.storage_path, created_at = item.created_at, updated_at = item.updated_at,
    }
    local copas_ok, copas = pcall(require, "copas")
    if copas_ok then
      copas.addthread(function()
        local ok, err = pcall(M._warm_image_renditions, warm_row)
        if not ok then print("[nyxframe] upload prewarm failed for media " .. tostring(media_id) .. ": " .. tostring(err)) end
      end)
    end
  end
  local adult_allowed = viewer_adult_allowed(tostring(user.id))
  local enriched = decode_media_row(item, adult_allowed, req)
  finalize_upload_debug_mark("decode_media_row done", debug_t0)
  -- Pre-render the default-grid-width thumbnail now instead of waiting for
  -- the first viewer (usually the uploader themselves, seconds from now)
  -- to hit M.serve_media_thumb's cache-miss path -- see prewarm_video_thumb's
  -- header comment. copas.addthread so this never delays THIS response:
  -- same fire-and-forget contract as notify_discord_upload above.
  if media_kind == "video" then
    local copas_ok, copas = pcall(require, "copas")
    if copas_ok then copas.addthread(function() prewarm_video_thumb(media_id, item) end) end
  end
  notify_discord_upload(req, user, enriched)
  finalize_upload_debug_mark("notify_discord_upload done", debug_t0)
  -- Scheduled posts (future publish_at) aren't visible yet, so saved-search
  -- subscribers must not be notified until the scheduled time actually
  -- arrives; there's no publish-time sweep (see parse_publish_at's comment
  -- above -- visibility is computed at read time everywhere), so a
  -- scheduled post simply never triggers this notification retroactively.
  if visibility == "public" and not publish_at then
    notify_matching_saved_searches(user.id, enriched)
    -- Followers get a "new upload" notification (in-app + push, via
    -- create_notification's own push.notify hook) the same way saved-
    -- search subscribers just did above -- same gating, since neither
    -- should fire for something that isn't actually visible yet.
    -- `notifications_muted=false` (per-follow mute, 2026-10-11 -- see
    -- M.set_follow_mute) filters this at the query level rather than
    -- fetching every follower and skipping muted ones in Lua: same
    -- "narrow the row set in SQL, don't post-filter a full fetch" pattern
    -- as the tag-rename UPDATE's `tags::jsonb ? %s` above.
    local followers = db.fetchall(
      "SELECT follower_id FROM user_follows WHERE followed_id=%s AND notifications_muted=false",
      tostring(user.id)
    )
    for _, f in ipairs(followers) do
      create_notification(db.toint(f.follower_id, f.follower_id), user.id, "new_upload", media_id, title)
    end
  end
  return 200, { media = enriched, possible_duplicates = arr(possible_duplicates), possible_site_duplicates = arr(possible_site_duplicates) }
end

function M.upload_media(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end

  local form = req.form or {}
  local upload = (req.files or {}).file
  if not upload or not upload.content or upload.content == "" then
    return 400, { detail = "Upload is empty." }
  end
  if #upload.content > M.settings.max_upload_bytes then
    return 413, { detail = "Uploads must be " .. M._upload_limit_label() .. " or smaller." }
  end

  local rl_status, rl_body = ratelimit.check("upload:" .. user.id, M.settings.upload_rate_limit_per_hour, 3600)
  if rl_status then return rl_status, rl_body end

  local original_filename = ((upload.filename or "upload"):match("([^/\\]+)$") or "upload"):sub(1, 255)

  -- defer=true (the website sends this): don't hold the request open for
  -- processing (remux/AI/hash/save). The bytes go to a staging file and
  -- the same background job the chunked path uses takes it from there;
  -- the client gets 202 + job_id right after the quick checks pass.
  -- Without it (older iOS builds), the response still carries the
  -- finished media exactly as before.
  if form_bool(form.defer, false) then
    return M._upload_handoff_bytes(req, user, upload.content, original_filename, form)
  end

  local telemetry_t0 = M.telemetry.now()
  local up_status, up_body, up_headers = finalize_upload(req, user, { content = upload.content }, original_filename, form)
  M.telemetry.record("upload", "direct", up_status == 200 and "success" or "error", M.telemetry.ms_since(telemetry_t0),
    { bytes = #upload.content, media_id = up_status == 200 and up_body and up_body.media and up_body.media.id or nil, status = up_status })
  return up_status, up_body, up_headers
end

-- ---------------------------------------------------------------------------
-- Chunked upload (large videos). The Cloudflare tunnel this deployment sits
-- behind hard-413s any single request body over ~100MB regardless of what
-- M.settings.max_upload_bytes allows -- confirmed live: a 105MB POST gets a
-- Cloudflare-branded 413 before it ever reaches this process, while 95MB
-- goes through fine. M.upload_media above therefore stays correct only up
-- to that edge limit; anything larger (most videos with the cap now raised
-- to 700MB) has to be split into several sub-100MB requests instead of one,
-- which is what this session-based init/append/finish flow does. Sessions
-- are small JSON files next to the staging file (shared by every worker
-- process), pruned in the background at most every 10 minutes.
-- ---------------------------------------------------------------------------

-- Lua's %q escapes for a *Lua* string literal, not a shell argument -- use
-- real single-quote shell escaping instead (same convention as
-- media_files.lua's own shell_quote(), duplicated here since that one is
-- local to that module). Defined this early so upload_chunk_storage.prune()
-- below and the HLS/orphan-cleanup helpers further down the file can both
-- see it as an upvalue -- Lua locals are only visible from their
-- declaration point onward, so a single shared definition has to sit above
-- every caller in source order, not just above whichever caller was added
-- first.
local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local UPLOAD_CHUNK_SESSION_TTL_SECONDS = 2 * 3600
local upload_chunk_storage = {}

-- Upload hand-off pipeline (reworked 2026-10-26).
--
-- Bytes arrive one of three ways -- a single multipart POST (direct), the
-- iOS app's in-order chunks (index only), or the website's parallel chunks
-- (index + offset, any order) -- and land in a staging file. From there a
-- background job does the slow part (faststart remux, hash, fingerprint,
-- AI metadata, store, DB insert) while the client polls
-- /api/media/upload/job/:id.
--
-- Jobs are files (staging dir), not memory, because the proxy spreads
-- requests over several worker processes. Each job records which worker
-- owns it and that worker's boot id; the primary worker resumes jobs whose
-- owner has since restarted (deploys, crashes), so a restart no longer
-- loses an upload that was mid-processing.
--
-- At most FINALIZE_MAX_CONCURRENT jobs run per worker; extra ones wait
-- their turn as "queued" instead of being rejected.
upload_chunk_storage.active_finalize_jobs = 0
upload_chunk_storage.FINALIZE_MAX_CONCURRENT = 3
-- Largest single chunk accepted: the whole request body is held in memory.
upload_chunk_storage.MAX_CHUNK_BYTES = 16 * 1024 * 1024
upload_chunk_storage.boot_id = "unset" -- set by M.configure_storage()
upload_chunk_storage.last_prune = 0

-- Staging lives on the fast-disk tier when configured (config.lua's
-- hot_dir); otherwise in uploads_dir, as before.
function upload_chunk_storage.dir()
  local hot = M.settings.hot_dir
  if hot and hot ~= "" then return hot .. "/staging" end
  return M.settings.uploads_dir
end

function upload_chunk_storage.write_json(path, value)
  local tmp = path .. ".tmp." .. tostring(math.random(100000, 999999))
  local f, err = io.open(tmp, "wb")
  if not f then return nil, err end
  f:write(cjson.encode(value))
  f:close()
  local ok, rename_err = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return nil, rename_err
  end
  return true
end

function upload_chunk_storage.read_json(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  local ok, value = pcall(cjson.decode, text or "")
  return ok and type(value) == "table" and value or nil
end

function upload_chunk_storage.session_path(session_id)
  return upload_chunk_storage.dir() .. "/_upload_sessions_" .. tostring(session_id) .. ".json"
end

function upload_chunk_storage.write(session_id, session)
  return upload_chunk_storage.write_json(upload_chunk_storage.session_path(session_id), session)
end

function upload_chunk_storage.read(session_id)
  return upload_chunk_storage.read_json(upload_chunk_storage.session_path(session_id))
end

function upload_chunk_storage.remove(session_id)
  os.remove(upload_chunk_storage.session_path(session_id))
end

function upload_chunk_storage.job_path(job_id)
  return upload_chunk_storage.dir() .. "/_upload_jobs_" .. tostring(job_id) .. ".json"
end

function upload_chunk_storage.job_write(job_id, job)
  return upload_chunk_storage.write_json(upload_chunk_storage.job_path(job_id), job)
end

function upload_chunk_storage.job_read(job_id)
  return upload_chunk_storage.read_json(upload_chunk_storage.job_path(job_id))
end

function upload_chunk_storage.worker_boot_path(port)
  return upload_chunk_storage.dir() .. "/_upload_worker_" .. tostring(port) .. ".boot"
end

function upload_chunk_storage.list(glob)
  local out = {}
  local handle = io.popen(string.format("find %s -maxdepth 1 -type f -name %s -print 2>/dev/null",
    shell_quote(upload_chunk_storage.dir()), shell_quote(glob)))
  if not handle then return out end
  for path in handle:lines() do out[#out + 1] = path end
  handle:close()
  return out
end

-- Abandoned sessions (no chunk written for 2h), stray direct-upload and
-- remux scratch files, and job records older than a day.
function upload_chunk_storage.prune()
  local dir = shell_quote(upload_chunk_storage.dir())
  local minutes = math.floor(UPLOAD_CHUNK_SESSION_TTL_SECONDS / 60)
  local handle = io.popen(string.format(
    "find %s -maxdepth 1 -type f -name '_upload_sessions_*.part' -mmin +%d -print 2>/dev/null", dir, minutes))
  if handle then
    for path in handle:lines() do
      local session_id = path:match("_upload_sessions_([%x]+)%.part$")
      pcall(os.remove, path)
      pcall(os.remove, path .. ".log")
      if session_id then upload_chunk_storage.remove(session_id) end
    end
    handle:close()
  end
  os.execute(string.format(
    "nice -n 10 find %s -maxdepth 1 -type f \\( -name '_upload_direct_*.part' -o -name 'faststart_*' -o -name '*.tmp.*' \\) -mmin +1440 -delete 2>/dev/null;"
      .. " find %s -maxdepth 1 -type f \\( -name '_upload_jobs_*.json' -o -name '_upload_sessions_*.json' \\) -mmin +1440 -delete 2>/dev/null",
    dir, dir))
end

-- At most every 10 minutes per worker, off the request path.
function upload_chunk_storage.maybe_prune()
  if os.time() - upload_chunk_storage.last_prune < 600 then return end
  upload_chunk_storage.last_prune = os.time()
  require("copas").addthread(function()
    local ok, err = pcall(upload_chunk_storage.prune)
    if not ok then print("[nyxframe] upload prune failed: " .. tostring(err)) end
  end)
end

-- Just the headers request_origin() reads -- what finalize_upload needs
-- from `req` to build absolute URLs. Stored with the job so a resumed job
-- (see recover_jobs) can rebuild a request; never the auth headers.
function upload_chunk_storage.safe_headers(req)
  local h = req.headers or {}
  return { host = h.host, ["x-forwarded-proto"] = h["x-forwarded-proto"], ["x-forwarded-host"] = h["x-forwarded-host"] }
end

-- Cheap checks run before handing off, so obvious mistakes (wrong file
-- type, bad visibility, unparseable date, missing title/category with AI
-- auto-fill off) are reported while the client is still waiting.
-- Title/category left blank WITH auto-fill on resolve during the job.
function upload_chunk_storage.precheck(temp_path, filename, form)
  local prefix = ""
  local f = io.open(temp_path, "rb")
  if f then
    prefix = f:read(512) or ""
    f:close()
  end
  local sniffed_mime = sniff_magic(prefix)
  if not sniffed_mime then return 400, { detail = "Unsupported or invalid file bytes." } end
  if not safe_extension(filename, sniffed_mime) then return 400, { detail = "Unsupported file extension." } end
  local visibility = (nn(form.visibility) or "public"):lower()
  if visibility ~= "public" and visibility ~= "unlisted" and visibility ~= "private" then
    return 400, { detail = "Visibility must be public, unlisted, or private." }
  end
  local _, publish_at_err = parse_publish_at(form.publish_at)
  if publish_at_err then return 400, { detail = publish_at_err } end
  local auto_ai = form_bool(form.auto_ai, true)
  if trim(nn(form.title) or "") == "" and not auto_ai then return 400, { detail = "Title is required." } end
  local category_id = tonumber(form.category_id)
  local has_category_name = nn(form.category_name) and trim(form.category_name) ~= ""
  if not (category_id and category_id > 0) and not has_category_name and not auto_ai then
    return 400, { detail = "Category is required." }
  end
  return nil
end

-- The full media object for a finished post, as finalize_upload returns
-- it -- for a job that died after its DB insert (see run_job/recover_jobs).
function upload_chunk_storage.done_response(req, user, media_id)
  local item = fetch_media_by_id(media_id, tostring(user.id))
  if not item then return nil end
  return { media = decode_media_row(item, viewer_adult_allowed(tostring(user.id)), req),
    possible_duplicates = arr({}), possible_site_duplicates = arr({}) }
end

function upload_chunk_storage.start_job(req, user, temp_path, total_size, filename, form)
  local bad_status, bad_body = upload_chunk_storage.precheck(temp_path, filename, form)
  if bad_status then
    pcall(os.remove, temp_path)
    return bad_status, bad_body
  end
  local job_id = sodium.sodium_bin2hex(sodium.randombytes_buf(16))
  local job = {
    user_id = user.id, status = "queued", stage = "queued", created_at = os.time(), heartbeat = os.time(),
    filename = filename, size = total_size,
    owner_port = M.settings.port, owner_boot = upload_chunk_storage.boot_id,
    input = { temp_path = temp_path, total_size = total_size, filename = filename, form = form,
      headers = upload_chunk_storage.safe_headers(req) },
  }
  local saved, save_err = upload_chunk_storage.job_write(job_id, job)
  if not saved then
    pcall(os.remove, temp_path)
    return 500, { detail = "Could not queue upload for processing: " .. tostring(save_err) }
  end
  require("copas").addthread(function() upload_chunk_storage.run_job(job_id, job, req, user) end)
  return 202, { status = "processing", job_id = job_id }
end

-- Runs one job to completion in its own copas thread. Retries transient
-- failures (Lua error or 5xx) up to 3 attempts, never a 4xx (bad input
-- would fail the same way again), and never once the DB insert happened
-- (stage "finishing" carries the new media id) -- a retry past that point
-- would create a duplicate post, so it reports the post as done instead.
function upload_chunk_storage.run_job(job_id, job, req, user)
  local copas = require("copas")
  local input = job.input
  local temp_path, total_size = input.temp_path, input.total_size
  local function save(fields)
    for k, v in pairs(fields) do job[k] = v end
    job.heartbeat = os.time()
    upload_chunk_storage.job_write(job_id, job)
  end
  local function finish(fields)
    job.input = nil
    save(fields)
    pcall(os.remove, temp_path)
  end

  local last_beat = os.time()
  while upload_chunk_storage.active_finalize_jobs >= upload_chunk_storage.FINALIZE_MAX_CONCURRENT do
    copas.sleep(0.25)
    if os.time() - last_beat >= 15 then
      save({})
      last_beat = os.time()
    end
  end
  upload_chunk_storage.active_finalize_jobs = upload_chunk_storage.active_finalize_jobs + 1
  save({ status = "processing", stage = "starting" })

  local ok_run, run_err = pcall(function()
    local MAX_ATTEMPTS = 3
    local BACKOFF_SECONDS = { 3, 10 }
    local attempt = 1
    while true do
      local telemetry_t0 = M.telemetry.now()
      local ok, status_code, resp_body = pcall(finalize_upload, req, user,
        { file_path = temp_path, file_size = total_size }, input.filename, input.form,
        function(stage, media_id, new_source)
          if new_source and new_source.file_path then
            temp_path, total_size = new_source.file_path, new_source.file_size or total_size
            input.temp_path, input.total_size = temp_path, total_size
          end
          save({ status = "processing", stage = stage, retrying = false, media_id = media_id or job.media_id })
        end)
      local duration_ms = M.telemetry.ms_since(telemetry_t0)

      if ok and status_code == 200 then
        M.telemetry.record("upload", "chunked", "success", duration_ms,
          { bytes = total_size, media_id = resp_body and resp_body.media and resp_body.media.id or nil, attempts = attempt })
        finish({ status = "done", stage = "done", response = resp_body, attempts = attempt })
        return
      end

      local detail = ok and ((resp_body and resp_body.detail) or "Upload failed.") or tostring(status_code)
      if not ok then
        print("[nyxframe] background upload finish error (job " .. job_id .. ", attempt " .. attempt .. "): " .. detail)
      end
      M.telemetry.record("upload", "chunked", "error", duration_ms,
        { bytes = total_size, status = ok and status_code or nil, detail = detail:sub(1, 300), attempt = attempt })

      if job.media_id then
        local done = upload_chunk_storage.done_response(req, user, job.media_id)
        if done then
          finish({ status = "done", stage = "done", response = done, attempts = attempt })
          return
        end
      end

      local retryable = (not ok) or (type(status_code) == "number" and status_code >= 500)
      local source_still_present = io.open(temp_path, "rb")
      if source_still_present then source_still_present:close() end
      if not retryable or not source_still_present or attempt >= MAX_ATTEMPTS then
        finish({ status = "error", detail = ok and detail or "Upload processing failed unexpectedly.",
          attempts = attempt, retrying = false })
        return
      end

      -- Recorded as a failure with retrying=true before the backoff, so a
      -- poll in this window sees what happened rather than a stale stage.
      save({ status = "error", detail = detail, attempts = attempt, retrying = true })
      copas.sleep(BACKOFF_SECONDS[attempt] or BACKOFF_SECONDS[#BACKOFF_SECONDS])
      attempt = attempt + 1
    end
  end)
  upload_chunk_storage.active_finalize_jobs = upload_chunk_storage.active_finalize_jobs - 1
  if not ok_run then
    print("[nyxframe] upload job " .. job_id .. " crashed: " .. tostring(run_err))
    finish({ status = "error", detail = "Upload processing failed unexpectedly.", retrying = false })
  end
end

-- Primary worker only (see M.start_upload_job_recovery): picks up jobs
-- whose owning worker has restarted since it took them.
function upload_chunk_storage.recover_jobs()
  local copas = require("copas")
  for _, path in ipairs(upload_chunk_storage.list("_upload_jobs_*.json")) do
    local job_id = path:match("_upload_jobs_([%x]+)%.json$")
    local job = job_id and upload_chunk_storage.job_read(job_id)
    local unfinished = job and job.input and (job.status == "queued" or job.status == "processing"
      or (job.status == "error" and job.retrying))
    if unfinished then
      local bf = io.open(upload_chunk_storage.worker_boot_path(job.owner_port), "rb")
      local current_boot = bf and bf:read("*a")
      if bf then bf:close() end
      if current_boot ~= job.owner_boot then
        local user = get_user(job.user_id)
        local req = { method = "POST", path = "/api/media/upload/finish", headers = job.input.headers or {}, query = {}, params = {} }
        local src = io.open(job.input.temp_path, "rb")
        if src then src:close() end
        local done = user and job.media_id and upload_chunk_storage.done_response(req, user, job.media_id)
        if done then
          job.input = nil
          job.status, job.stage, job.response, job.retrying = "done", "done", done, false
          upload_chunk_storage.job_write(job_id, job)
        elseif user and src then
          print("[nyxframe] resuming upload job " .. job_id .. " (its worker restarted)")
          job.owner_port, job.owner_boot = M.settings.port, upload_chunk_storage.boot_id
          job.status, job.stage, job.retrying = "queued", "queued", false
          upload_chunk_storage.job_write(job_id, job)
          copas.addthread(function() upload_chunk_storage.run_job(job_id, job, req, user) end)
        else
          job.input = nil
          job.status, job.retrying = "error", false
          job.detail = "Processing was interrupted by a server restart. Please upload the file again."
          upload_chunk_storage.job_write(job_id, job)
        end
      end
    end
  end
end

-- Called once per worker at startup (main.lua): turns on the fast-disk
-- tier and records this worker's boot id for job ownership.
function M.configure_storage()
  local hot = M.settings.hot_dir
  if hot and hot ~= "" then
    os.execute("mkdir -p " .. shell_quote(hot .. "/staging") .. " " .. shell_quote(hot .. "/media"))
    media_files.hot_root = hot
  end
  upload_chunk_storage.boot_id = sodium.sodium_bin2hex(sodium.randombytes_buf(8))
  local f = io.open(upload_chunk_storage.worker_boot_path(M.settings.port), "wb")
  if f then
    f:write(upload_chunk_storage.boot_id)
    f:close()
  end
end

function M.start_upload_job_recovery()
  local copas = require("copas")
  copas.addthread(function()
    copas.sleep(5) -- let the other workers write their boot ids first
    while true do
      local ok, err = pcall(upload_chunk_storage.recover_jobs)
      if not ok then print("[nyxframe] upload job recovery failed: " .. tostring(err)) end
      copas.sleep(60)
    end
  end)
end

-- Primary worker only: keeps the fast-disk tier under hot_max_gb (and the
-- disk itself above hot_min_free_gb) by moving the oldest originals to
-- uploads_dir. Copy to a temp name, rename into place, then delete the
-- fast copy -- lookups check the fast tier first, so a file is always
-- readable from one tier or the other, and a reader that already has the
-- fast copy open keeps reading it after the delete.
-- One pass; returns how many files were moved. Must run in a copas thread
-- (the copies run in the background while it yields).
function M._hot_tier_pass()
  local hot = M.settings.hot_dir
  if not hot or hot == "" then return 0 end
  local function read_cmd(cmd)
    local h = io.popen(cmd)
    if not h then return "" end
    local out = h:read("*a") or ""
    h:close()
    return out
  end
  do
    local used_kb = tonumber(read_cmd("du -sk " .. shell_quote(hot .. "/media") .. " 2>/dev/null"):match("^(%d+)")) or 0
    local free_kb = tonumber(read_cmd("df -k " .. shell_quote(hot) .. " 2>/dev/null | tail -1"):match("^%S+%s+%d+%s+%d+%s+(%d+)")) or math.huge
    local max_kb = M.settings.hot_max_gb * 1024 * 1024
    local min_free_kb = M.settings.hot_min_free_gb * 1024 * 1024
    if used_kb <= max_kb and free_kb >= min_free_kb then return 0 end
    -- Move oldest first until 80% of the cap and the free-space floor are met.
    local target_used = math.floor(max_kb * 0.8)
    local files = {}
    for line in read_cmd("find " .. shell_quote(hot .. "/media") .. " -type f ! -name '*.tmp.*' -exec stat -c '%Y %s %n' {} + 2>/dev/null"):gmatch("[^\n]+") do
      local mtime, size, path = line:match("^(%d+) (%d+) (.+)$")
      if path then files[#files + 1] = { tonumber(mtime), tonumber(size), path } end
    end
    table.sort(files, function(a, b) return a[1] < b[1] end)
    local moved = 0
    for _, file in ipairs(files) do
      if used_kb <= target_used and free_kb >= min_free_kb then break end
      local rel = file[3]:sub(#hot + 2)
      local cold = M.settings.uploads_dir .. "/" .. rel
      local cold_dir = cold:match("^(.*)/[^/]+$")
      local tmp = cold .. ".tmp." .. tostring(math.random(100000, 999999))
      local code = os.execute(string.format(
        "nice -n 19 ionice -c3 sh -c %s",
        shell_quote(string.format("mkdir -p %s && { [ -f %s ] || { cp -f %s %s && mv -f %s %s; }; }",
          shell_quote(cold_dir), shell_quote(cold), shell_quote(file[3]), shell_quote(tmp), shell_quote(tmp), shell_quote(cold)))))
      if code == 0 or code == true then
        os.remove(file[3])
        moved = moved + 1
        used_kb = used_kb - math.floor(file[2] / 1024)
        free_kb = free_kb + math.floor(file[2] / 1024)
      else
        os.remove(tmp)
        print("[nyxframe] hot tier: could not move " .. rel .. " to the uploads drive")
        break
      end
    end
    return moved
  end
end

function M.start_hot_tier_mover()
  local hot = M.settings.hot_dir
  if not hot or hot == "" then return end
  local copas = require("copas")
  copas.addthread(function()
    copas.sleep(120)
    while true do
      local ok, moved = pcall(M._hot_tier_pass)
      if not ok then
        print("[nyxframe] hot tier mover failed: " .. tostring(moved))
      elseif moved > 0 then
        print(string.format("[nyxframe] hot tier: moved %d originals to the uploads drive", moved))
      end
      copas.sleep(600)
    end
  end)
end

-- "2 GB" / "700 MB" for limit messages.
function M._upload_limit_label()
  local bytes = M.settings.max_upload_bytes
  local gb = bytes / (1024 * 1024 * 1024)
  if gb >= 1 then
    return (gb == math.floor(gb) and string.format("%d GB", gb) or string.format("%.1f GB", gb))
  end
  return string.format("%d MB", math.floor(bytes / (1024 * 1024)))
end

-- Free space (KB) where uploads are staged; cached for 10s (df is a
-- subprocess, and init can be called many times in a batch).
function upload_chunk_storage.free_kb()
  local now = os.time()
  local cache = upload_chunk_storage.free_cache
  if cache and now - cache.at < 10 then return cache.kb end
  local h = io.popen("df -k " .. shell_quote(upload_chunk_storage.dir()) .. " 2>/dev/null | tail -1")
  local line = h and h:read("*a") or ""
  if h then h:close() end
  local kb = tonumber(line:match("^%S+%s+%d+%s+%d+%s+(%d+)"))
  upload_chunk_storage.free_cache = { at = now, kb = kb }
  return kb
end

-- Direct POST /api/media with defer=true: stage the bytes and hand off.
function M._upload_handoff_bytes(req, user, content, filename, form)
  local temp_path = upload_chunk_storage.dir() .. "/_upload_direct_" .. sodium.sodium_bin2hex(sodium.randombytes_buf(16)) .. ".part"
  local f, ferr = io.open(temp_path, "wb")
  if not f then return 500, { detail = "Could not stage upload: " .. tostring(ferr) } end
  f:write(content)
  f:close()
  local plain_form = {}
  for k, v in pairs(form or {}) do
    if type(v) == "string" then plain_form[k] = v end
  end
  plain_form.defer = nil
  upload_chunk_storage.maybe_prune()
  return upload_chunk_storage.start_job(req, user, temp_path, #content, filename, plain_form)
end

function M.upload_chunk_init(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end

  local rl_status, rl_body = ratelimit.check("upload:" .. user.id, M.settings.upload_rate_limit_per_hour, 3600)
  if rl_status then return rl_status, rl_body end

  upload_chunk_storage.maybe_prune()

  local json = req.json or {}
  local total_size = tonumber(json.total_size)
  local filename = ((nn(json.filename) or "upload"):match("([^/\\]+)$") or "upload"):sub(1, 255)
  if not total_size or total_size <= 0 then
    return 400, { detail = "total_size is required." }
  end
  if total_size > M.settings.max_upload_bytes then
    return 413, { detail = "Uploads must be " .. M._upload_limit_label() .. " or smaller." }
  end

  -- Room for the file, a remuxed copy of it, and 2GB to spare -- refuse
  -- up front rather than fail after the whole thing has been sent.
  local free_kb = upload_chunk_storage.free_kb()
  if free_kb and free_kb * 1024 < total_size * 2 + 2 * 1024 * 1024 * 1024 then
    return 507, { detail = "The server is low on storage space right now. Please try again later or upload a smaller file." }
  end

  local session_id = sodium.sodium_bin2hex(sodium.randombytes_buf(16))
  local temp_path = upload_chunk_storage.dir() .. "/_upload_sessions_" .. session_id .. ".part"
  local f, ferr = io.open(temp_path, "wb")
  if not f then return 500, { detail = "Could not start upload: " .. tostring(ferr) } end
  f:close()

  local session = {
    user_id = user.id,
    temp_path = temp_path,
    filename = filename,
    total_size = total_size,
    received_bytes = 0,
    next_index = 0,
    created_at = os.time(),
  }
  local saved, save_err = upload_chunk_storage.write(session_id, session)
  if not saved then
    os.remove(temp_path)
    return 500, { detail = "Could not persist upload session: " .. tostring(save_err) }
  end

  -- chunk_size stays 4MB for in-order clients: iOS throttles background
  -- transfers, and Cloudflare drops a request that takes over ~120s, so a
  -- chunk must stay small enough to arrive well inside that even when
  -- throttled. Clients that send `offset` (parallel mode) may use any size
  -- up to max_chunk_size.
  return 200, {
    session_id = session_id,
    chunk_size = 4 * 1024 * 1024,
    max_chunk_size = upload_chunk_storage.MAX_CHUNK_BYTES,
    parallel = true,
  }
end

-- POST /api/media/upload/chunk?session_id=..&index=N[&offset=B]
--
-- With `offset`: the chunk is written at that byte offset, in any order
-- and from several connections at once; each write is logged to
-- <part>.log (one short O_APPEND line, safe across worker processes) and
-- finish checks the logged ranges cover the whole file. Without it: the
-- original in-order append (iOS), where re-sending the chunk that was
-- just accepted (a retry after a lost response) is acknowledged instead
-- of failing with 409.
function M.upload_chunk_append(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end

  local session_id = nn(req.query and req.query.session_id)
  local session = session_id and upload_chunk_storage.read(session_id)
  if not session or session.user_id ~= user.id then
    return 404, { detail = "Upload session not found or expired." }
  end
  local chunk = req.raw_body or ""
  if chunk == "" then
    return 400, { detail = "Empty chunk." }
  end
  if #chunk > upload_chunk_storage.MAX_CHUNK_BYTES then
    return 413, { detail = "Chunk is too large." }
  end

  local offset = tonumber(req.query and req.query.offset)
  if offset then
    if offset < 0 or offset ~= math.floor(offset) or offset + #chunk > session.total_size then
      return 400, { detail = "Chunk falls outside the file size declared at upload start." }
    end
    local f, ferr = io.open(session.temp_path, "r+b")
    if not f then return 404, { detail = "Upload session not found or expired." } end
    f:seek("set", offset)
    local wrote, werr = f:write(chunk)
    f:close()
    if not wrote then return 500, { detail = "Could not write chunk: " .. tostring(werr) } end
    local log, lerr = io.open(session.temp_path .. ".log", "ab")
    if not log then return 500, { detail = "Could not record chunk: " .. tostring(lerr) } end
    log:write(string.format("%d %d\n", offset, #chunk))
    log:close()
    return 200, { ok = true }
  end

  local index = tonumber(req.query and req.query.index)
  if index and index == session.next_index - 1 and session.last_chunk_bytes == #chunk then
    return 200, { ok = true, received_bytes = session.received_bytes, duplicate = true }
  end
  if not index or index ~= session.next_index then
    return 409, { detail = "Chunks must be uploaded in order, starting at 0." }
  end
  if session.received_bytes + #chunk > session.total_size then
    pcall(os.remove, session.temp_path)
    upload_chunk_storage.remove(session_id)
    return 413, { detail = "Received more bytes than declared at upload start." }
  end

  local f, ferr = io.open(session.temp_path, "ab")
  if not f then return 500, { detail = "Could not write chunk: " .. tostring(ferr) } end
  f:write(chunk)
  f:close()

  session.received_bytes = session.received_bytes + #chunk
  session.next_index = session.next_index + 1
  session.last_chunk_bytes = #chunk
  local saved, save_err = upload_chunk_storage.write(session_id, session)
  if not saved then
    return 500, { detail = "Could not persist upload progress: " .. tostring(save_err) }
  end
  return 200, { ok = true, received_bytes = session.received_bytes }
end

function M.upload_chunk_finish(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end

  local form = req.json or {}
  local session_id = nn(form.session_id)
  local session = session_id and upload_chunk_storage.read(session_id)
  if not session or session.user_id ~= user.id then
    return 404, { detail = "Upload session not found or expired." }
  end
  local temp_path = session.temp_path
  local total_size = session.total_size
  if not total_size or total_size == 0 then
    pcall(os.remove, temp_path)
    upload_chunk_storage.remove(session_id)
    return 400, { detail = "Upload is empty." }
  end

  -- Incomplete uploads keep their session, so the client can send what's
  -- missing (missing_from) and call finish again.
  local log = io.open(temp_path .. ".log", "rb")
  if log then
    local ranges = {}
    for line in log:lines() do
      local o, l = line:match("^(%d+) (%d+)$")
      if o then ranges[#ranges + 1] = { tonumber(o), tonumber(l) } end
    end
    log:close()
    table.sort(ranges, function(a, b) return a[1] < b[1] end)
    local covered = 0
    for _, r in ipairs(ranges) do
      if r[1] > covered then break end
      if r[1] + r[2] > covered then covered = r[1] + r[2] end
    end
    if covered < total_size then
      return 400, { detail = string.format("Upload is incomplete: missing data from byte %d of %d.", covered, total_size), missing_from = covered }
    end
    os.remove(temp_path .. ".log")
  elseif session.received_bytes ~= total_size then
    return 400, { detail = "Upload is incomplete: expected " .. total_size .. " bytes, received " .. session.received_bytes .. "." }
  end
  upload_chunk_storage.remove(session_id)

  -- Session metadata arrives as JSON; finalize_upload's helpers expect the
  -- string values a multipart form would give, so coerce booleans/arrays.
  local plain_form = {}
  for k, v in pairs(form) do
    if type(v) == "boolean" then
      plain_form[k] = v and "true" or "false"
    elseif type(v) == "table" then
      plain_form[k] = cjson.encode(v)
    elseif v ~= cjson.null then
      plain_form[k] = tostring(v)
    end
  end
  return upload_chunk_storage.start_job(req, user, temp_path, total_size, session.filename, plain_form)
end

-- GET /api/media/upload/job/:job_id -- outcome of a background job (see
-- start_job). While running it also reports `stage` (queued, starting,
-- optimizing, analyzing, fingerprinting, saving, finishing) for progress UI.
function M.upload_job_status(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end

  local job_id = nn(req.params and req.params.job_id)
  local job = job_id and upload_chunk_storage.job_read(job_id)
  if not job or tostring(job.user_id) ~= tostring(user.id) then
    return 404, { detail = "Upload job not found or expired." }
  end

  if job.status == "done" then
    local r = job.response or {}
    local media = r.media
    if media then
      -- The response went through a cjson encode/decode round trip on
      -- disk, which turns empty arrays into empty objects; iOS's strict
      -- Codable models reject that, so re-mark every array field.
      media.tags = arr(media.tags)
      media.subcategories = arr(media.subcategories)
      media.subcategory_ids = arr(media.subcategory_ids)
      media.subcategory_names = arr(media.subcategory_names)
    end
    return 200, { status = "done", media = media, possible_duplicates = arr(r.possible_duplicates), possible_site_duplicates = arr(r.possible_site_duplicates) }
  elseif job.status == "error" then
    -- retrying=true: a failed attempt that is about to be retried, not the
    -- final outcome.
    return 200, { status = "error", detail = job.detail or "Upload failed.", retrying = job.retrying or false, attempts = job.attempts }
  end
  return 200, { status = "processing", stage = job.stage or "queued", queued = job.status == "queued" }
end

-- Standalone "preview the AI suggestion before uploading" endpoint. Mirrors
-- app/routers/media.py's analyze_media_upload(): does NOT save anything --
-- just runs the same analysis + possible-duplicate check upload_media does
-- and returns the result for a client to show as a suggestion.
function M.analyze_media(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end

  local form = req.form or {}
  local upload = (req.files or {}).file
  if not upload or not upload.content or upload.content == "" then
    return 400, { detail = "Upload is empty." }
  end
  if #upload.content > M.settings.max_upload_bytes then
    return 413, { detail = "Uploads must be " .. M._upload_limit_label() .. " or smaller." }
  end

  local rl_status, rl_body = ratelimit.check("analyze:" .. user.id, M.settings.analyze_rate_limit_per_hour, 3600)
  if rl_status then return rl_status, rl_body end

  local sniffed_mime, media_kind = sniff_magic(upload.content)
  if not sniffed_mime then return 400, { detail = "Unsupported or invalid file bytes." } end
  local original_filename = ((upload.filename or "upload"):match("([^/\\]+)$") or "upload"):sub(1, 255)

  local title_hint = trim(nn(form.title) or ""):sub(1, 160)
  local description_hint = trim(nn(form.description) or "")
  local tags_hint = parse_tags(form.tags)

  local analysis
  if M.settings.ai_enabled and (media_kind == "image" or media_kind == "video") then
    local telemetry_t0 = M.telemetry.now()
    local ok, result = pcall(ai_metadata.analyze_media_bytes, {
      content = upload.content, filename = original_filename, mime_type = sniffed_mime, media_kind = media_kind,
      title_hint = title_hint, description_hint = description_hint, tags_hint = tags_hint, settings = M.settings,
    })
    M.telemetry.record("upload", "ai_analyze", ok and "success" or "error", M.telemetry.ms_since(telemetry_t0),
      { provider = M.settings.ai_provider, media_kind = media_kind, error = (not ok) and tostring(result):sub(1, 300) or nil })
    if ok then analysis = result end
  end
  if not analysis then
    analysis = ai_metadata.heuristic_analysis(original_filename, sniffed_mime, media_kind, title_hint, description_hint, tags_hint, media_files.media_dimensions(upload.content))
  end

  local fingerprint = media_kind == "image" and media_files.image_fingerprint(upload.content) or nil
  local possible_duplicates = find_possible_duplicates(req, user.id, fingerprint)

  return 200, {
    analysis = {
      title = analysis.title,
      suggested_filename = analysis.suggested_filename,
      tags = arr(analysis.tags),
      category_name = analysis.category_name,
      subcategory_name = analysis.subcategory_name,
      subcategory_names = arr(analysis.subcategory_names),
      is_adult = analysis.is_adult,
      source = analysis.source,
      confidence = analysis.confidence,
      reason = analysis.reason,
      description = analysis.description,
    },
    media_kind = media_kind,
    mime_type = sniffed_mime,
    original_filename = original_filename,
    possible_duplicates = arr(possible_duplicates),
  }
end

-- ---------------------------------------------------------------------------
-- Media edit/delete/moderation follow-ups: edit, controls-only patch,
-- soft-delete/restore, report, comment delete, similar-media, and bulk
-- edit/delete. Mirrors app/routers/media.py's edit_media/set_media_controls/
-- delete_media/restore_media/report_media/delete_comment/similar_media/
-- bulk_edit_media/bulk_delete_media + the corresponding app/db/media.py
-- functions. NOT ported: the AI-auto-train-on-edit side effect (requires the
-- LLM pipeline, see TODO.md) and multi-subcategory arrays (single
-- subcategory_id/subcategory_name only, matching the rest of this file).
-- ---------------------------------------------------------------------------

-- Shared by M.update_media and M.bulk_edit_media. Returns (nil, item) on
-- success or (status, error_message) on failure -- mirrors update_media()'s
-- ValueError/PermissionError/None-return cases as explicit return values
-- since Lua has no exceptions worth structuring control flow around here.
local function perform_update_media(media_id, owner_id, payload)
  local title = trim(nn(payload.title) or ""):gsub("%s+", " "):sub(1, 160)
  if title == "" then return 400, "Title is required." end
  local description = trim(nn(payload.description) or ""):gsub("%s+", " "):sub(1, 2000)

  local clean_tags, seen = {}, {}
  if type(payload.tags) == "table" then
    for _, raw in ipairs(payload.tags) do
      local tag = tostring(raw):gsub("[^%w_.%-]+", ""):sub(1, 32)
      local lowered = tag:lower()
      if tag ~= "" and not seen[lowered] then
        seen[lowered] = true
        clean_tags[#clean_tags + 1] = tag
        if #clean_tags >= 12 then break end
      end
    end
  end

  local category_id = tonumber(payload.category_id) or 0
  if category_id <= 0 then return 400, "A category is required." end
  local requested_ids = normalize_subcategory_ids(payload.subcategory_ids)
  if #requested_ids == 0 and nn(payload.subcategory_id) then
    requested_ids = normalize_subcategory_ids({ payload.subcategory_id })
  end
  local requested_names = normalize_subcategory_names(payload.subcategory_names)
  if #requested_names == 0 and nn(payload.subcategory_name) and trim(payload.subcategory_name) ~= "" then
    requested_names = normalize_subcategory_names({ payload.subcategory_name })
  end
  local resolved_subcategory_ids, subcat_err = resolve_subcategory_ids(category_id, requested_ids, requested_names, owner_id)
  if not resolved_subcategory_ids then return 400, subcat_err end

  local visibility = tostring(payload.visibility or "public"):lower()
  if visibility ~= "public" and visibility ~= "unlisted" and visibility ~= "private" then
    return 400, "Visibility must be public, unlisted, or private."
  end
  local is_adult = payload.is_adult and true or false
  local comments_enabled = true
  if payload.comments_enabled ~= nil then comments_enabled = payload.comments_enabled and true or false end
  local downloads_enabled = true
  if payload.downloads_enabled ~= nil then downloads_enabled = payload.downloads_enabled and true or false end
  local pinned = payload.pinned and "1" or "0"

  -- Scheduled publishing. Every feed query already honours publish_at (it
  -- hides a future-dated post from everyone but its owner) and the Studio
  -- card already renders a "Scheduled for ..." pill -- but nothing in the
  -- entire codebase ever WROTE the column, so the whole feature was
  -- unreachable. This is the write half.
  --
  -- Deliberately only touched when the caller explicitly says so. Absent key
  -- (nil) means "leave the schedule alone"; JSON null or an empty string
  -- means "clear it". That distinction is load-bearing rather than
  -- fastidious: M.bulk_edit_media rebuilds a full payload out of each post's
  -- CURRENT values and hands it here, and its `merged` table has no
  -- publish_at in it -- so an unconditional write would silently clear the
  -- schedule of every post touched by an unrelated bulk visibility change.
  --
  -- Accepts "2026-09-05T18:00" and "2026-09-05 18:00" alike, with or without
  -- seconds and offset. Postgres does the real parsing; this only rejects
  -- shapes that clearly are not a datetime, so a typo comes back as a 400
  -- rather than a database error. Stored as naive UTC to match created_at:
  -- this deployment's session timezone is UTC, so `publish_at <= now()` in
  -- the feed queries compares correctly.
  -- Same explicit-only contract as publish_at below, and for the same
  -- reason: M.bulk_edit_media rebuilds a full payload from each post's
  -- current values and its `merged` table carries no source_url, so an
  -- unconditional write would blank the source of every post caught by an
  -- unrelated bulk edit. Absent leaves it alone; null/"" clears it.
  local source_clause, source_param = "", nil
  if payload.source_url ~= nil then
    if payload.source_url == cjson.null or trim(tostring(payload.source_url)) == "" then
      source_clause = ",\n        source_url=NULL"
    else
      local normalized, source_err = M.normalize_source_url(payload.source_url)
      if source_err then return 400, source_err end
      source_clause = ",\n        source_url=%s"
      source_param = normalized
    end
  end

  local publish_clause, publish_param = "", nil
  if payload.publish_at ~= nil then
    local raw = payload.publish_at
    if raw == cjson.null or trim(tostring(raw)) == "" then
      publish_clause = ",\n        publish_at=NULL"
    else
      local when = trim(tostring(raw))
      if not when:match("^%d%d%d%d%-%d%d%-%d%d[T ]%d%d:%d%d") then
        return 400, "Schedule time must look like 2026-09-05T18:00."
      end
      publish_clause = ",\n        publish_at=(%s)::timestamptz AT TIME ZONE 'UTC'"
      publish_param = when:sub(1, 40)
    end
  end

  local row = db.fetchone(
    "SELECT user_id, title, description, tags, category_id, visibility, is_adult FROM media_items WHERE id=%s AND deleted_at IS NULL",
    tostring(media_id))
  if not row then return 404, "Media not found." end
  if tostring(row.user_id) ~= tostring(owner_id) then return 403, "Only the uploader can edit this post." end

  -- Snapshot the fields a viewer actually cares about before they're
  -- overwritten below, so M.media_edit_history has something to diff
  -- against. Only fields that actually changed get recorded.
  local new_tags_json = cjson.encode(arr(clean_tags))
  local edit_changes = {}
  if nn(row.title) ~= title then edit_changes.title = { from = row.title, to = title } end
  if (nn(row.description) or "") ~= description then edit_changes.description = { from = row.description, to = description } end
  if nn(row.tags) ~= new_tags_json then edit_changes.tags = { from = row.tags, to = new_tags_json } end
  if tostring(db.toint(row.category_id, row.category_id)) ~= tostring(category_id) then
    edit_changes.category_id = { from = row.category_id, to = category_id }
  end
  if tostring(row.visibility) ~= visibility then edit_changes.visibility = { from = row.visibility, to = visibility } end
  if db.tobool(row.is_adult) ~= is_adult then edit_changes.is_adult = { from = db.tobool(row.is_adult), to = is_adult } end

  -- Built by concatenation rather than string.format: the template is itself
  -- full of %s placeholders for db.execute to fill, so formatting it here
  -- would consume them.
  local sql = [[
    UPDATE media_items
    SET title=%s, description=%s, tags=%s, category_id=%s,
        visibility=%s, comments_enabled=%s, downloads_enabled=%s,
        pinned_at=CASE WHEN %s=1 THEN COALESCE(pinned_at, CURRENT_TIMESTAMP) ELSE NULL END,
        is_adult=%s, adult_marked_by_user=%s,
        moderation_status=CASE WHEN %s THEN 'adult' ELSE moderation_status END,
        moderation_reason=CASE WHEN %s THEN 'Uploader marked this post as 18+.' ELSE moderation_reason END,
        moderated_at=CASE WHEN %s THEN CURRENT_TIMESTAMP ELSE moderated_at END]]
    .. source_clause .. publish_clause .. [[

    WHERE id=%s AND user_id=%s
  ]]

  local params = {
    title, description, new_tags_json, tostring(category_id),
    visibility, comments_enabled, downloads_enabled,
    pinned, is_adult, is_adult, is_adult, is_adult, is_adult,
  }
  -- Positional, so this has to land between the moderated_at CASE and the
  -- WHERE clause -- exactly where publish_clause was spliced in above.
  -- Positional: source_clause is spliced BEFORE publish_clause above, so
  -- its parameter has to be appended first.
  if source_param then params[#params + 1] = source_param end
  if publish_param then params[#params + 1] = publish_param end
  params[#params + 1] = tostring(media_id)
  params[#params + 1] = owner_id
  db.execute(sql, unpack(params))
  write_media_subcategories(media_id, resolved_subcategory_ids)

  if next(edit_changes) then
    db.execute("INSERT INTO media_edit_history (media_id, editor_id, changes) VALUES (%s, %s, %s)",
      tostring(media_id), owner_id, cjson.encode(edit_changes))
  end

  return nil, fetch_media_by_id(media_id, tostring(owner_id))
end

function M.update_media(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local payload = json_body(req)

  local err_status, result = perform_update_media(media_id, user.id, payload)
  if err_status then return err_status, { detail = result } end
  local adult_allowed = viewer_adult_allowed(tostring(user.id))
  return 200, { media = decode_media_row(result, adult_allowed, req) }
end

-- Owner-only: previous edits aren't shown to other viewers, same as any
-- other uploader-facing control (M.set_media_controls, M.delete_media, ...).
function M.media_edit_history(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end

  local row = db.fetchone("SELECT user_id FROM media_items WHERE id=%s", tostring(media_id))
  if not row then return 404, { detail = "Media not found." } end
  if tostring(row.user_id) ~= tostring(user.id) then return 403, { detail = "Only the uploader can view this post's edit history." } end

  local rows = db.fetchall([[
    SELECT h.id, h.editor_id, h.changes, h.created_at, u.username, u.display_name
    FROM media_edit_history h JOIN users u ON u.id = h.editor_id
    WHERE h.media_id=%s
    ORDER BY h.created_at DESC
    LIMIT 100
  ]], tostring(media_id))

  local entries = {}
  for _, r in ipairs(rows) do
    local ok, changes = pcall(cjson.decode, r.changes)
    entries[#entries + 1] = {
      id = db.toint(r.id, r.id),
      editor_id = db.toint(r.editor_id, r.editor_id),
      username = r.username,
      display_name = r.display_name,
      changes = ok and changes or {},
      created_at = r.created_at,
    }
  end
  return 200, { history = arr(entries) }
end

function M.set_media_controls(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local payload = json_body(req)

  local updates, params = {}, {}
  if nn(payload.visibility) then
    local v = tostring(payload.visibility):lower()
    if v ~= "public" and v ~= "unlisted" and v ~= "private" then
      return 400, { detail = "Visibility must be public, unlisted, or private." }
    end
    updates[#updates + 1] = "visibility=%s"; params[#params + 1] = v
  end
  if payload.comments_enabled ~= nil then
    updates[#updates + 1] = "comments_enabled=%s"; params[#params + 1] = payload.comments_enabled and true or false
  end
  if payload.downloads_enabled ~= nil then
    updates[#updates + 1] = "downloads_enabled=%s"; params[#params + 1] = payload.downloads_enabled and true or false
  end
  if payload.pinned ~= nil then
    updates[#updates + 1] = "pinned_at=CASE WHEN %s=1 THEN COALESCE(pinned_at, CURRENT_TIMESTAMP) ELSE NULL END"
    params[#params + 1] = payload.pinned and "1" or "0"
  end
  -- Same explicit-only contract as perform_update_media's publish_at (see
  -- its comment): absent leaves the schedule alone, null/"" clears it. This
  -- endpoint is already a sparse patch, so that falls out naturally here.
  if payload.publish_at ~= nil then
    if payload.publish_at == cjson.null or trim(tostring(payload.publish_at)) == "" then
      updates[#updates + 1] = "publish_at=NULL"
    else
      local when = trim(tostring(payload.publish_at))
      if not when:match("^%d%d%d%d%-%d%d%-%d%d[T ]%d%d:%d%d") then
        return 400, { detail = "Schedule time must look like 2026-09-05T18:00." }
      end
      updates[#updates + 1] = "publish_at=(%s)::timestamptz AT TIME ZONE 'UTC'"
      params[#params + 1] = when:sub(1, 40)
    end
  end

  local row = db.fetchone("SELECT user_id FROM media_items WHERE id=%s AND deleted_at IS NULL", tostring(media_id))
  if not row then return 404, { detail = "Media not found." } end
  if tostring(row.user_id) ~= tostring(user.id) then return 403, { detail = "Only the uploader can change post controls." } end

  if #updates > 0 then
    params[#params + 1] = tostring(media_id)
    params[#params + 1] = user.id
    db.execute("UPDATE media_items SET " .. table.concat(updates, ", ") .. " WHERE id=%s AND user_id=%s", unpack(params))
  end

  local updated = fetch_media_by_id(media_id, tostring(user.id))
  local adult_allowed = viewer_adult_allowed(tostring(user.id))
  return 200, { media = decode_media_row(updated, adult_allowed, req) }
end

-- Shared by M.delete_media and M.bulk_delete_media. Returns the pre-delete
-- item row on success, nil if not found or not owned by owner_id.
local function perform_delete_media(media_id, owner_id)
  local item = fetch_media_by_id(media_id, tostring(owner_id))
  if not item or tostring(item.user_id) ~= tostring(owner_id) then return nil end
  db.execute(
    "UPDATE media_items SET deleted_at=CURRENT_TIMESTAMP, visibility='private' WHERE id=%s AND user_id=%s AND deleted_at IS NULL",
    tostring(media_id), owner_id)
  return item
end

function M.delete_media(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local item = perform_delete_media(media_id, user.id)
  if not item then return 404, { detail = "Media not found." } end
  return 200, { deleted = true }
end

function M.restore_media(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end

  local row = db.fetchone("SELECT user_id FROM media_items WHERE id=%s", tostring(media_id))
  if not row then return 404, { detail = "Media not found." } end
  if tostring(row.user_id) ~= tostring(user.id) then return 403, { detail = "Only the uploader can restore this post." } end
  db.execute("UPDATE media_items SET deleted_at=NULL, visibility='private' WHERE id=%s AND user_id=%s", tostring(media_id), user.id)

  local updated = fetch_media_by_id(media_id, tostring(user.id))
  local adult_allowed = viewer_adult_allowed(tostring(user.id))
  return 200, { media = decode_media_row(updated, adult_allowed, req) }
end

function M.report_media(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local payload = json_body(req)
  local reason = trim(nn(payload.reason) or ""):gsub("%s+", " "):sub(1, 80)
  if reason == "" then return 400, { detail = "A reason is required." } end
  local details = trim(nn(payload.details) or ""):gsub("%s+", " "):sub(1, 500)
  if details == "" then details = nil end

  local item = fetch_media_by_id(media_id, tostring(user.id))
  local vstatus, vbody = ensure_media_visible(item, tostring(user.id))
  if vstatus then return vstatus, vbody end

  db.execute([[
    INSERT INTO media_reports (media_id, user_id, reason, details)
    VALUES (%s, %s, %s, %s)
    ON CONFLICT (media_id, user_id) DO UPDATE SET reason=EXCLUDED.reason, details=EXCLUDED.details, status='open', created_at=CURRENT_TIMESTAMP
  ]], tostring(media_id), user.id, reason, details)

  local report = db.fetchone("SELECT * FROM media_reports WHERE media_id=%s AND user_id=%s", tostring(media_id), user.id)
  if report then
    report.id = db.toint(report.id, report.id)
    report.media_id = db.toint(report.media_id, report.media_id)
    report.user_id = db.toint(report.user_id, report.user_id)
  end
  return 200, { report = report }
end

function M.delete_comment(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local comment_id = tonumber(req.params.comment_id)
  if not comment_id then return 404, { detail = "Comment not found." } end

  local row = db.fetchone([[
    SELECT cm.id, cm.user_id AS comment_user_id, m.user_id AS media_user_id
    FROM media_comments cm JOIN media_items m ON m.id=cm.media_id
    WHERE cm.id=%s
  ]], tostring(comment_id))
  if not row then return 404, { detail = "Comment not found." } end
  if tostring(row.comment_user_id) ~= tostring(user.id) and tostring(row.media_user_id) ~= tostring(user.id) then
    return 403, { detail = "Only the commenter or post owner can delete this comment." }
  end
  db.execute("DELETE FROM media_comments WHERE id=%s", tostring(comment_id))
  return 200, { deleted = true }
end

-- Real paginated "More like this" feed, not just the fixed 12-item rail
-- M.media_detail shows inline -- previously this route existed with its
-- own independently-written (and slightly cruder: fixed to the first 8
-- tags, no offset/pagination at all) copy of that same scoring logic,
-- but nothing in either frontend ever actually called it. Now backs a
-- real dedicated "more like this" page/infinite-scroll feed.
function M.similar_media(req)
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local adult_allowed = viewer_adult_allowed(viewer_id)

  local source = fetch_media_by_id(media_id, viewer_id or "0")
  if not source or nn(source.deleted_at) then return 200, { media = {} } end

  local limit = bounded_limit(req.query.limit, 24, 60)
  local offset = bounded_offset(req.query.offset)
  local rows = compute_similar_media(req, media_id, source, adult_allowed, limit, offset)
  return 200, { media = arr(rows), limit = limit, offset = offset }
end

local BULK_PATCH_FIELDS = {
  visibility = true, comments_enabled = true, downloads_enabled = true, pinned = true, is_adult = true,
}

function M.bulk_edit_media(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local owner_flag = is_site_owner(user)

  local ids, seen = {}, {}
  if type(payload.ids) == "table" then
    for _, raw in ipairs(payload.ids) do
      local id = tonumber(raw)
      if id and id > 0 and not seen[id] then
        seen[id] = true
        ids[#ids + 1] = id
        if #ids >= 200 then break end
      end
    end
  end

  local patch = type(payload.patch) == "table" and payload.patch or {}
  local add_tag = nn(patch.add_tag) and normalize_upload_tag(patch.add_tag) or ""
  local overrides = {}
  for k, v in pairs(patch) do
    if BULK_PATCH_FIELDS[k] then overrides[k] = v end
  end

  local results = {}
  for _, media_id in ipairs(ids) do
    local existing = fetch_media_by_id(media_id, tostring(user.id))
    if not existing or nn(existing.deleted_at) then
      results[#results + 1] = { id = media_id, ok = false, error = "Not found." }
    else
      local owner_id = db.toint(existing.user_id, existing.user_id)
      if owner_id ~= user.id and not owner_flag then
        results[#results + 1] = { id = media_id, ok = false, error = "Forbidden." }
      else
        local tags = {}
        if existing.tags and existing.tags ~= cjson.null then
          local ok, decoded = pcall(cjson.decode, existing.tags)
          if ok and type(decoded) == "table" then tags = decoded end
        end
        if add_tag ~= "" then
          local already = false
          for _, t in ipairs(tags) do if t == add_tag then already = true; break end end
          if not already then
            tags[#tags + 1] = add_tag
            while #tags > M.settings.max_tags_per_upload do table.remove(tags, 1) end
          end
        end
        local merged = {
          title = existing.title,
          description = existing.description,
          tags = tags,
          category_id = existing.category_id,
          subcategory_ids = existing.subcategory_ids,
          visibility = existing.visibility,
          comments_enabled = existing.comments_enabled == nil and true or existing.comments_enabled,
          downloads_enabled = existing.downloads_enabled == nil and true or existing.downloads_enabled,
          pinned = nn(existing.pinned_at) ~= nil,
          is_adult = existing.is_adult,
        }
        for k, v in pairs(overrides) do merged[k] = v end
        local err_status, result = perform_update_media(media_id, owner_id, merged)
        if err_status then
          results[#results + 1] = { id = media_id, ok = false, error = result }
        else
          results[#results + 1] = { id = media_id, ok = true }
        end
      end
    end
  end
  return 200, { results = arr(results) }
end

function M.bulk_delete_media(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local owner_flag = is_site_owner(user)

  local ids, seen = {}, {}
  if type(payload.ids) == "table" then
    for _, raw in ipairs(payload.ids) do
      local id = tonumber(raw)
      if id and id > 0 and not seen[id] then
        seen[id] = true
        ids[#ids + 1] = id
        if #ids >= 200 then break end
      end
    end
  end

  local results = {}
  for _, media_id in ipairs(ids) do
    local item = fetch_media_by_id(media_id, tostring(user.id))
    if not item or nn(item.deleted_at) then
      results[#results + 1] = { id = media_id, ok = false, error = "Not found." }
    else
      local owner_id = db.toint(item.user_id, item.user_id)
      if owner_id == user.id then
        local deleted = perform_delete_media(media_id, owner_id)
        results[#results + 1] = { id = media_id, ok = deleted ~= nil }
      elseif owner_flag then
        db.execute(
          "UPDATE media_items SET deleted_at=CURRENT_TIMESTAMP, visibility='private' WHERE id=%s AND deleted_at IS NULL",
          tostring(media_id))
        results[#results + 1] = { id = media_id, ok = true }
      else
        results[#results + 1] = { id = media_id, ok = false, error = "Forbidden." }
      end
    end
  end
  return 200, { results = arr(results) }
end


-- ---------------------------------------------------------------------------
-- TOTP two-factor auth: enroll / confirm / disable / status, and real
-- verification wired into /api/auth/2fa/verify (replacing the previous
-- always-reject stub). Mirrors app/db/totp.py + app/totp.py exactly (same
-- pbkdf2_sha256-hashed recovery codes via gauth.password_hash, same
-- otpauth:// URI shape, same 6-digit/30s/+-1-step verification window).
-- ---------------------------------------------------------------------------

local function decode_recovery_codes(raw)
  if not raw or raw == cjson.null then return {} end
  local ok, decoded = pcall(cjson.decode, raw)
  if ok and type(decoded) == "table" then return decoded end
  return {}
end

-- Mirrors app/db/totp.py's verify_totp_or_recovery(): checks a live TOTP
-- code first, then falls back to consuming (and removing) a matching
-- recovery code.
function verify_totp_or_recovery(user_id, code)
  local row = db.fetchone("SELECT totp_secret, totp_enabled_at, totp_recovery_codes FROM users WHERE id=%s", user_id)
  if not row or nn(row.totp_enabled_at) == nil or nn(row.totp_secret) == nil then return false end
  if totp.verify_code(row.totp_secret, code, os.time()) then return true end
  local codes = decode_recovery_codes(nn(row.totp_recovery_codes))
  local stripped = trim(code)
  for i, hashed in ipairs(codes) do
    if gauth.verify_password_hash(stripped, hashed) then
      table.remove(codes, i)
      db.execute("UPDATE users SET totp_recovery_codes=%s WHERE id=%s", cjson.encode(arr(codes)), user_id)
      return true
    end
  end
  return false
end

function M.totp_status(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local row = db.fetchone("SELECT totp_enabled_at, totp_recovery_codes FROM users WHERE id=%s", user.id)
  local codes = decode_recovery_codes(row and nn(row.totp_recovery_codes))
  return 200, { enabled = (row and nn(row.totp_enabled_at) ~= nil) or false, recovery_codes_remaining = #codes }
end

function M.totp_enroll(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local secret = totp.generate_secret()
  db.execute("UPDATE users SET totp_secret=%s, totp_enabled_at=NULL WHERE id=%s", secret, user.id)
  return 200, { secret = secret, uri = totp.provisioning_uri(secret, user.username, "Nyxframe") }
end

function M.totp_confirm(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local code = tostring(nn(payload.code) or "")
  local row = db.fetchone("SELECT totp_secret FROM users WHERE id=%s", user.id)
  local secret = row and nn(row.totp_secret)
  if not secret then return 400, { detail = "Start 2FA setup first." } end
  if not totp.verify_code(secret, code, os.time()) then
    return 400, { detail = "Incorrect code. Check your authenticator app and try again." }
  end
  local recovery_codes = totp.generate_recovery_codes(8)
  local hashed = {}
  for i, rc in ipairs(recovery_codes) do hashed[i] = gauth.password_hash(rc) end
  db.execute("UPDATE users SET totp_enabled_at=now(), totp_recovery_codes=%s WHERE id=%s", cjson.encode(hashed), user.id)
  return 200, { enabled = true, recovery_codes = recovery_codes }
end

function M.totp_disable(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local password = tostring(nn(payload.password) or "")
  local row = db.fetchone("SELECT password_hash FROM users WHERE id=%s", user.id)
  if not row or not gauth.verify_password_hash(password, row.password_hash) then
    return 400, { detail = "Incorrect password." }
  end
  db.execute("UPDATE users SET totp_secret=NULL, totp_enabled_at=NULL, totp_recovery_codes=NULL WHERE id=%s", user.id)
  return 200, { enabled = false }
end

-- ---------------------------------------------------------------------------
-- Cheap read-only endpoints hit on nearly every page load (tag cloud, site
-- announcement banner, notification bell) -- ported because leaving them
-- 404ing would break the shell chrome on every single page, not just one
-- feature. Mirrors app/routers/categories.py's tags(), app/routers/admin.py's
-- site_announcement(), and app/routers/notifications.py's unread/read
-- endpoints (full notification listing/creation itself is NOT ported yet).
-- ---------------------------------------------------------------------------

function M.tag_cloud(req)
  local rows = db.fetchall(
    "SELECT tags FROM media_items WHERE tags IS NOT NULL AND deleted_at IS NULL AND visibility='public' ORDER BY created_at DESC LIMIT 500"
  )
  local counts = {}
  local order = {}
  for _, row in ipairs(rows) do
    if row.tags and row.tags ~= cjson.null then
      local ok, tags = pcall(cjson.decode, row.tags)
      if ok and type(tags) == "table" then
        for _, tag in ipairs(tags) do
          local normalized = trim(tostring(tag)):sub(1, 32)
          if normalized ~= "" then
            if not counts[normalized] then order[#order + 1] = normalized end
            counts[normalized] = (counts[normalized] or 0) + 1
          end
        end
      end
    end
  end
  table.sort(order, function(a, b)
    if counts[a] ~= counts[b] then return counts[a] > counts[b] end
    return a:lower() < b:lower()
  end)
  local out = {}
  for i = 1, math.min(30, #order) do out[i] = { tag = order[i], count = counts[order[i]] } end
  return 200, { tags = arr(out) }
end

function M.site_announcement(req)
  local row = db.fetchone("SELECT announcement_message, announcement_level, announcement_active, maintenance_mode, maintenance_message FROM site_settings WHERE id=1")
  row = row or {}
  return 200, {
    announcement_message = nn(row.announcement_message),
    announcement_level = nn(row.announcement_level) or "info",
    announcement_active = db.tobool(row.announcement_active),
    maintenance_mode = db.tobool(row.maintenance_mode),
    maintenance_message = nn(row.maintenance_message),
  }
end

-- ---------------------------------------------------------------------------
-- Site-wide rotating background. Mirrors app/routers/media_feed.py's
-- _background_candidate_rows()/_site_background_snapshot()/site_background()
-- (recovered from git history: 9986ab5^:app/routers/media_feed.py +
-- app/db/feed_collections.py's list_public_background_candidates()) --
-- another endpoint the Lua rewrite never ported, so the frontend's already-
-- built 5-minute rotation/crossfade logic (App.jsx) had nothing to fetch
-- and silently did nothing.
--
-- Simplified from the Python version in one deliberate way: Python falls
-- back to sniffing image-file header bytes for width/height when
-- image_width/image_height aren't populated on the row yet. This port
-- skips that fallback and only considers images that already have both
-- columns set -- simpler, and every current upload path already populates
-- them, so the candidate pool isn't meaningfully smaller. If a future
-- upload path stops populating dimensions, those images just won't be
-- eligible as backgrounds (fails safe, not silently wrong).
--
-- Module-level tables, not per-request state: this backend is one process
-- (no multi-worker fan-out to keep in sync), so a plain Lua table living
-- for the process lifetime plays the same role as Python's
-- main._background_cache / main._site_background_state globals -- every
-- client polling within the same 5-minute window gets the identical pick.
local BACKGROUND_CACHE_SECONDS = 300
local SITE_BACKGROUND_ROTATION_SECONDS = 300
local background_candidates_cache = { items = nil, built_at = 0 }
local site_background_state = { item = nil, picked_at = 0 }
math.randomseed(os.time())

local function background_candidate_rows()
  local now = os.time()
  if background_candidates_cache.items and (now - background_candidates_cache.built_at) < BACKGROUND_CACHE_SECONDS then
    return background_candidates_cache.items
  end
  -- Orientation + adult-content + visibility filtering all happen in SQL
  -- (not Lua-side after fetch): is_adult=false is not optional here -- this
  -- is the one condition standing between "site background" and "surprise
  -- 18+ content on every visitor's screen", so it lives in the WHERE clause
  -- itself rather than a filter step that's easier to accidentally skip.
  --
  -- Orientation only (width > height), not a near-exact-16:9 ratio check --
  -- the previous `ABS(ratio - 16/9) <= 0.035` tolerance rejected anything
  -- that wasn't almost exactly widescreen (a 4:3, 16:10, or ultrawide
  -- landscape image all fail that check despite being perfectly good
  -- backgrounds), which is stricter than "landscape" actually means. GIFs
  -- were never excluded here -- they share media_kind='image' with regular
  -- images (see is_gif_media(); distinguished only by mime_type/filename),
  -- so this already covered them once orientation was the only gate left.
  local rows = db.fetchall([[
      SELECT m.id, m.title, m.original_filename, m.mime_type, m.image_width, m.image_height,
             c.name AS category_name, sc.name AS subcategory_name,
             u.username, CASE WHEN u.public_profile THEN u.display_name ELSE u.username END AS display_name
      FROM media_items m
      JOIN categories c ON c.id = m.category_id
      LEFT JOIN subcategories sc ON sc.id = m.subcategory_id
      JOIN users u ON u.id = m.user_id
      WHERE m.deleted_at IS NULL
        AND m.visibility='public'
        AND m.media_kind='image'
        AND m.is_adult=false
        AND m.image_width IS NOT NULL AND m.image_height IS NOT NULL
        AND m.image_width > m.image_height
      ORDER BY COALESCE(m.pinned_at, m.created_at) DESC, m.created_at DESC
      LIMIT 180
    ]])
  for _, row in ipairs(rows) do
    row.id = db.toint(row.id, row.id)
    row.image_width = db.toint(row.image_width, row.image_width)
    row.image_height = db.toint(row.image_height, row.image_height)
  end
  background_candidates_cache.items = rows
  background_candidates_cache.built_at = now
  return rows
end

function M.site_background(req)
  local now = os.time()
  local needs_pick = (not site_background_state.item)
    or site_background_state.picked_at == 0
    or (now - site_background_state.picked_at) >= SITE_BACKGROUND_ROTATION_SECONDS
  if needs_pick then
    local candidates = background_candidate_rows()
    if #candidates == 0 then
      site_background_state.item = nil
      site_background_state.picked_at = now
    else
      -- Never repeat the immediately-previous pick when more than one
      -- candidate exists, so a slow-changing gallery doesn't visibly
      -- "rotate" to the exact same image it just showed.
      local previous_id = site_background_state.item and site_background_state.item.id
      local pool = {}
      for _, item in ipairs(candidates) do
        if item.id ~= previous_id then pool[#pool + 1] = item end
      end
      if #pool == 0 then pool = candidates end
      site_background_state.item = pool[math.random(#pool)]
      site_background_state.picked_at = now
    end
  end

  local item = site_background_state.item
  local remaining = math.max(1, SITE_BACKGROUND_ROTATION_SECONDS - (now - site_background_state.picked_at))
  if not item then
    return 200, {
      enabled = false, background = cjson.null, background_url = cjson.null, url = cjson.null,
      updated_at = cjson.null, status = "disabled", refresh_after_seconds = SITE_BACKGROUND_ROTATION_SECONDS,
    }
  end

  local origin = request_origin(req)
  -- GIFs go out as the raw original file, not the w=1440 thumb -- the
  -- thumb endpoint flattens everything (animated or not) to a single
  -- static WebP frame for grid-display performance, which would silently
  -- turn an animated GIF background into a still image. The frontend
  -- applies this as a CSS background-image, and browsers do animate GIFs
  -- used that way, so serving the real file is all that's needed here.
  local url
  if is_gif_media(item) then
    url = origin .. "/api/media/" .. item.id .. "/file"
  else
    -- .webp path so Cloudflare's edge caches it (see with_urls); every
    -- visitor in a 5-minute rotation window then shares one render.
    url = append_query(origin .. "/api/media/" .. item.id .. "/thumb.webp", "w", "1440")
  end
  return 200, {
    enabled = true,
    status = "active",
    background = {
      id = item.id,
      title = nn(item.title) or nn(item.original_filename) or ("Background " .. item.id),
      username = item.username,
      display_name = item.display_name,
      category_name = item.category_name,
      subcategory_name = item.subcategory_name,
      width = item.image_width,
      height = item.image_height,
      url = url,
    },
    updated_at = site_background_state.picked_at,
    refresh_after_seconds = remaining,
  }
end

function M.notifications_unread_count(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local row = db.fetchone("SELECT COUNT(*) AS n FROM notifications WHERE recipient_id=%s AND read_at IS NULL", user.id)
  return 200, { unread_count = db.toint(row and row.n, 0) }
end

function M.notifications_mark_read(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local notification_id = tonumber(req.params.notification_id)
  if notification_id then
    db.execute("UPDATE notifications SET read_at=now() WHERE id=%s AND recipient_id=%s AND read_at IS NULL", tostring(notification_id), user.id)
  end
  local row = db.fetchone("SELECT COUNT(*) AS n FROM notifications WHERE recipient_id=%s AND read_at IS NULL", user.id)
  return 200, { unread_count = db.toint(row and row.n, 0) }
end

function M.notifications_mark_all_read(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  db.execute("UPDATE notifications SET read_at=now() WHERE recipient_id=%s AND read_at IS NULL", user.id)
  return 200, { unread_count = 0 }
end

function M.notifications_list(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local limit = bounded_limit(req.query.limit, 30, 100)
  local rows = db.fetchall([[
    SELECT n.id, n.recipient_id, n.actor_id, n.kind, n.media_id, n.preview, n.read_at, n.created_at,
           a.username AS actor_username, a.display_name AS actor_display_name
    FROM notifications n
    LEFT JOIN users a ON a.id = n.actor_id
    WHERE n.recipient_id = %s
    ORDER BY n.created_at DESC
    LIMIT %s
  ]], user.id, tostring(limit))
  for _, row in ipairs(rows) do
    row.id = db.toint(row.id, row.id)
    row.recipient_id = db.toint(row.recipient_id, row.recipient_id)
    if row.actor_id then row.actor_id = db.toint(row.actor_id, row.actor_id) end
    if row.media_id then row.media_id = db.toint(row.media_id, row.media_id) end
  end
  local unread_row = db.fetchone("SELECT COUNT(*) AS n FROM notifications WHERE recipient_id=%s AND read_at IS NULL", user.id)
  return 200, { notifications = arr(rows), unread_count = db.toint(unread_row and unread_row.n, 0) }
end

-- Mirrors app/db/notifications.py's NOTIFICATION_KINDS exactly -- note "like"
-- and "report" are NOT valid kinds in Python (likes don't notify at all;
-- reports go through write_audit_log, not the notifications table).
local NOTIFICATION_KINDS = {
  follow = true, friend_request = true, friend_accept = true, comment = true,
  message = true, mention = true, reply = true, reaction = true, saved_search = true,
  comment_reaction = true, new_upload = true,
}

-- ONE bare global (not even one top-level local) -- this file is already
-- sitting exactly at LuaJIT's 200-local-per-chunk ceiling (confirmed: even
-- a single additional local here fails to compile), same situation as
-- webpush/acquire_transcode_slot elsewhere in this file.
push = {}

-- Text templates for a push notification's title/body, one per
-- NOTIFICATION_KINDS entry -- the server-side equivalent of
-- NotificationBell.jsx's own notificationText(), since a push notification
-- is rendered by the OS/browser notification UI, not by React, so there's
-- no client-side code running to generate it from the raw kind/preview
-- fields the way the in-app bell does.
function push.notification_text(kind, actor_name, media_title, preview)
  actor_name = actor_name or "Someone"
  if kind == "follow" then
    return "New follower", actor_name .. " followed you."
  elseif kind == "friend_request" then
    return "Friend request", actor_name .. " sent you a friend request."
  elseif kind == "friend_accept" then
    return "Friend request accepted", actor_name .. " accepted your friend request."
  elseif kind == "comment" then
    return "New comment", actor_name .. " commented" .. (media_title and (" on \"" .. media_title .. "\"") or " on your post") .. "."
  elseif kind == "message" then
    return "New message", actor_name .. " sent you a message."
  elseif kind == "mention" then
    return "You were mentioned", actor_name .. " mentioned you in a comment."
  elseif kind == "reply" then
    return "New reply", actor_name .. " replied to your comment."
  elseif kind == "reaction" then
    return "New reaction", actor_name .. " reacted to your post."
  elseif kind == "comment_reaction" then
    return "New reaction", actor_name .. " reacted to your comment."
  elseif kind == "new_upload" then
    return "New upload", actor_name .. " uploaded" .. (media_title and (" \"" .. media_title .. "\"") or " something new") .. "."
  elseif kind == "saved_search" then
    return "Saved search match", preview or "A new post matches one of your saved searches."
  end
  return "Nyxframe", preview or (actor_name .. " did something.")
end

-- Delivers `kind`'s web push to every device `recipient_id` has push
-- enabled on. Checked AFTER create_notification's own gating (self/
-- blocked/unknown-kind) so this never fires for a notification that
-- wouldn't have been created in-app either. The common case (no push
-- subscriptions at all) is one cheap indexed SELECT and nothing else --
-- the actor-name/media-title lookups below only run for recipients who
-- actually have at least one subscription to deliver to.
function push.notify(recipient_id, actor_id, kind, media_id, preview)
  local subs = db.fetchall("SELECT id, endpoint, p256dh, auth FROM push_subscriptions WHERE user_id=%s", tostring(recipient_id))
  if not subs or #subs == 0 then return end

  local actor_name = nil
  if actor_id then
    local actor = db.fetchone("SELECT username, display_name, public_profile FROM users WHERE id=%s", tostring(actor_id))
    if actor then actor_name = (db.tobool(actor.public_profile) and actor.display_name) or actor.username end
  end
  local media_title = nil
  if media_id then
    local m = db.fetchone("SELECT title FROM media_items WHERE id=%s", tostring(media_id))
    media_title = m and nn(m.title)
  end
  local title, body = push.notification_text(kind, actor_name, media_title, preview)
  local url = media_id and ("/media/" .. tostring(media_id))
    or (kind == "message" and "/messages")
    or (kind == "friend_request" and "/friends")
    or "/"

  for _, sub in ipairs(subs) do
    webpush.send_to_subscription_async(sub, { title = title, body = body, url = url }, function(ok, status)
      -- 404/410: the push service is telling us this subscription is
      -- permanently gone (unsubscribed, browser data cleared, endpoint
      -- rotated) -- not a transient failure, so clean it up rather than
      -- retrying it forever on every future notification.
      if ok and (status == 404 or status == 410) then
        db.execute("DELETE FROM push_subscriptions WHERE id=%s", tostring(sub.id))
      end
    end)
  end
end

-- True if `recipient_id` has blocked OR muted `actor_id` (either kind, not
-- bidirectional like is_blocked_either_way below -- muting someone is a
-- one-way "don't show me them" preference, it shouldn't also suppress
-- notifications the other person would get about the muter). Genuinely new
-- (not a git-history recovery): "mute" has been storable via
-- POST /api/users/:id/block since block_user() was ported, and shown in
-- Settings' "Blocked & Muted" list, but nothing ever actually consulted it
-- anywhere -- confirmed via a full grep for "mute"/"is_muted" across this
-- file, and confirmed the concept never existed in the original Python
-- backend either (this file's own stale comment claiming to mirror a
-- Python is_muted() was aspirational, not real -- there's no such function
-- in git history).
local function should_suppress_notification(recipient_id, actor_id)
  if not recipient_id or not actor_id then return false end
  local row = db.fetchone(
    "SELECT 1 FROM user_blocks WHERE blocker_id=%s AND blocked_id=%s LIMIT 1",
    tostring(recipient_id), tostring(actor_id)
  )
  return row ~= nil
end

-- Mirrors app/db/notifications.py's create_notification(): silently skips
-- self-notifications and unknown kinds rather than erroring, since callers
-- (like send_direct_message below) don't want a notification-table hiccup
-- to fail the actual action.
create_notification = function(recipient_id, actor_id, kind, media_id, preview)
  if not NOTIFICATION_KINDS[kind] then return end
  if actor_id and tostring(actor_id) == tostring(recipient_id) then return end
  if actor_id and should_suppress_notification(recipient_id, actor_id) then return end
  preview = preview and trim(preview):sub(1, 160) or nil
  if preview == "" then preview = nil end
  db.execute(
    "INSERT INTO notifications (recipient_id, actor_id, kind, media_id, preview) VALUES (%s, %s, %s, %s, %s)",
    tostring(recipient_id), actor_id and tostring(actor_id) or nil, kind, media_id and tostring(media_id) or nil, preview
  )
  push.notify(recipient_id, actor_id, kind, media_id, preview)
end

-- GET /api/push/vapid-public-key -- no auth required, this is the public
-- half of a keypair by design (RFC 8292): the frontend hands it straight
-- to PushManager.subscribe({applicationServerKey}).
function M.push_vapid_public_key(req)
  local key, err = webpush.vapid_public_key_b64url()
  if not key then return 500, { detail = "Push is not available: " .. tostring(err) } end
  return 200, { key = key }
end

-- POST /api/push/subscribe -- body: {endpoint, keys: {p256dh, auth}},
-- exactly the shape JSON.stringify(pushSubscription) on the frontend
-- already produces (toJSON() on a real PushSubscription nests p256dh/auth
-- under "keys"). Upserts on endpoint: re-subscribing the same browser
-- (e.g. after this account's push toggle was off then on again) updates
-- the existing row instead of erroring on the UNIQUE constraint.
function M.push_subscribe(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local endpoint = trim(nn(payload.endpoint) or "")
  local keys = payload.keys or {}
  local p256dh = trim(nn(keys.p256dh) or "")
  local push_auth = trim(nn(keys.auth) or "")
  if endpoint == "" or p256dh == "" or push_auth == "" then
    return 400, { detail = "A complete push subscription (endpoint, keys.p256dh, keys.auth) is required." }
  end
  if not (endpoint:match("^https://") or endpoint:match("^http://")) then
    return 400, { detail = "Invalid push endpoint." }
  end
  local user_agent = trim(nn(req.headers["user-agent"]) or ""):sub(1, 300)
  db.execute([[
    INSERT INTO push_subscriptions (user_id, endpoint, p256dh, auth, user_agent) VALUES (%s, %s, %s, %s, %s)
    ON CONFLICT (endpoint) DO UPDATE SET user_id=EXCLUDED.user_id, p256dh=EXCLUDED.p256dh, auth=EXCLUDED.auth, user_agent=EXCLUDED.user_agent
  ]], user.id, endpoint, p256dh, push_auth, user_agent ~= "" and user_agent or nil)
  return 200, { ok = true }
end

-- POST /api/push/unsubscribe -- body: {endpoint}. Scoped to the current
-- user's own subscriptions (a stolen/guessed endpoint string shouldn't let
-- anyone else's push subscription be deleted).
function M.push_unsubscribe(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local endpoint = trim(nn(payload.endpoint) or "")
  if endpoint == "" then return 400, { detail = "endpoint is required." } end
  db.execute("DELETE FROM push_subscriptions WHERE user_id=%s AND endpoint=%s", user.id, endpoint)
  return 200, { ok = true }
end

-- Mirrors app/db/social.py's is_blocked_either_way().
is_blocked_either_way = function(user_a, user_b)
  if not user_a or not user_b then return false end
  local row = db.fetchone(
    [[
      SELECT 1 FROM user_blocks
      WHERE kind='block' AND ((blocker_id=%s AND blocked_id=%s) OR (blocker_id=%s AND blocked_id=%s))
      LIMIT 1
    ]],
    tostring(user_a), tostring(user_b), tostring(user_b), tostring(user_a)
  )
  return row ~= nil
end

-- ---------------------------------------------------------------------------
-- Saved searches: persisted /api/media filters that notify their owner when
-- new matching public media is uploaded. Mirrors app/routers/saved_searches.py
-- + app/db/feed_collections.py's create/list/delete_saved_search,
-- find_saved_searches_matching, touch_saved_search_notified, and
-- _media_matches_saved_search_filter. Reuses the same
-- sanitize_smart_filter/SMART_FILTER_KEYS used by smart collections, since a
-- saved search's filter_json is the exact same validated shape.
-- NOT ported: Python's is_muted() check before notifying (muting isn't a
-- ported feature at all yet) -- only the block check applies here.
-- ---------------------------------------------------------------------------

local function decode_saved_search(row)
  if not row then return nil end
  row.id = db.toint(row.id, row.id)
  row.user_id = db.toint(row.user_id, row.user_id)
  if row.filter_json and row.filter_json ~= cjson.null then
    local ok, decoded = pcall(cjson.decode, row.filter_json)
    row.filter_json = (ok and type(decoded) == "table") and decoded or {}
  else
    row.filter_json = {}
  end
  return row
end

function M.list_saved_searches(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local rows = db.fetchall("SELECT * FROM saved_searches WHERE user_id=%s ORDER BY created_at DESC", user.id)
  for _, row in ipairs(rows) do decode_saved_search(row) end
  return 200, { saved_searches = arr(rows) }
end

function M.create_saved_search(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local name = trim(nn(payload.name) or ""):gsub("%s+", " "):sub(1, 80)
  if name == "" then return 400, { detail = "Name is required." } end
  local cleaned = sanitize_smart_filter(payload.filter_json)

  local row, err = db.fetchone(
    "INSERT INTO saved_searches (user_id, name, filter_json) VALUES (%s, %s, %s) RETURNING id",
    user.id, name, cjson.encode(cleaned)
  )
  if not row then return 500, { detail = "Could not save search: " .. tostring(err) } end
  local search = db.fetchone("SELECT * FROM saved_searches WHERE id=%s", tostring(db.toint(row.id, row.id)))
  return 200, { saved_search = decode_saved_search(search) }
end

function M.delete_saved_search(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local search_id = tonumber(req.params.search_id)
  if not search_id then return 404, { detail = "Saved search not found." } end
  local existing = db.fetchone("SELECT id FROM saved_searches WHERE id=%s AND user_id=%s", tostring(search_id), user.id)
  if not existing then return 404, { detail = "Saved search not found." } end
  db.execute("DELETE FROM saved_searches WHERE id=%s AND user_id=%s", tostring(search_id), user.id)
  return 200, { deleted = true }
end

-- PATCH /api/me/saved-searches/:search_id/mute { muted: bool } -- per-saved-
-- search notification muting, 2026-10-11 (see notify_matching_saved_searches'
-- own comment on the check this backs). A muted search keeps running
-- (last_notified_at still advances) and can be unmuted later without losing
-- anything -- this never touches the search itself, only whether a match
-- creates a notification.
function M.set_saved_search_mute(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local search_id = tonumber(req.params.search_id)
  if not search_id then return 404, { detail = "Saved search not found." } end
  local payload = json_body(req)
  local muted = db.tobool(payload.muted)
  local existing = db.fetchone("SELECT id FROM saved_searches WHERE id=%s AND user_id=%s", tostring(search_id), user.id)
  if not existing then return 404, { detail = "Saved search not found." } end
  db.execute("UPDATE saved_searches SET notifications_muted=%s WHERE id=%s AND user_id=%s", muted, tostring(search_id), user.id)
  return 200, { id = search_id, notifications_muted = muted }
end

-- Mirrors _media_matches_saved_search_filter(): evaluates a saved-search
-- filter against a single freshly-uploaded item in Lua rather than SQL, same
-- rationale as Python (runs once per upload against a handful of saved
-- searches, not per page view).
local function media_matches_saved_search_filter(media, filter_json)
  if filter_json.media_kind and media.media_kind ~= filter_json.media_kind then return false end
  if filter_json.category_id and tostring(media.category_id) ~= tostring(filter_json.category_id) then return false end
  if filter_json.subcategory_id then
    local match = false
    local wanted = tostring(filter_json.subcategory_id)
    if media.subcategory_id and tostring(media.subcategory_id) == wanted then match = true end
    if not match and type(media.subcategories) == "table" then
      for _, sc in ipairs(media.subcategories) do
        if sc.id and tostring(sc.id) == wanted then match = true; break end
      end
    end
    if not match then return false end
  end
  if filter_json.adult == "only" and not media.is_adult then return false end
  if filter_json.adult == "hide" and media.is_adult then return false end
  if filter_json.min_size ~= nil and (tonumber(media.file_size) or 0) < tonumber(filter_json.min_size) then return false end
  if filter_json.max_size ~= nil and (tonumber(media.file_size) or 0) > tonumber(filter_json.max_size) then return false end
  if filter_json.uploader and nn(filter_json.uploader) then
    local needle = tostring(filter_json.uploader):lower()
    local haystack = ((media.username or "") .. " " .. (media.display_name or "")):lower()
    if not haystack:find(needle, 1, true) then return false end
  end
  if filter_json.q and nn(filter_json.q) then
    local needle = tostring(filter_json.q):lower()
    local tag_text = ""
    if type(media.tags) == "table" then tag_text = table.concat(media.tags, " ") end
    local haystack = ((media.title or "") .. " " .. (media.description or "") .. " " .. tag_text):lower()
    if not haystack:find(needle, 1, true) then return false end
  end
  return true
end

-- Assigns the local forward-declared near notify_discord_upload, above
-- M.upload_media -- see that declaration's comment for why.
notify_matching_saved_searches = function(uploader_id, item)
  local ok, err = pcall(function()
    -- `notifications_muted=false` (per-saved-search mute, 2026-10-11 -- see
    -- M.set_saved_search_mute): a muted search still runs (so last_notified_at
    -- keeps advancing and the saved search itself keeps working if unmuted
    -- later) but never calls create_notification.
    local rows = db.fetchall("SELECT * FROM saved_searches WHERE user_id != %s AND notifications_muted=false", tostring(uploader_id))
    for _, row in ipairs(rows) do
      decode_saved_search(row)
      if media_matches_saved_search_filter(item, row.filter_json) then
        if not is_blocked_either_way(row.user_id, uploader_id) then
          create_notification(
            row.user_id, uploader_id, "saved_search", item.id,
            string.format('New match for "%s": %s', tostring(row.name), tostring(item.title))
          )
          db.execute("UPDATE saved_searches SET last_notified_at=CURRENT_TIMESTAMP WHERE id=%s", tostring(row.id))
        end
      end
    end
  end)
  if not ok then
    print("[nyxframe] saved-search match notification failed for uploader " .. tostring(uploader_id) .. ": " .. tostring(err))
  end
end

-- Mirrors app/routers/_shared.py's _with_user_urls(): fills in avatar_url +
-- site_owner for a user-shaped row that has an avatar_path/avatar_file_id.
function with_user_urls(req, user)
  if not user then return nil end
  if user.avatar_path and user.avatar_path ~= cjson.null then
    local origin = request_origin(req)
    user.avatar_url = origin .. "/api/users/" .. user.id .. "/avatar"
  end
  user.site_owner = is_site_owner(user)
  return user
end

-- ---------------------------------------------------------------------------
-- Direct messages. Mirrors app/routers/messages.py + app/db/messages.py.
-- ---------------------------------------------------------------------------

local function decode_message(row)
  if not row then return nil end
  row.id = db.toint(row.id, row.id)
  row.sender_id = db.toint(row.sender_id, row.sender_id)
  row.recipient_id = db.toint(row.recipient_id, row.recipient_id)
  row.public_profile = db.tobool(row.public_profile)
  row.is_online = db.tobool(row.is_online)
  return row
end

function M.message_threads(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local rows = db.fetchall(
    [[
      SELECT
        other_user.id AS id, other_user.id AS user_id, other_user.username,
        CASE WHEN other_user.public_profile THEN other_user.display_name ELSE other_user.username END AS display_name,
        CASE WHEN other_user.public_profile THEN other_user.avatar_path ELSE NULL END AS avatar_path,
        other_user.profile_color, other_user.public_profile, other_user.last_seen_at,
        (now() - other_user.last_seen_at) <= interval '180 seconds' AS is_online,
        latest.id AS last_message_id, latest.body AS last_message, latest.created_at AS last_message_at,
        latest.sender_id AS last_sender_id, COALESCE(unread.unread_count, 0) AS unread_count
      FROM (
        SELECT CASE WHEN sender_id=%s THEN recipient_id ELSE sender_id END AS other_id, MAX(id) AS last_id
        FROM user_messages
        WHERE sender_id=%s OR recipient_id=%s
        GROUP BY other_id
      ) threads
      JOIN user_messages latest ON latest.id = threads.last_id
      JOIN users other_user ON other_user.id = threads.other_id
      LEFT JOIN (
        SELECT sender_id AS other_id, COUNT(*) AS unread_count
        FROM user_messages
        WHERE recipient_id=%s AND read_at IS NULL
        GROUP BY sender_id
      ) unread ON unread.other_id = threads.other_id
      ORDER BY latest.created_at DESC
      LIMIT 100
    ]],
    user.id, user.id, user.id, user.id
  )
  for _, row in ipairs(rows) do
    row.id = db.toint(row.id, row.id)
    row.user_id = db.toint(row.user_id, row.user_id)
    row.last_message_id = row.last_message_id and db.toint(row.last_message_id, row.last_message_id) or nil
    row.last_sender_id = row.last_sender_id and db.toint(row.last_sender_id, row.last_sender_id) or nil
    row.unread_count = db.toint(row.unread_count, 0)
    row.public_profile = db.tobool(row.public_profile)
    row.is_online = db.tobool(row.is_online)
    with_user_urls(req, row)
  end
  return 200, { threads = arr(rows) }
end

local function fetch_direct_messages_sql(user_id, other_id, limit)
  return db.fetchall(
    [[
      SELECT msg.*, u.username, u.display_name, u.avatar_path, u.profile_color, u.public_profile,
             (now() - u.last_seen_at) <= interval '180 seconds' AS is_online
      FROM user_messages msg
      JOIN users u ON u.id = msg.sender_id
      WHERE (msg.sender_id=%s AND msg.recipient_id=%s) OR (msg.sender_id=%s AND msg.recipient_id=%s)
      ORDER BY msg.created_at DESC, msg.id DESC
      LIMIT %s
    ]],
    tostring(user_id), tostring(other_id), tostring(other_id), tostring(user_id), tostring(math.max(1, math.min(limit, 200)))
  )
end

function M.direct_messages(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local other_id = tonumber(req.params.user_id)
  if not other_id then return 404, { detail = "User not found." } end
  if tostring(other_id) == tostring(user.id) then
    return 400, { detail = "Pick another user to view messages." }
  end
  local other = get_user(tostring(other_id))
  if not other then return 400, { detail = "User not found." } end

  db.execute(
    "UPDATE user_messages SET read_at=COALESCE(read_at, CURRENT_TIMESTAMP) WHERE sender_id=%s AND recipient_id=%s AND read_at IS NULL",
    tostring(other_id), user.id
  )
  local limit = tonumber(req.query.limit) or 80
  local rows = fetch_direct_messages_sql(user.id, other_id, limit)
  local ordered = {}
  for i = #rows, 1, -1 do ordered[#ordered + 1] = decode_message(rows[i]) end
  return 200, { messages = arr(ordered) }
end

function M.send_direct_message(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local rl_status, rl_body = ratelimit.check("dm:" .. user.id, 60, 3600)
  if rl_status then return rl_status, rl_body end
  local other_id = tonumber(req.params.user_id)
  if not other_id then return 404, { detail = "User not found." } end
  if is_blocked_either_way(user.id, other_id) then
    return 403, { detail = "You cannot message this user." }
  end
  if tostring(other_id) == tostring(user.id) then
    return 400, { detail = "You cannot message yourself." }
  end
  local payload = json_body(req)
  local cleaned = trim(nn(payload.body) or ""):gsub("%s+", " ")
  if cleaned == "" then return 400, { detail = "Message cannot be empty." } end
  if #cleaned > 2000 then return 400, { detail = "Message must be 2000 characters or fewer." } end
  local other = get_user(tostring(other_id))
  if not other then return 400, { detail = "User not found." } end

  local row = db.fetchone(
    "INSERT INTO user_messages (sender_id, recipient_id, body) VALUES (%s, %s, %s) RETURNING id",
    user.id, tostring(other_id), cleaned
  )
  if not row then return 500, { detail = "Could not send message." } end
  local message = db.fetchone(
    [[
      SELECT msg.*, u.username, u.display_name, u.avatar_path, u.profile_color, u.public_profile,
             (now() - u.last_seen_at) <= interval '180 seconds' AS is_online
      FROM user_messages msg
      JOIN users u ON u.id = msg.sender_id
      WHERE msg.id = %s
    ]],
    tostring(db.toint(row.id, row.id))
  )
  create_notification(other_id, user.id, "message", nil, cleaned)
  return 200, { message = decode_message(message) }
end

-- ---------------------------------------------------------------------------
-- Group messaging. Genuinely new (not a git-history recovery like the DM
-- functions above) -- MessagesPage.jsx's "New group" UI has always called
-- GET/POST /api/threads and GET/POST /api/threads/:id/messages, but neither
-- the endpoints nor the underlying tables (message_groups/
-- message_group_members/group_messages -- see
-- scripts/pg_add_message_groups.sql) existed until now: confirmed via git
-- history that no hits for "api/threads"/"message_groups" exist anywhere in
-- the removed Python app/ tree either.
-- ---------------------------------------------------------------------------

local function group_membership_row(group_id, user_id)
  return db.fetchone(
    "SELECT 1 FROM message_group_members WHERE group_id=%s AND user_id=%s",
    tostring(group_id), tostring(user_id)
  )
end

-- Shared by list_groups/create_group: builds one thread-shaped row for a
-- single group from the given viewer's perspective. display_name falls back
-- to a comma-joined list of the OTHER members when the group has no
-- explicit name -- same idea as how most chat apps title an unnamed group.
local function decode_group_thread(group_id, viewer_id)
  local group = db.fetchone("SELECT id, name, created_by, created_at FROM message_groups WHERE id=%s", tostring(group_id))
  if not group then return nil end
  local members = db.fetchall(
    [[
      SELECT u.id, u.username,
             CASE WHEN u.public_profile THEN u.display_name ELSE u.username END AS display_name
      FROM message_group_members gm JOIN users u ON u.id = gm.user_id
      WHERE gm.group_id = %s
      ORDER BY gm.joined_at ASC
    ]],
    tostring(group_id)
  )
  for _, m in ipairs(members) do m.id = db.toint(m.id, m.id) end

  local display_name = nn(group.name)
  if not display_name then
    local other_names = {}
    for _, m in ipairs(members) do
      if tostring(m.id) ~= tostring(viewer_id) then other_names[#other_names + 1] = m.display_name end
    end
    display_name = #other_names > 0 and table.concat(other_names, ", ") or "Group"
  end

  local last = db.fetchone(
    "SELECT body FROM group_messages WHERE group_id=%s ORDER BY created_at DESC LIMIT 1",
    tostring(group_id)
  )

  return {
    id = db.toint(group.id, group.id),
    name = nn(group.name),
    display_name = display_name,
    last_message = last and last.body or nil,
    members = arr(members),
  }
end

function M.list_groups(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local group_ids = db.fetchall(
    [[
      SELECT gm.group_id FROM message_group_members gm
      JOIN message_groups g ON g.id = gm.group_id
      WHERE gm.user_id = %s
      ORDER BY g.created_at DESC
    ]],
    user.id
  )
  local threads = {}
  for _, row in ipairs(group_ids) do
    local thread = decode_group_thread(row.group_id, user.id)
    if thread then threads[#threads + 1] = thread end
  end
  return 200, { threads = arr(threads) }
end

function M.create_group(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local rl_status, rl_body = ratelimit.check("group_create:" .. user.id, 20, 3600)
  if rl_status then return rl_status, rl_body end
  local payload = json_body(req)
  local requested_ids = {}
  if type(payload.member_ids) == "table" then
    for _, id in ipairs(payload.member_ids) do
      local n = tonumber(id)
      if n and tostring(n) ~= tostring(user.id) then requested_ids[#requested_ids + 1] = n end
    end
  end
  -- Dedup + drop anyone blocked either way with the creator -- silently, so
  -- the group still forms with whoever's left rather than erroring the
  -- whole request over one bad invite (mirrors send_direct_message's own
  -- is_blocked_either_way check, just non-fatal here since this is a
  -- multi-member create, not a single-recipient send).
  local seen, member_ids = {}, {}
  for _, id in ipairs(requested_ids) do
    if not seen[id] and not is_blocked_either_way(user.id, id) then
      seen[id] = true
      member_ids[#member_ids + 1] = id
    end
  end
  if #member_ids == 0 then
    return 400, { detail = "Add at least one other member to start a group." }
  end

  local name = nn(payload.name)
  if name then
    name = trim(name):sub(1, 120)
    if name == "" then name = nil end
  end

  local row, err = db.fetchone(
    "INSERT INTO message_groups (name, created_by) VALUES (%s, %s) RETURNING id",
    name, user.id
  )
  if not row then return 500, { detail = "Could not create group: " .. tostring(err) } end
  local group_id = db.toint(row.id, row.id)

  db.execute("INSERT INTO message_group_members (group_id, user_id) VALUES (%s, %s)", tostring(group_id), user.id)
  for _, member_id in ipairs(member_ids) do
    db.execute(
      "INSERT INTO message_group_members (group_id, user_id) VALUES (%s, %s) ON CONFLICT DO NOTHING",
      tostring(group_id), tostring(member_id)
    )
  end

  return 200, { thread = decode_group_thread(group_id, user.id) }
end

function M.group_messages(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local group_id = tonumber(req.params.group_id)
  if not group_id then return 404, { detail = "Group not found." } end
  if not group_membership_row(group_id, user.id) then return 404, { detail = "Group not found." } end

  local limit = tonumber(req.query.limit) or 80
  local rows = db.fetchall(
    [[
      SELECT msg.id, msg.group_id, msg.sender_id, msg.body, msg.created_at,
             u.username, u.display_name, u.avatar_path AS user_avatar_path, u.profile_color, u.public_profile
      FROM group_messages msg
      JOIN users u ON u.id = msg.sender_id
      WHERE msg.group_id = %s
      ORDER BY msg.created_at DESC, msg.id DESC
      LIMIT %s
    ]],
    tostring(group_id), tostring(math.max(1, math.min(limit, 200)))
  )
  local ordered = {}
  for i = #rows, 1, -1 do
    local row = rows[i]
    row.id = db.toint(row.id, row.id)
    row.group_id = db.toint(row.group_id, row.group_id)
    row.sender_id = db.toint(row.sender_id, row.sender_id)
    row.public_profile = db.tobool(row.public_profile)
    if row.user_avatar_path and row.user_avatar_path ~= cjson.null then
      row.user_avatar_path = request_origin(req) .. "/api/users/" .. row.sender_id .. "/avatar"
    else
      row.user_avatar_path = nil
    end
    ordered[#ordered + 1] = row
  end
  return 200, { messages = arr(ordered) }
end

function M.send_group_message(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local rl_status, rl_body = ratelimit.check("group_message:" .. user.id, 60, 3600)
  if rl_status then return rl_status, rl_body end
  local group_id = tonumber(req.params.group_id)
  if not group_id then return 404, { detail = "Group not found." } end
  if not group_membership_row(group_id, user.id) then return 404, { detail = "Group not found." } end

  local payload = json_body(req)
  local cleaned = trim(nn(payload.body) or ""):gsub("%s+", " ")
  if cleaned == "" then return 400, { detail = "Message cannot be empty." } end
  if #cleaned > 2000 then return 400, { detail = "Message must be 2000 characters or fewer." } end

  local row = db.fetchone(
    "INSERT INTO group_messages (group_id, sender_id, body) VALUES (%s, %s, %s) RETURNING id",
    tostring(group_id), user.id, cleaned
  )
  if not row then return 500, { detail = "Could not send message." } end

  local message = db.fetchone(
    [[
      SELECT msg.id, msg.group_id, msg.sender_id, msg.body, msg.created_at,
             u.username, u.display_name, u.avatar_path AS user_avatar_path, u.profile_color, u.public_profile
      FROM group_messages msg JOIN users u ON u.id = msg.sender_id
      WHERE msg.id = %s
    ]],
    tostring(db.toint(row.id, row.id))
  )
  message.id = db.toint(message.id, message.id)
  message.group_id = db.toint(message.group_id, message.group_id)
  message.sender_id = db.toint(message.sender_id, message.sender_id)
  message.public_profile = db.tobool(message.public_profile)
  if message.user_avatar_path and message.user_avatar_path ~= cjson.null then
    message.user_avatar_path = request_origin(req) .. "/api/users/" .. message.sender_id .. "/avatar"
  else
    message.user_avatar_path = nil
  end

  local other_members = db.fetchall(
    "SELECT user_id FROM message_group_members WHERE group_id=%s AND user_id != %s",
    tostring(group_id), user.id
  )
  for _, m in ipairs(other_members) do
    create_notification(m.user_id, user.id, "message", nil, cleaned)
  end

  return 200, { message = message }
end

-- ---------------------------------------------------------------------------
-- Collections. Mirrors app/routers/collections.py + the collection-related
-- half of app/db/feed_collections.py (following_feed/liked_media/saved
-- searches are a different router's territory and NOT covered here).
-- ---------------------------------------------------------------------------

local function clean_text(value, max_len)
  local cleaned = trim(nn(value) or ""):gsub("%s+", " ")
  return cleaned:sub(1, max_len)
end

local function decode_collection(row)
  if not row then return nil end
  row.id = db.toint(row.id, row.id)
  row.user_id = db.toint(row.user_id, row.user_id)
  row.item_count = db.toint(row.item_count, 0)
  row.cover_media_id = row.cover_media_id and db.toint(row.cover_media_id, row.cover_media_id) or nil
  row.is_public = db.tobool(row.is_public)
  row.is_smart = db.tobool(row.is_smart)
  row.cover_is_adult = db.tobool(row.cover_is_adult)
  if row.is_smart and nn(row.filter_json) then
    local ok, decoded = pcall(cjson.decode, row.filter_json)
    row.filter = (ok and type(decoded) == "table") and decoded or {}
  else
    row.filter = {}
  end
  return row
end

-- Mirrors _with_collection_urls(): fills in cover_url (pointing at this
-- backend's own /api/media/:id/file) or locks the cover out entirely for an
-- unlocked-adult viewer, plus user_avatar_url.
local function with_collection_urls(req, collection, adult_allowed)
  if not collection then return nil end
  local origin = request_origin(req)
  if collection.cover_path and (adult_allowed or not collection.cover_is_adult) then
    if collection.cover_media_id then
      collection.cover_url = origin .. "/api/media/" .. collection.cover_media_id .. "/file"
    else
      collection.cover_url = nil
    end
  elseif collection.cover_is_adult then
    collection.cover_path = nil
    collection.cover_url = nil
    collection.cover_locked = true
  end
  if collection.user_avatar_path and collection.user_avatar_path ~= cjson.null then
    collection.user_avatar_url = origin .. "/api/users/" .. (collection.user_id or collection.id) .. "/avatar"
  end
  return collection
end

local COLLECTION_SELECT = [[
  SELECT mc.*, u.username, u.display_name, u.avatar_path AS user_avatar_path,
         COUNT(mi.id) AS item_count,
         MAX(mi.storage_path) AS cover_path,
         MAX(mi.media_kind) AS cover_media_kind,
         MAX(mi.id) AS cover_media_id,
         MAX(CASE WHEN mi.is_adult THEN 1 ELSE 0 END) AS cover_is_adult
  FROM media_collections mc
  JOIN users u ON u.id = mc.user_id
  LEFT JOIN media_collection_items mci ON mci.collection_id = mc.id
  LEFT JOIN media_items mi ON mi.id = mci.media_id AND mi.deleted_at IS NULL
    AND (mi.visibility='public' OR mi.user_id=%s OR mc.user_id=%s)
]]

local function fetch_collection(collection_id, viewer_id)
  local v = tostring(viewer_id or 0)
  return db.fetchone(
    COLLECTION_SELECT .. " WHERE mc.id=%s AND (mc.is_public OR mc.user_id=%s) GROUP BY mc.id, u.id",
    v, v, tostring(collection_id), v
  )
end

function M.collection_suggestions(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local existing = db.fetchall(
    COLLECTION_SELECT .. " WHERE mc.user_id=%s GROUP BY mc.id, u.id",
    user.id, user.id, user.id
  )
  local covered = {}
  for _, row in ipairs(existing) do
    if db.tobool(row.is_smart) and nn(row.filter_json) then
      local ok, decoded = pcall(cjson.decode, row.filter_json)
      if ok and type(decoded) == "table" and decoded.q then
        covered[tostring(decoded.q):lower()] = true
      end
    end
  end

  local rows = db.fetchall(
    "SELECT id, tags FROM media_items WHERE user_id=%s AND deleted_at IS NULL AND tags IS NOT NULL ORDER BY created_at DESC LIMIT 1000",
    user.id
  )
  local counts, sample = {}, {}
  for _, row in ipairs(rows) do
    if row.tags and row.tags ~= cjson.null then
      local ok, tags = pcall(cjson.decode, row.tags)
      if ok and type(tags) == "table" then
        for _, tag in ipairs(tags) do
          local normalized = trim(tostring(tag)):lower():sub(1, 32)
          if normalized ~= "" then
            counts[normalized] = (counts[normalized] or 0) + 1
            if not sample[normalized] then sample[normalized] = db.toint(row.id, row.id) end
          end
        end
      end
    end
  end
  local order = {}
  for tag, count in pairs(counts) do
    if count >= 4 and not covered[tag] then order[#order + 1] = tag end
  end
  table.sort(order, function(a, b)
    if counts[a] ~= counts[b] then return counts[a] > counts[b] end
    return a < b
  end)
  local suggestions = {}
  for i = 1, math.min(8, #order) do
    local tag = order[i]
    suggestions[i] = {
      tag = tag, count = counts[tag],
      thumb_url = append_query(request_origin(req) .. "/api/media/" .. sample[tag] .. "/thumb", "w", "640"),
    }
  end
  return 200, { suggestions = arr(suggestions) }
end

function M.list_collections(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local adult_allowed = viewer_adult_allowed(viewer_id)
  local mine = req.query.mine == "true" or req.query.mine == "1"
  if mine and not viewer_id then return 401, { detail = "Login required" } end
  local v = viewer_id or "0"
  local where = mine and "mc.user_id=%s" or "(mc.is_public OR mc.user_id=%s)"
  local rows = db.fetchall(
    COLLECTION_SELECT .. " WHERE " .. where .. " GROUP BY mc.id, u.id ORDER BY mc.updated_at DESC, mc.created_at DESC LIMIT 100",
    v, v, v
  )
  for _, row in ipairs(rows) do
    decode_collection(row)
    with_collection_urls(req, row, adult_allowed)
  end
  return 200, { collections = arr(rows) }
end

function M.create_collection(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local name = clean_text(payload.name, 100)
  if name == "" then return 400, { detail = "Name is required." } end
  local description_text = clean_text(payload.description, 500)
  local description = description_text ~= "" and description_text or nil
  local is_public = payload.is_public == nil or db.tobool(payload.is_public)
  local is_smart = db.tobool(payload.is_smart)
  local stored_filter = nil
  if is_smart then
    stored_filter = cjson.encode(sanitize_smart_filter(payload.filter_json)):sub(1, 8000)
  end

  local row = db.fetchone(
    "INSERT INTO media_collections (user_id, name, description, is_public, is_smart, filter_json) VALUES (%s, %s, %s, %s, %s, %s) RETURNING id",
    user.id, name, description, is_public, is_smart, stored_filter
  )
  if not row then return 500, { detail = "Could not create collection." } end
  local collection = fetch_collection(db.toint(row.id, row.id), user.id)
  local adult_allowed = viewer_adult_allowed(tostring(user.id))
  return 200, { collection = with_collection_urls(req, decode_collection(collection), adult_allowed) }
end

function M.collection_detail(req)
  local collection_id = tonumber(req.params.collection_id)
  if not collection_id then return 404, { detail = "Collection not found." } end
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local adult_allowed = viewer_adult_allowed(viewer_id)

  local collection = fetch_collection(collection_id, viewer_id)
  if not collection then return 404, { detail = "Collection not found." } end
  decode_collection(collection)

  local media_rows = {}
  if collection.is_smart then
    local filter = collection.filter or {}
    local fake_req = {
      headers = req.headers,
      query = {
        media_kind = filter.media_kind, category_id = filter.category_id and tostring(filter.category_id) or nil,
        subcategory_id = filter.subcategory_id and tostring(filter.subcategory_id) or nil,
        q = filter.q, uploader = filter.uploader,
        min_size = filter.min_size and tostring(filter.min_size) or nil,
        max_size = filter.max_size and tostring(filter.max_size) or nil,
        date_from = filter.date_from, date_to = filter.date_to, adult = filter.adult,
        sort = filter.sort or "new", limit = "120",
      },
    }
    local _, list_body = M.list_media(fake_req)
    media_rows = (list_body and list_body.media) or {}
  else
    local v = viewer_id or "0"
    media_rows = db.fetchall(
      string.format([[
        SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.description, m.tags,
               m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.file_size,
               m.views, m.downloads, m.created_at, m.updated_at, m.visibility,
               m.comments_enabled, m.downloads_enabled, m.pinned_at, m.is_adult,
               m.adult_marked_by_user, m.adult_marked_by_ai, m.moderation_status, m.dominant_color, m.source_url,
               c.name AS category_name, c.slug AS category_slug,
               sc.name AS subcategory_name, sc.slug AS subcategory_slug,
               u.username,
               CASE WHEN u.public_profile OR u.id::text=%%s THEN u.display_name ELSE u.username END AS display_name,
               CASE WHEN u.public_profile OR u.id::text=%%s THEN u.avatar_path ELSE NULL END AS user_avatar_path,
               u.profile_color, u.public_profile,
               (SELECT COUNT(DISTINCT lk.user_id) FROM media_likes lk WHERE lk.media_id = m.id) AS like_count,
               (SELECT COUNT(*) FROM media_comments cmc WHERE cmc.media_id = m.id) AS comment_count,
               CASE WHEN EXISTS (SELECT 1 FROM media_bookmarks b WHERE b.media_id = m.id AND b.user_id::text = %%s) THEN 1 ELSE 0 END AS bookmarked_by_me,
               CASE WHEN EXISTS (SELECT 1 FROM media_likes l2 WHERE l2.media_id = m.id AND l2.user_id::text = %%s) THEN 1 ELSE 0 END AS liked_by_me
        FROM media_collection_items mci
        JOIN media_items m ON m.id = mci.media_id
        JOIN categories c ON c.id = m.category_id
        LEFT JOIN subcategories sc ON sc.id = m.subcategory_id
        JOIN users u ON u.id = m.user_id
        WHERE mci.collection_id=%%s AND m.deleted_at IS NULL AND (m.visibility='public' OR m.user_id::text=%%s)
          %s
        ORDER BY mci.added_at DESC
        LIMIT 120
      ]], adult_allowed and "" or "AND m.is_adult=false"),
      v, v, v, v, tostring(collection_id), v
    )
    for _, row in ipairs(media_rows) do decode_media_row(row, adult_allowed, req) end
  end

  return 200, {
    collection = with_collection_urls(req, collection, adult_allowed),
    media = arr(media_rows),
  }
end

function M.save_collection_item(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local collection_id = tonumber(req.params.collection_id)
  if not collection_id then return 404, { detail = "Collection not found." } end
  local payload = json_body(req)
  local media_id = tonumber(payload.media_id)
  if not media_id then return 400, { detail = "media_id is required." } end
  local saved = payload.saved == nil or db.tobool(payload.saved)

  local collection = fetch_collection(collection_id, user.id)
  if not collection or tostring(collection.user_id) ~= tostring(user.id) then
    return 404, { detail = "Collection not found." }
  end
  local media = fetch_media_by_id(media_id, tostring(user.id))
  if not media or nn(media.deleted_at) then return 404, { detail = "Collection not found." } end
  if media.visibility == "private" and tostring(media.user_id) ~= tostring(user.id) then
    return 404, { detail = "Collection not found." }
  end

  if saved then
    db.execute(
      "INSERT INTO media_collection_items (collection_id, media_id) VALUES (%s, %s) ON CONFLICT (collection_id, media_id) DO NOTHING",
      tostring(collection_id), tostring(media_id)
    )
  else
    db.execute(
      "DELETE FROM media_collection_items WHERE collection_id=%s AND media_id=%s",
      tostring(collection_id), tostring(media_id)
    )
  end
  db.execute("UPDATE media_collections SET updated_at=CURRENT_TIMESTAMP WHERE id=%s", tostring(collection_id))

  local updated = fetch_collection(collection_id, user.id)
  local adult_allowed = viewer_adult_allowed(tostring(user.id))
  return 200, { collection = with_collection_urls(req, decode_collection(updated), adult_allowed) }
end

-- ---------------------------------------------------------------------------
-- Public profiles, follows, friend requests/friends, user search, blocks.
-- Mirrors app/routers/social.py + app/db/social.py (recovered from git
-- history: 9986ab5^:app/routers/social.py and app/db/social.py). Previously
-- missing entirely from the Lua rewrite -- discovered live-404ing on
-- /api/users/search, /api/users/:username(/profile), followers/following/
-- friends, friend-request/block, breaking profile pages, search, and
-- follow/friend flows for both the web app and iOS.
-- ---------------------------------------------------------------------------

-- Mirrors app/db/social.py's friend_status(): "self" | "friends" |
-- "pending_out" | "pending_in" | "none".
local function friend_status(viewer_id, user_id)
  if not viewer_id then return "none" end
  if tostring(viewer_id) == tostring(user_id) then return "self" end
  local row = db.fetchone(
    [[
      SELECT requester_id, addressee_id, status
      FROM friend_requests
      WHERE (requester_id=%s AND addressee_id=%s) OR (requester_id=%s AND addressee_id=%s)
      ORDER BY CASE status
        WHEN 'accepted' THEN 1 WHEN 'pending' THEN 2 WHEN 'declined' THEN 3 WHEN 'cancelled' THEN 4 ELSE 5
      END, created_at DESC
      LIMIT 1
    ]],
    tostring(viewer_id), tostring(user_id), tostring(user_id), tostring(viewer_id)
  )
  if not row or row.status == "declined" or row.status == "cancelled" then return "none" end
  if row.status == "accepted" then return "friends" end
  return tostring(row.requester_id) == tostring(viewer_id) and "pending_out" or "pending_in"
end

function M.search_users(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local viewer0 = tostring(viewer_id or 0)
  local q = trim(nn(req.query.q) or ""):gsub("%s+", " "):sub(1, 80)
  local limit = bounded_limit(req.query.limit, 30, 60)
  local needle = "%" .. q:gsub("([%%_])", "\\%1") .. "%"
  local rows = db.fetchall(
    [[
      SELECT u.id, u.username,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.display_name ELSE u.username END AS display_name,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.bio ELSE NULL END AS bio,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.profile_headline ELSE NULL END AS profile_headline,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.avatar_path ELSE NULL END AS avatar_path,
             u.profile_color, u.public_profile, u.show_liked_count, u.show_collections,
             u.show_recent_uploads, u.show_friends, u.adult_content_consent, u.email_verified_at,
             u.last_seen_at,
             COUNT(DISTINCT m.id) AS media_count,
             COUNT(DISTINCT f.follower_id) AS follower_count,
             MAX(CASE WHEN mine.follower_id IS NULL THEN 0 ELSE 1 END) AS followed_by_me,
             MAX(CASE WHEN mine.notifications_muted THEN 1 ELSE 0 END) AS follow_notifications_muted
      FROM users u
      LEFT JOIN media_items m ON m.user_id=u.id AND m.deleted_at IS NULL AND m.visibility='public'
      LEFT JOIN user_follows f ON f.followed_id=u.id
      LEFT JOIN user_follows mine ON mine.followed_id=u.id AND mine.follower_id::text=%s
      WHERE %s = ''
         OR u.username ILIKE %s
         OR (CASE WHEN u.public_profile OR u.id::text=%s THEN u.display_name ELSE NULL END) ILIKE %s
         OR (CASE WHEN u.public_profile OR u.id::text=%s THEN u.bio ELSE NULL END) ILIKE %s
         OR (CASE WHEN u.public_profile OR u.id::text=%s THEN u.profile_headline ELSE NULL END) ILIKE %s
      GROUP BY u.id
      ORDER BY (u.username=%s) DESC, follower_count DESC, media_count DESC, u.created_at DESC
      LIMIT %s
    ]],
    viewer0, viewer0, viewer0, viewer0, viewer0, q, needle, viewer0, needle, viewer0, needle, viewer0, needle,
    q, tostring(limit)
  )
  -- Batch friend_status lookups: previously one db.fetchone() per result row
  -- (N+1). Fetch every friend_requests row touching the viewer and any result
  -- user in a single query, then resolve status per-user in Lua.
  local statuses = {}
  if viewer_id and #rows > 0 then
    local placeholders = {}
    local ids = {}
    for i, row in ipairs(rows) do
      placeholders[i] = "%s"
      ids[i] = tostring(row.id)
    end
    local in_list = table.concat(placeholders, ", ")
    -- Build one flat params table and unpack() it exactly once, in the
    -- tail position: Lua only expands unpack()/a multi-value expression
    -- to multiple values when it's the LAST argument in a call -- every
    -- earlier occurrence silently truncates to its first element. Calling
    -- unpack(ids) twice in the same db.fetchall(...) argument list (as
    -- this did before) meant the first occurrence collapsed to a single
    -- value, so db.fetchall got 7 params for a 10-placeholder query and
    -- pg.lua's string.format() blew up with "bad argument #8" -- confirmed
    -- live via /api/users/search for any authenticated viewer with at
    -- least one result, i.e. this broke user search for every logged-in
    -- user, silently (never caught before since no prior testing had a
    -- real session to reach this branch).
    local fr_params = { viewer0 }
    for _, id in ipairs(ids) do fr_params[#fr_params + 1] = id end
    fr_params[#fr_params + 1] = viewer0
    for _, id in ipairs(ids) do fr_params[#fr_params + 1] = id end
    local fr_rows = db.fetchall(
      string.format(
        [[
          SELECT requester_id, addressee_id, status
          FROM friend_requests
          WHERE (requester_id=%%s AND addressee_id IN (%s)) OR (addressee_id=%%s AND requester_id IN (%s))
          ORDER BY CASE status
            WHEN 'accepted' THEN 1 WHEN 'pending' THEN 2 WHEN 'declined' THEN 3 WHEN 'cancelled' THEN 4 ELSE 5
          END, created_at DESC
        ]],
        in_list, in_list
      ),
      unpack(fr_params)
    )
    for _, fr in ipairs(fr_rows) do
      local other_id = tostring(fr.requester_id) == viewer0 and tostring(fr.addressee_id) or tostring(fr.requester_id)
      -- Rows are already ordered by priority/recency, same as the old
      -- per-pair LIMIT 1 query -- keep only the first (best) row per user.
      if not statuses[other_id] then
        if fr.status == "declined" or fr.status == "cancelled" then
          statuses[other_id] = "none"
        elseif fr.status == "accepted" then
          statuses[other_id] = "friends"
        else
          statuses[other_id] = tostring(fr.requester_id) == viewer0 and "pending_out" or "pending_in"
        end
      end
    end
  end
  for _, row in ipairs(rows) do
    decode_user(row)
    row.media_count = db.toint(row.media_count, 0)
    row.follower_count = db.toint(row.follower_count, 0)
    row.followed_by_me = db.tobool(row.followed_by_me)
    row.follow_notifications_muted = db.tobool(row.follow_notifications_muted)
    if not viewer_id then
      row.friend_status = "none"
    elseif tostring(viewer_id) == tostring(row.id) then
      row.friend_status = "self"
    else
      row.friend_status = statuses[tostring(row.id)] or "none"
    end
    with_user_urls(req, row)
  end
  return 200, { users = arr(rows), limit = limit }
end

-- ---------------------------------------------------------------------------
-- Suggested accounts to follow. New feature, 2026-10-11: no recommendation
-- surface existed for PEOPLE before this (M.similar_media already covers
-- "more like this post" via perceptual hash, but nothing suggested WHO to
-- follow).
--
-- Two signals, both restricted to accounts the viewer doesn't already
-- follow/isn't blocked by either direction:
--   1. Second-degree follows -- people followed by people the viewer
--      follows. Weighted by how many of the viewer's own follows also
--      follow that candidate (a candidate followed by 5 of your follows
--      outranks one followed by 1).
--   2. Creators of media the viewer has liked -- weighted 2x a single
--      mutual-follow point, since an explicit like is a stronger signal
--      than "someone I follow happens to follow them too."
-- A brand new account (no follows, no likes) has zero rows from either
-- signal, so this falls back to the simplest honest default: the
-- most-followed public accounts site-wide, excluding self/blocks, same as
-- any "trending creators" list would show.
--
-- One combined query (UNION ALL + GROUP BY SUM) rather than two round
-- trips plus a Lua-side merge -- Postgres does the ranking, this just
-- shapes the output, same division of labor as every other listing route
-- in this file.
function M.suggested_users(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local viewer0 = tostring(user.id)
  local limit = bounded_limit(req.query.limit, 10, 30)

  local rows, err = db.fetchall(
    [[
      WITH my_follows AS (
        SELECT followed_id FROM user_follows WHERE follower_id=%s
      ),
      not_blocked AS (
        SELECT u.id FROM users u
        WHERE u.id != %s
          AND u.id NOT IN (SELECT followed_id FROM my_follows)
          AND u.id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id=%s AND kind='block')
          AND u.id NOT IN (SELECT blocker_id FROM user_blocks WHERE blocked_id=%s AND kind='block')
      ),
      signals AS (
        SELECT uf2.followed_id AS user_id, COUNT(*)::real AS score
        FROM user_follows uf1
        JOIN user_follows uf2 ON uf2.follower_id = uf1.followed_id
        WHERE uf1.follower_id = %s
        GROUP BY uf2.followed_id
        UNION ALL
        SELECT m.user_id AS user_id, COUNT(*)::real * 2 AS score
        FROM media_likes ml
        JOIN media_items m ON m.id = ml.media_id AND m.deleted_at IS NULL
        WHERE ml.user_id = %s
        GROUP BY m.user_id
      ),
      ranked AS (
        SELECT s.user_id, SUM(s.score) AS total_score
        FROM signals s
        JOIN not_blocked nb ON nb.id = s.user_id
        GROUP BY s.user_id
        UNION ALL
        -- Fallback tier: most-followed public accounts, only used to pad
        -- out past however many real signal-based rows exist (LIMIT below
        -- always prefers the signal rows since they're unioned first and
        -- ORDER BY puts is_fallback before score).
        SELECT nb.id AS user_id, 0 AS total_score
        FROM not_blocked nb
        JOIN users u2 ON u2.id = nb.id
        WHERE u2.public_profile
      )
      SELECT r.user_id AS id,
             MAX(r.total_score) AS total_score,
             u.username, u.display_name, u.bio, u.profile_headline, u.avatar_path,
             u.profile_color, u.public_profile,
             COUNT(DISTINCT f.follower_id) AS follower_count
      FROM ranked r
      JOIN users u ON u.id = r.user_id
      LEFT JOIN user_follows f ON f.followed_id = u.id
      GROUP BY r.user_id, u.username, u.display_name, u.bio, u.profile_headline,
               u.avatar_path, u.profile_color, u.public_profile
      ORDER BY (MAX(r.total_score) > 0) DESC, MAX(r.total_score) DESC, follower_count DESC
      LIMIT %s
    ]],
    viewer0, viewer0, viewer0, viewer0, viewer0, viewer0, tostring(limit)
  )
  if err then return 500, { detail = "Query failed: " .. tostring(err) } end

  for _, row in ipairs(rows) do
    row.id = db.toint(row.id, row.id)
    row.follower_count = db.toint(row.follower_count, 0)
    row.total_score = tonumber(row.total_score) or 0
    row.public_profile = db.tobool(row.public_profile)
    if not row.public_profile then
      row.display_name = row.username
      row.bio, row.profile_headline, row.avatar_path = nil, nil, nil
    end
    row.match_reason = row.total_score > 0 and "signal" or "trending"
    with_user_urls(req, row)
  end
  return 200, { users = arr(rows), limit = limit }
end

-- NOT routes.lua's normalize_username() (that one lowercases, for
-- register/login only -- see its own comment). Mirrors app/db/_shared.py's
-- normalize_username(), which only trims: usernames are matched exactly as
-- stored, case-sensitively. Lua-registered accounts are always lowercase
-- already (register() lowercases at insert time), but accounts created
-- before that -- or migrated from the old MySQL DB -- can have mixed-case
-- usernames, so forcibly lowercasing the URL param here would 404 real
-- profiles like the site owner's own "HollowHeavenXR".
local function trimmed_username(u)
  return trim(u or ""):sub(1, 40)
end

local function get_public_profile(req, username, viewer_id)
  local viewer0 = tostring(viewer_id or 0)
  local row = db.fetchone(
    [[
      SELECT u.id, u.username,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.display_name ELSE u.username END AS display_name,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.bio ELSE NULL END AS bio,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.profile_headline ELSE NULL END AS profile_headline,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.featured_tags ELSE NULL END AS featured_tags,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.website_url ELSE NULL END AS website_url,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.location_label ELSE NULL END AS location_label,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.avatar_path ELSE NULL END AS avatar_path,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.user_settings ELSE NULL END AS user_settings,
             u.avatar_file_id, u.profile_color, u.public_profile, u.show_liked_count,
             u.show_collections, u.show_recent_uploads, u.show_friends, u.created_at, u.last_seen_at,
             u.discord_verified_at, u.discord_username,
             u.user_settings::jsonb->>'profile_show_follow_counts' AS show_follow_counts_raw,
             u.user_settings::jsonb->>'profile_show_joined_date' AS show_joined_date_raw,
             COUNT(DISTINCT m.id) AS media_count,
             COALESCE(SUM(CASE WHEN m.deleted_at IS NULL AND m.visibility='public' THEN m.downloads ELSE 0 END), 0) AS download_count,
             COUNT(DISTINCT (ml.user_id, ml.media_id)) AS like_count,
             COUNT(DISTINCT f1.follower_id) AS follower_count,
             COUNT(DISTINCT f2.followed_id) AS following_count,
             COUNT(DISTINCT CASE WHEN fr.status='accepted' AND (fr.requester_id=u.id OR fr.addressee_id=u.id) THEN fr.id END) AS friend_count,
             MAX(CASE WHEN f3.follower_id::text=%s THEN 1 ELSE 0 END) AS followed_by_me,
             MAX(CASE WHEN f3.notifications_muted THEN 1 ELSE 0 END) AS follow_notifications_muted,
             (now() - u.last_seen_at) <= interval '180 seconds' AS is_online
      FROM users u
      LEFT JOIN media_items m ON m.user_id=u.id AND m.deleted_at IS NULL AND (m.visibility='public' OR m.user_id::text=%s)
      LEFT JOIN media_likes ml ON ml.media_id=m.id
      LEFT JOIN user_follows f1 ON f1.followed_id=u.id
      LEFT JOIN user_follows f2 ON f2.follower_id=u.id
      LEFT JOIN user_follows f3 ON f3.followed_id=u.id AND f3.follower_id::text=%s
      LEFT JOIN friend_requests fr ON fr.status='accepted' AND (fr.requester_id=u.id OR fr.addressee_id=u.id)
      WHERE u.username=%s
      GROUP BY u.id
    ]],
    viewer0, viewer0, viewer0, viewer0, viewer0, viewer0, viewer0, viewer0, viewer0, viewer0, viewer0,
    trimmed_username(username)
  )
  if not row then return nil end
  decode_user(row)
  row.media_count = db.toint(row.media_count, 0)
  row.download_count = db.toint(row.download_count, 0)
  row.like_count = db.toint(row.like_count, 0)
  row.follower_count = db.toint(row.follower_count, 0)
  row.following_count = db.toint(row.following_count, 0)
  row.friend_count = db.toint(row.friend_count, 0)
  row.followed_by_me = db.tobool(row.followed_by_me)
  row.follow_notifications_muted = db.tobool(row.follow_notifications_muted)
  row.is_online = db.tobool(row.is_online)
  row.friend_status = viewer_id and friend_status(viewer_id, row.id) or "none"

  -- Privacy toggles that were stored/editable (Settings page) but never
  -- actually gated anything server-side -- confirmed via grep, same class
  -- of bug as mute's: show_liked_count, profile_show_follow_counts, and
  -- profile_show_joined_date all existed purely as inert form fields.
  -- like_count/follower_count/following_count/created_at were always
  -- computed and returned regardless, so turning the toggle off only ever
  -- hid the number client-side -- the real value was still sitting in the
  -- API response for anyone to read directly.
  local is_owner = viewer_id and tostring(viewer_id) == tostring(row.id)
  if not is_owner then
    if not db.tobool(row.show_liked_count) then row.like_count = nil end
    if row.show_follow_counts_raw == "false" then
      row.follower_count = nil
      row.following_count = nil
    end
    if row.show_joined_date_raw == "false" then row.created_at = nil end
    -- show_friends already gated the friends LIST (M.profile_page's
    -- list_profile_friends call), but not this raw count -- same partial-
    -- leak pattern as the three fields above, just missed in that pass
    -- since it's driven by an existing column rather than a settings-blob
    -- lookup.
    if not db.tobool(row.show_friends) then row.friend_count = nil end
  end
  row.show_follow_counts_raw = nil
  row.show_joined_date_raw = nil
  return row
end

function M.public_profile(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local profile = get_public_profile(req, req.params.username, viewer_id)
  if not profile then return 404, { detail = "User not found." } end
  if viewer_id and is_blocked_either_way(viewer_id, profile.id) then
    return 404, { detail = "User not found." }
  end
  return 200, { user = with_user_urls(req, profile) }
end

local function list_profile_media(req, target_id, viewer_id, viewer_can_open_adult, limit)
  local viewer0 = tostring(viewer_id or 0)
  local rows = db.fetchall(
    string.format([[
      SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.description, m.tags,
             m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.file_size,
             m.views, m.downloads, m.created_at, m.updated_at, m.visibility,
             m.comments_enabled, m.downloads_enabled, m.pinned_at, m.is_adult,
             m.adult_marked_by_user, m.adult_marked_by_ai, m.moderation_status, m.dominant_color, m.source_url,
             c.name AS category_name, c.slug AS category_slug,
             sc.name AS subcategory_name, sc.slug AS subcategory_slug,
             u.username, u.display_name, u.profile_color, u.public_profile,
             (SELECT COUNT(DISTINCT lk.user_id) FROM media_likes lk WHERE lk.media_id = m.id) AS like_count,
             (SELECT COUNT(*) FROM media_comments cmc WHERE cmc.media_id = m.id) AS comment_count,
             CASE WHEN EXISTS (SELECT 1 FROM media_bookmarks b WHERE b.media_id = m.id AND b.user_id::text = %%s) THEN 1 ELSE 0 END AS bookmarked_by_me,
             CASE WHEN EXISTS (SELECT 1 FROM media_likes l2 WHERE l2.media_id = m.id AND l2.user_id::text = %%s) THEN 1 ELSE 0 END AS liked_by_me
      FROM media_items m
      JOIN categories c ON c.id = m.category_id
      LEFT JOIN subcategories sc ON sc.id = m.subcategory_id
      JOIN users u ON u.id = m.user_id
      WHERE m.user_id=%%s AND m.deleted_at IS NULL AND (m.visibility='public' OR m.user_id::text=%%s)
        %s
      ORDER BY m.pinned_at DESC NULLS LAST, m.created_at DESC
      LIMIT %%s
    ]], viewer_can_open_adult and "" or "AND m.is_adult=false"),
    viewer0, viewer0, tostring(target_id), viewer0, tostring(limit)
  )
  attach_media_subcategories(rows)
  for _, row in ipairs(rows) do decode_media_row(row, viewer_can_open_adult, req) end
  return rows
end

local function list_profile_collections(req, target_id, viewer_id, adult_allowed, limit)
  local v = tostring(viewer_id or 0)
  local rows = db.fetchall(
    COLLECTION_SELECT .. [[
      WHERE mc.user_id=%s AND (mc.is_public OR mc.user_id=%s)
      GROUP BY mc.id, u.id
      ORDER BY mc.updated_at DESC, mc.created_at DESC
      LIMIT %s
    ]],
    v, v, tostring(target_id), v, tostring(limit)
  )
  for _, row in ipairs(rows) do
    decode_collection(row)
    with_collection_urls(req, row, adult_allowed)
  end
  return rows
end

local function list_profile_friends(user_id, viewer_id, limit)
  -- Must tostring() here (not just `viewer_id or "0"`): callers pass a mix
  -- of already-string ids (from auth_optional()) and raw numbers (from
  -- decode_user()'s current_user()/get_public_profile() results, e.g.
  -- my_friends() passing user.id twice) -- a bare Lua number bound against
  -- this query's "::text=%s" comparisons makes Postgres error with
  -- "operator does not exist: text = integer", which db.fetchall()
  -- swallows and returns as an empty list, not a visible error.
  local viewer0 = tostring(viewer_id or 0)
  local rows = db.fetchall(
    [[
      SELECT u.id, u.username,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.display_name ELSE u.username END AS display_name,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.bio ELSE NULL END AS bio,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.avatar_path ELSE NULL END AS avatar_path,
             u.profile_color, u.public_profile, u.last_seen_at, fr.responded_at AS friended_at
      FROM friend_requests fr
      JOIN users u ON u.id = CASE WHEN fr.requester_id::text=%s THEN fr.addressee_id ELSE fr.requester_id END
      WHERE fr.status='accepted' AND (fr.requester_id::text=%s OR fr.addressee_id::text=%s)
      ORDER BY fr.responded_at DESC, fr.created_at DESC
      LIMIT %s
    ]],
    viewer0, viewer0, viewer0, tostring(user_id), tostring(user_id), tostring(user_id), tostring(limit)
  )
  for _, row in ipairs(rows) do decode_user(row) end
  return rows
end

function M.profile_page(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local profile = get_public_profile(req, req.params.username, viewer_id)
  if not profile then return 404, { detail = "User not found." } end
  if viewer_id and is_blocked_either_way(viewer_id, profile.id) then
    return 404, { detail = "User not found." }
  end
  local adult_allowed = viewer_adult_allowed(viewer_id)
  local is_owner = viewer_id and tostring(viewer_id) == tostring(profile.id)
  local settings = profile.user_settings or {}
  local show_uploads = is_owner or (settings.profile_show_uploads ~= nil and settings.profile_show_uploads or profile.show_recent_uploads)
  local show_collections = is_owner or (settings.profile_show_collections ~= nil and settings.profile_show_collections or profile.show_collections)
  local show_friends = is_owner or (settings.profile_show_friends ~= nil and settings.profile_show_friends or profile.show_friends)
  local media = show_uploads and list_profile_media(req, profile.id, viewer_id, adult_allowed, 36) or {}
  local collections = show_collections and list_profile_collections(req, profile.id, viewer_id, adult_allowed, 12) or {}
  local friends = show_friends and list_profile_friends(profile.id, viewer_id, 18) or {}
  return 200, {
    user = with_user_urls(req, profile),
    media = arr(media),
    collections = arr(collections),
    friends = arr(friends),
  }
end

function M.follow_user(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local rl_status, rl_body = ratelimit.check("follow:" .. user.id, 60, 3600)
  if rl_status then return rl_status, rl_body end
  local followed_id = tonumber(req.params.user_id)
  if not followed_id then return 404, { detail = "User not found." } end
  local payload = json_body(req)
  local following = db.tobool(payload.following)
  if tostring(user.id) == tostring(followed_id) then
    return 400, { detail = "You cannot follow yourself." }
  end
  if following and is_blocked_either_way(user.id, followed_id) then
    return 403, { detail = "You cannot follow this user." }
  end
  local exists = db.fetchone("SELECT id FROM users WHERE id=%s", tostring(followed_id))
  if not exists then return 404, { detail = "User not found." } end
  if following then
    db.execute("INSERT INTO user_follows (follower_id, followed_id) VALUES (%s, %s) ON CONFLICT (follower_id, followed_id) DO NOTHING", tostring(user.id), tostring(followed_id))
  else
    db.execute("DELETE FROM user_follows WHERE follower_id=%s AND followed_id=%s", tostring(user.id), tostring(followed_id))
  end
  local count_row = db.fetchone("SELECT COUNT(*) AS n FROM user_follows WHERE followed_id=%s", tostring(followed_id))
  if following then create_notification(followed_id, user.id, "follow") end
  return 200, { followed_id = followed_id, following = following, follower_count = db.toint(count_row and count_row.n, 0) }
end

-- PATCH /api/users/:user_id/follow-mute { muted: bool } -- per-follow
-- notification muting, 2026-10-11 (see M.upload_media's finalize_upload --
-- the followers SELECT there is the thing this actually gates). Staying
-- followed but muted is deliberately a distinct state from unfollowing:
-- the viewer still sees this account in their following feed/list, they
-- just stop getting a "new_upload" notification for every post.
function M.set_follow_mute(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local followed_id = tonumber(req.params.user_id)
  if not followed_id then return 404, { detail = "User not found." } end
  local payload = json_body(req)
  local muted = db.tobool(payload.muted)
  local existing = db.fetchone(
    "SELECT follower_id FROM user_follows WHERE follower_id=%s AND followed_id=%s",
    tostring(user.id), tostring(followed_id)
  )
  if not existing then return 404, { detail = "You are not following this user." } end
  db.execute(
    "UPDATE user_follows SET notifications_muted=%s WHERE follower_id=%s AND followed_id=%s",
    muted, tostring(user.id), tostring(followed_id)
  )
  return 200, { followed_id = followed_id, notifications_muted = muted }
end

function M.send_friend_request(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local rl_status, rl_body = ratelimit.check("friend_request:" .. user.id, 30, 3600)
  if rl_status then return rl_status, rl_body end
  local addressee_id = tonumber(req.params.user_id)
  if not addressee_id then return 404, { detail = "User not found." } end
  if tostring(user.id) == tostring(addressee_id) then
    return 400, { detail = "You cannot friend yourself." }
  end
  if is_blocked_either_way(user.id, addressee_id) then
    return 403, { detail = "You cannot send a friend request to this user." }
  end
  local exists = db.fetchone("SELECT id FROM users WHERE id=%s", tostring(addressee_id))
  if not exists then return 400, { detail = "User not found." } end

  local existing = db.fetchone(
    [[
      SELECT * FROM friend_requests
      WHERE (requester_id=%s AND addressee_id=%s) OR (requester_id=%s AND addressee_id=%s)
      ORDER BY CASE status
        WHEN 'accepted' THEN 1 WHEN 'pending' THEN 2 WHEN 'declined' THEN 3 WHEN 'cancelled' THEN 4 ELSE 5
      END, created_at DESC
      LIMIT 1
    ]],
    tostring(user.id), tostring(addressee_id), tostring(addressee_id), tostring(user.id)
  )
  local result_status, request_row
  if existing and existing.status == "accepted" then
    result_status, request_row = "friends", existing
  elseif existing and existing.status == "pending" then
    if tostring(existing.requester_id) == tostring(addressee_id) then
      db.execute("UPDATE friend_requests SET status='accepted', responded_at=CURRENT_TIMESTAMP WHERE id=%s", tostring(existing.id))
      existing.status = "accepted"
      result_status, request_row = "friends", existing
    else
      result_status, request_row = "pending_out", existing
    end
  elseif existing then
    db.execute(
      "UPDATE friend_requests SET requester_id=%s, addressee_id=%s, status='pending', created_at=CURRENT_TIMESTAMP, responded_at=NULL WHERE id=%s",
      tostring(user.id), tostring(addressee_id), tostring(existing.id)
    )
    result_status = "pending_out"
    request_row = db.fetchone("SELECT * FROM friend_requests WHERE id=%s", tostring(existing.id))
  else
    local inserted = db.fetchone(
      "INSERT INTO friend_requests (requester_id, addressee_id) VALUES (%s, %s) RETURNING id",
      tostring(user.id), tostring(addressee_id)
    )
    result_status = "pending_out"
    request_row = db.fetchone("SELECT * FROM friend_requests WHERE id=%s", tostring(inserted.id))
  end
  if request_row then
    request_row.id = db.toint(request_row.id, request_row.id)
    request_row.requester_id = db.toint(request_row.requester_id, request_row.requester_id)
    request_row.addressee_id = db.toint(request_row.addressee_id, request_row.addressee_id)
  end
  create_notification(addressee_id, user.id, "friend_request")
  return 200, { status = result_status, request = request_row }
end

local function decode_friend_request_row(row)
  row.id = db.toint(row.id, row.id)
  row.requester_id = db.toint(row.requester_id, row.requester_id)
  row.addressee_id = db.toint(row.addressee_id, row.addressee_id)
  row.user_id = db.toint(row.user_id, row.user_id)
  row.public_profile = db.tobool(row.public_profile)
  row.is_online = db.tobool(row.is_online)
  local user = {
    id = row.user_id, username = row.username, display_name = row.display_name,
    bio = row.bio, avatar_path = row.avatar_path, profile_color = row.profile_color,
    public_profile = row.public_profile, last_seen_at = row.last_seen_at,
  }
  row.user = user
  return row
end

function M.friend_requests_list(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local function fetch(own_col, other_col)
    local rows = db.fetchall(
      string.format(
        [[
          SELECT fr.*, u.id AS user_id, u.username, u.display_name, u.bio, u.avatar_path,
                 u.profile_color, u.public_profile, u.last_seen_at
          FROM friend_requests fr
          JOIN users u ON u.id=fr.%s
          WHERE fr.%s=%%s AND fr.status='pending'
          ORDER BY fr.created_at DESC
          LIMIT 100
        ]],
        other_col, own_col
      ),
      tostring(user.id)
    )
    for _, row in ipairs(rows) do
      decode_friend_request_row(row)
      with_user_urls(req, row.user)
    end
    return rows
  end
  return 200, {
    incoming = arr(fetch("addressee_id", "requester_id")),
    outgoing = arr(fetch("requester_id", "addressee_id")),
  }
end

function M.respond_friend_request(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local request_id = tonumber(req.params.request_id)
  if not request_id then return 404, { detail = "Friend request not found." } end
  local payload = json_body(req)
  local action = nn(payload.action)
  local next_status = ({ accept = "accepted", decline = "declined", cancel = "cancelled" })[action or ""]
  if not next_status then return 400, { detail = "Action must be accept, decline, or cancel." } end

  local row
  if action == "cancel" then
    row = db.fetchone("SELECT * FROM friend_requests WHERE id=%s AND requester_id=%s AND status='pending'", tostring(request_id), tostring(user.id))
  else
    row = db.fetchone("SELECT * FROM friend_requests WHERE id=%s AND addressee_id=%s AND status='pending'", tostring(request_id), tostring(user.id))
  end
  if not row then return 404, { detail = "Friend request not found." } end
  db.execute("UPDATE friend_requests SET status=%s, responded_at=CURRENT_TIMESTAMP WHERE id=%s", next_status, tostring(request_id))
  row.status = next_status
  row.id = db.toint(row.id, row.id)
  row.requester_id = db.toint(row.requester_id, row.requester_id)
  row.addressee_id = db.toint(row.addressee_id, row.addressee_id)
  if next_status == "accepted" then
    create_notification(row.requester_id, user.id, "friend_accept")
  end
  return 200, { request = row }
end

function M.my_friends(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local friends = list_profile_friends(user.id, user.id, 80)
  for _, row in ipairs(friends) do with_user_urls(req, row) end
  return 200, { friends = arr(friends) }
end

function M.user_followers(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local user_id = tonumber(req.params.user_id)
  if not user_id then return 404, { detail = "User not found." } end
  local viewer0 = tostring(viewer_id or 0)
  local rows = db.fetchall(
    [[
      SELECT u.id, u.username,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.display_name ELSE u.username END AS display_name,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.bio ELSE NULL END AS bio,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.avatar_path ELSE NULL END AS avatar_path,
             u.profile_color, u.public_profile, u.last_seen_at
      FROM user_follows f
      JOIN users u ON u.id = f.follower_id
      WHERE f.followed_id=%s
      ORDER BY f.created_at DESC
      LIMIT 200
    ]],
    viewer0, viewer0, viewer0, tostring(user_id)
  )
  for _, row in ipairs(rows) do
    decode_user(row)
    with_user_urls(req, row)
  end
  return 200, { users = arr(rows) }
end

function M.user_following(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local user_id = tonumber(req.params.user_id)
  if not user_id then return 404, { detail = "User not found." } end
  local viewer0 = tostring(viewer_id or 0)
  local rows = db.fetchall(
    [[
      SELECT u.id, u.username,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.display_name ELSE u.username END AS display_name,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.bio ELSE NULL END AS bio,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.avatar_path ELSE NULL END AS avatar_path,
             u.profile_color, u.public_profile, u.last_seen_at
      FROM user_follows f
      JOIN users u ON u.id = f.followed_id
      WHERE f.follower_id=%s
      ORDER BY f.created_at DESC
      LIMIT 200
    ]],
    viewer0, viewer0, viewer0, tostring(user_id)
  )
  for _, row in ipairs(rows) do
    decode_user(row)
    with_user_urls(req, row)
  end
  return 200, { users = arr(rows) }
end

function M.user_friends(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local user_id = tonumber(req.params.user_id)
  if not user_id then return 404, { detail = "User not found." } end
  local friends = list_profile_friends(user_id, viewer_id, 80)
  for _, row in ipairs(friends) do with_user_urls(req, row) end
  return 200, { friends = arr(friends) }
end

function M.block_user(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local rl_status, rl_body = ratelimit.check("block_user:" .. user.id, 60, 3600)
  if rl_status then return rl_status, rl_body end
  local target_id = tonumber(req.params.user_id)
  if not target_id then return 404, { detail = "User not found." } end
  local payload = json_body(req)
  local kind = nn(payload.kind)
  if kind ~= "block" and kind ~= "mute" then return 400, { detail = "kind must be block or mute." } end
  if tostring(user.id) == tostring(target_id) then
    return 400, { detail = "You cannot block or mute yourself." }
  end
  local exists = db.fetchone("SELECT id FROM users WHERE id=%s", tostring(target_id))
  if not exists then return 400, { detail = "User not found." } end
  local active = db.tobool(payload.active)
  if active then
    db.execute(
      "INSERT INTO user_blocks (blocker_id, blocked_id, kind) VALUES (%s, %s, %s) ON CONFLICT (blocker_id, blocked_id, kind) DO NOTHING",
      tostring(user.id), tostring(target_id), kind
    )
  else
    db.execute("DELETE FROM user_blocks WHERE blocker_id=%s AND blocked_id=%s AND kind=%s", tostring(user.id), tostring(target_id), kind)
  end
  return 200, { blocked_id = target_id, kind = kind, active = active }
end

function M.my_blocks(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local rows = db.fetchall(
    [[
      SELECT ub.kind, ub.created_at, u.id, u.username, u.display_name, u.avatar_path, u.profile_color
      FROM user_blocks ub
      JOIN users u ON u.id = ub.blocked_id
      WHERE ub.blocker_id=%s
      ORDER BY ub.created_at DESC
    ]],
    tostring(user.id)
  )
  local blocks = {}
  for _, row in ipairs(rows) do
    local kind = row.kind
    local created_at = row.created_at
    row.kind, row.created_at = nil, nil
    decode_user(row)
    with_user_urls(req, row)
    blocks[#blocks + 1] = { kind = kind, created_at = created_at, user = row }
  end
  return 200, { blocks = arr(blocks) }
end

-- ---------------------------------------------------------------------------
-- Site-owner admin/moderation. Mirrors app/routers/admin.py +
-- app/db/admin.py. NOT PORTED as part of this pass: the storage dashboard /
-- purge-orphans endpoints (app/routers/admin.py's storage_dashboard /
-- purge_storage_orphans) -- those filesystem-walk the on-disk thumb/video
-- cache dirs, which is lower value while the dataset is DB-blob-backed (see
-- media_files.lua's docstring); left for a follow-up.
-- ---------------------------------------------------------------------------

-- Depends()-equivalent for _require_site_owner(): returns (owner_user) or
-- (nil, status, body) on failure.
local function require_site_owner(req)
  local user, auth, status, body = current_user(req)
  if not user then return nil, status, body end
  if not is_site_owner(user) then
    return nil, 403, { detail = "Only the verified site owner can use this action." }
  end
  return user
end
-- Exported for pages_admin.lua's server-rendered dashboard, which needs the
-- exact same "logged in AND verified site owner" check the JSON API
-- endpoints below use, but renders an HTML page/redirect on failure instead
-- of a JSON error body.
M.require_site_owner_for_page = require_site_owner

local function write_audit_log(actor_id, action, target_type, target_id, detail)
  detail = detail and tostring(detail):sub(1, 500) or nil
  if detail == "" then detail = nil end
  db.execute(
    "INSERT INTO moderation_audit_log (actor_id, action, target_type, target_id, detail) VALUES (%s, %s, %s, %s, %s)",
    actor_id and tostring(actor_id) or nil, tostring(action):sub(1, 60), tostring(target_type):sub(1, 30),
    target_id and tostring(target_id) or nil, detail
  )
end

-- ---------------------------------------------------------------------------
-- Background music (see scripts/pg_add_background_music.sql). Up to
-- MAX_BACKGROUND_MUSIC_TRACKS tracks the site owner injects/removes from
-- the admin panel; every visitor's client shuffles through whatever's
-- currently uploaded while browsing (M.list_background_music /
-- M.serve_background_music_file, both public/unauthenticated -- ambient
-- music isn't gated content) and ducks it when a video with sound starts
-- playing (client-side, see frontend/src/components/BackgroundMusicPlayer.jsx).
-- ---------------------------------------------------------------------------

local MAX_BACKGROUND_MUSIC_TRACKS = 10
local MAX_BACKGROUND_MUSIC_BYTES = 30 * 1024 * 1024

-- Minimal magic-byte sniffer for the handful of audio containers a track
-- upload realistically arrives as -- mirrors sniff_magic's image/video
-- approach (never trust the client-supplied Content-Type for what gets
-- stored/served back out).
local function sniff_audio_magic(content)
  local head = content:sub(1, 64)
  if head:sub(1, 3) == "ID3" then return "audio/mpeg" end
  -- Frame-sync MP3 with no ID3 tag: 11 set bits (0xFFE.. / 0xFFF..).
  if #head >= 2 and head:byte(1) == 0xFF and bit.band(head:byte(2), 0xE0) == 0xE0 then return "audio/mpeg" end
  if head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WAVE" then return "audio/wav" end
  if head:sub(1, 4) == "OggS" then return "audio/ogg" end
  if head:sub(1, 4) == "fLaC" then return "audio/flac" end
  if #head >= 12 and head:sub(5, 8) == "ftyp" then
    local brands = head:sub(9, 32):lower()
    if brands:find("m4a", 1, true) or brands:find("m4b", 1, true) then return "audio/mp4" end
  end
  return nil
end

local BACKGROUND_MUSIC_EXT = {
  ["audio/mpeg"] = ".mp3", ["audio/wav"] = ".wav", ["audio/ogg"] = ".ogg",
  ["audio/flac"] = ".flac", ["audio/mp4"] = ".m4a",
}

function M.admin_list_background_music(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local rows = db.fetchall(
    "SELECT bm.id, bm.title, bm.original_filename, bm.mime_type, bm.file_size, bm.sort_order, bm.created_at, " ..
      "u.username AS uploaded_by_username " ..
      "FROM background_music bm LEFT JOIN users u ON u.id = bm.uploaded_by " ..
      "ORDER BY bm.sort_order ASC, bm.id ASC"
  )
  local origin = request_origin(req)
  for _, row in ipairs(rows) do
    row.id = db.toint(row.id, row.id)
    row.file_size = db.toint(row.file_size, 0)
    row.url = origin .. "/api/background-music/" .. tostring(row.id) .. "/file"
  end
  return 200, { tracks = arr(rows), max_tracks = MAX_BACKGROUND_MUSIC_TRACKS }
end

function M.admin_upload_background_music(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end

  local count_row = db.fetchone("SELECT COUNT(*) AS n FROM background_music")
  if db.toint(count_row and count_row.n, 0) >= MAX_BACKGROUND_MUSIC_TRACKS then
    return 400, { detail = string.format("Only %d background tracks are allowed at once -- remove one first.", MAX_BACKGROUND_MUSIC_TRACKS) }
  end

  local upload = (req.files or {}).file
  if not upload or not upload.content or upload.content == "" then
    return 400, { detail = "Upload is empty." }
  end
  if #upload.content > MAX_BACKGROUND_MUSIC_BYTES then
    return 413, { detail = string.format("Tracks must be %dMB or smaller.", math.floor(MAX_BACKGROUND_MUSIC_BYTES / (1024 * 1024))) }
  end
  local mime_type = sniff_audio_magic(upload.content)
  if not mime_type then
    return 400, { detail = "Unsupported audio format. Use MP3, WAV, OGG, FLAC, or M4A." }
  end

  local form = req.form or {}
  local original_filename = ((upload.filename or "track"):match("([^/\\]+)$") or "track"):sub(1, 255)
  local title = trim(nn(form.title) or ""):sub(1, 120)
  if title == "" then
    title = (original_filename:gsub(BACKGROUND_MUSIC_EXT[mime_type] and BACKGROUND_MUSIC_EXT[mime_type] .. "$" or "%.[^.]+$", ""))
  end

  local next_sort_row = db.fetchone("SELECT COALESCE(MAX(sort_order), -1) + 1 AS n FROM background_music")
  local sort_order = db.toint(next_sort_row and next_sort_row.n, 0)

  local row = db.fetchone(
    "INSERT INTO background_music (title, original_filename, mime_type, content, file_size, sort_order, uploaded_by) " ..
      "VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING id",
    title, original_filename, mime_type, media_files.bytea_literal(upload.content), tostring(#upload.content), tostring(sort_order), tostring(owner.id)
  )
  write_audit_log(owner.id, "background_music_upload", "background_music", row and row.id, title)
  return 200, { id = row and db.toint(row.id), title = title }
end

function M.admin_delete_background_music(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local track_id = tonumber(req.params.track_id)
  if not track_id then return 404, { detail = "Track not found." } end
  local existing = db.fetchone("SELECT id, title FROM background_music WHERE id=%s", tostring(track_id))
  if not existing then return 404, { detail = "Track not found." } end
  db.execute("DELETE FROM background_music WHERE id=%s", tostring(track_id))
  write_audit_log(owner.id, "background_music_delete", "background_music", track_id, existing.title)
  return 200, { ok = true }
end


-- Public: every visitor's client (logged in or not) fetches this list to
-- build its own local shuffle order -- no auth, no per-track access
-- token, same as the site's public media browsing.
function M.list_background_music(req)
  local rows = db.fetchall(
    "SELECT id, title FROM background_music ORDER BY sort_order ASC, id ASC"
  )
  local origin = request_origin(req)
  for _, row in ipairs(rows) do
    row.id = db.toint(row.id, row.id)
    row.url = origin .. "/api/background-music/" .. tostring(row.id) .. "/file"
  end
  return 200, { tracks = arr(rows) }
end

function M.serve_background_music_file(req)
  local track_id = tonumber(req.params.track_id)
  if not track_id then return 404, { detail = "Track not found." } end
  local row = db.fetchone("SELECT mime_type, content FROM background_music WHERE id=%s", tostring(track_id))
  if not row then return 404, { detail = "Track not found." } end
  return 200, row.content, { ["Content-Type"] = row.mime_type, ["Cache-Control"] = "public, max-age=86400" }
end

function M.admin_stats(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local users_row = db.fetchone("SELECT COUNT(*) AS n FROM users")
  local categories_row = db.fetchone("SELECT COUNT(*) AS n FROM categories")
  local media_row = db.fetchone("SELECT COUNT(*) AS n, COALESCE(SUM(file_size), 0) AS bytes FROM media_items")
  local likes_row = db.fetchone("SELECT COUNT(*) AS n FROM media_likes")
  return 200, {
    stats = {
      users = db.toint(users_row and users_row.n, 0),
      categories = db.toint(categories_row and categories_row.n, 0),
      media = db.toint(media_row and media_row.n, 0),
      bytes = db.toint(media_row and media_row.bytes, 0),
      likes = db.toint(likes_row and likes_row.n, 0),
    },
  }
end

local REPORT_STATUSES = { open = true, reviewed = true, dismissed = true }

function M.admin_list_reports(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local q = req.query or {}
  local report_status = REPORT_STATUSES[q.status or ""] and q.status or nil
  local limit = math.max(1, math.min(tonumber(q.limit) or 50, 200))
  local offset = math.max(0, tonumber(q.offset) or 0)
  local where = report_status and "WHERE r.status=%s" or ""
  local sql = string.format(
    [[
      SELECT r.id, r.media_id, r.user_id, r.reason, r.details, r.status, r.created_at,
             m.title AS media_title, m.media_kind, m.mime_type,
             m.deleted_at AS media_deleted_at, m.user_id AS media_owner_id,
             ru.username AS reporter_username, ru.display_name AS reporter_display_name,
             mu.username AS media_owner_username, mu.display_name AS media_owner_display_name
      FROM media_reports r
      JOIN media_items m ON m.id = r.media_id
      JOIN users ru ON ru.id = r.user_id
      JOIN users mu ON mu.id = m.user_id
      %s
      ORDER BY r.created_at DESC
      LIMIT %%s OFFSET %%s
    ]],
    where
  )
  local rows
  if report_status then
    rows = db.fetchall(sql, report_status, tostring(limit), tostring(offset))
  else
    rows = db.fetchall(sql, tostring(limit), tostring(offset))
  end
  local origin = request_origin(req)
  for _, row in ipairs(rows) do
    row.id = db.toint(row.id, row.id)
    row.media_id = db.toint(row.media_id, row.media_id)
    row.user_id = db.toint(row.user_id, row.user_id)
    row.media_owner_id = row.media_owner_id and db.toint(row.media_owner_id, row.media_owner_id) or nil
    row.media_thumb_url = row.media_id and row.media_id > 0 and append_query(origin .. "/api/media/" .. row.media_id .. "/thumb", "w", "640") or nil
  end
  return 200, { reports = arr(rows), limit = limit, offset = offset }
end

function M.admin_resolve_report(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local report_id = tonumber(req.params.report_id)
  if not report_id then return 404, { detail = "Report not found." } end
  local payload = json_body(req)
  local new_status = nn(payload.status)
  if new_status ~= "reviewed" and new_status ~= "dismissed" then
    return 400, { detail = "status must be reviewed or dismissed." }
  end
  db.execute("UPDATE media_reports SET status=%s WHERE id=%s", new_status, tostring(report_id))
  local report = db.fetchone("SELECT * FROM media_reports WHERE id=%s", tostring(report_id))
  if not report then return 404, { detail = "Report not found." } end
  report.id = db.toint(report.id, report.id)
  report.media_id = db.toint(report.media_id, report.media_id)
  report.user_id = db.toint(report.user_id, report.user_id)
  write_audit_log(owner.id, "report_" .. new_status, "report", report_id, "media_id=" .. tostring(report.media_id))
  if payload.delete_media then
    db.execute(
      "UPDATE media_items SET deleted_at=CURRENT_TIMESTAMP, visibility='private' WHERE id=%s AND deleted_at IS NULL",
      tostring(report.media_id)
    )
    write_audit_log(owner.id, "delete_media", "media", report.media_id, nil)
  end
  return 200, { report = report }
end

function M.admin_ban_user(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local user_id = tonumber(req.params.user_id)
  if not user_id then return 404, { detail = "User not found." } end
  if tostring(user_id) == tostring(owner.id) then
    return 400, { detail = "You cannot ban your own account." }
  end
  local payload = json_body(req)
  local reason = trim(nn(payload.reason) or ""):sub(1, 300)
  if reason == "" then reason = nil end
  local until_value = nn(payload["until"])

  local result = db.execute(
    "UPDATE users SET banned_at=CURRENT_TIMESTAMP, banned_until=%s, ban_reason=%s, banned_by=%s WHERE id=%s",
    until_value, reason, owner.id, tostring(user_id)
  )
  local user = get_user(tostring(user_id))
  if not user then return 404, { detail = "User not found." } end
  write_audit_log(owner.id, "ban", "user", user_id, reason)
  user.site_owner = is_site_owner(user)
  return 200, { user = user }
end

function M.admin_unban_user(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local user_id = tonumber(req.params.user_id)
  if not user_id then return 404, { detail = "User not found." } end
  db.execute(
    "UPDATE users SET banned_at=NULL, banned_until=NULL, ban_reason=NULL, banned_by=NULL WHERE id=%s",
    tostring(user_id)
  )
  local user = get_user(tostring(user_id))
  if not user then return 404, { detail = "User not found." } end
  write_audit_log(owner.id, "unban", "user", user_id, nil)
  user.site_owner = is_site_owner(user)
  return 200, { user = user }
end

function M.admin_audit_log(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local limit = math.max(1, math.min(tonumber(req.query.limit) or 50, 200))
  local offset = math.max(0, tonumber(req.query.offset) or 0)
  local rows = db.fetchall(
    [[
      SELECT a.*, u.username AS actor_username, COALESCE(u.display_name, u.username) AS actor_display_name
      FROM moderation_audit_log a
      LEFT JOIN users u ON u.id = a.actor_id
      ORDER BY a.created_at DESC
      LIMIT %s OFFSET %s
    ]],
    tostring(limit), tostring(offset)
  )
  for _, row in ipairs(rows) do
    row.id = db.toint(row.id, row.id)
    row.actor_id = row.actor_id and db.toint(row.actor_id, row.actor_id) or nil
    row.target_id = row.target_id and db.toint(row.target_id, row.target_id) or nil
  end
  return 200, { entries = arr(rows) }
end

function M.admin_flagged_media(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local limit = math.max(1, math.min(tonumber(req.query.limit) or 50, 200))
  local offset = math.max(0, tonumber(req.query.offset) or 0)
  local rows = db.fetchall(
    [[
      SELECT m.*, u.username AS owner_username, COALESCE(u.display_name, u.username) AS owner_display_name
      FROM media_items m
      JOIN users u ON u.id = m.user_id
      WHERE m.moderation_status='pending_review' AND m.deleted_at IS NULL
      ORDER BY m.created_at DESC
      LIMIT %s OFFSET %s
    ]],
    tostring(limit), tostring(offset)
  )
  local origin = request_origin(req)
  for _, row in ipairs(rows) do
    numify_media(row)
    row.thumb_url = M.thumb_url_for(origin, row.id, row.media_kind, row.updated_at)
  end
  return 200, { media = arr(rows) }
end

function M.admin_resolve_flagged_media(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Flagged media not found." } end
  local payload = json_body(req)
  local decision = nn(payload.decision)
  if decision ~= "clear" and decision ~= "adult" then
    return 400, { detail = "decision must be clear or adult." }
  end
  db.execute(
    "UPDATE media_items SET moderation_status=%s, is_adult=%s, moderated_at=CURRENT_TIMESTAMP WHERE id=%s AND moderation_status='pending_review'",
    decision, decision == "adult", tostring(media_id)
  )
  local item = db.fetchone("SELECT * FROM media_items WHERE id=%s", tostring(media_id))
  if not item then return 404, { detail = "Flagged media not found." } end
  numify_media(item)
  write_audit_log(owner.id, "flagged_media_" .. decision, "media", media_id, nil)
  return 200, { media = item }
end

-- ---------------------------------------------------------------------------
-- Storage dashboard + orphaned-cache-file purge. Mirrors
-- app/db/admin.py's storage_by_user() and app/routers/admin.py's
-- _walk_cache_dir()/storage_dashboard()/purge_storage_orphans(), with one
-- deliberate correction: Python builds its "referenced" set from
-- storage_by_user()'s top-N-by-user aggregate rows, which only ever have a
-- user_id column -- referenced = {str(row["id"]) ...} raises KeyError
-- immediately (no "id" key in that row shape) and, even if it didn't, a
-- per-user aggregate has no media ids in it to match cache filenames
-- against anyway (those are named "<media_id>_<width>.webp", see
-- serve_media_thumb). This port instead builds the referenced set from the
-- actual set of live media_items ids, which is what the cache filenames are
-- really keyed by, so orphan detection actually works.
-- ---------------------------------------------------------------------------

local function storage_by_user(limit)
  limit = math.max(1, math.min(limit or 20, 100))
  local totals = db.fetchone("SELECT COALESCE(SUM(file_size), 0) AS total_bytes, COUNT(*) AS total_items FROM media_items WHERE deleted_at IS NULL")
  local by_user = db.fetchall([[
    SELECT m.user_id, u.username, COALESCE(u.display_name, u.username) AS display_name,
           COUNT(*) AS item_count, COALESCE(SUM(m.file_size), 0) AS total_bytes
    FROM media_items m
    JOIN users u ON u.id = m.user_id
    WHERE m.deleted_at IS NULL
    GROUP BY m.user_id, u.id
    ORDER BY total_bytes DESC
    LIMIT %s
  ]], tostring(limit))
  for _, row in ipairs(by_user) do
    row.user_id = db.toint(row.user_id, row.user_id)
    row.item_count = db.toint(row.item_count, 0)
    row.total_bytes = db.toint(row.total_bytes, 0)
  end
  return {
    total_bytes = db.toint(totals and totals.total_bytes, 0),
    total_items = db.toint(totals and totals.total_items, 0),
    by_user = by_user,
  }
end

-- Hardened 2026-10-11 while adding M.start_cache_orphan_sweep (below):
-- db.lua's M.fetchall ALWAYS returns a table as its first value, even on a
-- genuine SQL/connection failure (see its own definition) -- the original
-- `local rows = db.fetchall(...)` here silently got `{}` on any such
-- failure, with every caller then treating "no rows came back" as "no
-- media exists," i.e. everything looks orphaned. M.admin_purge_storage_
-- orphans (admin-triggered, a human watches the result) tolerated that
-- latent risk acceptably; M.start_cache_orphan_sweep does NOT -- it is
-- unattended and runs every 6 hours, so the exact same transient blip
-- would have it conclude nothing is referenced and treat the ENTIRE
-- cache as purgeable. Raising on a real error instead means the pcall
-- wrapping that sweep's own sweep_once skips the whole pass rather than
-- deleting anything, same fail-safe direction as every other sweep in
-- this file.
local function referenced_media_ids()
  local rows, err = db.fetchall("SELECT id FROM media_items WHERE deleted_at IS NULL")
  if err then error(err) end
  local set = {}
  for _, row in ipairs(rows) do set[tostring(db.toint(row.id, row.id))] = true end
  return set
end

local ORPHAN_CACHE_DIR_NAMES = { "_thumb_cache", "_video_cache", "_watermark_cache", "_original_cache" }
local ORPHAN_MIN_AGE_SECONDS = 24 * 3600

-- Duplicated from media_files.lua's own local ffmpeg_bin() for the same
-- reason as shell_quote above.
local function ffmpeg_bin()
  return os.getenv("GALLERY_FFMPEG_BIN") or "ffmpeg"
end

-- Runs a `-c copy -movflags +faststart` remux on a freshly-uploaded
-- MP4-family video so the "serve the original immediately via Range/206
-- while HLS renditions transcode in the background" path (see
-- ensure_hls_variant's header comment) actually delivers on "immediately":
-- a browser's <video> tag can't start decoding progressive MP4 until it
-- has the moov atom, and plenty of phone cameras/editors write that index
-- at the END of the file -- without this, the very first play of such an
-- upload would stall until nearly the whole file has streamed in, which is
-- the exact "transcoding/everything else takes a long time" symptom this
-- was added to close.
--
-- Pure stream copy (no re-encode), so this is disk-I/O-bound, not
-- CPU-bound, and fast regardless of file length -- runs synchronously in
-- the request path (same "blocks copas' event loop for the duration of the
-- ffmpeg process" tradeoff already accepted for thumbnail/preview
-- rendering, see media_files.lua's header comment) rather than the
-- detached-background pattern used for the real multi-quality transcodes,
-- since the upload response can't be sent until this either finishes or is
-- skipped.
--
-- Scratch files live under uploads_dir (not os.tmpname()'s system /tmp,
-- which is tmpfs -- RAM-backed -- on this box) both to avoid burning RAM
-- on multi-hundred-MB videos and so a same-filesystem os.rename() stays
-- possible; see save_media_file_to_disk's header comment on why
-- source_path exists at all.
--
-- Fails open: any error (corrupt input, an ffmpeg build without the mp4
-- muxer, an exotic codec the mp4 container can't hold, disk full, ...)
-- returns `source` completely untouched rather than failing the upload --
-- a working-but-not-instant upload beats rejecting an otherwise-valid one
-- over an optimization.
fast_start_remux_if_needed = function(source, sniffed_mime)
  -- mp4/mov/m4v are the only sniff_magic containers with a relocatable
  -- moov atom (ISO-BMFF/QuickTime family) -- webm/mkv (EBML) and ogg/flv
  -- have no such index to move, so +faststart is meaningless for them.
  if sniffed_mime ~= "video/mp4" and sniffed_mime ~= "video/quicktime" and sniffed_mime ~= "video/x-m4v" then
    return source
  end

  -- Scratch space: the upload staging dir (fast-disk tier when configured,
  -- see config.lua's hot_dir), so the remux reads and writes there instead
  -- of on the slow USB drive.
  local function faststart_tmp_path(suffix)
    local hot = M.settings.hot_dir
    local dir = (hot and hot ~= "") and (hot .. "/staging") or (M.settings.uploads_dir .. "/_upload_tmp")
    os.execute("mkdir -p " .. shell_quote(dir))
    return dir .. "/faststart_" .. tostring(math.random(100000000, 999999999)) .. suffix
  end

  local input_path, own_input = source.file_path, false
  if not input_path then
    input_path = faststart_tmp_path(".src")
    local f = io.open(input_path, "wb")
    if not f then return source end
    f:write(source.content)
    f:close()
    own_input = true
  end

  -- Already faststart (moov before mdat -- most phone exports and anything
  -- previously run through this): nothing to fix, skip copying the file.
  if media_files.mp4_is_faststart(input_path) == true then
    if own_input then os.remove(input_path) end
    return source
  end

  local output_path = faststart_tmp_path(".out")
  local container = sniffed_mime == "video/quicktime" and "mov" or "mp4"
  local function remux(flags)
    return os.execute(string.format(
      "nice -n 15 ionice -c2 -n6 %s -y -hide_banner -loglevel error -i %s -map 0:v:0 -map 0:a:0? "
        .. "-c copy %s -f %s %s >/dev/null 2>&1",
      ffmpeg_bin(), shell_quote(input_path), flags, container, shell_quote(output_path)
    ))
  end
  -- One pass: reserve room for the index at the front (sized from the
  -- source's own moov plus margin) so ffmpeg writes it there directly.
  -- +faststart instead writes the file and then rewrites all of it to move
  -- the index forward -- 18s vs 12s for a 1.9GB video. If the reservation
  -- turns out too small ffmpeg fails, and the two-pass way runs instead.
  local layout = media_files.mp4_layout(input_path)
  local exit
  if layout and layout.moov_size then
    exit = remux("-moov_size " .. tostring(math.floor(layout.moov_size * 1.05) + 65536))
    if not (exit == 0 or exit == true) or media_files.mp4_is_faststart(output_path) ~= true then
      os.remove(output_path)
      exit = nil
    end
  end
  if exit == nil then exit = remux("-movflags +faststart") end
  -- LuaJIT's os.execute returns the raw exit status (0 == success); the
  -- 5.2+ semantics some rocks emulate return (true, "exit", 0) instead --
  -- normalize both rather than assume one.
  local success = exit == 0 or exit == true
  local remuxed_size

  if success then
    local f = io.open(output_path, "rb")
    success = f ~= nil
    if f then
      remuxed_size = f:seek("end")
      f:close()
      success = remuxed_size ~= nil and remuxed_size > 0
    end
  end

  if own_input then os.remove(input_path) end

  if not success then
    os.remove(output_path)
    return source
  end

  -- Preserve whichever memory profile the caller was already using: a
  -- file_path in means the original bytes were never loaded into process
  -- memory (the entire point of the chunked-upload path for
  -- multi-hundred-MB videos), so returning file_path keeps
  -- save_media_file_to_disk on its cheap os.rename() branch instead of
  -- reading the remuxed copy back into a Lua string. content in means the
  -- bytes were already fully resident (M.upload_media's direct path, kept
  -- under ~100MB by the Cloudflare tunnel's own request-size cap), so
  -- reading the small remuxed copy back is no new cost.
  --
  -- file_size MUST be carried over here -- confirmed live: this used to
  -- return a bare { file_path = output_path } with no file_size, so
  -- source_size()'s fallback to source.file_size (used for both the
  -- media_items.file_size column and, upstream, nothing else) silently
  -- got nil for every mp4/mov/m4v upload where the remux actually
  -- succeeded, surfacing many calls later as a cryptic Postgres
  -- "invalid input syntax for type bigint: \"nil\"" on the INSERT. Use the
  -- remuxed output's own size (already measured above), not the original
  -- source.file_size -- +faststart changes the container's byte size
  -- slightly even under `-c copy`.
  if source.file_path then
    os.remove(source.file_path)
    return { file_path = output_path, file_size = remuxed_size }
  end

  local f = io.open(output_path, "rb")
  local content = f:read("*a")
  f:close()
  os.remove(output_path)
  return { content = content }
end

-- Pull N random tracks out of an arbitrary playlist URL (YouTube,
-- SoundCloud, anything yt-dlp's extractors cover) and add them as
-- background music. Runs entirely as a detached background job -- even a
-- handful of audio extractions can take minutes total, far past any
-- reasonable request timeout -- so this returns immediately and the admin
-- panel just polls the regular list endpoint to see tracks appear.
--
-- The job never inserts into the DB itself (no bytea/DB code in the bash
-- script -- that's real complexity worth not duplicating). Instead it
-- re-uses M.admin_upload_background_music by curling it over localhost for
-- each downloaded file, authenticated with a short-lived token minted for
-- this job. That gets the exact same validation (audio sniffing, size cap,
-- the MAX_BACKGROUND_MUSIC_TRACKS cap enforced per-insert) for free instead
-- of a second, easier-to-drift-out-of-sync copy of it.
--
-- Never string-interpolates untrusted text (playlist entry titles, etc.)
-- into a shell command: yt-dlp's own output-template sanitizes the title
-- into a filesystem-safe filename, and that's the ONLY place a title ever
-- appears -- curl's `-F file=@path` reads the multipart filename from the
-- path's basename, so no title text is ever concatenated into a command
-- line. The one piece of admin-supplied input (the playlist URL) is passed
-- as a real argv entry to bash (shell_quote'd once, by Lua, to launch the
-- script) and only ever referenced via a quoted shell variable after that,
-- never re-interpolated into another command string.
--
-- Same env-var-with-deployment-specific-fallback convention as
-- ffmpeg_bin()/ffprobe_bin() above: yt-dlp is a `pip install --user` tool
-- living in ~/.local/bin, which is on an interactive shell's PATH but NOT
-- on the systemd --user service's (confirmed live: PATH there is just
-- /usr/local/{s,}bin:/usr/bin:... -- a bare "yt-dlp" in the background
-- script failed with a silently-swallowed "command not found" every time,
-- the actual reason no tracks were ever appearing).
local function ytdlp_bin()
  return os.getenv("GALLERY_YTDLP_BIN") or (os.getenv("HOME") or "/home/desmondc") .. "/.local/bin/yt-dlp"
end

function M.admin_import_background_music_playlist(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end

  local payload = json_body(req)
  local playlist_url = trim(nn(payload.url) or "")
  if playlist_url == "" or not playlist_url:match("^https?://") then
    return 400, { detail = "Enter a valid playlist URL." }
  end

  local count_row = db.fetchone("SELECT COUNT(*) AS n FROM background_music")
  local remaining = MAX_BACKGROUND_MUSIC_TRACKS - db.toint(count_row and count_row.n, 0)
  if remaining <= 0 then
    return 400, { detail = string.format("Only %d background tracks are allowed at once -- remove one first.", MAX_BACKGROUND_MUSIC_TRACKS) }
  end
  local want = math.min(remaining, tonumber(payload.count) or remaining, 10)

  -- 20 minutes -- generous for even a slow multi-track import, but bounded
  -- (not a real login session) since this token only ever needs to live
  -- for the duration of this one background job.
  local internal_token = auth_lib.issue_token(M.settings.session_secret, { id = tostring(owner.id), username = owner.username }, 1200)

  -- No string.format here -- every value the script needs (playlist URL,
  -- track count, token, port, yt-dlp's real path) travels as a real bash
  -- argv entry ($1-$5), not interpolated into this template, so yt-dlp's
  -- own %(...)s output-template syntax can be written plainly instead of
  -- %%-escaped for a formatter that never runs over this string.
  local script = [[
#!/usr/bin/env bash
set -uo pipefail
PLAYLIST_URL="$1"
NEED="$2"
TOKEN="$3"
PORT="$4"
YTDLP="$5"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

"$YTDLP" --flat-playlist --print "%(webpage_url)s" "$PLAYLIST_URL" > "$TMPDIR/urls.txt" 2>/dev/null
shuf "$TMPDIR/urls.txt" | head -n "$NEED" > "$TMPDIR/picked.txt"

while IFS= read -r vurl; do
  [ -z "$vurl" ] && continue
  OUTDIR="$(mktemp -d)"
  timeout 180 nice -n 15 ionice -c2 -n6 "$YTDLP" -x --audio-format mp3 --audio-quality 5 \
    --no-playlist --match-filter "duration<900" \
    -o "$OUTDIR/%(title).100B.%(ext)s" "$vurl" >/dev/null 2>&1
  FILE="$(ls "$OUTDIR"/*.mp3 2>/dev/null | head -n1)"
  if [ -n "$FILE" ]; then
    curl -s -o /dev/null --max-time 60 -H "Authorization: Bearer $TOKEN" \
      -F "file=@$FILE;type=audio/mpeg" "http://127.0.0.1:$PORT/api/admin/background-music"
  fi
  rm -rf "$OUTDIR"
done < "$TMPDIR/picked.txt"
]]

  local script_path = os.tmpname() .. ".sh"
  local sf = assert(io.open(script_path, "wb"))
  sf:write(script)
  sf:close()

  local cmd = string.format(
    "( bash %s %s %s %s %s %s; rm -f %s ) </dev/null >/dev/null 2>&1 &",
    shell_quote(script_path), shell_quote(playlist_url), shell_quote(tostring(want)),
    shell_quote(internal_token), shell_quote(tostring(M.settings.port)), shell_quote(ytdlp_bin()),
    shell_quote(script_path)
  )
  os.execute(cmd)

  write_audit_log(owner.id, "background_music_playlist_import", "background_music", nil, playlist_url:sub(1, 200))
  return 202, { status = "importing", requested = want }
end

-- No lfs/posix rock is vendored, so directory listing shells out to `find`
-- (same io.popen/os.execute pattern media_files.lua already uses for
-- ffmpeg). `find -printf` gives size+mtime+path in one pass without a
-- per-file stat() round-trip.
local function walk_cache_dir(uploads_dir, referenced_ids)
  local total_bytes, total_files, orphan_bytes = 0, 0, 0
  local orphan_files = {}
  local now = os.time()
  for _, dir_name in ipairs(ORPHAN_CACHE_DIR_NAMES) do
    local cache_dir = uploads_dir .. "/" .. dir_name
    local handle = io.popen(string.format("find %s -type f -printf '%%s %%T@ %%p\\n' 2>/dev/null", shell_quote(cache_dir)))
    if handle then
      for line in handle:lines() do
        local size_str, mtime_str, path = line:match("^(%d+) (%S+) (.+)$")
        if size_str then
          local size = tonumber(size_str) or 0
          local mtime = tonumber(mtime_str) or 0
          total_bytes = total_bytes + size
          total_files = total_files + 1
          local filename = path:match("([^/]+)$") or path
          local media_id = filename:match("^(%d+)")
          local is_referenced = media_id and referenced_ids[media_id]
          if not is_referenced and (now - mtime) > ORPHAN_MIN_AGE_SECONDS then
            orphan_bytes = orphan_bytes + size
            orphan_files[#orphan_files + 1] = { path = path, size = size }
          end
        end
      end
      handle:close()
    end
  end
  return {
    cache_total_bytes = total_bytes,
    cache_total_files = total_files,
    orphan_bytes = orphan_bytes,
    orphan_count = #orphan_files,
    orphan_files = orphan_files,
  }
end

-- Admin side of the public status page (M.public_status, above): create/
-- resolve the human-curated incidents it displays. Site-owner-only, same
-- guard as every other admin_* route in this section.
function M.admin_create_incident(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local payload = json_body(req)
  local title = trim(nn(payload.title) or ""):sub(1, 200)
  if title == "" then return 400, { detail = "Title is required." } end
  local description = nn(payload.description) and tostring(payload.description):sub(1, 2000) or nil
  local severity = (nn(payload.severity) or "minor"):lower()
  if severity ~= "minor" and severity ~= "major" and severity ~= "critical" then severity = "minor" end

  local row, err = db.fetchone(
    "INSERT INTO status_incidents (title, description, severity, created_by) VALUES (%s, %s, %s, %s) RETURNING id",
    title, description, severity, tostring(owner.id)
  )
  if not row then return 500, { detail = "Could not create incident: " .. tostring(err) } end
  write_audit_log(owner.id, "incident_create", "status_incidents", db.toint(row.id, row.id), title)
  return 200, { id = db.toint(row.id, row.id), title = title, severity = severity }
end

function M.admin_resolve_incident(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local incident_id = tonumber(req.params.incident_id)
  if not incident_id then return 404, { detail = "Incident not found." } end
  local existing = db.fetchone("SELECT id FROM status_incidents WHERE id=%s", tostring(incident_id))
  if not existing then return 404, { detail = "Incident not found." } end
  db.execute("UPDATE status_incidents SET resolved_at=now() WHERE id=%s", tostring(incident_id))
  write_audit_log(owner.id, "incident_resolve", "status_incidents", incident_id, nil)
  return 200, { id = incident_id, resolved = true }
end

function M.admin_storage(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local by_user = storage_by_user(25)
  local cache_info = walk_cache_dir(M.settings.uploads_dir, referenced_media_ids())
  return 200, {
    total_bytes = by_user.total_bytes,
    total_items = by_user.total_items,
    by_user = arr(by_user.by_user),
    cache_total_bytes = cache_info.cache_total_bytes,
    cache_total_files = cache_info.cache_total_files,
    orphan_bytes = cache_info.orphan_bytes,
    orphan_count = cache_info.orphan_count,
  }
end

function M.admin_purge_storage_orphans(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local cache_info = walk_cache_dir(M.settings.uploads_dir, referenced_media_ids())
  local removed, freed_bytes = 0, 0
  for _, entry in ipairs(cache_info.orphan_files) do
    if os.remove(entry.path) then
      removed = removed + 1
      freed_bytes = freed_bytes + entry.size
    end
  end
  write_audit_log(owner.id, "storage_purge_orphans", "storage", nil, string.format("removed=%d bytes=%d", removed, freed_bytes))
  return 200, { removed = removed, freed_bytes = freed_bytes }
end

-- ---------------------------------------------------------------------------
-- Site-wide tag rename/merge. New feature, 2026-10-11: M.bulk_edit_media's
-- `add_tag` patch only ever touches an explicit, caller-supplied `ids`
-- array (capped at 200) -- there was no way to say "every post tagged X,
-- wherever it is, rename/merge that tag" without paging through the whole
-- library client-side first. Also covers pure deletion (an empty/omitted
-- `to` tag strips the tag from every post that has it) since that's the
-- same jsonb rewrite with one fewer branch.
--
-- Single batched UPDATE, not a SELECT-then-loop-N-single-row-UPDATEs --
-- the same philosophy every other bulk operation in this file uses
-- (bulk_edit_media itself included): let Postgres do the row-rewriting
-- work in one statement rather than paying a round trip per affected post.
-- `tags::jsonb ? %s` in the WHERE clause (the same `?`/`?|`/`?&` family
-- TODO.md's boolean-tag-search feature already uses) narrows the UPDATE to
-- exactly the rows that contain the tag, via the existing GIN index on
-- tags::jsonb -- it does not need a sequential scan of the whole table.
--
-- `array_agg(DISTINCT elem)` after the per-element CASE/filter is what
-- gives this MERGE semantics rather than plain rename: if a post already
-- carries both "catt" (a typo) and "cat", renaming "catt"->"cat" would
-- otherwise produce a tag array with "cat" listed twice; DISTINCT collapses
-- that back to one, so renaming into an already-present tag is safe to
-- call without checking for collisions first.
-- GET /api/admin/tags/:tag/usage -- preview count before committing to a
-- rename/merge/delete below. Cheap (same GIN-indexed `?` lookup the UPDATE
-- itself uses, just COUNT instead of rewrite) -- meant to be called from
-- the admin UI's confirmation step, not a heavy report.
function M.admin_tag_usage(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local tag = normalize_upload_tag(req.params.tag)
  if tag == "" then return 400, { detail = "Invalid tag." } end
  local row, err = db.fetchone(
    "SELECT COUNT(*) AS n FROM media_items WHERE deleted_at IS NULL AND tags IS NOT NULL AND tags::jsonb ? %s",
    tag
  )
  if err then return 500, { detail = "Query failed: " .. tostring(err) } end
  return 200, { tag = tag, count = db.toint(row and row.n, 0) }
end

-- POST /api/admin/tags/rename { from, to } -- `to` omitted/empty deletes
-- `from` everywhere instead of renaming it.
-- Nested INSIDE M.admin_rename_tag below (not a top-level local), same
-- 200-local-ceiling reason as every other such helper in this file.
function M.admin_rename_tag(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local payload = json_body(req)
  local from_tag = normalize_upload_tag(payload.from)
  local to_tag = normalize_upload_tag(payload.to or "")
  if from_tag == "" then return 400, { detail = "`from` tag is required." } end
  if from_tag == to_tag then return 400, { detail = "`to` must differ from `from` (or be omitted to delete)." } end

  local function tag_jsonb_rewrite_sql(drop_only)
    return string.format(
      [[
        UPDATE media_items
        SET tags = (
          SELECT COALESCE(to_jsonb(array_agg(DISTINCT elem)), '[]'::jsonb)::text
          FROM (
            SELECT %s AS elem
            FROM jsonb_array_elements_text(tags::jsonb) AS elem
          ) sub
          WHERE elem IS NOT NULL
        ), updated_at = now()
        WHERE deleted_at IS NULL AND tags IS NOT NULL AND tags::jsonb ? %%s
        RETURNING id
      ]],
      drop_only and "CASE WHEN elem = %s THEN NULL ELSE elem END" or "CASE WHEN elem = %s THEN %s ELSE elem END"
    )
  end

  local drop_only = to_tag == ""
  local sql = tag_jsonb_rewrite_sql(drop_only)
  local rows, err
  if drop_only then
    rows, err = db.fetchall(sql, from_tag, from_tag)
  else
    rows, err = db.fetchall(sql, from_tag, to_tag, from_tag)
  end
  if err then return 500, { detail = "Query failed: " .. tostring(err) } end

  write_audit_log(owner.id, drop_only and "tag_delete" or "tag_rename", "media_items", nil,
    string.format("from=%s to=%s affected=%d", from_tag, drop_only and "(deleted)" or to_tag, #rows))
  return 200, { from = from_tag, to = drop_only and cjson.null or to_tag, affected = #rows }
end

local SITE_SETTINGS_FIELDS = {
  "announcement_message", "announcement_level", "announcement_active",
  "maintenance_mode", "maintenance_message",
}
local SITE_SETTINGS_BOOL_FIELDS = { announcement_active = true, maintenance_mode = true }

local function fetch_site_settings()
  local row = db.fetchone("SELECT * FROM site_settings WHERE id=1")
  return row or {}
end

function M.admin_update_site_settings(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local payload = json_body(req)
  local sets, params, touched = {}, {}, {}
  for _, key in ipairs(SITE_SETTINGS_FIELDS) do
    local value = payload[key]
    if value ~= nil and value ~= cjson.null then
      sets[#sets + 1] = key .. "=%s"
      if SITE_SETTINGS_BOOL_FIELDS[key] then
        params[#params + 1] = db.tobool(value)
      else
        params[#params + 1] = tostring(value):sub(1, 500)
      end
      touched[#touched + 1] = key
    end
  end
  if #sets > 0 then
    sets[#sets + 1] = "updated_by=%s"
    params[#params + 1] = tostring(owner.id)
    db.execute("UPDATE site_settings SET " .. table.concat(sets, ", ") .. " WHERE id=1", unpack(params))
    write_audit_log(owner.id, "site_settings_update", "site_settings", nil, table.concat(touched, ", "))
  end
  return 200, { settings = fetch_site_settings() }
end

-- ---------------------------------------------------------------------------
-- AI vision status + training-example listing/export. Mirrors
-- app/routers/ai_vision.py.
--
-- NOT PORTED as part of this pass: the actual LLM-calling classification
-- pipeline (app/ai_metadata.py, ~2150 lines of prompt construction, OpenAI/
-- Gemini/Ollama request handling, and heuristic fallback analysis) that
-- powers auto_ai on upload and POST /api/media/analyze -- this is a
-- substantially larger, separate effort flagged for its own follow-up
-- pass. What IS ported: provider/config status reporting and reading back
-- previously-recorded training examples (ai_vision_training_examples rows),
-- neither of which requires the analysis pipeline itself.
-- ---------------------------------------------------------------------------

local function normalized_ai_provider()
  local provider = tostring(M.settings.ai_provider or ""):lower()
  if provider == "google" or provider == "google-gemini" then provider = "gemini" end
  if provider == "" then provider = "heuristic-only" end
  return provider
end

local function active_ai_model()
  local provider = M.settings.ai_provider
  if provider == "gemini" or provider == "google" or provider == "google-gemini" then return M.settings.ai_model end
  if provider == "ollama" then return M.settings.ai_ollama_model end
  return M.settings.ai_model
end

local function active_ai_base_url()
  if M.settings.ai_provider == "ollama" then return M.settings.ai_ollama_base_url end
  return M.settings.ai_base_url
end

function M.ai_vision_status(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local provider = normalized_ai_provider()
  local training_count = 0
  local rows = db.fetchall(
    "SELECT id FROM ai_vision_training_examples WHERE user_id=%s ORDER BY created_at DESC LIMIT 1000",
    user.id
  )
  training_count = #rows

  local vision = {
    provider = provider,
    ai_enabled = M.settings.ai_enabled and true or false,
    training_examples_loaded_limit = M.settings.ai_training_examples_limit,
    training_examples_available = training_count,
    active_model = active_ai_model(),
    active_base_url = provider == "ollama" and active_ai_base_url() or nil,
    gemini_key_configured = (M.settings.ai_api_key ~= "" and provider == "gemini") and true or false,
  }
  if provider == "gemini" then
    vision.active_base_url = "https://generativelanguage.googleapis.com"
    -- NOT `cond and nil or false` -- that Lua ternary idiom breaks whenever
    -- the "true" branch value is itself nil/false (nil is falsy, so `or`
    -- always falls through to the third operand regardless of `cond`).
    -- Confirmed live: this previously reported "unreachable, no API key
    -- configured" unconditionally, even with gemini_key_configured=true.
    if M.settings.ai_api_key ~= "" then
      vision.reachable = nil
      vision.reason = nil
    else
      vision.reachable = false
      vision.reason = "Gemini provider is selected but no Gemini API key is configured."
    end
  elseif provider == "ollama" then
    local base_url = tostring(M.settings.ai_ollama_base_url or "http://127.0.0.1:11434"):gsub("/+$", "")
    -- copas.http, not socket.http directly -- a blocking HTTP call here
    -- would stall every other in-flight request on this single-threaded
    -- server.
    local ok, http = pcall(require, "copas.http")
    local ok2, result = pcall(function()
      local ltn12 = require("ltn12")
      local chunks = {}
      local _, code = http.request({ url = base_url .. "/api/tags", sink = ltn12.sink.table(chunks), timeout = 3 })
      if code ~= 200 then error("HTTP " .. tostring(code)) end
      local decoded = cjson.decode(table.concat(chunks)) or {}
      local models = {}
      for _, item in ipairs(decoded.models or {}) do
        if item.name and item.name ~= "" then models[#models + 1] = item.name end
        if #models >= 50 then break end
      end
      return models
    end)
    if ok and ok2 then
      vision.reachable = true
      vision.models = arr(result)
    else
      vision.reachable = false
      vision.reason = tostring(result):sub(1, 240)
    end
  end
  return 200, { vision = vision }
end

local function decode_ai_training_example(row)
  if not row then return nil end
  for _, key in ipairs({ "source_tags", "corrected_tags" }) do
    if row[key] and row[key] ~= cjson.null then
      local ok, decoded = pcall(cjson.decode, row[key])
      row[key] = (ok and type(decoded) == "table") and decoded or {}
    else
      row[key] = {}
    end
  end
  row.corrected_is_adult = db.tobool(row.corrected_is_adult)
  return row
end

function M.list_ai_training(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local limit = math.max(1, math.min(tonumber(req.query.limit) or 50, 80))
  local rows = db.fetchall(
    "SELECT * FROM ai_vision_training_examples WHERE user_id=%s ORDER BY created_at DESC LIMIT %s",
    user.id, tostring(limit)
  )
  for _, row in ipairs(rows) do decode_ai_training_example(row) end
  return 200, { training_examples = arr(rows) }
end

function M.export_ai_training(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local limit = math.max(1, math.min(tonumber(req.query.limit) or 500, 5000))
  local rows = db.fetchall(
    [[
      SELECT t.*, m.media_kind, m.mime_type
      FROM ai_vision_training_examples t
      LEFT JOIN media_items m ON m.id = t.media_id
      WHERE t.user_id=%s
      ORDER BY t.created_at DESC
      LIMIT %s
    ]],
    user.id, tostring(limit)
  )
  local lines = {}
  for _, row in ipairs(rows) do
    decode_ai_training_example(row)
    lines[#lines + 1] = cjson.encode(row)
  end
  return 200, table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""), {
    ["Content-Type"] = "application/x-ndjson; charset=utf-8",
    ["Content-Disposition"] = 'attachment; filename="gallery-ai-vision-training.jsonl"',
  }
end

-- ---------------------------------------------------------------------------
-- AI training-example write path (POST /api/media/:media_id/ai/train).
-- Mirrors app/db/ai_vision.py's record_ai_vision_training_example() and
-- app/routers/media.py's train_media_ai(). NOTE: the dedupe_key here is NOT
-- byte-identical to Python's sha256(json.dumps(payload, sort_keys=True)) --
-- cjson has no whitespace/key-order mode matching Python's json.dumps
-- exactly, and this key is only used for this backend's own upsert-by-key
-- lookups going forward (Python is being retired), so internal consistency
-- is what matters, not cross-backend hash equality with rows Python wrote
-- previously (worst case: an occasional duplicate row instead of a perfect
-- upsert onto a pre-cutover Python-written example).
-- ---------------------------------------------------------------------------

local function ai_training_dedupe_key(payload)
  local ordered = table.concat({
    tostring(payload.user_id), tostring(payload.media_id or ""), tostring(payload.original_filename or ""),
    tostring(payload.corrected_title or ""), tostring(payload.corrected_category_name or ""),
    tostring(payload.corrected_subcategory_name or ""), table.concat(payload.corrected_tags or {}, ","),
    tostring(payload.image_phash or ""), tostring(payload.image_dhash or ""),
  }, "|")
  return sodium.sodium_bin2hex(sodium.crypto_hash_sha256(ordered))
end

-- Mirrors _clean_tags(): dedup, alnum/._- only, max 12, 32 chars each.
local function clean_ai_tags(values)
  local iterable = {}
  if type(values) == "string" then
    for tok in values:gmatch("[^,#%s]+") do iterable[#iterable + 1] = tok end
  elseif type(values) == "table" then
    iterable = values
  end
  local clean, seen = {}, {}
  for _, raw in ipairs(iterable) do
    local tag = tostring(raw):gsub("^%s+", ""):gsub("%s+$", ""):gsub("[^%w_.%-]+", ""):sub(1, 32)
    local lowered = tag:lower()
    if tag ~= "" and not seen[lowered] then
      seen[lowered] = true
      clean[#clean + 1] = tag
      if #clean >= 12 then break end
    end
  end
  return clean
end

-- Returns (example) on success, or (nil, "forbidden"|"not_found"|error_string).
local function record_ai_training_example(user_id, media_id, source, corrected, notes)
  local title = clean_text(nn(corrected.title) or nn(corrected.corrected_title), 160)
  if title == "" then return nil, "Title is required." end
  local category_name = clean_text(nn(corrected.category_name) or nn(corrected.corrected_category_name), 80)
  if category_name == "" then category_name = nil end
  local subcategory_name = clean_text(nn(corrected.subcategory_name) or nn(corrected.corrected_subcategory_name), 80)
  if subcategory_name == "" then subcategory_name = nil end
  local corrected_tags = clean_ai_tags(corrected.tags or corrected.corrected_tags or {})
  local source_tags = clean_ai_tags(source.tags or source.source_tags or {})

  if media_id then
    local row = db.fetchone("SELECT id, user_id FROM media_items WHERE id=%s AND deleted_at IS NULL", tostring(media_id))
    if not row then return nil, "not_found" end
    if tostring(row.user_id) ~= tostring(user_id) then return nil, "forbidden" end
  end

  local original_filename = clean_text(source.original_filename, 255)
  if original_filename == "" then original_filename = nil end
  local source_title = clean_text(source.title, 160)
  if source_title == "" then source_title = nil end
  local source_category_name = clean_text(source.category_name, 80)
  if source_category_name == "" then source_category_name = nil end
  local source_subcategory_name = clean_text(source.subcategory_name, 80)
  if source_subcategory_name == "" then source_subcategory_name = nil end
  local notes_text = clean_text(notes, 500)
  if notes_text == "" then notes_text = nil end
  local image_phash = nn(source.image_phash) or nn(source.source_image_phash)
  local image_dhash = nn(source.image_dhash) or nn(source.source_image_dhash)
  local image_width = tonumber(source.image_width)
  local image_height = tonumber(source.image_height)
  local training_origin = clean_text(nn(source.training_origin) or nn(source.origin), 80)
  if training_origin == "" then training_origin = nil end
  local training_confidence = math.max(0.0, math.min(tonumber(source.training_confidence or corrected.training_confidence) or 0.72, 1.0))
  local corrected_is_adult = (corrected.is_adult or corrected.corrected_is_adult) and true or false

  local dedupe_key = ai_training_dedupe_key({
    user_id = user_id, media_id = media_id, original_filename = original_filename,
    corrected_title = title, corrected_category_name = category_name,
    corrected_subcategory_name = subcategory_name, corrected_tags = corrected_tags,
    image_phash = image_phash, image_dhash = image_dhash,
  })

  local existing = db.fetchone("SELECT id FROM ai_vision_training_examples WHERE dedupe_key=%s LIMIT 1", dedupe_key)
  local training_id
  if existing then
    training_id = db.toint(existing.id, existing.id)
    db.execute([[
      UPDATE ai_vision_training_examples
      SET source_title=COALESCE(%s, source_title),
          source_category_name=COALESCE(%s, source_category_name),
          source_subcategory_name=COALESCE(%s, source_subcategory_name),
          source_tags=%s,
          corrected_title=%s,
          corrected_category_name=COALESCE(%s, corrected_category_name),
          corrected_subcategory_name=COALESCE(%s, corrected_subcategory_name),
          corrected_tags=%s,
          corrected_is_adult=%s,
          notes=COALESCE(%s, notes),
          original_filename=COALESCE(%s, original_filename),
          image_phash=COALESCE(%s, image_phash),
          image_dhash=COALESCE(%s, image_dhash),
          image_width=COALESCE(%s, image_width),
          image_height=COALESCE(%s, image_height),
          training_origin=COALESCE(%s, training_origin),
          training_confidence=GREATEST(training_confidence, %s)
      WHERE id=%s
    ]],
      source_title, source_category_name, source_subcategory_name, cjson.encode(arr(source_tags)),
      title, category_name, subcategory_name, cjson.encode(arr(corrected_tags)),
      corrected_is_adult, notes_text, original_filename, image_phash, image_dhash,
      image_width and tostring(image_width) or nil, image_height and tostring(image_height) or nil,
      training_origin, tostring(training_confidence), tostring(training_id)
    )
  else
    local row, err = db.fetchone([[
      INSERT INTO ai_vision_training_examples
        (user_id, media_id, original_filename, source_title, source_category_name, source_subcategory_name,
         source_tags, corrected_title, corrected_category_name, corrected_subcategory_name, corrected_tags,
         corrected_is_adult, notes, dedupe_key, image_phash, image_dhash, image_width, image_height, training_origin, training_confidence)
      VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
      RETURNING id
    ]],
      tostring(user_id), media_id and tostring(media_id) or nil, original_filename, source_title,
      source_category_name, source_subcategory_name, cjson.encode(arr(source_tags)),
      title, category_name, subcategory_name, cjson.encode(arr(corrected_tags)),
      corrected_is_adult, notes_text, dedupe_key, image_phash, image_dhash,
      image_width and tostring(image_width) or nil, image_height and tostring(image_height) or nil,
      training_origin, tostring(training_confidence)
    )
    if not row then return nil, "Could not save training example: " .. tostring(err) end
    training_id = db.toint(row.id, row.id)
  end

  local result = db.fetchone("SELECT * FROM ai_vision_training_examples WHERE id=%s", tostring(training_id))
  return decode_ai_training_example(result)
end

function M.train_media_ai(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local item = fetch_media_by_id(media_id, tostring(user.id))
  if not item then return 404, { detail = "Media not found." } end
  local item_tags = {}
  if item.tags and item.tags ~= cjson.null then
    local ok, decoded = pcall(cjson.decode, item.tags)
    if ok and type(decoded) == "table" then item_tags = decoded end
  end

  local payload = json_body(req)
  local corrected = {
    title = payload.title, category_name = payload.category_name,
    subcategory_name = payload.subcategory_name, tags = payload.tags or {},
    is_adult = payload.is_adult and true or false,
  }
  local source = {
    original_filename = item.original_filename, title = item.title,
    category_name = item.category_name, subcategory_name = item.subcategory_name,
    tags = item_tags,
  }
  local example, err = record_ai_training_example(user.id, media_id, source, corrected, payload.notes)
  if err == "forbidden" then return 403, { detail = "You can only train AI using your own media." } end
  if err == "not_found" then return 404, { detail = "Media not found." } end
  if not example then return 400, { detail = tostring(err) } end
  return 200, { training_example = example }
end

-- Client-side telemetry only (never blocks/affects the actual media load) --
-- mirrors app/routers/media.py's report_media_load_diagnostic().
function M.media_load_diagnostic(req)
  local media_id = tonumber(req.params.media_id)
  local auth = auth_optional(req)
  local payload = json_body(req)
  local context = tostring(nn(payload.context) or ""):lower():sub(1, 48)
  local outcome = tostring(nn(payload.outcome) or ""):lower():sub(1, 32)
  local media_kind = tostring(nn(payload.media_kind) or ""):lower():sub(1, 16)
  local selected_source = tostring(nn(payload.selected_source) or ""):lower():sub(1, 32)
  print(string.format(
    "[nyxframe] media load diagnostic media_id=%s outcome=%s context=%s selected=%s media_kind=%s viewer_id=%s",
    tostring(media_id), outcome ~= "" and outcome or "unknown", context ~= "" and context or "unknown",
    selected_source ~= "" and selected_source or "none", media_kind ~= "" and media_kind or "unknown",
    tostring(auth and auth.id or 0)
  ))
  M.telemetry.record("media_load", media_id, outcome ~= "" and outcome or "unknown", nil, {
    context = context ~= "" and context or nil, selected_source = selected_source ~= "" and selected_source or nil,
    media_kind = media_kind ~= "" and media_kind or nil, viewer_id = auth and auth.id or nil,
  })
  return 200, { ok = true }
end

-- Client-side video/HLS playback telemetry -- companion to
-- media_load_diagnostic above, but for the richer set of events only
-- VideoPlayer.jsx can observe (time-to-first-frame, buffering stalls,
-- quality downgrades, final outcome). Same "never blocks/affects the actual
-- playback" contract: this only ever records what already happened.
function M.media_playback_diagnostic(req)
  local media_id = tonumber(req.params.media_id)
  local auth = auth_optional(req)
  local payload = json_body(req)
  local outcome = tostring(nn(payload.outcome) or ""):lower():sub(1, 32)
  local quality = tostring(nn(payload.quality) or ""):lower():sub(1, 16)
  local ttff_ms = tonumber(payload.time_to_first_frame_ms)
  local stall_count = math.max(0, math.floor(tonumber(payload.stall_count) or 0))
  local stall_ms = math.max(0, math.floor(tonumber(payload.stall_total_ms) or 0))
  local downgrade_count = math.max(0, math.floor(tonumber(payload.quality_downgrade_count) or 0))
  local using_hls_js = payload.using_hls_js and true or false
  M.telemetry.record("media_playback", media_id, outcome ~= "" and outcome or "unknown", ttff_ms and math.floor(ttff_ms) or nil, {
    quality = quality ~= "" and quality or nil, stall_count = stall_count, stall_total_ms = stall_ms,
    quality_downgrade_count = downgrade_count, using_hls_js = using_hls_js, viewer_id = auth and auth.id or nil,
  })
  return 200, { ok = true }
end

-- Fire-and-forget upload-experience beacon from the client (UploadPage.jsx),
-- posted once a direct or chunked upload settles -- there's no media_id yet
-- at that point (that's the whole reason this isn't just another
-- media_load_diagnostic-style per-media endpoint), so this is keyed by
-- upload outcome/size/timing only, same "never affects the actual upload"
-- contract as the other client diagnostics beacons.
function M.upload_client_diagnostic(req)
  local auth = auth_optional(req)
  local payload = json_body(req)
  local outcome = tostring(nn(payload.outcome) or ""):lower():sub(1, 32)
  local method = tostring(nn(payload.method) or ""):lower():sub(1, 16) -- "direct" | "chunked"
  local duration_ms = tonumber(payload.duration_ms)
  local bytes = tonumber(payload.bytes)
  local chunk_count = tonumber(payload.chunk_count)
  local retry_count = tonumber(payload.retry_count)
  local error_message = nn(payload.error_message)
  M.telemetry.record("upload", "client_" .. (method ~= "" and method or "unknown"), outcome ~= "" and outcome or "unknown",
    duration_ms and math.floor(duration_ms) or nil, {
      bytes = bytes and math.floor(bytes) or nil, chunk_count = chunk_count and math.floor(chunk_count) or nil,
      retry_count = retry_count and math.floor(retry_count) or nil,
      error = error_message and error_message:sub(1, 300) or nil, viewer_id = auth and auth.id or nil,
    })
  return 200, { ok = true }
end

-- ---------------------------------------------------------------------------
-- Media byte-serving: thumb / file / preview / download / avatar.
-- Mirrors app/routers/media_streaming.py. See media_files.lua's module
-- docstring for why ffmpeg (not a PIL-equivalent) renders every thumbnail/
-- preview here. STORAGE MODEL: current live media_items all resolve via the
-- on-disk content-addressed tree under uploads_dir/media/ (save_media_file_
-- to_disk) -- the DB-blob path (media_files/media_file_chunks) that used to
-- be what was actually configured is now legacy/empty for every current
-- row, kept only as a fallback resolve_media_bytes still checks.
--
-- RESOLVED (was flagged here as a known limitation): serve_media_bytes_
-- response now has a Range-aware fast path (range_io.* + the "seek-and-read
-- just the requested byte range" block near its top) that reads directly
-- from the on-disk _original_cache file via seek + a bounded read, instead
-- of buffering the whole file into memory per request the way this comment
-- used to describe. Confirmed live: a Range request against a 454MB video
-- went from ~19-20s (whole-file read) to ~0.2-0.35s (seek-based) once the
-- cache is warm. Only the original cold-cache population (still a full
-- read, once) and the quality-transcode/HLS paths still work the old way.
-- ---------------------------------------------------------------------------

local function adult_file_allowed(req, media_id, access, viewer_id)
  if access and access ~= "" and access == gauth.media_access_token(M.settings.session_secret, media_id) then
    return true
  end
  return viewer_adult_allowed(viewer_id)
end

-- Same capability-token fallback as adult_file_allowed, for private posts:
-- lets the post's own owner load it via a plain <img>/<video src> tag (no
-- cookie sent cross-origin) as long as the URL came from a `with_urls`
-- response their own session was already allowed to see.
local function private_file_allowed(media_id, access, owner)
  if owner then return true end
  return access ~= nil and access ~= "" and access == gauth.media_access_token(M.settings.session_secret, media_id)
end

-- Disk cache for resolve_media_bytes' DB-blob branch, same convention as
-- _thumb_cache/_video_cache/_watermark_cache/_hls_cache. Every other byte-
-- serving path in this file caches its OWN derived output (a resize, a
-- transcode, a watermark) but nothing ever cached the raw resolved
-- original -- so every single call to resolve_media_bytes() re-ran
-- media_files.get_media_file()'s full `SELECT ... content bytea` (plus, for
-- any chunked upload, a second query and a table.concat over every chunk)
-- straight from Postgres. That's the ONE thing on the request path that
-- genuinely can't be avoided for a cache MISS, but respond_with_range's
-- caller (serve_media_bytes_response) re-hits it on every request -- and a
-- <video> element issues many Range requests per playback (an initial probe
-- plus one per seek/buffer refill), each previously re-running this same
-- multi-hundred-MB blob fetch from scratch. Confirmed live: this is what
-- made a single video "take a while" to start (the first byte doesn't ship
-- until the whole blob round-trips from Postgres into a Lua string) and
-- made an unrelated concurrent request stall too, for the same reason
-- flagged in ensure_video_quality_cache's header comment -- the fetch runs
-- inline on copas' single-threaded loop, so a large blob read blocks
-- everyone else's request handling for its own duration, and a page
-- refresh (the <video> tag re-requesting the same file) reliably
-- re-triggered it. Keying the cache filename by media_id + updated_at (no
-- extra content_sha256 query -- the whole point is avoiding an extra DB
-- round trip on the hot path) means an edit that changes updated_at simply
-- misses once and re-populates, same self-correcting behavior already
-- documented for the video-quality/HLS caches below.
local function original_bytes_cache_path(media_id, item)
  local digest_seed = tostring(item.updated_at or item.created_at or media_id)
  local key = sodium.sodium_bin2hex(sodium.crypto_hash_sha256(digest_seed)):sub(1, 16)
  local shard = string.format("%02x", db.toint(media_id, 0) % 256)
  return M.settings.uploads_dir .. "/_original_cache/" .. shard .. "/" .. tostring(media_id) .. "_" .. key .. ".bin"
end

-- Grouped into one table (rather than three top-level locals) purely to
-- stay under this file's 200-local-variable ceiling -- routes.lua is
-- already near it (Lua's own hard per-chunk limit), so a bare `local
-- function` per helper here was enough to push it over. `range_io.*` reads
-- exactly like three plain functions at every call site below.
local range_io = {}

-- Cheap size lookup (seek-to-end, no read) so the Range math below never
-- has to load a file's bytes just to learn how big it is.
function range_io.file_size(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local size = f:seek("end")
  f:close()
  return size
end

-- Reads only [start_byte, end_byte] (inclusive, 0-based) from a file on
-- disk via seek + a bounded read -- never materializes the rest of the
-- file. Companion to range_io.parse below: together these let a Range
-- request against an already-cached original touch only the bytes it
-- actually asked for, instead of resolve_media_bytes' cf:read("*a")
-- whole-file read.
function range_io.read_file_range(path, start_byte, end_byte)
  local f = io.open(path, "rb")
  if not f then return nil end
  if start_byte > 0 then f:seek("set", start_byte) end
  local data = f:read(end_byte - start_byte + 1)
  f:close()
  return data
end

-- Same Range-header parsing as respond_with_range below, but against a
-- known total size rather than an in-memory content string -- lets a
-- caller compute which bytes it actually needs to read BEFORE reading
-- anything. Returns (status, start_byte, end_byte, headers); status is 200
-- (no/ignored Range -- caller should serve the whole file), 206 (a real
-- satisfiable range), or 416 (unsatisfiable -- caller sends an empty body).
function range_io.parse(req, total, mime_type, extra_headers)
  local headers = { ["Content-Type"] = mime_type or "application/octet-stream", ["Accept-Ranges"] = "bytes" }
  for k, v in pairs(extra_headers or {}) do headers[k] = v end

  local range = req.headers and req.headers["range"]
  if not range then return 200, 0, total - 1, headers end

  local start_s, end_s = tostring(range):match("^bytes=(%d*)-(%d*)$")
  if not start_s or (start_s == "" and end_s == "") then
    return 200, 0, total - 1, headers
  end
  local start_byte, end_byte
  if start_s == "" then
    local suffix_len = tonumber(end_s) or 0
    start_byte = math.max(0, total - suffix_len)
    end_byte = total - 1
  else
    start_byte = tonumber(start_s) or 0
    end_byte = (end_s ~= "" and tonumber(end_s)) or (total - 1)
  end
  end_byte = math.min(end_byte, total - 1)
  if start_byte > end_byte or start_byte >= total then
    headers["Content-Range"] = "bytes */" .. total
    return 416, 0, -1, headers
  end

  headers["Content-Range"] = string.format("bytes %d-%d/%d", start_byte, end_byte, total)
  return 206, start_byte, end_byte, headers
end

-- Reads an open file handle in chunks, yielding to copas between them,
-- instead of one uninterruptible f:read("*a"). copas is single-threaded
-- (it's the same thread serving every other request), so a single blocking
-- read of a large file -- a cold multi-MB media file on the spinning
-- /mnt/fastssd disk is a real tens-to-hundreds-of-ms read -- stalls the
-- entire worker for all of it, not just the current request. Same pattern
-- already proven for HLS segments (see serve_hls_segment above).
--
-- Hung off M (not its own top-level local) because this file is already
-- sitting at LuaJIT's 200-local-per-function ceiling for its outer chunk --
-- one more top-level `local` here fails the whole module to load.
function M._read_file_chunked(f)
  local copas_ok, copas = pcall(require, "copas")
  local parts, n = {}, 0
  while true do
    local chunk = f:read(256 * 1024)
    if not chunk or chunk == "" then break end
    n = n + 1
    parts[n] = chunk
    if copas_ok then copas.sleep(0) end
  end
  return table.concat(parts)
end

-- Resolves what to actually serve for a media item: DB blob (preferred) or
-- legacy on-disk file. Returns (content_bytes, mime_type) or (nil, nil) if
-- genuinely missing -- callers must 404 cleanly on the latter, not crash
-- (this is the common case for the current, April-29-restored dataset: see
-- media_files.lua's docstring -- media_files is empty for all 540 rows).
local function resolve_media_bytes(item)
  local cache_path = item.id and original_bytes_cache_path(item.id, item)
  if cache_path then
    local cf = io.open(cache_path, "rb")
    if cf then
      local bytes = M._read_file_chunked(cf)
      cf:close()
      if bytes and #bytes > 0 then return bytes, item.mime_type, item.original_filename end
    end
  end

  local content, mime_type, original_filename
  local file_info = media_files.get_media_file_info(item.id)
  if file_info then
    local full = media_files.get_media_file(item.id)
    if full and full.content and #full.content > 0 then
      content, mime_type, original_filename = full.content, full.mime_type or item.mime_type, full.original_filename or item.original_filename
    end
  end
  if not content then
    local legacy = media_files.legacy_upload_path(M.settings.uploads_dir, item.storage_path)
    if legacy then
      local f = io.open(legacy, "rb")
      if f then
        content = M._read_file_chunked(f)
        f:close()
        mime_type, original_filename = item.mime_type, item.original_filename
      end
    end
  end

  if content and cache_path then
    os.execute("mkdir -p " .. shell_quote(cache_path:match("^(.*)/[^/]+$")))
    local out = io.open(cache_path, "wb")
    if out then out:write(content); out:close() end
  end

  return content, mime_type, original_filename
end

-- Shared by the file/preview/thumb image routes below. Previously only
-- serve_media_bytes_response (the ?quality=original "High Quality" /file
-- endpoint) applied a watermark, so it only ever showed up there --
-- serve_media_preview and serve_media_thumb (what viewers actually see in
-- the grid and lightbox the vast majority of the time) rendered straight
-- from the unwatermarked original bytes. Caches the watermarked ORIGINAL
-- (keyed by media_id + hash of the current watermark text), so callers
-- that then resize/re-encode it (render_webp_from_bytes for
-- previews/thumbs) all inherit the watermark for free instead of each
-- needing its own cache.
-- ---------------------------------------------------------------------------
-- Image renditions (2026-10-26): render from the file on disk, cache
-- previews, pre-render the sizes the site actually asks for.
-- (Hung off M -- this file is at LuaJIT's 200-local ceiling.)
-- ---------------------------------------------------------------------------

-- Standard sizes the frontend requests: grid cards (640), lightbox (1280),
-- detail page preview (size=detail -> 1920 @ q92). Rendered together by the
-- warmer so a post is fast everywhere before anyone opens it.
M._GRID_THUMB_WIDTH = 640
M._LIGHTBOX_THUMB_WIDTH = 1280
M._PREVIEW_SIZES = { mini = { 360, 78 }, card = { 880, 86 }, detail = { 1920, 92 } }

-- A path ffmpeg can read the original from without Lua loading the bytes:
-- the original-bytes cache file if present, else the upload on disk.
function M._image_source_path(item)
  local cache_path = item.id and original_bytes_cache_path(item.id, item)
  if cache_path then
    local f = io.open(cache_path, "rb")
    if f then
      local size = f:seek("end")
      f:close()
      if size and size > 0 then return cache_path end
    end
  end
  return media_files.legacy_upload_path(M.settings.uploads_dir, item.storage_path)
end

-- Slim row for the byte-serving image routes (thumb/preview). They only
-- need access-control and file-location columns; fetch_media_by_id also
-- computes like/comment/bookmark counts and subcategories (~7ms per call,
-- i.e. ~0.4s of DB work per page of 48 thumbnails).
function M._fetch_media_for_bytes(media_id)
  return db.fetchone([[
    SELECT m.id, m.user_id, m.media_kind, m.mime_type, m.original_filename, m.storage_path,
           m.file_size, m.created_at, m.updated_at, m.visibility, m.is_adult,
           m.youtube_video_id, m.deleted_at, m.expires_at, m.content_sha256
    FROM media_items m
    JOIN users u ON u.id = m.user_id
    WHERE m.id = %s
  ]], tostring(media_id))
end

function M._image_thumb_cache_path(media_id, width)
  return M.settings.uploads_dir .. "/_thumb_cache/" .. media_id .. "_" .. width .. ".webp"
end

-- Versioned by updated_at (same idiom as original_bytes_cache_path), so an
-- edited post gets a fresh preview instead of a stale cached one.
function M._preview_cache_path(media_id, item, size)
  local digest_seed = tostring(item.updated_at or item.created_at or media_id)
  local key = sodium.sodium_bin2hex(sodium.crypto_hash_sha256(digest_seed)):sub(1, 12)
  local shard = string.format("%02x", db.toint(media_id, 0) % 256)
  return M.settings.uploads_dir .. "/_preview_cache/" .. shard .. "/" .. tostring(media_id) .. "_" .. size .. "_" .. key .. ".webp"
end

-- Shared cache headers for thumbs/previews. Public, non-adult, non-expiring
-- posts may be cached by Cloudflare's edge (their URLs end in .webp, see
-- with_urls); everything else is browser-only ("private").
function M._image_cache_control(item, max_age)
  local shareable = item.visibility == "public" and not item.is_adult and not nn(item.expires_at)
  return (shareable and "public" or "private") .. ", max-age=" .. tostring(max_age or 604800) .. ", immutable"
end

function M._read_whole_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local bytes = M._read_file_chunked(f)
  f:close()
  if bytes == "" then return nil end
  return bytes
end

function M._write_file_atomic(path, bytes)
  local dir = path:match("^(.*)/[^/]+$")
  if dir then os.execute("mkdir -p " .. shell_quote(dir)) end
  local tmp = path .. ".part" .. tostring(math.random(100000, 999999))
  local out = io.open(tmp, "wb")
  if not out then return false end
  out:write(bytes)
  out:close()
  return os.rename(tmp, path) and true or false
end

local function apply_image_watermark_if_configured(media_id, item, content, mime_type)
  if item.media_kind ~= "image" then return content end
  local watermark_text = nil -- WATERMARKS_ENABLED = false (get_user lookup for it removed too)
  if not watermark_text or watermark_text == "" then return content end

  local cache_key = sodium.sodium_bin2hex(sodium.crypto_hash_sha256(watermark_text)):sub(1, 16)
  local cache_dir = M.settings.uploads_dir .. "/_watermark_cache"
  local cache_path = cache_dir .. "/" .. tostring(media_id) .. "_" .. cache_key
  local cf = io.open(cache_path, "rb")
  if cf then
    local cached = cf:read("*a")
    cf:close()
    return cached
  end

  local watermarked = media_files.apply_watermark(content, mime_type, watermark_text)
  if watermarked then
    os.execute("mkdir -p " .. shell_quote(cache_dir))
    local out = io.open(cache_path, "wb")
    if out then
      out:write(watermarked)
      out:close()
    end
    return watermarked
  end
  return content
end

-- Deliberately a bare global, not `local function` -- M.upload_media's
-- finalize_upload (much earlier in this file) calls this, and Lua locals
-- are only visible from their declaration point onward in source order, so
-- a caller positioned earlier in the chunk can't see a later `local
-- function` no matter when it actually runs. Same forward-reference
-- problem (and the same fix) as acquire_transcode_slot/
-- fast_start_remux_if_needed elsewhere in this file -- also frees one slot
-- against this file's 200-top-level-local ceiling instead of costing one.
--
-- Pre-renders a freshly uploaded video's default grid-width (520px)
-- thumbnail right after upload instead of waiting for the first viewer to
-- hit M.serve_media_thumb's cache-miss path below. Confirmed live
-- 2026-10-11 auditing media loading: the FIRST person to ever see a given
-- video's thumbnail is normally the uploader themselves, on their own
-- profile/feed, moments after uploading -- previously always the
-- placeholder SVG, even though the real render was already launching in
-- the background by then anyway. Shifting that same render earlier (upload
-- time instead of first-view time) means it's simply done by the time
-- anyone looks.
--
-- Deliberately reuses M.serve_media_thumb's exact cache path, .pending
-- marker convention, and acquire_transcode_slot concurrency cap rather
-- than inventing a second mechanism -- a viewer's request a moment later
-- just finds the cache file (or an in-flight marker) already there, same
-- as it always has. Called via copas.addthread from M.upload_media's
-- finalize_upload (fire-and-forget, same contract as notify_discord_upload
-- -- a busy transcode cap or a render failure here must never surface to
-- the uploader; the existing lazy on-demand path remains the fallback
-- exactly as it already was before this existed).
prewarm_video_thumb = function(media_id, item)
  local ok, err = pcall(function()
    local width = 520
    local shard = string.format("%02x", media_id % 256)
    local cache_path = M.settings.uploads_dir .. "/_thumb_cache/" .. shard .. "/" .. media_id .. "_" .. width .. ".webp"
    local cache_dir = cache_path:match("^(.*)/[^/]+$")
    os.execute("mkdir -p " .. shell_quote(cache_dir))

    -- Mirrors M.serve_media_thumb's claim_thumb_job/cache-hit checks: bail
    -- quietly if a render is already in flight (shouldn't happen this soon
    -- after upload, but costs nothing to check) or somehow already cached.
    local existing_marker = io.open(cache_path .. ".pending", "rb")
    if existing_marker then existing_marker:close() return end
    local cf = io.open(cache_path, "rb")
    if cf then cf:close() return end

    -- A YouTube source link wins over the frame-grab -- same precedence
    -- M.serve_media_thumb's lazy path already gives it. Without this check,
    -- this prewarm would win the race against that lazy path every time
    -- (it runs right at upload, long before any viewer's first GET), caching
    -- the wrong (frame-grabbed) thumbnail permanently -- serve_media_thumb's
    -- cache-hit check short-circuits before ever reaching its own YouTube
    -- branch. Fetches the real YouTube thumbnail here instead of skipping
    -- outright, so the uploader still sees it warm immediately like every
    -- other video, rather than falling back to the lazy on-first-view path.
    if item.youtube_video_id and item.youtube_video_id ~= cjson.null and nn(item.youtube_video_id) then
      local slot_path = acquire_transcode_slot()
      if not slot_path then return end
      local marker = cache_path .. ".pending"
      local out = io.open(marker, "wb")
      if out then out:write(tostring(os.time())); out:close() end
      local youtube_thumb = require("youtube_thumb")
      local ok2, bytes = pcall(youtube_thumb.fetch_best_thumbnail_bytes, item.youtube_video_id)
      local rendered = ok2 and bytes and media_files.render_webp_from_bytes(bytes, width, 84, nil)
      if rendered then
        local out2 = io.open(cache_path, "wb")
        if out2 then out2:write(rendered); out2:close() end
      end
      os.remove(marker)
      os.execute("rm -f " .. shell_quote(slot_path))
      return
    end

    local slot_path = acquire_transcode_slot()
    if not slot_path then return end -- box busy right now; the lazy path still covers this video

    local marker = cache_path .. ".pending"
    local out = io.open(marker, "wb")
    if out then out:write(tostring(os.time())); out:close() end

    -- ffmpeg reads the stored file directly. (This used to load the whole
    -- video into Lua memory via resolve_media_bytes and write a second
    -- full copy to _original_cache just to grab one frame -- hundreds of
    -- MB of GC heap and disk writes per upload.)
    local src_path = M._image_source_path(item)
    if not src_path then
      local content = resolve_media_bytes(item)
      if not content then
        os.remove(marker)
        os.execute("rm -f " .. shell_quote(slot_path))
        return
      end
      src_path = original_bytes_cache_path(media_id, item)
    end
    local tmp_dst = cache_path .. ".tmp.webp"
    local render_cmd = media_files.render_webp_scene_aware_cmd(src_path, tmp_dst, width, 84, 0.35)
    os.execute(string.format(
      "( %s; if [ -s %s ]; then mv -f %s %s; fi; rm -f %s %s ) >/dev/null 2>&1 &",
      render_cmd, shell_quote(tmp_dst), shell_quote(tmp_dst), shell_quote(cache_path), shell_quote(marker), shell_quote(slot_path)
    ))
  end)
  if not ok then
    print("[nyxframe] prewarm_video_thumb error (media " .. tostring(media_id) .. "): " .. tostring(err))
  end
end

-- One-shot startup backfill, 2026-10-11: prewarm_video_thumb only ever
-- covers videos uploaded AFTER it existed -- every video uploaded earlier
-- still takes the old lazy path, i.e. sits unthumbnailed until a viewer's
-- GET .../thumb happens to miss. The live incident that prompted this
-- (both workers stalling 20-100s on trivial endpoints) was exactly a
-- viewer scrolling into a run of those pre-existing, never-thumbnailed
-- videos at once -- a burst of cache misses each paying resolve_media_bytes'
-- full blocking blob-fetch cost back to back. serve_media_thumb's miss path
-- is now backgrounded (see its video branch above) so a live miss burst no
-- longer stalls the RESPONSE, but the backlog of never-viewed videos is
-- still sitting there waiting to cause the next burst whenever someone
-- scrolls into them. This walks that backlog itself, one video at a time
-- with a deliberate gap between each (THUMB_BACKFILL_DELAY_SECONDS) so the
-- backfill never reintroduces the very burst pattern it exists to drain --
-- a single resolve_media_bytes call every few seconds is a brief, isolated
-- stall on whichever worker runs it, not a pile-up. Idempotent (skips
-- anything already cached or already in flight via prewarm_video_thumb's
-- own marker/cache checks) and safe to run on every startup: once the
-- backlog is drained it just scans and finds nothing left to do.
--
-- No top-level `local` for the 4-second delay below -- routes.lua is
-- already at LuaJIT's 200-local-per-chunk ceiling (see
-- original_bytes_cache_path's neighboring comment), so this stays an
-- inline literal instead of costing one more slot.
function M.start_thumb_backfill_sweep()
  local copas = require("copas")
  copas.addthread(function()
    local function thumb_cached(media_id)
      local shard = string.format("%02x", media_id % 256)
      local path = M.settings.uploads_dir .. "/_thumb_cache/" .. shard .. "/" .. media_id .. "_520.webp"
      local f = io.open(path, "rb")
      if f then f:close() return true end
      return false
    end

    local rows, err = db.fetchall([[
      SELECT id, updated_at, created_at, mime_type, original_filename, storage_path
      FROM media_items
      WHERE media_kind = 'video' AND deleted_at IS NULL
      ORDER BY id
    ]])
    if err then
      print("[nyxframe] thumb_backfill_sweep: could not list videos: " .. tostring(err))
      return
    end

    local queued, skipped = 0, 0
    for _, row in ipairs(rows) do
      local media_id = db.toint(row.id, row.id)
      if thumb_cached(media_id) then
        skipped = skipped + 1
      else
        local item = {
          id = media_id, updated_at = row.updated_at, created_at = row.created_at,
          mime_type = row.mime_type, original_filename = row.original_filename, storage_path = row.storage_path,
        }
        local ok, perr = pcall(prewarm_video_thumb, media_id, item)
        if not ok then
          print("[nyxframe] thumb_backfill_sweep: prewarm failed for media " .. tostring(media_id) .. ": " .. tostring(perr))
        end
        queued = queued + 1
        copas.sleep(4)
      end
    end
    print(string.format(
      "[nyxframe] thumb_backfill_sweep: done -- queued %d, already cached %d, total %d",
      queued, skipped, #rows
    ))
  end)
end

function M.serve_media_thumb(req)
  -- Claims the right to launch a backgrounded thumbnail-render job: writes
  -- `marker_path` with the current epoch and returns true, unless a fresh
  -- (<120s old) marker is already there (another request's job is in
  -- flight), in which case it returns false and does nothing. Mirrors
  -- video_extras.lua's claim_job; declared as a local *inside* this
  -- function rather than at file scope because routes.lua is already at
  -- LuaJIT's 200-local-per-chunk ceiling for the main chunk (see
  -- original_bytes_cache_path's neighboring range_io comment) -- a nested
  -- function's locals get their own separate budget.
  local function claim_thumb_job(marker_path)
    local existing = io.open(marker_path, "rb")
    if existing then
      local claimed_at = tonumber(existing:read("*a") or "")
      existing:close()
      if claimed_at and (os.time() - claimed_at) < 120 then
        return false
      end
    end
    local out = io.open(marker_path, "wb")
    if not out then return false end
    out:write(tostring(os.time()))
    out:close()
    return true
  end

  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local item = M._fetch_media_for_bytes(media_id)
  if not item then return 404, { detail = "Media not found." } end
  item.is_adult = db.tobool(item.is_adult)
  local owner = viewer_id and tostring(item.user_id) == tostring(viewer_id)
  if item.visibility == "private" and not private_file_allowed(media_id, req.query.access, owner) then
    return 403, { detail = "This post is private." }
  end
  if item.is_adult and not adult_file_allowed(req, media_id, req.query.access, viewer_id) then
    return 403, { detail = "Age verification required for this 18+ post." }
  end

  local width = math.max(160, math.min(tonumber(req.query.w) or 520, 1440))
  local shard = string.format("%02x", media_id % 256)
  local media_kind = tostring(item.media_kind or ""):lower()

  -- Cache lookup: images cache flat (matches the ~364 pre-existing cache
  -- files under uploads/_thumb_cache/ from before the restore), videos cache
  -- sharded -- see _video_thumb_cache_file's identical convention in Python.
  local flat_path = M.settings.uploads_dir .. "/_thumb_cache/" .. media_id .. "_" .. width .. ".webp"
  local shard_path = M.settings.uploads_dir .. "/_thumb_cache/" .. shard .. "/" .. media_id .. "_" .. width .. ".webp"
  local cache_path = media_kind == "video" and shard_path or flat_path
  local cf = io.open(cache_path, "rb")
  if cf then
    local bytes = M._read_file_chunked(cf)
    cf:close()
    return 200, bytes, { ["Content-Type"] = "image/webp", ["Cache-Control"] = M._image_cache_control(item) }
  end

  -- YouTube source-link override takes precedence over BOTH the video and
  -- image default-render paths below -- an uploader who linked a YouTube
  -- video wants THAT video's thumbnail, not a frame grabbed from their own
  -- re-upload or the raw image bytes. Backgrounded same as the video branch
  -- below rather than fetched inline: an outbound GET to img.youtube.com
  -- has far less predictable latency than a local ffmpeg call, so blocking
  -- this worker's event loop on it would be worse, not better. Shares
  -- claim_thumb_job's marker and acquire_transcode_slot's cap with every
  -- other backgrounded thumbnail job for the same reason those already do:
  -- one proven concurrency ceiling, not a new one per feature.
  if item.youtube_video_id and item.youtube_video_id ~= cjson.null and nn(item.youtube_video_id) then
    local marker = cache_path .. ".pending"
    local cache_dir = cache_path:match("^(.*)/[^/]+$")
    os.execute("mkdir -p " .. shell_quote(cache_dir))
    local copas = require("copas")
    copas.addthread(function()
      if not claim_thumb_job(marker) then return end
      local slot_path = acquire_transcode_slot()
      if not slot_path then
        os.remove(marker)
        return
      end
      local youtube_thumb = require("youtube_thumb")
      local ok, bytes = pcall(youtube_thumb.fetch_best_thumbnail_bytes, item.youtube_video_id)
      local rendered = ok and bytes and media_files.render_webp_from_bytes(bytes, width, 84, nil)
      if rendered then
        local out = io.open(cache_path, "wb")
        if out then out:write(rendered); out:close() end
      else
        print("[nyxframe] youtube thumbnail override failed (media " .. tostring(media_id) .. "): " .. tostring(bytes))
      end
      os.remove(marker)
      os.execute("rm -f " .. shell_quote(slot_path))
    end)
    local svg = media_files.video_placeholder_svg(width)
    return 200, svg, { ["Content-Type"] = "image/svg+xml", ["Cache-Control"] = "public, max-age=20" }
  end

  if media_kind == "video" then
    -- Rendering a video thumb means loading the whole source and having
    -- ffmpeg seek/decode into it -- multi-second on a large upload, and
    -- that blocks copas' single event loop for every OTHER concurrent
    -- request on this worker meanwhile (see media_files.lua's header
    -- comment). A burst of misses against never-before-viewed videos (a
    -- bulk import, a cache purge) would otherwise stall the whole worker
    -- one video at a time. So this backgrounds the render instead of
    -- calling it inline: claim a job marker, resolve+persist the source
    -- once, launch ffmpeg detached, and return the same placeholder SVG
    -- already used for the "couldn't render" case immediately. The real
    -- thumbnail takes over on whichever later request finds the cache file
    -- in place -- same contract the frontend already handles today.
    local marker = cache_path .. ".pending"
    local cache_dir = cache_path:match("^(.*)/[^/]+$")
    -- Must exist before claim_thumb_job's io.open(marker, "wb") below --
    -- a never-before-rendered shard directory doesn't exist yet, which
    -- would otherwise make the marker write fail, claim_thumb_job return
    -- false, and the render job silently never launch at all. Cheap
    -- (mkdir -p on an existing dir is near-instant), unlike the blob fetch
    -- below, so this alone stays inline.
    os.execute("mkdir -p " .. shell_quote(cache_dir))
    -- Everything past this point used to run inline here, including
    -- resolve_media_bytes(item) -- which for a never-before-viewed video
    -- means pulling the full original (DB blob or disk file, easily
    -- hundreds of MB) into memory and persisting it to the original-bytes
    -- cache. That's pure I/O/memory work, not spawned-and-detached like
    -- the ffmpeg call beneath it, so it was blocking copas' single event
    -- loop for this ENTIRE worker for however long that fetch took --
    -- seconds normally, tens of seconds whenever the box is under memory
    -- pressure (see 2026-10-11's RAM audit: this box runs at ~98% RAM
    -- committed against 7GB total even right after boot). A gallery grid
    -- with a cluster of never-cached videos fired this inline on every one
    -- of them in a burst, and each blocked EVERY other request on that
    -- worker -- not just other thumbs, /api/me and /api/health too --
    -- which is exactly the symmetric 20-100s stalls across unrelated
    -- endpoints seen in both workers' access logs that afternoon. Moving
    -- the whole claim+slot+fetch+render sequence into a copas.addthread
    -- (same mechanism prewarm_video_thumb above already uses for the
    -- upload-time case) means this handler now does nothing but schedule
    -- the work and return the placeholder immediately, same as the
    -- already-backgrounded ffmpeg step. claim_thumb_job's own marker check
    -- still makes concurrent requests for the same video safe -- it just
    -- runs a tick later now instead of synchronously.
    local copas = require("copas")
    copas.addthread(function()
      if not claim_thumb_job(marker) then return end
      -- Draws from the SAME global ffmpeg concurrency cap video transcoding
      -- uses (acquire_transcode_slot/transcode.max_concurrent, benchmarked
      -- against this box's actual hardware -- see that table's header
      -- comment), rather than its own separate budget that would simply
      -- ADD to total concurrent ffmpeg load instead of sharing a ceiling
      -- already proven safe. This host has gone down once before
      -- (2026-08-26) from unbounded parallel ffmpeg jobs spawned with no
      -- cap at all -- a burst of thumbnail cache misses (bulk import,
      -- cache purge, several viewers opening never-seen videos at once)
      -- is exactly that failure shape, just for a different job type.
      local slot_path = acquire_transcode_slot()
      if slot_path then
        local content = resolve_media_bytes(item)
        if content then
          local src_path = original_bytes_cache_path(media_id, item)
          local tmp_dst = cache_path .. ".tmp.webp"
          local render_cmd = media_files.render_webp_scene_aware_cmd(src_path, tmp_dst, width, 84, 0.35)
          os.execute(string.format(
            "( %s; if [ -s %s ]; then mv -f %s %s; fi; rm -f %s %s ) >/dev/null 2>&1 &",
            render_cmd, shell_quote(tmp_dst), shell_quote(tmp_dst), shell_quote(cache_path), shell_quote(marker), shell_quote(slot_path)
          ))
        else
          os.remove(marker)
          os.execute("rm -f " .. shell_quote(slot_path))
        end
      else
        -- Every slot is held by a still-running job right now. Release the
        -- thumb marker immediately rather than letting it sit claimed for
        -- nothing until its 120s staleness window expires -- no job
        -- actually started, so the very next request should be free to
        -- try again right away, same "degrades gracefully, don't queue"
        -- philosophy the transcode cap itself already uses.
        os.remove(marker)
      end
    end)
    local svg = media_files.video_placeholder_svg(width)
    -- Short, non-immutable cache: unlike the permanent "couldn't render"
    -- case this used to be the only user of, this placeholder can also mean
    -- "rendering right now" -- a week-long immutable cache would otherwise
    -- freeze a fresh upload's thumbnail as a placeholder for a week even
    -- after the real render finishes seconds later.
    return 200, svg, { ["Content-Type"] = "image/svg+xml", ["Cache-Control"] = "public, max-age=20" }
  end

  -- Images only below: a small-image webp encode is cheap (tens of ms), so
  -- this stays synchronous -- see media_files.lua's header comment.
  -- Render straight from the original on disk when we can (2026-10-26):
  -- skips loading a 4-15MB original into Lua and writing a temp copy of it.
  -- (Watermarking is disabled, so the bytes path below adds nothing then.)
  local src_path = M._image_source_path(item)
  local rendered = src_path and media_files.render_webp_bytes_from_path(src_path, width, 84) or nil
  if not rendered then
    local content = resolve_media_bytes(item)
    if content then
      content = apply_image_watermark_if_configured(media_id, item, content, item.mime_type)
      rendered = media_files.render_webp_from_bytes(content, width, 84, nil)
    end
  end
  if rendered then
    M._write_file_atomic(cache_path, rendered)
    return 200, rendered, { ["Content-Type"] = "image/webp", ["Cache-Control"] = M._image_cache_control(item) }
  end
  return 404, { detail = "File missing from database." }
end

-- ---------------------------------------------------------------------------
-- Video quality-variant transcoding (?quality=720p on GET .../file). Mirrors
-- app/routers/media_streaming.py's VIDEO_QUALITY_PROFILES/
-- _normalize_video_quality/_ensure_video_quality_cache, with one deliberate
-- simplification: Python streams the ffmpeg transcode to the client while
-- simultaneously writing the cache file (so playback starts within ~1s), and
-- dedups concurrent transcodes of the same (media_id, quality) via an
-- in-memory active-streams set. This backend already loads full DB-blob
-- content into memory and blocks copas' single-threaded event loop for the
-- duration of any ffmpeg call (see media_files.lua's render_webp -- same
-- accepted tradeoff, not new here), so a "transcode fully, then serve"
-- approach is consistent with the rest of this file: no partial-progress
-- streaming, and no dedup (two concurrent first-requests for the same
-- quality will transcode twice -- rare, self-correcting once the cache
-- file exists, and not worth an in-memory coordination table for this
-- deployment's traffic level).
-- ---------------------------------------------------------------------------

-- vaapi_ceiling_bps: only used on the h264_vaapi path (see ensure_hls_variant
-- below) as QVBR's required -b:v/-maxrate ceiling -- global_quality (reusing
-- this same table's crf value, which happens to sit on the same rough 0-51
-- QP-like scale as x264's crf) is what actually drives quality/size there,
-- this is just a generous cap against pathologically complex content, not
-- the primary quality lever the way it would be for a CPU CBR/VBR encode.
local VIDEO_QUALITY_PROFILES = {
  ["1080p"] = { max_width = 1920, crf = 22, audio_bitrate = "320k", preset = "fast", profile = "high", vaapi_ceiling_bps = 8000000 },
  ["720p"]  = { max_width = 1280, crf = 25, audio_bitrate = "256k", preset = "fast", profile = "high", vaapi_ceiling_bps = 5000000 },
  ["480p"]  = { max_width = 854,  crf = 28, audio_bitrate = "192k", preset = "fast", profile = "high", vaapi_ceiling_bps = 2500000 },
  ["144p"]  = { max_width = 256,  crf = 36, audio_bitrate = "64k",  preset = "ultrafast", profile = "baseline", vaapi_ceiling_bps = 400000 },
}
local VIDEO_TRANSCODE_SIZE_LIMIT = 500 * 1024 * 1024

local function ffprobe_bin()
  return os.getenv("GALLERY_FFPROBE_BIN") or "ffprobe"
end

-- Reads the source video's pixel width via ffprobe, or nil if the probe
-- fails for any reason (corrupt/unusual container -- callers must fall
-- back to the old downscale-only behavior in that case, not crash).
local function probe_video_width(path)
  local probe = io.popen(string.format(
    "%s -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 %s 2>/dev/null",
    ffprobe_bin(), shell_quote(path)
  ))
  if not probe then return nil end
  local line = probe:read("*l")
  probe:close()
  return tonumber(line)
end

-- Builds the -vf scale filter for one quality-profile transcode. A plain
-- `scale='min(max_width,iw)'` (the old behavior) never grows the frame --
-- picking "1080p" on a phone upload that's actually 480p produced a file
-- labeled 1080p with zero visual improvement, just wasted encode time.
-- When the source is genuinely smaller than the requested rendition, scale
-- up to it for real and follow with a mild unsharp pass, since a bare
-- upscale by itself only produces a softer copy of the same pixels --
-- unsharp is what makes the extra resolution actually look sharper instead
-- of just blurrier-but-bigger. Downscaling (the common case) keeps the
-- original lanczos-only behavior unchanged.
local function video_scale_filter(src_path, max_width)
  local source_width = probe_video_width(src_path)
  if source_width and source_width > 0 and source_width < max_width then
    return string.format("scale=%d:-2:flags=lanczos,unsharp=5:5:0.8:5:5:0.0", max_width)
  end
  return string.format("scale='min(%d,iw)':-2:flags=lanczos", max_width)
end

local function normalize_video_quality(value)
  local quality = tostring(value or "high"):lower()
  local legacy = { medium = "720p", low = "480p", high = "original", original = "original" }
  quality = legacy[quality] or quality
  if quality == "original" or VIDEO_QUALITY_PROFILES[quality] then return quality end
  return "original"
end

local function video_quality_cache_path(media_id, quality, digest_seed)
  local key = sodium.sodium_bin2hex(sodium.crypto_hash_sha256(tostring(digest_seed))):sub(1, 16)
  return M.settings.uploads_dir .. "/_video_cache/" .. tostring(media_id) .. "_" .. quality .. "_" .. key .. ".mp4"
end

-- Used everywhere a "is this job actually dead, or just still running" call
-- has to be made: the global concurrency slot count, and each function's
-- own per-(media,quality) pending marker. All four uses are the same
-- underlying question, so one constant, not per-callsite guesses.
--
-- 2026-08-31: raised from 5 minutes -- confirmed live, right after
-- re-enabling the media warmer, that 5 minutes is too short: a slot file's
-- mtime is never refreshed while its job runs, so ANY job that legitimately
-- takes longer than 5 minutes gets its OWN slot reclaimed and handed to a
-- new job while the original is still running. Caught a 1080p QVBR encode
-- still running at 5m25s having its slot reused, producing 3 concurrent
-- real ffmpeg processes against a cap of 2 -- and since 2-3 concurrent
-- VAAPI sessions already measurably slow each other down on this box's
-- hardware (confirmed earlier: ~64% overhead for just 2 concurrent jobs),
-- every extra job piling on this way makes the others run longer too,
-- which reclaims more slots, which piles on more jobs -- an
-- unbounded-growth spiral, not a one-off blip. 30 minutes is comfortably
-- clear of the longest real encode observed so far (~10 minutes, CPU path,
-- heavy contention) while still reclaiming a slot from something actually
-- crashed in a reasonable time.
local VIDEO_TRANSCODE_PENDING_STALE_SECONDS = 30 * 60

-- Global cap on concurrently-running detached ffmpeg transcodes, shared by
-- both ensure_video_quality_cache below and ensure_hls_variant further
-- down. Confirmed live (2026-08-23): with no cap, a burst of cold-cache
-- requests -- several distinct videos with no ready transcode yet, e.g.
-- right after a backend restart orphans whatever was mid-encode -- each
-- launched their own full libx264 job simultaneously. nice -n 19/ionice
-- only lower scheduling PRIORITY, not a hard core reservation, so 2-3
-- concurrent encodes on an 8-core box still starved the request-serving
-- worker processes badly enough that even trivial endpoints (GET /api/me)
-- timed out for real users. Filesystem-based (one file per running job
-- under _transcode_slots/), same convention as the .pending markers below
-- -- correct across a restart AND across this backend's multiple worker
-- processes (an in-memory counter would only ever see its own process'
-- jobs, not the other worker's).
--
-- Degrades gracefully rather than queuing: a request that can't get a slot
-- just doesn't launch a job this time, exactly like the existing
-- "transcode isn't ready yet" cache-miss path already does (serve the
-- original / 404 "not available yet", per caller) -- no new coordination
-- machinery, consistent with this file's existing tolerance for "rare,
-- self-correcting" over building a real queue for this deployment's
-- traffic level.
--
-- RECONSIDERED 2026-08-31 after ensure_hls_variant moved decode onto the
-- GPU too (see that function's own comment) -- asked directly "since it's
-- GPU now, can this go up?" and checked with real concurrent-job
-- benchmarks rather than guessing: on this box's VAAPI/VCN hardware,
-- aggregate transcode throughput measured HIGHEST at 2 concurrent jobs
-- (3.8 source-seconds of video processed per wall-clock second) and
-- WORSE at 3 (2.78/s -- barely above what a single job alone achieves).
-- The video engine itself is a single shared hardware block; pushing more
-- concurrent sessions through it doesn't add capacity; it just makes every
-- session wait on the others, so 3+ jobs spend more time contending than
-- they gain from parallelism. This isn't the same CPU-starvation concern
-- the 2026-08-23 finding above was about (this box's CPU cores now sit
-- mostly idle during a transcode, confirmed via `top` while running
-- concurrent jobs) -- it's the GPU's own ceiling. 2 is not an arbitrary
-- safety margin left over from the CPU era; it's this hardware's actual
-- capacity, re-confirmed under the new pipeline, not the old one. Raise
-- this only after re-benchmarking on whatever GPU is actually running it
-- (`ffmpeg -hwaccel vaapi ... &` two/three copies at once, watch
-- /sys/class/drm/card*/device/vcn_busy_percent and total wall-clock vs.
-- source duration, same method used here) -- don't just bump the number
-- because decode moved to the GPU.
--
-- (2026-09-01: this cap is now the `transcode.max_concurrent` field of the
-- table declared immediately below rather than its own top-level local --
-- see that table's own comment for why. Nothing about the value or the
-- reasoning above changed.)
-- ---------------------------------------------------------------------------
-- Transcode-pipeline state that isn't a plain constant: the media warmer's
-- restraint policy, plus two bits of shared slot bookkeeping.
--
-- ONE table rather than the several top-level locals this would otherwise
-- be, because this file's main chunk is at LuaJIT's hard 200-local ceiling
-- -- adding them as plain locals does not merely risk it, it fails to
-- compile at all (confirmed: "main function has more than 200 local
-- variables"). Same workaround, same reason, as range_io further up; every
-- field below reads like a plain local at its call sites. Declared here,
-- ahead of transcode_slots_dir, so all of it is in scope for the slot
-- helpers below as well as for ensure_hls_variant and the warmer itself;
-- the function-valued fields are attached at the points further down where
-- what they call is in scope.
--
-- 2026-09-01: the warmer was still measurably slowing the rest of the site
-- even after the 2026-08-31 round of fixes, so everything that governs how
-- hard it pushes got tightened at once. Four independent brakes, in the
-- order a warming pass hits them:
--
--   1. jobs_max = 1 -- the warmer runs AT MOST ONE ffmpeg at a time, on its
--      own warm_N slot pool, claimed IN ADDITION TO (never instead of) the
--      shared transcode.max_concurrent budget. This is a warmer-only
--      ceiling: a real viewer's on-demand transcode still draws on the full
--      shared cap of 2 and is never throttled by the warmer's own restraint,
--      which is the same principle the 2026-08-31 load-guard comment below
--      already set out.
--   2. Warm only when the transcode pipeline is COMPLETELY idle -- zero
--      shared slots held, not merely one free. Together with (1) the warmer
--      can therefore hold at most 1 of the 2 shared slots, so a viewer
--      arriving mid-warm always finds a free slot instead of a 503 "busy";
--      previously the warmer could legitimately occupy both at once and
--      every cold-start viewer request in that window got turned away.
--   3. Warm only when NOBODY is watching -- any variant whose .last_watched
--      heartbeat (see M._touch_hls_heartbeat) is fresher than
--      watch_idle_seconds means a player is actively streaming right now, and
--      the warmer sits the pass out entirely rather than competing with it
--      for the GPU's single shared video block, for disk I/O, or for the
--      event loop. This is the brake that keeps live playback unaffected:
--      while someone is watching, the warmer does not merely run at lower
--      priority, it does not run.
--   4. Load guard at max_load, was a flat 8 -- i.e. exactly this box's core
--      count, so the warmer only backed off once the machine was ALREADY
--      saturated, far too late to avoid the lag it was itself causing. Half
--      the core count leaves actual headroom.
--
-- Every threshold is env-overridable so this can be retuned (or the warmer
-- effectively parked) on the live box without a code change and redeploy.
-- ---------------------------------------------------------------------------
local transcode = {
  -- The global concurrency cap. A field rather than the top-level local it
  -- used to be purely to free that local slot for this table -- see the
  -- 200-local note above; the long comment block preceding this table
  -- explains the value itself, and none of that reasoning changed.
  max_concurrent = 2,
  -- Set once per process by transcode_slots_dir below.
  slots_dir_made = false,
  warmer = {
    jobs_max = tonumber(os.getenv("GALLERY_WARMER_MAX_JOBS") or "") or 1,
    max_load = tonumber(os.getenv("GALLERY_WARMER_MAX_LOAD") or "") or 4,
    watch_idle_seconds = tonumber(os.getenv("GALLERY_WARMER_WATCH_IDLE_SECONDS") or "") or 120,
    -- How long a memoized "this variant is complete" answer is trusted
    -- before the warmer re-checks the filesystem for real -- see
    -- transcode.warmer.variant_ready below.
    revalidate_seconds = tonumber(os.getenv("GALLERY_WARMER_REVALIDATE_SECONDS") or "") or 1800,
    -- Memo of variant directories already confirmed complete, plus when it
    -- was last emptied.
    ready = {},
    ready_count = 0,
    ready_since = 0,
  },
}

-- 2026-09-01: the `mkdir -p` used to run on EVERY call -- and every call
-- fork/execs a whole shell out of this worker process, which (like all
-- os.execute/io.popen here) blocks copas' single-threaded loop that is also
-- serving live HTTP requests. Between the warmer's per-candidate capacity
-- peek and each viewer request's own claim, that was a steady drip of
-- pointless forks to create a directory that has existed since the first
-- one. Created once per process instead; if something deletes it out from
-- under us the next claim just fails and backs off, exactly like a full cap.
local function transcode_slots_dir()
  local dir = M.settings.uploads_dir .. "/_transcode_slots"
  if not transcode.slots_dir_made then
    os.execute("mkdir -p " .. shell_quote(dir))
    transcode.slots_dir_made = true
  end
  return dir
end

-- Claim time of one slot file, or nil if it isn't held at all.
--
-- 2026-09-01: slot files now CONTAIN their claim timestamp (written by the
-- same atomic noclobber redirect that creates them, see
-- acquire_transcode_slot) instead of carrying it only as an mtime that
-- nothing but `find -printf` could read. A plain io.open can answer "how old
-- is this claim" now, which is what lets both readers below run entirely
-- fork-free -- previously every capacity check spawned a shell AND a `find`,
-- blocking the request-serving event loop each time, and the warmer did that
-- on every candidate variant it considered. Slot names are fixed
-- (slot_1..slot_N / warm_1..warm_N) so there is nothing to enumerate.
--
-- An existing-but-empty file is the microsecond window between the shell
-- creating it and the write landing; report it as freshly claimed rather
-- than as stale, so a concurrent reader can never reclaim a slot out from
-- under the job that just won it.
transcode.slot_claimed_at = function(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local body = f:read("*a")
  f:close()
  return tonumber(body and body:match("^%s*(%d+)")) or os.time()
end

-- Shared by acquire_transcode_slot (below) and the background warmer's own
-- pre-flight check: counts slot files younger than the staleness bound,
-- i.e. jobs genuinely still running right now.
local function count_active_transcode_slots(prefix, count)
  local dir = transcode_slots_dir()
  local now = os.time()
  local active = 0
  for i = 1, (count or transcode.max_concurrent) do
    local claimed_at = transcode.slot_claimed_at(dir .. "/" .. (prefix or "slot_") .. i)
    if claimed_at and (now - claimed_at) < VIDEO_TRANSCODE_PENDING_STALE_SECONDS then
      active = active + 1
    end
  end
  return active
end

-- Cheap peek, no claim: lets a caller decide whether it's even worth doing
-- the expensive work leading up to a transcode attempt (e.g. the warmer
-- below resolving a video's full bytes into memory) before finding out the
-- cap is full. Racy against a concurrent claim by design -- same "rare,
-- self-correcting" tolerance as everything else in this section, not worth
-- real locking for this deployment's traffic level.
local function transcode_slot_available()
  return count_active_transcode_slots() < transcode.max_concurrent
end

-- Returns a slot path for the caller to `rm -f` as part of its own job
-- cleanup command (so the slot releases itself the instant the job ends,
-- success or failure), or nil if every slot is currently held by a
-- still-fresh job. Stale slot files (owner process died without cleaning
-- up -- e.g. killed by a `systemctl restart` landing mid-transcode, same
-- failure mode the .pending markers already guard against) don't count
-- against the cap.
--
-- BUGFIX 2026-08-26: the old version checked count_active_transcode_slots()
-- and THEN wrote a uniquely-named file -- a check-then-act race, not an
-- atomic claim. Confirmed live: a burst of near-simultaneous callers (e.g.
-- several live requests landing on different worker processes at the same
-- moment the warmer also fires -- exactly the "right after a backend
-- restart" scenario this section's header comment already called out as a
-- known trigger, and this backend really was crash-looping at the time) can
-- all read the same "count < cap" snapshot before any of them has written
-- their own file, so every one of them passes the check and launches a
-- job. Observed live: 5-6 real concurrent ffmpeg encodes against a cap of
-- 2, saturating most of the host's CPU.
--
-- Fixed by claiming one of exactly transcode.max_concurrent fixed slot
-- names (slot_1..slot_N) via the shell's `noclobber` option instead of a
-- random per-job filename: `set -C; > path` is an atomic OS-level
-- O_CREAT|O_EXCL, so exactly one caller can ever win a given slot name --
-- no window between checking and claiming. A stale slot (owner died
-- without cleaning up) is removed before the claim attempt so it doesn't
-- permanently wedge that slot index.
--
-- 2026-09-01: takes an optional pool (name prefix + size) so the media
-- warmer can hold a SECOND, warmer-only slot of its own on top of the shared
-- one -- see the `transcode.warmer` table's header comment below for why. Defaults are
-- the original shared pool, so every existing call site is unchanged. Also
-- now reads each slot's age straight out of the file (see
-- transcode_slot_claimed_at) instead of forking a `find` per slot index, and
-- writes the claim timestamp as the file's contents -- `printf` is a shell
-- builtin, so the claim still costs exactly the one shell it always did.
-- Deliberately a bare global, not `local function` -- serve_media_thumb
-- (earlier in this file, see its video-thumbnail branch) needs to call
-- this, and Lua locals are only visible from their declaration point
-- onward in source order, so a caller positioned earlier in the chunk
-- can't see a later `local function` no matter when it actually runs.
-- Same forward-reference problem (and the same fix) as
-- fast_start_remux_if_needed elsewhere in this file. Also frees one slot
-- against this file's 200-top-level-local ceiling instead of costing one.
acquire_transcode_slot = function(prefix, count)
  local dir = transcode_slots_dir()
  local now = os.time()
  prefix = prefix or "slot_"
  for i = 1, (count or transcode.max_concurrent) do
    local slot_path = dir .. "/" .. prefix .. i
    local claimed_at = transcode.slot_claimed_at(slot_path)
    if claimed_at and (now - claimed_at) >= VIDEO_TRANSCODE_PENDING_STALE_SECONDS then
      os.execute("rm -f " .. shell_quote(slot_path))
    end
    -- The noclobber redirect failure (expected whenever the slot is already
    -- held) is a shell-level error raised while opening ">%s", which runs
    -- BEFORE the trailing "2>/dev/null" takes effect -- redirects apply
    -- left to right, so that message reached the journal on every contended
    -- claim instead of being suppressed. Wrapping in a `{ ; }` group applies
    -- 2>/dev/null to the whole group before the inner redirect executes.
    local claimed = os.execute(string.format(
      "set -C; { printf %%s %s > %s ; } 2>/dev/null", tostring(now), shell_quote(slot_path)))
    if claimed == 0 or claimed == true then
      return slot_path
    end
  end
  return nil
end

-- Source pixel dimensions in one probe, or nil if unreadable.
transcode.probe_video_dims = function(path)
  local probe = io.popen(string.format(
    "%s -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 %s 2>/dev/null",
    ffprobe_bin(), shell_quote(path)))
  if not probe then return nil end
  local line = probe:read("*l") or ""
  probe:close()
  local w, h = line:match("^(%d+),(%d+)")
  return tonumber(w), tonumber(h)
end

-- Path to a cached full-frame RGBA watermark overlay for this text at this
-- exact output size, or nil if one can't be produced.
--
-- 2026-09-01, and this is the single biggest speedup in the whole pipeline.
-- The watermark used to be burned in with drawtext, which has no hardware
-- variant, so every frame had to leave the GPU and come back:
-- hwdownload -> software lanczos scale -> drawtext -> hwupload. Benchmarked
-- on media 621 (a 1080p60 source) with the box otherwise idle, the 480p
-- rendition ran at 1.0x realtime -- i.e. it could not encode as fast as a
-- viewer watches, which is precisely how a viewer ends up staring at a
-- half-encoded video that keeps stalling.
--
-- Rendering the text ONCE into a transparent PNG the size of the output
-- frame, then compositing it with overlay_vaapi, keeps every frame on the
-- GPU for the whole pipeline. Measured, same box, same source, same
-- watermark:
--
--     480p    1.0x -> 6.3x realtime
--     720p    1.9x -> 3.6x
--     1080p   1.3x -> 1.9x
--
-- A full-FRAME overlay rather than a tightly-cropped one is deliberate: the
-- PNG is rendered through the very same drawtext filter string the CPU path
-- uses, against a transparent canvas of the output size, so the watermark
-- lands at pixel-identical coordinates with no separate positioning maths to
-- get wrong. The cost is nil -- these are 6-20KB PNGs, uploaded to the GPU
-- once per job, and the per-frame blend is the same work either way.
--
-- Cached by (text, width, height) since it depends on nothing else; a text
-- change produces a new key, and the digest seed already includes the
-- watermark text so the variants themselves re-encode anyway.
transcode.watermark_overlay = function(watermark_text, w, h)
  if not watermark_text or watermark_text == "" or not w or not h then return nil end
  local key = sodium.sodium_bin2hex(sodium.crypto_hash_sha256(tostring(watermark_text))):sub(1, 16)
  local dir = M.settings.uploads_dir .. "/_wm_overlay_cache"
  local path = string.format("%s/%s_%dx%d.png", dir, key, w, h)
  local cached = io.open(path, "rb")
  if cached then cached:close() return path end

  local filter, text_file = media_files.video_watermark_filter(watermark_text)
  if not filter then return nil end
  os.execute("mkdir -p " .. shell_quote(dir))
  -- Rendered to a temp name and renamed into place so a concurrent job can
  -- never observe a half-written PNG as a cache hit.
  local tmp = string.format("%s.tmp.%d.png", path, math.random(100000, 999999))
  local ok = os.execute(string.format(
    "%s -y -hide_banner -loglevel error -f lavfi -i %s -vf %s -frames:v 1 %s 2>/dev/null",
    ffmpeg_bin(),
    shell_quote(string.format("color=black@0.0:s=%dx%d,format=rgba", w, h)),
    shell_quote(filter), shell_quote(tmp)))
  if text_file then os.remove(text_file) end
  if ok == 0 or ok == true then
    os.execute(string.format("mv -f %s %s 2>/dev/null", shell_quote(tmp), shell_quote(path)))
    local check = io.open(path, "rb")
    if check then check:close() return path end
  end
  os.remove(tmp)
  return nil
end

-- Returns (transcoded_bytes, "video/mp4") on success, or (nil) to signal
-- "serve the original instead" (quality is "original", no ffmpeg profile
-- for that quality name, the file is too large to transcode, or a
-- transcode isn't cached yet).
--
-- The transcode itself now always runs as a DETACHED background process
-- rather than inline: running it inline blocked copas' single-threaded
-- loop for the whole transcode (measured live: 6+ seconds for a 40MB->
-- 720p pass, during which a concurrent, completely unrelated request from
-- another client timed out with zero bytes received). A cache miss now
-- falls through to serving the original immediately (still Range/206-
-- servable, so playback still starts instantly) while ffmpeg runs
-- detached; the requested quality becomes available near-instantly, via
-- the cache-hit path below, for every request after that -- including a
-- retry/reload of this same video by the same viewer a moment later.
-- Nested (not top-level) locals: this file's main chunk is already at
-- LuaJIT's 200-local ceiling.
--
-- 2026-08-31: NO CPU FALLBACK, deliberately. This used to fail open onto a
-- libx264 re-encode when no VAAPI device was found; that's exactly the
-- CPU-heavy background transcoding that made main.lua disable the media
-- warmer in the first place (BUGFIX 2026-08-26: sustained 6-7 of 8 cores
-- for hours, starved an unrelated Discord voice-bot swarm on the same box
-- into chronic disconnects). Re-enabling the warmer is only safe because
-- transcoding now runs on a dedicated GPU block instead of the CPU cores
-- everything else on this box also needs -- a silent CPU fallback would
-- quietly reopen that exact failure mode the moment the GPU is ever
-- unavailable, which defeats the entire point. Skipping the encode
-- instead (a quality just isn't offered yet) is a strictly better failure
-- than resurrecting the box-wide slowdown incident. See
-- ensure_hls_variant's identical pair for the confirmed-live hardware
-- details.
local function ensure_video_quality_cache(media_id, item, content, quality)
  local function vaapi_device()
    return os.getenv("GALLERY_VAAPI_DEVICE") or "/dev/dri/renderD128"
  end
  -- Retries before concluding "unavailable": a missing/unreadable device
  -- node is usually a real, sustained condition (driver crash, unplugged
  -- hardware), but a brief driver-reset window can transiently fail this
  -- exact check too -- worth 2 quick retries rather than skipping an
  -- encode (and, for an on-demand request, 503ing a viewer) over a blip
  -- that would have cleared a couple seconds later. copas.sleep (not
  -- os.execute("sleep ...")) so this yields to the scheduler instead of
  -- blocking the whole event loop for other requests during the wait --
  -- same guarded pattern as M.serve_hls_playlist's bounded poll.
  local function vaapi_available()
    local copas_ok, copas = pcall(require, "copas")
    for attempt = 1, 3 do
      local f = io.open(vaapi_device(), "rb")
      if f then f:close() return true end
      if attempt < 3 and copas_ok then copas.sleep(1) end
    end
    return false
  end

  local profile = VIDEO_QUALITY_PROFILES[quality]
  if not profile then return nil end
  if #content > VIDEO_TRANSCODE_SIZE_LIMIT then return nil end
  -- Every call here is a real re-encode (there's no -c copy option at this
  -- level -- callers only reach this for quality ~= "original"), so this
  -- is GPU-or-nothing unconditionally, checked before even looking at the
  -- pending marker/concurrency slot below: a GPU-less box would never be
  -- able to use one anyway.
  if not vaapi_available() then return nil end

  local sha_row = db.fetchone("SELECT content_sha256 FROM media_items WHERE id=%s", tostring(media_id))
  local watermark_text = nil -- WATERMARKS_ENABLED = false (get_user lookup for it removed too)
  local digest_seed = ((sha_row and nn(sha_row.content_sha256)) or item.updated_at or item.created_at or tostring(media_id))
    .. "|wm=" .. tostring(watermark_text or "")
  local cache_file = video_quality_cache_path(media_id, quality, digest_seed)

  local existing = io.open(cache_file, "rb")
  if existing then
    local bytes = M._read_file_chunked(existing)
    existing:close()
    if bytes and #bytes > 0 then return bytes, "video/mp4" end
  end

  -- A ".pending" marker (its content is just the unix timestamp it was
  -- created at) records that a background job is already in flight for
  -- this exact (media_id, quality, content digest), so a burst of
  -- requests before the first transcode finishes doesn't launch a pile of
  -- duplicate ffmpeg processes. Filesystem-based rather than an in-memory
  -- Lua table so it's automatically correct even across a server restart
  -- mid-transcode; a max age guards against a marker orphaned by a
  -- process that died without cleaning up after itself.
  local pending_marker = cache_file .. ".pending"
  local pf = io.open(pending_marker, "rb")
  local pending_age = nil
  if pf then
    pending_age = tonumber(pf:read("*a"))
    pf:close()
  end
  local already_pending = pending_age and (os.time() - pending_age) < VIDEO_TRANSCODE_PENDING_STALE_SECONDS

  -- acquire_transcode_slot() first, before touching disk at all: no point
  -- writing the .src.bin/.pending files for a job that's just going to
  -- decline to launch anyway because every slot is taken.
  local slot_path = not already_pending and acquire_transcode_slot() or nil
  if slot_path then
    os.execute("mkdir -p " .. shell_quote(M.settings.uploads_dir .. "/_video_cache"))
    local src = cache_file .. ".src." .. tostring(math.random(100000, 999999)) .. ".bin"
    local f = assert(io.open(src, "wb"))
    f:write(content)
    f:close()

    local marker = assert(io.open(pending_marker, "wb"))
    marker:write(tostring(os.time()))
    marker:close()

    local tmp_dst = cache_file .. ".tmp." .. tostring(math.random(100000, 999999)) .. ".mp4"
    local scale_filter = video_scale_filter(src, profile.max_width)
    local wm_filter, wm_text_file = media_files.video_watermark_filter(watermark_text)
    if wm_filter then scale_filter = scale_filter .. "," .. wm_filter end
    local cleanup = shell_quote(src) .. " " .. shell_quote(pending_marker) .. " " .. shell_quote(tmp_dst) .. " " .. shell_quote(slot_path)
    if wm_text_file then cleanup = cleanup .. " " .. shell_quote(wm_text_file) end

    -- vaapi_available() already confirmed true at the top of this
    -- function -- GPU codec_args unconditionally, no CPU fallback (see
    -- this function's own header comment for why). QVBR is the closest
    -- thing to CRF this driver supports (see ensure_hls_variant's
    -- identical branch); crf reused as global_quality.
    local vaapi_profile = profile.profile == "baseline" and "constrained_baseline" or profile.profile
    local pre_input_args = string.format("-vaapi_device %s ", shell_quote(vaapi_device()))
    -- -profile:v, not bare -profile -- see ensure_hls_variant's identical
    -- fix; ffmpeg warns bare -profile is ambiguous between the video and
    -- audio streams once both -c:v and -c:a are specified. No
    -- force_key_frames here: this produces a plain .mp4 (no HLS
    -- segmenting), so there's no segment-boundary alignment to fix.
    local codec_args = string.format(
      "-vf %s,format=nv12,hwupload -c:v h264_vaapi -rc_mode QVBR -global_quality %d -b:v %d -maxrate %d "
        .. "-profile:v %s -level 4.1 -c:a aac -b:a %s",
      shell_quote(scale_filter), profile.crf, profile.vaapi_ceiling_bps, profile.vaapi_ceiling_bps,
      vaapi_profile, profile.audio_bitrate
    )

    -- nice/ionice: this whole codepath was already "run detached so it
    -- doesn't block the event loop", but a CPU-bound ffmpeg encode at
    -- default (0) priority still competes for the CPU with the luajit
    -- process itself on a single/few-core box -- confirmed live: a
    -- watermarked re-encode saturated CPU badly enough that the whole
    -- site (unrelated requests, even the static SPA) went unresponsive
    -- for as long as ffmpeg ran, the "random severe slowdown under load"
    -- symptom in a different guise from the DB-blocking one. Lowest CPU
    -- ("nice -n 19") and I/O ("ionice -c2 -n7", best-effort lowest) scheduling
    -- priority so the kernel always favors the request-serving process.
    local cmd = string.format(
      "( nice -n 19 ionice -c2 -n7 %s -y -hide_banner -loglevel error %s-i %s -map 0:v:0 -map 0:a:0? %s "
        .. "-movflags +faststart -f mp4 %s "
        .. "&& mv -f %s %s; rm -f %s ) </dev/null >/dev/null 2>&1 &",
      ffmpeg_bin(), pre_input_args, shell_quote(src), codec_args, shell_quote(tmp_dst),
      shell_quote(tmp_dst), shell_quote(cache_file),
      cleanup
    )
    os.execute(cmd)
  end

  return nil
end

-- ---------------------------------------------------------------------------
-- Real HLS adaptive streaming. Range/206 (below) gets a player playing
-- almost instantly and buffering progressively, but it's still one fixed
-- rendition per request -- no seamless quality switching, and a quality
-- change means abandoning the current connection and re-requesting the
-- whole file at a different rendition. This gives real segmented,
-- progressively-encoded HLS: ffmpeg is launched detached (same pattern as
-- ensure_video_quality_cache above) with `-f hls`, which writes the
-- .m3u8 playlist and .ts segments to disk INCREMENTALLY as it encodes --
-- a client can start playing segment 0 while segment 4 is still being
-- encoded, and AVPlayer/hls.js re-poll the (still-growing) playlist for
-- new segments exactly like a live stream, dropping the trailing
-- #EXT-X-ENDLIST tag in automatically once ffmpeg reaches end of input.
-- "original" quality uses `-c copy` (remux only, no re-encode) so it's
-- available almost immediately regardless of source length.
-- ---------------------------------------------------------------------------

local HLS_SEGMENT_SECONDS = 6

-- media_id kept as a param (unused now) rather than reshuffling both call
-- sites -- item.content_sha256 (fetch_media_stream_row above) replaces
-- what used to be this function's own db.fetchone, which fired a second,
-- redundant query for the same row on every call -- including
-- serve_hls_segment's per-segment call, i.e. every ~6s of playback.
local function media_content_digest_seed(media_id, item, watermark_text)
  local base = nn(item.content_sha256) or item.updated_at or item.created_at or tostring(media_id)
  return base .. "|wm=" .. tostring(watermark_text or "")
end

local function hls_variant_dir(media_id, quality, digest_seed)
  local key = sodium.sodium_bin2hex(sodium.crypto_hash_sha256(tostring(digest_seed))):sub(1, 16)
  return M.settings.uploads_dir .. "/_hls_cache/" .. tostring(media_id) .. "_" .. quality .. "_" .. key
end

-- Returns the variant's cache directory (which may not have any segments
-- in it yet -- see the bounded poll in M.serve_hls_playlist) or nil if
-- this quality isn't offered at all for this file.
-- A playlist.m3u8 that exists but has no #EXT-X-ENDLIST is a dead artifact
-- from an encode that never finished (ffmpeg crashed, got OOM-killed, or --
-- since the detached transcode job lives in this service's systemd
-- cgroup and `systemctl restart` defaults to KillMode=control-group --
-- simply got torn down by a routine backend restart landing mid-transcode.
-- Confirmed live: media 606's 720p variant has been a 0-byte playlist.m3u8
-- plus a truncated last segment since a restart on 2026-08-10, and would
-- have 503'd "still starting up" forever, since nothing ever re-triggers
-- an encode for a file that already "exists".
-- BUGFIX 2026-09-01: #EXT-X-ENDLIST alone is NOT proof a variant is
-- complete, which is what this used to assume. Confirmed by direct
-- experiment: ffmpeg handles SIGTERM as a clean shutdown and writes the HLS
-- trailer -- ENDLIST included -- for whatever it had encoded so far. A
-- killed encode therefore leaves a playlist that is truncated but looks
-- finished, and because "looks finished" is exactly what this function
-- tested, that truncated variant was then cached and served FOREVER: no
-- retry, no relaunch, no way back. Two things routinely send that SIGTERM:
-- M.start_hls_idle_reaper (kills a transcode whose viewer clicked away) and
-- any `systemctl restart` of this service (KillMode=control-group tears
-- down the detached ffmpeg along with the worker).
--
-- Found in production as exactly the reported symptom -- "a 5 minute video
-- is cut down on original and 1080p": media 663 served 21s (original) and 9s
-- (1080p) of a 300s video, 668 served 62s of 450s, 664 served 39s of 195s.
-- The pattern is not a coincidence: original and 1080p are the slowest
-- renditions to encode, so they are the ones a kill is most likely to land
-- in the middle of.
--
-- So a variant is complete only if it has ENDLIST AND its own summed EXTINF
-- duration is within a small tolerance of the source's real duration
-- (recorded as `.expected_duration` when the job launched -- see
-- ensure_hls_variant). Anything shorter is a killed encode: report it as not
-- ready, and the existing relaunch path rebuilds it from scratch.
--
-- The `.verified` marker is a pure optimisation on top: this function is
-- called on EVERY playlist and segment request, and it used to read the
-- whole playlist.m3u8 (thousands of lines on a long video) every time just
-- to look for one tag. A variant that has passed the duration check can
-- never later fail it, so the verdict is written once and every subsequent
-- call is a single small open -- strictly less I/O per request than the
-- version that only checked for ENDLIST.
--
-- Variants encoded before this change have no `.expected_duration` and
-- cannot be checked retroactively; they keep the old ENDLIST-only behaviour.
-- The three truncated ones above were found and deleted by hand at deploy
-- time, so the remaining legacy variants are known-good.
local function hls_variant_ready(dir)
  local vf = io.open(dir .. "/.verified", "rb")
  if vf then vf:close() return true end

  local f = io.open(dir .. "/playlist.m3u8", "rb")
  if not f then return false end
  local text = f:read("*a")
  f:close()
  if not text or not text:find("#EXT-X-ENDLIST", 1, true) then return false end

  local ef = io.open(dir .. "/.expected_duration", "rb")
  local expected = ef and tonumber((ef:read("*a") or ""):match("[%d%.]+")) or nil
  if ef then ef:close() end
  if expected and expected > 0 then
    local actual = 0
    for d in text:gmatch("#EXTINF:([%d%.]+)") do actual = actual + (tonumber(d) or 0) end
    -- 3% slack absorbs the last partial segment and rounding; a killed
    -- encode is short by far more than that (9s of 300s, 62s of 450s).
    if actual < expected * 0.97 then return false end
  end

  local mark = io.open(dir .. "/.verified", "wb")
  if mark then mark:write("1") mark:close() end
  return true
end

-- `item` alone (no pre-read file bytes) is enough to check whether a
-- variant is already cached -- the size cap uses the DB's file_size
-- column rather than an actual read, and pending/ready checks are pure
-- filesystem stats. The full source is only read from disk/DB (via
-- content_fn, called at most once) on a genuine cache miss, right before
-- it's written to source.bin. This matters because M.serve_hls_playlist
-- calls this on every playlist request, including hls.js's periodic
-- re-polls of a still-growing (no #EXT-X-ENDLIST yet) playlist during an
-- active transcode -- previously that read the ENTIRE source file into
-- memory on every one of those polls, for every concurrent viewer,
-- regardless of whether anything actually needed launching. On a public
-- gallery with several people watching different in-progress transcodes
-- at once, that was real, repeated, avoidable memory/disk pressure.
--
-- `opts` (2026-09-01, media warmer only -- every viewer-facing call site
-- passes nothing and behaves exactly as before) carries `warmer = true`,
-- which makes this claim the warmer's own single-job slot on top of the
-- shared one, and `source_path`, an already-on-disk copy of the original to
-- hardlink instead of buffering through memory. See the `transcode.warmer` table's
-- header comment above and the two call sites' own comments below.
local function ensure_hls_variant(media_id, item, content_fn, quality, opts)
  -- Nested (not top-level) locals: this file's main chunk is already at
  -- LuaJIT's 200-local ceiling, and these are only ever needed here (both
  -- the early skip-if-no-GPU check below and the codec_args section
  -- further down use this same pair, hence defined once up top rather
  -- than duplicated in both places).
  local function vaapi_device()
    return os.getenv("GALLERY_VAAPI_DEVICE") or "/dev/dri/renderD128"
  end

  -- Confirmed live 2026-08-31 on this box's AMD Radeon 610M (Mendocino
  -- APU): h264_vaapi works, including through a drawtext filter
  -- (format=nv12,hwupload after the software drawtext stage, since
  -- drawtext itself has no hardware-surface variant). A plain readability
  -- check rather than shelling out to vainfo -- ffmpeg does its own real
  -- device/driver validation when it actually opens the device, and this
  -- is just meant to catch "there's no GPU here at all".
  --
  -- 2026-08-31: NO CPU FALLBACK, deliberately -- see the needs_reencode
  -- check below and ensure_video_quality_cache's identical one. This used
  -- to fail open onto a libx264 re-encode when this returned false;
  -- that's exactly the CPU-heavy background transcoding that made
  -- main.lua disable the media warmer in the first place (BUGFIX
  -- 2026-08-26: sustained 6-7 of 8 cores for hours, starved an unrelated
  -- Discord voice-bot swarm on the same box into chronic disconnects).
  -- Re-enabling the warmer is only safe because transcoding now runs on a
  -- dedicated GPU block instead of the CPU cores everything else on this
  -- box also needs -- a silent CPU fallback would quietly reopen that
  -- exact failure mode the moment the GPU is ever unavailable, which
  -- defeats the entire point. Skipping the encode instead (a quality just
  -- isn't offered yet) is a strictly better failure than resurrecting the
  -- box-wide slowdown incident.
  --
  -- Retries before concluding "unavailable" -- see
  -- ensure_video_quality_cache's identical comment for why (a brief
  -- driver-reset window can transiently fail this exact check, and it's
  -- worth 2 quick retries rather than 503ing a viewer over a blip).
  -- copas.sleep so this yields instead of blocking the whole event loop.
  local function vaapi_available()
    local copas_ok, copas = pcall(require, "copas")
    for attempt = 1, 3 do
      local f = io.open(vaapi_device(), "rb")
      if f then f:close() return true end
      if attempt < 3 and copas_ok then copas.sleep(1) end
    end
    return false
  end

  if quality ~= "original" and not VIDEO_QUALITY_PROFILES[quality] then return nil end
  -- "original" is a `-c copy` remux (no re-encode -- see the codec_args
  -- branch below), not a real transcode, so the size cap that exists to
  -- bound ffmpeg re-encode time doesn't apply to it. Applying it here
  -- anyway meant any upload over the cap 404'd on EVERY quality, including
  -- the one rendition explicitly meant to "be available almost instantly
  -- regardless of source length" per this section's own header comment --
  -- the exact "nothing plays" symptom for large uploads.
  if quality ~= "original" and db.toint(item.file_size, 0) > VIDEO_TRANSCODE_SIZE_LIMIT then return nil end

  local watermark_text = nil -- WATERMARKS_ENABLED = false (get_user lookup for it removed too)
  local digest_seed = media_content_digest_seed(media_id, item, watermark_text)
  local dir = hls_variant_dir(media_id, quality, digest_seed)

  -- Every quality tier other than a non-watermarked "original" needs a
  -- real re-encode (scaling always does; a watermarked "original" does
  -- too, since -c copy can't run a filter graph) -- see vaapi_available's
  -- own header comment for why that's GPU-or-nothing now. Checked before
  -- even claiming a concurrency slot below: a GPU-less box would never be
  -- able to use one anyway, so there's no point holding it.
  local needs_reencode = quality ~= "original" or (watermark_text ~= nil and watermark_text ~= "")
  if needs_reencode and not vaapi_available() then return nil, "gpu_unavailable" end

  -- Same filesystem-based ".pending" dedup as ensure_video_quality_cache.
  local pending_marker = dir .. ".pending"
  local pf = io.open(pending_marker, "rb")
  local pending_age = pf and tonumber(pf:read("*a")) or nil
  if pf then pf:close() end
  local still_encoding = pending_age and (os.time() - pending_age) < VIDEO_TRANSCODE_PENDING_STALE_SECONDS
  if still_encoding then
    -- A still-fresh marker only proves the job was CLAIMED recently, not
    -- that the encoder is still actually alive -- if ffmpeg crashed (or
    -- errored out immediately on this specific file -- an odd resolution,
    -- a corrupt frame, whatever) moments after starting, this marker would
    -- otherwise read as "still running" for up to the full 30-minute
    -- staleness window, during which every viewer gets handed a playlist
    -- that will never grow past whatever partial/truncated segment ffmpeg
    -- wrote before dying. Suspected live cause of a "this format isn't
    -- supported by your browser" report on a video whose actual source
    -- codec was plain h264 (confirmed via ffprobe, so not a real
    -- incompatibility) -- a truncated tail segment fails to demux/decode
    -- exactly the same way a genuine one would, and reloading the same
    -- broken segment "confirms" it as permanent instead of a one-off.
    -- Now checkable at all because ensure_hls_variant's own launch writes
    -- a .pid file (see its header comment) -- reuses the same
    -- /proc/<pid>/cmdline liveness check as M.start_hls_idle_reaper.
    local pid_f = io.open(dir .. "/.pid", "rb")
    local pid = pid_f and tonumber(pid_f:read("*a")) or nil
    if pid_f then pid_f:close() end
    if pid then
      local cf = io.open("/proc/" .. tostring(pid) .. "/cmdline", "rb")
      local cmdline = cf and cf:read("*a") or ""
      if cf then cf:close() end
      still_encoding = cmdline:find("ffmpeg", 1, true) ~= nil
    end
    -- pid == nil: .pid hasn't been written yet -- the narrow window right
    -- after this function's own os.execute(cmd) returns but before the
    -- backgrounded subshell's `echo $!` has run. Not a dead job, just not
    -- provably alive yet either -- trust the marker rather than misfire on
    -- a race this function itself just created a moment ago.
  end

  -- Trust the existing directory only if it's genuinely complete, or a
  -- transcode for it is still actively running (don't stomp on/duplicate
  -- live work just because the playlist hasn't gotten its ENDLIST yet).
  if hls_variant_ready(dir) or still_encoding then return dir end
  -- A stale marker means the previous encoder died. Remove the incomplete
  -- directory before relaunching so old segments can never be served as a
  -- newly-started variant.
  os.execute("rm -rf " .. shell_quote(dir))
  os.remove(pending_marker)

  -- Global concurrency cap (see acquire_transcode_slot's header comment)
  -- checked BEFORE claiming the .pending marker below: a capacity-blocked
  -- request that still wrote the marker would block every other viewer's
  -- retry for this same variant for the next 5 minutes even though no job
  -- is actually running.
  local capacity_slot_path = acquire_transcode_slot()
  if not capacity_slot_path then return nil, "busy" end

  -- Warmer-only second cap, claimed on top of (not instead of) the shared
  -- slot above, so the warmer can never have more than transcode.warmer.jobs_max = 1
  -- ffmpeg running while a viewer's own on-demand transcode still draws on
  -- the full shared budget of 2. Same atomic-noclobber claim, same
  -- self-cleanup-on-exit contract (it is appended to the job's `cleanup`
  -- list below), same staleness reclaim -- just a separate pool of slot
  -- names. Releasing the shared slot again on failure matters: holding a
  -- slot we have decided not to use would turn away a real viewer for
  -- nothing.
  local warm_slot_path = nil
  if opts and opts.warmer then
    warm_slot_path = acquire_transcode_slot("warm_", transcode.warmer.jobs_max)
    if not warm_slot_path then
      os.remove(capacity_slot_path)
      return nil, "busy"
    end
  end

  -- Claim this slot BEFORE calling content_fn(), not after: content_fn()
  -- reads through resolve_media_bytes, which can hit the DB (potentially a
  -- large blob fetch) and therefore genuinely yields to copas's scheduler
  -- (a query still queues on whichever pooled connection db.lua hands it,
  -- and pgmoon's socket I/O yields regardless -- see db.lua's pool and
  -- swarmlua/pg.lua's per-connection lock). If the marker write happened
  -- after that yield, two viewers' requests landing on the
  -- same cold digest within the same moment could both pass the check
  -- above before either had written the marker, and both go on to launch
  -- their own duplicate ffmpeg job against the same output directory.
  -- Writing the marker here, before the one yielding step in this
  -- function, keeps the check-then-claim sequence atomic with respect to
  -- other coroutines the same way it was when content was always resolved
  -- up front by the caller.
  --
  -- mkdir -p the top-level _hls_cache dir BEFORE this write, not just
  -- `dir` further below: pending_marker lives at _hls_cache/<variant>.pending
  -- (a sibling of `dir`, not inside it), so it only ever worked before
  -- because _hls_cache/ already existed from some earlier variant's own
  -- mkdir -p. Confirmed live: with a fully empty uploads dir (no _hls_cache
  -- at all yet), io.open here threw "No such file or directory" and the
  -- concurrency slot claimed above leaked (never reached its cleanup),
  -- which is exactly what "server is busy" for every subsequent request
  -- traced back to.
  os.execute("mkdir -p " .. shell_quote(M.settings.uploads_dir .. "/_hls_cache"))
  local marker = assert(io.open(pending_marker, "wb"))
  marker:write(tostring(os.time()))
  marker:close()

  os.execute("mkdir -p " .. shell_quote(dir))
  -- Marks this variant as speculative pre-warm rather than something a
  -- viewer asked for. The reaper needs the distinction: BOTH kinds of
  -- background job legitimately have no heartbeat (a viewer who was handed a
  -- complete rendition instead is no longer polling the one they asked for),
  -- but only the warmer's own work should be stopped when viewers appear.
  if opts and opts.warmer then
    local wm = io.open(dir .. "/.warm", "wb")
    if wm then wm:write("1") wm:close() end
  end
  local src = dir .. "/source.bin"

  -- 2026-09-01: hardlink the original into place when the caller already
  -- knows where it lives on disk (the media warmer does -- see its call
  -- sites). content_fn is resolve_media_bytes, which reads the ENTIRE video
  -- into a Lua string -- up to the 500MB transcode cap -- and then writes
  -- every byte of it back out to source.bin. Both halves are blocking,
  -- non-yielding I/O executed inside the single-threaded copas loop that is
  -- simultaneously serving every HTTP request on this worker, so each warm
  -- launch stalled the whole site for as long as a full read+write of the
  -- source took, on top of the memory spike. `ln` is a metadata operation:
  -- constant time, zero bytes copied, no spike. `cp` covers the source
  -- happening to sit on a different filesystem, and falling through to
  -- content_fn covers the original not being on disk at all yet (a DB-stored
  -- blob whose _original_cache copy has not been written) -- that path also
  -- populates the cache, so the next quality for the same video takes the
  -- fast path.
  --
  -- Safe against the job's own cleanup: `rm -f source.bin` drops only THIS
  -- link, never the shared cache file, which keeps its own.
  local linked = false
  if opts and opts.source_path then
    local probe = io.open(opts.source_path, "rb")
    if probe then
      probe:close()
      local q_src, q_dst = shell_quote(opts.source_path), shell_quote(src)
      -- Symlink before cp: since 2026-10-26 new originals live on the
      -- fast-disk tier (config.lua's hot_dir) while _hls_cache is on the
      -- USB drive, so the hardlink fails across filesystems and cp would
      -- copy the whole video onto the slowest disk. source.bin is only
      -- read while the encode runs (the job removes it afterwards).
      local rc = os.execute(string.format(
        "ln -f %s %s 2>/dev/null || ln -sf %s %s 2>/dev/null || nice -n 10 cp -f %s %s 2>/dev/null",
        q_src, q_dst, q_src, q_dst, q_src, q_dst))
      linked = (rc == 0 or rc == true)
    end
  end

  if not linked then
    local content = content_fn()
    if not content then
      os.remove(pending_marker)
      os.remove(capacity_slot_path)
      if warm_slot_path then os.remove(warm_slot_path) end
      -- mkdir -p above now runs before the source is resolved, so clean up
      -- the empty directory it would otherwise leave behind.
      os.execute("rm -rf " .. shell_quote(dir))
      return nil, "missing"
    end
    local f = assert(io.open(src, "wb"))
    f:write(content)
    f:close()
    content = nil
  end

  -- Recorded before ffmpeg starts so hls_variant_ready can later tell a
  -- finished encode from a killed one (see its header comment). Written into
  -- the variant directory, so the `rm -rf dir` that precedes any relaunch
  -- clears it along with everything else. One ffprobe on the launch path
  -- only -- never on a cache hit.
  local source_bitrate_bps
  do
    -- Via os.execute into a file (not io.popen) so blockwatch runs it in
    -- the background: on the USB drive this probe held a worker 0.65s+.
    local probe_out = dir .. "/.probe"
    os.execute(string.format(
      "%s -v error -show_entries format=duration,bit_rate -of csv=p=0 %s > %s 2>/dev/null",
      ffprobe_bin(), shell_quote(src), shell_quote(probe_out)))
    local pf = io.open(probe_out, "rb")
    local out = pf and pf:read("*a") or ""
    if pf then pf:close() end
    os.remove(probe_out)
    -- `-of csv=p=0` on format=duration,bit_rate emits one "duration,bitrate"
    -- line; either field can be "N/A" on an odd container, hence the
    -- tolerant per-field match rather than positional parsing.
    local d_s, b_s = out:match("([^,\n]*),([^,\n]*)")
    local source_duration = tonumber(d_s and d_s:match("[%d%.]+"))
    source_bitrate_bps = tonumber(b_s and b_s:match("%d+"))
    if source_duration and source_duration > 0 then
      local df = io.open(dir .. "/.expected_duration", "wb")
      if df then df:write(string.format("%.3f", source_duration)) df:close() end
    end
  end

  local wm_filter, wm_text_file = media_files.video_watermark_filter(watermark_text)

  -- Nested (not top-level) local: this file's main chunk is already at
  -- LuaJIT's 200-local ceiling, and this is only ever needed here.
  --
  -- Source video bitrate in bits/sec, or nil if unavailable -- used to
  -- target a VAAPI VBR encode below at roughly the same bitrate as the
  -- source instead of guessing a fixed number, since VAAPI's rate control
  -- is QP/bitrate-based with no CRF-style "same visual quality regardless
  -- of content" mode.
  local function probe_video_bitrate(path)
    local probe = io.popen(string.format(
      "%s -v error -select_streams v:0 -show_entries stream=bit_rate -of csv=p=0 %s 2>/dev/null",
      ffprobe_bin(), shell_quote(path)
    ))
    if not probe then return nil end
    local line = probe:read("*l")
    probe:close()
    return tonumber(line)
  end

  -- vaapi_available() was already checked above (needs_reencode gate) for
  -- every branch that reaches here with something to actually re-encode --
  -- both branches below build GPU codec_args unconditionally, no CPU
  -- fallback (see vaapi_available's own header comment for why).
  --
  -- `-hwaccel vaapi -hwaccel_output_format vaapi` (both branches) decodes
  -- the source on the GPU's VCN block too, instead of the previous
  -- software decode -- confirmed live 2026-08-31 via direct ffmpeg
  -- benchmarks on a real 1080p source (30s clip): software decode alone
  -- ran a single 480p+watermark job at ~27s of user CPU time; hwaccel
  -- decode dropped that to ~16s (-40%) with a comparable or slightly
  -- faster wall-clock, decode being the dominant CPU cost in this
  -- pipeline, not the software scale/drawtext stages after it (which stay
  -- exactly as they were -- `hwdownload` right after decode hands them a
  -- normal system-memory nv12 frame, so video_scale_filter's upscale/
  -- unsharp branch and the watermark drawtext filter need no changes at
  -- all). A more aggressive all-hardware pipeline (scale_vaapi, keeping
  -- frames on-GPU end to end) was also benchmarked and cut CPU further
  -- (~93% for the no-watermark case) but made watermarked jobs' wall-clock
  -- WORSE (~19s vs ~8.5s for the same 30s clip) due to the hwdownload/
  -- hwupload round-trip drawtext still requires (no VAAPI-native drawtext
  -- exists) -- not worth that trade for this deployment.
  --
  -- Do NOT read any of this as license to raise transcode.max_concurrent,
  -- though -- also confirmed live via direct concurrent-job benchmarking:
  -- aggregate throughput on this box's VCN block PEAKS at 2 concurrent
  -- jobs (3.8 source-seconds processed per wall-clock second) and drops at
  -- 3 (2.78/s, worse than 2 concurrent AND barely above 1 job's 1.57/s) --
  -- the video engine itself, not CPU, is the binding constraint once
  -- decode is also on the GPU, and it's already near its ceiling at 2. This
  -- matches the existing "~64% overhead for just 2 concurrent jobs" finding
  -- recorded above for the OLD software-decode pipeline (see
  -- VIDEO_TRANSCODE_PENDING_STALE_SECONDS's comment) -- two independent
  -- measurements, two different pipelines, same conclusion: this GPU's
  -- video block, not an arbitrary CPU-safety number, is what actually caps
  -- concurrency at 2 on this hardware.
  local pre_input_args = ""
  local codec_args
  -- Set together by the all-GPU branches below: a second input (the
  -- watermark PNG), the filter graph, and its overlay-upload prelude. When
  -- they stay empty the command keeps its original single-input `-vf` shape.
  local extra_input_args, filter_complex, overlay_prep = "", nil, ""
  if quality == "original" then
    if wm_filter then
      -- A watermark can't be burned in through `-c copy` (stream remux,
      -- no filter graph runs at all) -- re-encode at the source
      -- resolution so "original" still gets watermarked like every other
      -- quality instead of silently skipping it, which was the actual bug
      -- report ("watermark doesn't show up at all on videos"). Runs on
      -- the GPU's dedicated VAAPI encode block: separate silicon from the
      -- CPU entirely, so it doesn't compete for the same cycles no matter
      -- how loaded the box's CPU is. VAAPI has no CRF-equivalent "same
      -- quality regardless of content" mode, so VBR is targeted at the
      -- source's own bitrate (falling back to a flat 6Mbps guess if
      -- ffprobe can't read it) rather than a guessed QP, to land in the
      -- same ballpark as the source instead of guessing at a QP-to-CRF
      -- equivalence.
      -- Prefer the all-GPU composite (see transcode.watermark_overlay): at
      -- full source resolution this is the most expensive rendition on the
      -- site, and it is the one the player asks for by default.
      local sw, sh = transcode.probe_video_dims(src)
      local overlay_png = sw and sh and transcode.watermark_overlay(watermark_text, sw, sh)
      local vf = "hwdownload,format=nv12," .. wm_filter .. ",format=nv12,hwupload"
      if overlay_png then
        extra_input_args = string.format("-i %s ", shell_quote(overlay_png))
        filter_complex = "[0:v][wm]overlay_vaapi=x=0:y=0[v]"
        overlay_prep = "[1:v]format=rgba,hwupload[wm];"
        vf = nil
      end
      local source_bitrate = source_bitrate_bps or probe_video_bitrate(src) or 6000000
      local maxrate = math.floor(source_bitrate * 1.3)
      local bufsize = maxrate * 2
      pre_input_args = string.format(
        "-hwaccel vaapi -hwaccel_output_format vaapi -vaapi_device %s ", shell_quote(vaapi_device())
      )
      -- force_key_frames: without an explicit keyframe interval, the HLS
      -- muxer can only cut a new segment at whatever keyframe the encoder
      -- happens to produce at/after hls_time -- fine for constant-frame-rate
      -- source but confirmed live to produce badly uneven segments (an
      -- alternating 8s/4s pattern against a 6s HLS_SEGMENT_SECONDS target)
      -- on real uploaded video, which turned out to be variable-frame-rate
      -- (ffprobe's avg_frame_rate != r_frame_rate on that source, common for
      -- phone/screen recordings) -- frame-count GOP sizing doesn't map to a
      -- fixed wall-clock interval under VFR. A time-based forced keyframe
      -- every HLS_SEGMENT_SECONDS sidesteps needing to probe fps at all and
      -- is fps-agnostic by construction; verified locally (real VAAPI
      -- device, the exact source that produced the uneven segments above)
      -- to produce clean, uniform 6.000000s segments end to end.
      -- -profile:v (not bare -profile, which ffmpeg warns is ambiguous
      -- between the video and audio streams) -- confirmed to still resolve
      -- to the video stream's profile as-is, but that's undocumented
      -- behavior this ffmpeg version happens to have, not a guarantee.
      codec_args = string.format(
        "%s -force_key_frames %s -c:v h264_vaapi -rc_mode VBR -b:v %d -maxrate %d -bufsize %d -profile:v high -level 4.1 -c:a aac -b:a 320k",
        vf and ("-vf " .. shell_quote(vf)) or "",
        shell_quote(string.format("expr:gte(t,n_forced*%d)", HLS_SEGMENT_SECONDS)),
        source_bitrate, maxrate, bufsize
      )
    else
      codec_args = "-c copy"
    end
  else
    -- Unlike "original" above, these tiers always re-encode regardless of
    -- watermark (scaling itself requires it), so needs_reencode above was
    -- unconditionally true and vaapi_available() already confirmed.
    local profile = VIDEO_QUALITY_PROFILES[quality]
    local scale_filter = "hwdownload,format=nv12," .. video_scale_filter(src, profile.max_width)
    if wm_filter then scale_filter = scale_filter .. "," .. wm_filter end

    -- All-GPU scale (+ watermark composite) where it is safe to use, which
    -- is the overwhelmingly common case: a genuine DOWNSCALE of a source at
    -- least as wide as the tier. The upscale case keeps the old chain --
    -- video_scale_filter adds an unsharp pass when upscaling and there is no
    -- VAAPI equivalent, so that path stays exactly as it was rather than
    -- silently dropping the sharpening. Likewise any failure to produce the
    -- overlay PNG falls back rather than dropping the watermark: a missing
    -- watermark is a correctness bug, a slower encode is not.
    local src_w, src_h = transcode.probe_video_dims(src)
    if src_w and src_h and src_w >= profile.max_width then
      local out_w = profile.max_width
      -- Even height, matching the ":-2" the software scaler was computing.
      local out_h = math.floor(src_h * out_w / src_w / 2 + 0.5) * 2
      local overlay_png = wm_filter and transcode.watermark_overlay(watermark_text, out_w, out_h) or nil
      if wm_filter and overlay_png then
        extra_input_args = string.format("-i %s ", shell_quote(overlay_png))
        overlay_prep = "[1:v]format=rgba,hwupload[wm];"
        filter_complex = string.format(
          "[0:v]scale_vaapi=w=%d:h=%d[bg];[bg][wm]overlay_vaapi=x=0:y=0[v]", out_w, out_h)
        scale_filter = nil
      elseif not wm_filter then
        filter_complex = string.format("[0:v]scale_vaapi=w=%d:h=%d[v]", out_w, out_h)
        scale_filter = nil
      end
    end
    -- No CRF-equivalent constant-quality mode on this driver (ICQ isn't
    -- supported -- confirmed live 2026-08-31, only CQP/CBR/VBR/QVBR are)
    -- so QVBR is the closest fit: global_quality reuses this table's own
    -- crf value (same rough 0-51 QP-like scale as x264's crf) as the
    -- actual quality driver, with vaapi_ceiling_bps as a generous cap
    -- against pathologically complex content rather than the primary
    -- lever. "baseline" has no VAAPI equivalent name -- maps to
    -- constrained_baseline, the closest match.
    -- Never spend more bits than the source actually has.
    --
    -- 2026-09-01, measured on media 621: the 1080p rendition came out at
    -- 508MB against a 468MB `original` -- 4.3MB per segment versus 3.9MB.
    -- The rendition meant to be a step DOWN was the most expensive thing on
    -- the site, costing more disk, more GPU time and more bytes per viewer
    -- than the source it was derived from, for no visual gain: QVBR was
    -- handed a flat 8Mbps ceiling regardless of whether the source was
    -- anywhere near it, and a 1080p tier applied to an already-1080p source
    -- does no downscaling to claw that back. This matters more than it
    -- looks: the uploads volume is a USB-attached disk that reads cold data
    -- at ~23MB/s (measured), so bytes per segment IS the binding constraint
    -- on how many people can watch at once.
    --
    -- min() only ever binds in that pathological case -- for a genuine
    -- downscale (480p off a 1080p source) the tier ceiling is already far
    -- below the source bitrate and nothing changes. Falls back to the flat
    -- ceiling when ffprobe cannot read a bitrate.
    local ceiling_bps = profile.vaapi_ceiling_bps
    if source_bitrate_bps and source_bitrate_bps > 0 then
      ceiling_bps = math.min(ceiling_bps, source_bitrate_bps)
    end
    local vaapi_profile = profile.profile == "baseline" and "constrained_baseline" or profile.profile
    pre_input_args = string.format(
      "-hwaccel vaapi -hwaccel_output_format vaapi -vaapi_device %s ", shell_quote(vaapi_device())
    )
    -- force_key_frames + -profile:v: see the identical fix (and its
    -- verification notes) on the "original"-quality VBR branch above --
    -- same VFR-source uneven-segment issue applies here too, and this QVBR
    -- branch is the one that actually runs for every scaled quality tier.
    codec_args = string.format(
      "%s -force_key_frames %s -c:v h264_vaapi -rc_mode QVBR -global_quality %d -b:v %d -maxrate %d "
        .. "-profile:v %s -level 4.1 -c:a aac -b:a %s",
      scale_filter and ("-vf " .. shell_quote(scale_filter .. ",format=nv12,hwupload")) or "",
      shell_quote(string.format("expr:gte(t,n_forced*%d)", HLS_SEGMENT_SECONDS)),
      profile.crf, ceiling_bps, ceiling_bps,
      vaapi_profile, profile.audio_bitrate
    )
  end

  local pid_file = dir .. "/.pid"
  local cleanup = shell_quote(src) .. " " .. shell_quote(pending_marker) .. " " .. shell_quote(capacity_slot_path) .. " " .. shell_quote(pid_file)
  if warm_slot_path then cleanup = cleanup .. " " .. shell_quote(warm_slot_path) end
  if wm_text_file then cleanup = cleanup .. " " .. shell_quote(wm_text_file) end

  -- hls_flags temp_file: each playlist rewrite happens via write-then-
  -- rename, so a concurrent read of playlist.m3u8 (M.serve_hls_playlist,
  -- possibly mid-encode) never sees a torn/partial write.
  -- nice/ionice: see ensure_video_quality_cache's identical comment --
  -- keeps a CPU-heavy detached encode from starving the request-serving
  -- process of CPU, confirmed live to otherwise make the whole site
  -- unresponsive for the duration of the encode.
  -- pre_input_args: empty for every branch except the VAAPI one above,
  -- which needs `-vaapi_device ...` before `-i` (a global option, not a
  -- per-input or per-output one).
  --
  -- ffmpeg itself is backgrounded WITHIN the outer subshell (rather than
  -- the old "( ffmpeg; rm cleanup ) &" that only ever backgrounded the
  -- whole thing as one unit) so `$!` captures ffmpeg's own PID -- nice/
  -- ionice exec() into place rather than forking again, so this PID is
  -- ffmpeg's real one, not a short-lived wrapper's. See
  -- M.start_hls_idle_reaper below for why: without a direct PID, there was
  -- no way to actually stop an abandoned transcode early (only the
  -- 30-minute crash-orphan sweep would ever reclaim it), so a viewer who
  -- clicked off mid-encode left it running for however long the encode
  -- naturally takes, tying up one of only transcode.max_concurrent=2
  -- global slots the whole site shares. `wait` blocks the subshell on
  -- exactly that one background job, so `rm -f cleanup` (slot included)
  -- still fires the instant ffmpeg exits, killed early or not -- no change
  -- to the existing self-cleanup-on-exit contract.
  -- filter_complex needs its output mapped by label, and pulls in the
  -- watermark PNG as a second input; without it the original single-input
  -- `-vf` form is used unchanged.
  local graph_args, map_args = "", "-map 0:v:0 -map 0:a:0?"
  if filter_complex then
    graph_args = string.format("-filter_complex %s ", shell_quote(overlay_prep .. filter_complex))
    map_args = "-map \"[v]\" -map 0:a:0?"
  end

  local cmd = string.format(
    "( nice -n 19 ionice -c2 -n7 %s -y -hide_banner -loglevel error %s-i %s %s%s%s %s "
      -- playlist_type EVENT, not VOD -- and this is what actually decides
      -- whether a cold video is watchable while it encodes.
      --
      -- 2026-09-01: ffmpeg's HLS muxer only rewrites the playlist after each
      -- segment when the playlist type is NOT vod; for vod it writes the
      -- playlist exactly once, from av_write_trailer, when the encode
      -- finishes. Verified directly: 16s into a vod encode there was one
      -- segment on disk and NO playlist.m3u8 at all, while the identical
      -- encode as `event` had a playlist with its first entry already in it.
      --
      -- So every partial playlist previously observed mid-encode only existed
      -- because that job had been KILLED (the trailer runs on SIGTERM too --
      -- the same behaviour behind the truncated-variant bug). For a genuinely
      -- cold video this meant serve_hls_playlist's bounded wait for a first
      -- #EXTINF could never succeed no matter how long it waited: the file it
      -- was polling for does not exist until the whole encode is done. A cold
      -- 11-minute video therefore 503'd for the entire ~6-10 minutes it took
      -- to encode, which is exactly the "it won't load" symptom.
      --
      -- EVENT is the right type for a growing-but-will-end recording: every
      -- segment stays listed (so seeking back works, unlike a live window),
      -- and av_write_trailer still appends #EXT-X-ENDLIST on completion, so
      -- the duration check in hls_variant_ready is unaffected.
      .. "-f hls -hls_time %d -hls_list_size 0 -hls_playlist_type event -hls_flags independent_segments+temp_file "
      .. "-hls_segment_filename %s %s & echo $! > %s; wait; rm -f %s ) </dev/null >/dev/null 2>&1 &",
    ffmpeg_bin(), pre_input_args, shell_quote(src), extra_input_args, graph_args, map_args,
    codec_args, HLS_SEGMENT_SECONDS,
    shell_quote(dir .. "/seg_%05d.ts"), shell_quote(dir .. "/playlist.m3u8"), shell_quote(pid_file),
    cleanup
  )
  os.execute(cmd)
  return dir
end

-- ---------------------------------------------------------------------------
-- Background media warmer: proactively pre-transcodes every video's HLS
-- quality-variant renditions (144p/480p/720p/1080p plus "original", via
-- ensure_hls_variant), so a viewer's FIRST request for a given quality is
-- already a cache hit instead of a live cold-start transcode. That
-- fallback path is still correct and still happens for anything the warmer
-- hasn't reached yet or that a capacity-full moment skipped -- this only
-- shrinks how often it's needed.
--
-- FIXED 2026-08-31 (was warming the wrong cache entirely): this used to
-- warm ensure_video_quality_cache's mp4 renditions (_video_cache/) on the
-- stated assumption that "the traffic pattern actually observed in
-- production" was plain `/file?quality=` requests, not per-rendition HLS
-- fetches. That assumption no longer held -- confirmed live, videoQualityUrl
-- in utils/media.js unconditionally builds /hls/<quality>/playlist.m3u8 for
-- every quality including what used to be a raw mp4 link, and the iOS
-- client never requests a quality-specific mp4 either. The warmer was
-- therefore diligently keeping an entirely unread cache warm every pass
-- while the actual _hls_cache/ per-quality directories the player requests
-- stayed permanently cold except for "original" (the one rendition warmed
-- below regardless, since it has no size cap) -- reported live as "the
-- warmer should have finished by now, so why does every quality switch
-- still transcode." ensure_video_quality_cache/_video_cache itself is left
-- in place (M.serve_media_file still honors ?quality= if anything ever
-- calls it) -- only the warmer's target changed.
--
-- Runs as a slow, perpetual copas background coroutine, gated to the
-- primary worker only (see main.lua's is_primary_worker) -- every worker
-- shares the same on-disk cache, so a second worker warming in parallel
-- would just race the first one for the same slot files and cache paths
-- with zero benefit. Never claims the shared transcode slot itself: it only
-- ever asks ensure_hls_variant to do so, exactly like a live request would,
-- and backs off when none are free -- so foreground traffic and the warmer
-- draw from the exact same transcode.max_concurrent budget, never a
-- separate one.
--
-- 2026-09-01: the warmer additionally holds a slot from its OWN
-- (transcode.warmer.jobs_max = 1) pool for the duration of each job, so it
-- can never run more than one ffmpeg at a time. That is a ceiling ON TOP of
-- the shared budget, not a replacement for it and not a reservation out of
-- it: a viewer's on-demand transcode never touches the warm_N pool and is
-- never throttled by it. See the transcode.warmer table's header comment for
-- this and the three other brakes added at the same time.
-- ---------------------------------------------------------------------------

-- 2026-09-01: every pause lengthened substantially. The old values were
-- tuned for "catch a cold library up quickly," which is the wrong goal now
-- that the library is essentially fully warm and the only remaining work is
-- new uploads -- a trickle that a slow sweep absorbs perfectly well. Cost of
-- a pass is no longer the pass itself either (see transcode.warmer.variant_ready's
-- memo), so sweeping less often costs nothing and gives the box longer
-- uninterrupted stretches with no warmer activity at all.
local WARM_QUALITIES = { "480p", "720p", "1080p", "144p" }
local WARM_BATCH_SIZE = 25
local WARM_IDLE_PAUSE_SECONDS = 120   -- whole library scanned, nothing needs warming right now
local WARM_LAUNCH_PAUSE_SECONDS = 15  -- after actually launching one transcode
local WARM_BUSY_PAUSE_SECONDS = 60    -- backed off: busy pipeline, live viewer, or loaded box
local WARM_SCAN_PAUSE_SECONDS = 1.0   -- between cheap existence-checks (no launch happened)

-- True while any HLS variant is being actively streamed right now.
--
-- .last_watched is touched on every real playlist/segment request (see
-- M._touch_hls_heartbeat) and both hls.js and Safari's native engine keep
-- re-polling for as long as a player is attached, so a heartbeat fresher
-- than watch_idle_seconds IS "somebody is watching something." The warmer
-- stands down entirely in that case rather than competing for the GPU's one
-- shared video block -- brake (3) in the `transcode.warmer` table's header comment.
--
-- The one io.popen here (`find`, which does block the event loop for the
-- length of a directory scan like every shell-out in this file) is called
-- only immediately before an actual launch, never on the steady-state
-- "everything is already warm" passes -- those must stay fork-free, since
-- they are what runs essentially all of the time. -mmin rather than a
-- -newermt seconds expression: supported identically by every find
-- implementation, and minute granularity is plenty for "is anyone watching."
transcode.warmer.someone_is_watching = function()
  local minutes = math.max(1, math.ceil(transcode.warmer.watch_idle_seconds / 60))
  local handle = io.popen(string.format(
    "find %s -maxdepth 2 -name .last_watched -mmin -%d -print -quit 2>/dev/null",
    shell_quote(M.settings.uploads_dir .. "/_hls_cache"), minutes))
  if not handle then return false end
  local line = handle:read("*l")
  handle:close()
  return line ~= nil and line ~= ""
end

-- hls_variant_ready, memoized.
--
-- A finished variant is finished forever: its directory name is content-
-- addressed (hls_variant_dir hashes the source digest plus watermark text),
-- so any change to the underlying media yields a different directory rather
-- than invalidating this one, and the only thing that ever deletes a variant
-- directory is the stale-artifact sweep, which acts exclusively on variants
-- with a stale .pending marker -- i.e. never on a complete one. Nothing can
-- make a true answer here go false.
--
-- Worth memoizing because the uncached check opens and reads a whole
-- playlist.m3u8 (thousands of lines for a long video) and the warmer does
-- that for up to 5 variants on each of 25 items per pass -- ~125 blocking
-- reads, repeated forever, over a library that is already fully warm. That
-- constant background churn through the event loop serving live requests is
-- a large part of what "the warmer lags the site" actually was. Steady-state
-- passes now touch the disk for genuinely new work only.
--
-- Bounded so a very large library can't grow this without limit: past the
-- cap it simply starts over, trading one expensive sweep for a flat memory
-- ceiling. Deliberately warmer-local rather than shared with the request
-- path -- a viewer's own request should keep asking the filesystem.
--
-- The one thing that CAN falsify a memoized answer is somebody deleting a
-- variant directory out of band -- clearing cache by hand on the box, which
-- is a normal enough thing to do here (confirmed the hard way while testing
-- this change: a hand-deleted variant stayed un-rewarmed because the warmer
-- had memoized it as complete seconds earlier, and only a restart would have
-- noticed). So the memo also expires wholesale every revalidate_seconds,
-- which costs one honest full re-scan every 30 minutes instead of one on
-- every pass forever -- still ~99.9% of the savings, and the warmer
-- self-heals from an out-of-band deletion within half an hour rather than
-- never.
transcode.warmer.expire_ready_memo = function()
  local now = os.time()
  if now - transcode.warmer.ready_since >= transcode.warmer.revalidate_seconds then
    transcode.warmer.ready, transcode.warmer.ready_count = {}, 0
    transcode.warmer.ready_since = now
  end
end

transcode.warmer.variant_ready = function(dir)
  if transcode.warmer.ready[dir] then return true end
  if not hls_variant_ready(dir) then return false end
  if transcode.warmer.ready_count >= 5000 then
    transcode.warmer.ready, transcode.warmer.ready_count = {}, 0
    transcode.warmer.ready_since = os.time()
  end
  transcode.warmer.ready[dir] = true
  transcode.warmer.ready_count = transcode.warmer.ready_count + 1
  return true
end

-- Launches one warm transcode, or reports "busy" without launching.
--
-- The final two brakes are checked here, as late as possible -- immediately
-- before committing to a job -- so that the overwhelmingly common case (a
-- pass that finds nothing to warm) never pays for them.
transcode.warmer.try_launch = function(item, quality)
  if not transcode_slot_available() then return "busy" end
  if transcode.warmer.someone_is_watching() then return "busy" end
  ensure_hls_variant(item.id, item, function() return resolve_media_bytes(item) end, quality, {
    warmer = true,
    -- Lets ensure_hls_variant hardlink the original instead of reading the
    -- whole video through memory; see its own comment there. nil-safe: an
    -- item whose original is not on disk yet just takes the old path.
    -- The stored original itself (fast-disk tier or uploads drive), else
    -- the _original_cache copy -- see M._image_source_path.
    source_path = M._image_source_path(item),
  })
  return "launched"
end

-- One warming attempt over a small batch of media_items, ordered by id so
-- repeated calls sweep the whole library deterministically. Returns
-- ("wrap", cursor_id) when the batch is empty (reached the end -- caller
-- should restart from 0, which also naturally picks up new uploads),
-- ("launched", last_id) after starting exactly one real transcode job,
-- ("busy", last_id) if a cache miss was found but no slot was free, or
-- ("batch_done", last_id) if this whole batch was already fully warm.
-- Launching (or finding "busy") at most once per call, rather than
-- draining the whole batch in one pass, is what keeps this a gentle
-- trickle instead of a burst -- the driver loop below paces calls with its
-- own sleep between them.
--
-- BUGFIX 2026-08-31: confirmed live that this kept launching new GPU
-- transcode jobs even while the whole MACHINE (not just this Lua process)
-- was already severely oversubscribed -- caught mid-incident: load average
-- over 20 on this 8-core box, one ffmpeg job stuck 26+ minutes in
-- uninterruptible disk-wait, a worker process actually crashed with
-- systemd's own "timeout" result (killed mid-shutdown because a stuck
-- ffmpeg wouldn't exit), and completely unrelated endpoints like
-- /api/tags taking 13-14 SECONDS to respond. Moving transcoding to the
-- GPU (see vaapi_available's header comment) fixed the CPU-encode-
-- saturation failure mode this exact warmer hit before, but ffmpeg's
-- decode/filter/mux stages still run on the CPU, and concurrent jobs still
-- compete for disk I/O and memory with everything else sharing this box
-- (Postgres, Lavalink, a full desktop session) -- GPU offload was never
-- going to make THAT contention disappear. This is the one piece of the
-- whole transcoding pipeline that's pure nice-to-have (on-demand
-- transcoding for a real viewer already works fine standing alone) -- it
-- has no business adding load when the box is already struggling, so it
-- backs off entirely (reusing "busy"'s existing pacing) rather than
-- launching anything once 1-minute load average passes the core count.
-- Deliberately NOT touching acquire_transcode_slot/transcode.max_concurrent
-- -- that cap is shared with on-demand requests too, and a real viewer
-- waiting on their own video should never be throttled by the warmer's own
-- restraint. (Still true 2026-09-01: the warmer-only cap added then is a
-- SECOND, separate slot pool layered on top, so the shared cap of 2 that
-- viewers draw on is untouched.)
--
-- 2026-09-01: the load ceiling moved from a hard-coded 8 to transcode.warmer.max_load
-- (default 4), and a second, stricter gate joined it -- the shared transcode
-- pool has to be COMPLETELY idle, not merely non-full, before the warmer
-- adds anything to it. Both are brakes (4) and (2) in the `transcode.warmer` table's
-- header comment; the remaining two are applied at the launch itself, in
-- transcode.warmer.try_launch. Both checks here are deliberately fork-free (one
-- /proc/loadavg read, N io.opens on fixed slot paths) because they run on
-- every single pass forever, including the ones with nothing to do.
local function warm_one_pass(cursor_id)
  do
    local f = io.open("/proc/loadavg", "rb")
    local load = f and tonumber((f:read("*l") or ""):match("^(%S+)"))
    if f then f:close() end
    if load and load > transcode.warmer.max_load then return "busy", cursor_id end
  end
  if count_active_transcode_slots() > 0 then return "busy", cursor_id end
  transcode.warmer.expire_ready_memo()

  local rows = db.fetchall([[
    SELECT id, user_id, storage_path, mime_type, original_filename, file_size,
           media_kind, updated_at, created_at, content_sha256
    FROM media_items
    WHERE media_kind='video' AND deleted_at IS NULL AND id > %s
    ORDER BY id ASC
    LIMIT %s
  ]], tostring(cursor_id), tostring(WARM_BATCH_SIZE))

  if #rows == 0 then return "wrap", cursor_id end

  local last_id = cursor_id
  for _, item in ipairs(rows) do
    last_id = db.toint(item.id, item.id)
    item.id = last_id
    item.file_size = db.toint(item.file_size, 0)

    -- Needed by both the HLS quality loop below and the "original" check
    -- after it -- previously computed INSIDE the size-cap `if` below, which
    -- meant it was simply undefined (a stray global, effectively nil) for
    -- any item that skipped that block, silently corrupting the "original"
    -- HLS variant's cache path for every such item. Never actually
    -- triggered in production so far (every video happens to currently be
    -- both >0 bytes and under the 500MB cap), but would misfire the moment
    -- either condition wasn't true -- fixed by computing this once,
    -- unconditionally, for every item.
    local watermark_text = nil -- WATERMARKS_ENABLED = false (get_user lookup for it removed too)
    local digest_seed = (nn(item.content_sha256) or item.updated_at or item.created_at or tostring(item.id))
      .. "|wm=" .. tostring(watermark_text or "")

    -- Warms the HLS per-quality cache (_hls_cache/), which is what the live
    -- player actually requests -- videoQualityUrl() in utils/media.js always
    -- builds /hls/<quality>/playlist.m3u8, never /file?quality=, and the iOS
    -- app doesn't request a quality-specific mp4 either. This used to call
    -- ensure_video_quality_cache (the OLDER /file?quality= mp4 rendition
    -- path, still served on request but confirmed unreachable from any
    -- current client) instead, which meant this loop dutifully filled in
    -- _video_cache/ on every pass while HLS's own per-quality directories
    -- stayed permanently cold -- exactly the "warmer says it's done, but
    -- every quality switch still transcodes live" symptom reported live.
    -- ensure_hls_variant enforces the same size cap internally for anything
    -- other than "original", so the outer file_size check here is just
    -- avoiding the wasted cache-path computation/lookup for a request that
    -- would decline anyway, not a correctness requirement.
    if item.file_size > 0 and item.file_size <= VIDEO_TRANSCODE_SIZE_LIMIT then
      for _, quality in ipairs(WARM_QUALITIES) do
        local hls_dir = hls_variant_dir(item.id, quality, digest_seed)
        if not transcode.warmer.variant_ready(hls_dir) then
          return transcode.warmer.try_launch(item, quality), last_id
        end
      end
    end

    -- Original HLS is a remux and deliberately has no size cap. Warm it for
    -- large uploads too, otherwise those videos always begin with a cold
    -- playlist even though this rendition does not require re-encoding.
    local hls_dir = hls_variant_dir(item.id, "original", digest_seed)
    if not transcode.warmer.variant_ready(hls_dir) then
      return transcode.warmer.try_launch(item, "original"), last_id
    end
  end

  return "batch_done", last_id
end

-- Image rendition warmer (2026-10-26). Pre-renders, for every image post,
-- the three sizes the site requests -- grid thumb (640), lightbox thumb
-- (1280) and detail preview (1920) -- in ONE ffmpeg decode, so the first
-- visitor never waits on a cold render. Recent uploads (last 15 minutes)
-- are checked first on every round; the rest of the library is walked
-- newest -> oldest, one image at a time, at the lowest CPU/IO priority, and
-- the warmer backs off whenever the machine is busy (the music bots share
-- this host). GALLERY_ENABLE_IMAGE_WARMER=false turns it off.
function M._image_renditions_missing(item)
  local wanted = {
    { dst = M._image_thumb_cache_path(item.id, M._GRID_THUMB_WIDTH), max_edge = M._GRID_THUMB_WIDTH, quality = 84 },
    { dst = M._image_thumb_cache_path(item.id, M._LIGHTBOX_THUMB_WIDTH), max_edge = M._LIGHTBOX_THUMB_WIDTH, quality = 84 },
    { dst = M._preview_cache_path(item.id, item, "detail"), max_edge = M._PREVIEW_SIZES.detail[1], quality = M._PREVIEW_SIZES.detail[2] },
  }
  local missing = {}
  for _, o in ipairs(wanted) do
    local f = io.open(o.dst, "rb")
    if f then f:close() else missing[#missing + 1] = o end
  end
  return missing
end

function M._system_busy()
  local f = io.open("/proc/loadavg", "rb")
  if not f then return false end
  local load1 = tonumber((f:read("*l") or ""):match("^(%S+)"))
  f:close()
  if not M._ncpu then
    local n = 0
    local c = io.open("/proc/cpuinfo", "rb")
    if c then
      for line in c:lines() do if line:match("^processor") then n = n + 1 end end
      c:close()
    end
    M._ncpu = math.max(1, n)
  end
  return load1 ~= nil and load1 > M._ncpu * 0.7
end

-- Renders whatever is missing for one image row. Returns number rendered.
function M._warm_image_renditions(item)
  if is_gif_media(item) then return 0 end
  local missing = M._image_renditions_missing(item)
  if #missing == 0 then return 0 end
  local src = M._image_source_path(item)
  if not src then return 0 end
  for _, o in ipairs(missing) do
    local dir = o.dst:match("^(.*)/[^/]+$")
    if dir then os.execute("mkdir -p " .. shell_quote(dir)) end
  end
  local cmd, finish = media_files.render_webp_multi_cmd(src, missing, {
    prefix = "nice -n 19 ionice -c3 " .. media_files.ffmpeg_bin() .. " -threads 2 -filter_complex_threads 1",
  })
  require("blockwatch").execute_yielding(cmd, { uncapped = true })
  local rendered = 0
  for _, ok in ipairs(finish()) do if ok then rendered = rendered + 1 end end
  return rendered
end

function M.start_image_rendition_warmer()
  local copas = require("copas")
  local COLUMNS = "m.id, m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.created_at, m.updated_at"
  local BASE_WHERE = "m.media_kind = 'image' AND m.deleted_at IS NULL"
  copas.addthread(function()
    copas.sleep(30) -- let a fresh restart settle first
    local cursor = nil
    local rendered_total, pass_started = 0, os.time()
    local function warm_rows(rows)
      for _, row in ipairs(rows) do
        row.id = db.toint(row.id, row.id)
        while M._system_busy() do copas.sleep(20) end
        local ok, n = pcall(M._warm_image_renditions, row)
        if not ok then
          print("[nyxframe] image warmer: media " .. tostring(row.id) .. " failed: " .. tostring(n))
        elseif n > 0 then
          rendered_total = rendered_total + n
          if rendered_total % 150 < n then
            print(string.format("[nyxframe] image warmer: %d renditions so far this pass", rendered_total))
          end
          copas.sleep(0.25)
        end
      end
    end
    while true do
      local t0 = M.telemetry.now()
      local ok, err = pcall(function()
        -- Fresh uploads first, every round.
        local recent = db.fetchall("SELECT " .. COLUMNS .. " FROM media_items m WHERE " .. BASE_WHERE
          .. " AND m.created_at > now() - interval '15 minutes' ORDER BY m.id DESC LIMIT 50")
        warm_rows(recent or {})
        local rows
        if cursor then
          rows = db.fetchall("SELECT " .. COLUMNS .. " FROM media_items m WHERE " .. BASE_WHERE
            .. " AND m.id < %s ORDER BY m.id DESC LIMIT 25", tostring(cursor))
        else
          rows = db.fetchall("SELECT " .. COLUMNS .. " FROM media_items m WHERE " .. BASE_WHERE
            .. " ORDER BY m.id DESC LIMIT 25")
        end
        rows = rows or {}
        if #rows == 0 then
          if rendered_total > 0 then
            print(string.format("[nyxframe] image warmer: pass done, %d renditions in %ds", rendered_total, os.time() - pass_started))
          end
          M.telemetry.job_result("image_warmer", true, M.telemetry.ms_since(t0), { event = "pass_done", rendered = rendered_total })
          cursor, rendered_total, pass_started = nil, 0, os.time()
          copas.sleep(60)
          return
        end
        warm_rows(rows)
        cursor = db.toint(rows[#rows].id, rows[#rows].id)
      end)
      if not ok then
        print("[nyxframe] image warmer error: " .. tostring(err))
        M.telemetry.job_result("image_warmer", false, M.telemetry.ms_since(t0), { error = tostring(err):sub(1, 300) })
        copas.sleep(30)
      else
        copas.sleep(0.5)
      end
    end
  end)
end

-- Starts the transcode.warmer. Call once from main.lua, already gated to the primary
-- worker there. A pcall around each pass means one bad row or a transient
-- filesystem error logs and backs off instead of ever killing the
-- coroutine (and, since this runs inside the same process as request
-- serving, instead of ever taking the whole worker down with it).
function M.start_media_warmer()
  local copas = require("copas")
  copas.addthread(function()
    local cursor = 0
    while true do
      local telemetry_t0 = M.telemetry.now()
      local ok, status, next_cursor = pcall(warm_one_pass, cursor)
      local telemetry_ms = M.telemetry.ms_since(telemetry_t0)
      if not ok then
        print("[nyxframe] media warmer error: " .. tostring(status))
        M.telemetry.job_result("media_warmer", false, telemetry_ms, { error = tostring(status):sub(1, 300) })
        copas.sleep(WARM_IDLE_PAUSE_SECONDS)
      elseif status == "wrap" then
        M.telemetry.job_result("media_warmer", true, telemetry_ms, nil)
        cursor = 0
        copas.sleep(WARM_IDLE_PAUSE_SECONDS)
      elseif status == "busy" then
        M.telemetry.job_result("media_warmer", true, telemetry_ms, nil)
        cursor = next_cursor or cursor
        copas.sleep(WARM_BUSY_PAUSE_SECONDS)
      elseif status == "launched" then
        -- The one outcome worth a durable row: an actual transcode got
        -- kicked off, distinguishing "warmer is idle" from "warmer is doing
        -- real CPU/GPU work right now" on the admin panel.
        M.telemetry.job_result("media_warmer", true, telemetry_ms, { event = "launched", cursor = next_cursor })
        cursor = next_cursor or cursor
        copas.sleep(WARM_LAUNCH_PAUSE_SECONDS)
      else -- "batch_done": nothing to launch in this batch, keep sweeping forward briskly
        M.telemetry.job_result("media_warmer", true, telemetry_ms, nil)
        cursor = next_cursor or cursor
        copas.sleep(WARM_SCAN_PAUSE_SECONDS)
      end
    end
  end)
end

-- Sweeps _video_cache/_hls_cache/_upload_tmp for stale partial-transcode
-- artifacts left behind when an ffmpeg job died without cleaning up after
-- itself -- crash, OOM-kill, or this service getting restarted mid-encode
-- (systemd's default KillMode=control-group tears the detached child down
-- along with the worker; see ensure_hls_variant's/ensure_video_quality_
-- cache's own header comments on this exact failure mode). ensure_hls_
-- variant self-heals a stale HLS variant, but only the next time someone
-- actually requests that exact quality again -- a variant nobody ever
-- re-requests just sits there forever. ensure_video_quality_cache has NO
-- self-heal at all: every attempt writes a freshly-randomly-suffixed
-- .src.bin/.tmp.mp4 pair and has no way to notice (let alone clean up) an
-- older pair left behind by a previous killed attempt.
--
-- Confirmed live 2026-08-31: ~1.5GB of exactly this garbage sitting in
-- _video_cache from several worker restarts earlier the same day, none of
-- it caught by the existing admin-triggered walk_cache_dir/
-- admin_purge_storage_orphans pair above -- that sweep only catches cache
-- files for media that's been DELETED; these are for media that's still
-- very much alive, just an interrupted encode attempt.
--
-- Its own background pass (not piggybacked onto the media warmer's loop)
-- so it keeps running even with GALLERY_ENABLE_MEDIA_WARMER=false (see
-- main.lua's BUGFIX 2026-08-26 comment on why that exists) -- an
-- interrupted encode's leftovers should get swept regardless of whether
-- proactive warming is turned on. Call once from main.lua, same
-- primary-worker gate as the warmer (every worker shares the same on-disk
-- cache, so running this in more than one would just have them race each
-- other over the same files for no benefit).
function M.start_stale_transcode_cleanup()
  local copas = require("copas")
  local SWEEP_INTERVAL_SECONDS = 30 * 60
  -- Deliberately still longer than VIDEO_TRANSCODE_PENDING_STALE_SECONDS
  -- (30 min as of 2026-08-31 -- used to decide whether an incoming
  -- REQUEST should wait vs. relaunch, or whether the global concurrency
  -- count still trusts a slot) -- this decides whether to actually DELETE
  -- files, so it has to stay comfortably clear of the longest any real
  -- encode should ever take, not just the window a client's poll loop
  -- waits on. The longest real encode confirmed live so far (a 12-minute
  -- 1080p60 watermarked original, CPU path, heavy contention) was ~10
  -- minutes; an hour leaves wide margin even for a much larger
  -- unwatermarked-but-still-re-encoded original with no size cap.
  local MIN_AGE_SECONDS = 60 * 60

  local function remove_stale_by_pattern(dir, name_pattern)
    local removed, freed = 0, 0
    local now = os.time()
    local handle = io.popen(string.format(
      "find %s -maxdepth 1 -type f -name %s -printf '%%T@ %%s %%p\\n' 2>/dev/null",
      shell_quote(dir), shell_quote(name_pattern)
    ))
    if not handle then return removed, freed end
    for line in handle:lines() do
      local mtime_str, size_str, path = line:match("^(%S+) (%d+) (.+)$")
      local mtime = tonumber(mtime_str)
      if mtime and (now - mtime) > MIN_AGE_SECONDS then
        if os.remove(path) then
          removed = removed + 1
          freed = freed + (tonumber(size_str) or 0)
        end
      end
    end
    handle:close()
    return removed, freed
  end

  local function sweep_once()
    local removed, freed = 0, 0

    for _, pattern in ipairs({ "*.pending", "*.src.*.bin", "*.tmp.*.mp4" }) do
      local r, f = remove_stale_by_pattern(M.settings.uploads_dir .. "/_video_cache", pattern)
      removed, freed = removed + r, freed + f
    end

    -- fast_start_remux_if_needed always cleans up its own scratch files on
    -- every return path -- these can only accumulate if the whole worker
    -- process died mid-upload, so this is defense-in-depth, not the
    -- expected common case the way _video_cache's leftovers are.
    for _, pattern in ipairs({ "*.src", "*.out" }) do
      local r, f = remove_stale_by_pattern(M.settings.uploads_dir .. "/_upload_tmp", pattern)
      removed, freed = removed + r, freed + f
    end

    -- _hls_cache: a stale .pending marker's sibling is a whole DIRECTORY
    -- (segments + playlist.m3u8), not a single file -- same "not ready,
    -- previous encoder died" condition ensure_hls_variant itself checks
    -- for and self-heals on next request, just proactive here instead of
    -- waiting for one that may never come.
    local hls_dir = M.settings.uploads_dir .. "/_hls_cache"
    local now = os.time()
    local handle = io.popen(string.format(
      "find %s -maxdepth 1 -type f -name '*.pending' -printf '%%T@ %%p\\n' 2>/dev/null",
      shell_quote(hls_dir)
    ))
    if handle then
      for line in handle:lines() do
        local mtime_str, marker_path = line:match("^(%S+) (.+)$")
        local mtime = tonumber(mtime_str)
        local variant_dir = marker_path and marker_path:match("^(.*)%.pending$")
        if mtime and variant_dir and (now - mtime) > MIN_AGE_SECONDS and not hls_variant_ready(variant_dir) then
          local du = io.popen(string.format("du -sb %s 2>/dev/null", shell_quote(variant_dir)))
          local dir_bytes = 0
          if du then
            local dline = du:read("*l")
            dir_bytes = dline and tonumber(dline:match("^(%d+)")) or 0
            du:close()
          end
          os.execute("rm -rf " .. shell_quote(variant_dir))
          os.remove(marker_path)
          removed = removed + 1
          freed = freed + dir_bytes
        end
      end
      handle:close()
    end

    return removed, freed
  end

  copas.addthread(function()
    while true do
      local telemetry_t0 = M.telemetry.now()
      local ok, removed_or_err, freed = pcall(sweep_once)
      local telemetry_ms = M.telemetry.ms_since(telemetry_t0)
      if not ok then
        print("[nyxframe] stale transcode cleanup error: " .. tostring(removed_or_err))
        M.telemetry.job_result("stale_transcode_cleanup", false, telemetry_ms, { error = tostring(removed_or_err):sub(1, 300) })
      elseif removed_or_err and removed_or_err > 0 then
        print(string.format("[nyxframe] stale transcode cleanup: removed %d item(s), freed %d bytes", removed_or_err, freed or 0))
        M.telemetry.job_result("stale_transcode_cleanup", true, telemetry_ms, { removed = removed_or_err, freed_bytes = freed or 0 })
      else
        M.telemetry.job_result("stale_transcode_cleanup", true, telemetry_ms, nil)
      end
      copas.sleep(SWEEP_INTERVAL_SECONDS)
    end
  end)
end

-- Reclaims a transcode slot early when the viewer who caused it to launch
-- has actually left, instead of waiting out the full encode (up to ~10
-- minutes on the longest real one observed) or the 30-minute crash-orphan
-- sweep above. Confirmed live as the actual mechanism behind "click off a
-- video, then anything else that needs a fresh transcode is slow to load":
-- transcode.max_concurrent is a global cap of 2 for the entire site, so
-- one or two abandoned-but-still-running encodes can fully starve every
-- other viewer's (or the same viewer's next video's) cold-cache request
-- for as long as those jobs keep running with nobody watching.
--
-- Deliberately does NOT touch a variant with no .last_watched heartbeat at
-- all -- that's the media warmer's own pre-warm (see start_media_warmer's
-- header comment: it explicitly launches the HLS "original" remux ahead of
-- any real viewer), which must be allowed to run to completion regardless
-- of whether anyone's watching yet. Only a variant that WAS being watched
-- (heartbeat exists -- touch_hls_heartbeat only ever gets called from a
-- real playlist/segment request) and has since gone idle counts as
-- abandoned.
--
-- Short sweep interval (contrast the 30-minute one above, which only ever
-- needs to catch genuinely-crashed jobs): the whole point is reclaiming a
-- slot within tens of seconds of real abandonment, not eventually.
function M.start_hls_idle_reaper()
  local copas = require("copas")
  local SWEEP_INTERVAL_SECONDS = 10
  -- Generous enough that normal hls.js/native live-playlist re-poll gaps
  -- (typically well under HLS_SEGMENT_SECONDS=6s while a player is actually
  -- attached) never look like abandonment, even accounting for a slow
  -- connection or a backgrounded-but-still-open tab throttling timers.
  local IDLE_SECONDS = 25

  local function reap_once()
    local reaped = 0
    local now = os.time()
    local hls_dir = M.settings.uploads_dir .. "/_hls_cache"
    -- 2026-09-01: a warm job already in flight when viewers turn up used to
    -- keep running to completion, and for a big rendition that is minutes of
    -- GPU and disk contention against live playback. Confirmed by load test:
    -- the warmer's brakes stop it LAUNCHING while anyone is watching, but
    -- warm_1 stayed held for a whole 8-viewer run that started just after a
    -- job did, and segment p95 suffered for it. Checked once per sweep, and
    -- only when something might actually need stopping.
    local viewers_present = nil

    -- Don't reap an encode that has barely started.
    --
    -- 2026-09-01, caught live on a fully cold media 621 (an 11 minute
    -- 1080p60 source): the request launches the encode, waits for a first
    -- segment, gives up, and returns "still starting up". The viewer's single
    -- request is then 25 seconds old, so the reaper kills the job -- and the
    -- next request starts the whole thing over from zero. A cold video with
    -- no warm rendition to fall back on could therefore NEVER become
    -- playable, no matter how many times it was requested; every attempt was
    -- killed in its first half minute. Observed exactly that loop three times
    -- in a row in the journal.
    --
    -- A grace period comfortably longer than the request's own wait budget
    -- means the first viewer's attempt always survives long enough to produce
    -- something, even when they gave up. Abandonment of a LONG-running
    -- encode -- the case this reaper exists for -- is unaffected, since those
    -- are minutes old by the time anyone clicks away.
    local STARTUP_GRACE_SECONDS = 90
    local function just_launched(dir)
      local pf = io.open(dir .. ".pending", "rb")
      local launched = pf and tonumber((pf:read("*a") or ""):match("%d+")) or nil
      if pf then pf:close() end
      return launched ~= nil and (now - launched) < STARTUP_GRACE_SECONDS
    end

    -- Don't throw away an encode that is nearly finished.
    --
    -- 2026-09-01: caught live -- a viewer triggered a cold 1080p, made one
    -- request, and left; 25s later the reaper killed the job at 52s of a 62s
    -- video. 84% of the work discarded, and since a truncated variant is
    -- (correctly) no longer cached, the whole thing has to be redone from
    -- scratch the next time anyone asks. Reclaiming a slot from a job that
    -- is seconds from releasing it on its own gains nothing and costs the
    -- entire encode. The abandonment case this reaper exists for -- a viewer
    -- clicking off a long encode that has barely started -- is unaffected.
    --
    -- Only consulted for a variant already known to be still encoding, so
    -- this reads a playlist that the sweep would be reading anyway.
    local function nearly_done(dir)
      local ef = io.open(dir .. "/.expected_duration", "rb")
      local expected = ef and tonumber((ef:read("*a") or ""):match("[%d%.]+")) or nil
      if ef then ef:close() end
      if not expected or expected <= 0 then return false end
      local pf2 = io.open(dir .. "/playlist.m3u8", "rb")
      if not pf2 then return false end
      local text = pf2:read("*a") or ""
      pf2:close()
      local done = 0
      for d in text:gmatch("#EXTINF:([%d%.]+)") do done = done + (tonumber(d) or 0) end
      return done >= expected * 0.8
    end
    local handle = io.popen(string.format("find %s -mindepth 1 -maxdepth 1 -type d 2>/dev/null", shell_quote(hls_dir)))
    if not handle then return reaped end
    for dir in handle:lines() do
      -- hls_variant_ready (has #EXT-X-ENDLIST) means the encode already
      -- finished on its own -- nothing to reap regardless of heartbeat age.
      if not hls_variant_ready(dir) then
        local pf = io.open(dir .. "/.pid", "rb")
        local pid = pf and tonumber(pf:read("*a")) or nil
        if pf then pf:close() end
        local hb = io.open(dir .. "/.last_watched", "rb")
        local last_watched = hb and tonumber(hb:read("*a")) or nil
        if hb then hb:close() end
        -- A still-encoding variant with a .pid but NO heartbeat file at all
        -- is the media warmer's own pre-warm (nobody has ever requested it).
        -- It used to be left strictly alone. It still is while the site is
        -- idle -- that is the whole point of pre-warming -- but not while
        -- somebody is actually watching something: a viewer's playback beats
        -- speculative work for a video nobody has asked for. Stopping it is
        -- safe in a way it was NOT before today: hls_variant_ready now
        -- rejects a truncated encode on duration rather than caching it, so
        -- the partial output is discarded and the warmer simply redoes it in
        -- the next idle window (its launch gate already requires two minutes
        -- with nobody watching, so this cannot thrash tightly). The cost is
        -- repeating that work; the alternative is degrading live playback,
        -- which is the thing the warmer is explicitly not allowed to do.
        local warm_marker = io.open(dir .. "/.warm", "rb")
        local is_prewarm = warm_marker ~= nil
        if warm_marker then warm_marker:close() end
        if pid and not last_watched and is_prewarm then
          if viewers_present == nil then
            viewers_present = transcode.warmer.someone_is_watching()
          end
          if viewers_present then
            local cf = io.open("/proc/" .. tostring(pid) .. "/cmdline", "rb")
            local cmdline = cf and cf:read("*a") or ""
            if cf then cf:close() end
            if cmdline:find("ffmpeg", 1, true) then
              local exit = os.execute("kill -TERM " .. tostring(pid) .. " 2>/dev/null")
              if exit == 0 or exit == true then reaped = reaped + 1 end
            end
          end
        elseif pid and last_watched and (now - last_watched) > IDLE_SECONDS
               and not just_launched(dir) and not nearly_done(dir) then
          -- Guard against PID reuse (the OS handing this exact number to
          -- an unrelated process between ffmpeg exiting and this sweep
          -- running): only proceed if /proc still shows this PID as an
          -- actual ffmpeg process. Linux-only, same assumption this whole
          -- section already makes (VAAPI device paths, nice/ionice, etc).
          local cf = io.open("/proc/" .. tostring(pid) .. "/cmdline", "rb")
          local cmdline = cf and cf:read("*a") or ""
          if cf then cf:close() end
          if cmdline:find("ffmpeg", 1, true) then
            -- kill's own exit status doubles as "was it actually still
            -- alive" -- nonzero (process already gone) just isn't counted,
            -- no separate kill -0 pre-check needed. SIGTERM, not -9: lets
            -- ffmpeg tear down cleanly (close the VAAPI device/file
            -- handles) rather than risking a leaked GPU context.
            local exit = os.execute("kill -TERM " .. tostring(pid) .. " 2>/dev/null")
            if exit == 0 or exit == true then reaped = reaped + 1 end
          end
        end
      end
    end
    handle:close()
    return reaped
  end

  copas.addthread(function()
    while true do
      local telemetry_t0 = M.telemetry.now()
      local ok, reaped_or_err = pcall(reap_once)
      local telemetry_ms = M.telemetry.ms_since(telemetry_t0)
      if not ok then
        print("[nyxframe] hls idle reaper error: " .. tostring(reaped_or_err))
        M.telemetry.job_result("hls_idle_reaper", false, telemetry_ms, { error = tostring(reaped_or_err):sub(1, 300) })
      elseif reaped_or_err and reaped_or_err > 0 then
        print(string.format("[nyxframe] hls idle reaper: stopped %d abandoned transcode(s)", reaped_or_err))
        M.telemetry.job_result("hls_idle_reaper", true, telemetry_ms, { reaped = reaped_or_err })
      else
        M.telemetry.job_result("hls_idle_reaper", true, telemetry_ms, nil)
      end
      copas.sleep(SWEEP_INTERVAL_SECONDS)
    end
  end)
end

-- Builds the query string to propagate onto sub-resource URLs (master
-- playlist -> per-quality playlist -> segments), so a viewer who only
-- authenticated via ?access= or ?key= on the FIRST request stays
-- authenticated through the rest of the chain -- relative-URL resolution
-- doesn't inherit a parent playlist's query string on its own, and a
-- <video> tag/HLS player can't attach custom headers to the sub-requests
-- it makes. ?access= (the narrower, single-post capability token) wins if
-- both are somehow present.
local function hls_propagated_qs(req)
  local access = req.query and nn(req.query.access)
  if access then return "?access=" .. access end
  local key = req.query and nn(req.query.key)
  if key then return "?key=" .. key end
  return nil
end

-- fetch_media_by_id joins categories/subcategories/users and aggregates
-- likes/comments/bookmarks with 3 COUNT DISTINCTs -- built for rendering a
-- post's full detail view, not for an auth check. hls_check_access runs on
-- EVERY segment request (every ~6s of playback, per viewer, per active
-- stream) as well as every playlist load, so on a public gallery with
-- several people streaming at once that heavy query was firing constantly
-- for no reason -- none of the joined/aggregated columns are used past
-- this function. This lean, join-free query carries only what
-- hls_check_access/ensure_hls_variant/resolve_media_bytes/serve_hls_segment
-- actually read.
local function fetch_media_stream_row(media_id)
  return db.fetchone([[
    SELECT id, user_id, media_kind, mime_type, original_filename, storage_path, file_size,
           created_at, updated_at, visibility, is_adult, deleted_at, content_sha256
    FROM media_items WHERE id = %s
  ]], tostring(media_id))
end

-- Shared by all three HLS routes below: 404s (not 403 -- matches this
-- file's "don't leak existence" convention elsewhere) on anything that
-- would also 404/403 through the regular file-serving path.
local function hls_check_access(req, media_id)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local item = fetch_media_stream_row(media_id)
  if not item or nn(item.deleted_at) ~= nil then return nil, 404, { detail = "Media not found." } end
  item.is_adult = db.tobool(item.is_adult)
  local owner = viewer_id and tostring(item.user_id) == tostring(viewer_id)
  if item.visibility == "private" and not private_file_allowed(media_id, req.query.access, owner) then
    return nil, 403, { detail = "This post is private." }
  end
  if item.is_adult and not adult_file_allowed(req, media_id, req.query.access, viewer_id) then
    return nil, 403, { detail = "Age verification required for this 18+ post." }
  end
  if item.media_kind ~= "video" then return nil, 404, { detail = "Not a video." } end

  -- 4th return: whether THIS request's success is safe to hand to a
  -- SHARED/public cache (a CDN, a corporate proxy, anything that isn't
  -- this one requester's own browser) that would replay the identical
  -- cached response to any later requester of the same URL, auth or not.
  -- That's only true when nothing about WHO is asking affected the outcome
  -- above: visibility isn't private (private posts can succeed purely via
  -- session/owner identity, `private_file_allowed`'s `owner` branch, which
  -- never appears in the URL), and for an adult post specifically, THIS
  -- request's own access token -- not session-based age verification via
  -- `viewer_adult_allowed`, which is exactly as session-bound as the owner
  -- check above -- is what let it through. Get this wrong in the permissive
  -- direction and a shared cache could serve one logged-in viewer's
  -- successful private/adult response to a later unauthorized requester of
  -- the identical URL; wrong in the conservative direction just forgoes a
  -- caching opportunity, so callers should treat this as default-false.
  local access = req.query.access
  local valid_access_token = access ~= nil and access ~= "" and access == gauth.media_access_token(M.settings.session_secret, media_id)
  local publicly_cacheable = item.visibility ~= "private" and (not item.is_adult or valid_access_token)
  return item, nil, nil, publicly_cacheable
end

local HLS_BANDWIDTH_BY_QUALITY = { ["1080p"] = 5000000, ["720p"] = 2800000, ["480p"] = 1400000, ["144p"] = 300000 }

function M.serve_hls_master(req)
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local item, status, body, publicly_cacheable = hls_check_access(req, media_id)
  if not item then return status, body end

  local access_qs = hls_propagated_qs(req) or ""
  local lines = { "#EXTM3U", "#EXT-X-VERSION:6" }
  -- Original first: no re-encode needed (fast remux), so it's always the
  -- quickest to become available and is a sane default rendition even
  -- for a source too large to offer any transcoded quality for.
  lines[#lines + 1] = '#EXT-X-STREAM-INF:BANDWIDTH=8000000,NAME="Original"'
  lines[#lines + 1] = string.format("/api/media/%d/hls/original/playlist.m3u8%s", media_id, access_qs)
  for _, quality in ipairs({ "1080p", "720p", "480p", "144p" }) do
    lines[#lines + 1] = string.format('#EXT-X-STREAM-INF:BANDWIDTH=%d,NAME="%s"', HLS_BANDWIDTH_BY_QUALITY[quality], quality)
    lines[#lines + 1] = string.format("/api/media/%d/hls/%s/playlist.m3u8%s", media_id, quality, access_qs)
  end
  -- This list of quality URLs is the same for a given media_id regardless
  -- of encode progress, so (unlike the per-quality playlist below) there's
  -- no readiness check to gate on -- only the access-safety one.
  return 200, table.concat(lines, "\n") .. "\n", {
    ["Content-Type"] = "application/vnd.apple.mpegurl",
    ["Cache-Control"] = publicly_cacheable and "public, max-age=31536000, immutable" or "no-cache",
  }
end

-- Touched on every real playlist/segment request for a variant -- both
-- hls.js and Safari's native engine keep re-polling a still-growing (no
-- #EXT-X-ENDLIST) playlist and fetching new segments on their own timers
-- for as long as a player instance is actually attached, so this file's
-- mtime staying fresh IS the "someone is still watching" signal.
-- M.start_hls_idle_reaper below is the only reader -- a still-encoding
-- variant with no heartbeat file at all (the media warmer's own pre-warm,
-- launched with nobody watching yet) is left alone; one whose heartbeat has
-- gone stale (a real viewer clicked away) is what gets reaped early.
function M._touch_hls_heartbeat(dir)
  local f = io.open(dir .. "/.last_watched", "wb")
  if f then
    f:write(tostring(os.time()))
    f:close()
  end
end

function M.serve_hls_playlist(req)
  local media_id = tonumber(req.params.media_id)
  local quality = normalize_video_quality(req.params.quality)
  if not media_id then return 404, { detail = "Media not found." } end
  local item, status, body, publicly_cacheable = hls_check_access(req, media_id)
  if not item then return status, body end

  -- source_path (2026-09-01): the same hardlink fast path the media warmer
  -- uses, now on the viewer path too -- this is the cold-start case, and it
  -- was reading the entire video (up to 500MB) into a Lua string and writing
  -- every byte back out to source.bin, blocking the event loop that serves
  -- every other request for the whole of it. It is a metadata operation now.
  -- Falls back to content_fn exactly as before when the original is not
  -- already cached on disk.
  -- Best rendition that is ALREADY complete and playable right now, or nil.
  --
  -- 2026-09-01: every "can't serve this quality yet" branch below used to
  -- end in either a 503 or a 302 to `original`, and for this library both are
  -- close to the worst possible answer. The big posts are 200-450MB, and
  -- because the owner sets a watermark even `original` is a full re-encode
  -- rather than a remux -- so a cold `original` is minutes of GPU work, and
  -- redirecting a stuck viewer TO it (the old "busy" behaviour) sent them to
  -- the single most expensive rendition on the site. Meanwhile the ladder
  -- below it is usually sitting on disk fully warmed: when media 663's
  -- original and 1080p were rebuilding, its 144p/480p/720p were all complete.
  -- So: hand the viewer the best thing that actually exists and let the
  -- requested quality finish warming in the background. Playing immediately
  -- one tier down beats a spinner and a retry loop.
  --
  -- Prefers the closest quality BELOW the requested one (a viewer who asked
  -- for 1080p would rather have 720p than 144p), then falls back upward.
  -- Costs at most four `.verified` opens -- see hls_variant_ready's fast
  -- path -- and only ever runs on a branch that was about to fail anyway.
  local function best_ready_quality()
    local ladder = { "144p", "480p", "720p", "1080p", "original" }
    local wm = nil -- WATERMARKS_ENABLED = false (get_user lookup for it removed too)
    local seed = media_content_digest_seed(media_id, item, wm)
    local at = nil
    for i, q in ipairs(ladder) do if q == quality then at = i break end end
    local order = {}
    for i = (at or #ladder) - 1, 1, -1 do order[#order + 1] = ladder[i] end
    for i = (at or 0) + 1, #ladder do order[#order + 1] = ladder[i] end
    for _, q in ipairs(order) do
      if hls_variant_ready(hls_variant_dir(media_id, q, seed)) then return q end
    end
    return nil
  end

  local dir, err = ensure_hls_variant(media_id, item, function() return resolve_media_bytes(item) end, quality, {
    source_path = M._image_source_path(item),
  })
  if not dir then
    if err == "missing" then return 404, { detail = "File is missing." } end
    -- "busy" (see acquire_transcode_slot) means the transcode queue is
    -- full, not that this quality doesn't exist -- 503 + Retry-After so a
    -- player/client can distinguish "try again shortly" from "give up and
    -- fall back to another quality permanently".
    if err == "busy" then
      -- Was: an unconditional 302 to `original` for any non-original
      -- quality. On this library that redirected a viewer from a rendition
      -- that merely needed a slot onto the most expensive encode on the
      -- site, which is very often not warm either -- so the redirect just
      -- moved the stall. Send them to something genuinely ready instead.
      local ready_q = best_ready_quality()
      if ready_q and ready_q ~= quality then
        local fallback_qs = hls_propagated_qs(req) or ""
        return 302, "", {
          ["Location"] = string.format("/api/media/%d/hls/%s/playlist.m3u8%s", media_id, ready_q, fallback_qs),
          ["Cache-Control"] = "no-store",
        }
      end
      return 503, { detail = "Server is busy transcoding other videos right now. Try again in a few seconds." }, { ["Retry-After"] = "5" }
    end
    -- "gpu_unavailable" (see ensure_hls_variant/vaapi_available): this
    -- quality needs a real re-encode and there's deliberately no CPU
    -- fallback anymore, so a missing/broken GPU means exactly this
    -- instead of silently falling back to the CPU-heavy path that caused
    -- the 2026-08-26 incident. Distinct message from the generic 404
    -- below since this is an infra condition, not a fact about the file.
    -- Retry-After longer than the "busy" case's 5s: vaapi_available()
    -- already spent ~2s retrying internally before returning this, so
    -- getting here at all means the condition survived that -- more
    -- likely a sustained outage than a one-off blip, worth a longer gap
    -- before a client (or hls.js's own retry loop) tries again.
    if err == "gpu_unavailable" then
      -- An already-encoded rendition needs no GPU to serve, so a GPU outage
      -- should not stop playback of a video that is partly warmed.
      local ready_q = best_ready_quality()
      if ready_q and ready_q ~= quality then
        local fallback_qs = hls_propagated_qs(req) or ""
        return 302, "", {
          ["Location"] = string.format("/api/media/%d/hls/%s/playlist.m3u8%s", media_id, ready_q, fallback_qs),
          ["Cache-Control"] = "no-store",
        }
      end
      return 503, { detail = "Video transcoding hardware is temporarily unavailable. Try again later." }, { ["Retry-After"] = "15" }
    end
    return 404, { detail = "This quality is not available for this video." }
  end

  -- Bounded, yielding wait for the first segment(s): a cold cache means
  -- the background ffmpeg job was JUST launched a moment ago by the call
  -- above, so the playlist file may not have its first #EXTINF entry
  -- written yet. copas.sleep yields to the scheduler on each iteration
  -- (confirmed: coroutine_yield under the hood) so other in-flight
  -- requests are serviced during this wait, unlike the multi-minute
  -- fully-synchronous transcode this replaces.
  -- ffmpeg writes segment lines as bare relative filenames ("seg_00000.ts")
  -- with no awareness of the request's own ?access= token -- fine for a
  -- non-adult video (M.serve_hls_segment only checks that token when
  -- item.is_adult), but an adult-gated post needs every segment request
  -- to carry it too, and relative-URL resolution doesn't inherit a
  -- parent playlist's query string. Rewritten here rather than relying on
  -- AVURLAssetHTTPHeaderFieldsKey propagating to segment requests, which
  -- this app has already hit real inconsistency with for redirects/Range
  -- requests -- and web's plain <video> tag can't attach custom headers
  -- to sub-resource requests at all regardless.
  local access_qs = hls_propagated_qs(req)

  -- Never hand back a half-encoded rendition when a finished one exists.
  --
  -- This used to serve the requested variant's playlist the moment it had a
  -- single #EXTINF in it, even though the encode was still running and even
  -- when a complete rendition of the same video was sitting on disk. The
  -- player then gets a playlist that stops partway and has to keep re-polling
  -- for more, and if the encoder is not comfortably ahead of playback it
  -- stalls -- which it very often was not: measured on a quiet box, the 480p
  -- rendition of media 621 encoded at 1.0x realtime before the GPU pipeline
  -- work, i.e. exactly the speed it was being watched at. A complete
  -- rendition one tier down is strictly better than a stuttering one at the
  -- requested tier.
  --
  -- The redirect deliberately does NOT touch this variant's heartbeat. That
  -- matters: the encode was just launched for it, and a heartbeat that then
  -- goes stale is what tells the reaper the viewer abandoned it. Since we are
  -- the ones sending the viewer elsewhere, marking it "being watched" here
  -- guaranteed it would be killed 25 seconds later -- caught live, a cold
  -- 480p on 621 was killed at 63s of 714s having been redirected away from,
  -- so every request restarted it from nothing and it could never finish.
  -- With no heartbeat and no .warm marker the reaper leaves it alone, it
  -- completes in the background, and the next viewer gets it warm.
  if not hls_variant_ready(dir) then
    local complete_alt = best_ready_quality()
    if complete_alt and complete_alt ~= quality then
      return 302, "", {
        ["Location"] = string.format("/api/media/%d/hls/%s/playlist.m3u8%s",
          media_id, complete_alt, access_qs or ""),
        ["Cache-Control"] = "no-store",
      }
    end
  end

  -- Actually serving this variant now, so it counts as being watched.
  M._touch_hls_heartbeat(dir)

  -- Nothing complete to fall back on, so wait for this encode's first
  -- segment and stream it as it grows -- still far better than a spinner.
  --
  -- 20s rather than the old 8s. This branch is now only reached when there
  -- is genuinely nothing else to serve, and in that situation a viewer is far
  -- better off waiting than being handed a 503 they have to retry out of.
  -- Measured on a cold media 621: `original` is a full 1080p60 re-encode
  -- running around 1-2x realtime, so its first 6s segment lands a little past
  -- the old 8s cutoff -- close enough that the budget, not the encoder, was
  -- what turned a working cold start into an error.
  local ready_alt = nil
  local wait_budget = 20
  local playlist_path = dir .. "/playlist.m3u8"
  local waited = 0
  while waited < wait_budget do
    local f = io.open(playlist_path, "rb")
    if f then
      local text = f:read("*a")
      f:close()
      if text and text:find("#EXTINF", 1, true) then
        if access_qs then
          -- Escape any literal "%" in the token itself so gsub's
          -- replacement-string parser doesn't mistake it for a
          -- backreference/escape sequence.
          local safe_access_qs = access_qs:gsub("%%", "%%%%")
          text = text:gsub("(seg_%d+%.ts)", "%1" .. safe_access_qs)
        end
        -- Long, public, immutable caching only once BOTH hold: the variant
        -- is fully finished (hls_variant_ready -- while still encoding, this
        -- exact response will have fewer segments next request, so it must
        -- never be treated as immutable) AND this response is safe for a
        -- SHARED cache per hls_check_access's 4th return (see its own doc
        -- comment -- private posts, and adult posts reached via session
        -- rather than an access token, must never be marked `public`, since
        -- a shared cache would then be able to replay this exact response
        -- to a later unauthorized requester of the identical URL). Otherwise
        -- unchanged from before: `no-cache` so a still-growing or
        -- access-controlled playlist is always revalidated at the origin.
        local cache_control = (publicly_cacheable and hls_variant_ready(dir))
          and "public, max-age=31536000, immutable" or "no-cache"
        return 200, text, { ["Content-Type"] = "application/vnd.apple.mpegurl", ["Cache-Control"] = cache_control }
      end
    end
    local copas_ok, copas = pcall(require, "copas")
    if copas_ok then copas.sleep(0.25) end
    waited = waited + 0.25
  end
  -- Retry-After was already sent on the OTHER 503 branch above (transcode
  -- queue full) but missing here -- same "still not ready, not a dead end"
  -- meaning, so any client that respects the header (hls.js's own retry
  -- loop doesn't; it runs its own capped-backoff timer regardless) should
  -- get the same signal either way.
  -- Still no first segment after the bounded wait. The encode IS running and
  -- will finish in the background (a cold 300MB watermarked original is
  -- minutes of work, far past any wait a request can hold), so rather than
  -- leave the viewer on a retry loop, send them to a rendition that is
  -- already complete if there is one. Measured live: this is the difference
  -- between "503, nothing plays" and instant playback one tier down.
  if ready_alt and ready_alt ~= quality then
    local fallback_qs = hls_propagated_qs(req) or ""
    return 302, "", {
      ["Location"] = string.format("/api/media/%d/hls/%s/playlist.m3u8%s", media_id, ready_alt, fallback_qs),
      ["Cache-Control"] = "no-store",
    }
  end
  return 503, { detail = "This video is still starting up -- try again in a moment." }, { ["Retry-After"] = "3" }
end

function M.serve_hls_segment(req)
  local media_id = tonumber(req.params.media_id)
  local quality = normalize_video_quality(req.params.quality)
  local segment = req.params.segment
  if not media_id or not segment or not segment:match("^seg_%d+%.ts$") then
    return 404, { detail = "Not found." }
  end
  local item, status, body, publicly_cacheable = hls_check_access(req, media_id)
  if not item then return status, body end

  local seg_watermark_text = nil -- WATERMARKS_ENABLED = false (get_user lookup for it removed too)
  local digest_seed = media_content_digest_seed(media_id, item, seg_watermark_text)
  local dir = hls_variant_dir(media_id, quality, digest_seed)
  local f = io.open(dir .. "/" .. segment, "rb")
  if not f then return 404, { detail = "Segment not found." } end

  -- Read in chunks, yielding between them, rather than one f:read("*a").
  --
  -- Measured 2026-09-01 while load-testing concurrent viewers: a single
  -- uncontended segment request costs 8ms end to end, but that is a
  -- page-cache hit. A COLD segment is a real 3.5MB disk read at ~21MB/s --
  -- ~165ms -- and `f:read("*a")` is one uninterruptible blocking call, so
  -- the entire worker (copas is single-threaded, and it is the same thread
  -- serving every other request) stalls for all of it. With 8 simulated
  -- viewers pulling segments of the big adult-gated videos that head-of-line
  -- blocking took segment p50 to 430ms and dragged an unrelated /api/health
  -- probe from ~1ms to a 247ms worst case. Playback is a stream of cold
  -- sequential reads by nature, so this is the normal case, not an edge one.
  --
  -- Same total disk time, but broken into ~12ms pieces with a yield after
  -- each, so other requests interleave instead of queueing behind a whole
  -- segment. copas.sleep(0) is the documented "yield to the scheduler now"
  -- idiom already used elsewhere in this file. Still buffers the finished
  -- body (httpd's send_response takes one string and sets Content-Length
  -- from it), so this reduces latency under concurrency, not peak memory.
  local copas_ok, copas = pcall(require, "copas")
  local parts, n = {}, 0
  while true do
    local chunk = f:read(256 * 1024)
    if not chunk or chunk == "" then break end
    n = n + 1
    parts[n] = chunk
    if copas_ok then copas.sleep(0) end
  end
  f:close()
  local bytes = table.concat(parts)
  M._touch_hls_heartbeat(dir)
  -- PRE-EXISTING GAP FIXED HERE (2026-09-13): this was unconditionally
  -- `public, max-age=86400` regardless of how access was granted -- see
  -- hls_check_access's 4th return value doc comment for exactly why that's
  -- unsafe for a private post, or an adult post reached via session-based
  -- age verification rather than this request's own access token: a shared
  -- cache honoring `public` could replay either straight to a later
  -- unauthorized requester of the identical segment URL. `private` (not
  -- `no-store`) in the unsafe case: an individual segment's bytes never
  -- change once written regardless of visibility, so the requester's OWN
  -- browser caching it for normal seek/replay within their own viewing
  -- session is still both safe and worth keeping -- only a SHARED cache
  -- must not store it.
  local cache_scope = publicly_cacheable and "public" or "private"
  return 200, bytes, { ["Content-Type"] = "video/mp2t", ["Cache-Control"] = cache_scope .. ", max-age=86400" }
end

-- Adds real HTTP Range/206 support. Previously flagged as a KNOWN
-- LIMITATION (see this section's header comment above): httpd.lua always
-- wrote one Content-Length-framed body with no partial-content path, so
-- video <video> elements couldn't seek properly in the browser (seeking
-- a <video> depends on the server answering a Range request, not just on
-- the client re-requesting the whole file) and every scrub re-downloaded
-- the entire file. The full byte content is already in memory by the time
-- this runs (resolve_media_bytes() reads the whole DB blob), so this is
-- just header parsing + a string slice + a 206 status -- no actual
-- streaming/chunking machinery needed.
local function respond_with_range(req, content, mime_type, extra_headers)
  local total = #content
  local headers = { ["Content-Type"] = mime_type or "application/octet-stream", ["Accept-Ranges"] = "bytes" }
  for k, v in pairs(extra_headers or {}) do headers[k] = v end

  local range = req.headers and req.headers["range"]
  if not range then return 200, content, headers end

  local start_s, end_s = tostring(range):match("^bytes=(%d*)-(%d*)$")
  if not start_s or (start_s == "" and end_s == "") then
    -- Malformed/unsupported Range (e.g. multi-range) -- ignore and serve
    -- the full body rather than 416ing on something we just don't parse.
    return 200, content, headers
  end
  local start_byte, end_byte
  if start_s == "" then
    -- "bytes=-500" -- last 500 bytes.
    local suffix_len = tonumber(end_s) or 0
    start_byte = math.max(0, total - suffix_len)
    end_byte = total - 1
  else
    start_byte = tonumber(start_s) or 0
    end_byte = (end_s ~= "" and tonumber(end_s)) or (total - 1)
  end
  end_byte = math.min(end_byte, total - 1)
  if start_byte > end_byte or start_byte >= total then
    headers["Content-Range"] = "bytes */" .. total
    return 416, "", headers
  end

  headers["Content-Range"] = string.format("bytes %d-%d/%d", start_byte, end_byte, total)
  return 206, content:sub(start_byte + 1, end_byte + 1), headers
end

local function serve_media_bytes_response(req, media_id, as_download, quality)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local item = fetch_media_by_id(media_id, viewer_id or "0")
  if not item or nn(item.deleted_at) ~= nil then return 404, { detail = "Media not found." } end
  item.is_adult = db.tobool(item.is_adult)
  local owner = viewer_id and tostring(item.user_id) == tostring(viewer_id)
  if item.visibility == "private" and not private_file_allowed(media_id, req.query.access, owner) then
    return 403, { detail = "This post is private." }
  end
  if as_download and not db.tobool(item.downloads_enabled) and not owner then
    return 403, { detail = "Downloads are disabled for this post." }
  end
  if item.is_adult and not adult_file_allowed(req, media_id, req.query.access, viewer_id) then
    return 403, { detail = "Age verification required for this 18+ post." }
  end

  -- Fast path: seek-and-read just the requested byte range straight from
  -- the on-disk original-bytes cache, instead of resolve_media_bytes()
  -- reading the whole (up to several-hundred-MB) file into memory first.
  -- A <video> element issues many Range requests per playback (an initial
  -- probe plus one per seek/buffer refill); this server runs on copas'
  -- single-threaded event loop, so a full-file read for EACH of those
  -- blocked every other in-flight request on the server for the duration
  -- of that read too, not just the one video's own load time. Scoped to
  -- videos at "original" quality: images are small enough not to matter
  -- (and may still need watermarking below), and the quality-transcode
  -- path already reads from its own, typically much smaller, transcoded
  -- cache file. Only fires on a warm cache -- a MISS still has to fetch
  -- the whole thing once via the existing path below (same cost as
  -- before), but every request after that hits this fast path instead.
  if not as_download and item.media_kind == "video" and normalize_video_quality(quality) == "original" then
    local fast_cache_path = item.id and original_bytes_cache_path(item.id, item)
    local total = fast_cache_path and range_io.file_size(fast_cache_path)
    if total then
      local status, start_byte, end_byte, headers = range_io.parse(
        req, total, item.mime_type, { ["Cache-Control"] = "public, max-age=86400" }
      )
      if status == 416 then
        return 416, "", headers
      end
      local slice = range_io.read_file_range(fast_cache_path, start_byte, end_byte)
      if slice then
        return status, slice, headers
      end
      -- Cache file vanished between the size check and the read (e.g. an
      -- eviction mid-request) -- fall through to the normal path below
      -- rather than 500ing.
    end
  end

  local content, mime_type, original_filename = resolve_media_bytes(item)
  if not content then
    return 404, { detail = "File is missing. Re-upload this post once so it can be saved into the new DB-backed file store." }
  end

  content = apply_image_watermark_if_configured(media_id, item, content, mime_type)

  if as_download then
    db.execute("UPDATE media_items SET downloads=downloads+1 WHERE id=%s", tostring(media_id))
  end
  if as_download then
    -- Downloads always send the whole file -- Range/206 is a streaming-
    -- playback concern (<video> seeking), not a "save as" one.
    local headers = {
      ["Content-Type"] = mime_type or "application/octet-stream",
      ["Content-Disposition"] = "attachment; filename=\"" .. (original_filename or "download"):gsub('"', "") .. "\"",
      ["Cache-Control"] = "private, max-age=0, no-cache",
    }
    return 200, content, headers
  end

  local normalized_quality = normalize_video_quality(quality)
  if item.media_kind == "video" and normalized_quality ~= "original" then
    local transcoded, transcoded_mime = ensure_video_quality_cache(media_id, item, content, normalized_quality)
    if transcoded then
      return respond_with_range(req, transcoded, transcoded_mime, {
        ["Cache-Control"] = "public, max-age=86400",
        ["X-Video-Quality"] = normalized_quality,
        ["X-Video-Codec"] = "h264/aac",
      })
    end
    -- Transcode unavailable/failed/too large -- fall through to the original,
    -- same as Python's _video_variant_response returning None.
  end
  return respond_with_range(req, content, mime_type, { ["Cache-Control"] = "public, max-age=86400" })
end

function M.serve_media_file(req)
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  return serve_media_bytes_response(req, media_id, false, req.query and req.query.quality)
end

function M.download_media(req)
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  return serve_media_bytes_response(req, media_id, true)
end

-- ---------------------------------------------------------------------------
-- Zip downloads (StudioPage.jsx's "Download selected" and
-- CollectionsPage.jsx's "Download collection" -- both confirmed
-- live-404ing, and the zip-building capability they need didn't exist
-- anywhere in this codebase yet, unlike most other gaps this session which
-- were "recover the existing logic." Shells out to the system `zip` binary
-- via os.execute/os.tmpname, the same convention media_files.lua already
-- uses for ffmpeg/ImageMagick calls (see its "ffmpeg-backed thumbnail"
-- section) -- no Lua zip library is installed (checked: neither `zip` nor
-- `minizip` rocks are available), and this matches how every other
-- shell-out in this codebase already works rather than introducing a new
-- technique.
-- ---------------------------------------------------------------------------

local function zip_shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Writes each accessible item's bytes to a scratch temp dir, zips it with
-- the system `zip` binary, reads the result back into memory, and cleans up
-- -- returns the zip bytes, or nil if nothing was downloadable (private and
-- not owned, downloads disabled and not owned, or bytes missing). Mirrors
-- serve_media_bytes_response's own per-item visibility/downloads_enabled
-- gating, just skipping rather than 403ing the whole batch over one
-- inaccessible item.
local function build_media_zip(items, viewer_id)
  local tmp_dir = os.tmpname()
  os.remove(tmp_dir)
  os.execute("mkdir -p " .. zip_shell_quote(tmp_dir))

  local file_paths = {}
  for _, item in ipairs(items) do
    local owner = viewer_id and tostring(item.user_id) == tostring(viewer_id)
    local visible = item.visibility ~= "private" or owner
    local allowed = db.tobool(item.downloads_enabled) or owner
    if visible and allowed then
      local content = resolve_media_bytes(item)
      if content then
        local safe_base = tostring(item.original_filename or ("media-" .. item.id)):gsub("[/\\]", "_")
        local path = tmp_dir .. "/" .. tostring(item.id) .. "-" .. safe_base
        local f = io.open(path, "wb")
        if f then
          f:write(content)
          f:close()
          file_paths[#file_paths + 1] = path
        end
      end
    end
  end

  if #file_paths == 0 then
    os.execute("rm -rf " .. zip_shell_quote(tmp_dir))
    return nil
  end

  local zip_path = tmp_dir .. ".zip"
  local quoted_paths = {}
  for _, p in ipairs(file_paths) do quoted_paths[#quoted_paths + 1] = zip_shell_quote(p) end
  local cmd = "cd " .. zip_shell_quote(tmp_dir) .. " && zip -j -q " .. zip_shell_quote(zip_path)
    .. " " .. table.concat(quoted_paths, " ") .. " </dev/null >/dev/null 2>&1"
  local ok = os.execute(cmd)
  local success = (ok == 0 or ok == true)

  local zip_bytes = nil
  if success then
    local f = io.open(zip_path, "rb")
    if f then
      zip_bytes = f:read("*a")
      f:close()
    end
  end
  os.execute("rm -rf " .. zip_shell_quote(tmp_dir))
  os.remove(zip_path)
  return zip_bytes
end

-- POST /api/media/download-batch -- confirmed live-404ing: StudioPage.jsx's
-- "Download selected" bulk action has always called this.
function M.download_media_batch(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local rl_status, rl_body = ratelimit.check("download_batch:" .. (viewer_id or client_ip(req)), 30, 3600)
  if rl_status then return rl_status, rl_body end

  local payload = json_body(req)
  local ids = {}
  if type(payload.media_ids) == "table" then
    for _, id in ipairs(payload.media_ids) do
      local n = tonumber(id)
      if n then ids[#ids + 1] = n end
    end
  end
  if #ids == 0 then return 400, { detail = "No posts selected." } end
  if #ids > 50 then return 400, { detail = "Select 50 or fewer posts at a time." } end

  local items = {}
  for _, id in ipairs(ids) do
    local item = fetch_media_by_id(id, viewer_id or "0")
    if item and nn(item.deleted_at) == nil then
      item.is_adult = db.tobool(item.is_adult)
      items[#items + 1] = item
    end
  end

  local zip_bytes = build_media_zip(items, viewer_id)
  if not zip_bytes then return 404, { detail = "None of the selected posts could be downloaded." } end
  return 200, zip_bytes, {
    ["Content-Type"] = "application/zip",
    ["Content-Disposition"] = 'attachment; filename="gallery-selection.zip"',
  }
end

-- GET /api/collections/:collection_id/download -- confirmed live-404ing:
-- CollectionsPage.jsx has always called this. Delegates access control
-- entirely to M.collection_detail (private-collection 404 gating, smart-
-- collection filter resolution) rather than duplicating it.
function M.download_collection(req)
  local status, body = M.collection_detail(req)
  if status ~= 200 then return status, body end
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  -- body.media went through arr() inside collection_detail, which returns
  -- the special cjson.empty_array sentinel (not a real table) for an empty
  -- list -- `#` on that userdata errors, so normalize back to {} here.
  local items = type(body.media) == "table" and body.media or {}
  if #items == 0 then return 404, { detail = "This collection has no downloadable posts." } end

  local zip_bytes = build_media_zip(items, viewer_id)
  if not zip_bytes then return 404, { detail = "None of the posts in this collection could be downloaded." } end

  local raw_name = tostring((body.collection and body.collection.name) or "collection")
  local safe_name = raw_name:gsub("[^%w%-_ ]", ""):gsub("%s+", "-"):sub(1, 60)
  if safe_name == "" then safe_name = "collection" end
  return 200, zip_bytes, {
    ["Content-Type"] = "application/zip",
    ["Content-Disposition"] = string.format('attachment; filename="%s.zip"', safe_name),
  }
end

function M.serve_media_preview(req)
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local item = M._fetch_media_for_bytes(media_id)
  if not item or nn(item.deleted_at) ~= nil then return 404, { detail = "Media not found." } end
  item.is_adult = db.tobool(item.is_adult)
  local owner = viewer_id and tostring(item.user_id) == tostring(viewer_id)
  if item.visibility == "private" and not private_file_allowed(media_id, req.query.access, owner) then
    return 403, { detail = "This post is private." }
  end
  if item.is_adult and not adult_file_allowed(req, media_id, req.query.access, viewer_id) then
    return 403, { detail = "Age verification required for this 18+ post." }
  end
  if tostring(item.media_kind or "") ~= "image" then
    return serve_media_bytes_response(req, media_id, false)
  end
  local size = tostring(req.query.size or "card")
  if not M._PREVIEW_SIZES[size] then size = "card" end
  local max_edge, quality = M._PREVIEW_SIZES[size][1], M._PREVIEW_SIZES[size][2]
  local headers = { ["Content-Type"] = "image/webp", ["Cache-Control"] = M._image_cache_control(item) }

  -- Disk cache (2026-10-26): previews used to be re-rendered by ffmpeg on
  -- EVERY view (1-2s for a detail page). Now rendered once (or ahead of
  -- time by the rendition warmer) and served from _preview_cache.
  local cache_path = M._preview_cache_path(media_id, item, size)
  local cached = M._read_whole_file(cache_path)
  if cached then return 200, cached, headers end

  local src_path = M._image_source_path(item)
  local rendered = src_path and media_files.render_webp_bytes_from_path(src_path, max_edge, quality) or nil
  local content
  if not rendered then
    content = resolve_media_bytes(item)
    if not content then
      return 404, { detail = "Preview is missing. Re-upload this post once so it can be saved into the new DB-backed file store." }
    end
    content = apply_image_watermark_if_configured(media_id, item, content, item.mime_type)
    rendered = media_files.render_webp_from_bytes(content, max_edge, quality)
  end
  if rendered then
    M._write_file_atomic(cache_path, rendered)
    return 200, rendered, headers
  end
  return 200, content, { ["Content-Type"] = item.mime_type or "application/octet-stream", ["Cache-Control"] = "private, max-age=86400" }
end

-- Avatars are shown at most ~128px but were served at upload size (100KB+)
-- straight out of a bytea column on every page. Now a 256px WEBP is
-- rendered once per avatar file and kept in _preview_cache/avatars; only
-- the tiny id/sha row is read from the DB. GIFs stay as uploaded (animated).
function M._avatar_rendition(user_id)
  local meta = db.fetchone([[
    SELECT f.id, f.sha256, f.mime_type FROM user_avatar_files f
    JOIN users u ON u.avatar_file_id = f.id WHERE u.id = %s
  ]], user_id)
  if not meta or nn(meta.mime_type) == "image/gif" then return nil end
  local path = M.settings.uploads_dir .. "/_preview_cache/avatars/" .. tostring(user_id) .. "_"
    .. tostring(meta.id) .. "_" .. tostring(nn(meta.sha256) or ""):sub(1, 12) .. ".webp"
  local cached = M._read_whole_file(path)
  if cached then return cached end
  local file_row = media_files.get_avatar_file(user_id)
  if not (file_row and file_row.content and #file_row.content > 0) then return nil end
  local rendered = media_files.render_webp_from_bytes(file_row.content, 256, 86)
  if rendered and #rendered > 0 and #rendered < #file_row.content then
    M._write_file_atomic(path, rendered)
    return rendered
  end
  return nil
end

function M.serve_user_avatar(req)
  local user_id = tonumber(req.params.user_id)
  if not user_id then return 404, { detail = "User not found." } end
  local ok_small, small = pcall(M._avatar_rendition, user_id)
  if ok_small and small then
    return 200, small, { ["Content-Type"] = "image/webp", ["Cache-Control"] = "public, max-age=86400" }
  end
  local file_row = media_files.get_avatar_file(user_id)
  if file_row and file_row.content and #file_row.content > 0 then
    return 200, file_row.content, { ["Content-Type"] = file_row.mime_type or "image/jpeg", ["Cache-Control"] = "public, max-age=86400" }
  end
  local user = get_user(tostring(user_id))
  local legacy = user and media_files.legacy_upload_path(M.settings.uploads_dir, nn(user.avatar_path))
  if legacy then
    local f = io.open(legacy, "rb")
    if f then
      local content = f:read("*a")
      f:close()
      return 200, content, { ["Content-Type"] = (user.avatar_mime_type) or "image/jpeg", ["Cache-Control"] = "public, max-age=86400" }
    end
  end
  local svg = string.format(
    "<svg xmlns='http://www.w3.org/2000/svg' width='128' height='128' viewBox='0 0 128 128'>"
      .. "<rect width='128' height='128' rx='64' fill='#202832'/>"
      .. "<text x='64' y='74' text-anchor='middle' font-family='Inter,Arial,sans-serif' font-size='34' font-weight='800' fill='#9ba8b7'>U%d</text></svg>",
    user_id
  )
  return 200, svg, { ["Content-Type"] = "image/svg+xml", ["Cache-Control"] = "public, max-age=3600" }
end

-- ---------------------------------------------------------------------------
-- "My Other Projects" tab: proxies each project's latest .ipa from its
-- GitHub repo (Lumisound, and now Nyxframe itself once it goes back to
-- private -- the whole reason this got generalized instead of staying a
-- Lumisound-only special case). A private repo means the browser can't just
-- link straight to a GitHub release asset -- private-repo asset downloads
-- need an Authorization header GitHub's own CDN redirect won't carry, and
-- this repo owner obviously can't hand out their GitHub token to the page's
-- visitors. Shells out to the `gh` CLI instead of a Lua HTTPS client: it's
-- already authenticated on this box (this backend and `gh` both run as the
-- same user), so this never needs to read/store/handle the token itself --
-- confirmed `gh auth status` succeeds even with every keyring/DBus/session
-- env var stripped, so it works fine from this systemd --user service's
-- minimal environment too. Same detached-background-job + bounded-poll
-- shape as the video transcode section above, so a slow GitHub fetch
-- yields to other requests instead of blocking the single-threaded server.
-- ---------------------------------------------------------------------------

local PROJECT_DOWNLOAD_POLL_SECONDS = 20

local function project_download_cache_dir()
  local dir = M.settings.uploads_dir .. "/_project_downloads"
  os.execute("mkdir -p " .. shell_quote(dir))
  return dir
end

-- Fast metadata-only call (no asset bytes), so a synchronous io.popen here
-- is fine -- this is the same kind of brief, bounded call the rest of this
-- file already makes synchronously (e.g. ffprobe-equivalent lookups).
local function project_latest_tag(repo)
  local handle = io.popen(
    "env -i HOME=" .. shell_quote(os.getenv("HOME") or "") .. " PATH=" .. shell_quote(os.getenv("PATH") or "")
      .. " gh release list --repo " .. shell_quote(repo)
      .. " --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null"
  )
  if not handle then return nil end
  local tag = handle:read("*a")
  handle:close()
  tag = tag and tag:gsub("%s+$", "") or ""
  return tag ~= "" and tag or nil
end

local function project_safe_tag(tag)
  return (tag:gsub("[^%w%.%-]", "_"))
end

-- key: short filesystem-safe prefix for this project's cache files (e.g.
-- "lumisound"/"nyxframe"). display_name: used only in the filename and
-- error text shown to the visitor.
local function download_latest_ipa(req, repo, key, display_name)
  -- Unauthenticated by design (this is the public "My Other Projects"
  -- download tab, streamed via the server's own `gh` credentials against
  -- private repos) -- but with no rate limit at all, any visitor could hit
  -- this endlessly and either hammer `gh`/GitHub with this server's own
  -- credentials or just repeatedly pull the cached .ipa off disk. Same
  -- ratelimit.check(...) mechanism the upload/analyze/avatar endpoints use,
  -- keyed per-IP (there's no auth here to key on) and shared across both
  -- projects so one visitor can't just alternate targets to dodge it.
  local rl_status, rl_body = ratelimit.check("project_download:" .. client_ip(req), 10, 3600)
  if rl_status then return rl_status, rl_body end

  local tag = project_latest_tag(repo)
  if not tag then return 502, { detail = "Could not reach GitHub to check the latest " .. display_name .. " release. Try again shortly." } end

  local dir = project_download_cache_dir()
  local safe_tag = project_safe_tag(tag)
  local final_path = dir .. "/" .. key .. "_" .. safe_tag .. ".ipa"
  local filename = display_name .. "-" .. safe_tag .. ".ipa"

  local existing = io.open(final_path, "rb")
  if existing then
    local content = M._read_file_chunked(existing)
    existing:close()
    return 200, content, {
      ["Content-Type"] = "application/octet-stream",
      ["Content-Disposition"] = 'attachment; filename="' .. filename .. '"',
      ["Cache-Control"] = "private, max-age=0, no-cache",
    }
  end

  -- Same filesystem-based ".pending" dedup as the video transcode section:
  -- a concurrent second visitor hitting this while the first download is
  -- still in flight waits on the SAME fetch rather than kicking off a
  -- redundant one.
  local pending_marker = final_path .. ".pending"
  local pf = io.open(pending_marker, "rb")
  local pending_age = pf and tonumber(pf:read("*a")) or nil
  if pf then pf:close() end
  local still_fetching = pending_age and (os.time() - pending_age) < PROJECT_DOWNLOAD_POLL_SECONDS

  if not still_fetching then
    local marker = assert(io.open(pending_marker, "wb"))
    marker:write(tostring(os.time()))
    marker:close()

    local tmp_path = final_path .. ".tmp." .. tostring(math.random(100000, 999999))
    local cmd = string.format(
      "( env -i HOME=%s PATH=%s gh release download %s --repo %s --pattern '*.ipa' -O %s --clobber "
        .. "&& mv -f %s %s; rm -f %s %s ) </dev/null >/dev/null 2>&1 &",
      shell_quote(os.getenv("HOME") or ""), shell_quote(os.getenv("PATH") or ""),
      shell_quote(tag), shell_quote(repo), shell_quote(tmp_path),
      shell_quote(tmp_path), shell_quote(final_path),
      shell_quote(tmp_path), shell_quote(pending_marker)
    )
    os.execute(cmd)
  end

  local waited = 0
  while waited < PROJECT_DOWNLOAD_POLL_SECONDS do
    local f = io.open(final_path, "rb")
    if f then
      local content = M._read_file_chunked(f)
      f:close()
      return 200, content, {
        ["Content-Type"] = "application/octet-stream",
        ["Content-Disposition"] = 'attachment; filename="' .. filename .. '"',
        ["Cache-Control"] = "private, max-age=0, no-cache",
      }
    end
    local copas_ok, copas = pcall(require, "copas")
    if copas_ok then copas.sleep(0.5) end
    waited = waited + 0.5
  end
  return 503, { detail = "Still fetching the latest " .. display_name .. " build from GitHub -- try again in a moment." }
end

function M.download_lumisound(req)
  return download_latest_ipa(req, "HollowHeavenXR/Lumisound", "lumisound", "Lumisound")
end

function M.download_nyxframe(req)
  return download_latest_ipa(req, "HollowHeavenXR/Nyxframe", "nyxframe", "Nyxframe")
end

-- ---------------------------------------------------------------------------
-- Telemetry / Ops admin panel (see telemetry.lua for the in-memory request/
-- job stats and the durable telemetry_events table this also reads from).
-- Deliberately does NOT call admin_storage/walk_cache_dir here (that shells
-- out to `find` per cache directory -- see that function's own header
-- comment) or referenced_media_ids' full-table id scan; this panel is meant
-- to be loaded often (site-owner glancing at ops health), not just when
-- someone is specifically investigating storage.
function M.admin_telemetry(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local q = req.query or {}
  local snapshot = M.telemetry.snapshot()
  local recent, err = M.telemetry.recent_events(nn(q.event_type), q.limit)
  return 200, {
    request_stats = arr(snapshot.request_stats),
    request_stats_since = snapshot.request_stats_since,
    jobs = snapshot.jobs,
    counters = snapshot.counters,
    transcode_active_slots = count_active_transcode_slots(),
    transcode_max_concurrent = transcode.max_concurrent,
    recent_events = arr(recent),
  }
end

-- ---------------------------------------------------------------------------
-- Permanent deletion of long-soft-deleted media. `perform_delete_media`
-- (this file, ~line 3762) only ever sets deleted_at + visibility='private'
-- -- kept indefinitely with no automatic cleanup until now, confirmed live
-- 2026-09-14 (a user asked how long a deleted post stays recoverable; the
-- honest answer at the time was "forever"). Runs once a day, primary
-- worker only (same gate as every other background loop in this file),
-- hard-deleting any media_items row whose deleted_at is older than
-- GALLERY_DELETED_MEDIA_RETENTION_DAYS (default 10) -- past that point
-- restore_media can no longer bring it back, so this is a real, permanent,
-- irreversible cleanup, unlike every other background loop in this file.
--
-- Every table that references media_items(id) does so with ON DELETE
-- CASCADE (confirmed live against the schema) except
-- ai_vision_training_examples, which deliberately uses ON DELETE SET NULL
-- so training examples outlive the media that inspired them -- a plain
-- DELETE FROM media_items here cleans up every dependent row correctly
-- with no separate cleanup needed for any of them.
--
-- The physical file is a different story: storage is content-addressed
-- (media/<shard>/<sha256>.<ext>), so more than one media_items row can
-- point at the exact same file (confirmed live the same day: two
-- near-simultaneous test uploads of the same video landed on the
-- identical storage_path). The file is only unlinked once no OTHER
-- media_items row -- deleted or not, this candidate's own row already
-- removed by that point -- still references that path. Racy in principle
-- against a concurrent upload landing on the same content-hash between
-- that check and the unlink, but the worst case is a rare orphaned
-- original file, the same class of gap the existing cache-orphan purge
-- (admin_purge_storage_orphans) already tolerates -- not a new risk, and
-- that same admin action would eventually catch a leftover cache entry for
-- it regardless.
-- Nested INSIDE M.start_deleted_media_purge below (not top-level locals)
-- for the same reason range_io/sweep_once/reap_once all are elsewhere in
-- this file: the main chunk is already at LuaJIT's 200-local ceiling --
-- confirmed live, adding this as two more top-level locals broke
-- `luajit -e "loadfile(...)"` with the exact "more than 200 local
-- variables" error the range_io comment already warns about.
-- ---------------------------------------------------------------------------
-- Ephemeral/"stories" post expiry sweep. New feature, 2026-10-11, paired
-- with finalize_upload's `expires_in_hours` option above.
--
-- Deliberately reuses the EXISTING soft-delete mechanism (same
-- deleted_at=now(), visibility='private' pair perform_delete_media already
-- applies) rather than adding a new `expires_at > now()` condition to
-- every browsing query in this file (list_media, fetch_media_feed,
-- fetch_media_by_id, leaderboard, feed_signal, suggested_users,
-- continue_watching, and more). That would mean finding and correctly
-- updating every one of those WHERE clauses, with a real risk of missing
-- one -- a scattered, easy-to-regress change versus a single sweep that
-- flips the one flag every one of those queries already filters on.
-- Reusing soft-delete also means an expired story automatically inherits
-- the FULL existing lifecycle for free: it's recoverable via
-- M.restore_media until the retention window (M.start_deleted_media_purge,
-- above) closes, then hard-deleted exactly like any other deleted post --
-- no separate cleanup path needed for ephemeral content specifically.
--
-- Short interval (contrast the 6-hour cache-orphan sweep or the daily
-- deleted-media purge): stories are meant to disappear close to on time,
-- not hours late. Still cheap -- indexed on expires_at (partial index,
-- WHERE expires_at IS NOT NULL -- see pg_add_media_expiry.sql), so this is
-- a tiny index scan against however many ephemeral posts are currently
-- pending, not a sequential scan of the whole table.
function M.start_media_expiry_sweep()
  local copas = require("copas")
  local SWEEP_INTERVAL_SECONDS = 5 * 60

  local function sweep_once()
    local rows, err = db.fetchall(
      [[
        UPDATE media_items
        SET deleted_at=now(), visibility='private'
        WHERE expires_at IS NOT NULL AND expires_at <= now() AND deleted_at IS NULL
        RETURNING id
      ]]
    )
    -- NOT `rows and #rows or 0`, and NOT `if not rows then ...` either --
    -- db.lua's M.fetchall ALWAYS returns a table as its first value (`rows
    -- or {}`, see its own definition), even on a real SQL failure; the
    -- error only ever shows up in the second return value. Checking
    -- `rows`'s truthiness therefore can never detect a failure -- `err`
    -- is the only signal. Confirmed live 2026-10-11: got this wrong twice
    -- in a row before catching it (first with `rows and #rows or 0`, then
    -- with an equally-wrong `if not rows`), pre-migration, against a table
    -- that didn't have expires_at yet -- both versions silently returned
    -- "0 expired" with zero telemetry rows, zero log lines, nothing to
    -- indicate anything had gone wrong at all.
    if err then error(err) end
    return #rows
  end

  copas.addthread(function()
    while true do
      local telemetry_t0 = M.telemetry.now()
      local ok, removed_or_err = pcall(sweep_once)
      local telemetry_ms = M.telemetry.ms_since(telemetry_t0)
      if not ok then
        print("[nyxframe] media expiry sweep error: " .. tostring(removed_or_err))
        M.telemetry.job_result("media_expiry_sweep", false, telemetry_ms, { error = tostring(removed_or_err):sub(1, 300) })
      elseif removed_or_err and removed_or_err > 0 then
        print(string.format("[nyxframe] media expiry sweep: expired %d post(s)", removed_or_err))
        M.telemetry.job_result("media_expiry_sweep", true, telemetry_ms, { expired = removed_or_err })
      else
        M.telemetry.job_result("media_expiry_sweep", true, telemetry_ms, nil)
      end
      copas.sleep(SWEEP_INTERVAL_SECONDS)
    end
  end)
end

function M.start_deleted_media_purge()
  local copas = require("copas")
  local SWEEP_INTERVAL_SECONDS = 6 * 3600

  local function purge_deleted_media_once()
    local retention_days = math.max(1, M.settings.deleted_media_retention_days or 10)
    local candidates = db.fetchall(
      "SELECT id, storage_path FROM media_items WHERE deleted_at IS NOT NULL AND deleted_at < now() - (%s || ' days')::interval",
      tostring(retention_days)
    )
    local removed_rows, removed_files, freed_bytes = 0, 0, 0
    for _, item in ipairs(candidates) do
      local media_id = db.toint(item.id, item.id)
      local storage_path = nn(item.storage_path)
      -- Redundant deleted_at guard: closes the window where this row was
      -- restored between the SELECT above and this DELETE.
      local deleted_ok = db.execute("DELETE FROM media_items WHERE id=%s AND deleted_at IS NOT NULL", tostring(media_id))
      if deleted_ok then
        removed_rows = removed_rows + 1
        if storage_path then
          local still_referenced = db.fetchone("SELECT id FROM media_items WHERE storage_path=%s LIMIT 1", storage_path)
          if not still_referenced then
            -- Either storage tier may hold it (see config.lua's hot_dir).
            local roots = { M.settings.uploads_dir }
            if media_files.hot_root then roots[#roots + 1] = media_files.hot_root end
            for _, root in ipairs(roots) do
              local full_path = root .. "/" .. storage_path
              local size = 0
              local f = io.open(full_path, "rb")
              if f then
                size = f:seek("end") or 0
                f:close()
              end
              if os.remove(full_path) then
                removed_files = removed_files + 1
                freed_bytes = freed_bytes + size
              end
            end
          end
        end
      end
    end
    return removed_rows, removed_files, freed_bytes
  end

  copas.addthread(function()
    while true do
      local telemetry_t0 = M.telemetry.now()
      local ok, removed_rows, removed_files, freed_bytes = pcall(purge_deleted_media_once)
      local telemetry_ms = M.telemetry.ms_since(telemetry_t0)
      if not ok then
        print("[nyxframe] deleted-media purge error: " .. tostring(removed_rows))
        M.telemetry.job_result("deleted_media_purge", false, telemetry_ms, { error = tostring(removed_rows):sub(1, 300) })
      elseif removed_rows and removed_rows > 0 then
        print(string.format(
          "[nyxframe] deleted-media purge: permanently removed %d post(s), %d file(s), freed %d bytes",
          removed_rows, removed_files or 0, freed_bytes or 0
        ))
        write_audit_log(nil, "deleted_media_purge", "storage", nil,
          string.format("removed=%d files=%d bytes=%d", removed_rows, removed_files or 0, freed_bytes or 0))
        M.telemetry.job_result("deleted_media_purge", true, telemetry_ms,
          { removed_rows = removed_rows, removed_files = removed_files, freed_bytes = freed_bytes })
      else
        M.telemetry.job_result("deleted_media_purge", true, telemetry_ms, nil)
      end
      copas.sleep(SWEEP_INTERVAL_SECONDS)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Automatic cache-orphan sweep for the three content-digest-keyed caches
-- (_video_cache, _original_cache, _hls_cache). Confirmed live 2026-10-11
-- while auditing disk usage: unlike the stale-PENDING sweep above (only
-- catches a crashed encode's OWN in-flight leftovers) or
-- M.start_deleted_media_purge above (only ever removes the raw uploaded
-- original, and only for media whose row no longer exists), nothing
-- automatic -- or even admin-manual -- ever reclaims a FINISHED rendition
-- that a content change superseded. Re-uploading/editing a still-live
-- media_items row changes content_sha256 (or, for _original_cache,
-- updated_at), which changes that cache's digest key (see
-- media_content_digest_seed/hls_variant_dir/original_bytes_cache_path), but
-- the OLD key's file/directory is simply never looked at again -- it isn't
-- "orphaned" by admin_purge_storage_orphans' definition (the media_id is
-- still referenced), so it sits there forever.
--
-- Found live: media 621 carries two complete 1080p directories AND two
-- complete "original" directories under _hls_cache for two different keys
-- (one clearly superseded), same pattern on media 639; _hls_cache alone was
-- 40GB with literally no cleanup path, manual or automatic -- unlike
-- _video_cache/_original_cache/_watermark_cache/_thumb_cache,
-- admin_purge_storage_orphans' ORPHAN_CACHE_DIR_NAMES never included it at
-- all. This sweep is deliberately separate from that admin tool (not a
-- rewrite of it) rather than risk its existing flat-file-only walk: it adds
-- the other failure mode a digest key can hit -- "the media_id is still
-- referenced, but this isn't its CURRENT key" -- on top of the existing
-- "media_id isn't referenced at all" case, for all three key-addressed
-- caches, _hls_cache (directory-per-variant) included.
--
-- Deliberately excludes _thumb_cache (not digest-keyed -- same path for a
-- given media_id+width gets overwritten in place, nothing to supersede) and
-- _watermark_cache (small, already reachable via the existing admin tool).
--
-- Far less frequent than the stale-pending sweep: a superseded-but-complete
-- entry never un-supersedes itself, so there's no urgency, just steady
-- reclamation. Same primary-worker-only gate as every other background loop
-- in this file -- every worker shares the same on-disk cache.
-- Nested INSIDE M.start_cache_orphan_sweep below (not a top-level local),
-- same reason as every other helper in this file that is -- the main chunk
-- is already at LuaJIT's 200-local ceiling; confirmed live, adding this as
-- its own top-level local broke `luajit -e "loadfile(...)"` with the exact
-- "more than 200 local variables" error range_io's comment already warns
-- about.
function M.start_cache_orphan_sweep()
  local copas = require("copas")
  local SWEEP_INTERVAL_SECONDS = 6 * 3600
  -- Same margin as the manual orphan-purge path -- never touches anything
  -- that could plausibly still be an in-flight job for a brand new key.
  local MIN_AGE_SECONDS = 24 * 3600

  local function current_media_digest_keys()
    local sodium = require("luasodium")
    -- Check `err`, not `rows` -- see referenced_media_ids' header comment
    -- (above M.admin_purge_storage_orphans) for why db.fetchall's first
    -- return value can never be used to detect a failure.
    local rows, err = db.fetchall("SELECT id, content_sha256, updated_at, created_at FROM media_items WHERE deleted_at IS NULL")
    if err then error(err) end
    local transcode_keys, original_keys = {}, {}
    for _, row in ipairs(rows) do
      local media_id = tostring(db.toint(row.id, row.id))
      local transcode_seed = media_content_digest_seed(media_id, row, nil)
      transcode_keys[media_id] = sodium.sodium_bin2hex(sodium.crypto_hash_sha256(tostring(transcode_seed))):sub(1, 16)
      local original_seed = tostring(row.updated_at or row.created_at or media_id)
      original_keys[media_id] = sodium.sodium_bin2hex(sodium.crypto_hash_sha256(original_seed)):sub(1, 16)
    end
    return transcode_keys, original_keys
  end

  -- "<id>_<quality>_<key>" (directories, _hls_cache) or "<id>_<quality>_
  -- <key>.mp4" (_video_cache) -- quality is alnum, key is hex.
  local function parse_quality_style(name)
    local stem = name:match("^(.-)%.[^./]+$") or name
    return stem:match("^(%d+)_%w+_(%x+)$")
  end

  -- "<id>_<key>.bin" (_original_cache, one shard dir at a time).
  local function parse_flat_style(name)
    local stem = name:match("^(.-)%.[^./]+$") or name
    return stem:match("^(%d+)_(%x+)$")
  end

  -- `find_type` is "-type f" or "-type d" (the latter for _hls_cache, where
  -- the variant directory itself is the orphan unit). Size of a directory
  -- is measured with `du -sb` since `find -printf %s` on a directory only
  -- reports the directory inode's own size, not its contents.
  local function sweep_dir(dir, referenced, keys, now, find_type, parse_name, is_dir)
    local removed, freed = 0, 0
    local handle = io.popen(string.format(
      "find %s -mindepth 1 -maxdepth 1 %s -printf '%%T@ %%p\\n' 2>/dev/null",
      shell_quote(dir), find_type))
    if not handle then return removed, freed end
    for line in handle:lines() do
      local mtime_str, path = line:match("^(%S+) (.+)$")
      local mtime = tonumber(mtime_str)
      local name = path and path:match("([^/]+)$")
      -- NOT `name and parse_name(name)` -- Lua's `and` always truncates its
      -- right operand to a single value, which would silently discard
      -- parse_name's second return (`key`) on every call. Confirmed live
      -- 2026-10-11: that exact bug shipped in this function's first deploy
      -- and made every pass a true no-op (key always nil, so the purgeable
      -- check below could never pass) with no error and nothing in the
      -- logs -- caught by manually re-running this logic against the real
      -- DB/filesystem after a first pass reclaimed 0 bytes when ~33GB was
      -- expected.
      local media_id, key = parse_name(name or "")
      if media_id and key and mtime and (now - mtime) > MIN_AGE_SECONDS then
        local current_key = keys[media_id]
        local purgeable = not referenced[media_id] or (current_key and key ~= current_key)
        if purgeable then
          local size = 0
          if is_dir then
            local du = io.popen(string.format("du -sb %s 2>/dev/null", shell_quote(path)))
            if du then
              size = tonumber((du:read("*l") or ""):match("^(%d+)")) or 0
              du:close()
            end
            os.execute("rm -rf " .. shell_quote(path))
          else
            local f = io.open(path, "rb")
            if f then size = f:seek("end") or 0; f:close() end
            os.remove(path)
          end
          removed, freed = removed + 1, freed + size
        end
      end
    end
    handle:close()
    return removed, freed
  end

  local function sweep_once()
    local now = os.time()
    local referenced = referenced_media_ids()
    local transcode_keys, original_keys = current_media_digest_keys()
    local removed, freed = 0, 0

    local r, f = sweep_dir(M.settings.uploads_dir .. "/_video_cache", referenced, transcode_keys, now, "-type f", parse_quality_style, false)
    removed, freed = removed + r, freed + f

    r, f = sweep_dir(M.settings.uploads_dir .. "/_hls_cache", referenced, transcode_keys, now, "-type d", parse_quality_style, true)
    removed, freed = removed + r, freed + f

    -- _original_cache is sharded one level deep (_original_cache/<2-hex>/
    -- <id>_<key>.bin, see original_bytes_cache_path) -- sweep each shard
    -- directory present rather than assuming a fixed shard count/naming.
    local shard_handle = io.popen(string.format(
      "find %s -mindepth 1 -maxdepth 1 -type d -printf '%%p\\n' 2>/dev/null",
      shell_quote(M.settings.uploads_dir .. "/_original_cache")))
    if shard_handle then
      for shard_dir in shard_handle:lines() do
        r, f = sweep_dir(shard_dir, referenced, original_keys, now, "-type f", parse_flat_style, false)
        removed, freed = removed + r, freed + f
      end
      shard_handle:close()
    end

    return removed, freed
  end

  copas.addthread(function()
    while true do
      local telemetry_t0 = M.telemetry.now()
      local ok, removed_or_err, freed = pcall(sweep_once)
      local telemetry_ms = M.telemetry.ms_since(telemetry_t0)
      if not ok then
        print("[nyxframe] cache orphan sweep error: " .. tostring(removed_or_err))
        M.telemetry.job_result("cache_orphan_sweep", false, telemetry_ms, { error = tostring(removed_or_err):sub(1, 300) })
      elseif removed_or_err and removed_or_err > 0 then
        print(string.format("[nyxframe] cache orphan sweep: removed %d item(s), freed %d bytes", removed_or_err, freed or 0))
        write_audit_log(nil, "cache_orphan_sweep", "storage", nil, string.format("removed=%d bytes=%d", removed_or_err, freed or 0))
        M.telemetry.job_result("cache_orphan_sweep", true, telemetry_ms, { removed = removed_or_err, freed_bytes = freed or 0 })
      else
        M.telemetry.job_result("cache_orphan_sweep", true, telemetry_ms, nil)
      end
      copas.sleep(SWEEP_INTERVAL_SECONDS)
    end
  end)
end

-- Internals shared with src/video_extras.lua (seek sprites, captions).
--
-- ONE table assignment, not a handful of exported locals, because this
-- chunk is at LuaJIT's 200-local ceiling (see the notes at the top of
-- this file) -- `M.x = <existing local>` costs no new slot, a `local
-- exported = {...}` would have cost the last one. video_extras requires
-- this module lazily, from inside its own functions, so the two files
-- can reference each other without a load-order cycle.
M._video_extras_api = {
  check_access = hls_check_access,
  variant_dir = hls_variant_dir,
  variant_ready = hls_variant_ready,
  digest_seed = media_content_digest_seed,
  settings = function() return M.settings end,
}

return M
