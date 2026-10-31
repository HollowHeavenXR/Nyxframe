//! Direct messages and group threads.

use crate::app::uid;
use crate::db::J;
use crate::http::{R, Reply, Req};
use crate::routes::notify;
use crate::util::{bools, cut};
use serde_json::{Value, json};

const MSG_SELECT: &str = "SELECT msg.*, u.username, u.display_name, u.avatar_path, u.profile_color, u.public_profile, (now() - u.last_seen_at) <= interval '180 seconds' AS is_online \
                          FROM user_messages msg JOIN users u ON u.id = msg.sender_id";

fn decode_message(mut r: Value) -> Value {
    bools(&mut r, &["public_profile", "is_online"]);
    for k in ["public_profile", "is_online"] {
        if r.get(k).is_none() {
            r[k] = json!(false);
        }
    }
    r
}

fn clean_body(req: &Req) -> R<String> {
    let b = req.js("body").unwrap_or_default().split_whitespace().collect::<Vec<_>>().join(" ");
    if b.is_empty() {
        return Err(Reply::err(400, "Message cannot be empty."));
    }
    if b.len() > 2000 {
        return Err(Reply::err(400, "Message must be 2000 characters or fewer."));
    }
    Ok(b)
}

pub async fn threads(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let rows = req
        .app
        .db
        .all(
            "SELECT other_user.id AS id, other_user.id AS user_id, other_user.username, \
               CASE WHEN other_user.public_profile THEN other_user.display_name ELSE other_user.username END AS display_name, \
               CASE WHEN other_user.public_profile THEN other_user.avatar_path ELSE NULL END AS avatar_path, \
               other_user.profile_color, other_user.public_profile, other_user.last_seen_at, \
               (now() - other_user.last_seen_at) <= interval '180 seconds' AS is_online, \
               latest.id AS last_message_id, latest.body AS last_message, latest.created_at AS last_message_at, \
               latest.sender_id AS last_sender_id, COALESCE(unread.unread_count, 0) AS unread_count \
             FROM (SELECT CASE WHEN sender_id=$1 THEN recipient_id ELSE sender_id END AS other_id, MAX(id) AS last_id FROM user_messages WHERE sender_id=$1 OR recipient_id=$1 GROUP BY other_id) threads \
             JOIN user_messages latest ON latest.id = threads.last_id JOIN users other_user ON other_user.id = threads.other_id \
             LEFT JOIN (SELECT sender_id AS other_id, COUNT(*) AS unread_count FROM user_messages WHERE recipient_id=$1 AND read_at IS NULL GROUP BY sender_id) unread ON unread.other_id = threads.other_id \
             ORDER BY latest.created_at DESC LIMIT 100",
            &[uid(&user).into()],
        )
        .await;
    let out: Vec<Value> = rows.into_iter().map(|r| req.with_user_urls(decode_message(r))).collect();
    Ok(Reply::ok(json!({ "threads": out })))
}

pub async fn direct_messages(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    let Some(other) = req.pi("user_id") else { return Err(Reply::err(404, "User not found.")) };
    if other == u {
        return Err(Reply::err(400, "Pick another user to view messages."));
    }
    if req.app.get_user(other).await.is_none() {
        return Err(Reply::err(400, "User not found."));
    }
    let db = &req.app.db;
    let _ = db.exec("UPDATE user_messages SET read_at=COALESCE(read_at, CURRENT_TIMESTAMP) WHERE sender_id=$1 AND recipient_id=$2 AND read_at IS NULL", &[other.into(), u.into()]).await;
    let limit = req.qi("limit").unwrap_or(80).clamp(1, 200);
    let mut rows = db
        .all(
            &format!("{MSG_SELECT} WHERE (msg.sender_id=$1 AND msg.recipient_id=$2) OR (msg.sender_id=$2 AND msg.recipient_id=$1) ORDER BY msg.created_at DESC, msg.id DESC LIMIT $3"),
            &[u.into(), other.into(), limit.into()],
        )
        .await;
    rows.reverse();
    Ok(Reply::ok(json!({ "messages": rows.into_iter().map(decode_message).collect::<Vec<_>>() })))
}

pub async fn send_direct(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    req.app.rate_check(&format!("dm:{u}"), 60, 3600).await?;
    let Some(other) = req.pi("user_id") else { return Err(Reply::err(404, "User not found.")) };
    if notify::is_blocked_either_way(&req.app, u, other).await {
        return Err(Reply::err(403, "You cannot message this user."));
    }
    if other == u {
        return Err(Reply::err(400, "You cannot message yourself."));
    }
    let body = clean_body(&req)?;
    if req.app.get_user(other).await.is_none() {
        return Err(Reply::err(400, "User not found."));
    }
    let db = &req.app.db;
    let id = db
        .opt("INSERT INTO user_messages (sender_id, recipient_id, body) VALUES ($1, $2, $3) RETURNING id", &[u.into(), other.into(), body.as_str().into()])
        .await
        .and_then(|r| r.i("id"))
        .ok_or_else(|| Reply::err(500, "Could not send message."))?;
    let msg = db.opt(&format!("{MSG_SELECT} WHERE msg.id = $1"), &[id.into()]).await.map(decode_message);
    notify::create(&req.app, other, Some(u), "message", None, Some(&body)).await;
    Ok(Reply::ok(json!({ "message": msg })))
}

// ---- groups -----------------------------------------------------------------------------------------
async fn is_member(req: &Req, group: i64, user: i64) -> bool {
    req.app.db.opt("SELECT 1 AS x FROM message_group_members WHERE group_id=$1 AND user_id=$2", &[group.into(), user.into()]).await.is_some()
}

async fn group_thread(req: &Req, group: i64, viewer: i64) -> Option<Value> {
    let db = &req.app.db;
    let g = db.opt("SELECT id, name, created_by, created_at FROM message_groups WHERE id=$1", &[group.into()]).await?;
    let members = db
        .all(
            "SELECT u.id, u.username, CASE WHEN u.public_profile THEN u.display_name ELSE u.username END AS display_name FROM message_group_members gm JOIN users u ON u.id = gm.user_id WHERE gm.group_id = $1 ORDER BY gm.joined_at ASC",
            &[group.into()],
        )
        .await;
    let display = g.s("name").unwrap_or_else(|| {
        let others: Vec<String> = members.iter().filter(|m| m.i("id") != Some(viewer)).filter_map(|m| m.s("display_name")).collect();
        if others.is_empty() { "Group".into() } else { others.join(", ") }
    });
    let last = db.opt("SELECT body FROM group_messages WHERE group_id=$1 ORDER BY created_at DESC LIMIT 1", &[group.into()]).await.and_then(|r| r.s("body"));
    let mut t = json!({ "id": g["id"], "display_name": display, "members": members });
    if let Some(n) = g.s("name") {
        t["name"] = json!(n);
    }
    if let Some(l) = last {
        t["last_message"] = json!(l);
    }
    Some(t)
}

pub async fn list_groups(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    let ids = req.app.db.all("SELECT gm.group_id FROM message_group_members gm JOIN message_groups g ON g.id = gm.group_id WHERE gm.user_id = $1 ORDER BY g.created_at DESC", &[u.into()]).await;
    let mut out = Vec::new();
    for r in ids {
        if let Some(t) = group_thread(&req, r.i("group_id").unwrap_or(0), u).await {
            out.push(t);
        }
    }
    Ok(Reply::ok(json!({ "threads": out })))
}

pub async fn create_group(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    req.app.rate_check(&format!("group_create:{u}"), 20, 3600).await?;
    let mut members: Vec<i64> = Vec::new();
    for raw in req.json.get("member_ids").and_then(Value::as_array).into_iter().flatten() {
        if let Some(n) = crate::util::vint(Some(raw)).filter(|n| *n != u) {
            if !members.contains(&n) && !notify::is_blocked_either_way(&req.app, u, n).await {
                members.push(n);
            }
        }
    }
    if members.is_empty() {
        return Err(Reply::err(400, "Add at least one other member to start a group."));
    }
    let name = req.js("name").map(|n| cut(n.trim(), 120)).filter(|n| !n.is_empty());
    let db = &req.app.db;
    let gid = db
        .one("INSERT INTO message_groups (name, created_by) VALUES ($1, $2) RETURNING id", &[name.into(), u.into()])
        .await
        .map_err(|e| Reply::err(500, format!("Could not create group: {e}")))?
        .and_then(|r| r.i("id"))
        .unwrap_or(0);
    let _ = db.exec("INSERT INTO message_group_members (group_id, user_id) VALUES ($1, $2)", &[gid.into(), u.into()]).await;
    for m in members {
        let _ = db.exec("INSERT INTO message_group_members (group_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING", &[gid.into(), m.into()]).await;
    }
    Ok(Reply::ok(json!({ "thread": group_thread(&req, gid, u).await })))
}

const GMSG_SELECT: &str = "SELECT msg.id, msg.group_id, msg.sender_id, msg.body, msg.created_at, u.username, u.display_name, u.avatar_path AS user_avatar_path, u.profile_color, u.public_profile \
                           FROM group_messages msg JOIN users u ON u.id = msg.sender_id";

fn decode_gmsg(req: &Req, mut r: Value) -> Value {
    bools(&mut r, &["public_profile"]);
    if r.get("public_profile").is_none() {
        r["public_profile"] = json!(false);
    }
    if r.as_object_mut().unwrap().remove("user_avatar_path").is_some() {
        r["user_avatar_path"] = json!(format!("{}/api/users/{}/avatar", req.origin(), r.i("sender_id").unwrap_or(0)));
    }
    r
}

pub async fn group_messages(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    let Some(g) = req.pi("group_id") else { return Err(Reply::err(404, "Group not found.")) };
    if !is_member(&req, g, u).await {
        return Err(Reply::err(404, "Group not found."));
    }
    let limit = req.qi("limit").unwrap_or(80).clamp(1, 200);
    let mut rows = req.app.db.all(&format!("{GMSG_SELECT} WHERE msg.group_id = $1 ORDER BY msg.created_at DESC, msg.id DESC LIMIT $2"), &[g.into(), limit.into()]).await;
    rows.reverse();
    Ok(Reply::ok(json!({ "messages": rows.into_iter().map(|r| decode_gmsg(&req, r)).collect::<Vec<_>>() })))
}

pub async fn send_group(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    req.app.rate_check(&format!("group_message:{u}"), 60, 3600).await?;
    let Some(g) = req.pi("group_id") else { return Err(Reply::err(404, "Group not found.")) };
    if !is_member(&req, g, u).await {
        return Err(Reply::err(404, "Group not found."));
    }
    let body = clean_body(&req)?;
    let db = &req.app.db;
    let id = db
        .opt("INSERT INTO group_messages (group_id, sender_id, body) VALUES ($1, $2, $3) RETURNING id", &[g.into(), u.into(), body.as_str().into()])
        .await
        .and_then(|r| r.i("id"))
        .ok_or_else(|| Reply::err(500, "Could not send message."))?;
    let msg = db.opt(&format!("{GMSG_SELECT} WHERE msg.id = $1"), &[id.into()]).await.map(|r| decode_gmsg(&req, r));
    for m in db.all("SELECT user_id FROM message_group_members WHERE group_id=$1 AND user_id != $2", &[g.into(), u.into()]).await {
        notify::create(&req.app, m.i("user_id").unwrap_or(0), Some(u), "message", None, Some(&body)).await;
    }
    Ok(Reply::ok(json!({ "message": msg })))
}
