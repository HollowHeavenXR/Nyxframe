//! Notifications (+ web push delivery), block checks, push subscriptions
//! and saved searches (including the new-upload match notifier).

use crate::app::{App, uid};
use crate::db::J;
use crate::http::{R, Reply, Req};
use crate::util::{cut, tobool, vstr};
use serde_json::{Map, Value, json};

const KINDS: &[&str] = &["follow", "friend_request", "friend_accept", "comment", "message", "mention", "reply", "reaction", "saved_search", "comment_reaction", "new_upload"];

fn push_text(kind: &str, actor: Option<&str>, title: Option<&str>, preview: Option<&str>) -> (String, String) {
    let a = actor.unwrap_or("Someone");
    let (t, b) = match kind {
        "follow" => ("New follower", format!("{a} followed you.")),
        "friend_request" => ("Friend request", format!("{a} sent you a friend request.")),
        "friend_accept" => ("Friend request accepted", format!("{a} accepted your friend request.")),
        "comment" => ("New comment", format!("{a} commented{}.", title.map(|t| format!(" on \"{t}\"")).unwrap_or_else(|| " on your post".into()))),
        "message" => ("New message", format!("{a} sent you a message.")),
        "mention" => ("You were mentioned", format!("{a} mentioned you in a comment.")),
        "reply" => ("New reply", format!("{a} replied to your comment.")),
        "reaction" => ("New reaction", format!("{a} reacted to your post.")),
        "comment_reaction" => ("New reaction", format!("{a} reacted to your comment.")),
        "new_upload" => ("New upload", format!("{a} uploaded{}.", title.map(|t| format!(" \"{t}\"")).unwrap_or_else(|| " something new".into()))),
        "saved_search" => ("Saved search match", preview.unwrap_or("A new post matches one of your saved searches.").to_string()),
        _ => ("Nyxframe", preview.map(str::to_string).unwrap_or_else(|| format!("{a} did something."))),
    };
    (t.to_string(), b)
}

async fn push_notify(app: &App, recipient: i64, actor: Option<i64>, kind: &str, media_id: Option<i64>, preview: Option<&str>) {
    let subs = app.db.all("SELECT id, endpoint, p256dh, auth FROM push_subscriptions WHERE user_id=$1", &[recipient.into()]).await;
    if subs.is_empty() {
        return;
    }
    let mut actor_name = None;
    if let Some(a) = actor {
        if let Some(r) = app.db.opt("SELECT username, display_name, public_profile FROM users WHERE id=$1", &[a.into()]).await {
            actor_name = if tobool(r.get("public_profile")) { r.s("display_name").or(r.s("username")) } else { r.s("username") };
        }
    }
    let mut title = None;
    if let Some(m) = media_id {
        title = app.db.opt("SELECT title FROM media_items WHERE id=$1", &[m.into()]).await.and_then(|r| r.s("title"));
    }
    let (t, b) = push_text(kind, actor_name.as_deref(), title.as_deref(), preview);
    let url = match (media_id, kind) {
        (Some(m), _) => format!("/media/{m}"),
        (None, "message") => "/messages".into(),
        (None, "friend_request") => "/friends".into(),
        _ => "/".into(),
    };
    let payload = json!({ "title": t, "body": b, "url": url });
    for sub in subs {
        let (http, db, dir, subj, payload) = (app.http.clone(), app.db.clone(), app.settings.uploads_dir.clone(), app.settings.vapid_subject.clone(), payload.clone());
        tokio::spawn(async move {
            match crate::webpush::send(&http, &dir, &subj, &sub, &payload).await {
                Ok(404) | Ok(410) => {
                    let _ = db.exec("DELETE FROM push_subscriptions WHERE id=$1", &[sub.i("id").unwrap_or(0).into()]).await;
                }
                Ok(_) => {}
                Err(e) => println!("[nyxframe] web push send failed: {e}"),
            }
        });
    }
}

/// Recipient has blocked or muted the actor (one-way).
async fn suppressed(app: &App, recipient: i64, actor: i64) -> bool {
    app.db.opt("SELECT 1 AS x FROM user_blocks WHERE blocker_id=$1 AND blocked_id=$2 LIMIT 1", &[recipient.into(), actor.into()]).await.is_some()
}

/// In-app notification + push; silently skips self, unknown kinds and muted/blocked actors.
pub async fn create(app: &App, recipient: i64, actor: Option<i64>, kind: &str, media_id: Option<i64>, preview: Option<&str>) {
    if !KINDS.contains(&kind) || actor == Some(recipient) {
        return;
    }
    if let Some(a) = actor {
        if suppressed(app, recipient, a).await {
            return;
        }
    }
    let preview = preview.map(|p| cut(p.trim(), 160)).filter(|p| !p.is_empty());
    let _ = app
        .db
        .exec("INSERT INTO notifications (recipient_id, actor_id, kind, media_id, preview) VALUES ($1, $2, $3, $4, $5)", &[recipient.into(), actor.into(), kind.into(), media_id.into(), preview.clone().into()])
        .await;
    push_notify(app, recipient, actor, kind, media_id, preview.as_deref()).await;
}

pub async fn is_blocked_either_way(app: &App, a: i64, b: i64) -> bool {
    app.db
        .opt("SELECT 1 AS x FROM user_blocks WHERE kind='block' AND ((blocker_id=$1 AND blocked_id=$2) OR (blocker_id=$2 AND blocked_id=$1)) LIMIT 1", &[a.into(), b.into()])
        .await
        .is_some()
}

// ---- notifications --------------------------------------------------------------------------------
async fn unread(req: &Req, id: i64) -> i64 {
    req.app.db.opt("SELECT COUNT(*) AS n FROM notifications WHERE recipient_id=$1 AND read_at IS NULL", &[id.into()]).await.and_then(|r| r.i("n")).unwrap_or(0)
}

pub async fn unread_count(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    Ok(Reply::ok(json!({ "unread_count": unread(&req, uid(&user)).await })))
}

pub async fn mark_read(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = uid(&user);
    if let Some(n) = req.pi("notification_id") {
        let _ = req.app.db.exec("UPDATE notifications SET read_at=now() WHERE id=$1 AND recipient_id=$2 AND read_at IS NULL", &[n.into(), id.into()]).await;
    }
    Ok(Reply::ok(json!({ "unread_count": unread(&req, id).await })))
}

pub async fn mark_all_read(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let _ = req.app.db.exec("UPDATE notifications SET read_at=now() WHERE recipient_id=$1 AND read_at IS NULL", &[uid(&user).into()]).await;
    Ok(Reply::ok(json!({ "unread_count": 0 })))
}

pub async fn list(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = uid(&user);
    let limit = req.qi("limit").unwrap_or(30).clamp(1, 100);
    let rows = req
        .app
        .db
        .all(
            "SELECT n.id, n.recipient_id, n.actor_id, n.kind, n.media_id, n.preview, n.read_at, n.created_at, a.username AS actor_username, a.display_name AS actor_display_name \
             FROM notifications n LEFT JOIN users a ON a.id = n.actor_id WHERE n.recipient_id = $1 ORDER BY n.created_at DESC LIMIT $2",
            &[id.into(), limit.into()],
        )
        .await;
    Ok(Reply::ok(json!({ "notifications": rows, "unread_count": unread(&req, id).await })))
}

// ---- push subscriptions ------------------------------------------------------------------------------
pub async fn vapid_public_key(req: Req) -> R<Reply> {
    let key = crate::webpush::public_key_b64url(&req.app.settings.uploads_dir).map_err(|e| Reply::err(500, format!("Push is not available: {e}")))?;
    Ok(Reply::ok(json!({ "key": key })))
}

pub async fn subscribe(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let endpoint = req.js("endpoint").unwrap_or_default().trim().to_string();
    let keys = req.json.get("keys").cloned().unwrap_or_else(|| json!({}));
    let p256dh = vstr(keys.get("p256dh")).unwrap_or_default().trim().to_string();
    let auth = vstr(keys.get("auth")).unwrap_or_default().trim().to_string();
    if endpoint.is_empty() || p256dh.is_empty() || auth.is_empty() {
        return Err(Reply::err(400, "A complete push subscription (endpoint, keys.p256dh, keys.auth) is required."));
    }
    if !(endpoint.starts_with("https://") || endpoint.starts_with("http://")) {
        return Err(Reply::err(400, "Invalid push endpoint."));
    }
    let ua = cut(req.header("user-agent").unwrap_or("").trim(), 300);
    let _ = req
        .app
        .db
        .exec(
            "INSERT INTO push_subscriptions (user_id, endpoint, p256dh, auth, user_agent) VALUES ($1, $2, $3, $4, $5) \
             ON CONFLICT (endpoint) DO UPDATE SET user_id=EXCLUDED.user_id, p256dh=EXCLUDED.p256dh, auth=EXCLUDED.auth, user_agent=EXCLUDED.user_agent",
            &[uid(&user).into(), endpoint.into(), p256dh.into(), auth.into(), (!ua.is_empty()).then_some(ua).into()],
        )
        .await;
    Ok(Reply::ok(json!({ "ok": true })))
}

pub async fn unsubscribe(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let endpoint = req.js("endpoint").unwrap_or_default().trim().to_string();
    if endpoint.is_empty() {
        return Err(Reply::err(400, "endpoint is required."));
    }
    let _ = req.app.db.exec("DELETE FROM push_subscriptions WHERE user_id=$1 AND endpoint=$2", &[uid(&user).into(), endpoint.into()]).await;
    Ok(Reply::ok(json!({ "ok": true })))
}

// ---- saved searches ------------------------------------------------------------------------------------
const SMART_KEYS: &[&str] = &["media_kind", "category_id", "subcategory_id", "q", "uploader", "min_size", "max_size", "date_from", "date_to", "adult", "sort"];

fn is_date(s: &str) -> bool {
    s.len() == 10 && s.chars().enumerate().all(|(i, c)| if i == 4 || i == 7 { c == '-' } else { c.is_ascii_digit() })
}

/// _sanitize_smart_collection_filter: only known keys, validated/coerced.
pub fn sanitize_smart_filter(v: Option<&Value>) -> Value {
    let mut out = Map::new();
    let Some(obj) = v.and_then(Value::as_object) else { return json!({}) };
    for (k, val) in obj {
        if !SMART_KEYS.contains(&k.as_str()) || val.is_null() || val == "" {
            continue;
        }
        let s = vstr(Some(val)).unwrap_or_default();
        let num = crate::util::vnum(Some(val));
        match k.as_str() {
            "media_kind" if s == "image" || s == "video" => {
                out.insert(k.clone(), json!(s));
            }
            "category_id" | "subcategory_id" => {
                if let Some(n) = num {
                    out.insert(k.clone(), json!(n.floor() as i64));
                }
            }
            "min_size" | "max_size" => {
                if let Some(n) = num {
                    out.insert(k.clone(), json!((n.floor() as i64).max(0)));
                }
            }
            "date_from" | "date_to" if is_date(&s) => {
                out.insert(k.clone(), json!(s));
            }
            "adult" if s == "only" || s == "hide" => {
                out.insert(k.clone(), json!(s));
            }
            "sort" if ["new", "old", "popular", "views", "downloads", "trending"].contains(&s.as_str()) => {
                out.insert(k.clone(), json!(s));
            }
            "q" | "uploader" => {
                out.insert(k.clone(), json!(cut(&s, 80)));
            }
            _ => {}
        }
    }
    if out.is_empty() { json!({}) } else { Value::Object(out) }
}

fn decode_saved(mut row: Value) -> Value {
    row["filter_json"] = row.s("filter_json").and_then(|s| serde_json::from_str::<Value>(&s).ok()).filter(Value::is_object).unwrap_or_else(|| json!({}));
    row
}

pub async fn list_saved(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let rows: Vec<Value> = req.app.db.all("SELECT * FROM saved_searches WHERE user_id=$1 ORDER BY created_at DESC", &[uid(&user).into()]).await.into_iter().map(decode_saved).collect();
    Ok(Reply::ok(json!({ "saved_searches": rows })))
}

pub async fn create_saved(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let name = cut(&req.js("name").unwrap_or_default().split_whitespace().collect::<Vec<_>>().join(" "), 80);
    if name.is_empty() {
        return Err(Reply::err(400, "Name is required."));
    }
    let cleaned = sanitize_smart_filter(req.json.get("filter_json"));
    let row = req
        .app
        .db
        .one("INSERT INTO saved_searches (user_id, name, filter_json) VALUES ($1, $2, $3) RETURNING id", &[uid(&user).into(), name.into(), cleaned.to_string().into()])
        .await
        .map_err(|e| Reply::err(500, format!("Could not save search: {e}")))?;
    let id = row.and_then(|r| r.i("id")).unwrap_or(0);
    let s = req.app.db.opt("SELECT * FROM saved_searches WHERE id=$1", &[id.into()]).await.map(decode_saved);
    Ok(Reply::ok(json!({ "saved_search": s })))
}

pub async fn delete_saved(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = uid(&user);
    let Some(sid) = req.pi("search_id") else { return Err(Reply::err(404, "Saved search not found.")) };
    if req.app.db.opt("SELECT id FROM saved_searches WHERE id=$1 AND user_id=$2", &[sid.into(), id.into()]).await.is_none() {
        return Err(Reply::err(404, "Saved search not found."));
    }
    let _ = req.app.db.exec("DELETE FROM saved_searches WHERE id=$1 AND user_id=$2", &[sid.into(), id.into()]).await;
    Ok(Reply::ok(json!({ "deleted": true })))
}

pub async fn mute_saved(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = uid(&user);
    let Some(sid) = req.pi("search_id") else { return Err(Reply::err(404, "Saved search not found.")) };
    let muted = tobool(req.json.get("muted"));
    if req.app.db.opt("SELECT id FROM saved_searches WHERE id=$1 AND user_id=$2", &[sid.into(), id.into()]).await.is_none() {
        return Err(Reply::err(404, "Saved search not found."));
    }
    let _ = req.app.db.exec("UPDATE saved_searches SET notifications_muted=$1 WHERE id=$2 AND user_id=$3", &[muted.into(), sid.into(), id.into()]).await;
    Ok(Reply::ok(json!({ "id": sid, "notifications_muted": muted })))
}

/// _media_matches_saved_search_filter, evaluated in memory for one new upload.
pub fn media_matches(media: &Value, f: &Value) -> bool {
    let fs = |k: &str| vstr(f.get(k));
    if let Some(k) = fs("media_kind") {
        if media.s("media_kind").as_deref() != Some(k.as_str()) {
            return false;
        }
    }
    if let Some(c) = fs("category_id") {
        if vstr(media.get("category_id")).as_deref() != Some(c.as_str()) {
            return false;
        }
    }
    if let Some(w) = fs("subcategory_id") {
        let direct = vstr(media.get("subcategory_id")).as_deref() == Some(w.as_str());
        let listed = media["subcategories"].as_array().is_some_and(|a| a.iter().any(|s| vstr(s.get("id")).as_deref() == Some(w.as_str())));
        if !direct && !listed {
            return false;
        }
    }
    let adult = tobool(media.get("is_adult"));
    match fs("adult").as_deref() {
        Some("only") if !adult => return false,
        Some("hide") if adult => return false,
        _ => {}
    }
    let size = crate::util::vnum(media.get("file_size")).unwrap_or(0.0);
    if let Some(n) = crate::util::vnum(f.get("min_size")) {
        if size < n {
            return false;
        }
    }
    if let Some(n) = crate::util::vnum(f.get("max_size")) {
        if size > n {
            return false;
        }
    }
    if let Some(u) = fs("uploader") {
        let hay = format!("{} {}", media.s("username").unwrap_or_default(), media.s("display_name").unwrap_or_default()).to_lowercase();
        if !hay.contains(&u.to_lowercase()) {
            return false;
        }
    }
    if let Some(q) = fs("q") {
        let tags = media["tags"].as_array().map(|a| a.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" ")).unwrap_or_default();
        let hay = format!("{} {} {}", media.s("title").unwrap_or_default(), media.s("description").unwrap_or_default(), tags).to_lowercase();
        if !hay.contains(&q.to_lowercase()) {
            return false;
        }
    }
    true
}

/// After a public upload: notify everyone whose saved search matches it.
pub async fn notify_matching_saved_searches(app: &App, uploader: i64, item: &Value) {
    let rows = app.db.all("SELECT * FROM saved_searches WHERE user_id != $1 AND notifications_muted=false", &[uploader.into()]).await;
    for row in rows.into_iter().map(decode_saved) {
        if !media_matches(item, &row["filter_json"]) {
            continue;
        }
        let owner = row.i("user_id").unwrap_or(0);
        if is_blocked_either_way(app, owner, uploader).await {
            continue;
        }
        let text = format!("New match for \"{}\": {}", row.s("name").unwrap_or_default(), item.s("title").unwrap_or_else(|| "nil".into()));
        create(app, owner, Some(uploader), "saved_search", item.i("id"), Some(&text)).await;
        let _ = app.db.exec("UPDATE saved_searches SET last_notified_at=CURRENT_TIMESTAMP WHERE id=$1", &[row.i("id").unwrap_or(0).into()]).await;
    }
}
