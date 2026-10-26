-- Auth primitives: password hashing (PBKDF2-HMAC-SHA256, wire-compatible with
-- the Python app's `pbkdf2_sha256$<iter>$<b64 salt>$<b64 digest>` format so
-- any account rows created by either backend stay readable by the other) and
-- signed opaque bearer tokens / session values.
--
-- Design note on tokens: the Python app used itsdangerous.URLSafeTimedSerializer
-- (a specific byte format tied to Python's itsdangerous library) for both the
-- session cookie and the `Authorization: Bearer <token>` API token. This is a
-- full backend rewrite, not a shim living alongside a still-running Python
-- instance, and the frontend (frontend/src/api.js) treats both the cookie and
-- the bearer token as completely opaque — it never parses them, only stores
-- and replays them (see api.js using `credentials: "omit"` and sessionStorage
-- for the bearer token). So byte-for-byte itsdangerous compatibility is not
-- required for the contract to keep working; what matters is that THIS
-- backend can consistently issue and verify its own tokens. We use a plain
-- HMAC-SHA256-signed JSON payload with an embedded expiry instead.

local cjson = require("cjson")
local sodium = require("luasodium")

local M = {}

local B64_VARIANT = sodium.sodium_base64_VARIANT_URLSAFE_NO_PADDING

local function b64url_encode(bin)
  return sodium.sodium_bin2base64(bin, B64_VARIANT)
end

local function b64url_decode(text)
  local ok, bin = pcall(sodium.sodium_base642bin, text, B64_VARIANT)
  if not ok then return nil end
  return bin
end

-- Generic, spec-compliant HMAC-SHA256 (arbitrary-length key), built on
-- libsodium's crypto_hash_sha256. libsodium's own crypto_auth_hmacsha256
-- requires a fixed 32-byte key so it can't be used directly for PBKDF2 or for
-- signing with our variable-length session secret.
local BLOCKSIZE = 64

local function xor_pad(key, byte)
  local out = {}
  for i = 1, #key do
    out[i] = string.char(bit_xor_byte(key:byte(i), byte))
  end
  return table.concat(out)
end

-- LuaJIT has bit.band/bxor via the `bit` library; use it if present, else a
-- tiny fallback table (only needed for the two constant XOR bytes 0x36/0x5c).
local bit_ok, bitlib = pcall(require, "bit")
local XOR_TABLE
if not bit_ok then
  XOR_TABLE = {}
  for a = 0, 255 do
    XOR_TABLE[a] = {}
    for b = 0, 255 do
      local x, y, r, bitv = a, b, 0, 1
      while x > 0 or y > 0 do
        local abit, bbit = x % 2, y % 2
        if abit ~= bbit then r = r + bitv end
        x, y, bitv = (x - abit) / 2, (y - bbit) / 2, bitv * 2
      end
      XOR_TABLE[a][b] = r
    end
  end
end

function bit_xor_byte(a, b)
  if bit_ok then return bitlib.bxor(a, b) end
  return XOR_TABLE[a][b]
end

function M.sha256(msg)
  return sodium.crypto_hash_sha256(msg)
end

-- Mirrors app/db/helpers.py's _verification_token_hash(): hex-encoded SHA-256
-- of the raw verification token/code, used for the *_verification_*_hash
-- columns (webhook_verification_code_hash, email_verification_token_hash,
-- etc.) so a verification code is never stored in plaintext.
function M.verification_token_hash(token)
  return sodium.sodium_bin2hex(M.sha256(tostring(token or "")))
end

-- Mirrors app/verification.py's _verification_code(): an 8-digit numeric
-- code from a CSPRNG (secrets.randbelow() in Python; libsodium's
-- randombytes_uniform() here — plain math.random() is NOT seeded from a
-- secure source and would make verification codes guessable/predictable).
function M.verification_code()
  return string.format("%08d", sodium.randombytes_uniform(100000000))
end

function M.hmac_sha256(key, msg)
  if #key > BLOCKSIZE then key = M.sha256(key) end
  if #key < BLOCKSIZE then key = key .. string.rep("\0", BLOCKSIZE - #key) end
  local ipad = xor_pad(key, 0x36)
  local opad = xor_pad(key, 0x5c)
  return M.sha256(opad .. M.sha256(ipad .. msg))
end

-- PBKDF2-HMAC-SHA256(password, salt, iterations, dklen) — matches Python's
-- hashlib.pbkdf2_hmac("sha256", password, salt, iterations) byte-for-byte.
-- OpenSSL's native PBKDF2 (luaossl) when available: same bytes, but ~17x
-- faster (140ms vs 2.4s for the 260k-iteration login check). This runs on
-- the request's worker without yielding, so the Lua loop below froze every
-- other request on that worker for 2.5-5s per login/sign-up.
local ossl_kdf_ok, ossl_kdf = pcall(require, "openssl.kdf")

function M.pbkdf2_hmac_sha256(password, salt, iterations, dklen)
  dklen = dklen or 32
  if ossl_kdf_ok then
    local ok, out = pcall(ossl_kdf.derive, {
      type = "PBKDF2", md = "sha256", pass = password, salt = salt, iter = iterations, outlen = dklen,
    })
    if ok and type(out) == "string" and #out == dklen then return out end
  end
  local hlen = 32
  local blocks_needed = math.ceil(dklen / hlen)
  local dk_parts = {}
  for block_index = 1, blocks_needed do
    local int_be = string.char(
      bit_xor_byte(0, 0) -- placeholder, overwritten below (kept for clarity)
    )
    -- big-endian uint32 block index
    local i = block_index
    int_be = string.char(
      math.floor(i / 16777216) % 256,
      math.floor(i / 65536) % 256,
      math.floor(i / 256) % 256,
      i % 256
    )
    local u = M.hmac_sha256(password, salt .. int_be)
    local t = u
    for _ = 2, iterations do
      u = M.hmac_sha256(password, u)
      local next_t = {}
      for byte_index = 1, hlen do
        next_t[byte_index] = string.char(bit_xor_byte(t:byte(byte_index), u:byte(byte_index)))
      end
      t = table.concat(next_t)
    end
    dk_parts[#dk_parts + 1] = t
  end
  return table.concat(dk_parts):sub(1, dklen)
end

local PBKDF2_ITERATIONS = 260000

function M.password_hash(password)
  local salt = sodium.randombytes_buf and sodium.randombytes_buf(16) or tostring(math.random())
  local digest = M.pbkdf2_hmac_sha256(password, salt, PBKDF2_ITERATIONS, 32)
  return string.format(
    "pbkdf2_sha256$%d$%s$%s",
    PBKDF2_ITERATIONS,
    sodium.sodium_bin2base64(salt, sodium.sodium_base64_VARIANT_ORIGINAL),
    sodium.sodium_bin2base64(digest, sodium.sodium_base64_VARIANT_ORIGINAL)
  )
end

function M.verify_password_hash(password, stored_hash)
  if not stored_hash or stored_hash == "" then return false end
  local algo, iter_text, salt_b64, digest_b64 = stored_hash:match("^([^$]+)%$([^$]+)%$([^$]+)%$([^$]+)$")
  if algo ~= "pbkdf2_sha256" then return false end
  local iterations = tonumber(iter_text)
  local ok1, salt = pcall(sodium.sodium_base642bin, salt_b64, sodium.sodium_base64_VARIANT_ORIGINAL)
  local ok2, expected = pcall(sodium.sodium_base642bin, digest_b64, sodium.sodium_base64_VARIANT_ORIGINAL)
  if not (ok1 and ok2 and iterations) then return false end
  local actual = M.pbkdf2_hmac_sha256(password, salt, iterations, #expected)
  if #actual ~= #expected then return false end
  local diff = 0
  for i = 1, #actual do
    diff = bit_xor_byte(diff, bit_xor_byte(actual:byte(i), expected:byte(i)))
  end
  return diff == 0
end

-- ---------------------------------------------------------------------------
-- Signed tokens (session cookie value AND `Authorization: Bearer` API token)
-- ---------------------------------------------------------------------------

-- payload: a plain table (username/role/guild_id/site_owner/moderator/admin_mode).
-- Encoded as base64url(json) + "." + base64url(expires_at) + "." + base64url(hmac).
function M.issue_token(secret, payload, ttl_seconds)
  local body = {}
  for k, v in pairs(payload) do body[k] = v end
  body.exp = os.time() + (ttl_seconds or 43200)
  local json = cjson.encode(body)
  local json_part = b64url_encode(json)
  local sig = M.hmac_sha256(secret, json_part)
  local sig_part = b64url_encode(sig)
  return json_part .. "." .. sig_part
end

-- Returns decoded payload table, or nil if missing/invalid/expired.
function M.verify_token(secret, token)
  if not token or token == "" then return nil end
  local json_part, sig_part = token:match("^([^.]+)%.([^.]+)$")
  if not json_part then return nil end
  local expected_sig = M.hmac_sha256(secret, json_part)
  local given_sig = b64url_decode(sig_part)
  if not given_sig or #given_sig ~= #expected_sig then return nil end
  local diff = 0
  for i = 1, #expected_sig do
    diff = bit_xor_byte(diff, bit_xor_byte(expected_sig:byte(i), given_sig:byte(i)))
  end
  if diff ~= 0 then return nil end
  local json = b64url_decode(json_part)
  if not json then return nil end
  local ok, payload = pcall(cjson.decode, json)
  if not ok or type(payload) ~= "table" then return nil end
  if payload.exp and os.time() > payload.exp then return nil end
  return payload
end

-- Mirrors auth.py's issue_api_token()/verify_api_token() field defaults.
function M.issue_api_token(secret, username, opts)
  opts = opts or {}
  local payload = {
    username = username,
    role = opts.role or "admin",
    site_owner = opts.site_owner and true or false,
    moderator = opts.moderator and true or false,
  }
  if opts.guild_id and opts.guild_id ~= "" then payload.guild_id = tostring(opts.guild_id) end
  local admin_mode = opts.admin_mode
  if admin_mode == nil then
    admin_mode = (opts.site_owner and true or false) and (tostring(opts.role or "admin"):lower() == "admin") and not opts.guild_id
  end
  payload.admin_mode = admin_mode and true or false
  return M.issue_token(secret, payload, opts.ttl_seconds)
end

function M.verify_api_token(secret, token)
  local data = M.verify_token(secret, token)
  if not data then return nil end
  if data.role == nil then data.role = data.guild_id and "account" or "admin" end
  if data.site_owner == nil then data.site_owner = false end
  if data.moderator == nil then data.moderator = false end
  if data.admin_mode == nil then
    data.admin_mode = data.site_owner and (tostring(data.role):lower() == "admin") and not data.guild_id
  end
  return data
end

function M.extract_bearer_token(authorization_header)
  if not authorization_header then return nil end
  local token = authorization_header:match("^[Bb]earer%s+(.+)$")
  if token then token = token:match("^%s*(.-)%s*$") end
  if token == "" then return nil end
  return token
end

local function constant_time_eq(a, b)
  if #a ~= #b then return false end
  local diff = 0
  for i = 1, #a do
    diff = bit_xor_byte(diff, bit_xor_byte(a:byte(i), b:byte(i)))
  end
  return diff == 0
end
M.constant_time_eq = constant_time_eq

function M.verify_credentials(username, password, expected_username, expected_password)
  if not expected_password or expected_password == "" then return false end
  return constant_time_eq(username, expected_username) and constant_time_eq(password, expected_password)
end

return M
