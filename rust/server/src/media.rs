//! Media row shaping shared by every list/detail endpoint (routes.lua's
//! with_urls, decode_media_row, attach_media_subcategories, the common
//! SELECT and fetch_media_feed).

use crate::db::{J, Sql};
use crate::http::{R, Reply, Req};
use crate::util::{append_query, bools, digits, json_list};
use serde_json::{Value, json};
use std::collections::HashMap;

/// The list SELECT; `{v}` is the viewer-id text placeholder.
pub fn select_cols(v: &str) -> String {
    format!(
        "SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.description, m.tags, \
           m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.file_size, m.video_codecs, \
           m.views, m.downloads, m.created_at, m.updated_at, m.visibility, \
           m.comments_enabled, m.downloads_enabled, m.pinned_at, m.is_adult, \
           m.adult_marked_by_user, m.adult_marked_by_ai, m.moderation_status, m.dominant_color, m.source_url, \
           c.name AS category_name, c.slug AS category_slug, \
           sc.name AS subcategory_name, sc.slug AS subcategory_slug, \
           u.username, \
           CASE WHEN u.public_profile OR u.id::text={v} THEN u.display_name ELSE u.username END AS display_name, \
           CASE WHEN u.public_profile OR u.id::text={v} THEN u.bio ELSE NULL END AS user_bio, \
           CASE WHEN u.public_profile OR u.id::text={v} THEN u.website_url ELSE NULL END AS user_website_url, \
           CASE WHEN u.public_profile OR u.id::text={v} THEN u.avatar_path ELSE NULL END AS user_avatar_path, \
           u.profile_color, u.public_profile, \
           (SELECT COUNT(DISTINCT lk.user_id) FROM media_likes lk WHERE lk.media_id = m.id) AS like_count, \
           (SELECT COUNT(*) FROM media_comments cmc WHERE cmc.media_id = m.id) AS comment_count, \
           CASE WHEN EXISTS (SELECT 1 FROM media_bookmarks b WHERE b.media_id = m.id AND b.user_id::text = {v}) THEN 1 ELSE 0 END AS bookmarked_by_me, \
           CASE WHEN EXISTS (SELECT 1 FROM media_likes l2 WHERE l2.media_id = m.id AND l2.user_id::text = {v}) THEN 1 ELSE 0 END AS liked_by_me"
    )
}

/// Owner's-own-media SELECT (my_media / on_this_day): raw uploader names.
pub fn select_cols_own(v: &str) -> String {
    format!(
        "SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.description, m.tags, \
           m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.file_size, m.video_codecs, \
           m.views, m.downloads, m.created_at, m.updated_at, m.visibility, \
           m.comments_enabled, m.downloads_enabled, m.pinned_at, m.is_adult, \
           m.adult_marked_by_user, m.adult_marked_by_ai, m.moderation_status, m.dominant_color, m.source_url, \
           c.name AS category_name, c.slug AS category_slug, \
           sc.name AS subcategory_name, sc.slug AS subcategory_slug, \
           u.username, u.display_name, u.profile_color, u.public_profile, \
           (SELECT COUNT(DISTINCT lk.user_id) FROM media_likes lk WHERE lk.media_id = m.id) AS like_count, \
           (SELECT COUNT(*) FROM media_comments cmc WHERE cmc.media_id = m.id) AS comment_count, \
           CASE WHEN EXISTS (SELECT 1 FROM media_bookmarks b WHERE b.media_id = m.id AND b.user_id::text = {v}) THEN 1 ELSE 0 END AS bookmarked_by_me, \
           CASE WHEN EXISTS (SELECT 1 FROM media_likes l2 WHERE l2.media_id = m.id AND l2.user_id::text = {v}) THEN 1 ELSE 0 END AS liked_by_me"
    )
}

pub const FROM_JOINS: &str = "FROM media_items m JOIN categories c ON c.id = m.category_id LEFT JOIN subcategories sc ON sc.id = m.subcategory_id JOIN users u ON u.id = m.user_id";

pub fn thumb_url_for(origin: &str, id: i64, kind: &str, updated_at: &Value) -> Option<String> {
    if kind != "image" && kind != "video" {
        return None;
    }
    let mut url = append_query(&format!("{origin}/api/media/{id}/thumb"), "w", "640");
    if let Some(u) = updated_at.as_str() {
        url = append_query(&url, "v", &digits(u));
    }
    Some(url)
}

fn is_gif(row: &Value) -> bool {
    let mime = row.s("mime_type").unwrap_or_default().to_lowercase();
    let name = row.s("original_filename").or(row.s("storage_path")).unwrap_or_default().to_lowercase();
    mime == "image/gif" || name.ends_with(".gif")
}

/// url / thumb_url / preview_url / download_url (with the access token),
/// or nulls for a locked 18+ row.
pub fn with_urls(req: &Req, row: &mut Value, adult_allowed: bool) {
    let origin = req.origin();
    let is_adult = row["is_adult"].as_bool().unwrap_or(false);
    let locked = is_adult && !adult_allowed;
    row["locked"] = json!(locked);
    row["viewer_can_open_adult"] = json!(adult_allowed);
    row["requires_adult_blur"] = json!(is_adult && adult_allowed);
    let o = row.as_object_mut().unwrap();
    if locked {
        for k in ["storage_path", "url", "preview_url", "thumb_url", "download_url"] {
            o.remove(k);
        }
    } else {
        let id = row.i("id").unwrap_or(0);
        let kind = row.s("media_kind").unwrap_or_default();
        let url = format!("{origin}/api/media/{id}/file");
        let download = format!("{origin}/api/media/{id}/download");
        let thumb = thumb_url_for(&origin, id, &kind, &row["updated_at"]).map(|t| t.replacen("/thumb?", "/thumb.webp?", 1));
        let preview = if is_gif(row) {
            Some(url.clone())
        } else if kind == "image" {
            let mut p = format!("{origin}/api/media/{id}/preview.webp");
            if let Some(u) = row["updated_at"].as_str() {
                p = append_query(&p, "v", &digits(u));
            }
            Some(p)
        } else {
            thumb.clone()
        };
        let token = crate::auth::media_access_token(req.app.secret(), id);
        row["url"] = json!(append_query(&url, "access", &token));
        row["download_url"] = json!(append_query(&download, "access", &token));
        match preview {
            Some(p) => row["preview_url"] = json!(append_query(&p, "access", &token)),
            None => {
                row.as_object_mut().unwrap().remove("preview_url");
            }
        }
        match thumb {
            Some(t) => row["thumb_url"] = json!(append_query(&t, "access", &token)),
            None => {
                row.as_object_mut().unwrap().remove("thumb_url");
            }
        }
    }
    if row.get("user_avatar_path").is_some_and(|v| !v.is_null()) {
        let uid = row.i("user_id").or(row.i("id")).unwrap_or(0);
        row["user_avatar_url"] = json!(format!("{origin}/api/users/{uid}/avatar"));
    }
}

/// MP4 with 8-bit H.264 and AAC/MP3 (or no) audio plays straight from the file.
pub fn direct_playable(row: &Value) -> bool {
    if row.s("media_kind").as_deref() != Some("video") {
        return false;
    }
    let mime = row.s("mime_type").unwrap_or_default().to_lowercase();
    if mime != "video/mp4" && mime != "video/x-m4v" {
        return false;
    }
    let Some(codecs) = row.s("video_codecs") else { return false };
    let (video, audio) = codecs.split_once('+').unwrap_or((&codecs, ""));
    (video == "h264/yuv420p" || video == "h264/yuvj420p") && matches!(audio, "" | "aac" | "mp3")
}

pub fn decode_media_row(req: &Req, row: &mut Value, adult_allowed: bool) {
    let o = row.as_object_mut().unwrap();
    // Like the Lua build: only reported when the column is non-NULL.
    if o.remove("custom_thumb_path").is_some() {
        o.insert("has_custom_thumbnail".into(), json!(true));
    }
    if o.contains_key("video_codecs") {
        let dp = direct_playable(row);
        let o = row.as_object_mut().unwrap();
        o.remove("video_codecs");
        o.insert("direct_play".into(), json!(dp));
    }
    bools(row, &["is_adult", "adult_marked_by_user", "adult_marked_by_ai", "comments_enabled", "downloads_enabled", "public_profile", "liked_by_me", "bookmarked_by_me"]);
    for k in ["is_adult", "adult_marked_by_user", "adult_marked_by_ai", "comments_enabled", "downloads_enabled", "public_profile", "liked_by_me", "bookmarked_by_me"] {
        if row.get(k).is_none() {
            row[k] = json!(false);
        }
    }
    row["tags"] = json_list(row.get("tags"));
    with_urls(req, row, adult_allowed);
}

/// subcategories / subcategory_ids / subcategory_names for each row; the
/// first one also fills the single subcategory_* fields.
pub async fn attach_subcategories(req: &Req, rows: &mut [Value]) {
    if rows.is_empty() {
        return;
    }
    let ids: Vec<i64> = rows.iter().filter_map(|r| r.i("id")).collect();
    let mut q = Sql::new();
    let list = ids.iter().map(|i| q.bind(*i)).collect::<Vec<_>>().join(",");
    let sql = format!(
        "SELECT ms.media_id, ms.position, s.id, s.category_id, s.name, s.slug FROM media_item_subcategories ms JOIN subcategories s ON s.id = ms.subcategory_id \
         WHERE ms.media_id IN ({list}) ORDER BY ms.media_id ASC, ms.position ASC"
    );
    let subs = req.app.db.all(&sql, &q.params).await;
    let mut grouped: HashMap<i64, Vec<Value>> = HashMap::new();
    for s in subs {
        grouped.entry(s.i("media_id").unwrap_or(0)).or_default().push(json!({ "id": s["id"], "category_id": s["category_id"], "name": s["name"], "slug": s["slug"] }));
    }
    for row in rows.iter_mut() {
        let subs = grouped.remove(&row.i("id").unwrap_or(0)).unwrap_or_default();
        row["subcategory_ids"] = json!(subs.iter().map(|s| s["id"].clone()).collect::<Vec<_>>());
        row["subcategory_names"] = json!(subs.iter().map(|s| s["name"].clone()).collect::<Vec<_>>());
        if let Some(first) = subs.first() {
            row["subcategory_id"] = first["id"].clone();
            row["subcategory_name"] = first["name"].clone();
            row["subcategory_slug"] = first["slug"].clone();
        }
        row["subcategories"] = json!(subs);
    }
}

/// attach_subcategories + decode_media_row over a page of rows.
pub async fn finish_rows(req: &Req, rows: &mut Vec<Value>, adult_allowed: bool) {
    attach_subcategories(req, rows).await;
    for r in rows.iter_mut() {
        decode_media_row(req, r, adult_allowed);
    }
}

pub fn bounded_limit(v: Option<i64>, default: i64, max: i64) -> i64 {
    v.unwrap_or(default).clamp(1, max)
}

pub fn bounded_offset(v: Option<i64>) -> i64 {
    v.unwrap_or(0).max(0)
}

/// Viewer as (int id, "0"-defaulted text) for the visibility clauses.
pub fn viewer_keys(v: Option<i64>) -> (i64, String) {
    let id = v.unwrap_or(0);
    (id, id.to_string())
}

/// fetch_media_feed: visibility + block + adult rules, an optional extra
/// clause, then `order` and paging.
pub async fn fetch_feed(req: &Req, viewer: Option<i64>, extra: impl FnOnce(&mut Sql) -> Option<String>, order: &str, limit: i64, offset: i64) -> Result<Vec<Value>, String> {
    let adult_ok = req.app.viewer_adult_allowed(viewer).await;
    let (vid, vtext) = viewer_keys(viewer);
    let mut q = Sql::new();
    let vt = q.bind(vtext);
    let vi = q.bind(vid);
    let mut clauses = vec!["m.deleted_at IS NULL".to_string(), format!("(m.visibility='public' OR m.user_id={vi})"), format!("(m.publish_at IS NULL OR m.publish_at <= now() OR m.user_id={vi})")];
    if viewer.is_some() {
        clauses.push(format!("m.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id={vi})"));
    }
    if !adult_ok {
        clauses.push("m.is_adult=false".into());
    }
    if let Some(c) = extra(&mut q) {
        clauses.push(c);
    }
    let (l, o) = (q.bind(limit), q.bind(offset));
    let sql = format!("{} {FROM_JOINS} WHERE {} ORDER BY {order} LIMIT {l} OFFSET {o}", select_cols(&vt), clauses.join(" AND "));
    let mut rows = req.app.db.query(&sql, &q.params).await?;
    finish_rows(req, &mut rows, adult_ok).await;
    Ok(rows)
}

/// fetch_media_by_id: one row with the detail-only columns, any state.
pub async fn fetch_by_id(req: &Req, media_id: i64, viewer: Option<i64>) -> Option<Value> {
    let (_, vtext) = viewer_keys(viewer);
    let mut q = Sql::new();
    let vt = q.bind(vtext);
    let id = q.bind(media_id);
    let sql = format!(
        "{}, m.youtube_video_id, m.custom_thumb_path, m.deleted_at, m.publish_at {FROM_JOINS} WHERE m.id = {id}",
        select_cols(&vt)
    );
    let mut row = req.app.db.opt(&sql, &q.params).await?;
    attach_subcategories(req, std::slice::from_mut(&mut row)).await;
    Some(row)
}

pub fn query_failed(e: String) -> Reply {
    Reply::err(500, format!("Query failed: {e}"))
}

pub fn ok_media(rows: Vec<Value>) -> R<Reply> {
    Ok(Reply::ok(json!({ "media": rows })))
}


// ---- categories / subcategories (find-or-create, up to 20 per post) -------------------------------
pub const MAX_SUBCATEGORIES: usize = 20;

pub async fn find_or_create_category(db: &crate::db::Db, name: &str, kind: &str, user_id: i64) -> Option<i64> {
    let name = crate::util::cut(name.trim(), 80);
    if name.is_empty() {
        return None;
    }
    let slug = crate::util::slugify(&name);
    if let Some(r) = db.opt("SELECT id FROM categories WHERE name=$1 OR slug=$2", &[name.as_str().into(), slug.as_str().into()]).await {
        return r.i("id");
    }
    let kind = if ["image", "video", "mixed"].contains(&kind) { kind } else { "mixed" };
    db.opt("INSERT INTO categories (name, slug, media_kind, created_by) VALUES ($1, $2, $3, $4) RETURNING id", &[name.into(), slug.into(), kind.into(), user_id.into()]).await.and_then(|r| r.i("id"))
}

async fn find_or_create_subcategory(db: &crate::db::Db, category_id: i64, name: &str, user_id: i64) -> Option<i64> {
    let name = crate::util::cut(name.trim(), 80);
    if name.is_empty() {
        return None;
    }
    let slug = crate::util::slugify(&name);
    if let Some(r) = db.opt("SELECT id FROM subcategories WHERE category_id=$1 AND (name=$2 OR slug=$3)", &[category_id.into(), name.as_str().into(), slug.as_str().into()]).await {
        return r.i("id");
    }
    db.opt("INSERT INTO subcategories (category_id, name, slug, created_by) VALUES ($1, $2, $3, $4) RETURNING id", &[category_id.into(), name.into(), slug.into(), user_id.into()])
        .await
        .and_then(|r| r.i("id"))
}

pub fn normalize_subcategory_ids(v: Option<&Value>) -> Vec<i64> {
    let mut out = Vec::new();
    for raw in v.and_then(Value::as_array).into_iter().flatten() {
        if let Some(id) = crate::util::vnum(Some(raw)).filter(|n| *n > 0.0).map(|n| n.floor() as i64) {
            if !out.contains(&id) {
                out.push(id);
                if out.len() >= MAX_SUBCATEGORIES {
                    break;
                }
            }
        }
    }
    out
}

pub fn normalize_subcategory_names(v: Option<&Value>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for raw in v.and_then(Value::as_array).into_iter().flatten() {
        let cleaned = crate::util::cut(&crate::util::vstr(Some(raw)).unwrap_or_default().split_whitespace().collect::<Vec<_>>().join(" "), 80);
        if !cleaned.is_empty() && !out.iter().any(|n| n.to_lowercase() == cleaned.to_lowercase()) {
            out.push(cleaned);
            if out.len() >= MAX_SUBCATEGORIES {
                break;
            }
        }
    }
    out
}

/// Validate existing subcategory ids against the category and create any named ones.
pub async fn resolve_subcategory_ids(db: &crate::db::Db, category_id: i64, ids: Vec<i64>, names: Vec<String>, user_id: i64) -> Result<Vec<i64>, String> {
    if category_id <= 0 {
        return Err("Choose a valid category.".into());
    }
    if db.opt("SELECT id FROM categories WHERE id=$1", &[category_id.into()]).await.is_none() {
        return Err("Category does not exist.".into());
    }
    let mut out = Vec::new();
    for id in ids {
        if db.opt("SELECT id FROM subcategories WHERE id=$1 AND category_id=$2", &[id.into(), category_id.into()]).await.is_none() {
            return Err("Subcategory does not belong to that category.".into());
        }
        out.push(id);
    }
    for n in names {
        if out.len() >= MAX_SUBCATEGORIES {
            break;
        }
        if let Some(id) = find_or_create_subcategory(db, category_id, &n, user_id).await {
            if !out.contains(&id) {
                out.push(id);
            }
        }
    }
    out.truncate(MAX_SUBCATEGORIES);
    Ok(out)
}

pub async fn write_subcategories(db: &crate::db::Db, media_id: i64, ids: &[i64]) {
    let _ = db.exec("UPDATE media_items SET subcategory_id=$1 WHERE id=$2", &[ids.first().copied().into(), media_id.into()]).await;
    let _ = db.exec("DELETE FROM media_item_subcategories WHERE media_id=$1", &[media_id.into()]).await;
    for (i, id) in ids.iter().enumerate() {
        let _ = db.exec("INSERT INTO media_item_subcategories (media_id, subcategory_id, position) VALUES ($1, $2, $3)", &[media_id.into(), (*id).into(), ((i + 1) as i64).into()]).await;
    }
}

/// Upload/bulk tag normalization: strip leading #, spaces to dashes, safe chars only.
pub fn normalize_upload_tag(v: &str, max_len: i64) -> String {
    let t = v.trim().trim_start_matches('#');
    let t: String = t.split_whitespace().collect::<Vec<_>>().join("-");
    let t: String = t.chars().filter(|c| c.is_ascii_alphanumeric() || "_.-".contains(*c)).collect();
    crate::util::cut(&t, max_len.max(1) as usize)
}

/// "a, b #c" -> deduped, normalized tags (max `max` of them).
pub fn parse_tags(v: &str, max_len: i64, max: i64) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for raw in v.split([',', '#', '\n', '\r', '\t']).filter(|s| !s.is_empty()) {
        let t = normalize_upload_tag(raw, max_len);
        if !t.is_empty() && !out.iter().any(|x| x.to_lowercase() == t.to_lowercase()) {
            out.push(t);
            if out.len() as i64 >= max {
                break;
            }
        }
    }
    out
}

/// _ensure_media_visible_to_viewer.
pub async fn ensure_visible(req: &Req, item: Option<&Value>, viewer: Option<i64>) -> R<()> {
    let Some(item) = item.filter(|i| i["deleted_at"].is_null()) else { return Err(Reply::err(404, "Media not found.")) };
    let owner = viewer.is_some() && item.i("user_id") == viewer;
    if item.s("visibility").as_deref() == Some("private") && !owner {
        return Err(Reply::err(403, "This post is private."));
    }
    if let (Some(p), false) = (item.s("publish_at"), owner) {
        let fut = req.app.db.opt("SELECT ($1::timestamp > now()) AS is_future", &[p.into()]).await;
        if fut.is_some_and(|r| crate::util::tobool(r.get("is_future"))) {
            return Err(Reply::err(404, "Media not found."));
        }
    }
    Ok(())
}
