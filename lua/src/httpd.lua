-- Minimal HTTP/1.1 JSON API server on copas+luasocket.
--
-- Framework choice (see final report for full justification): copas +
-- luasocket + a hand-rolled request/response layer, all libraries already
-- vendored/proven in this exact environment for the 13 Lua bot rewrites
-- (lua-shared/swarmlua). Rejected alternatives:
--   * OpenResty/nginx  - explicitly ruled out by the deployment model (plain
--     LuaJIT in Alpine, no nginx sidecar, matches the bots).
--   * pegasus.lua      - a reasonable pure-Lua HTTP framework, but it is a
--     NEW dependency with no track record in this project, whereas copas is
--     already installed, tested, and used for the bots' own event loop.
--   * lua-http (cqueues) - modern and full-featured, but built on cqueues, a
--     different event-loop model than the copas loop the rest of the swarm
--     already standardized on; mixing two coroutine schedulers in one
--     process is asking for trouble.
-- WebSocket upgrade: implemented below using the already-installed
-- `lua-websockets` rock's `websocket.handshake` (Sec-WebSocket-Accept
-- computation for the 101 response) and `websocket.sync` (frame
-- encode/decode glued to a socket via sock_send/sock_receive/sock_close
-- callbacks) — reusing the accepted HTTP socket directly, no second
-- listener/port needed. See M.ws_route()/handle_ws_upgrade() below. The
-- receive side does NOT reuse websocket.sync's own receive() for the read
-- loop in routes.lua's /ws handler, because that function treats every
-- socket error -- including a plain read timeout -- as a fatal disconnect,
-- and this server needs "no message in N seconds" to mean "send a keepalive
-- ping and keep waiting", matching app/routers/websocket.py's behavior.

local socket = require("socket")
local copas = require("copas")
local cjson = require("cjson.safe")
local bit = require("bit")
local ws_handshake = require("websocket.handshake")
local ws_sync = require("websocket.sync")

local M = {}
M.routes = {} -- { {method=, pattern=, keys={}, handler=} }
-- Fast path for match_route below: routes with no ":param" segment (the
-- large majority -- 158/158 of this server's registered routes contain no
-- "?"/"*" either, confirmed by grepping main.lua's httpd.route(...) calls,
-- so an exact string match on the path is behaviorally identical to the
-- regex match split_path_pattern would otherwise build for them) go in here
-- keyed by method+path for an O(1) lookup instead of a linear regex scan.
-- Routes with a ":param" still need the regex list below.
M.literal_routes = {} -- M.literal_routes[method][path] = { handler=, pattern= }
M.pattern_routes = {} -- M.pattern_routes[method] = { {regex=, keys=, handler=, pattern=}, ... }
M.ws_routes = {} -- { {pattern=, handler=} }, GET+Upgrade:websocket only, exact-path match
M.cors = { allowed_origins = {}, origin_suffix_matcher = nil }
-- CIDR allow-list of peers this server will trust an incoming
-- X-Forwarded-For header from (set by main.lua from
-- config.lua's trusted_proxy_cidrs, itself GALLERY_TRUSTED_PROXY_CIDRS).
-- Populated before M.serve() is ever called; nil/empty means "trust no
-- one" -- every request then falls back to its raw TCP peer address, same
-- as if XFF were never sent. See ip_in_trusted_cidrs() below.
M.trusted_proxy_cidrs = {}
-- Optional fallback(method, path) -> status, body, headers | nil, called only
-- when no registered route matches. Returning nil keeps the normal JSON 404
-- (see static.lua's SPA fallback, the only current user of this hook).
M.fallback_handler = nil
-- Optional hook(method, route_pattern_or_path, status, duration_ms), called
-- once per request right alongside access_log_line below. Set by main.lua to
-- telemetry.record_request -- kept as a plain settable field (not a
-- `require("telemetry")` in this file) so httpd.lua stays decoupled from the
-- telemetry/db modules; a nil hook (telemetry disabled, or main.lua never
-- set it) is just skipped.
M.on_request = nil

local function split_path_pattern(pattern)
  local keys = {}
  local regex = "^" .. pattern:gsub("([%.%-%+%[%]%(%)%$%^%%])", "%%%1"):gsub(":([%w_]+)", function(name)
    keys[#keys + 1] = name
    return "([^/]+)"
  end) .. "$"
  return regex, keys
end

function M.route(method, pattern, handler)
  local regex, keys = split_path_pattern(pattern)
  local entry = { method = method, regex = regex, keys = keys, handler = handler, pattern = pattern }
  M.routes[#M.routes + 1] = entry
  if #keys > 0 then
    M.pattern_routes[method] = M.pattern_routes[method] or {}
    local bucket = M.pattern_routes[method]
    bucket[#bucket + 1] = entry
  else
    M.literal_routes[method] = M.literal_routes[method] or {}
    M.literal_routes[method][pattern] = entry
  end
end

-- WS routes are exact-path only (just "/ws" today) — no :param support needed.
-- handler(conn, req, sock) owns the full connection lifecycle (its own
-- receive/send loop) and is called once per accepted upgrade; httpd closes
-- the socket when the handler returns, if it isn't already closed.
function M.ws_route(pattern, handler)
  M.ws_routes[#M.ws_routes + 1] = { pattern = pattern, handler = handler }
end

local function match_ws_route(path)
  for _, r in ipairs(M.ws_routes) do
    if r.pattern == path then return r.handler end
  end
  return nil
end

-- Third return value is the registered pattern string itself (e.g.
-- "/api/media/:media_id"), not the raw path -- M.on_request below buckets
-- telemetry by this so a distinct media_id/job_id per request doesn't blow
-- up the bucket count.
--
-- Literal (no ":param") routes are the large majority -- checked first via
-- an O(1) table lookup instead of a linear regex scan over every registered
-- route. Only a path that misses the literal table falls through to the
-- much smaller parametrized-route list for that method.
local function match_route(method, path)
  local literal_bucket = M.literal_routes[method]
  local lit = literal_bucket and literal_bucket[path]
  if lit then return lit.handler, {}, lit.pattern end

  local pattern_bucket = M.pattern_routes[method]
  if pattern_bucket then
    for _, r in ipairs(pattern_bucket) do
      local caps = { path:match(r.regex) }
      if caps[1] ~= nil then
        local params = {}
        for i, k in ipairs(r.keys) do params[k] = caps[i] end
        return r.handler, params, r.pattern
      end
    end
  end
  return nil
end

-- Minimal multipart/form-data parser for file uploads (mirrors what FastAPI's
-- UploadFile/Form(...) parsing gives app/routers/media.py's upload_media).
-- Whole body is already in memory by the time this runs (see the
-- content-length read in handle_connection below) -- same tradeoff already
-- accepted elsewhere in this port (e.g. media_files.lua's ffmpeg shell-out)
-- rather than streaming multi-GB uploads to a temp file the way Python's
-- _read_validated_upload_streamed does; fine for this deployment's traffic
-- level, revisit if very large uploads become common.
local function parse_multipart(body, boundary)
  -- Index-based: each field's bytes are copied out of `body` exactly once
  -- (the old version made four full copies of every file part -- part,
  -- leading-CRLF strip, content, trailing-CRLF strip -- which for an 80MB
  -- upload meant ~320MB of garbage and a long stop-the-world GC).
  local form, files = {}, {}
  local delim = "--" .. boundary
  local _, e = body:find(delim, 1, true)
  while e do
    local next_s = body:find(delim, e + 1, true)
    if not next_s then break end
    local ps = e + 1
    if body:sub(ps, ps + 1) == "\r\n" then ps = ps + 2 end
    local header_end = body:find("\r\n\r\n", ps, true)
    if header_end and header_end < next_s then
      local header_block = body:sub(ps, header_end - 1)
      local cs, ce = header_end + 4, next_s - 1
      if ce - cs >= 1 and body:sub(ce - 1, ce) == "\r\n" then ce = ce - 2 end
      local name = header_block:match('name="([^"]*)"')
      local filename = header_block:match('filename="([^"]*)"')
      local content_type = header_block:match("[Cc]ontent%-[Tt]ype:%s*([^\r\n]+)")
      if name and filename ~= nil then
        files[name] = { filename = filename, content_type = content_type, content = body:sub(cs, ce) }
      elseif name then
        form[name] = body:sub(cs, ce)
      end
    end
    e = next_s + #delim - 1
  end
  return form, files
end

local function url_decode(s)
  s = s:gsub("+", " ")
  s = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
  return s
end

local function parse_query(qs)
  local out = {}
  if not qs then return out end
  for pair in qs:gmatch("[^&]+") do
    local k, v = pair:match("^([^=]+)=?(.*)$")
    if k then out[url_decode(k)] = url_decode(v or "") end
  end
  return out
end

local function origin_allowed(origin)
  if not origin or origin == "" then return false end
  for _, allowed in ipairs(M.cors.allowed_origins) do
    if allowed == origin then return true end
  end
  if M.cors.origin_suffix_matcher and M.cors.origin_suffix_matcher(origin) then
    return true
  end
  return false
end

-- Baseline security headers, applied to every response. Nothing here is
-- environment-specific (unlike CORS) so it's safe to hardcode: this backend
-- is only ever reached over HTTPS in production (the Cloudflare tunnel
-- terminates TLS in front of it), and there's no legitimate reason for this
-- API/gallery to be framed by another site or have the browser MIME-sniff
-- its responses.
local function apply_security_headers(headers_out)
  -- Pins HTTPS for a year including subdomains, and opts into the browser
  -- preload list -- closes the window where a plain http:// first request
  -- could be intercepted before ever seeing a redirect.
  headers_out["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains; preload"
  headers_out["X-Content-Type-Options"] = "nosniff"
  headers_out["X-Frame-Options"] = "DENY"
  headers_out["Referrer-Policy"] = "strict-origin-when-cross-origin"
end

local function apply_cors(headers_out, req_headers)
  apply_security_headers(headers_out)
  local origin = req_headers["origin"]
  if origin_allowed(origin) then
    headers_out["Access-Control-Allow-Origin"] = origin
    headers_out["Access-Control-Allow-Credentials"] = "true"
    headers_out["Vary"] = "Origin"
  end
  headers_out["Access-Control-Allow-Methods"] = "GET, POST, PUT, PATCH, DELETE, OPTIONS"
  headers_out["Access-Control-Allow-Headers"] = "Authorization, Content-Type"
end

local function read_headers(sock)
  local headers = {}
  local first_line = nil
  while true do
    local line, err = copas.receive(sock, "*l")
    if not line then return nil, nil, err end
    if first_line == nil then
      first_line = line
    elseif line == "" then
      break
    else
      local k, v = line:match("^([^:]+):%s*(.*)$")
      if k then headers[k:lower()] = v end
    end
  end
  return first_line, headers
end

-- Idle-read timeout (seconds) for a kept-alive connection waiting on its
-- NEXT request. Applied to the whole socket right after accept (so it also
-- bounds how long a freshly-opened connection can sit there never sending a
-- request line at all), not just between requests. Generous enough for any
-- real client/browser's between-request gap on an open page, short enough
-- that an idle/dead connection doesn't sit on a coroutine indefinitely now
-- that connections can outlive a single request.
local KEEP_ALIVE_IDLE_SECONDS = 15

-- A response is always fully buffered with an exact Content-Length (see
-- handle_connection -- every handler's return value goes through this, no
-- code path anywhere streams directly to the socket), which is exactly
-- what HTTP/1.1 keep-alive needs: the client can find the end of this
-- response without relying on the connection closing, so the socket is
-- safe to reuse for another request right after.
local function send_response(sock, status, status_text, headers, body, keep_alive)
  body = body or ""
  headers["Content-Length"] = tostring(#body)
  if keep_alive then
    headers["Connection"] = "keep-alive"
    headers["Keep-Alive"] = "timeout=" .. KEEP_ALIVE_IDLE_SECONDS
  else
    headers["Connection"] = "close"
  end
  headers["Server"] = "SwarmPanel-Lua"
  local lines = { string.format("HTTP/1.1 %d %s", status, status_text) }
  for k, v in pairs(headers) do
    lines[#lines + 1] = string.format("%s: %s", k, tostring(v))
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = body
  copas.send(sock, table.concat(lines, "\r\n"))
end

-- HTTP/1.1 defaults to persistent connections unless the client sent
-- "Connection: close"; HTTP/1.0 is the opposite (closes by default unless
-- the client explicitly asked for "Connection: keep-alive"). version is the
-- "1.1"/"1.0" capture from the request line, nil if somehow unparseable
-- (treated as 1.0's stricter default).
local function wants_keep_alive(headers, version)
  local conn_hdr = (headers["connection"] or ""):lower()
  if conn_hdr:find("close", 1, true) then return false end
  if version == "1.1" then return true end
  -- plain=true below means NO pattern escaping -- "-" needs no "%-" here
  -- (that literal "%" would never appear in a real Connection header, which
  -- is exactly the bug this comment is pinned next to: an earlier version
  -- of this line searched for the escaped pattern text itself instead of a
  -- literal "keep-alive" substring, so it never matched).
  return conn_hdr:find("keep-alive", 1, true) ~= nil
end

local STATUS_TEXT = {
  [200] = "OK", [201] = "Created", [202] = "Accepted", [204] = "No Content", [206] = "Partial Content",
  [301] = "Moved Permanently", [303] = "See Other",
  [400] = "Bad Request", [401] = "Unauthorized", [403] = "Forbidden",
  [404] = "Not Found", [405] = "Method Not Allowed", [409] = "Conflict",
  [416] = "Range Not Satisfiable",
  [429] = "Too Many Requests", [500] = "Internal Server Error",
  [503] = "Service Unavailable",
}

-- Accepts a WS upgrade on the already-accepted HTTP socket and hands off to
-- the registered handler for the rest of the connection's lifetime. Mirrors
-- websocket.handshake.accept_upgrade()'s own validation (upgrade/connection/
-- version/key headers present) but works from the already-parsed headers
-- table instead of re-parsing raw request text, since httpd.lua already did
-- that in read_headers().
local function handle_ws_upgrade(sock, headers, path, query, handler)
  local key = headers["sec-websocket-key"]
  local version = headers["sec-websocket-version"]
  local connection_hdr = (headers["connection"] or ""):lower()
  if not key or key == "" or version ~= "13" or not connection_hdr:match("upgrade") then
    pcall(copas.send, sock, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    return
  end
  local origin = headers["origin"]
  if origin and origin ~= "" and not origin_allowed(origin) then
    pcall(copas.send, sock, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    return
  end

  local accept_key = ws_handshake.sec_websocket_accept(key)
  local resp = "HTTP/1.1 101 Switching Protocols\r\n"
    .. "Upgrade: websocket\r\n"
    .. "Connection: Upgrade\r\n"
    .. "Sec-WebSocket-Accept: " .. accept_key .. "\r\n\r\n"
  local sent = copas.send(sock, resp)
  if not sent then
    pcall(function() sock:close() end)
    return
  end

  local conn = { is_server = true, state = "OPEN" }
  conn.sock_send = function(_, ...) return copas.send(sock, ...) end
  conn.sock_receive = function(_, ...) return copas.receive(sock, ...) end
  conn.sock_close = function(_)
    pcall(function() sock:shutdown() end)
    pcall(function() sock:close() end)
  end
  conn = ws_sync.extend(conn)

  local req = { path = path, query = query or {}, headers = headers }
  local ok, err = pcall(handler, conn, req, sock)
  if not ok then
    print("[swarmpanel-lua] ws handler error: " .. tostring(err))
  end
  if conn.state ~= "CLOSED" then
    pcall(function() conn:close() end)
  end
  pcall(function() sock:close() end)
end

-- ---------------------------------------------------------------------------
-- Access logging (Feature: request/status logging).
--
-- Previously this server logged nothing per-request at all -- no method,
-- path, status, timing, or client IP for any request, successful or not.
-- Combined with the unhandled-error swallowing this same file used to have
-- (see the 500 path below), that meant there was no way to answer "what did
-- the last hour of traffic actually look like" short of adding print()
-- statements by hand, reproducing, and removing them again -- exactly what
-- happened while diagnosing the HLS transcode-slot leak this same session.
--
-- One line per request, written to stdout (captured by journald under this
-- service's unit, same as every other log line here) once the response has
-- actually been sent, so the logged status always reflects what the client
-- received -- not what a handler intended to send before some later step
-- (CORS headers, body encoding) failed.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Trusted-proxy CIDR matching, for deciding whether to honor an incoming
-- X-Forwarded-For header at all (see M.trusted_proxy_cidrs above). No CIDR
-- utility existed anywhere in this codebase before this fix (confirmed via
-- grep across lua/src/*.lua) -- this is intentionally small: it only needs
-- to handle the shapes GALLERY_TRUSTED_PROXY_CIDRS actually holds
-- ("a.b.c.d/n" for IPv4, "addr/128" for an exact IPv6 match), not full
-- generality.
-- ---------------------------------------------------------------------------

local function ipv4_to_int(ip)
  local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if not (a and b and c and d) then return nil end
  if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
  return a * 16777216 + b * 65536 + c * 256 + d
end

-- ip: plain address string (no port). cidr: "network/bits", or a bare
-- address (treated as an exact match, bits implied = full width).
local function ip_in_cidr(ip, cidr)
  if not ip or ip == "" then return false end
  local net, bits_str = cidr:match("^([^/]+)/(%d+)$")
  if not net then
    return ip == cidr
  end
  local bits = tonumber(bits_str)
  local is_v6 = ip:find(":", 1, true) or net:find(":", 1, true)
  if is_v6 then
    -- Only IPv6 CIDR actually configured for this deployment is ::1/128
    -- (loopback, exact match) -- rather than implement full 128-bit prefix
    -- math for a case that never comes up, this fails closed (does not
    -- match) for any IPv6 prefix shorter than /128, and does a plain string
    -- compare for /128.
    if bits >= 128 then return ip == net end
    return false
  end
  local ip_int, net_int = ipv4_to_int(ip), ipv4_to_int(net)
  if not ip_int or not net_int then return false end
  if bits <= 0 then return true end
  if bits >= 32 then return ip_int == net_int end
  local mask = bit.bnot(bit.rshift(0xFFFFFFFF, bits)) -- LuaJIT bit.* args/results are 32-bit
  return bit.band(ip_int, mask) == bit.band(net_int, mask)
end

local function ip_in_trusted_cidrs(ip)
  for _, cidr in ipairs(M.trusted_proxy_cidrs or {}) do
    if ip_in_cidr(ip, cidr) then return true end
  end
  return false
end

local function access_log_line(method, path, status, duration_ms, client_ip, user_agent)
  local level = (status and status >= 500) and "ERROR"
    or (status and status >= 400) and "WARN"
    or "INFO"
  print(string.format(
    "[access] %-5s %-45s %3d  %6.1fms  ip=%s  level=%s ua=%s",
    tostring(method or "?"), tostring(path or "?"), tonumber(status) or 0,
    duration_ms, tostring(client_ip or "?"), level,
    tostring((user_agent or ""):sub(1, 80))
  ))
end

-- Serves exactly one request off `sock` and returns whether the connection
-- should stay open for another one. Split out of handle_connection so that
-- function can loop this for HTTP/1.1 keep-alive instead of closing the
-- socket after every single request (see KEEP_ALIVE_IDLE_SECONDS above).
local function serve_one_request(sock, start_time)
  -- Populated as the request is parsed, so a log line can still be written
  -- (with whatever's known so far) even for a request that fails before a
  -- route was ever matched -- e.g. a malformed request line.
  local log_method, log_path, log_status, log_ip, log_ua = nil, nil, nil, nil, nil
  local log_route_pattern = nil
  -- Defaults to false (close): every early-exit path below (no request
  -- line at all, a malformed one, a WS upgrade handing the socket off to
  -- its own lifecycle) wants that default. It only ever becomes true once
  -- headers are parsed AND the client/HTTP-version actually asked for it.
  local keep_alive = false

  -- Every response in this function should go through this instead of
  -- calling send_response directly, purely so log_status always reflects
  -- what actually got sent to the client, from every exit path below.
  local function respond(status, status_text, headers, body)
    log_status = status
    send_response(sock, status, status_text, headers, body, keep_alive)
  end

  local ok, result = pcall(function()
    local first_line, headers = read_headers(sock)
    if not first_line then return false end
    -- Time from the request's arrival, not from when this kept-alive
    -- connection started waiting for it (that idle gap used to be counted
    -- as request time in the access log and route telemetry).
    start_time = socket.gettime()
    local method, path_and_query, version = first_line:match("^(%u+)%s+(%S+)%s+HTTP/(%d%.%d)")
    log_method = method or "?"
    if method then require("blockwatch").label(coroutine.running(), method .. " " .. path_and_query) end
    if not method then
      respond(400, "Bad Request", {}, cjson.encode({ detail = "Malformed request line" }))
      return false
    end
    keep_alive = wants_keep_alive(headers, version)
    local path, qs = path_and_query:match("^([^?]*)%??(.*)$")
    log_path = path
    local query = parse_query(qs)

    -- Client IP + User-Agent computed here (not just on the matched-route
    -- path below) so even a 400/404/OPTIONS response still logs who sent
    -- it. Only honors X-Forwarded-For when the actual TCP peer (this
    -- backend sits behind the cloudflared tunnel / nyxframe-proxy) is
    -- itself in M.trusted_proxy_cidrs -- otherwise ANY visitor could set
    -- their own X-Forwarded-For header and have it trusted outright, which
    -- silently defeated every IP-keyed rate limit in routes.lua
    -- (registration, login lockout, download-batch: an attacker could just
    -- roll the header to reset their own bucket on every request). Falls
    -- back to the raw peer address for direct/untrusted connections either
    -- way. Mirrors security.py's _client_ip(), now with the trust check
    -- Python's version already had.
    local peer_ok, peer_ip = pcall(function() return (sock:getpeername()) end)
    peer_ip = (peer_ok and peer_ip) or "unknown"
    local client_ip = peer_ip
    if ip_in_trusted_cidrs(peer_ip) then
      local xff = (headers["x-forwarded-for"] or ""):match("^[^,]+")
      xff = xff and xff:match("^%s*(.-)%s*$")
      if xff and xff ~= "" then client_ip = xff end
    end
    log_ip = client_ip
    log_ua = headers["user-agent"]

    if method == "GET" and (headers["upgrade"] or ""):lower() == "websocket" then
      local ws_handler = match_ws_route(path)
      if ws_handler then
        log_status = 101
        handle_ws_upgrade(sock, headers, path, query, ws_handler)
        -- The socket's lifecycle now belongs entirely to the WS handler
        -- (which closes it itself) -- nothing left for the HTTP
        -- keep-alive loop to do with it.
        return false
      end
      -- No matching WS route: fall through to the normal 404 path below (no
      -- body to read on a GET+Upgrade request either way).
    end

    local body = ""
    local content_length = tonumber(headers["content-length"] or "0") or 0
    if content_length > 0 then
      local data = copas.receive(sock, content_length)
      if data then
        body = data
      else
        -- Incomplete/failed body read: the socket's read position no
        -- longer lines up with where the next request would start, so
        -- this connection can't safely be reused for another request
        -- even if the client asked to keep-alive.
        keep_alive = false
      end
    end

    local resp_headers = {}
    apply_cors(resp_headers, headers)

    if method == "OPTIONS" then
      respond(204, "No Content", resp_headers, "")
      return keep_alive
    end

    local handler, params, route_pattern = match_route(method, path)
    log_route_pattern = route_pattern
    if not handler then
      if M.fallback_handler then
        local fb_status, fb_body, fb_headers = M.fallback_handler(method, path, headers)
        if fb_status then
          for k, v in pairs(fb_headers or {}) do resp_headers[k] = v end
          respond(fb_status, STATUS_TEXT[fb_status] or "OK", resp_headers, fb_body)
          return keep_alive
        end
      end
      resp_headers["Content-Type"] = "application/json"
      respond(404, "Not Found", resp_headers, cjson.encode({ detail = "Not found" }))
      return keep_alive
    end

    local req = {
      method = method,
      path = path,
      query = query,
      params = params or {},
      headers = headers,
      raw_body = body,
      client_ip = client_ip,
      form = {},
      files = {},
    }
    local content_type = headers["content-type"] or ""
    if body ~= "" and content_type:match("application/json") then
      local decoded = cjson.decode(body)
      req.json = decoded or {}
    elseif body ~= "" and content_type:match("multipart/form%-data") then
      local boundary = content_type:match('boundary="?([^";]+)"?')
      if boundary then
        req.form, req.files = parse_multipart(body, boundary)
      end
      req.json = {}
    else
      req.json = {}
    end

    local status, resp_body, extra_headers = handler(req)
    status = status or 200
    for k, v in pairs(extra_headers or {}) do resp_headers[k] = v end
    resp_headers["Content-Type"] = resp_headers["Content-Type"] or "application/json"
    local body_out
    if type(resp_body) == "table" then
      body_out = cjson.encode(resp_body)
    else
      body_out = tostring(resp_body or "")
    end
    -- access_log_line only ever printed method/path/status/timing -- the
    -- actual `detail` text (e.g. "Could not save media: nil") never made it
    -- to journalctl anywhere, so a fast client-side toast was the ONLY place
    -- an error's real message ever appeared, gone the moment the page moved
    -- on. Print it here too, truncated so a huge payload (e.g. validation
    -- errors echoing a big form) can't flood the log.
    if status >= 400 then
      print(string.format("[error-detail] %s %s -> %d: %s", method, path, status, body_out:sub(1, 500)))
    end
    respond(status, STATUS_TEXT[status] or "OK", resp_headers, body_out)
    return keep_alive
  end)
  if not ok then
    -- Previously silent: `result` (the pcall error message on this branch)
    -- was caught but never logged anywhere, so every 500 was completely
    -- invisible in `journalctl` -- the only way to diagnose one was
    -- reproducing it with ad-hoc print() patches added and removed by
    -- hand. print() here goes to the unit's stdout, same as every other
    -- log line this service already emits.
    print("[nyxframe] unhandled error: " .. tostring(result))
    log_status = 500
    -- Force-close rather than trust keep_alive from whatever state things
    -- were in when the error hit -- an exception partway through (e.g.
    -- mid body-read or mid JSON decode) can leave the socket's read
    -- position unknown, which would desync whatever request comes next on
    -- a reused connection.
    keep_alive = false
    pcall(respond, 500, "Internal Server Error", { ["Content-Type"] = "application/json" }, cjson.encode({ detail = "Internal server error" }))
  else
    keep_alive = result or false
  end
  if log_method then
    -- log_method is only nil for a connection that closed before sending
    -- any request line at all (e.g. a TCP health-check probe, or this
    -- connection's keep-alive idle timeout firing while waiting on the
    -- NEXT request) -- nothing meaningful to log for those.
    local duration_ms = (socket.gettime() - start_time) * 1000
    access_log_line(log_method, log_path, log_status, duration_ms, log_ip, log_ua)
    if M.on_request then
      -- log_route_pattern is nil for a 404/OPTIONS/websocket-upgrade path (no
      -- registered :param route matched) or a request that failed before
      -- routing ran at all -- the raw path is still a reasonable bucket key
      -- for those (a malformed/unmatched path has no :id segments to blow up
      -- cardinality with).
      pcall(M.on_request, log_method, log_route_pattern or log_path, log_status, duration_ms)
    end
    io.stdout:flush()
  end
  return keep_alive
end

-- Loops serve_one_request over the same socket for as long as the client
-- and this server both agree to keep it open (see wants_keep_alive),
-- instead of the pre-keep-alive behavior of closing after exactly one
-- request. settimeout applies to every read on this socket, including the
-- very first request line -- it's what turns an idle/dead connection (a
-- client that opened a socket and then sent nothing, or a reused
-- connection nobody sent another request on) into a clean close instead of
-- tying up a coroutine indefinitely, now that a connection's lifetime is no
-- longer bounded by "exactly one request".
local function handle_connection(sock)
  -- BUGFIX 2026-10-26: this used to be sock:settimeout(KEEP_ALIVE_IDLE_SECONDS)
  -- on the raw socket, which makes it a BLOCKING socket again -- copas needs
  -- it at 0. Every kept-alive connection then froze the whole worker inside
  -- recv() while it waited for the client's next request (up to the full 15s
  -- idle timeout). Cloudflare's tunnel always reuses connections, so this
  -- was the 5-40s "site loads slowly" stall on nearly every page. The idle
  -- timeout now lives in copas (read side only, so a long download to a slow
  -- client isn't cut off).
  sock:settimeout(0)
  copas.settimeouts(sock, nil, nil, KEEP_ALIVE_IDLE_SECONDS)
  while true do
    local start_time = socket.gettime()
    local keep_alive = serve_one_request(sock, start_time)
    if not keep_alive then break end
  end
  pcall(function() sock:close() end)
end

function M.listen(host, port)
  local server = assert(socket.bind(host, port))
  server:settimeout(0)
  copas.addserver(server, handle_connection)
  print(string.format("[swarmpanel-lua] listening on %s:%d", host, port))
end

function M.run()
  copas.loop()
end

return M
