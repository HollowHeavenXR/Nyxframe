//! Shared state plus the session/user helpers from the top of routes.lua
//! (decode_user, get_user's 5s cache, current_user, auth_optional, API keys).

use crate::auth;
use crate::config::Settings;
use crate::db::{Db, J};
use crate::http::{R, Reply, Req};
use crate::telemetry::Telemetry;
use crate::util::{self, json_list, json_obj, tobool};
use regex::Regex;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub type AppRef = Arc<App>;

pub const SESSION_COOKIE: &str = "image_gallery_session";
pub const SITE_OWNER_EMAIL: &str = "uxzheavenlyyei@icloud.com";
const API_KEY_PREFIX: &str = "gk_";

pub const USER_PUBLIC_COLUMNS: &str = "id, username, display_name, bio, website_url, location_label, profile_headline, \
  featured_tags, profile_color, \
  email, email_verified_at, avatar_path, avatar_file_id, avatar_mime_type, avatar_original_filename, public_profile, \
  show_liked_count, show_collections, show_recent_uploads, show_friends, \
  birthdate, age_verified_at, adult_content_consent, totp_enabled_at, \
  discord_user_id, discord_username, discord_verified_at, \
  user_settings, created_at, updated_at, last_seen_at, \
  banned_at, banned_until, ban_reason";

struct CachedUser {
    at: Instant,
    user: Value,
    ban_active: bool,
}

pub struct App {
    pub settings: Arc<Settings>,
    pub db: Arc<Db>,
    pub telemetry: Arc<Telemetry>,
    pub http: reqwest::Client,
    pub cors_origins: Vec<String>,
    pub tunnel_origin: Option<Regex>,
    pub limiter: crate::ratelimit::Limiter,
    pub started: Instant,
    pub requests: AtomicI64,
    users: Mutex<HashMap<i64, CachedUser>>,
    seen: Mutex<HashMap<i64, Instant>>,
    api_keys_seen: Mutex<HashMap<i64, Instant>>,
}

impl App {
    pub fn new(settings: Settings) -> AppRef {
        let settings = Arc::new(settings);
        let db = Arc::new(Db::new(settings.clone()));
        let mut cors_origins = settings.cors_allowed_origins.clone();
        if cors_origins.is_empty() {
            cors_origins = vec![
                settings.pages_public_url.trim_end_matches('/').to_string(),
                "http://127.0.0.1:8788".into(),
                "http://localhost:8788".into(),
                "http://127.0.0.1:8000".into(),
                "http://localhost:8000".into(),
            ];
        }
        // The Lua build turns any configured origin regex into this fixed
        // tunnel-host allow-list rather than evaluating it.
        let tunnel_origin = (!settings.cors_allow_origin_regex.is_empty())
            .then(|| Regex::new(r"^https://[A-Za-z0-9-]+\.(trycloudflare\.com|ngrok-free\.dev|ngrok\.io|pinggy-free\.link|serveousercontent\.com|lhr\.life)$").unwrap());
        Arc::new(Self {
            telemetry: Arc::new(Telemetry::start(db.clone(), settings.telemetry_enabled)),
            http: reqwest::Client::builder().pool_idle_timeout(Duration::from_secs(90)).timeout(Duration::from_secs(30)).build().expect("http client"),
            cors_origins,
            tunnel_origin,
            limiter: Default::default(),
            started: Instant::now(),
            requests: AtomicI64::new(0),
            users: Mutex::default(),
            seen: Mutex::default(),
            api_keys_seen: Mutex::default(),
            settings,
            db,
        })
    }

    pub fn count_request(&self) {
        self.requests.fetch_add(1, Ordering::Relaxed);
    }

    pub fn secret(&self) -> &str {
        &self.settings.session_secret
    }

    pub fn session_cookie(&self, token: &str, max_age: Option<i64>) -> String {
        let base = format!("{SESSION_COOKIE}={token}; Path=/; HttpOnly; Secure; SameSite=None");
        match max_age {
            Some(a) => format!("{base}; Max-Age={a}"),
            None => base,
        }
    }

    pub fn issue_session(&self, user: &Value) -> String {
        auth::issue_session(self.secret(), user, self.settings.api_token_ttl_seconds)
    }

    /// Session reply headers: the token in the cookie too.
    pub fn with_session(&self, r: Reply, token: &str) -> Reply {
        r.cookie(self.session_cookie(token, Some(self.settings.api_token_ttl_seconds)))
    }

    pub async fn rate_check(&self, key: &str, limit: i64, window: i64) -> R<()> {
        self.limiter.check(&self.db, key, limit, window).await
    }

    // ---- users ----------------------------------------------------------------------------------
    pub fn invalidate_user(&self, id: i64) {
        self.users.lock().unwrap().remove(&id);
    }

    async fn load_user(&self, id: i64) -> Option<(Value, bool)> {
        let sql = format!(
            "SELECT {USER_PUBLIC_COLUMNS}, (banned_at IS NOT NULL AND (banned_until IS NULL OR banned_until > now()::timestamp)) AS __ban_active FROM users WHERE id=$1"
        );
        let mut row = self.db.opt(&sql, &[id.into()]).await?;
        let ban = tobool(row.get("__ban_active"));
        if let Some(o) = row.as_object_mut() {
            o.remove("__ban_active");
        }
        Some((decode_user(row), ban))
    }

    /// get_user(): the public columns, decoded; cached 5s.
    pub async fn get_user(&self, id: i64) -> Option<Value> {
        self.get_user_ban(id).await.map(|(u, _)| u)
    }

    pub async fn get_user_ban(&self, id: i64) -> Option<(Value, bool)> {
        if let Some(c) = self.users.lock().unwrap().get(&id).filter(|c| c.at.elapsed() < Duration::from_secs(5)) {
            return Some((c.user.clone(), c.ban_active));
        }
        let (user, ban) = self.load_user(id).await?;
        let mut m = self.users.lock().unwrap();
        if m.len() >= 500 {
            m.retain(|_, c| c.at.elapsed() < Duration::from_secs(5));
        }
        m.insert(id, CachedUser { at: Instant::now(), user: user.clone(), ban_active: ban });
        Some((user, ban))
    }

    pub async fn viewer_adult_allowed(&self, viewer: Option<i64>) -> bool {
        let Some(v) = viewer else { return false };
        self.get_user(v).await.is_some_and(|u| !u["age_verified_at"].is_null() && tobool(u.get("adult_content_consent")))
    }

    /// last_seen_at refresh, at most once a minute per account.
    pub async fn touch_last_seen(&self, id: i64) {
        {
            let mut m = self.seen.lock().unwrap();
            if m.get(&id).is_some_and(|t| t.elapsed() < Duration::from_secs(60)) {
                return;
            }
            if m.len() > 5000 {
                m.retain(|_, t| t.elapsed() < Duration::from_secs(60));
            }
            m.insert(id, Instant::now());
        }
        let _ = self.db.exec("UPDATE users SET last_seen_at=now() WHERE id=$1 AND (last_seen_at IS NULL OR last_seen_at < now() - interval '60 seconds')", &[id.into()]).await;
    }

    /// `gk_...` read-only API key -> owning user id.
    pub async fn resolve_api_key(&self, raw: &str) -> Option<i64> {
        if !raw.starts_with(API_KEY_PREFIX) {
            return None;
        }
        let row = self.db.opt("SELECT id, user_id FROM api_keys WHERE token_hash=$1 AND revoked_at IS NULL", &[auth::sha256_hex(raw).into()]).await?;
        let key_id = row.i("id")?;
        let stale = {
            let mut m = self.api_keys_seen.lock().unwrap();
            let stale = m.get(&key_id).is_none_or(|t| t.elapsed() >= Duration::from_secs(60));
            if stale {
                m.insert(key_id, Instant::now());
            }
            stale
        };
        if stale {
            let _ = self.db.exec("UPDATE api_keys SET last_used_at=now() WHERE id=$1 AND (last_used_at IS NULL OR last_used_at < now() - interval '60 seconds')", &[key_id.into()]).await;
        }
        row.i("user_id")
    }
}

pub fn api_key_prefix() -> &'static str {
    API_KEY_PREFIX
}

/// decode_user(): bool coercion, featured_tags as a list, user_settings as an object.
pub fn decode_user(mut row: Value) -> Value {
    // Always present (false when the column wasn't selected), like the Lua decode_user.
    for k in ["public_profile", "show_liked_count", "show_collections", "show_recent_uploads", "show_friends", "adult_content_consent"] {
        row[k] = json!(tobool(row.get(k)));
    }
    row["totp_enabled"] = json!(!row["totp_enabled_at"].is_null());
    row["featured_tags"] = json_list(row.get("featured_tags"));
    row["user_settings"] = json_obj(row.get("user_settings"));
    row
}

pub fn is_site_owner(user: &Value) -> bool {
    !user["email_verified_at"].is_null() && user.s("email").unwrap_or_default().to_lowercase() == SITE_OWNER_EMAIL
}

/// accent_contrast_text / accent_gradient on user_settings.
pub fn with_derived_accent(mut user: Value) -> Value {
    let Some(accent) = user["user_settings"].get("accent_color").and_then(Value::as_str).filter(|a| !a.is_empty()).map(str::to_string) else { return user };
    let secondary = user["user_settings"].get("accent_secondary").and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string).unwrap_or_else(|| util::auto_secondary(&accent));
    user["user_settings"]["accent_contrast_text"] = json!(util::contrast_text(&accent));
    user["user_settings"]["accent_gradient"] = json!(util::gradient(&accent, &secondary));
    user
}

impl Req {
    /// Absolute scheme://host for URLs in responses (X-Forwarded-Proto/Host aware).
    pub fn origin(&self) -> String {
        let first = |v: Option<&str>| v.and_then(|v| v.split([',', ' ', '\t']).find(|s| !s.is_empty())).map(str::to_string);
        let proto = first(self.header("x-forwarded-proto")).unwrap_or_else(|| "http".into());
        let host = first(self.header("x-forwarded-host").or(self.header("host"))).unwrap_or_else(|| "localhost".into());
        format!("{proto}://{host}")
    }

    pub fn token(&self) -> Option<String> {
        auth::bearer(self.header("authorization")).or_else(|| self.cookies.get(SESSION_COOKIE).filter(|t| !t.is_empty()).cloned())
    }

    /// Verified session payload {id, username, display_name, exp}.
    pub fn session(&self) -> Option<Value> {
        auth::verify_token(self.app.secret(), &self.token()?)
    }

    fn session_id(&self) -> Option<i64> {
        self.session().and_then(|v| auth::id_of(&v["id"]))
    }

    /// current_user(): a logged-in, existing, unbanned account (or 401/403).
    /// GET requests may use a read-only `?key=` API key instead.
    pub async fn current_user(&self) -> R<Value> {
        let mut id = self.session_id();
        if id.is_none() && self.method == axum::http::Method::GET {
            if let Some(k) = self.q("key") {
                id = self.app.resolve_api_key(&k).await;
            }
        }
        let Some(id) = id else { return Err(Reply::err(401, "Login required")) };
        let Some((user, banned)) = self.app.get_user_ban(id).await else { return Err(Reply::err(401, "Login required")) };
        if banned {
            return Err(Reply::err(403, user.s("ban_reason").unwrap_or_else(|| "Your account has been suspended.".into())));
        }
        self.app.touch_last_seen(id).await;
        Ok(user)
    }

    /// auth_optional(): the viewer's user id, if any (session or `?key=`).
    pub async fn viewer(&self) -> Option<i64> {
        if let Some(id) = self.session_id() {
            self.app.touch_last_seen(id).await;
            return Some(id);
        }
        let id = self.app.resolve_api_key(&self.q("key")?).await?;
        self.app.touch_last_seen(id).await;
        Some(id)
    }

    /// Site-owner gate (verified owner email).
    pub async fn require_site_owner(&self) -> R<Value> {
        let user = self.current_user().await?;
        if !is_site_owner(&user) {
            return Err(Reply::err(403, "Only the verified site owner can use this action."));
        }
        Ok(user)
    }

    /// with_user_urls(): avatar_url + site_owner on a user-shaped row.
    pub fn with_user_urls(&self, mut user: Value) -> Value {
        if user.get("avatar_path").is_some_and(|v| !v.is_null()) {
            if let Some(id) = util::vstr(user.get("id")) {
                user["avatar_url"] = json!(format!("{}/api/users/{id}/avatar", self.origin()));
            }
        }
        user["site_owner"] = json!(is_site_owner(&user));
        user
    }
}

/// Lua `tostring(x)` for a user-id param slot.
pub fn uid(user: &Value) -> i64 {
    user.i("id").unwrap_or(0)
}

