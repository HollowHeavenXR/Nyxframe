//! Single-post endpoints: detail, watch progress, random, similar, live
//! viewer count, personal tags, memories, likes, bookmarks, comments,
//! reactions, edits/controls/history, delete/restore, reports, bulk edits.

use crate::app::{is_site_owner, uid};
use crate::db::{J, P, Sql};
use crate::http::{R, Reply, Req};
use crate::media::{self, decode_media_row, ensure_visible, fetch_by_id, query_failed, with_urls};
use crate::routes::notify;
use crate::util::{bools, cut, json_list, tobool, truthy, vnum, vstr};
use serde_json::{Map, Value, json};
use std::collections::HashMap;

fn mid(req: &Req) -> R<i64> {
    req.pi("media_id").ok_or_else(|| Reply::err(404, "Media not found."))
}

/// Re-fetch and shape one post for the response.
async fn media_reply(req: &Req, id: i64, viewer: i64) -> R<Reply> {
    let adult = req.app.viewer_adult_allowed(Some(viewer)).await;
    let mut item = fetch_by_id(req, id, Some(viewer)).await.ok_or_else(|| Reply::err(404, "Media not found."))?;
    decode_media_row(req, &mut item, adult);
    Ok(Reply::ok(json!({ "media": item })))
}

// ---- watch progress ----------------------------------------------------------------------------
pub async fn save_watch_progress(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = mid(&req)?;
    let Some(pos) = vnum(req.json.get("position_seconds")).filter(|p| *p >= 0.0) else { return Err(Reply::err(400, "position_seconds is required.")) };
    let dur = vnum(req.json.get("duration_seconds"));
    let db = &req.app.db;
    if pos < 5.0 || dur.is_some_and(|d| d > 0.0 && pos / d >= 0.95) {
        let _ = db.exec("DELETE FROM media_watch_progress WHERE user_id=$1 AND media_id=$2", &[uid(&user).into(), id.into()]).await;
        return Ok(Reply::ok(json!({ "saved": false, "cleared": true })));
    }
    let _ = db
        .exec(
            "INSERT INTO media_watch_progress (user_id, media_id, position_seconds, duration_seconds, updated_at) VALUES ($1, $2, $3, $4, now()) \
             ON CONFLICT (user_id, media_id) DO UPDATE SET position_seconds=EXCLUDED.position_seconds, duration_seconds=EXCLUDED.duration_seconds, updated_at=now()",
            &[uid(&user).into(), id.into(), pos.into(), dur.into()],
        )
        .await;
    Ok(Reply::ok(json!({ "saved": true })))
}

pub async fn watch_progress(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = mid(&req)?;
    let Some(r) = req.app.db.opt("SELECT position_seconds, duration_seconds, updated_at FROM media_watch_progress WHERE user_id=$1 AND media_id=$2", &[uid(&user).into(), id.into()]).await else {
        return Ok(Reply::ok(json!({ "position_seconds": null, "duration_seconds": null })));
    };
    Ok(Reply::ok(json!({ "position_seconds": r.f("position_seconds"), "duration_seconds": r.f("duration_seconds"), "updated_at": r["updated_at"] })))
}

pub async fn continue_watching(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = uid(&user);
    let limit = req.qi("limit").unwrap_or(12).clamp(1, 30);
    let adult = req.app.viewer_adult_allowed(Some(id)).await;
    let rows = req
        .app
        .db
        .all(
            "SELECT wp.media_id, wp.position_seconds, wp.duration_seconds, wp.updated_at FROM media_watch_progress wp JOIN media_items m ON m.id = wp.media_id AND m.deleted_at IS NULL \
             WHERE wp.user_id=$1 ORDER BY wp.updated_at DESC LIMIT $2",
            &[id.into(), limit.into()],
        )
        .await;
    let mut out = Vec::new();
    for p in rows {
        if let Some(mut item) = fetch_by_id(&req, p.i("media_id").unwrap_or(0), Some(id)).await {
            decode_media_row(&req, &mut item, adult);
            item["watch_position_seconds"] = json!(p.f("position_seconds"));
            item["watch_duration_seconds"] = json!(p.f("duration_seconds"));
            item["watch_updated_at"] = p["updated_at"].clone();
            out.push(item);
        }
    }
    Ok(Reply::ok(json!({ "media": out, "limit": limit })))
}

pub async fn media_random(req: Req) -> R<Reply> {
    let viewer = req.viewer().await;
    let adult = req.app.viewer_adult_allowed(viewer).await;
    let mut c = vec!["m.deleted_at IS NULL", "m.visibility='public'", "(m.publish_at IS NULL OR m.publish_at <= now())"];
    let mut params: Vec<P> = vec![];
    if let Some(v) = viewer {
        c.push("m.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id=$1)");
        params.push(v.into());
    }
    if !adult {
        c.push("m.is_adult=false");
    }
    let sql = format!("SELECT m.id FROM media_items m WHERE {} ORDER BY random() LIMIT 1", c.join(" AND "));
    let row = req.app.db.one(&sql, &params).await.map_err(query_failed)?.ok_or_else(|| Reply::err(404, "No media available."))?;
    let mut item = fetch_by_id(&req, row.i("id").unwrap_or(0), viewer).await.ok_or_else(|| Reply::err(404, "Media not found."))?;
    decode_media_row(&req, &mut item, adult);
    Ok(Reply::ok(json!({ "media": item })))
}

/// Related posts: tag overlap + same category, else newest in the category.
async fn compute_similar(req: &Req, id: i64, item: &Value, adult: bool, limit: i64, offset: i64) -> Vec<Value> {
    let tags: Vec<String> = json_list(item.get("tags")).as_array().map(|a| a.iter().filter_map(|t| vstr(Some(t))).collect()).unwrap_or_default();
    let cat = item.i("category_id").unwrap_or(0);
    let adult_clause = if adult { "" } else { "AND m.is_adult=false" };
    let cols = "SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.is_adult, m.created_at, m.views FROM media_items m";
    let mut q = Sql::new();
    let sql = if !tags.is_empty() {
        let (i, c) = (q.bind(id), q.bind(cat));
        let arr = tags.iter().map(|t| q.bind(t.as_str())).collect::<Vec<_>>().join(",");
        let (l, o) = (q.bind(limit), q.bind(offset));
        format!(
            "{cols} WHERE m.id != {i} AND m.deleted_at IS NULL AND m.visibility='public' AND (m.publish_at IS NULL OR m.publish_at <= now()) \
             AND (m.category_id = {c} OR (m.tags::jsonb ?| ARRAY[{arr}]::text[])) {adult_clause} \
             ORDER BY (CASE WHEN m.category_id = {c} THEN 1 ELSE 0 END) + (SELECT count(*) FROM jsonb_array_elements_text(m.tags::jsonb) t WHERE t = ANY(ARRAY[{arr}]::text[])) DESC, m.created_at DESC \
             LIMIT {l} OFFSET {o}"
        )
    } else {
        let (c, i, l, o) = (q.bind(cat), q.bind(id), q.bind(limit), q.bind(offset));
        format!(
            "{cols} WHERE m.category_id = {c} AND m.id != {i} AND m.deleted_at IS NULL AND m.visibility='public' AND (m.publish_at IS NULL OR m.publish_at <= now()) {adult_clause} \
             ORDER BY m.created_at DESC LIMIT {l} OFFSET {o}"
        )
    };
    let mut rows = req.app.db.all(&sql, &q.params).await;
    for r in &mut rows {
        bools(r, &["is_adult"]);
        if r.get("is_adult").is_none() {
            r["is_adult"] = json!(false);
        }
        with_urls(req, r, adult);
    }
    media::attach_subcategories(req, &mut rows).await;
    rows
}

async fn reaction_summary(req: &Req, table: &str, key: &str, id: i64, viewer: Option<i64>) -> Value {
    let rows = req.app.db.all(&format!("SELECT emoji, COUNT(*) AS n FROM {table} WHERE {key}=$1 GROUP BY emoji ORDER BY n DESC"), &[id.into()]).await;
    let counts: Map<String, Value> = rows.iter().map(|r| (r.s("emoji").unwrap_or_default(), json!(r.i("n").unwrap_or(0)))).collect();
    let mut out = json!({ "counts": counts });
    if let Some(v) = viewer {
        if let Some(e) = req.app.db.opt(&format!("SELECT emoji FROM {table} WHERE {key}=$1 AND user_id=$2"), &[id.into(), v.into()]).await.and_then(|r| r.s("emoji")) {
            out["my_reaction"] = json!(e);
        }
    }
    out
}

async fn personal_tags(req: &Req, media_id: i64, user: i64) -> Vec<Value> {
    req.app.db.all("SELECT tag FROM media_personal_tags WHERE media_id=$1 AND user_id=$2 ORDER BY tag", &[media_id.into(), user.into()]).await.into_iter().map(|r| r["tag"].clone()).collect()
}

pub async fn media_detail(req: Req) -> R<Reply> {
    let id = mid(&req)?;
    let viewer = req.viewer().await;
    let adult = req.app.viewer_adult_allowed(viewer).await;
    let item = fetch_by_id(&req, id, viewer).await;
    ensure_visible(&req, item.as_ref(), viewer).await?;
    let mut item = item.unwrap();
    if tobool(item.get("is_adult")) && !adult {
        return Err(Reply::err(403, "Age verification required for this 18+ post."));
    }
    let db = &req.app.db;
    let key = match viewer {
        Some(v) => format!("user:{v}"),
        None => format!("ip:{}", req.client_ip),
    };
    if db.opt("INSERT INTO media_views (media_id, viewer_key) VALUES ($1, $2) ON CONFLICT (media_id, viewer_key) DO NOTHING RETURNING media_id", &[id.into(), key.into()]).await.is_some() {
        let _ = db.exec("UPDATE media_items SET views=views+1 WHERE id=$1", &[id.into()]).await;
    }
    let mut comments = db
        .all(
            "SELECT cm.id, cm.media_id, cm.user_id, cm.body, cm.created_at, cm.parent_comment_id, u.username, \
               CASE WHEN u.public_profile THEN u.display_name ELSE u.username END AS display_name, \
               CASE WHEN u.public_profile THEN u.avatar_path ELSE NULL END AS user_avatar_path \
             FROM media_comments cm JOIN users u ON u.id = cm.user_id WHERE cm.media_id = $1 ORDER BY cm.created_at ASC LIMIT 80",
            &[id.into()],
        )
        .await;
    if !comments.is_empty() {
        let ids: Vec<i64> = comments.iter().filter_map(|c| c.i("id")).collect();
        let list = ids.iter().map(i64::to_string).collect::<Vec<_>>().join(",");
        let mut counts: HashMap<i64, Map<String, Value>> = HashMap::new();
        for r in db.all(&format!("SELECT comment_id, emoji, COUNT(*) AS n FROM media_comment_reactions WHERE comment_id IN ({list}) GROUP BY comment_id, emoji"), &[]).await {
            counts.entry(r.i("comment_id").unwrap_or(0)).or_default().insert(r.s("emoji").unwrap_or_default(), json!(r.i("n").unwrap_or(0)));
        }
        let mut mine: HashMap<i64, String> = HashMap::new();
        if let Some(v) = viewer {
            for r in db.all(&format!("SELECT comment_id, emoji FROM media_comment_reactions WHERE user_id=$1 AND comment_id IN ({list})"), &[v.into()]).await {
                mine.insert(r.i("comment_id").unwrap_or(0), r.s("emoji").unwrap_or_default());
            }
        }
        for c in &mut comments {
            let cid = c.i("id").unwrap_or(0);
            let mut rx = json!({ "counts": counts.remove(&cid).unwrap_or_default() });
            if let Some(e) = mine.remove(&cid) {
                rx["my_reaction"] = json!(e);
            }
            c["reactions"] = rx;
        }
    }
    let reactions = reaction_summary(&req, "media_reactions", "media_id", id, viewer).await;
    let similar = compute_similar(&req, id, &item, adult, 12, 0).await;
    let ptags = match viewer {
        Some(v) => personal_tags(&req, id, v).await,
        None => vec![],
    };
    decode_media_row(&req, &mut item, adult);
    Ok(Reply::ok(json!({ "media": item, "comments": comments, "reactions": reactions, "similar": similar, "personal_tags": ptags })))
}

pub async fn viewing_heartbeat(req: Req) -> R<Reply> {
    let id = mid(&req)?;
    let viewer = req.viewer().await;
    let item = fetch_by_id(&req, id, viewer).await;
    ensure_visible(&req, item.as_ref(), viewer).await?;
    if tobool(item.as_ref().and_then(|i| i.get("is_adult"))) && !req.app.viewer_adult_allowed(viewer).await {
        return Err(Reply::err(403, "Age verification required for this 18+ post."));
    }
    let key = match viewer {
        Some(v) => format!("user:{v}"),
        None => format!("ip:{}", req.client_ip),
    };
    let db = &req.app.db;
    let _ = db
        .exec("INSERT INTO media_active_viewers (media_id, viewer_key, last_seen_at) VALUES ($1, $2, now()) ON CONFLICT (media_id, viewer_key) DO UPDATE SET last_seen_at=now()", &[id.into(), key.into()])
        .await;
    let n = db.opt("SELECT COUNT(*) AS n FROM media_active_viewers WHERE media_id=$1 AND last_seen_at > now() - interval '25 seconds'", &[id.into()]).await.and_then(|r| r.i("n")).unwrap_or(0);
    Ok(Reply::ok(json!({ "viewing_now": n })))
}

// ---- personal tags ---------------------------------------------------------------------------------
fn clean_personal_tag(raw: &str) -> String {
    cut(&raw.trim().to_lowercase().split_whitespace().collect::<Vec<_>>().join(" "), 60)
}

pub async fn add_personal_tag(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let (id, u) = (mid(&req)?, uid(&user));
    let item = fetch_by_id(&req, id, Some(u)).await;
    ensure_visible(&req, item.as_ref(), Some(u)).await?;
    let tag = clean_personal_tag(&req.js("tag").unwrap_or_default());
    if tag.is_empty() {
        return Err(Reply::err(400, "Tag is required."));
    }
    let _ = req.app.db.exec("INSERT INTO media_personal_tags (media_id, user_id, tag) VALUES ($1, $2, $3) ON CONFLICT (media_id, user_id, tag) DO NOTHING", &[id.into(), u.into(), tag.into()]).await;
    Ok(Reply::ok(json!({ "personal_tags": personal_tags(&req, id, u).await })))
}

pub async fn remove_personal_tag(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let (id, u) = (mid(&req)?, uid(&user));
    let tag = clean_personal_tag(&crate::http::url_decode(&req.p("tag")));
    let _ = req.app.db.exec("DELETE FROM media_personal_tags WHERE media_id=$1 AND user_id=$2 AND tag=$3", &[id.into(), u.into(), tag.into()]).await;
    Ok(Reply::ok(json!({ "personal_tags": personal_tags(&req, id, u).await })))
}

const LITE_COLS: &str = "m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.is_adult, m.created_at, m.views, m.visibility";

fn lite_rows(req: &Req, rows: &mut [Value], adult: bool) {
    for r in rows {
        bools(r, &["is_adult"]);
        if r.get("is_adult").is_none() {
            r["is_adult"] = json!(false);
        }
        with_urls(req, r, adult);
    }
}

pub async fn my_personal_tags(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    if let Some(tag) = req.q("tag") {
        let sql = format!("SELECT {LITE_COLS} FROM media_personal_tags pt JOIN media_items m ON m.id = pt.media_id WHERE pt.user_id=$1 AND pt.tag=$2 AND m.deleted_at IS NULL ORDER BY pt.created_at DESC LIMIT 200");
        let mut rows = req.app.db.all(&sql, &[u.into(), clean_personal_tag(&tag).into()]).await;
        let adult = req.app.viewer_adult_allowed(Some(u)).await;
        lite_rows(&req, &mut rows, adult);
        return media::ok_media(rows);
    }
    let tags = req.app.db.all("SELECT tag, COUNT(*) AS n FROM media_personal_tags WHERE user_id=$1 GROUP BY tag ORDER BY n DESC, tag ASC", &[u.into()]).await;
    Ok(Reply::ok(json!({ "tags": tags })))
}

pub async fn my_memories(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    let sql = format!(
        "SELECT {LITE_COLS}, EXTRACT(YEAR FROM now())::int - EXTRACT(YEAR FROM m.created_at)::int AS years_ago FROM media_items m WHERE m.user_id=$1 AND m.deleted_at IS NULL \
         AND EXTRACT(MONTH FROM m.created_at) = EXTRACT(MONTH FROM now()) AND EXTRACT(DAY FROM m.created_at) = EXTRACT(DAY FROM now()) AND EXTRACT(YEAR FROM m.created_at) < EXTRACT(YEAR FROM now()) \
         ORDER BY m.created_at ASC LIMIT 50"
    );
    let mut rows = req.app.db.all(&sql, &[u.into()]).await;
    let adult = req.app.viewer_adult_allowed(Some(u)).await;
    lite_rows(&req, &mut rows, adult);
    media::ok_media(rows)
}

// ---- likes / bookmarks ---------------------------------------------------------------------------
async fn toggle(req: Req, flag: &str, table: &str) -> R<Reply> {
    let user = req.current_user().await?;
    let (id, u) = (mid(&req)?, uid(&user));
    let on = truthy(req.json.get(flag));
    let item = fetch_by_id(&req, id, Some(u)).await;
    ensure_visible(&req, item.as_ref(), Some(u)).await?;
    let sql = if on { format!("INSERT INTO {table} (user_id, media_id) VALUES ($1, $2) ON CONFLICT DO NOTHING") } else { format!("DELETE FROM {table} WHERE user_id=$1 AND media_id=$2") };
    let _ = req.app.db.exec(&sql, &[u.into(), id.into()]).await;
    media_reply(&req, id, u).await
}

pub async fn like_media(req: Req) -> R<Reply> {
    toggle(req, "liked", "media_likes").await
}

pub async fn bookmark_media(req: Req) -> R<Reply> {
    toggle(req, "bookmarked", "media_bookmarks").await
}

// ---- comments / reactions -----------------------------------------------------------------------
fn mentions(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let padded = format!(" {text}");
    let b = padded.as_bytes();
    let ok = |c: u8| c.is_ascii_alphanumeric() || c == b'_' || c == b'.' || c == b'-';
    let mut i = 1;
    while i < b.len() {
        let prev = b[i - 1];
        if b[i] == b'@' && !(prev.is_ascii_alphanumeric() || prev == b'_') {
            let start = i + 1;
            let mut j = start;
            while j < b.len() && ok(b[j]) {
                j += 1;
            }
            if j > start {
                let name = padded[start..j].to_string();
                let low = name.to_lowercase();
                if (3..=40).contains(&name.len()) && !out.contains(&low) {
                    out.push(low);
                    if out.len() >= 10 {
                        break;
                    }
                }
            }
            i = j.max(i + 1);
        } else {
            i += 1;
        }
    }
    out
}

pub async fn add_comment(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    req.app.rate_check(&format!("comment:{u}"), 30, 3600).await?;
    let id = mid(&req)?;
    let text = req.js("body").unwrap_or_default().trim().to_string();
    if text.is_empty() {
        return Err(Reply::err(400, "Comment cannot be empty."));
    }
    let text = cut(&text, 500);
    let parent = req.js("parent_comment_id");
    let item = fetch_by_id(&req, id, Some(u)).await;
    ensure_visible(&req, item.as_ref(), Some(u)).await?;
    let item = item.unwrap();
    if !tobool(item.get("comments_enabled")) {
        return Err(Reply::err(403, "Comments are disabled for this post."));
    }
    let row = req
        .app
        .db
        .one("INSERT INTO media_comments (media_id, user_id, body, parent_comment_id) VALUES ($1, $2, $3, $4) RETURNING *", &[id.into(), u.into(), text.as_str().into(), parent.clone().into()])
        .await
        .map_err(|e| Reply::err(500, format!("Could not add comment: {e}")))?;
    let owner = item.i("user_id").unwrap_or(0);
    notify::create(&req.app, owner, Some(u), if parent.is_some() { "reply" } else { "comment" }, Some(id), Some(&text)).await;
    let names = mentions(&text);
    if !names.is_empty() {
        let mut q = Sql::new();
        let list = names.iter().map(|n| q.bind(n.as_str())).collect::<Vec<_>>().join(", ");
        let mut done = vec![];
        for r in req.app.db.all(&format!("SELECT id, username FROM users WHERE LOWER(username) IN ({list})"), &q.params).await {
            let m = r.i("id").unwrap_or(0);
            if m != u && m != owner && !done.contains(&m) {
                done.push(m);
                if !notify::is_blocked_either_way(&req.app, u, m).await {
                    notify::create(&req.app, m, Some(u), "mention", Some(id), Some(&text)).await;
                }
            }
        }
    }
    Ok(Reply::ok(json!({ "comment": row })))
}

fn emoji_of(req: &Req) -> R<String> {
    let e = cut(req.js("emoji").unwrap_or_default().trim(), 16);
    if e.is_empty() { Err(Reply::err(400, "An emoji is required.")) } else { Ok(e) }
}

pub async fn react_to_media(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let (id, u) = (mid(&req)?, uid(&user));
    let emoji = emoji_of(&req)?;
    let item = fetch_by_id(&req, id, Some(u)).await;
    ensure_visible(&req, item.as_ref(), Some(u)).await?;
    let db = &req.app.db;
    let existing = db.opt("SELECT emoji FROM media_reactions WHERE media_id=$1 AND user_id=$2", &[id.into(), u.into()]).await.and_then(|r| r.s("emoji"));
    if existing.as_deref() == Some(emoji.as_str()) {
        let _ = db.exec("DELETE FROM media_reactions WHERE media_id=$1 AND user_id=$2", &[id.into(), u.into()]).await;
    } else {
        let _ = db
            .exec("INSERT INTO media_reactions (media_id, user_id, emoji) VALUES ($1, $2, $3) ON CONFLICT (media_id, user_id) DO UPDATE SET emoji=EXCLUDED.emoji, created_at=now()", &[id.into(), u.into(), emoji.into()])
            .await;
    }
    let summary = reaction_summary(&req, "media_reactions", "media_id", id, Some(u)).await;
    let owner = item.as_ref().and_then(|i| i.i("user_id")).unwrap_or(0);
    if let (true, Some(mine)) = (owner != u, summary.get("my_reaction").and_then(Value::as_str)) {
        notify::create(&req.app, owner, Some(u), "reaction", Some(id), Some(mine)).await;
    }
    Ok(Reply::ok(json!({ "reactions": summary })))
}

pub async fn react_to_comment(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    let Some(cid) = req.pi("comment_id") else { return Err(Reply::err(404, "Comment not found.")) };
    let emoji = emoji_of(&req)?;
    let db = &req.app.db;
    let comment = db.opt("SELECT id, media_id, user_id FROM media_comments WHERE id=$1", &[cid.into()]).await.ok_or_else(|| Reply::err(404, "Comment not found."))?;
    let media_id = comment.i("media_id").unwrap_or(0);
    let item = fetch_by_id(&req, media_id, Some(u)).await;
    ensure_visible(&req, item.as_ref(), Some(u)).await?;
    let existing = db.opt("SELECT emoji FROM media_comment_reactions WHERE comment_id=$1 AND user_id=$2", &[cid.into(), u.into()]).await.and_then(|r| r.s("emoji"));
    if existing.as_deref() == Some(emoji.as_str()) {
        let _ = db.exec("DELETE FROM media_comment_reactions WHERE comment_id=$1 AND user_id=$2", &[cid.into(), u.into()]).await;
    } else {
        let _ = db
            .exec(
                "INSERT INTO media_comment_reactions (comment_id, user_id, emoji) VALUES ($1, $2, $3) ON CONFLICT (comment_id, user_id) DO UPDATE SET emoji=EXCLUDED.emoji, created_at=now()",
                &[cid.into(), u.into(), emoji.into()],
            )
            .await;
    }
    let summary = reaction_summary(&req, "media_comment_reactions", "comment_id", cid, Some(u)).await;
    let owner = comment.i("user_id").unwrap_or(0);
    if let (true, Some(mine)) = (owner != u, summary.get("my_reaction").and_then(Value::as_str)) {
        notify::create(&req.app, owner, Some(u), "comment_reaction", Some(media_id), Some(mine)).await;
    }
    Ok(Reply::ok(json!({ "comment_id": cid, "reactions": summary })))
}

pub async fn delete_comment(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    let Some(cid) = req.pi("comment_id") else { return Err(Reply::err(404, "Comment not found.")) };
    let row = req
        .app
        .db
        .opt("SELECT cm.id, cm.user_id AS comment_user_id, m.user_id AS media_user_id FROM media_comments cm JOIN media_items m ON m.id=cm.media_id WHERE cm.id=$1", &[cid.into()])
        .await
        .ok_or_else(|| Reply::err(404, "Comment not found."))?;
    if row.i("comment_user_id") != Some(u) && row.i("media_user_id") != Some(u) {
        return Err(Reply::err(403, "Only the commenter or post owner can delete this comment."));
    }
    let _ = req.app.db.exec("DELETE FROM media_comments WHERE id=$1", &[cid.into()]).await;
    Ok(Reply::ok(json!({ "deleted": true })))
}

// ---- edits -----------------------------------------------------------------------------------------
fn schedule_ok(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() >= 16
        && b[..4].iter().all(u8::is_ascii_digit)
        && b[4] == b'-'
        && b[5..7].iter().all(u8::is_ascii_digit)
        && b[7] == b'-'
        && b[8..10].iter().all(u8::is_ascii_digit)
        && (b[10] == b'T' || b[10] == b' ')
        && b[11..13].iter().all(u8::is_ascii_digit)
        && b[13] == b':'
        && b[14..16].iter().all(u8::is_ascii_digit)
}

/// M.normalize_source_url: Ok(None) when absent, Err(message) when unusable.
pub fn normalize_source_url(v: Option<&Value>) -> Result<Option<String>, String> {
    let Some(raw) = vstr(v).map(|s| s.trim().to_string()).filter(|s| !s.is_empty()) else { return Ok(None) };
    if raw.len() > 500 {
        return Err("Source link must be 500 characters or fewer.".into());
    }
    if raw.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err("Source link cannot contain spaces.".into());
    }
    let scheme = raw.split_once(':').map(|(s, _)| s).filter(|s| s.chars().next().is_some_and(|c| c.is_ascii_alphabetic()) && s.chars().all(|c| c.is_ascii_alphanumeric() || "+.-".contains(c)));
    let Some(scheme) = scheme else { return Err("Source link must start with http:// or https://.".into()) };
    if !matches!(scheme.to_lowercase().as_str(), "http" | "https") {
        return Err("Source link must start with http:// or https://.".into());
    }
    let after = raw.strip_prefix("https://").or_else(|| raw.strip_prefix("http://"));
    if after.is_none_or(|a| a.is_empty() || a.starts_with('/')) {
        return Err("Source link must include a domain, like https://example.com/post/1.".into());
    }
    Ok(Some(raw))
}

/// perform_update_media: Err((status, detail)) or the refreshed raw row.
pub async fn perform_update(req: &Req, id: i64, owner: i64, p: &Value) -> Result<Value, (u16, String)> {
    let squash = |s: String| s.split_whitespace().collect::<Vec<_>>().join(" ");
    let title = cut(&squash(vstr(p.get("title")).unwrap_or_default()), 160);
    if title.is_empty() {
        return Err((400, "Title is required.".into()));
    }
    let description = cut(&squash(vstr(p.get("description")).unwrap_or_default()), 2000);
    let mut tags: Vec<String> = Vec::new();
    for raw in p.get("tags").and_then(Value::as_array).into_iter().flatten() {
        let t: String = vstr(Some(raw)).unwrap_or_default().chars().filter(|c| c.is_ascii_alphanumeric() || "_.-".contains(*c)).collect();
        let t = cut(&t, 32);
        if !t.is_empty() && !tags.iter().any(|x| x.to_lowercase() == t.to_lowercase()) {
            tags.push(t);
            if tags.len() >= 12 {
                break;
            }
        }
    }
    let category_id = vnum(p.get("category_id")).map(|n| n.floor() as i64).unwrap_or(0);
    if category_id <= 0 {
        return Err((400, "A category is required.".into()));
    }
    let mut ids = media::normalize_subcategory_ids(p.get("subcategory_ids"));
    if ids.is_empty() && !p["subcategory_id"].is_null() {
        ids = media::normalize_subcategory_ids(Some(&json!([p["subcategory_id"]])));
    }
    let mut names = media::normalize_subcategory_names(p.get("subcategory_names"));
    if names.is_empty() && vstr(p.get("subcategory_name")).is_some_and(|s| !s.trim().is_empty()) {
        names = media::normalize_subcategory_names(Some(&json!([p["subcategory_name"]])));
    }
    let db = &req.app.db;
    let subs = media::resolve_subcategory_ids(db, category_id, ids, names, owner).await.map_err(|e| (400, e))?;
    let visibility = vstr(p.get("visibility")).unwrap_or_else(|| "public".into()).to_lowercase();
    if !matches!(visibility.as_str(), "public" | "unlisted" | "private") {
        return Err((400, "Visibility must be public, unlisted, or private.".into()));
    }
    let is_adult = truthy(p.get("is_adult"));
    let comments_enabled = p.get("comments_enabled").map(|v| truthy(Some(v))).unwrap_or(true);
    let downloads_enabled = p.get("downloads_enabled").map(|v| truthy(Some(v))).unwrap_or(true);
    let pinned = truthy(p.get("pinned"));
    let mut q = Sql::new();
    let mut extra = String::new();
    if let Some(sv) = p.get("source_url") {
        if sv.is_null() || vstr(Some(sv)).unwrap_or_default().trim().is_empty() {
            extra.push_str(", source_url=NULL");
        } else {
            let n = normalize_source_url(Some(sv)).map_err(|e| (400, e))?;
            extra.push_str(&format!(", source_url={}", q.bind(n)));
        }
    }
    if let Some(pv) = p.get("publish_at") {
        let when = vstr(Some(pv)).unwrap_or_default().trim().to_string();
        if pv.is_null() || when.is_empty() {
            extra.push_str(", publish_at=NULL");
        } else {
            if !schedule_ok(&when) {
                return Err((400, "Schedule time must look like 2026-09-05T18:00.".into()));
            }
            extra.push_str(&format!(", publish_at=({}::text)::timestamptz AT TIME ZONE 'UTC'", q.bind(cut(&when, 40))));
        }
    }
    let row = db
        .opt("SELECT user_id, title, description, tags, category_id, visibility, is_adult FROM media_items WHERE id=$1 AND deleted_at IS NULL", &[id.into()])
        .await
        .ok_or((404, "Media not found.".to_string()))?;
    if row.i("user_id") != Some(owner) {
        return Err((403, "Only the uploader can edit this post.".into()));
    }
    let new_tags = json!(tags).to_string();
    let mut changes = Map::new();
    if row.s("title").as_deref() != Some(title.as_str()) {
        changes.insert("title".into(), json!({ "from": row["title"], "to": title }));
    }
    if row.s("description").unwrap_or_default() != description {
        changes.insert("description".into(), json!({ "from": row["description"], "to": description }));
    }
    if row.s("tags").as_deref() != Some(new_tags.as_str()) {
        changes.insert("tags".into(), json!({ "from": row["tags"], "to": new_tags }));
    }
    if row.i("category_id") != Some(category_id) {
        changes.insert("category_id".into(), json!({ "from": row["category_id"], "to": category_id }));
    }
    if row.s("visibility").as_deref() != Some(visibility.as_str()) {
        changes.insert("visibility".into(), json!({ "from": row["visibility"], "to": visibility }));
    }
    if tobool(row.get("is_adult")) != is_adult {
        changes.insert("is_adult".into(), json!({ "from": tobool(row.get("is_adult")), "to": is_adult }));
    }
    let (t, d, tg, cat) = (q.bind(title.as_str()), q.bind(description.as_str()), q.bind(new_tags.as_str()), q.bind(category_id));
    let (vis, ce, de, pin, adult) = (q.bind(visibility.as_str()), q.bind(comments_enabled), q.bind(downloads_enabled), q.bind(pinned), q.bind(is_adult));
    let (wid, wown) = (q.bind(id), q.bind(owner));
    let sql = format!(
        "UPDATE media_items SET title={t}, description={d}, tags={tg}, category_id={cat}, visibility={vis}, comments_enabled={ce}, downloads_enabled={de}, \
         pinned_at=CASE WHEN {pin} THEN COALESCE(pinned_at, CURRENT_TIMESTAMP) ELSE NULL END, is_adult={adult}, adult_marked_by_user={adult}, \
         moderation_status=CASE WHEN {adult} THEN 'adult' ELSE moderation_status END, \
         moderation_reason=CASE WHEN {adult} THEN 'Uploader marked this post as 18+.' ELSE moderation_reason END, \
         moderated_at=CASE WHEN {adult} THEN CURRENT_TIMESTAMP ELSE moderated_at END{extra} WHERE id={wid} AND user_id={wown}"
    );
    db.exec(&sql, &q.params).await.map_err(|e| (500, format!("Could not update media: {e}")))?;
    media::write_subcategories(db, id, &subs).await;
    if !changes.is_empty() {
        let _ = db.exec("INSERT INTO media_edit_history (media_id, editor_id, changes) VALUES ($1, $2, $3)", &[id.into(), owner.into(), Value::Object(changes).to_string().into()]).await;
    }
    fetch_by_id(req, id, Some(owner)).await.ok_or((404, "Media not found.".into()))
}

pub async fn update_media(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let (id, u) = (mid(&req)?, uid(&user));
    let mut row = perform_update(&req, id, u, &req.json).await.map_err(|(s, d)| Reply::err(s, d))?;
    let adult = req.app.viewer_adult_allowed(Some(u)).await;
    decode_media_row(&req, &mut row, adult);
    Ok(Reply::ok(json!({ "media": row })))
}

pub async fn edit_history(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = mid(&req)?;
    let db = &req.app.db;
    let row = db.opt("SELECT user_id FROM media_items WHERE id=$1", &[id.into()]).await.ok_or_else(|| Reply::err(404, "Media not found."))?;
    if row.i("user_id") != Some(uid(&user)) {
        return Err(Reply::err(403, "Only the uploader can view this post's edit history."));
    }
    let rows = db
        .all(
            "SELECT h.id, h.editor_id, h.changes, h.created_at, u.username, u.display_name FROM media_edit_history h JOIN users u ON u.id = h.editor_id WHERE h.media_id=$1 ORDER BY h.created_at DESC LIMIT 100",
            &[id.into()],
        )
        .await;
    let out: Vec<Value> = rows
        .into_iter()
        .map(|r| {
            let changes = r.s("changes").and_then(|c| serde_json::from_str::<Value>(&c).ok()).unwrap_or_else(|| json!({}));
            json!({ "id": r["id"], "editor_id": r["editor_id"], "username": r["username"], "display_name": r["display_name"], "changes": changes, "created_at": r["created_at"] })
        })
        .collect();
    Ok(Reply::ok(json!({ "history": out })))
}

pub async fn set_controls(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let (id, u) = (mid(&req)?, uid(&user));
    let p = &req.json;
    let mut q = Sql::new();
    let mut sets = Vec::new();
    if let Some(v) = vstr(p.get("visibility")) {
        let v = v.to_lowercase();
        if !matches!(v.as_str(), "public" | "unlisted" | "private") {
            return Err(Reply::err(400, "Visibility must be public, unlisted, or private."));
        }
        sets.push(format!("visibility={}", q.bind(v)));
    }
    if let Some(v) = p.get("comments_enabled") {
        sets.push(format!("comments_enabled={}", q.bind(truthy(Some(v)))));
    }
    if let Some(v) = p.get("downloads_enabled") {
        sets.push(format!("downloads_enabled={}", q.bind(truthy(Some(v)))));
    }
    if let Some(v) = p.get("pinned") {
        sets.push(format!("pinned_at=CASE WHEN {} THEN COALESCE(pinned_at, CURRENT_TIMESTAMP) ELSE NULL END", q.bind(truthy(Some(v)))));
    }
    if let Some(pv) = p.get("publish_at") {
        let when = vstr(Some(pv)).unwrap_or_default().trim().to_string();
        if pv.is_null() || when.is_empty() {
            sets.push("publish_at=NULL".into());
        } else {
            if !schedule_ok(&when) {
                return Err(Reply::err(400, "Schedule time must look like 2026-09-05T18:00."));
            }
            sets.push(format!("publish_at=({}::text)::timestamptz AT TIME ZONE 'UTC'", q.bind(cut(&when, 40))));
        }
    }
    let db = &req.app.db;
    let row = db.opt("SELECT user_id FROM media_items WHERE id=$1 AND deleted_at IS NULL", &[id.into()]).await.ok_or_else(|| Reply::err(404, "Media not found."))?;
    if row.i("user_id") != Some(u) {
        return Err(Reply::err(403, "Only the uploader can change post controls."));
    }
    if !sets.is_empty() {
        let (i, o) = (q.bind(id), q.bind(u));
        let _ = db.exec(&format!("UPDATE media_items SET {} WHERE id={i} AND user_id={o}", sets.join(", ")), &q.params).await;
    }
    media_reply(&req, id, u).await
}

/// Soft delete by the owner; returns false if not found/owned.
pub async fn perform_delete(req: &Req, id: i64, owner: i64) -> bool {
    match fetch_by_id(req, id, Some(owner)).await {
        Some(item) if item.i("user_id") == Some(owner) => {
            let _ = req.app.db.exec("UPDATE media_items SET deleted_at=CURRENT_TIMESTAMP, visibility='private' WHERE id=$1 AND user_id=$2 AND deleted_at IS NULL", &[id.into(), owner.into()]).await;
            true
        }
        _ => false,
    }
}

pub async fn delete_media(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = mid(&req)?;
    if !perform_delete(&req, id, uid(&user)).await {
        return Err(Reply::err(404, "Media not found."));
    }
    Ok(Reply::ok(json!({ "deleted": true })))
}

pub async fn restore_media(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let (id, u) = (mid(&req)?, uid(&user));
    let db = &req.app.db;
    let row = db.opt("SELECT user_id FROM media_items WHERE id=$1", &[id.into()]).await.ok_or_else(|| Reply::err(404, "Media not found."))?;
    if row.i("user_id") != Some(u) {
        return Err(Reply::err(403, "Only the uploader can restore this post."));
    }
    let _ = db.exec("UPDATE media_items SET deleted_at=NULL, visibility='private' WHERE id=$1 AND user_id=$2", &[id.into(), u.into()]).await;
    media_reply(&req, id, u).await
}

pub async fn report_media(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let (id, u) = (mid(&req)?, uid(&user));
    let squash = |s: String| s.split_whitespace().collect::<Vec<_>>().join(" ");
    let reason = cut(&squash(req.js("reason").unwrap_or_default()), 80);
    if reason.is_empty() {
        return Err(Reply::err(400, "A reason is required."));
    }
    let details = Some(cut(&squash(req.js("details").unwrap_or_default()), 500)).filter(|d| !d.is_empty());
    let item = fetch_by_id(&req, id, Some(u)).await;
    ensure_visible(&req, item.as_ref(), Some(u)).await?;
    let db = &req.app.db;
    let _ = db
        .exec(
            "INSERT INTO media_reports (media_id, user_id, reason, details) VALUES ($1, $2, $3, $4) \
             ON CONFLICT (media_id, user_id) DO UPDATE SET reason=EXCLUDED.reason, details=EXCLUDED.details, status='open', created_at=CURRENT_TIMESTAMP",
            &[id.into(), u.into(), reason.into(), details.into()],
        )
        .await;
    let report = db.opt("SELECT * FROM media_reports WHERE media_id=$1 AND user_id=$2", &[id.into(), u.into()]).await;
    Ok(Reply::ok(json!({ "report": report })))
}

pub async fn similar_media(req: Req) -> R<Reply> {
    let id = mid(&req)?;
    let viewer = req.viewer().await;
    let adult = req.app.viewer_adult_allowed(viewer).await;
    let Some(src) = fetch_by_id(&req, id, viewer).await.filter(|s| s["deleted_at"].is_null()) else { return Ok(Reply::ok(json!({ "media": {} }))) };
    let limit = req.qi("limit").unwrap_or(24).clamp(1, 60);
    let offset = req.qi("offset").unwrap_or(0).max(0);
    let rows = compute_similar(&req, id, &src, adult, limit, offset).await;
    Ok(Reply::ok(json!({ "media": rows, "limit": limit, "offset": offset })))
}

fn bulk_ids(v: Option<&Value>) -> Vec<i64> {
    let mut out = Vec::new();
    for raw in v.and_then(Value::as_array).into_iter().flatten() {
        if let Some(id) = vnum(Some(raw)).filter(|n| *n > 0.0).map(|n| n as i64) {
            if !out.contains(&id) {
                out.push(id);
                if out.len() >= 200 {
                    break;
                }
            }
        }
    }
    out
}

pub async fn bulk_edit(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    let owner_flag = is_site_owner(&user);
    let ids = bulk_ids(req.json.get("ids"));
    let patch = req.json.get("patch").filter(|p| p.is_object()).cloned().unwrap_or_else(|| json!({}));
    let add_tag = vstr(patch.get("add_tag")).map(|t| media::normalize_upload_tag(&t, req.app.settings.max_tag_length)).unwrap_or_default();
    let mut results = Vec::new();
    for id in ids {
        let Some(existing) = fetch_by_id(&req, id, Some(u)).await.filter(|e| e["deleted_at"].is_null()) else {
            results.push(json!({ "id": id, "ok": false, "error": "Not found." }));
            continue;
        };
        let owner = existing.i("user_id").unwrap_or(0);
        if owner != u && !owner_flag {
            results.push(json!({ "id": id, "ok": false, "error": "Forbidden." }));
            continue;
        }
        let mut tags: Vec<Value> = json_list(existing.get("tags")).as_array().cloned().unwrap_or_default();
        if !add_tag.is_empty() && !tags.iter().any(|t| t == &json!(add_tag)) {
            tags.push(json!(add_tag));
            while tags.len() as i64 > req.app.settings.max_tags_per_upload {
                tags.remove(0);
            }
        }
        let mut merged = json!({
            "title": existing["title"],
            "description": existing["description"],
            "tags": tags,
            "category_id": existing["category_id"],
            "subcategory_ids": existing["subcategory_ids"],
            "visibility": existing["visibility"],
            "comments_enabled": existing.get("comments_enabled").cloned().unwrap_or(json!(true)),
            "downloads_enabled": existing.get("downloads_enabled").cloned().unwrap_or(json!(true)),
            "pinned": !existing["pinned_at"].is_null(),
            "is_adult": existing["is_adult"],
        });
        for k in ["visibility", "comments_enabled", "downloads_enabled", "pinned", "is_adult"] {
            if let Some(v) = patch.get(k) {
                merged[k] = v.clone();
            }
        }
        match perform_update(&req, id, owner, &merged).await {
            Ok(_) => results.push(json!({ "id": id, "ok": true })),
            Err((_, e)) => results.push(json!({ "id": id, "ok": false, "error": e })),
        }
    }
    Ok(Reply::ok(json!({ "results": results })))
}

pub async fn bulk_delete(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    let owner_flag = is_site_owner(&user);
    let mut results = Vec::new();
    for id in bulk_ids(req.json.get("ids")) {
        let Some(item) = fetch_by_id(&req, id, Some(u)).await.filter(|e| e["deleted_at"].is_null()) else {
            results.push(json!({ "id": id, "ok": false, "error": "Not found." }));
            continue;
        };
        let owner = item.i("user_id").unwrap_or(0);
        if owner == u {
            results.push(json!({ "id": id, "ok": perform_delete(&req, id, owner).await }));
        } else if owner_flag {
            let _ = req.app.db.exec("UPDATE media_items SET deleted_at=CURRENT_TIMESTAMP, visibility='private' WHERE id=$1 AND deleted_at IS NULL", &[id.into()]).await;
            results.push(json!({ "id": id, "ok": true }));
        } else {
            results.push(json!({ "id": id, "ok": false, "error": "Forbidden." }));
        }
    }
    Ok(Reply::ok(json!({ "results": results })))
}

#[cfg(test)]
mod tests {
    #[test]
    fn mention_parse() {
        assert_eq!(super::mentions("hi @Bob and @al and email a@b.com @carol.x"), vec!["bob".to_string(), "carol.x".to_string()]);
        assert!(super::schedule_ok("2026-09-05T18:00"));
        assert!(!super::schedule_ok("tomorrow"));
    }
}
