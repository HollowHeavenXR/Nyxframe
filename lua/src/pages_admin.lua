-- Server-rendered site-owner admin/moderation dashboard at
-- gallery.xenusanimations.studio/admin -- another "safe to rewrite" slice
-- (see pages_auth.lua's header comment for the same rationale): read-heavy
-- tables with simple per-row POST-button actions, exactly the data-table +
-- form pattern SwarmPanel's own admin pages already use, and single-user
-- facing (site-owner only) so a visual mismatch with the React app carries
-- no risk to regular users.
--
-- One page, one GET request, six stacked sections (not a tabbed JS UI --
-- no client-side state needed for a page only the owner ever opens).
-- Every action button is its own <form method="POST"> to a dedicated path
-- under /admin/actions/*, which calls the corresponding routes.admin_*
-- handler (reused directly, not reimplemented) and redirects back to
-- /admin with a "?flash=" query message on completion.

local routes = require("routes")
local html = require("html")
local cjson = require("cjson.safe")

local esc = html.esc
local parse_urlencoded = html.parse_urlencoded
local format_bytes = html.format_bytes
local format_date = html.format_date

local M = {}

local HTML_HEADERS = { ["Content-Type"] = "text/html; charset=utf-8" }

local function layout_error(message)
  return ([[<!doctype html><html><head><meta charset="utf-8"><title>Admin</title></head>
<body style="background:#101318;color:#e7e9ee;font-family:sans-serif;padding:40px;">
<p>%s</p><p><a href="/" style="color:#37c9a7;">Back to Nyxframe</a></p>
</body></html>]]):format(esc(message))
end

-- Every handler in this file needs the same "must be logged in AND be the
-- verified site owner" gate. Returns the owner user table on success, or
-- (nil, status, body, headers) to return directly from the caller -- body
-- is a redirect Location header table for a 302, or an HTML string
-- otherwise (headers is nil in that case; caller supplies HTML_HEADERS).
local function gate(req)
  local owner, status, body = routes.require_site_owner_for_page(req)
  if owner then return owner end
  if status == 401 then
    return nil, 302, "", { ["Location"] = "/login" }
  end
  return nil, status or 403, layout_error(body and body.detail or "Access denied.")
end

local STYLE = [[
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; background: #101318; color: #e7e9ee; font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
  .wrap { max-width: 960px; margin: 0 auto; padding: 24px 20px 80px; }
  h1 { font-size: 22px; margin: 0 0 4px; }
  h2 { font-size: 16px; margin: 40px 0 12px; border-bottom: 1px solid rgba(255,255,255,0.1); padding-bottom: 8px; }
  p.lede { color: #9aa1af; margin: 0 0 8px; }
  .flash { background: rgba(55,201,167,0.15); border: 1px solid rgba(55,201,167,0.4); color: #9fe8d4;
    border-radius: 10px; padding: 10px 14px; margin-bottom: 16px; }
  .flash.error { background: rgba(220,80,80,0.15); border-color: rgba(220,80,80,0.4); color: #ffb4b4; }
  .metric-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 10px; margin-bottom: 16px; }
  .metric { background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.08); border-radius: 12px; padding: 12px; }
  .metric strong { display: block; font-size: 18px; }
  .metric span { color: #9aa1af; font-size: 12px; }
  .row { display: flex; align-items: flex-start; gap: 12px; background: rgba(255,255,255,0.03);
    border: 1px solid rgba(255,255,255,0.07); border-radius: 12px; padding: 12px; margin-bottom: 8px; }
  .row img { width: 48px; height: 48px; border-radius: 8px; object-fit: cover; flex-shrink: 0; }
  .row .body { flex: 1; min-width: 0; }
  .row .body strong { display: block; }
  .row .muted { color: #9aa1af; font-size: 12px; }
  .row .actions { display: flex; gap: 6px; flex-wrap: wrap; }
  form.inline { display: inline; }
  button, input[type=submit] {
    padding: 6px 12px; border-radius: 8px; border: 1px solid rgba(255,255,255,0.15);
    background: rgba(255,255,255,0.06); color: #e7e9ee; font-size: 13px; cursor: pointer;
  }
  button.primary { background: #37c9a7; color: #04211b; border-color: transparent; font-weight: 600; }
  button.danger { background: rgba(220,80,80,0.2); border-color: rgba(220,80,80,0.4); color: #ffb4b4; }
  .empty { color: #9aa1af; padding: 16px 0; }
  .filters a { color: #9aa1af; text-decoration: none; margin-right: 12px; font-size: 13px; }
  .filters a.active { color: #37c9a7; font-weight: 600; }
  label { display: block; font-size: 13px; color: #9aa1af; margin: 12px 0 4px; }
  input[type=text], input[type=email] {
    width: 100%; max-width: 420px; padding: 8px 10px; border-radius: 8px; border: 1px solid rgba(255,255,255,0.12);
    background: rgba(255,255,255,0.03); color: #e7e9ee;
  }
  select { padding: 8px 10px; border-radius: 8px; background: rgba(255,255,255,0.03); color: #e7e9ee; border: 1px solid rgba(255,255,255,0.12); }
  .check-row { display: flex; align-items: center; gap: 8px; font-size: 14px; color: #e7e9ee; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid rgba(255,255,255,0.08); }
  th { color: #9aa1af; font-weight: 500; }
</style>
]]

local function layout(body_html, flash)
  local flash_html = ""
  if flash and flash ~= "" then
    local kind = flash:match("^error:") and "error" or ""
    local text = flash:gsub("^error:", "")
    flash_html = ('<div class="flash %s">%s</div>'):format(kind, esc(text))
  end
  return ([[<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Admin // Nyxframe</title>
%s
</head>
<body>
<div class="wrap">
  <h1>Admin</h1>
  <p class="lede">Review reports and flagged uploads, manage accounts, watch storage, and control site-wide messaging.</p>
  %s
  %s
</div>
</body>
</html>]]):format(STYLE, flash_html, body_html)
end

-- ---------------------------------------------------------------------------
-- Reports
-- ---------------------------------------------------------------------------

local function reports_section(req, owner)
  local status_filter = req.query.status
  if status_filter == nil then status_filter = "open" end
  local list_req = { headers = req.headers, query = { status = status_filter ~= "" and status_filter or nil, limit = "100" } }
  local _, reports_body = routes.admin_list_reports(list_req)
  local reports = html.as_list(reports_body and reports_body.reports)

  local function filter_link(value, label)
    local active = (status_filter == value) or (value == "" and status_filter == "")
    return ('<a href="/admin?status=%s#reports" class="%s">%s</a>'):format(esc(value), active and "active" or "", esc(label))
  end

  local rows = {}
  for _, r in ipairs(reports) do
    rows[#rows + 1] = ([[
      <div class="row">
        %s
        <div class="body">
          <strong>%s</strong>
          <p>%s%s</p>
          <p class="muted">Reported by %s on %s &middot; Uploaded by %s%s</p>
        </div>
        <div class="actions">
          <form class="inline" method="POST" action="/admin/actions/report-resolve">
            <input type="hidden" name="report_id" value="%s"><input type="hidden" name="status" value="reviewed">
            <button type="submit">Mark reviewed</button>
          </form>
          <form class="inline" method="POST" action="/admin/actions/report-resolve">
            <input type="hidden" name="report_id" value="%s"><input type="hidden" name="status" value="dismissed">
            <button type="submit">Dismiss</button>
          </form>
          <form class="inline" method="POST" action="/admin/actions/report-resolve" onsubmit="return confirm('Delete the reported media? This cannot be undone from here.');">
            <input type="hidden" name="report_id" value="%s"><input type="hidden" name="status" value="reviewed"><input type="hidden" name="delete_media" value="1">
            <button class="danger" type="submit" %s>Delete &amp; resolve</button>
          </form>
        </div>
      </div>
    ]]):format(
      r.media_thumb_url and ('<img src="%s" alt="">'):format(esc(r.media_thumb_url)) or "",
      esc(r.media_title or ("Media #" .. tostring(r.media_id))),
      esc(r.reason), r.details and (" &mdash; " .. esc(r.details)) or "",
      esc(r.reporter_display_name or r.reporter_username or "someone"), esc(format_date(r.created_at)),
      esc(r.media_owner_display_name or r.media_owner_username or "unknown"),
      r.media_deleted_at and " &middot; Already deleted" or "",
      esc(r.id), esc(r.id), esc(r.id),
      r.media_deleted_at and "disabled" or ""
    )
  end

  return ([[
    <h2 id="reports">Reports</h2>
    <div class="filters">%s %s %s %s</div>
    %s
  ]]):format(
    filter_link("open", "Open"), filter_link("reviewed", "Reviewed"), filter_link("dismissed", "Dismissed"), filter_link("", "All"),
    #rows > 0 and table.concat(rows, "") or '<div class="empty">No reports here.</div>'
  )
end

-- ---------------------------------------------------------------------------
-- Flagged uploads
-- ---------------------------------------------------------------------------

local function flagged_section(req)
  local _, body = routes.admin_flagged_media({ headers = req.headers, query = { limit = "100" } })
  local items = html.as_list(body and body.media)
  local rows = {}
  for _, item in ipairs(items) do
    rows[#rows + 1] = ([[
      <div class="row">
        %s
        <div class="body">
          <strong>%s</strong>
          <p>%s</p>
          <p class="muted">Uploaded by %s on %s</p>
        </div>
        <div class="actions">
          <form class="inline" method="POST" action="/admin/actions/flagged-resolve">
            <input type="hidden" name="media_id" value="%s"><input type="hidden" name="decision" value="adult">
            <button type="submit">Confirm 18+</button>
          </form>
          <form class="inline" method="POST" action="/admin/actions/flagged-resolve">
            <input type="hidden" name="media_id" value="%s"><input type="hidden" name="decision" value="clear">
            <button type="submit">Clear</button>
          </form>
        </div>
      </div>
    ]]):format(
      item.thumb_url and ('<img src="%s" alt="">'):format(esc(item.thumb_url)) or "",
      esc(item.title or ("Media #" .. tostring(item.id))),
      esc(item.moderation_reason or "AI/keyword flagged as adult content without uploader confirmation."),
      esc(item.owner_display_name or item.owner_username or "unknown"), esc(format_date(item.created_at)),
      esc(item.id), esc(item.id)
    )
  end
  return ([[
    <h2 id="flagged">Flagged Uploads</h2>
    %s
  ]]):format(#rows > 0 and table.concat(rows, "") or '<div class="empty">Nothing flagged for review.</div>')
end

-- ---------------------------------------------------------------------------
-- Users & bans
-- ---------------------------------------------------------------------------

local function users_section(req)
  local q = req.query.q or ""
  local _, body = routes.search_users({ headers = req.headers, query = { q = q, limit = "30" } })
  local users = html.as_list(body and body.users)
  local rows = {}
  for _, u in ipairs(users) do
    local action
    if u.banned_at then
      action = ([[
        <form class="inline" method="POST" action="/admin/actions/unban">
          <input type="hidden" name="user_id" value="%s">
          <button type="submit">Unban</button>
        </form>
      ]]):format(esc(u.id))
    else
      action = ([[
        <form class="inline" method="POST" action="/admin/actions/ban">
          <input type="hidden" name="user_id" value="%s">
          <input type="text" name="reason" placeholder="Ban reason" style="width:140px;display:inline-block;">
          <input type="text" name="until" placeholder="Until (YYYY-MM-DD, optional)" style="width:170px;display:inline-block;">
          <button class="danger" type="submit" %s onclick="return confirm('Ban @%s?');">Ban</button>
        </form>
      ]]):format(esc(u.id), u.site_owner and "disabled" or "", esc(u.username))
    end
    -- Permanent delete (routes.admin_delete_user): the username must be
    -- typed back, same rule as the app's admin panel.
    if not u.site_owner then
      action = action .. ([[
        <form class="inline" method="POST" action="/admin/actions/delete-user" onsubmit="return confirm('Permanently delete @%s and ALL their posts, comments, likes and collections? This cannot be undone.');">
          <input type="hidden" name="user_id" value="%s">
          <input type="text" name="confirm_username" placeholder="Type %s to delete" autocomplete="off" style="width:170px;display:inline-block;">
          <button class="danger" type="submit">Delete permanently</button>
        </form>
      ]]):format(esc(u.username), esc(u.id), esc(u.username))
    end
    local status_text
    if u.banned_at then
      status_text = "Banned" .. (u.banned_until and (" until " .. format_date(u.banned_until)) or " permanently")
        .. (u.ban_reason and (" &mdash; " .. esc(u.ban_reason)) or "")
    else
      status_text = "Active account"
    end
    rows[#rows + 1] = ([[
      <div class="row">
        <div class="body">
          <strong>%s <span class="muted">@%s</span></strong>
          <p class="muted">%s</p>
        </div>
        <div class="actions">%s</div>
      </div>
    ]]):format(esc(u.display_name or u.username), esc(u.username), status_text, action)
  end
  return ([[
    <h2 id="users">Users &amp; Bans</h2>
    <form method="GET" action="/admin#users">
      <label for="q">Search users</label>
      <input id="q" type="text" name="q" value="%s" placeholder="username or display name">
      <button type="submit" class="primary">Search</button>
    </form>
    <div style="margin-top:12px;">%s</div>
  ]]):format(esc(q), #rows > 0 and table.concat(rows, "") or '<div class="empty">No users found.</div>')
end

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

local function storage_section(req)
  local _, body = routes.admin_storage({ headers = req.headers, query = {} })
  if not body then return '<h2 id="storage">Storage</h2><div class="empty">Storage data unavailable.</div>' end
  local rows = {}
  for _, row in ipairs(html.as_list(body.by_user)) do
    rows[#rows + 1] = ("<tr><td>%s</td><td>%s</td><td>%s</td></tr>"):format(
      esc(row.display_name or row.username), esc(row.item_count), esc(format_bytes(row.total_bytes))
    )
  end
  return ([[
    <h2 id="storage">Storage</h2>
    <div class="metric-grid">
      <div class="metric"><strong>%s</strong><span>Tracked media</span></div>
      <div class="metric"><strong>%s</strong><span>Active items</span></div>
      <div class="metric"><strong>%s</strong><span>Cache size</span></div>
      <div class="metric"><strong>%s</strong><span>Orphaned cache (%s)</span></div>
    </div>
    <form method="POST" action="/admin/actions/purge-orphans" onsubmit="return confirm('Purge orphaned thumbnail/video cache files older than 24h? Originals are never touched.');">
      <button class="primary" type="submit" %s>Purge cache orphans</button>
    </form>
    <h3 style="margin-top:20px;font-size:14px;">Top storage users</h3>
    <table><thead><tr><th>User</th><th>Items</th><th>Bytes</th></tr></thead><tbody>%s</tbody></table>
  ]]):format(
    format_bytes(body.total_bytes), esc(body.total_items), format_bytes(body.cache_total_bytes),
    format_bytes(body.orphan_bytes), esc(body.orphan_count),
    ((tonumber(body.orphan_count) or 0) > 0) and "" or "disabled",
    #rows > 0 and table.concat(rows, "") or "<tr><td colspan=\"3\">No data.</td></tr>"
  )
end

-- ---------------------------------------------------------------------------
-- Site settings
-- ---------------------------------------------------------------------------

local function site_settings_section(req)
  local _, form = routes.site_announcement({ headers = req.headers, query = {} })
  form = form or {}
  local function checked(v) return v and "checked" or "" end
  local function level_option(value, label)
    return ('<option value="%s" %s>%s</option>'):format(esc(value), (form.announcement_level == value) and "selected" or "", esc(label))
  end
  return ([[
    <h2 id="site">Site Settings</h2>
    <form method="POST" action="/admin/actions/site-settings">
      <h3 style="font-size:14px;">Site-wide announcement</h3>
      <p class="muted">Shows as a dismissible banner to every visitor.</p>
      <label class="check-row"><input type="checkbox" name="announcement_active" %s> Active</label>
      <label for="announcement_message">Message</label>
      <input id="announcement_message" type="text" name="announcement_message" value="%s" maxlength="500">
      <label for="announcement_level">Level</label>
      <select id="announcement_level" name="announcement_level">%s%s%s</select>

      <h3 style="font-size:14px;margin-top:20px;">Maintenance mode</h3>
      <p class="muted">Shows a full-page maintenance screen to everyone except you.</p>
      <label class="check-row"><input type="checkbox" name="maintenance_mode" %s> Enabled</label>
      <label for="maintenance_message">Message</label>
      <input id="maintenance_message" type="text" name="maintenance_message" value="%s" maxlength="500">

      <div style="margin-top:16px;"><button class="primary" type="submit">Save site settings</button></div>
    </form>
  ]]):format(
    checked(form.announcement_active), esc(form.announcement_message),
    level_option("info", "Info"), level_option("warning", "Warning"), level_option("critical", "Critical"),
    checked(form.maintenance_mode), esc(form.maintenance_message)
  )
end

-- ---------------------------------------------------------------------------
-- Audit log
-- ---------------------------------------------------------------------------

local function audit_log_section(req)
  local _, body = routes.admin_audit_log({ headers = req.headers, query = { limit = "100" } })
  local entries = html.as_list(body and body.entries)
  local rows = {}
  for _, e in ipairs(entries) do
    rows[#rows + 1] = ([[
      <div class="row">
        <div class="body">
          <strong>%s &mdash; %s%s</strong>
          <p class="muted">%s &middot; %s%s</p>
        </div>
      </div>
    ]]):format(
      esc(e.action), esc(e.target_type), e.target_id and (" #" .. esc(e.target_id)) or "",
      esc(e.actor_display_name or e.actor_username or "System"), esc(format_date(e.created_at)),
      e.detail and (" &mdash; " .. esc(e.detail)) or ""
    )
  end
  return ([[
    <h2 id="audit">Audit Log</h2>
    %s
  ]]):format(#rows > 0 and table.concat(rows, "") or '<div class="empty">No moderation activity yet.</div>')
end

-- ---------------------------------------------------------------------------
-- Telemetry / Ops (see lua/src/telemetry.lua + routes.admin_telemetry)
-- ---------------------------------------------------------------------------

local function fmt_ago(unix_time)
  if not unix_time or unix_time == 0 then return "never" end
  local seconds = os.time() - tonumber(unix_time)
  if seconds < 5 then return "just now" end
  if seconds < 90 then return seconds .. "s ago" end
  if seconds < 5400 then return math.floor(seconds / 60) .. "m ago" end
  return math.floor(seconds / 3600) .. "h ago"
end

local function telemetry_section(req)
  local _, body = routes.admin_telemetry({ headers = req.headers, query = {} })
  if not body then return '<h2 id="telemetry">Telemetry / Ops</h2><div class="empty">Telemetry unavailable.</div>' end

  local job_cards = {}
  -- Fixed display order so the panel doesn't reshuffle between loads --
  -- jobs is a plain name->snapshot map (routes.admin_telemetry/
  -- telemetry.lua's M.job_snapshot), so iteration order isn't stable.
  local JOB_ORDER = {
    "media_warmer", "stale_transcode_cleanup", "hls_idle_reaper",
    "weekly_digest", "db_health_watch", "deleted_media_purge",
  }
  for _, name in ipairs(JOB_ORDER) do
    local job = body.jobs and body.jobs[name]
    if job then
      job_cards[#job_cards + 1] = ([[
        <div class="metric">
          <strong style="color:%s;">%s</strong>
          <span>%s &middot; last run %s &middot; %dms</span>
        </div>
      ]]):format(
        job.ok and "#9fe8d4" or "#ffb4b4", esc(name),
        job.ok and "OK" or "ERROR", fmt_ago(job.at), tonumber(job.duration_ms) or 0
      )
    end
  end

  local route_rows = {}
  for _, r in ipairs(html.as_list(body.request_stats)) do
    route_rows[#route_rows + 1] = ("<tr><td>%s</td><td>%s</td><td>%s</td><td>%sms</td><td>%sms</td></tr>"):format(
      esc(r.route), esc(r.count), esc(r.error_count), esc(r.avg_ms), esc(r.p95_ms)
    )
  end

  local event_rows = {}
  for _, e in ipairs(html.as_list(body.recent_events)) do
    local meta_text = ""
    if e.meta and e.meta ~= "" then
      -- telemetry_events.meta is a JSONB column -- pg.lua hands it back as
      -- raw JSON text (same reason digest.lua/routes.lua cjson.decode()
      -- other jsonb columns like user_settings), not an already-decoded
      -- Lua table.
      local ok, decoded = pcall(cjson.decode, e.meta)
      if ok and type(decoded) == "table" then
        local parts = {}
        for k, v in pairs(decoded) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
        meta_text = table.concat(parts, " ")
      end
    end
    event_rows[#event_rows + 1] = ("<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>"):format(
      esc(format_date(e.created_at)), esc(e.event_type), esc(e.subject or ""), esc(e.outcome or ""),
      esc(e.duration_ms or ""), esc(meta_text)
    )
  end

  return ([[
    <h2 id="telemetry">Telemetry / Ops</h2>
    <h3 style="font-size:14px;">Background jobs</h3>
    <div class="metric-grid">%s</div>
    <h3 style="font-size:14px;">Transcode slots</h3>
    <div class="metric-grid">
      <div class="metric"><strong>%s / %s</strong><span>Active concurrency slots</span></div>
    </div>
    <h3 style="font-size:14px;">Request latency (since %s)</h3>
    <table><thead><tr><th>Route</th><th>Count</th><th>Errors</th><th>Avg</th><th>p95</th></tr></thead><tbody>%s</tbody></table>
    <h3 style="font-size:14px;margin-top:20px;">Recent events</h3>
    <table><thead><tr><th>When</th><th>Type</th><th>Subject</th><th>Outcome</th><th>ms</th><th>Detail</th></tr></thead><tbody>%s</tbody></table>
  ]]):format(
    #job_cards > 0 and table.concat(job_cards, "") or '<div class="empty">No job runs recorded yet.</div>',
    esc(body.transcode_active_slots), esc(body.transcode_max_concurrent),
    esc(fmt_ago(body.request_stats_since)),
    #route_rows > 0 and table.concat(route_rows, "") or "<tr><td colspan=\"5\">No requests recorded yet.</td></tr>",
    #event_rows > 0 and table.concat(event_rows, "") or "<tr><td colspan=\"6\">No events recorded yet.</td></tr>"
  )
end

-- ---------------------------------------------------------------------------
-- Page + actions
-- ---------------------------------------------------------------------------

function M.admin_page(req)
  local owner, err_status, err_body, err_headers = gate(req)
  if not owner then return err_status, err_body, err_headers or HTML_HEADERS end
  local flash = req.query.flash

  local body = table.concat({
    telemetry_section(req),
    reports_section(req, owner),
    flagged_section(req),
    users_section(req),
    storage_section(req),
    site_settings_section(req),
    audit_log_section(req),
  }, "")

  return 200, layout(body, flash), HTML_HEADERS
end

local function redirect_to_admin(flash, anchor)
  local location = "/admin" .. (flash and ("?flash=" .. flash:gsub(" ", "%%20")) or "")
  if anchor then location = location .. "#" .. anchor end
  return 302, "", { ["Location"] = location }
end

function M.action_report_resolve(req)
  local owner = gate(req)
  if not owner then return redirect_to_admin("error:Access denied.") end
  local fields = parse_urlencoded(req.raw_body)
  req.json = { status = fields.status, delete_media = fields.delete_media == "1" }
  req.params = { report_id = fields.report_id }
  local status = routes.admin_resolve_report(req)
  if status ~= 200 then return redirect_to_admin("error:Could not resolve report.", "reports") end
  return redirect_to_admin(fields.delete_media == "1" and "Media deleted and report resolved." or "Report updated.", "reports")
end

function M.action_flagged_resolve(req)
  local owner = gate(req)
  if not owner then return redirect_to_admin("error:Access denied.") end
  local fields = parse_urlencoded(req.raw_body)
  req.json = { decision = fields.decision }
  req.params = { media_id = fields.media_id }
  local status = routes.admin_resolve_flagged_media(req)
  if status ~= 200 then return redirect_to_admin("error:Could not resolve flagged media.", "flagged") end
  return redirect_to_admin("Marked " .. fields.decision .. ".", "flagged")
end

function M.action_ban(req)
  local owner = gate(req)
  if not owner then return redirect_to_admin("error:Access denied.") end
  local fields = parse_urlencoded(req.raw_body)
  -- fields["until"] not fields.until: `until` is a Lua reserved word, invalid after a dot.
  local until_value = fields["until"]
  req.json = { reason = fields.reason, ["until"] = (until_value and until_value ~= "") and until_value or nil }
  req.params = { user_id = fields.user_id }
  local status = routes.admin_ban_user(req)
  if status ~= 200 then return redirect_to_admin("error:Could not ban user.", "users") end
  return redirect_to_admin("User banned.", "users")
end

function M.action_unban(req)
  local owner = gate(req)
  if not owner then return redirect_to_admin("error:Access denied.") end
  local fields = parse_urlencoded(req.raw_body)
  req.params = { user_id = fields.user_id }
  local status = routes.admin_unban_user(req)
  if status ~= 200 then return redirect_to_admin("error:Could not unban user.", "users") end
  return redirect_to_admin("User unbanned.", "users")
end

function M.action_delete_user(req)
  local owner = gate(req)
  if not owner then return redirect_to_admin("error:Access denied.") end
  local fields = parse_urlencoded(req.raw_body)
  req.json = { confirm_username = fields.confirm_username }
  req.params = { user_id = fields.user_id }
  local status, body = routes.admin_delete_user(req)
  if status ~= 200 then
    return redirect_to_admin("error:" .. tostring(body and body.detail or "Could not delete user."), "users")
  end
  return redirect_to_admin("Deleted @" .. tostring(body.username) .. " permanently.", "users")
end

function M.action_purge_orphans(req)
  local owner = gate(req)
  if not owner then return redirect_to_admin("error:Access denied.") end
  local status, body = routes.admin_purge_storage_orphans(req)
  if status ~= 200 then return redirect_to_admin("error:Purge failed.", "storage") end
  return redirect_to_admin(("Removed %d file(s), freed %s."):format(body.removed or 0, format_bytes(body.freed_bytes)), "storage")
end

function M.action_site_settings(req)
  local owner = gate(req)
  if not owner then return redirect_to_admin("error:Access denied.") end
  local fields = parse_urlencoded(req.raw_body)
  req.json = {
    announcement_active = fields.announcement_active == "on",
    announcement_message = fields.announcement_message,
    announcement_level = fields.announcement_level,
    maintenance_mode = fields.maintenance_mode == "on",
    maintenance_message = fields.maintenance_message,
  }
  local status = routes.admin_update_site_settings(req)
  if status ~= 200 then return redirect_to_admin("error:Could not save site settings.", "site") end
  return redirect_to_admin("Site settings saved.", "site")
end

return M
