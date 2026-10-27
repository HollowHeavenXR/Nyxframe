import { useCallback, useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { Ban, CheckCircle2, ChevronDown, ExternalLink, Flag, HardDrive, History, Megaphone, Music, RefreshCw, ShieldAlert, Trash2, Upload, XCircle } from "lucide-react";
import { apiFetch, clearApiCache } from "../api.js";
import { EmptyState, Notice, Page, Segmented, SkeletonList } from "../components/ui.jsx";
import { formatDate, formatBytes } from "../utils/format.js";

const STATUS_FILTERS = [["open", "Open"], ["reviewed", "Reviewed"], ["dismissed", "Dismissed"], ["", "All"]];
const TABS = [
  ["reports", "Reports"],
  ["flagged", "Flagged Uploads"],
  ["users", "Users"],
  ["storage", "Storage"],
  ["site", "Site Settings"],
  ["music", "Background Music"],
  ["audit", "Audit Log"],
];

// Same class of bug as DiscoverPage's filters -- plain local state, so
// leaving /admin (any nav click) and coming back always dumped you back
// on "Reports" regardless of which section you'd actually been on.
const TAB_SESSION_KEY = "nyxframe_admin_tab";

export function AdminPage({ ctx }) {
  const [tab, setTab] = useState(() => {
    try {
      const stored = sessionStorage.getItem(TAB_SESSION_KEY);
      return TABS.some(([value]) => value === stored) ? stored : "reports";
    } catch (_error) {
      return "reports";
    }
  });

  function selectTab(next) {
    setTab(next);
    try { sessionStorage.setItem(TAB_SESSION_KEY, next); } catch (_error) { /* private browsing */ }
  }

  if (!ctx.user) {
    return (
      <Page title="Admin" eyebrow="Moderation">
        <EmptyState title="Login required" />
      </Page>
    );
  }
  if (!ctx.user.site_owner) {
    return (
      <Page title="Admin" eyebrow="Moderation">
        <EmptyState title="You do not have access to this page" />
      </Page>
    );
  }

  return (
    <Page
      title="Admin"
      eyebrow="Moderation"
      lede="Review reports and flagged uploads, manage accounts, watch storage, and control site-wide messaging."
      actions={<Segmented value={tab} onChange={selectTab} options={TABS} />}
    >
      {tab === "reports" ? <ReportsTab ctx={ctx} /> : null}
      {tab === "flagged" ? <FlaggedTab ctx={ctx} /> : null}
      {tab === "users" ? <UsersTab ctx={ctx} /> : null}
      {tab === "storage" ? <StorageTab ctx={ctx} /> : null}
      {tab === "site" ? <SiteSettingsTab ctx={ctx} /> : null}
      {tab === "site" ? <IncidentsPanel ctx={ctx} /> : null}
      {tab === "music" ? <MusicTab ctx={ctx} /> : null}
      {tab === "audit" ? <AuditLogTab /> : null}
    </Page>
  );
}

function ReportsTab({ ctx }) {
  const [status, setStatus] = useState("open");
  const [reports, setReports] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [busyId, setBusyId] = useState("");

  const showToast = ctx.showToast;

  const loadReports = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const query = status ? `?status=${encodeURIComponent(status)}` : "";
      const data = await apiFetch(`/api/admin/reports${query}`);
      setReports(data.reports || []);
    } catch (fetchError) {
      setError(fetchError.message);
    } finally {
      setLoading(false);
    }
  }, [status]);

  useEffect(() => {
    loadReports();
  }, [loadReports]);

  async function resolveReport(report, nextStatus, { deleteMedia = false } = {}) {
    if (deleteMedia && !window.confirm("Delete the reported media? This cannot be undone from here.")) return;
    setBusyId(String(report.id));
    try {
      await apiFetch(`/api/admin/reports/${report.id}/resolve`, {
        method: "POST",
        body: JSON.stringify({ status: nextStatus, delete_media: deleteMedia }),
      });
      clearApiCache();
      showToast(deleteMedia ? "Media deleted and report resolved." : `Report marked ${nextStatus}.`, "success");
      setReports((rows) => rows.filter((row) => Number(row.id) !== Number(report.id)));
    } catch (resolveError) {
      showToast(resolveError.message, "error");
    } finally {
      setBusyId("");
    }
  }

  return (
    <div className="admin-tab">
      <div className="admin-tab-head">
        <Segmented value={status} onChange={setStatus} options={STATUS_FILTERS} />
        <button type="button" onClick={loadReports} disabled={loading}><RefreshCw size={16} />Refresh</button>
      </div>
      {error ? <Notice kind="error">{error}</Notice> : null}
      {loading ? <SkeletonList /> : (
        <div className="admin-reports-list">
          {reports.map((report) => (
            <article className="admin-report-row" key={report.id}>
              <Link to={`/media/${report.media_id}`} className="admin-report-thumb">
                {report.media_thumb_url ? <img src={report.media_thumb_url} alt="" loading="lazy" decoding="async" /> : <ShieldAlert size={28} />}
              </Link>
              <div className="admin-report-body">
                <strong>{report.media_title || `Media #${report.media_id}`}</strong>
                <p className="admin-report-reason">{report.reason}{report.details ? ` — ${report.details}` : ""}</p>
                <p className="muted-copy">
                  Reported by {report.reporter_display_name || report.reporter_username || "someone"} on {formatDate(report.created_at)}
                  {" · "}Uploaded by {report.media_owner_display_name || report.media_owner_username || "unknown"}
                  {report.media_deleted_at ? " · Already deleted" : ""}
                </p>
                <span className={`report-status-pill status-${report.status}`}>{report.status}</span>
              </div>
              <div className="admin-report-actions">
                <button type="button" onClick={() => resolveReport(report, "reviewed")} disabled={busyId === String(report.id)}>
                  <CheckCircle2 size={16} />Mark reviewed
                </button>
                <button type="button" onClick={() => resolveReport(report, "dismissed")} disabled={busyId === String(report.id)}>
                  <XCircle size={16} />Dismiss
                </button>
                <button
                  type="button"
                  className="danger"
                  onClick={() => resolveReport(report, "reviewed", { deleteMedia: true })}
                  disabled={busyId === String(report.id) || Boolean(report.media_deleted_at)}
                >
                  <Trash2 size={16} />Delete &amp; resolve
                </button>
              </div>
            </article>
          ))}
          {!loading && !reports.length ? <EmptyState title="No reports here" /> : null}
        </div>
      )}
    </div>
  );
}

function FlaggedTab({ ctx }) {
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState("");
  const showToast = ctx.showToast;

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const data = await apiFetch("/api/admin/flagged-media");
      setItems(data.media || []);
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setLoading(false);
    }
  }, [showToast]);

  useEffect(() => {
    load();
  }, [load]);

  async function resolve(item, decision) {
    setBusyId(String(item.id));
    try {
      await apiFetch(`/api/admin/flagged-media/${item.id}/resolve`, {
        method: "POST",
        body: JSON.stringify({ decision }),
      });
      clearApiCache();
      showToast(`Marked ${decision}.`, "success");
      setItems((rows) => rows.filter((row) => Number(row.id) !== Number(item.id)));
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setBusyId("");
    }
  }

  return (
    <div className="admin-tab">
      <div className="admin-tab-head"><button type="button" onClick={load} disabled={loading}><RefreshCw size={16} />Refresh</button></div>
      {loading ? <SkeletonList /> : (
        <div className="admin-reports-list">
          {items.map((item) => (
            <article className="admin-report-row" key={item.id}>
              <Link to={`/media/${item.id}`} className="admin-report-thumb">
                {item.thumb_url ? <img src={item.thumb_url} alt="" loading="lazy" decoding="async" /> : <Flag size={28} />}
              </Link>
              <div className="admin-report-body">
                <strong>{item.title || `Media #${item.id}`}</strong>
                <p className="admin-report-reason">{item.moderation_reason || "AI/keyword flagged as adult content without uploader confirmation."}</p>
                <p className="muted-copy">Uploaded by {item.owner_display_name || item.owner_username || "unknown"} on {formatDate(item.created_at)}</p>
              </div>
              <div className="admin-report-actions">
                <button type="button" onClick={() => resolve(item, "adult")} disabled={busyId === String(item.id)}><CheckCircle2 size={16} />Confirm 18+</button>
                <button type="button" onClick={() => resolve(item, "clear")} disabled={busyId === String(item.id)}><XCircle size={16} />Clear</button>
              </div>
            </article>
          ))}
          {!loading && !items.length ? <EmptyState title="Nothing flagged for review" /> : null}
        </div>
      )}
    </div>
  );
}

const USER_FILTERS = [["all", "All"], ["active", "Active"], ["banned", "Banned"]];
const USER_SORTS = [
  ["newest", "Newest"],
  ["oldest", "Oldest"],
  ["posts", "Most posts"],
  ["last_seen", "Recently active"],
  ["storage", "Most storage"],
  ["name", "Name"],
];
const BAN_DURATIONS = [["1", "1 day"], ["7", "7 days"], ["30", "30 days"], ["365", "1 year"], ["", "Permanent"]];
const USERS_PAGE = 40;

function countLabel(value, one, many = `${one}s`) {
  const n = Number(value) || 0;
  return `${n.toLocaleString()} ${n === 1 ? one : many}`;
}

function UsersTab({ ctx }) {
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState("all");
  const [sort, setSort] = useState("newest");
  const [users, setUsers] = useState([]);
  const [total, setTotal] = useState(null);
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(true);
  const [openId, setOpenId] = useState(null);
  const requestRef = useRef(0);

  const load = useCallback(async (offset = 0) => {
    const requestId = ++requestRef.current;
    setLoading(true);
    try {
      const params = new URLSearchParams({ filter, sort, limit: String(USERS_PAGE), offset: String(offset) });
      if (query.trim()) params.set("q", query.trim());
      const data = await apiFetch(`/api/admin/users?${params}`);
      if (requestId !== requestRef.current) return;
      setUsers((current) => (offset ? [...current, ...(data.users || [])] : data.users || []));
      setHasMore(Boolean(data.has_more));
      setTotal(data.total_users ?? null);
    } catch (error) {
      if (requestId === requestRef.current) ctx.showToast(error.message, "error");
    } finally {
      if (requestId === requestRef.current) setLoading(false);
    }
  }, [ctx, filter, query, sort]);

  useEffect(() => {
    const timer = setTimeout(() => load(0), query ? 250 : 0);
    return () => clearTimeout(timer);
  }, [load, query]);

  function replaceUser(next) {
    setUsers((current) => current.map((user) => (user.id === next.id ? { ...user, ...next } : user)));
  }

  function removeUser(id) {
    setUsers((current) => current.filter((user) => user.id !== id));
    setTotal((current) => (current ? current - 1 : current));
    setOpenId(null);
  }

  return (
    <div className="admin-tab admin-users">
      <div className="admin-users-controls">
        <label className="field">
          <span>Search{total != null ? <small className="muted"> · {total.toLocaleString()} accounts</small> : null}</span>
          <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Username, display name or email" />
        </label>
        <Segmented value={filter} onChange={setFilter} options={USER_FILTERS} />
        <label className="field admin-users-sort">
          <span>Sort</span>
          <select value={sort} onChange={(event) => setSort(event.target.value)}>
            {USER_SORTS.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
          </select>
        </label>
      </div>

      <div className="admin-users-list">
        {users.map((user) => (
          <AdminUserRow
            key={user.id}
            ctx={ctx}
            user={user}
            open={openId === user.id}
            onToggle={() => setOpenId((current) => (current === user.id ? null : user.id))}
            onChanged={replaceUser}
            onDeleted={removeUser}
          />
        ))}
        {loading ? <SkeletonList /> : null}
        {!loading && !users.length ? <EmptyState title="No users found" /> : null}
        {hasMore && !loading ? (
          <button type="button" className="admin-users-more" onClick={() => load(users.length)}>Load more</button>
        ) : null}
      </div>
    </div>
  );
}

function AdminUserRow({ ctx, user, open, onToggle, onChanged, onDeleted }) {
  const name = user.display_name || user.username;
  return (
    <article className={`admin-user-row${open ? " is-open" : ""}`}>
      <button type="button" className="admin-user-summary" onClick={onToggle} aria-expanded={open}>
        <span className="admin-user-avatar" style={{ background: user.profile_color || undefined }}>
          {user.avatar_url ? <img src={user.avatar_url} alt="" loading="lazy" /> : name.slice(0, 1).toUpperCase()}
        </span>
        <span className="admin-user-main">
          <strong>
            {name} <small>@{user.username}</small>
            {user.site_owner ? <em className="admin-badge is-owner">Owner</em> : null}
            {user.banned ? <em className="admin-badge is-banned">Banned</em> : null}
          </strong>
          <span className="muted small">
            {countLabel(user.post_count, "post")} · {countLabel(user.comment_count, "comment")} · {countLabel(user.like_count, "like")} · {formatBytes(user.storage_bytes || 0)}
          </span>
          <span className="muted small">
            Joined {formatDate(user.created_at)}{user.last_seen_at ? ` · last seen ${formatDate(user.last_seen_at)}` : " · never seen"}{user.email ? ` · ${user.email}` : ""}
          </span>
        </span>
        <ChevronDown className="admin-user-chevron" size={18} />
      </button>
      {open ? <AdminUserDetail ctx={ctx} user={user} onChanged={onChanged} onDeleted={onDeleted} /> : null}
    </article>
  );
}

function AdminUserDetail({ ctx, user, onChanged, onDeleted }) {
  const [detail, setDetail] = useState(null);
  const [busy, setBusy] = useState(false);
  const [banReason, setBanReason] = useState("");
  const [banDays, setBanDays] = useState("7");
  const [confirmText, setConfirmText] = useState("");

  const refresh = useCallback(async () => {
    try {
      const data = await apiFetch(`/api/admin/users/${user.id}`);
      setDetail(data);
      onChanged(data.user);
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [user.id]);

  useEffect(() => { refresh(); }, [refresh]);

  async function act(run, message) {
    setBusy(true);
    try {
      await run();
      ctx.showToast(message, "success");
      await refresh();
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setBusy(false);
    }
  }

  function ban(event) {
    event.preventDefault();
    const until = banDays ? new Date(Date.now() + Number(banDays) * 86_400_000).toISOString() : null;
    act(() => apiFetch(`/api/admin/users/${user.id}/ban`, {
      method: "POST",
      body: JSON.stringify({ reason: banReason.trim() || null, until }),
    }), `@${user.username} banned${until ? ` until ${formatDate(until)}` : " permanently"}.`);
  }

  async function deleteAccount() {
    setBusy(true);
    try {
      const data = await apiFetch(`/api/admin/users/${user.id}/delete`, {
        method: "POST",
        body: JSON.stringify({ confirm_username: confirmText }),
        timeoutMs: 120_000,
      });
      clearApiCache();
      ctx.showToast(`@${data.username} was permanently deleted.`, "success");
      onDeleted(user.id);
    } catch (error) {
      ctx.showToast(error.message, "error");
      setBusy(false);
    }
  }

  const counts = detail?.counts;
  const info = detail?.user || user;
  const canDelete = detail ? detail.user.can_delete : false;
  const removal = counts ? [
    countLabel(counts.posts, "post") + (counts.posts ? ` (${counts.videos} video${counts.videos === 1 ? "" : "s"}, ${counts.images} image${counts.images === 1 ? "" : "s"}, ${formatBytes(counts.storage_bytes)})` : ""),
    countLabel(counts.comments, "comment") + " they wrote",
    countLabel(counts.comments_from_others, "comment") + " other people left on their posts",
    countLabel(counts.likes, "like"),
    countLabel(counts.bookmarks, "bookmark"),
    countLabel(counts.collections, "collection"),
    `${countLabel(counts.followers, "follower")} and ${counts.following} followed account${counts.following === 1 ? "" : "s"}`,
    countLabel(counts.messages, "message") + " they sent",
  ] : [];

  return (
    <div className="admin-user-detail">
      {!detail ? <SkeletonList /> : (
        <>
          <div className="admin-user-stats">
            {[["Posts", counts.posts], ["Comments", counts.comments], ["Likes", counts.likes], ["Collections", counts.collections], ["Followers", counts.followers], ["Storage", formatBytes(counts.storage_bytes)]].map(([label, value]) => (
              <div key={label}><strong>{typeof value === "number" ? value.toLocaleString() : value}</strong><span>{label}</span></div>
            ))}
          </div>
          <div className="admin-user-links">
            <Link to={`/users/${encodeURIComponent(info.username)}`}><ExternalLink size={14} />View profile</Link>
            {info.age_verified_at ? <span className="muted small">Age verified {formatDate(info.age_verified_at)}</span> : <span className="muted small">Age not verified</span>}
          </div>

          {info.site_owner ? <p className="muted small">This is the site owner's account.</p> : (
            <section className="admin-user-section">
              <h4><Ban size={15} />{info.banned ? "Banned" : "Ban"}</h4>
              {info.banned ? (
                <>
                  <p className="small">
                    {info.banned_until ? `Until ${formatDate(info.banned_until)}` : "Permanently"}{info.ban_reason ? ` — ${info.ban_reason}` : ""}
                  </p>
                  <button type="button" disabled={busy} onClick={() => act(() => apiFetch(`/api/admin/users/${user.id}/unban`, { method: "POST" }), `@${user.username} unbanned.`)}>
                    <CheckCircle2 size={16} />Unban
                  </button>
                </>
              ) : (
                <form className="admin-ban-form" onSubmit={ban}>
                  <input value={banReason} onChange={(event) => setBanReason(event.target.value)} maxLength={300} placeholder="Reason (shown to them)" aria-label="Ban reason" />
                  <select value={banDays} onChange={(event) => setBanDays(event.target.value)} aria-label="Ban length">
                    {BAN_DURATIONS.map(([value, label]) => <option key={label} value={value}>{label}</option>)}
                  </select>
                  <button type="submit" className="danger" disabled={busy}><Ban size={16} />Ban</button>
                </form>
              )}
            </section>
          )}

          {canDelete ? (
            <section className="admin-user-section admin-danger-zone">
              <h4><Trash2 size={15} />Delete account permanently</h4>
              <p className="small">This can't be undone. Deleting <strong>@{info.username}</strong> removes:</p>
              <ul className="admin-removal-list">{removal.map((line) => <li key={line}>{line}</li>)}</ul>
              <p className="small muted">Group chats and conversations they started stay with the other members; only their own messages go.</p>
              <label className="field">
                <span>Type <strong>{info.username}</strong> to confirm</span>
                <input value={confirmText} onChange={(event) => setConfirmText(event.target.value)} autoComplete="off" spellCheck={false} />
              </label>
              <button type="button" className="danger" disabled={busy || confirmText !== info.username} onClick={deleteAccount}>
                <Trash2 size={16} />{busy ? "Deleting…" : `Permanently delete @${info.username}`}
              </button>
            </section>
          ) : null}
        </>
      )}
    </div>
  );
}

function StorageTab({ ctx }) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [purging, setPurging] = useState(false);
  const [fromTag, setFromTag] = useState("");
  const [toTag, setToTag] = useState("");
  const [tagUsage, setTagUsage] = useState(null);
  const [tagBusy, setTagBusy] = useState(false);
  const showToast = ctx.showToast;

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setData(await apiFetch("/api/admin/storage"));
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setLoading(false);
    }
  }, [showToast]);

  useEffect(() => {
    load();
  }, [load]);

  async function purge() {
    if (!window.confirm("Purge orphaned thumbnail/video cache files older than 24h? Originals are never touched.")) return;
    setPurging(true);
    try {
      const result = await apiFetch("/api/admin/storage/purge-orphans", { method: "POST" });
      showToast(`Removed ${result.removed} file(s), freed ${formatBytes(result.freed_bytes)}.`, "success");
      load();
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setPurging(false);
    }
  }

  // Site-wide tag rename/merge/delete, 2026-10-11 (see routes.lua's
  // M.admin_tag_usage/M.admin_rename_tag) -- operates on EVERY post
  // tagged `fromTag`, not an explicit selection, so the preview-count step
  // before the confirm() is the only safety net on what's otherwise an
  // irreversible bulk rewrite.
  async function checkTagUsage() {
    const tag = fromTag.trim();
    if (!tag) return;
    setTagBusy(true);
    try {
      const result = await apiFetch(`/api/admin/tags/${encodeURIComponent(tag)}/usage`);
      setTagUsage(result);
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setTagBusy(false);
    }
  }

  async function runTagRename() {
    const from = fromTag.trim();
    const to = toTag.trim();
    if (!from) return;
    const verb = to ? `rename "${from}" to "${to}"` : `delete "${from}" from every post`;
    if (!window.confirm(`Really ${verb}? This affects ${tagUsage?.count ?? "an unknown number of"} post(s) and cannot be undone.`)) return;
    setTagBusy(true);
    try {
      const result = await apiFetch("/api/admin/tags/rename", {
        method: "POST",
        body: JSON.stringify({ from, to }),
      });
      showToast(`Updated ${result.affected} post(s).`, "success");
      setFromTag("");
      setToTag("");
      setTagUsage(null);
      clearApiCache("/api/media");
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setTagBusy(false);
    }
  }

  if (loading) return <SkeletonList />;
  if (!data) return <EmptyState title="Storage data unavailable" />;

  return (
    <div className="admin-tab">
      <div className="settings-status-grid">
        <div><strong>{formatBytes(data.total_bytes)}</strong><span>Tracked media</span></div>
        <div><strong>{data.total_items}</strong><span>Active items</span></div>
        <div><strong>{formatBytes(data.cache_total_bytes)}</strong><span>Cache size</span></div>
        <div><strong>{formatBytes(data.orphan_bytes)}</strong><span>Orphaned cache ({data.orphan_count})</span></div>
      </div>
      <div className="form-actions settings-actions">
        <button type="button" onClick={purge} disabled={purging || !data.orphan_count}><HardDrive size={16} />{purging ? "Purging..." : "Purge cache orphans"}</button>
      </div>
      <h3>Top storage users</h3>
      <div className="admin-reports-list">
        {(data.by_user || []).map((row) => (
          <article className="admin-report-row" key={row.user_id}>
            <div className="admin-report-body">
              <strong>{row.display_name || row.username}</strong>
              <p className="muted-copy">{row.item_count} item(s)</p>
            </div>
            <strong>{formatBytes(row.total_bytes)}</strong>
          </article>
        ))}
      </div>
      <h3>Tag tools</h3>
      <div className="stacked-form">
        <div className="form-row">
          <input
            type="text"
            placeholder="from tag"
            value={fromTag}
            onChange={(event) => { setFromTag(event.target.value); setTagUsage(null); }}
          />
          <input type="text" placeholder="to tag (blank = delete)" value={toTag} onChange={(event) => setToTag(event.target.value)} />
        </div>
        <div className="form-actions settings-actions">
          <button type="button" onClick={checkTagUsage} disabled={tagBusy || !fromTag.trim()}>Check usage</button>
          <button type="button" onClick={runTagRename} disabled={tagBusy || !fromTag.trim()} className="danger">
            {toTag.trim() ? "Rename / merge" : "Delete everywhere"}
          </button>
        </div>
        {tagUsage ? <p className="muted-copy">"{tagUsage.tag}" appears on {tagUsage.count} post(s).</p> : null}
      </div>
    </div>
  );
}

function SiteSettingsTab({ ctx }) {
  const [form, setForm] = useState(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const showToast = ctx.showToast;

  useEffect(() => {
    (async () => {
      setLoading(true);
      try {
        setForm(await apiFetch("/api/site/announcement"));
      } catch (error) {
        showToast(error.message, "error");
      } finally {
        setLoading(false);
      }
    })();
  }, [showToast]);

  async function save(event) {
    event.preventDefault();
    setSaving(true);
    try {
      const data = await apiFetch("/api/admin/site-settings", { method: "PATCH", body: JSON.stringify(form) });
      setForm((current) => ({ ...current, ...data.settings }));
      clearApiCache("/api/site/announcement");
      showToast("Site settings saved.", "success");
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setSaving(false);
    }
  }

  if (loading || !form) return <SkeletonList />;

  return (
    <form className="admin-tab stacked-form" onSubmit={save}>
      <div className="settings-cluster">
        <div className="settings-cluster-head"><h3><Megaphone size={16} /> Site-wide announcement</h3><p>Shows as a dismissible banner to every visitor.</p></div>
        <label className="check-row"><input type="checkbox" checked={Boolean(form.announcement_active)} onChange={(event) => setForm((c) => ({ ...c, announcement_active: event.target.checked }))} />Active</label>
        <label className="field"><span>Message</span><input value={form.announcement_message || ""} onChange={(event) => setForm((c) => ({ ...c, announcement_message: event.target.value }))} maxLength={500} /></label>
        <label className="field"><span>Level</span>
          <select value={form.announcement_level || "info"} onChange={(event) => setForm((c) => ({ ...c, announcement_level: event.target.value }))}>
            <option value="info">Info</option>
            <option value="warning">Warning</option>
            <option value="critical">Critical</option>
          </select>
        </label>
      </div>
      <div className="settings-cluster">
        <div className="settings-cluster-head"><h3>Maintenance mode</h3><p>Shows a full-page maintenance screen to everyone except you.</p></div>
        <label className="check-row"><input type="checkbox" checked={Boolean(form.maintenance_mode)} onChange={(event) => setForm((c) => ({ ...c, maintenance_mode: event.target.checked }))} />Enabled</label>
        <label className="field"><span>Message</span><input value={form.maintenance_message || ""} onChange={(event) => setForm((c) => ({ ...c, maintenance_message: event.target.value }))} maxLength={500} /></label>
      </div>
      <div className="form-actions settings-actions">
        <button className="primary" type="submit" disabled={saving}>{saving ? "Saving..." : "Save site settings"}</button>
      </div>
    </form>
  );
}

// Admin side of the public status page (/status, see routes.lua's
// M.public_status/M.admin_create_incident/M.admin_resolve_incident). A
// plain list + create form rather than a sub-tab of its own -- this is a
// handful-of-times-a-year action, not something that needs its own
// dedicated navigation slot.
function IncidentsPanel({ ctx }) {
  const [incidents, setIncidents] = useState([]);
  const [loading, setLoading] = useState(true);
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [severity, setSeverity] = useState("minor");
  const [busy, setBusy] = useState(false);
  const showToast = ctx.showToast;

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const data = await apiFetch("/api/status");
      setIncidents(data.incidents || []);
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setLoading(false);
    }
  }, [showToast]);

  useEffect(() => { load(); }, [load]);

  async function createIncident(event) {
    event.preventDefault();
    if (!title.trim()) return;
    setBusy(true);
    try {
      await apiFetch("/api/admin/incidents", {
        method: "POST",
        body: JSON.stringify({ title: title.trim(), description: description.trim() || undefined, severity }),
      });
      setTitle("");
      setDescription("");
      setSeverity("minor");
      clearApiCache("/api/status");
      load();
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setBusy(false);
    }
  }

  async function resolveIncident(id) {
    setBusy(true);
    try {
      await apiFetch(`/api/admin/incidents/${id}/resolve`, { method: "POST" });
      clearApiCache("/api/status");
      load();
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="admin-tab stacked-form">
      <div className="settings-cluster">
        <div className="settings-cluster-head"><h3><ShieldAlert size={16} /> Status page incidents</h3><p>Shown publicly at /status.</p></div>
        <form className="form-row" onSubmit={createIncident}>
          <input placeholder="Incident title" value={title} onChange={(event) => setTitle(event.target.value)} maxLength={200} />
          <select value={severity} onChange={(event) => setSeverity(event.target.value)}>
            <option value="minor">Minor</option>
            <option value="major">Major</option>
            <option value="critical">Critical</option>
          </select>
          <input placeholder="Description (optional)" value={description} onChange={(event) => setDescription(event.target.value)} maxLength={2000} />
          <button type="submit" disabled={busy || !title.trim()}>Post incident</button>
        </form>
      </div>
      {loading ? <SkeletonList /> : (
        <div className="admin-reports-list">
          {incidents.map((incident) => (
            <article className="admin-report-row" key={incident.id}>
              <div className="admin-report-body">
                <strong>{incident.title}</strong>
                <p className="muted-copy">{incident.severity} · started {formatDate(incident.started_at)}{incident.resolved ? ` · resolved ${formatDate(incident.resolved_at)}` : " · ongoing"}</p>
              </div>
              {!incident.resolved ? (
                <button type="button" onClick={() => resolveIncident(incident.id)} disabled={busy}><CheckCircle2 size={16} />Resolve</button>
              ) : null}
            </article>
          ))}
          {!incidents.length ? <EmptyState title="No incidents posted" /> : null}
        </div>
      )}
    </div>
  );
}

function MusicTab({ ctx }) {
  const [tracks, setTracks] = useState([]);
  const [maxTracks, setMaxTracks] = useState(10);
  const [loading, setLoading] = useState(true);
  const [uploading, setUploading] = useState(false);
  const [busyId, setBusyId] = useState("");
  const [clearingAll, setClearingAll] = useState(false);
  const [title, setTitle] = useState("");
  const [file, setFile] = useState(null);
  const [playlistUrl, setPlaylistUrl] = useState("");
  const [importing, setImporting] = useState(false);
  const showToast = ctx.showToast;

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const data = await apiFetch("/api/admin/background-music");
      setTracks(data.tracks || []);
      setMaxTracks(data.max_tracks || 10);
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setLoading(false);
    }
  }, [showToast]);

  useEffect(() => {
    load();
  }, [load]);

  async function upload(event) {
    event.preventDefault();
    if (!file) return showToast("Choose an audio file first.", "error");
    setUploading(true);
    try {
      const body = new FormData();
      body.set("file", file);
      body.set("title", title);
      await apiFetch("/api/admin/background-music", { method: "POST", body });
      setTitle("");
      setFile(null);
      const input = document.getElementById("bg-music-file-input");
      if (input) input.value = "";
      showToast("Track added.", "success");
      load();
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setUploading(false);
    }
  }

  // The import runs as a detached background job (each track's download can
  // take up to a few minutes -- see routes.lua's admin_import_background_
  // music_playlist), so the POST just kicks it off and this polls the
  // regular list for a while afterward so new tracks appear without the
  // admin having to remember to hit refresh themselves.
  async function importPlaylist(event) {
    event.preventDefault();
    if (!playlistUrl.trim()) return showToast("Enter a playlist URL first.", "error");
    setImporting(true);
    try {
      const result = await apiFetch("/api/admin/background-music/import-playlist", {
        method: "POST",
        body: JSON.stringify({ url: playlistUrl.trim() }),
      });
      setPlaylistUrl("");
      showToast(`Importing up to ${result.requested} track(s) in the background — this can take a few minutes.`, "success");
      const deadline = Date.now() + 5 * 60_000;
      const poll = async () => {
        await load();
        if (Date.now() < deadline) setTimeout(poll, 10_000);
      };
      setTimeout(poll, 10_000);
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setImporting(false);
    }
  }

  async function remove(trackId) {
    if (!window.confirm("Remove this background track?")) return;
    setBusyId(trackId);
    try {
      await apiFetch(`/api/admin/background-music/${trackId}`, { method: "DELETE" });
      setTracks((current) => current.filter((track) => track.id !== trackId));
      showToast("Track removed.", "success");
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setBusyId("");
    }
  }

  // No bulk-delete endpoint on the backend -- ten is a small enough count
  // that looping the existing single-track DELETE is simpler than adding
  // and maintaining a second route just for this.
  async function clearAll() {
    if (!window.confirm(`Remove all ${tracks.length} background tracks? This can't be undone.`)) return;
    setClearingAll(true);
    try {
      for (const track of tracks) {
        await apiFetch(`/api/admin/background-music/${track.id}`, { method: "DELETE" });
      }
      setTracks([]);
      showToast("All background tracks removed.", "success");
    } catch (error) {
      showToast(error.message, "error");
      load();
    } finally {
      setClearingAll(false);
    }
  }

  if (loading) return <SkeletonList />;

  return (
    <div className="admin-tab">
      <div className="settings-cluster">
        <div className="settings-cluster-head">
          <h3><Music size={16} /> Background music</h3>
          <p>Shuffled ambient tracks visitors hear while browsing. Ducks out automatically when a video with sound starts playing. Up to {maxTracks} tracks.</p>
          {tracks.length > 0 ? (
            <button type="button" onClick={clearAll} disabled={clearingAll || busyId !== ""}>
              <Trash2 size={16} />{clearingAll ? "Clearing..." : `Clear all (${tracks.length})`}
            </button>
          ) : null}
        </div>
        {tracks.length < maxTracks ? (
          <form className="stacked-form" onSubmit={upload}>
            <label className="field"><span>Title (optional)</span>
              <input value={title} onChange={(event) => setTitle(event.target.value)} maxLength={120} placeholder="Uses the filename if left blank" />
            </label>
            <label className="field"><span>Audio file</span>
              <input id="bg-music-file-input" type="file" accept="audio/*,.mp3,.wav,.ogg,.flac,.m4a" onChange={(event) => setFile(event.target.files?.[0] || null)} />
            </label>
            <div className="form-actions settings-actions">
              <button className="primary" type="submit" disabled={uploading || !file}><Upload size={16} />{uploading ? "Uploading..." : "Add track"}</button>
            </div>
          </form>
        ) : (
          <p className="muted-copy">Track limit reached — remove one below to add another.</p>
        )}
      </div>

      {tracks.length < maxTracks ? (
        <div className="settings-cluster">
          <div className="settings-cluster-head">
            <h3>Import from a playlist</h3>
            <p>Paste a playlist link (YouTube, SoundCloud, anything yt-dlp supports) and it'll randomly pull tracks to fill your remaining {maxTracks - tracks.length} slot(s). Runs in the background — can take a few minutes.</p>
          </div>
          <form className="stacked-form" onSubmit={importPlaylist}>
            <label className="field"><span>Playlist URL</span>
              <input
                type="url"
                value={playlistUrl}
                onChange={(event) => setPlaylistUrl(event.target.value)}
                placeholder="https://www.youtube.com/playlist?list=..."
              />
            </label>
            <div className="form-actions settings-actions">
              <button className="primary" type="submit" disabled={importing || !playlistUrl.trim()}>
                <Music size={16} />{importing ? "Starting import..." : "Import random tracks"}
              </button>
            </div>
          </form>
        </div>
      ) : null}

      {tracks.length === 0 ? (
        <EmptyState title="No background tracks yet" hint="Add one above to start the ambient shuffle for visitors." />
      ) : (
        <div className="admin-reports-list">
          {tracks.map((track) => (
            <article className="admin-report-row" key={track.id}>
              <div className="admin-report-body">
                <strong>{track.title}</strong>
                <p className="muted-copy">{track.original_filename} · {formatBytes(track.file_size)} · added by {track.uploaded_by_username || "unknown"} · {formatDate(track.created_at)}</p>
                <audio controls preload="none" src={track.url} style={{ marginTop: 8, maxWidth: 320 }} />
              </div>
              <button type="button" onClick={() => remove(track.id)} disabled={busyId === track.id}><Trash2 size={16} />{busyId === track.id ? "Removing..." : "Remove"}</button>
            </article>
          ))}
        </div>
      )}
    </div>
  );
}

function AuditLogTab() {
  const [entries, setEntries] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    (async () => {
      setLoading(true);
      try {
        const data = await apiFetch("/api/admin/audit-log?limit=100");
        setEntries(data.entries || []);
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  if (loading) return <SkeletonList />;

  return (
    <div className="admin-tab">
      <div className="admin-reports-list">
        {entries.map((entry) => (
          <article className="admin-report-row" key={entry.id}>
            <History size={20} />
            <div className="admin-report-body">
              <strong>{entry.action} — {entry.target_type}{entry.target_id ? ` #${entry.target_id}` : ""}</strong>
              <p className="muted-copy">
                {entry.actor_display_name || entry.actor_username || "System"} · {formatDate(entry.created_at)}
                {entry.detail ? ` — ${entry.detail}` : ""}
              </p>
            </div>
          </article>
        ))}
        {!entries.length ? <EmptyState title="No moderation activity yet" /> : null}
      </div>
    </div>
  );
}
