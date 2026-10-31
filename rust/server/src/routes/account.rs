//! Health/status, auth (register/login/2FA/logout), the signed-in account
//! (me, profile, settings, avatar, age, password, export, Discord
//! verification), TOTP and API keys.

use crate::app::{self, is_site_owner, uid, with_derived_accent};
use crate::auth;
use crate::db::{J, P};
use crate::http::{R, Reply, Req};
use crate::util::{cut, iso_now, tobool};
use serde_json::{Value, json};

const LOOKS: &str = include_str!("../../assets/gallery_looks.json");

fn user_out(req: &Req, user: Value) -> Value {
    let mut u = with_derived_accent(user);
    u["site_owner"] = json!(is_site_owner(&u));
    req.with_user_urls(u)
}

/// Re-read the account after a write and answer `{ user }`.
async fn refreshed(req: &Req, id: i64) -> R<Reply> {
    req.app.invalidate_user(id);
    let u = req.app.get_user(id).await.ok_or_else(|| Reply::err(404, "Account not found."))?;
    Ok(Reply::ok(json!({ "user": user_out(req, u) })))
}

// ---- health -------------------------------------------------------------------------------
pub async fn health(req: Req) -> R<Reply> {
    let s = &req.app.settings;
    Ok(Reply::ok(json!({
        "ok": true,
        "schema": s.db_schema,
        "storage_backend": s.storage_backend,
        "max_upload_bytes": s.max_upload_bytes,
        "media_page_limit": s.media_page_limit,
        "max_tags_per_upload": s.max_tags_per_upload,
        "request_id": req.header("x-request-id").unwrap_or(""),
        "server_time": iso_now(),
    })))
}

pub async fn live_checks(req: Req) -> R<Reply> {
    let s = req.app.settings.clone();
    if req.app.db.one("SELECT now() AS now", &[]).await.ok().flatten().is_none() {
        return Ok(Reply::ok(json!({
            "ok": false, "status": "offline", "backend": "image_gallery",
            "checks": [{ "id": "db", "label": "Database reachable", "ok": false, "severity": "error", "detail": "Database is unreachable." }],
            "check_map": { "api": true, "db": false },
            "snapshot": [],
            "storage_backend": s.storage_backend, "max_upload_bytes": s.max_upload_bytes, "media_page_limit": s.media_page_limit,
            "server_time": iso_now(),
        })));
    }
    let mut checks = vec![
        json!({ "id": "api", "label": "API reachable", "ok": true, "detail": "Backend responded." }),
        json!({ "id": "db", "label": "Database reachable", "ok": true, "detail": format!("Schema {} responded.", s.db_schema) }),
    ];
    if let Some(v) = req.viewer().await {
        let ok = req.app.get_user(v).await.is_some();
        checks.push(json!({ "id": "session", "label": "Login session", "ok": ok, "detail": if ok { "Signed in." } else { "Token is invalid or account is gone." } }));
    }
    let map: serde_json::Map<String, Value> = checks.iter().map(|c| (c["id"].as_str().unwrap_or("").to_string(), c["ok"].clone())).collect();
    Ok(Reply::ok(json!({
        "ok": true, "status": "ok", "backend": "image_gallery",
        "checks": checks, "check_map": map, "snapshot": {},
        "storage_backend": s.storage_backend, "max_upload_bytes": s.max_upload_bytes, "media_page_limit": s.media_page_limit,
        "server_time": iso_now(),
    })))
}

pub async fn public_status(req: Req) -> R<Reply> {
    let db_ok = req.app.db.one("SELECT 1 AS ok", &[]).await.ok().flatten().is_some();
    let mut incidents = req.app.db.all("SELECT id, title, description, severity, started_at, resolved_at FROM status_incidents ORDER BY started_at DESC LIMIT 20", &[]).await;
    let mut active = 0;
    for r in &mut incidents {
        let resolved = !r["resolved_at"].is_null();
        r["resolved"] = json!(resolved);
        if !resolved {
            active += 1;
        }
    }
    Ok(Reply::ok(json!({
        "ok": db_ok && active == 0,
        "database_reachable": db_ok,
        "active_incident_count": active,
        "incidents": incidents,
        "server_time": iso_now(),
    })))
}

// ---- auth -----------------------------------------------------------------------------------
fn normalize_username(u: &str) -> String {
    cut(&u.trim().to_lowercase(), 40)
}

pub async fn register(req: Req) -> R<Reply> {
    let app = req.app.clone();
    app.rate_check(&format!("register:{}", req.client_ip), 10, 3600).await?;
    let username = normalize_username(&req.js("username").unwrap_or_default());
    let password = req.js("password").unwrap_or_default();
    let email = req.js("email").map(|e| e.trim().to_lowercase()).filter(|e| !e.is_empty()).map(|e| cut(&e, 255));
    let mut display_name = cut(req.js("display_name").unwrap_or_else(|| username.clone()).trim(), 80);
    if display_name.is_empty() {
        display_name = username.clone();
    }
    if username.is_empty() {
        return Err(Reply::err(400, "Username is required."));
    }
    if username.len() < 3 {
        return Err(Reply::err(400, "Username must be at least 3 characters."));
    }
    if !username.chars().all(|c| c.is_ascii_alphanumeric() || "_.-".contains(c)) {
        return Err(Reply::err(400, "Username may only contain letters, numbers, \".\", \"_\", and \"-\"."));
    }
    if password.len() < 8 {
        return Err(Reply::err(400, "Password must be at least 8 characters."));
    }
    if app.db.opt("SELECT id FROM users WHERE LOWER(username)=$1 OR (LOWER(email)=$2 AND email IS NOT NULL)", &[username.as_str().into(), email.clone().into()]).await.is_some() {
        return Err(Reply::err(409, "That username or email is already taken."));
    }
    let hash = auth::password_hash_async(password).await;
    let row = app
        .db
        .one("INSERT INTO users (username, display_name, password_hash, email) VALUES ($1, $2, $3, $4) RETURNING id", &[username.as_str().into(), display_name.into(), hash.into(), email.into()])
        .await;
    let id = match row {
        Ok(Some(r)) if r.i("id").is_some() => r.i("id").unwrap(),
        other => {
            app.telemetry.record("auth", Some("register"), Some("error"), None, Some(json!({ "username": username })));
            let e = other.err().unwrap_or_else(|| "nil".into());
            return Err(Reply::err(500, format!("Registration failed: {e}")));
        }
    };
    app.telemetry.record("auth", Some("register"), Some("success"), None, Some(json!({ "username": username })));
    app.invalidate_user(id);
    let user = app.get_user(id).await.ok_or_else(|| Reply::err(500, "Registration failed: account missing"))?;
    let token = app.issue_session(&user);
    let body = json!({ "user": req.with_user_urls(user), "token": token, "email_verification_sent": false, "email_error": null });
    Ok(app.with_session(Reply::ok(body), &token))
}

pub async fn login(req: Req) -> R<Reply> {
    let app = req.app.clone();
    let username_raw = cut(req.js("username").unwrap_or_default().trim(), 80);
    let password = req.js("password").unwrap_or_default();
    let ip = req.client_ip.clone();
    let recent = app
        .db
        .opt(
            "SELECT COUNT(*) AS n FROM auth_attempts WHERE successful=false AND created_at >= (now() - interval '15 minutes') AND (ip_address=$1 OR username=$2)",
            &[ip.as_str().into(), username_raw.as_str().into()],
        )
        .await;
    if recent.and_then(|r| r.i("n")).unwrap_or(0) >= 8 {
        return Err(Reply::err(429, "Too many failed login attempts. Try again later."));
    }
    let username = normalize_username(&username_raw);
    let row = app.db.opt("SELECT id, password_hash FROM users WHERE LOWER(username)=$1", &[username.into()]).await;
    let ok = match &row {
        Some(r) => auth::verify_password_async(password, r.s("password_hash").unwrap_or_default()).await,
        None => false,
    };
    let _ = app
        .db
        .exec(
            "INSERT INTO auth_attempts (username, ip_address, successful) VALUES ($1, $2, $3)",
            &[(!username_raw.is_empty()).then(|| username_raw.clone()).into(), cut(&ip, 64).into(), ok.into()],
        )
        .await;
    app.telemetry.count(if ok { "auth_login_success" } else { "auth_login_failure" }, 1);
    if !ok {
        return Err(Reply::err(401, "Invalid username or password."));
    }
    let id = row.and_then(|r| r.i("id")).unwrap_or(0);
    let _ = app.db.exec("UPDATE users SET last_login_at=now(), last_seen_at=now() WHERE id=$1", &[id.into()]).await;
    app.invalidate_user(id);
    let (user, banned) = app.get_user_ban(id).await.ok_or_else(|| Reply::err(401, "Invalid username or password."))?;
    if banned {
        app.telemetry.count("auth_login_banned", 1);
        return Err(Reply::err(403, user.s("ban_reason").unwrap_or_else(|| "Your account has been suspended.".into())));
    }
    if tobool(user.get("totp_enabled")) {
        return Ok(Reply::ok(json!({ "needs_2fa": true, "pending_token": auth::issue_2fa_pending(app.secret(), id) })));
    }
    let token = app.issue_session(&user);
    Ok(app.with_session(Reply::ok(json!({ "user": req.with_user_urls(user), "token": token })), &token))
}

/// Live TOTP code, else consume a matching recovery code.
pub async fn verify_totp_or_recovery(req: &Req, user_id: i64, code: &str) -> bool {
    let db = &req.app.db;
    let Some(row) = db.opt("SELECT totp_secret, totp_enabled_at, totp_recovery_codes FROM users WHERE id=$1", &[user_id.into()]).await else { return false };
    let (Some(secret), false) = (row.s("totp_secret"), row["totp_enabled_at"].is_null()) else { return false };
    if crate::totp::verify_code(&secret, code, crate::util::now()) {
        return true;
    }
    let mut codes: Vec<String> = row.s("totp_recovery_codes").and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
    let stripped = code.trim().to_string();
    for i in 0..codes.len() {
        if auth::verify_password_async(stripped.clone(), codes[i].clone()).await {
            codes.remove(i);
            let _ = db.exec("UPDATE users SET totp_recovery_codes=$1 WHERE id=$2", &[json!(codes).to_string().into(), user_id.into()]).await;
            return true;
        }
    }
    false
}

pub async fn verify_2fa(req: Req) -> R<Reply> {
    let app = req.app.clone();
    let code = req.js("code").unwrap_or_default();
    let Some(user_id) = req.js("pending_token").and_then(|t| auth::verify_2fa_pending(app.secret(), &t)) else {
        return Err(Reply::err(401, "Your sign-in attempt expired. Log in again."));
    };
    app.rate_check(&format!("2fa-verify:{user_id}"), 10, 600).await?;
    if !verify_totp_or_recovery(&req, user_id, &code).await {
        return Err(Reply::err(400, "Invalid authentication code."));
    }
    let user = app.get_user(user_id).await.ok_or_else(|| Reply::err(404, "Account not found."))?;
    let token = app.issue_session(&user);
    Ok(app.with_session(Reply::ok(json!({ "user": req.with_user_urls(user), "token": token })), &token))
}

pub async fn logout(req: Req) -> R<Reply> {
    Ok(Reply::ok(json!({ "ok": true })).cookie(req.app.session_cookie("", Some(0))))
}

pub async fn me(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    Ok(Reply::ok(json!({ "user": user_out(&req, user) })))
}

pub async fn update_profile(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let p = crate::user_settings::clean_profile_updates(&req.json).map_err(|e| Reply::err(400, e))?;
    let id = uid(&user);
    let _ = req
        .app
        .db
        .exec(
            "UPDATE users SET display_name=$1, bio=$2, profile_quote=$3, website_url=$4, location_label=$5, profile_headline=$6, featured_tags=$7, profile_color=$8, \
             public_profile=$9, show_liked_count=$10, show_collections=$11, show_recent_uploads=$12, show_friends=$13 WHERE id=$14",
            &[
                p.display_name.into(),
                p.bio.into(),
                p.profile_quote.into(),
                p.website_url.into(),
                p.location_label.into(),
                p.profile_headline.into(),
                p.featured_tags.into(),
                p.profile_color.into(),
                p.public_profile.into(),
                p.show_liked_count.into(),
                p.show_collections.into(),
                p.show_recent_uploads.into(),
                p.show_friends.into(),
                id.into(),
            ],
        )
        .await;
    refreshed(&req, id).await
}

pub async fn update_settings(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let filtered: serde_json::Map<String, Value> = req.json.as_object().map(|o| o.iter().filter(|(_, v)| !v.is_null()).map(|(k, v)| (k.clone(), v.clone())).collect()).unwrap_or_default();
    let cleaned = crate::user_settings::clean_user_settings(&filtered, &user["user_settings"]).map_err(|e| Reply::err(400, e))?;
    let id = uid(&user);
    let _ = req.app.db.exec("UPDATE users SET user_settings=$1 WHERE id=$2", &[cleaned.to_string().into(), id.into()]).await;
    refreshed(&req, id).await
}

pub async fn appearance_presets(req: Req) -> R<Reply> {
    req.current_user().await?;
    Ok(Reply::ok(serde_json::from_str(LOOKS).unwrap_or_else(|_| json!({ "gallery": [], "profile": [] }))))
}

pub async fn update_avatar(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = uid(&user);
    let Some(f) = req.file("file").filter(|f| !f.data.is_empty()) else { return Err(Reply::err(400, "Upload is empty.")) };
    if f.data.len() > 5 * 1024 * 1024 {
        return Err(Reply::err(413, "Avatars must be 5MB or smaller."));
    }
    req.app.rate_check(&format!("avatar:{id}"), 20, 3600).await?;
    let Some((mime, "image")) = crate::sniff::sniff_magic(&f.data) else { return Err(Reply::err(400, "Avatar must be an image.")) };
    let name = crate::sniff::clean_filename(&f.filename, "avatar");
    if crate::sniff::safe_extension(&name, mime).is_none() {
        return Err(Reply::err(400, "Unsupported file extension."));
    }
    let sha = crate::media_files::sha256_bytes(&f.data);
    crate::media_files::save_avatar_file(&req.app.db, id, &f.data, &sha, mime, &name).await.map_err(|e| Reply::err(500, format!("Avatar upload failed: {e}")))?;
    refreshed(&req, id).await
}

pub async fn verify_age(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    if !tobool(req.json.get("confirm_over_18")) {
        return Err(Reply::err(400, "Confirm that you are 18 or older to continue."));
    }
    let b = req.js("birthdate").unwrap_or_default();
    let shape_ok = b.len() == 10 && b.chars().enumerate().all(|(i, c)| if i == 4 || i == 7 { c == '-' } else { c.is_ascii_digit() });
    if !shape_ok {
        return Err(Reply::err(400, "Birthdate must use YYYY-MM-DD."));
    }
    let Ok(Some(row)) = req.app.db.one("SELECT ($1::date > CURRENT_DATE) AS in_future, date_part('year', age(CURRENT_DATE, $1::date)) AS age_years", &[P::Text(b.clone())]).await else {
        return Err(Reply::err(400, "Invalid birthdate."));
    };
    if tobool(row.get("in_future")) {
        return Err(Reply::err(400, "Birthdate cannot be in the future."));
    }
    if row.i("age_years").unwrap_or(0) < 18 {
        return Err(Reply::err(403, "You must be 18 or older to view 18+ posts."));
    }
    let id = uid(&user);
    let _ = req.app.db.exec("UPDATE users SET birthdate=$1::date, age_verified_at=now(), adult_content_consent=true WHERE id=$2", &[P::Text(b), id.into()]).await;
    refreshed(&req, id).await
}

pub async fn change_password(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let old = req.js("old_password").unwrap_or_default();
    let new = req.js("new_password").unwrap_or_default();
    if new.len() < 8 {
        return Err(Reply::err(400, "New password must be at least 8 characters."));
    }
    let id = uid(&user);
    let stored = req.app.db.opt("SELECT password_hash FROM users WHERE id=$1", &[id.into()]).await.and_then(|r| r.s("password_hash"));
    let ok = match stored {
        Some(h) => auth::verify_password_async(old, h).await,
        None => false,
    };
    if !ok {
        return Err(Reply::err(401, "Current password is incorrect."));
    }
    let h = auth::password_hash_async(new).await;
    let _ = req.app.db.exec("UPDATE users SET password_hash=$1 WHERE id=$2", &[h.into(), id.into()]).await;
    Ok(Reply::ok(json!({ "ok": true })))
}

pub async fn export_account(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = uid(&user);
    let db = &req.app.db;
    let q = |sql: &'static str| async move { db.all(sql, &[id.into()]).await };
    let payload = json!({
        "exported_at": iso_now(),
        "profile": req.app.get_user(id).await,
        "media": q("SELECT id, title, description, tags, media_kind, visibility, views, downloads, created_at FROM media_items WHERE user_id=$1 ORDER BY created_at DESC").await,
        "collections": q("SELECT id, name, description, is_public, is_smart, created_at FROM media_collections WHERE user_id=$1 ORDER BY created_at DESC").await,
        "following": q("SELECT u.id, u.username FROM user_follows f JOIN users u ON u.id = f.followed_id WHERE f.follower_id=$1").await,
        "followers": q("SELECT u.id, u.username FROM user_follows f JOIN users u ON u.id = f.follower_id WHERE f.followed_id=$1").await,
        "likes": q("SELECT media_id FROM media_likes WHERE user_id=$1").await,
        "bookmarks": q("SELECT media_id FROM media_bookmarks WHERE user_id=$1").await,
        "comments": q("SELECT media_id, body, created_at FROM media_comments WHERE user_id=$1 ORDER BY created_at DESC").await,
        "saved_searches": q("SELECT name, filter_json, created_at FROM saved_searches WHERE user_id=$1 ORDER BY created_at DESC").await,
    });
    Ok(Reply::text(200, payload.to_string(), "application/json; charset=utf-8").header("Content-Disposition", format!("attachment; filename=\"image-gallery-export-{id}.json\"")))
}

// ---- Discord verification ----------------------------------------------------------------------
pub async fn discord_verify_status(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let pending = req.app.db.opt("SELECT method, expires_at, (now() > expires_at) AS is_expired FROM discord_verifications WHERE user_id=$1", &[uid(&user).into()]).await;
    let pending = pending.filter(|p| !tobool(p.get("is_expired"))).map(|p| json!({ "method": p["method"], "expires_at": p["expires_at"] }));
    Ok(Reply::ok(json!({
        "verified": !user["discord_verified_at"].is_null(),
        "discord_username": user["discord_username"],
        "discord_user_id": user["discord_user_id"],
        "pending": pending,
        "dm_available": crate::discord::bot_enabled(&req.app),
    })))
}

pub async fn discord_verify_start(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = uid(&user);
    req.app.rate_check(&format!("discord_verify:{id}"), 5, 3600).await?;
    let method = req.js("method").unwrap_or_default();
    if method != "dm" && method != "webhook" {
        return Err(Reply::err(400, "method must be \"dm\" or \"webhook\"."));
    }
    let code = auth::verification_code();
    let target = if method == "dm" {
        if !crate::discord::bot_enabled(&req.app) {
            return Err(Reply::err(400, "Discord verification isn't configured on this server yet."));
        }
        let t = req.js("discord_user_id").unwrap_or_default();
        if t.is_empty() || !t.chars().all(|c| c.is_ascii_digit()) {
            return Err(Reply::err(
                400,
                "Enter a valid Discord User ID (numbers only -- in Discord, enable Settings > Advanced > Developer Mode, then right-click your name and Copy User ID).",
            ));
        }
        crate::discord::send_dm(&req.app, &t, &format!("Your Nyxframe verification code is: {code}\nIt expires in 10 minutes.")).await.map_err(|e| Reply::err(400, e))?;
        t
    } else {
        let url = user["user_settings"].get("discord_webhook_url").and_then(Value::as_str).unwrap_or("").to_string();
        if !crate::discord::webhook_valid(&url) {
            return Err(Reply::err(400, "Set a Discord webhook URL under Settings > Integrations first."));
        }
        crate::discord::webhook_send(
            &req.app,
            &url,
            json!([{ "title": "Nyxframe verification code", "description": format!("Code: **{code}**\nExpires in 10 minutes. Enter it on the Settings page."), "color": 0x37c9a7 }]),
        );
        url
    };
    let _ = req
        .app
        .db
        .exec(
            "INSERT INTO discord_verifications (user_id, code_hash, method, target, attempts, expires_at) VALUES ($1, $2, $3, $4, 0, now() + interval '10 minutes') \
             ON CONFLICT (user_id) DO UPDATE SET code_hash=EXCLUDED.code_hash, method=EXCLUDED.method, target=EXCLUDED.target, attempts=0, expires_at=EXCLUDED.expires_at, created_at=now()",
            &[id.into(), auth::sha256_hex(&code).into(), method.as_str().into(), cut(&target, 255).into()],
        )
        .await;
    Ok(Reply::ok(json!({ "ok": true, "method": method, "expires_in_seconds": 600 })))
}

pub async fn discord_verify_confirm(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = uid(&user);
    let code = req.js("code").unwrap_or_default().trim().to_string();
    if code.is_empty() {
        return Err(Reply::err(400, "Enter the code you received."));
    }
    let db = &req.app.db;
    let Some(p) = db.opt("SELECT method, target, code_hash, attempts, (now() > expires_at) AS is_expired FROM discord_verifications WHERE user_id=$1", &[id.into()]).await else {
        return Err(Reply::err(400, "No verification in progress -- start over."));
    };
    if p.i("attempts").unwrap_or(0) >= 5 || tobool(p.get("is_expired")) {
        let _ = db.exec("DELETE FROM discord_verifications WHERE user_id=$1", &[id.into()]).await;
        return Err(Reply::err(400, "That code expired or had too many incorrect attempts -- start over."));
    }
    if Some(auth::sha256_hex(&code)) != p.s("code_hash").map(|h| h.trim().to_string()) {
        let _ = db.exec("UPDATE discord_verifications SET attempts=attempts+1 WHERE user_id=$1", &[id.into()]).await;
        return Err(Reply::err(400, "Incorrect code."));
    }
    if p.s("method").as_deref() == Some("dm") {
        let target = p.s("target").unwrap_or_default();
        let name = crate::discord::get_user(&req.app, &target).await;
        let _ = db.exec("UPDATE users SET discord_user_id=$1, discord_username=$2, discord_verified_at=now() WHERE id=$3", &[target.into(), name.into(), id.into()]).await;
    } else {
        let _ = db.exec("UPDATE users SET discord_verified_at=now() WHERE id=$1", &[id.into()]).await;
    }
    let _ = db.exec("DELETE FROM discord_verifications WHERE user_id=$1", &[id.into()]).await;
    refreshed(&req, id).await
}

pub async fn discord_unlink(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = uid(&user);
    let _ = req.app.db.exec("UPDATE users SET discord_user_id=NULL, discord_username=NULL, discord_verified_at=NULL WHERE id=$1", &[id.into()]).await;
    let _ = req.app.db.exec("DELETE FROM discord_verifications WHERE user_id=$1", &[id.into()]).await;
    refreshed(&req, id).await
}

// ---- TOTP ----------------------------------------------------------------------------------------
fn recovery_count(row: &Option<Value>) -> usize {
    row.as_ref().and_then(|r| r.s("totp_recovery_codes")).and_then(|s| serde_json::from_str::<Vec<Value>>(&s).ok()).map(|v| v.len()).unwrap_or(0)
}

pub async fn totp_status(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let row = req.app.db.opt("SELECT totp_enabled_at, totp_recovery_codes FROM users WHERE id=$1", &[uid(&user).into()]).await;
    let enabled = row.as_ref().is_some_and(|r| !r["totp_enabled_at"].is_null());
    Ok(Reply::ok(json!({ "enabled": enabled, "recovery_codes_remaining": recovery_count(&row) })))
}

pub async fn totp_enroll(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let secret = crate::totp::generate_secret();
    let _ = req.app.db.exec("UPDATE users SET totp_secret=$1, totp_enabled_at=NULL WHERE id=$2", &[secret.as_str().into(), uid(&user).into()]).await;
    let uri = crate::totp::provisioning_uri(&secret, &user.s("username").unwrap_or_default(), "Nyxframe");
    Ok(Reply::ok(json!({ "secret": secret, "uri": uri })))
}

pub async fn totp_confirm(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = uid(&user);
    let code = req.js("code").unwrap_or_default();
    let Some(secret) = req.app.db.opt("SELECT totp_secret FROM users WHERE id=$1", &[id.into()]).await.and_then(|r| r.s("totp_secret")) else {
        return Err(Reply::err(400, "Start 2FA setup first."));
    };
    if !crate::totp::verify_code(&secret, &code, crate::util::now()) {
        return Err(Reply::err(400, "Incorrect code. Check your authenticator app and try again."));
    }
    let codes = crate::totp::recovery_codes(8);
    let mut hashed = Vec::with_capacity(codes.len());
    for c in &codes {
        hashed.push(auth::password_hash_async(c.clone()).await);
    }
    let _ = req.app.db.exec("UPDATE users SET totp_enabled_at=now(), totp_recovery_codes=$1 WHERE id=$2", &[json!(hashed).to_string().into(), id.into()]).await;
    req.app.invalidate_user(id);
    Ok(Reply::ok(json!({ "enabled": true, "recovery_codes": codes })))
}

pub async fn totp_disable(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = uid(&user);
    let password = req.js("password").unwrap_or_default();
    let stored = req.app.db.opt("SELECT password_hash FROM users WHERE id=$1", &[id.into()]).await.and_then(|r| r.s("password_hash"));
    let ok = match stored {
        Some(h) => auth::verify_password_async(password, h).await,
        None => false,
    };
    if !ok {
        return Err(Reply::err(400, "Incorrect password."));
    }
    let _ = req.app.db.exec("UPDATE users SET totp_secret=NULL, totp_enabled_at=NULL, totp_recovery_codes=NULL WHERE id=$1", &[id.into()]).await;
    req.app.invalidate_user(id);
    Ok(Reply::ok(json!({ "enabled": false })))
}

// ---- API keys --------------------------------------------------------------------------------------
pub async fn create_api_key(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let label = cut(req.js("label").unwrap_or_else(|| "API key".into()).trim(), 80);
    let raw = format!("{}{}", app::api_key_prefix(), auth::random_hex(24));
    let row = req
        .app
        .db
        .one("INSERT INTO api_keys (user_id, label, token_hash) VALUES ($1, $2, $3) RETURNING id, created_at", &[uid(&user).into(), label.as_str().into(), auth::sha256_hex(&raw).into()])
        .await
        .map_err(|e| Reply::err(500, format!("Could not create API key: {e}")))?
        .ok_or_else(|| Reply::err(500, "Could not create API key: nil"))?;
    Ok(Reply::ok(json!({ "key": raw, "id": row["id"], "label": label, "created_at": row["created_at"] })))
}

pub async fn list_api_keys(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let rows = req.app.db.all("SELECT id, label, created_at, last_used_at, revoked_at FROM api_keys WHERE user_id=$1 ORDER BY created_at DESC", &[uid(&user).into()]).await;
    Ok(Reply::ok(json!({ "api_keys": rows })))
}

pub async fn revoke_api_key(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let Some(kid) = req.pi("key_id") else { return Err(Reply::err(404, "API key not found.")) };
    let _ = req.app.db.exec("UPDATE api_keys SET revoked_at=now() WHERE id=$1 AND user_id=$2 AND revoked_at IS NULL", &[kid.into(), uid(&user).into()]).await;
    Ok(Reply::ok(json!({ "ok": true })))
}
