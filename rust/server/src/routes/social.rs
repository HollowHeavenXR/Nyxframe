//! People: search, suggestions, public profiles, follows, friend
//! requests, followers/following/friends lists, blocks and mutes.

use crate::app::{App, decode_user, uid};
use crate::db::{J, Sql};
use crate::http::{R, Reply, Req};
use crate::media::{FROM_JOINS, finish_rows, select_cols_own};
use crate::routes::browse::like_escape;
use crate::routes::notify;
use crate::util::{bools, cut, tobool, truthy};
use serde_json::{Value, json};
use std::collections::HashMap;

const FR_ORDER: &str = "ORDER BY CASE status WHEN 'accepted' THEN 1 WHEN 'pending' THEN 2 WHEN 'declined' THEN 3 WHEN 'cancelled' THEN 4 ELSE 5 END, created_at DESC";

fn status_of(row: &Value, viewer: i64) -> &'static str {
    match row.s("status").as_deref() {
        Some("declined") | Some("cancelled") | None => "none",
        Some("accepted") => "friends",
        _ => {
            if row.i("requester_id") == Some(viewer) {
                "pending_out"
            } else {
                "pending_in"
            }
        }
    }
}

pub async fn friend_status(app: &App, viewer: Option<i64>, user: i64) -> &'static str {
    let Some(v) = viewer else { return "none" };
    if v == user {
        return "self";
    }
    let row = app
        .db
        .opt(&format!("SELECT requester_id, addressee_id, status FROM friend_requests WHERE (requester_id=$1 AND addressee_id=$2) OR (requester_id=$2 AND addressee_id=$1) {FR_ORDER} LIMIT 1"), &[v.into(), user.into()])
        .await;
    row.map(|r| status_of(&r, v)).unwrap_or("none")
}

pub async fn search_users(req: Req) -> R<Reply> {
    let viewer = req.viewer().await;
    let v = viewer.unwrap_or(0);
    let q = cut(&req.q("q").unwrap_or_default().split_whitespace().collect::<Vec<_>>().join(" "), 80);
    let limit = req.qi("limit").unwrap_or(30).clamp(1, 60);
    let rows = req
        .app
        .db
        .all(
            "SELECT u.id, u.username, \
               CASE WHEN u.public_profile OR u.id::text=$1 THEN u.display_name ELSE u.username END AS display_name, \
               CASE WHEN u.public_profile OR u.id::text=$1 THEN u.bio ELSE NULL END AS bio, \
               CASE WHEN u.public_profile OR u.id::text=$1 THEN u.profile_headline ELSE NULL END AS profile_headline, \
               CASE WHEN u.public_profile OR u.id::text=$1 THEN u.avatar_path ELSE NULL END AS avatar_path, \
               u.profile_color, u.public_profile, u.show_liked_count, u.show_collections, u.show_recent_uploads, u.show_friends, u.adult_content_consent, u.email_verified_at, u.last_seen_at, \
               COUNT(DISTINCT m.id) AS media_count, COUNT(DISTINCT f.follower_id) AS follower_count, \
               MAX(CASE WHEN mine.follower_id IS NULL THEN 0 ELSE 1 END) AS followed_by_me, \
               MAX(CASE WHEN mine.notifications_muted THEN 1 ELSE 0 END) AS follow_notifications_muted \
             FROM users u LEFT JOIN media_items m ON m.user_id=u.id AND m.deleted_at IS NULL AND m.visibility='public' \
             LEFT JOIN user_follows f ON f.followed_id=u.id LEFT JOIN user_follows mine ON mine.followed_id=u.id AND mine.follower_id::text=$1 \
             WHERE $2 = '' OR u.username ILIKE $3 \
               OR (CASE WHEN u.public_profile OR u.id::text=$1 THEN u.display_name ELSE NULL END) ILIKE $3 \
               OR (CASE WHEN u.public_profile OR u.id::text=$1 THEN u.bio ELSE NULL END) ILIKE $3 \
               OR (CASE WHEN u.public_profile OR u.id::text=$1 THEN u.profile_headline ELSE NULL END) ILIKE $3 \
             GROUP BY u.id ORDER BY (u.username=$2) DESC, follower_count DESC, media_count DESC, u.created_at DESC LIMIT $4",
            &[v.to_string().into(), q.as_str().into(), like_escape(&q).into(), limit.into()],
        )
        .await;
    let mut statuses: HashMap<i64, &'static str> = HashMap::new();
    if let (Some(vid), false) = (viewer, rows.is_empty()) {
        let list = rows.iter().filter_map(|r| r.i("id")).map(|i| i.to_string()).collect::<Vec<_>>().join(", ");
        let frs = req
            .app
            .db
            .all(&format!("SELECT requester_id, addressee_id, status, created_at FROM friend_requests WHERE (requester_id=$1 AND addressee_id IN ({list})) OR (addressee_id=$1 AND requester_id IN ({list})) {FR_ORDER}"), &[vid.into()])
            .await;
        for fr in frs {
            let other = if fr.i("requester_id") == Some(vid) { fr.i("addressee_id") } else { fr.i("requester_id") }.unwrap_or(0);
            statuses.entry(other).or_insert_with(|| status_of(&fr, vid));
        }
    }
    let out: Vec<Value> = rows
        .into_iter()
        .map(|r| {
            let mut r = decode_user(r);
            bools(&mut r, &["followed_by_me", "follow_notifications_muted"]);
            let id = r.i("id").unwrap_or(0);
            r["friend_status"] = json!(match viewer {
                None => "none",
                Some(x) if x == id => "self",
                _ => statuses.get(&id).copied().unwrap_or("none"),
            });
            req.with_user_urls(r)
        })
        .collect();
    Ok(Reply::ok(json!({ "users": out, "limit": limit })))
}

pub async fn suggested_users(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let limit = req.qi("limit").unwrap_or(10).clamp(1, 30);
    let rows = req
        .app
        .db
        .query(
            "WITH my_follows AS (SELECT followed_id FROM user_follows WHERE follower_id=$1), \
             not_blocked AS (SELECT u.id FROM users u WHERE u.id != $1 AND u.id NOT IN (SELECT followed_id FROM my_follows) \
               AND u.id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id=$1 AND kind='block') AND u.id NOT IN (SELECT blocker_id FROM user_blocks WHERE blocked_id=$1 AND kind='block')), \
             signals AS (SELECT uf2.followed_id AS user_id, COUNT(*)::real AS score FROM user_follows uf1 JOIN user_follows uf2 ON uf2.follower_id = uf1.followed_id WHERE uf1.follower_id = $1 GROUP BY uf2.followed_id \
               UNION ALL SELECT m.user_id AS user_id, COUNT(*)::real * 2 AS score FROM media_likes ml JOIN media_items m ON m.id = ml.media_id AND m.deleted_at IS NULL WHERE ml.user_id = $1 GROUP BY m.user_id), \
             ranked AS (SELECT s.user_id, SUM(s.score) AS total_score FROM signals s JOIN not_blocked nb ON nb.id = s.user_id GROUP BY s.user_id \
               UNION ALL SELECT nb.id AS user_id, 0 AS total_score FROM not_blocked nb JOIN users u2 ON u2.id = nb.id WHERE u2.public_profile) \
             SELECT r.user_id AS id, MAX(r.total_score) AS total_score, u.username, u.display_name, u.bio, u.profile_headline, u.avatar_path, u.profile_color, u.public_profile, \
               COUNT(DISTINCT f.follower_id) AS follower_count \
             FROM ranked r JOIN users u ON u.id = r.user_id LEFT JOIN user_follows f ON f.followed_id = u.id \
             GROUP BY r.user_id, u.username, u.display_name, u.bio, u.profile_headline, u.avatar_path, u.profile_color, u.public_profile \
             ORDER BY (MAX(r.total_score) > 0) DESC, MAX(r.total_score) DESC, follower_count DESC LIMIT $2",
            &[uid(&user).into(), limit.into()],
        )
        .await
        .map_err(crate::media::query_failed)?;
    let out: Vec<Value> = rows
        .into_iter()
        .map(|mut r| {
            let score = r.f("total_score").unwrap_or(0.0);
            r["total_score"] = json!(score);
            let public = tobool(r.get("public_profile"));
            r["public_profile"] = json!(public);
            if !public {
                r["display_name"] = r["username"].clone();
                let o = r.as_object_mut().unwrap();
                for k in ["bio", "profile_headline", "avatar_path"] {
                    o.remove(k);
                }
            }
            r["match_reason"] = json!(if score > 0.0 { "signal" } else { "trending" });
            req.with_user_urls(r)
        })
        .collect();
    Ok(Reply::ok(json!({ "users": out, "limit": limit })))
}

/// One profile with counts and the privacy toggles applied.
async fn public_profile_row(req: &Req, username: &str, viewer: Option<i64>) -> Option<Value> {
    let v = viewer.unwrap_or(0).to_string();
    let row = req
        .app
        .db
        .opt(
            "SELECT u.id, u.username, \
               CASE WHEN u.public_profile OR u.id::text=$1 THEN u.display_name ELSE u.username END AS display_name, \
               CASE WHEN u.public_profile OR u.id::text=$1 THEN u.bio ELSE NULL END AS bio, \
               CASE WHEN u.public_profile OR u.id::text=$1 THEN u.profile_headline ELSE NULL END AS profile_headline, \
               CASE WHEN u.public_profile OR u.id::text=$1 THEN u.featured_tags ELSE NULL END AS featured_tags, \
               CASE WHEN u.public_profile OR u.id::text=$1 THEN u.website_url ELSE NULL END AS website_url, \
               CASE WHEN u.public_profile OR u.id::text=$1 THEN u.location_label ELSE NULL END AS location_label, \
               CASE WHEN u.public_profile OR u.id::text=$1 THEN u.avatar_path ELSE NULL END AS avatar_path, \
               CASE WHEN u.public_profile OR u.id::text=$1 THEN u.user_settings ELSE NULL END AS user_settings, \
               u.avatar_file_id, u.profile_color, u.public_profile, u.show_liked_count, u.show_collections, u.show_recent_uploads, u.show_friends, u.created_at, u.last_seen_at, \
               u.discord_verified_at, u.discord_username, \
               u.user_settings::jsonb->>'profile_show_follow_counts' AS show_follow_counts_raw, u.user_settings::jsonb->>'profile_show_joined_date' AS show_joined_date_raw, \
               COUNT(DISTINCT m.id) AS media_count, \
               COALESCE(SUM(CASE WHEN m.deleted_at IS NULL AND m.visibility='public' THEN m.downloads ELSE 0 END), 0)::bigint AS download_count, \
               COUNT(DISTINCT (ml.user_id, ml.media_id)) AS like_count, COUNT(DISTINCT f1.follower_id) AS follower_count, COUNT(DISTINCT f2.followed_id) AS following_count, \
               COUNT(DISTINCT CASE WHEN fr.status='accepted' AND (fr.requester_id=u.id OR fr.addressee_id=u.id) THEN fr.id END) AS friend_count, \
               MAX(CASE WHEN f3.follower_id::text=$1 THEN 1 ELSE 0 END) AS followed_by_me, MAX(CASE WHEN f3.notifications_muted THEN 1 ELSE 0 END) AS follow_notifications_muted, \
               (now() - u.last_seen_at) <= interval '180 seconds' AS is_online \
             FROM users u LEFT JOIN media_items m ON m.user_id=u.id AND m.deleted_at IS NULL AND (m.visibility='public' OR m.user_id::text=$1) \
             LEFT JOIN media_likes ml ON ml.media_id=m.id LEFT JOIN user_follows f1 ON f1.followed_id=u.id LEFT JOIN user_follows f2 ON f2.follower_id=u.id \
             LEFT JOIN user_follows f3 ON f3.followed_id=u.id AND f3.follower_id::text=$1 \
             LEFT JOIN friend_requests fr ON fr.status='accepted' AND (fr.requester_id=u.id OR fr.addressee_id=u.id) \
             WHERE u.username=$2 GROUP BY u.id",
            &[v.into(), cut(username.trim(), 40).into()],
        )
        .await?;
    let mut row = decode_user(row);
    bools(&mut row, &["followed_by_me", "follow_notifications_muted", "is_online"]);
    let id = row.i("id").unwrap_or(0);
    row["friend_status"] = json!(friend_status(&req.app, viewer, id).await);
    let owner = viewer == Some(id);
    let o = row.as_object_mut().unwrap();
    let raw_counts = o.remove("show_follow_counts_raw");
    let raw_joined = o.remove("show_joined_date_raw");
    if !owner {
        if !tobool(o.get("show_liked_count")) {
            o.remove("like_count");
        }
        if raw_counts.as_ref().and_then(Value::as_str) == Some("false") {
            o.remove("follower_count");
            o.remove("following_count");
        }
        if raw_joined.as_ref().and_then(Value::as_str) == Some("false") {
            o.remove("created_at");
        }
        if !tobool(o.get("show_friends")) {
            o.remove("friend_count");
        }
    }
    Some(row)
}

async fn visible_profile(req: &Req, viewer: Option<i64>) -> R<Value> {
    let username = crate::http::url_decode(&req.p("username"));
    let p = public_profile_row(req, &username, viewer).await.ok_or_else(|| Reply::err(404, "User not found."))?;
    if let Some(v) = viewer {
        if notify::is_blocked_either_way(&req.app, v, p.i("id").unwrap_or(0)).await {
            return Err(Reply::err(404, "User not found."));
        }
    }
    Ok(p)
}

pub async fn public_profile(req: Req) -> R<Reply> {
    let viewer = req.viewer().await;
    let p = visible_profile(&req, viewer).await?;
    Ok(Reply::ok(json!({ "user": req.with_user_urls(p) })))
}

async fn profile_friends(req: &Req, user: i64, viewer: Option<i64>, limit: i64) -> Vec<Value> {
    req.app
        .db
        .all(
            "SELECT u.id, u.username, CASE WHEN u.public_profile OR u.id::text=$1 THEN u.display_name ELSE u.username END AS display_name, \
               CASE WHEN u.public_profile OR u.id::text=$1 THEN u.bio ELSE NULL END AS bio, CASE WHEN u.public_profile OR u.id::text=$1 THEN u.avatar_path ELSE NULL END AS avatar_path, \
               u.profile_color, u.public_profile, u.last_seen_at, fr.responded_at AS friended_at \
             FROM friend_requests fr JOIN users u ON u.id = CASE WHEN fr.requester_id::text=$2 THEN fr.addressee_id ELSE fr.requester_id END \
             WHERE fr.status='accepted' AND (fr.requester_id::text=$2 OR fr.addressee_id::text=$2) ORDER BY fr.responded_at DESC, fr.created_at DESC LIMIT $3",
            &[viewer.unwrap_or(0).to_string().into(), user.to_string().into(), limit.into()],
        )
        .await
        .into_iter()
        .map(decode_user)
        .collect()
}

pub async fn profile_page(req: Req) -> R<Reply> {
    let viewer = req.viewer().await;
    let p = visible_profile(&req, viewer).await?;
    let adult = req.app.viewer_adult_allowed(viewer).await;
    let pid = p.i("id").unwrap_or(0);
    let owner = viewer == Some(pid);
    let settings = &p["user_settings"];
    // Lua's `s.x ~= nil and s.x or fallback`: only an explicit true wins over the column.
    let pick = |k: &str, col: &str| owner || truthy(settings.get(k)) || tobool(p.get(col));
    let (show_up, show_col, show_fr) = (pick("profile_show_uploads", "show_recent_uploads"), pick("profile_show_collections", "show_collections"), pick("profile_show_friends", "show_friends"));
    let v = viewer.unwrap_or(0);
    let media = if show_up {
        let mut q = Sql::new();
        let vt = q.bind(v.to_string());
        let t = q.bind(pid);
        let adult_clause = if adult { "" } else { "AND m.is_adult=false" };
        let sql = format!(
            "{} {FROM_JOINS} WHERE m.user_id={t} AND m.deleted_at IS NULL AND (m.visibility='public' OR m.user_id::text={vt}) {adult_clause} ORDER BY m.pinned_at DESC NULLS LAST, m.created_at DESC LIMIT 36",
            select_cols_own(&vt)
        );
        let mut rows = req.app.db.all(&sql, &q.params).await;
        finish_rows(&req, &mut rows, adult).await;
        rows
    } else {
        vec![]
    };
    let collections = if show_col { crate::routes::collections::for_profile(&req, pid, viewer, adult, 12).await } else { vec![] };
    let friends = if show_fr { profile_friends(&req, pid, viewer, 18).await } else { vec![] };
    Ok(Reply::ok(json!({ "user": req.with_user_urls(p), "media": media, "collections": collections, "friends": friends })))
}

fn target(req: &Req) -> R<i64> {
    req.pi("user_id").ok_or_else(|| Reply::err(404, "User not found."))
}

async fn user_exists(req: &Req, id: i64) -> bool {
    req.app.db.opt("SELECT id FROM users WHERE id=$1", &[id.into()]).await.is_some()
}

pub async fn follow(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    req.app.rate_check(&format!("follow:{u}"), 60, 3600).await?;
    let t = target(&req)?;
    let following = tobool(req.json.get("following"));
    if u == t {
        return Err(Reply::err(400, "You cannot follow yourself."));
    }
    if following && notify::is_blocked_either_way(&req.app, u, t).await {
        return Err(Reply::err(403, "You cannot follow this user."));
    }
    if !user_exists(&req, t).await {
        return Err(Reply::err(404, "User not found."));
    }
    let db = &req.app.db;
    let sql = if following { "INSERT INTO user_follows (follower_id, followed_id) VALUES ($1, $2) ON CONFLICT (follower_id, followed_id) DO NOTHING" } else { "DELETE FROM user_follows WHERE follower_id=$1 AND followed_id=$2" };
    let _ = db.exec(sql, &[u.into(), t.into()]).await;
    let n = db.opt("SELECT COUNT(*) AS n FROM user_follows WHERE followed_id=$1", &[t.into()]).await.and_then(|r| r.i("n")).unwrap_or(0);
    if following {
        notify::create(&req.app, t, Some(u), "follow", None, None).await;
    }
    Ok(Reply::ok(json!({ "followed_id": t, "following": following, "follower_count": n })))
}

pub async fn follow_mute(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let (u, t) = (uid(&user), target(&req)?);
    let muted = tobool(req.json.get("muted"));
    let db = &req.app.db;
    if db.opt("SELECT follower_id FROM user_follows WHERE follower_id=$1 AND followed_id=$2", &[u.into(), t.into()]).await.is_none() {
        return Err(Reply::err(404, "You are not following this user."));
    }
    let _ = db.exec("UPDATE user_follows SET notifications_muted=$1 WHERE follower_id=$2 AND followed_id=$3", &[muted.into(), u.into(), t.into()]).await;
    Ok(Reply::ok(json!({ "followed_id": t, "notifications_muted": muted })))
}

pub async fn friend_request(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    req.app.rate_check(&format!("friend_request:{u}"), 30, 3600).await?;
    let t = target(&req)?;
    if u == t {
        return Err(Reply::err(400, "You cannot friend yourself."));
    }
    if notify::is_blocked_either_way(&req.app, u, t).await {
        return Err(Reply::err(403, "You cannot send a friend request to this user."));
    }
    if !user_exists(&req, t).await {
        return Err(Reply::err(400, "User not found."));
    }
    let db = &req.app.db;
    let existing = db.opt(&format!("SELECT * FROM friend_requests WHERE (requester_id=$1 AND addressee_id=$2) OR (requester_id=$2 AND addressee_id=$1) {FR_ORDER} LIMIT 1"), &[u.into(), t.into()]).await;
    let (status, row) = match existing {
        Some(e) if e.s("status").as_deref() == Some("accepted") => ("friends", Some(e)),
        Some(mut e) if e.s("status").as_deref() == Some("pending") => {
            if e.i("requester_id") == Some(t) {
                let _ = db.exec("UPDATE friend_requests SET status='accepted', responded_at=CURRENT_TIMESTAMP WHERE id=$1", &[e.i("id").unwrap_or(0).into()]).await;
                e["status"] = json!("accepted");
                ("friends", Some(e))
            } else {
                ("pending_out", Some(e))
            }
        }
        Some(e) => {
            let id = e.i("id").unwrap_or(0);
            let _ = db.exec("UPDATE friend_requests SET requester_id=$1, addressee_id=$2, status='pending', created_at=CURRENT_TIMESTAMP, responded_at=NULL WHERE id=$3", &[u.into(), t.into(), id.into()]).await;
            ("pending_out", db.opt("SELECT * FROM friend_requests WHERE id=$1", &[id.into()]).await)
        }
        None => {
            let id = db.opt("INSERT INTO friend_requests (requester_id, addressee_id) VALUES ($1, $2) RETURNING id", &[u.into(), t.into()]).await.and_then(|r| r.i("id")).unwrap_or(0);
            ("pending_out", db.opt("SELECT * FROM friend_requests WHERE id=$1", &[id.into()]).await)
        }
    };
    notify::create(&req.app, t, Some(u), "friend_request", None, None).await;
    Ok(Reply::ok(json!({ "status": status, "request": row })))
}

pub async fn friend_requests(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    let fetch = |own: &'static str, other: &'static str| {
        let req = &req;
        async move {
            let rows = req
                .app
                .db
                .all(
                    &format!(
                        "SELECT fr.*, u.id AS user_id, u.username, u.display_name, u.bio, u.avatar_path, u.profile_color, u.public_profile, u.last_seen_at \
                         FROM friend_requests fr JOIN users u ON u.id=fr.{other} WHERE fr.{own}=$1 AND fr.status='pending' ORDER BY fr.created_at DESC LIMIT 100"
                    ),
                    &[u.into()],
                )
                .await;
            rows.into_iter()
                .map(|mut r| {
                    let public = tobool(r.get("public_profile"));
                    r["public_profile"] = json!(public);
                    r["is_online"] = json!(tobool(r.get("is_online")));
                    let mut nested = json!({ "id": r["user_id"], "public_profile": public });
                    for k in ["username", "display_name", "bio", "avatar_path", "profile_color", "last_seen_at"] {
                        if let Some(v) = r.get(k).filter(|v| !v.is_null()) {
                            nested[k] = v.clone();
                        }
                    }
                    r["user"] = req.with_user_urls(nested);
                    r
                })
                .collect::<Vec<_>>()
        }
    };
    let incoming = fetch("addressee_id", "requester_id").await;
    let outgoing = fetch("requester_id", "addressee_id").await;
    Ok(Reply::ok(json!({ "incoming": incoming, "outgoing": outgoing })))
}

pub async fn respond_friend_request(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    let Some(rid) = req.pi("request_id") else { return Err(Reply::err(404, "Friend request not found.")) };
    let action = req.js("action").unwrap_or_default();
    let next = match action.as_str() {
        "accept" => "accepted",
        "decline" => "declined",
        "cancel" => "cancelled",
        _ => return Err(Reply::err(400, "Action must be accept, decline, or cancel.")),
    };
    let db = &req.app.db;
    let col = if action == "cancel" { "requester_id" } else { "addressee_id" };
    let mut row = db
        .opt(&format!("SELECT * FROM friend_requests WHERE id=$1 AND {col}=$2 AND status='pending'"), &[rid.into(), u.into()])
        .await
        .ok_or_else(|| Reply::err(404, "Friend request not found."))?;
    let _ = db.exec("UPDATE friend_requests SET status=$1, responded_at=CURRENT_TIMESTAMP WHERE id=$2", &[next.into(), rid.into()]).await;
    row["status"] = json!(next);
    if next == "accepted" {
        notify::create(&req.app, row.i("requester_id").unwrap_or(0), Some(u), "friend_accept", None, None).await;
    }
    Ok(Reply::ok(json!({ "request": row })))
}

pub async fn my_friends(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    let f: Vec<Value> = profile_friends(&req, u, Some(u), 80).await.into_iter().map(|r| req.with_user_urls(r)).collect();
    Ok(Reply::ok(json!({ "friends": f })))
}

async fn follow_list(req: Req, join_col: &str, where_col: &str) -> R<Reply> {
    let viewer = req.viewer().await;
    let t = target(&req)?;
    let rows = req
        .app
        .db
        .all(
            &format!(
                "SELECT u.id, u.username, CASE WHEN u.public_profile OR u.id::text=$1 THEN u.display_name ELSE u.username END AS display_name, \
                   CASE WHEN u.public_profile OR u.id::text=$1 THEN u.bio ELSE NULL END AS bio, CASE WHEN u.public_profile OR u.id::text=$1 THEN u.avatar_path ELSE NULL END AS avatar_path, \
                   u.profile_color, u.public_profile, u.last_seen_at FROM user_follows f JOIN users u ON u.id = f.{join_col} WHERE f.{where_col}=$2 ORDER BY f.created_at DESC LIMIT 200"
            ),
            &[viewer.unwrap_or(0).to_string().into(), t.into()],
        )
        .await;
    let out: Vec<Value> = rows.into_iter().map(|r| req.with_user_urls(decode_user(r))).collect();
    Ok(Reply::ok(json!({ "users": out })))
}

pub async fn followers(req: Req) -> R<Reply> {
    follow_list(req, "follower_id", "followed_id").await
}

pub async fn following(req: Req) -> R<Reply> {
    follow_list(req, "followed_id", "follower_id").await
}

pub async fn user_friends(req: Req) -> R<Reply> {
    let viewer = req.viewer().await;
    let t = target(&req)?;
    let f: Vec<Value> = profile_friends(&req, t, viewer, 80).await.into_iter().map(|r| req.with_user_urls(r)).collect();
    Ok(Reply::ok(json!({ "friends": f })))
}

pub async fn block(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    req.app.rate_check(&format!("block_user:{u}"), 60, 3600).await?;
    let t = target(&req)?;
    let kind = req.js("kind").unwrap_or_default();
    if kind != "block" && kind != "mute" {
        return Err(Reply::err(400, "kind must be block or mute."));
    }
    if u == t {
        return Err(Reply::err(400, "You cannot block or mute yourself."));
    }
    if !user_exists(&req, t).await {
        return Err(Reply::err(400, "User not found."));
    }
    let active = tobool(req.json.get("active"));
    let sql = if active { "INSERT INTO user_blocks (blocker_id, blocked_id, kind) VALUES ($1, $2, $3) ON CONFLICT (blocker_id, blocked_id, kind) DO NOTHING" } else { "DELETE FROM user_blocks WHERE blocker_id=$1 AND blocked_id=$2 AND kind=$3" };
    let _ = req.app.db.exec(sql, &[u.into(), t.into(), kind.as_str().into()]).await;
    Ok(Reply::ok(json!({ "blocked_id": t, "kind": kind, "active": active })))
}

pub async fn my_blocks(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let rows = req
        .app
        .db
        .all("SELECT ub.kind, ub.created_at, u.id, u.username, u.display_name, u.avatar_path, u.profile_color FROM user_blocks ub JOIN users u ON u.id = ub.blocked_id WHERE ub.blocker_id=$1 ORDER BY ub.created_at DESC", &[uid(&user).into()])
        .await;
    let out: Vec<Value> = rows
        .into_iter()
        .map(|mut r| {
            let o = r.as_object_mut().unwrap();
            let (kind, created) = (o.remove("kind"), o.remove("created_at"));
            json!({ "kind": kind, "created_at": created, "user": req.with_user_urls(decode_user(r)) })
        })
        .collect();
    Ok(Reply::ok(json!({ "blocks": out })))
}
