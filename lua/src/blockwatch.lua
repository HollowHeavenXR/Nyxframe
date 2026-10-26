-- Event-loop stall detector (2026-10-26).
--
-- Everything in a worker shares one copas loop, so any synchronous work
-- (ffmpeg via os.execute, io.popen reads, big Lua loops) freezes every other
-- request on that worker. This times every coroutine resume and logs the
-- ones that held the loop too long, with the request they were serving (or,
-- for background jobs, where they stopped), plus slow os.execute/io.popen
-- calls with their command line. Lines start with "[block]" (a slow command
-- that ran in the background without blocking anything logs "[slow-exec]").
--
-- Must be installed BEFORE copas is first required: copas caches
-- coroutine.resume in a local at load time.
--
-- It also makes os.execute non-blocking for request handlers: when called
-- from a coroutine copas resumed directly, the command runs in the
-- background and the caller sleeps (copas.sleep) until it exits, so other
-- requests keep being served while ffmpeg works. Exit status is preserved.
-- Quick filesystem one-liners (mkdir/rm/mv/...) still run inline. At most
-- GALLERY_EXEC_CONCURRENCY (default 2) background commands run at once per
-- worker, so a page of cold thumbnails can't start 48 ffmpegs and starve
-- the music bots sharing this machine.
--
-- Env: GALLERY_BLOCK_WARN_MS (default 400), GALLERY_BLOCKWATCH=0 disables
-- both; GALLERY_ASYNC_EXEC=0 keeps os.execute synchronous.

local M = {}

local enabled = (os.getenv("GALLERY_BLOCKWATCH") or "1") ~= "0"
local WARN_MS = tonumber(os.getenv("GALLERY_BLOCK_WARN_MS")) or 400
local labels = setmetatable({}, { __mode = "k" }) -- coroutine -> "GET /api/x"
-- GALLERY_BLOCK_TRACE=1: also remember where each coroutine last yielded,
-- so a stall is reported as "from <line> at <line>" (costs a traceback per
-- yield -- diagnostics only).
local TRACE = os.getenv("GALLERY_BLOCK_TRACE") == "1"
local last_at = setmetatable({}, { __mode = "k" })
local log = function(line) io.stdout:write(line, "\n"); io.stdout:flush() end
local now

local function short(s, n)
  s = tostring(s or ""):gsub("%s+", " ")
  n = n or 220
  if #s > n then return s:sub(1, n) .. "..." end
  return s
end

-- Where a background coroutine stopped: first frame inside our own code.
local function where(co)
  local tb = debug.traceback(co, "", 0) or ""
  for line in tb:gmatch("[^\n]+") do
    local loc = line:match("(%./src/[%w_]+%.lua:%d+)") or line:match("(src/[%w_]+%.lua:%d+)")
      or line:match("(main%.lua:%d+)")
    if loc and not loc:find("blockwatch", 1, true) then return loc end
  end
  return "?"
end

function M.label(co, text) if co then labels[co] = text end end

function M.install(opts)
  if not enabled or M.installed then return end
  M.installed = true
  if opts and opts.log then log = opts.log end
  local socket = require("socket")
  now = socket.gettime

  local raw_resume = coroutine.resume
  local stack, depth = {}, 0
  M._top = function() return depth == 1 and stack[1] or nil end
  coroutine.resume = function(co, ...)
    local t0 = now()
    depth = depth + 1
    stack[depth] = co
    local r = { raw_resume(co, ...) }
    stack[depth] = nil
    depth = depth - 1
    local ms = (now() - t0) * 1000
    if ms >= WARN_MS then
      local label = labels[co]
      local status = coroutine.status(co)
      log(("[block] loop held %.0fms by %s%s%s"):format(ms,
        label and short(label, 160) or ("background " .. where(co)),
        (TRACE and last_at[co]) and (" from " .. last_at[co]) or "",
        (label and status == "suspended") and (" at " .. where(co)) or ""))
    end
    if TRACE and coroutine.status(co) == "suspended" then last_at[co] = where(co) end
    return unpack(r)
  end

  local raw_execute = os.execute
  local async_enabled = (os.getenv("GALLERY_ASYNC_EXEC") or "1") ~= "0"
  local max_running = tonumber(os.getenv("GALLERY_EXEC_CONCURRENCY")) or 2
  local running = 0
  local copas -- loaded lazily (must not load before install() finishes)

  local function is_quick(cmd)
    local c = tostring(cmd):gsub("^%s+", "")
    if c:find("ffmpeg", 1, true) or c:find("ffprobe", 1, true) or c:find("yt-dlp", 1, true)
      or c:find("curl", 1, true) or c:find("find ", 1, true) or c:find("tar ", 1, true) then
      return false
    end
    -- Recursive deletes, copies and chained commands can move a lot of
    -- data (one `rm -rf` of an HLS dir on the USB drive held a worker for
    -- 15s), so only plain single-file one-liners run inline.
    if c:find(" -r", 1, true) or c:find("||", 1, true) or c:find("&&", 1, true) or c:match("^cp ") then
      return false
    end
    return c:match("^mkdir ") or c:match("^rm ") or c:match("^mv ") or c:match("^touch ")
      or c:match("^test ") or c:match("^%[ ") or c:match("^stat ") or c:match("^ln ") or c:match("^cp ")
  end

  -- Already detached ("... &" at the end): returns at once anyway.
  local function is_detached(cmd)
    return tostring(cmd):match("&%s*$") ~= nil
  end

  local function sh_quote(x) return "'" .. tostring(x):gsub("'", "'\\''") .. "'" end

  -- opts.uncapped: don't count against GALLERY_EXEC_CONCURRENCY (the
  -- background rendition warmer, which paces itself and must never make a
  -- visitor's request wait for a slot).
  local function execute_yielding(cmd, opts)
    copas = copas or require("copas")
    local capped = not (opts and opts.uncapped)
    while capped and running >= max_running do
      if not pcall(copas.sleep, 0.05) then require("socket").sleep(0.05) end
    end
    if capped then running = running + 1 end
    local marker = os.tmpname()
    os.remove(marker)
    local ok_launch = pcall(raw_execute, string.format(
      "( ( %s ); echo $? > %s.part; mv -f %s.part %s ) </dev/null &",
      cmd, sh_quote(marker), sh_quote(marker), sh_quote(marker)))
    if not ok_launch then
      if capped then running = running - 1 end
      return raw_execute(cmd)
    end
    local delay = 0.005
    local code
    while true do
      local f = io.open(marker, "rb")
      if f then
        code = tonumber((f:read("*a") or ""):match("%d+"))
        f:close()
        os.remove(marker)
        break
      end
      -- A caller inside a C boundary (an iterator, a gsub callback) can't
      -- yield: wait without yielding instead of failing the request.
      if not pcall(copas.sleep, delay) then require("socket").sleep(delay) end
      if delay < 0.05 then delay = delay * 2 end
    end
    if capped then running = running - 1 end
    -- LuaJIT's os.execute returns the raw wait status: 0 on success,
    -- exit_code * 256 otherwise. Callers here only test == 0.
    if code == 0 then return 0 end
    return (code or 1) * 256
  end
  M.execute_yielding = execute_yielding

  os.execute = function(cmd)
    local t0 = now()
    local a, b, c
    local co = coroutine.running()
    if async_enabled and cmd and co and M._top() == co and not is_quick(cmd) and not is_detached(cmd) then
      a = execute_yielding(cmd)
      local ms = (now() - t0) * 1000
      if ms >= WARN_MS * 5 then log(("[slow-exec] os.execute %.0fms (loop stayed free): %s"):format(ms, short(cmd))) end
      return a
    end
    a, b, c = raw_execute(cmd)
    local ms = (now() - t0) * 1000
    if ms >= WARN_MS then log(("[block] os.execute %.0fms: %s"):format(ms, short(cmd))) end
    return a, b, c
  end

  -- io.popen handles: time every method call (read/lines/close) and report
  -- the total at close. Proxy table so callers keep using h:read() etc.
  local raw_popen = io.popen
  io.popen = function(cmd, mode)
    local h, err = raw_popen(cmd, mode)
    if not h then return h, err end
    local spent = 0
    local proxy = {}
    setmetatable(proxy, { __index = function(_, k)
      local f = h[k]
      if type(f) ~= "function" then return f end
      return function(_, ...)
        local t0 = now()
        local r = { f(h, ...) }
        spent = spent + (now() - t0)
        if k == "close" and spent * 1000 >= WARN_MS then
          log(("[block] io.popen %.0fms: %s"):format(spent * 1000, short(cmd)))
        end
        if k == "lines" and type(r[1]) == "function" then
          local it = r[1]
          r[1] = function(...)
            local t1 = now()
            local v = it(...)
            spent = spent + (now() - t1)
            return v
          end
        end
        return unpack(r)
      end
    end })
    return proxy
  end
end

return M
