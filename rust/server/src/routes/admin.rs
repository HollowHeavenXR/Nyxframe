//! Site-owner admin: stats, reports, bans, audit log, flagged media,
//! storage + orphan purge, tag usage/rename, site settings, incidents,
//! background music, telemetry and user management.

use crate::app::{is_site_owner, uid};
use crate::db::{J, P, Sql};
use crate::http::{R, Reply, Req};
use crate::media::{normalize_upload_tag, thumb_url_for};
use crate::util::{append_query, cut, tobool, truthy, vstr};
use serde_json::{Value, json};
use std::collections::HashSet;

pub async fn audit(app: &crate::app::App, actor: Option<i64>, action: &str, target_type: &str, target_id: Option<i64>, detail: Option<String>) {
    let detail = detail.map(|d| cut(&d, 500)).filter(|d| !d.is_empty());
    let _ = app
        .db
        .exec(
            "INSERT INTO moderation_audit_log (actor_id, action, target_type, target_id, detail) VALUES ($1, $2, $3, $4, $5)",
            &[actor.into(), cut(action, 60).into(), cut(target_type, 30).into(), target_id.into(), detail.into()],
        )
        .await;
}

fn page(req: &Req, default: i64, max: i64) -> (i64, i64) {
    (req.qi("limit").unwrap_or(default).clamp(1, max), req.qi("offset").unwrap_or(0).max(0))
}

pub async fn stats(req: Req) -> R<Reply> {
    req.require_site_owner().await?;
    let db = &req.app.db;
    let n = |sql: &'static str| async move { db.opt(sql, &[]).await.unwrap_or_else(|| json!({})) };
    let media = n("SELECT COUNT(*) AS n, COALESCE(SUM(file_size), 0)::bigint AS bytes FROM media_items").await;
    Ok(Reply::ok(json!({ "stats": {
        "users": n("SELECT COUNT(*) AS n FROM users").await.i("n").unwrap_or(0),
        "categories": n("SELECT COUNT(*) AS n FROM categories").await.i("n").unwrap_or(0),
        "media": media.i("n").unwrap_or(0),
        "bytes": media.i("bytes").unwrap_or(0),
        "likes": n("SELECT COUNT(*) AS n FROM media_likes").await.i("n").unwrap_or(0),
    }})))
}

pub async fn list_reports(req: Req) -> R<Reply> {
    req.require_site_owner().await?;
    let status = req.q("status").filter(|s| matches!(s.as_str(), "open" | "reviewed" | "dismissed"));
    let (limit, offset) = page(&req, 50, 200);
    let mut q = Sql::new();
    let filter = status.map(|s| format!("WHERE r.status={}", q.bind(s))).unwrap_or_default();
    let (l, o) = (q.bind(limit), q.bind(offset));
    let sql = format!(
        "SELECT r.id, r.media_id, r.user_id, r.reason, r.details, r.status, r.created_at, m.title AS media_title, m.media_kind, m.mime_type, m.deleted_at AS media_deleted_at, \
           m.user_id AS media_owner_id, ru.username AS reporter_username, ru.display_name AS reporter_display_name, mu.username AS media_owner_username, mu.display_name AS media_owner_display_name \
         FROM media_reports r JOIN media_items m ON m.id = r.media_id JOIN users ru ON ru.id = r.user_id JOIN users mu ON mu.id = m.user_id {filter} ORDER BY r.created_at DESC LIMIT {l} OFFSET {o}"
    );
    let origin = req.origin();
    let rows: Vec<Value> = req
        .app
        .db
        .all(&sql, &q.params)
        .await
        .into_iter()
        .map(|mut r| {
            if let Some(m) = r.i("media_id").filter(|m| *m > 0) {
                r["media_thumb_url"] = json!(append_query(&format!("{origin}/api/media/{m}/thumb"), "w", "640"));
            }
            r
        })
        .collect();
    Ok(Reply::ok(json!({ "reports": rows, "limit": limit, "offset": offset })))
}

pub async fn resolve_report(req: Req) -> R<Reply> {
    let owner = req.require_site_owner().await?;
    let o = uid(&owner);
    let rid = req.pi("report_id").ok_or_else(|| Reply::err(404, "Report not found."))?;
    let st = req.js("status").unwrap_or_default();
    if st != "reviewed" && st != "dismissed" {
        return Err(Reply::err(400, "status must be reviewed or dismissed."));
    }
    let db = &req.app.db;
    let _ = db.exec("UPDATE media_reports SET status=$1 WHERE id=$2", &[st.as_str().into(), rid.into()]).await;
    let report = db.opt("SELECT * FROM media_reports WHERE id=$1", &[rid.into()]).await.ok_or_else(|| Reply::err(404, "Report not found."))?;
    let mid = report.i("media_id").unwrap_or(0);
    audit(&req.app, Some(o), &format!("report_{st}"), "report", Some(rid), Some(format!("media_id={mid}"))).await;
    if truthy(req.json.get("delete_media")) {
        let _ = db.exec("UPDATE media_items SET deleted_at=CURRENT_TIMESTAMP, visibility='private' WHERE id=$1 AND deleted_at IS NULL", &[mid.into()]).await;
        audit(&req.app, Some(o), "delete_media", "media", Some(mid), None).await;
    }
    Ok(Reply::ok(json!({ "report": report })))
}

async fn user_out(req: &Req, id: i64) -> R<Reply> {
    req.app.invalidate_user(id);
    let mut u = req.app.get_user(id).await.ok_or_else(|| Reply::err(404, "User not found."))?;
    u["site_owner"] = json!(is_site_owner(&u));
    Ok(Reply::ok(json!({ "user": u })))
}

pub async fn ban_user(req: Req) -> R<Reply> {
    let owner = req.require_site_owner().await?;
    let id = req.pi("user_id").ok_or_else(|| Reply::err(404, "User not found."))?;
    if id == uid(&owner) {
        return Err(Reply::err(400, "You cannot ban your own account."));
    }
    let reason = Some(cut(req.js("reason").unwrap_or_default().trim(), 300)).filter(|r| !r.is_empty());
    let until = req.js("until");
    let _ = req
        .app
        .db
        .exec("UPDATE users SET banned_at=CURRENT_TIMESTAMP, banned_until=$1::text::timestamp, ban_reason=$2, banned_by=$3 WHERE id=$4", &[until.into(), reason.clone().into(), uid(&owner).into(), id.into()])
        .await;
    if req.app.get_user(id).await.is_none() {
        return Err(Reply::err(404, "User not found."));
    }
    audit(&req.app, Some(uid(&owner)), "ban", "user", Some(id), reason).await;
    user_out(&req, id).await
}

pub async fn unban_user(req: Req) -> R<Reply> {
    let owner = req.require_site_owner().await?;
    let id = req.pi("user_id").ok_or_else(|| Reply::err(404, "User not found."))?;
    let _ = req.app.db.exec("UPDATE users SET banned_at=NULL, banned_until=NULL, ban_reason=NULL, banned_by=NULL WHERE id=$1", &[id.into()]).await;
    if req.app.get_user(id).await.is_none() {
        return Err(Reply::err(404, "User not found."));
    }
    audit(&req.app, Some(uid(&owner)), "unban", "user", Some(id), None).await;
    user_out(&req, id).await
}

pub async fn audit_log(req: Req) -> R<Reply> {
    req.require_site_owner().await?;
    let (limit, offset) = page(&req, 50, 200);
    let rows = req
        .app
        .db
        .all(
            "SELECT a.*, u.username AS actor_username, COALESCE(u.display_name, u.username) AS actor_display_name FROM moderation_audit_log a LEFT JOIN users u ON u.id = a.actor_id ORDER BY a.created_at DESC LIMIT $1 OFFSET $2",
            &[limit.into(), offset.into()],
        )
        .await;
    Ok(Reply::ok(json!({ "entries": rows })))
}

pub async fn flagged_media(req: Req) -> R<Reply> {
    req.require_site_owner().await?;
    let (limit, offset) = page(&req, 50, 200);
    let origin = req.origin();
    let rows: Vec<Value> = req
        .app
        .db
        .all(
            "SELECT m.*, u.username AS owner_username, COALESCE(u.display_name, u.username) AS owner_display_name FROM media_items m JOIN users u ON u.id = m.user_id \
             WHERE m.moderation_status='pending_review' AND m.deleted_at IS NULL ORDER BY m.created_at DESC LIMIT $1 OFFSET $2",
            &[limit.into(), offset.into()],
        )
        .await
        .into_iter()
        .map(|mut r| {
            if let Some(t) = thumb_url_for(&origin, r.i("id").unwrap_or(0), &r.s("media_kind").unwrap_or_default(), &r["updated_at"]) {
                r["thumb_url"] = json!(t);
            }
            r
        })
        .collect();
    Ok(Reply::ok(json!({ "media": rows })))
}

pub async fn resolve_flagged(req: Req) -> R<Reply> {
    let owner = req.require_site_owner().await?;
    let id = req.pi("media_id").ok_or_else(|| Reply::err(404, "Flagged media not found."))?;
    let d = req.js("decision").unwrap_or_default();
    if d != "clear" && d != "adult" {
        return Err(Reply::err(400, "decision must be clear or adult."));
    }
    let db = &req.app.db;
    let _ = db.exec("UPDATE media_items SET moderation_status=$1, is_adult=$2, moderated_at=CURRENT_TIMESTAMP WHERE id=$3 AND moderation_status='pending_review'", &[d.as_str().into(), (d == "adult").into(), id.into()]).await;
    let item = db.opt("SELECT * FROM media_items WHERE id=$1", &[id.into()]).await.ok_or_else(|| Reply::err(404, "Flagged media not found."))?;
    audit(&req.app, Some(uid(&owner)), &format!("flagged_media_{d}"), "media", Some(id), None).await;
    Ok(Reply::ok(json!({ "media": item })))
}

// ---- storage ----------------------------------------------------------------------------------------
struct Orphans {
    total_bytes: u64,
    total_files: u64,
    orphan_bytes: u64,
    files: Vec<(std::path::PathBuf, u64)>,
}

async fn walk_caches(req: &Req) -> Result<Orphans, Reply> {
    let ids: HashSet<String> = req.app.db.query("SELECT id FROM media_items WHERE deleted_at IS NULL", &[]).await.map_err(crate::media::query_failed)?.iter().filter_map(|r| r.i("id")).map(|i| i.to_string()).collect();
    let root = req.app.settings.uploads_dir.clone();
    tokio::task::spawn_blocking(move || {
        let mut o = Orphans { total_bytes: 0, total_files: 0, orphan_bytes: 0, files: vec![] };
        let now = std::time::SystemTime::now();
        for d in ["_thumb_cache", "_video_cache", "_watermark_cache", "_original_cache"] {
            let mut stack = vec![std::path::PathBuf::from(format!("{root}/{d}"))];
            while let Some(dir) = stack.pop() {
                let Ok(rd) = std::fs::read_dir(&dir) else { continue };
                for e in rd.flatten() {
                    let p = e.path();
                    let Ok(m) = e.metadata() else { continue };
                    if m.is_dir() {
                        stack.push(p);
                        continue;
                    }
                    o.total_bytes += m.len();
                    o.total_files += 1;
                    let name = e.file_name().to_string_lossy().to_string();
                    let id: String = name.chars().take_while(char::is_ascii_digit).collect();
                    let old = m.modified().ok().and_then(|t| now.duration_since(t).ok()).is_some_and(|a| a.as_secs() > 86400);
                    if (id.is_empty() || !ids.contains(&id)) && old {
                        o.orphan_bytes += m.len();
                        o.files.push((p, m.len()));
                    }
                }
            }
        }
        o
    })
    .await
    .map_err(|_| Reply::err(500, "Storage scan failed."))
}

pub async fn storage(req: Req) -> R<Reply> {
    req.require_site_owner().await?;
    let db = &req.app.db;
    let totals = db.opt("SELECT COALESCE(SUM(file_size), 0)::bigint AS total_bytes, COUNT(*) AS total_items FROM media_items WHERE deleted_at IS NULL", &[]).await.unwrap_or_else(|| json!({}));
    let by_user = db
        .all(
            "SELECT m.user_id, u.username, COALESCE(u.display_name, u.username) AS display_name, COUNT(*) AS item_count, COALESCE(SUM(m.file_size), 0)::bigint AS total_bytes \
             FROM media_items m JOIN users u ON u.id = m.user_id WHERE m.deleted_at IS NULL GROUP BY m.user_id, u.id ORDER BY total_bytes DESC LIMIT 25",
            &[],
        )
        .await;
    let o = walk_caches(&req).await?;
    Ok(Reply::ok(json!({
        "total_bytes": totals.i("total_bytes").unwrap_or(0), "total_items": totals.i("total_items").unwrap_or(0), "by_user": by_user,
        "cache_total_bytes": o.total_bytes, "cache_total_files": o.total_files, "orphan_bytes": o.orphan_bytes, "orphan_count": o.files.len(),
    })))
}

pub async fn purge_orphans(req: Req) -> R<Reply> {
    let owner = req.require_site_owner().await?;
    let o = walk_caches(&req).await?;
    let (mut removed, mut freed) = (0u64, 0u64);
    for (p, size) in o.files {
        if tokio::fs::remove_file(&p).await.is_ok() {
            removed += 1;
            freed += size;
        }
    }
    audit(&req.app, Some(uid(&owner)), "storage_purge_orphans", "storage", None, Some(format!("removed={removed} bytes={freed}"))).await;
    Ok(Reply::ok(json!({ "removed": removed, "freed_bytes": freed })))
}

// ---- tags / settings / incidents ------------------------------------------------------------------------
pub async fn tag_usage(req: Req) -> R<Reply> {
    req.require_site_owner().await?;
    let tag = normalize_upload_tag(&crate::http::url_decode(&req.p("tag")), req.app.settings.max_tag_length);
    if tag.is_empty() {
        return Err(Reply::err(400, "Invalid tag."));
    }
    let row = req.app.db.one("SELECT COUNT(*) AS n FROM media_items WHERE deleted_at IS NULL AND tags IS NOT NULL AND tags::jsonb ? $1", &[tag.as_str().into()]).await.map_err(crate::media::query_failed)?;
    Ok(Reply::ok(json!({ "tag": tag, "count": row.and_then(|r| r.i("n")).unwrap_or(0) })))
}

pub async fn rename_tag(req: Req) -> R<Reply> {
    let owner = req.require_site_owner().await?;
    let ml = req.app.settings.max_tag_length;
    let from = normalize_upload_tag(&req.js("from").unwrap_or_default(), ml);
    let to = normalize_upload_tag(&req.js("to").unwrap_or_default(), ml);
    if from.is_empty() {
        return Err(Reply::err(400, "`from` tag is required."));
    }
    if from == to {
        return Err(Reply::err(400, "`to` must differ from `from` (or be omitted to delete)."));
    }
    let drop = to.is_empty();
    let expr = if drop { "CASE WHEN elem = $1 THEN NULL ELSE elem END" } else { "CASE WHEN elem = $1 THEN $2 ELSE elem END" };
    let sql = format!(
        "UPDATE media_items SET tags = (SELECT COALESCE(to_jsonb(array_agg(DISTINCT elem)), '[]'::jsonb)::text FROM (SELECT {expr} AS elem FROM jsonb_array_elements_text(tags::jsonb) AS elem) sub WHERE elem IS NOT NULL), \
         updated_at = now() WHERE deleted_at IS NULL AND tags IS NOT NULL AND tags::jsonb ? $1 RETURNING id"
    );
    let params: Vec<P> = if drop { vec![from.as_str().into()] } else { vec![from.as_str().into(), to.as_str().into()] };
    let rows = req.app.db.query(&sql, &params).await.map_err(crate::media::query_failed)?;
    audit(&req.app, Some(uid(&owner)), if drop { "tag_delete" } else { "tag_rename" }, "media_items", None, Some(format!("from={from} to={} affected={}", if drop { "(deleted)" } else { &to }, rows.len()))).await;
    Ok(Reply::ok(json!({ "from": from, "to": if drop { Value::Null } else { json!(to) }, "affected": rows.len() })))
}

pub async fn update_site_settings(req: Req) -> R<Reply> {
    let owner = req.require_site_owner().await?;
    let mut q = Sql::new();
    let mut sets = vec![];
    let mut touched = vec![];
    for k in ["announcement_message", "announcement_level", "announcement_active", "maintenance_mode", "maintenance_message"] {
        let Some(v) = req.json.get(k).filter(|v| !v.is_null()) else { continue };
        let ph = if matches!(k, "announcement_active" | "maintenance_mode") { q.bind(tobool(Some(v))) } else { q.bind(cut(&vstr(Some(v)).unwrap_or_default(), 500)) };
        sets.push(format!("{k}={ph}"));
        touched.push(k);
    }
    let db = &req.app.db;
    if !sets.is_empty() {
        sets.push(format!("updated_by={}", q.bind(uid(&owner))));
        let _ = db.exec(&format!("UPDATE site_settings SET {} WHERE id=1", sets.join(", ")), &q.params).await;
        audit(&req.app, Some(uid(&owner)), "site_settings_update", "site_settings", None, Some(touched.join(", "))).await;
    }
    let s = db.opt("SELECT * FROM site_settings WHERE id=1", &[]).await.unwrap_or_else(|| json!({}));
    Ok(Reply::ok(json!({ "settings": s })))
}

pub async fn create_incident(req: Req) -> R<Reply> {
    let owner = req.require_site_owner().await?;
    let title = cut(req.js("title").unwrap_or_default().trim(), 200);
    if title.is_empty() {
        return Err(Reply::err(400, "Title is required."));
    }
    let desc = req.js("description").map(|d| cut(&d, 2000));
    let sev = req.js("severity").map(|s| s.to_lowercase()).filter(|s| matches!(s.as_str(), "minor" | "major" | "critical")).unwrap_or_else(|| "minor".into());
    let id = req
        .app
        .db
        .one("INSERT INTO status_incidents (title, description, severity, created_by) VALUES ($1, $2, $3, $4) RETURNING id", &[title.as_str().into(), desc.into(), sev.as_str().into(), uid(&owner).into()])
        .await
        .map_err(|e| Reply::err(500, format!("Could not create incident: {e}")))?
        .and_then(|r| r.i("id"))
        .unwrap_or(0);
    audit(&req.app, Some(uid(&owner)), "incident_create", "status_incidents", Some(id), Some(title.clone())).await;
    Ok(Reply::ok(json!({ "id": id, "title": title, "severity": sev })))
}

pub async fn resolve_incident(req: Req) -> R<Reply> {
    let owner = req.require_site_owner().await?;
    let id = req.pi("incident_id").ok_or_else(|| Reply::err(404, "Incident not found."))?;
    if req.app.db.opt("SELECT id FROM status_incidents WHERE id=$1", &[id.into()]).await.is_none() {
        return Err(Reply::err(404, "Incident not found."));
    }
    let _ = req.app.db.exec("UPDATE status_incidents SET resolved_at=now() WHERE id=$1", &[id.into()]).await;
    audit(&req.app, Some(uid(&owner)), "incident_resolve", "status_incidents", Some(id), None).await;
    Ok(Reply::ok(json!({ "id": id, "resolved": true })))
}

// ---- background music ----------------------------------------------------------------------------------
const MAX_TRACKS: i64 = 10;
const MAX_TRACK_BYTES: usize = 30 * 1024 * 1024;

fn sniff_audio(c: &[u8]) -> Option<(&'static str, &'static str)> {
    let h = &c[..c.len().min(64)];
    if h.starts_with(b"ID3") || (h.len() >= 2 && h[0] == 0xFF && h[1] & 0xE0 == 0xE0) {
        return Some(("audio/mpeg", ".mp3"));
    }
    if h.starts_with(b"RIFF") && h.get(8..12) == Some(b"WAVE") {
        return Some(("audio/wav", ".wav"));
    }
    if h.starts_with(b"OggS") {
        return Some(("audio/ogg", ".ogg"));
    }
    if h.starts_with(b"fLaC") {
        return Some(("audio/flac", ".flac"));
    }
    if h.len() >= 12 && &h[4..8] == b"ftyp" {
        let b = String::from_utf8_lossy(&h[8..h.len().min(32)]).to_lowercase();
        if b.contains("m4a") || b.contains("m4b") {
            return Some(("audio/mp4", ".m4a"));
        }
    }
    None
}

pub async fn admin_list_music(req: Req) -> R<Reply> {
    req.require_site_owner().await?;
    let origin = req.origin();
    let rows: Vec<Value> = req
        .app
        .db
        .all("SELECT bm.id, bm.title, bm.original_filename, bm.mime_type, bm.file_size, bm.sort_order, bm.created_at, u.username AS uploaded_by_username FROM background_music bm LEFT JOIN users u ON u.id = bm.uploaded_by ORDER BY bm.sort_order ASC, bm.id ASC", &[])
        .await
        .into_iter()
        .map(|mut r| {
            r["url"] = json!(format!("{origin}/api/background-music/{}/file", r.i("id").unwrap_or(0)));
            r
        })
        .collect();
    Ok(Reply::ok(json!({ "tracks": rows, "max_tracks": MAX_TRACKS })))
}

async fn track_count(req: &Req) -> i64 {
    req.app.db.opt("SELECT COUNT(*) AS n FROM background_music", &[]).await.and_then(|r| r.i("n")).unwrap_or(0)
}

pub async fn admin_upload_music(req: Req) -> R<Reply> {
    let owner = req.require_site_owner().await?;
    if track_count(&req).await >= MAX_TRACKS {
        return Err(Reply::err(400, format!("Only {MAX_TRACKS} background tracks are allowed at once -- remove one first.")));
    }
    let Some(f) = req.file("file").filter(|f| !f.data.is_empty()) else { return Err(Reply::err(400, "Upload is empty.")) };
    if f.data.len() > MAX_TRACK_BYTES {
        return Err(Reply::err(413, "Tracks must be 30MB or smaller."));
    }
    let (mime, ext) = sniff_audio(&f.data).ok_or_else(|| Reply::err(400, "Unsupported audio format. Use MP3, WAV, OGG, FLAC, or M4A."))?;
    let name = crate::sniff::clean_filename(&f.filename, "track");
    let mut title = cut(req.form.get("title").map(|t| t.trim()).unwrap_or(""), 120);
    if title.is_empty() {
        title = name.strip_suffix(ext).map(str::to_string).unwrap_or_else(|| name.rfind('.').map(|i| name[..i].to_string()).unwrap_or_else(|| name.clone()));
    }
    let db = &req.app.db;
    let sort = db.opt("SELECT COALESCE(MAX(sort_order), -1) + 1 AS n FROM background_music", &[]).await.and_then(|r| r.i("n")).unwrap_or(0);
    let id = db
        .opt(
            "INSERT INTO background_music (title, original_filename, mime_type, content, file_size, sort_order, uploaded_by) VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id",
            &[title.as_str().into(), name.into(), mime.into(), P::Bytes(f.data.to_vec()), (f.data.len() as i64).into(), sort.into(), uid(&owner).into()],
        )
        .await
        .and_then(|r| r.i("id"));
    audit(&req.app, Some(uid(&owner)), "background_music_upload", "background_music", id, Some(title.clone())).await;
    Ok(Reply::ok(json!({ "id": id, "title": title })))
}

pub async fn admin_delete_music(req: Req) -> R<Reply> {
    let owner = req.require_site_owner().await?;
    let id = req.pi("track_id").ok_or_else(|| Reply::err(404, "Track not found."))?;
    let row = req.app.db.opt("SELECT id, title FROM background_music WHERE id=$1", &[id.into()]).await.ok_or_else(|| Reply::err(404, "Track not found."))?;
    let _ = req.app.db.exec("DELETE FROM background_music WHERE id=$1", &[id.into()]).await;
    audit(&req.app, Some(uid(&owner)), "background_music_delete", "background_music", Some(id), row.s("title")).await;
    Ok(Reply::ok(json!({ "ok": true })))
}

pub async fn list_music(req: Req) -> R<Reply> {
    let origin = req.origin();
    let rows: Vec<Value> = req
        .app
        .db
        .all("SELECT id, title FROM background_music ORDER BY sort_order ASC, id ASC", &[])
        .await
        .into_iter()
        .map(|mut r| {
            r["url"] = json!(format!("{origin}/api/background-music/{}/file", r.i("id").unwrap_or(0)));
            r
        })
        .collect();
    Ok(Reply::ok(json!({ "tracks": rows })))
}

pub async fn music_file(req: Req) -> R<Reply> {
    let id = req.pi("track_id").ok_or_else(|| Reply::err(404, "Track not found."))?;
    let mime = req.app.db.opt("SELECT mime_type FROM background_music WHERE id=$1", &[id.into()]).await.and_then(|r| r.s("mime_type")).ok_or_else(|| Reply::err(404, "Track not found."))?;
    let content = req.app.db.bytes("SELECT content FROM background_music WHERE id=$1", &[id.into()]).await.ok().flatten().unwrap_or_default();
    Ok(Reply::bytes(200, content, &mime).header("Cache-Control", "public, max-age=86400"))
}

pub async fn import_music_playlist(req: Req) -> R<Reply> {
    let owner = req.require_site_owner().await?;
    let url = req.js("url").unwrap_or_default().trim().to_string();
    if url.is_empty() || !(url.starts_with("http://") || url.starts_with("https://")) {
        return Err(Reply::err(400, "Enter a valid playlist URL."));
    }
    let remaining = MAX_TRACKS - track_count(&req).await;
    if remaining <= 0 {
        return Err(Reply::err(400, format!("Only {MAX_TRACKS} background tracks are allowed at once -- remove one first.")));
    }
    let want = remaining.min(req.ji("count").unwrap_or(remaining)).min(10).max(1);
    let token = crate::auth::issue_token(req.app.secret(), json!({ "id": uid(&owner).to_string(), "username": owner["username"] }), 1200);
    let ytdlp = std::env::var("GALLERY_YTDLP_BIN").unwrap_or_else(|_| format!("{}/.local/bin/yt-dlp", std::env::var("HOME").unwrap_or_else(|_| "/home/desmondc".into())));
    let port = req.app.settings.port;
    let (u2, http) = (url.clone(), req.app.http.clone());
    tokio::spawn(async move {
        let list = tokio::process::Command::new(&ytdlp).args(["--flat-playlist", "--print", "%(webpage_url)s"]).arg(&u2).stderr(std::process::Stdio::null()).output().await;
        let Ok(list) = list else { return };
        let mut urls: Vec<String> = String::from_utf8_lossy(&list.stdout).lines().map(str::trim).filter(|l| !l.is_empty()).map(str::to_string).collect();
        use rand::seq::SliceRandom;
        urls.shuffle(&mut rand::rng());
        for v in urls.into_iter().take(want as usize) {
            let dir = crate::media_files::tmp_path(".yt");
            let _ = tokio::fs::create_dir_all(&dir).await;
            let mut c = tokio::process::Command::new("timeout");
            c.args(["180", "nice", "-n", "15", "ionice", "-c2", "-n6"]).arg(&ytdlp).args(["-x", "--audio-format", "mp3", "--audio-quality", "5", "-o"]).arg(format!("{dir}/%(title).100B.%(ext)s")).arg(&v);
            c.stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
            let _ = c.status().await;
            if let Ok(mut rd) = tokio::fs::read_dir(&dir).await {
                while let Ok(Some(e)) = rd.next_entry().await {
                    let p = e.path();
                    if p.extension().is_some_and(|x| x == "mp3") {
                        if let Ok(bytes) = tokio::fs::read(&p).await {
                            let part = reqwest::multipart::Part::bytes(bytes).file_name(e.file_name().to_string_lossy().to_string()).mime_str("audio/mpeg").unwrap();
                            let _ = http.post(format!("http://127.0.0.1:{port}/api/admin/background-music")).bearer_auth(&token).multipart(reqwest::multipart::Form::new().part("file", part)).send().await;
                        }
                        break;
                    }
                }
            }
            let _ = tokio::fs::remove_dir_all(&dir).await;
        }
    });
    audit(&req.app, Some(uid(&owner)), "background_music_playlist_import", "background_music", None, Some(cut(&url, 200))).await;
    Ok(Reply::json(202, json!({ "status": "importing", "requested": want })))
}

// ---- telemetry ------------------------------------------------------------------------------------------
pub async fn telemetry(req: Req) -> R<Reply> {
    req.require_site_owner().await?;
    let snap = req.app.telemetry.snapshot();
    let recent = req.app.telemetry.recent_events(req.q("event_type").as_deref(), req.qi("limit").unwrap_or(50)).await;
    Ok(Reply::ok(json!({
        "request_stats": snap["request_stats"], "request_stats_since": snap["request_stats_since"], "jobs": snap["jobs"], "counters": snap["counters"],
        "transcode_active_slots": crate::video::active_slots(&req.app), "transcode_max_concurrent": crate::video::MAX_CONCURRENT, "recent_events": recent,
    })))
}

// ---- users -----------------------------------------------------------------------------------------------
const USER_COLS: &str = "u.id, u.username, u.display_name, u.email, u.email_verified_at, u.profile_color, u.avatar_path, u.avatar_file_id, u.created_at, u.last_seen_at, u.last_login_at, \
                         u.banned_at, u.banned_until, u.ban_reason, u.age_verified_at";

fn admin_row(req: &Req, mut r: Value) -> Value {
    for k in ["post_count", "comment_count", "like_count", "collection_count", "storage_bytes"] {
        r[k] = json!(r.i(k).unwrap_or(0));
    }
    r["site_owner"] = json!(is_site_owner(&r));
    r["banned"] = json!(!r["banned_at"].is_null());
    let has_avatar = !r["avatar_path"].is_null() || !r["avatar_file_id"].is_null();
    let id = r.i("id").unwrap_or(0);
    let o = r.as_object_mut().unwrap();
    o.remove("avatar_path");
    o.remove("avatar_file_id");
    if has_avatar {
        o.insert("avatar_url".into(), json!(format!("{}/api/users/{id}/avatar", req.origin())));
    }
    r
}

pub async fn list_users(req: Req) -> R<Reply> {
    req.require_site_owner().await?;
    let q = cut(req.q("q").unwrap_or_default().trim(), 80);
    let order = match req.q("sort").as_deref().unwrap_or("newest") {
        "oldest" => "u.created_at ASC",
        "posts" => "post_count DESC, u.id DESC",
        "last_seen" => "u.last_seen_at DESC NULLS LAST",
        "name" => "lower(u.username) ASC",
        "storage" => "storage_bytes DESC, u.id DESC",
        _ => "u.created_at DESC",
    };
    let limit = req.qi("limit").unwrap_or(50).clamp(1, 100);
    let offset = req.qi("offset").unwrap_or(0).max(0);
    let mut s = Sql::new();
    let mut w = vec!["TRUE".to_string()];
    if !q.is_empty() {
        let mut like = String::from("%");
        for c in q.chars() {
            if "%_\\".contains(c) {
                like.push('\\');
            }
            like.push(c);
        }
        like.push('%');
        let p = s.bind(like);
        w.push(format!("(u.username ILIKE {p} OR u.display_name ILIKE {p} OR u.email ILIKE {p})"));
    }
    match req.q("filter").as_deref() {
        Some("banned") => w.push("u.banned_at IS NOT NULL".into()),
        Some("active") => w.push("u.banned_at IS NULL".into()),
        _ => {}
    }
    let (l, o) = (s.bind(limit + 1), s.bind(offset));
    let sql = format!(
        "SELECT {USER_COLS}, (SELECT count(*) FROM media_items m WHERE m.user_id = u.id AND m.deleted_at IS NULL) AS post_count, (SELECT count(*) FROM media_comments c WHERE c.user_id = u.id) AS comment_count, \
           (SELECT count(*) FROM media_likes l WHERE l.user_id = u.id) AS like_count, (SELECT count(*) FROM media_collections col WHERE col.user_id = u.id) AS collection_count, \
           (SELECT COALESCE(sum(m2.file_size), 0) FROM media_items m2 WHERE m2.user_id = u.id)::bigint AS storage_bytes \
         FROM users u WHERE {} ORDER BY {order} LIMIT {l} OFFSET {o}",
        w.join(" AND ")
    );
    let rows = req.app.db.query(&sql, &s.params).await.map_err(crate::media::query_failed)?;
    let has_more = rows.len() as i64 > limit;
    let users: Vec<Value> = rows.into_iter().take(limit as usize).map(|r| admin_row(&req, r)).collect();
    let total = req.app.db.opt("SELECT count(*) AS n FROM users", &[]).await.and_then(|r| r.i("n")).unwrap_or(0);
    Ok(Reply::ok(json!({ "users": users, "has_more": has_more, "total_users": total })))
}

async fn user_counts(req: &Req, id: i64) -> Value {
    let row = req
        .app
        .db
        .opt(
            "SELECT (SELECT count(*) FROM media_items WHERE user_id = $1) AS posts, (SELECT count(*) FROM media_items WHERE user_id = $1 AND media_kind = 'video') AS videos, \
               (SELECT count(*) FROM media_items WHERE user_id = $1 AND media_kind = 'image') AS images, (SELECT COALESCE(sum(file_size), 0) FROM media_items WHERE user_id = $1)::bigint AS storage_bytes, \
               (SELECT count(*) FROM media_comments WHERE user_id = $1) AS comments, \
               (SELECT count(*) FROM media_comments c JOIN media_items m ON m.id = c.media_id WHERE m.user_id = $1 AND c.user_id <> $1) AS comments_from_others, \
               (SELECT count(*) FROM media_likes WHERE user_id = $1) AS likes, (SELECT count(*) FROM media_bookmarks WHERE user_id = $1) AS bookmarks, \
               (SELECT count(*) FROM media_collections WHERE user_id = $1) AS collections, (SELECT count(*) FROM user_follows WHERE followed_id = $1) AS followers, \
               (SELECT count(*) FROM user_follows WHERE follower_id = $1) AS following, \
               (SELECT count(*) FROM user_messages WHERE sender_id = $1) + (SELECT count(*) FROM thread_messages WHERE sender_id = $1) + (SELECT count(*) FROM group_messages WHERE sender_id = $1) AS messages",
            &[id.into()],
        )
        .await
        .unwrap_or_else(|| json!({}));
    let mut out = serde_json::Map::new();
    if let Some(o) = row.as_object() {
        for (k, _) in o {
            out.insert(k.clone(), json!(row.i(k).unwrap_or(0)));
        }
    }
    Value::Object(out)
}

pub async fn user_summary(req: Req) -> R<Reply> {
    let owner = req.require_site_owner().await?;
    let id = req.pi("user_id").ok_or_else(|| Reply::err(404, "User not found."))?;
    let row = req
        .app
        .db
        .opt(&format!("SELECT {USER_COLS}, 0 AS post_count, 0 AS comment_count, 0 AS like_count, 0 AS collection_count, 0 AS storage_bytes FROM users u WHERE u.id = $1"), &[id.into()])
        .await
        .ok_or_else(|| Reply::err(404, "User not found."))?;
    let mut user = admin_row(&req, row);
    let counts = user_counts(&req, id).await;
    for (k, c) in [("post_count", "posts"), ("comment_count", "comments"), ("like_count", "likes"), ("collection_count", "collections"), ("storage_bytes", "storage_bytes")] {
        user[k] = counts[c].clone();
    }
    user["can_delete"] = json!(!tobool(user.get("site_owner")) && id != uid(&owner));
    Ok(Reply::ok(json!({ "user": user, "counts": counts })))
}

async fn purge_user_files(app: crate::app::AppRef, rows: Vec<Value>, user_id: i64) {
    let up = app.settings.uploads_dir.clone();
    let roots: Vec<String> = [Some(up.clone()), crate::media_files::hot_root()].into_iter().flatten().collect();
    let mut removed = 0;
    let rm_prefix = |dir: String, prefix: String| {
        if let Ok(rd) = std::fs::read_dir(&dir) {
            for e in rd.flatten() {
                if e.file_name().to_string_lossy().starts_with(&prefix) {
                    let p = e.path();
                    let _ = if p.is_dir() { std::fs::remove_dir_all(&p) } else { std::fs::remove_file(&p) };
                }
            }
        }
    };
    for r in &rows {
        let id = r.i("id").unwrap_or(0);
        if let Some(sp) = r.s("storage_path").filter(|s| !s.starts_with("db://") && !s.contains("..")) {
            if app.db.opt("SELECT 1 AS x FROM media_items WHERE storage_path = $1 LIMIT 1", &[sp.as_str().into()]).await.is_none() {
                for root in &roots {
                    if std::fs::remove_file(format!("{root}/{sp}")).is_ok() {
                        removed += 1;
                    }
                }
            }
        }
        if let Some(ct) = r.s("custom_thumb_path").filter(|c| !c.contains("..")) {
            for root in &roots {
                let _ = std::fs::remove_file(format!("{root}/{ct}"));
            }
        }
        if id > 0 {
            let sh = crate::video::shard(id);
            let p = format!("{id}_");
            for d in ["_hls_cache", "_video_cache", "_extras_cache", "_watermark_cache", "_thumb_cache"] {
                rm_prefix(format!("{up}/{d}"), p.clone());
            }
            for d in [format!("_thumb_cache/{sh}"), format!("_preview_cache/{sh}"), format!("_original_cache/{sh}")] {
                rm_prefix(format!("{up}/{d}"), p.clone());
            }
        }
        tokio::task::yield_now().await;
    }
    rm_prefix(format!("{up}/_preview_cache/avatars"), format!("{user_id}_"));
    println!("[nyxframe] deleted user {user_id}: removed {removed} stored files for {} posts", rows.len());
}

pub async fn delete_user(req: Req) -> R<Reply> {
    let owner = req.require_site_owner().await?;
    let o = uid(&owner);
    let id = req.pi("user_id").ok_or_else(|| Reply::err(404, "User not found."))?;
    let target = req.app.get_user(id).await.ok_or_else(|| Reply::err(404, "User not found."))?;
    if id == o {
        return Err(Reply::err(400, "You can't delete your own account from here."));
    }
    if is_site_owner(&target) {
        return Err(Reply::err(400, "The site owner's account can't be deleted."));
    }
    if req.js("confirm_username") != target.s("username") {
        return Err(Reply::err(400, "Type the username exactly to confirm."));
    }
    let counts = user_counts(&req, id).await;
    let db = &req.app.db;
    let rows = db.all("SELECT id, storage_path, custom_thumb_path FROM media_items WHERE user_id = $1", &[id.into()]).await;
    let _ = db.exec("UPDATE status_incidents SET created_by = $1 WHERE created_by = $2", &[o.into(), id.into()]).await;
    for (tbl, members, key) in [("message_threads", "message_thread_members", "thread_id"), ("message_groups", "message_group_members", "group_id")] {
        let _ = db
            .exec(
                &format!(
                    "UPDATE {tbl} t SET created_by = (SELECT mm.user_id FROM {members} mm WHERE mm.{key} = t.id AND mm.user_id <> $1 ORDER BY mm.joined_at, mm.user_id LIMIT 1) \
                     WHERE t.created_by = $1 AND EXISTS (SELECT 1 FROM {members} mm2 WHERE mm2.{key} = t.id AND mm2.user_id <> $1)"
                ),
                &[id.into()],
            )
            .await;
    }
    db.exec("DELETE FROM users WHERE id = $1", &[id.into()]).await.map_err(|e| Reply::err(500, format!("Could not delete the user: {e}")))?;
    req.app.invalidate_user(id);
    let name = target.s("username").unwrap_or_default();
    let n = |k: &str| counts.i(k).unwrap_or(0);
    audit(&req.app, Some(o), "delete_user", "user", Some(id), Some(format!("@{name} permanently deleted: {} posts, {} comments, {} likes, {} collections", n("posts"), n("comments"), n("likes"), n("collections")))).await;
    tokio::spawn(purge_user_files(req.app.clone(), rows, id));
    Ok(Reply::ok(json!({ "deleted": true, "username": name, "removed": counts })))
}
