//! Settings from the environment (port of config.lua; same variable names and defaults).

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}
fn env_or(name: &str, default: &str) -> String {
    env(name).unwrap_or_else(|| default.to_string())
}
fn env_i(name: &str, default: i64) -> i64 {
    env(name).and_then(|v| v.trim().parse().ok()).unwrap_or(default)
}
fn env_b(name: &str, default: bool) -> bool {
    env(name).map(|v| matches!(v.to_lowercase().as_str(), "1" | "true" | "yes" | "on")).unwrap_or(default)
}
fn env_csv(name: &str) -> Vec<String> {
    env(name).map(|v| v.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()).unwrap_or_default()
}

#[derive(Clone, Debug)]
pub struct Settings {
    pub db_host: String,
    pub db_port: u16,
    pub db_user: String,
    pub db_password: String,
    pub db_name: String,
    pub db_pool_size: usize,
    pub session_secret: String,
    pub api_token_ttl_seconds: i64,
    pub cors_allowed_origins: Vec<String>,
    pub cors_allow_origin_regex: String,
    pub trusted_hosts: Vec<String>,
    pub trusted_proxy_cidrs: Vec<String>,
    pub pages_public_url: String,
    pub public_origin: String,
    pub digest_send_weekday: i64,
    pub digest_send_hour: i64,
    pub uploads_dir: String,
    pub hot_dir: String,
    pub hot_max_gb: i64,
    pub hot_min_free_gb: i64,
    pub storage_backend: String,
    pub max_upload_bytes: i64,
    pub upload_rate_limit_per_hour: i64,
    pub analyze_rate_limit_per_hour: i64,
    pub media_page_limit: i64,
    pub max_tags_per_upload: i64,
    pub max_tag_length: i64,
    pub visual_phash_max_distance: i64,
    pub visual_dhash_max_distance: i64,
    pub dedup_scan_window_days: i64,
    pub host: String,
    pub port: u16,
    pub db_schema: String,
    pub ai_enabled: bool,
    pub ai_provider: String,
    pub ai_api_key: String,
    pub ai_base_url: String,
    pub ai_ollama_base_url: String,
    pub ai_model: String,
    pub ai_ollama_model: String,
    pub ai_timeout_seconds: i64,
    pub discord_bot_token: String,
    pub ai_training_examples_limit: i64,
    pub telemetry_enabled: bool,
    pub telemetry_retention_days: i64,
    pub deleted_media_retention_days: i64,
    pub deleted_media_purge_enabled: bool,
    pub cache_orphan_sweep_enabled: bool,
    pub media_expiry_sweep_enabled: bool,
    pub thumb_backfill_sweep_enabled: bool,
    pub media_warmer_enabled: bool,
    pub transcode_cleanup_enabled: bool,
    pub vaapi_device: String,
    pub exec_concurrency: usize,
    pub vapid_subject: String,
    pub smtp_host: String,
    pub smtp_port: u16,
    pub smtp_username: String,
    pub smtp_password: String,
    pub smtp_from_email: String,
    pub smtp_use_tls: bool,
    pub gh_token: String,
    pub static_dir: String,
}

impl Settings {
    pub fn load() -> Self {
        let has_openai = env("GALLERY_AI_API_KEY").or(env("OPENAI_API_KEY")).is_some();
        let ai_any = has_openai || env("GALLERY_GEMINI_API_KEY").is_some() || env("GALLERY_OLLAMA_MODEL").is_some();
        let port = env_i("GALLERY_HTTP_PORT", 8788) as u16;
        Settings {
            db_host: env("GALLERY_DB_HOST").or(env("DB_HOST")).unwrap_or_else(|| "127.0.0.1".into()),
            db_port: env_i("GALLERY_PG_PORT", env_i("GALLERY_DB_PORT_PG", 5432)) as u16,
            db_user: env("GALLERY_DB_USER").or(env("DB_USER")).unwrap_or_else(|| "botuser".into()),
            db_password: env("GALLERY_DB_PASSWORD").or(env("DB_PASSWORD")).unwrap_or_default(),
            db_name: env_or("GALLERY_DB_SCHEMA", "image_gallery"),
            // One async process replaces 4 Lua workers x 6 connections.
            db_pool_size: env_i("GALLERY_DB_POOL_SIZE", 24).max(1) as usize,
            session_secret: env_or("GALLERY_SESSION_SECRET", ""),
            api_token_ttl_seconds: env_i("GALLERY_API_TOKEN_TTL_SECONDS", 1_209_600),
            cors_allowed_origins: env_csv("GALLERY_CORS_ALLOWED_ORIGINS"),
            cors_allow_origin_regex: env_or("GALLERY_CORS_ALLOW_ORIGIN_REGEX", ""),
            trusted_hosts: env_csv("GALLERY_TRUSTED_HOSTS"),
            trusted_proxy_cidrs: env_csv("GALLERY_TRUSTED_PROXY_CIDRS"),
            pages_public_url: env_or("GALLERY_PAGES_PUBLIC_URL", "https://heavenlyxenusvr.github.io/Nyxframe/"),
            public_origin: env("GALLERY_CLOUDFLARE_PUBLIC_URL").unwrap_or_else(|| format!("http://localhost:{port}")),
            digest_send_weekday: env_i("GALLERY_DIGEST_SEND_WEEKDAY", 2),
            digest_send_hour: env_i("GALLERY_DIGEST_SEND_HOUR", 15),
            uploads_dir: env_or("GALLERY_UPLOADS_DIR", "../uploads").trim_end_matches('/').to_string(),
            hot_dir: env_or("GALLERY_HOT_DIR", "").trim_end_matches('/').to_string(),
            hot_max_gb: env_i("GALLERY_HOT_MAX_GB", 25).max(1),
            hot_min_free_gb: env_i("GALLERY_HOT_MIN_FREE_GB", 15).max(1),
            storage_backend: env_or("GALLERY_STORAGE_BACKEND", "database"),
            max_upload_bytes: env_i("GALLERY_MAX_UPLOAD_BYTES", 3 * 1024 * 1024 * 1024),
            upload_rate_limit_per_hour: env_i("GALLERY_UPLOAD_RATE_LIMIT_PER_HOUR", 60).max(1),
            analyze_rate_limit_per_hour: env_i("GALLERY_ANALYZE_RATE_LIMIT_PER_HOUR", 120).max(1),
            media_page_limit: env_i("GALLERY_MEDIA_PAGE_LIMIT", 100).clamp(1, 200),
            max_tags_per_upload: env_i("GALLERY_MAX_TAGS_PER_UPLOAD", 12).clamp(1, 50),
            max_tag_length: env_i("GALLERY_MAX_TAG_LENGTH", 32).clamp(8, 80),
            visual_phash_max_distance: env_i("GALLERY_VISUAL_PHASH_MAX_DISTANCE", 10),
            visual_dhash_max_distance: env_i("GALLERY_VISUAL_DHASH_MAX_DISTANCE", 14),
            dedup_scan_window_days: env_i("GALLERY_DEDUP_SCAN_WINDOW_DAYS", 90),
            host: env_or("GALLERY_HTTP_HOST", "0.0.0.0"),
            port,
            db_schema: env_or("GALLERY_DB_SCHEMA", "image_gallery"),
            ai_enabled: env_b("GALLERY_AI_ENABLED", ai_any),
            ai_provider: env("GALLERY_AI_PROVIDER").unwrap_or_else(|| if has_openai { "openai".into() } else { "ollama".into() }),
            ai_api_key: env("GALLERY_AI_API_KEY").or(env("OPENAI_API_KEY")).or(env("GALLERY_GEMINI_API_KEY")).unwrap_or_default(),
            ai_base_url: env("GALLERY_AI_BASE_URL").or(env("OPENAI_BASE_URL")).unwrap_or_else(|| "https://api.openai.com/v1".into()).trim_end_matches('/').to_string(),
            ai_ollama_base_url: env_or("GALLERY_OLLAMA_BASE_URL", "http://127.0.0.1:11434"),
            ai_model: env("GALLERY_GEMINI_MODEL").or(env("GEMINI_MODEL")).or(env("GALLERY_AI_MODEL")).unwrap_or_else(|| "gpt-4o-mini".into()),
            ai_ollama_model: env_or("GALLERY_OLLAMA_MODEL", "llava"),
            ai_timeout_seconds: env_i("GALLERY_AI_TIMEOUT_SECONDS", 45),
            discord_bot_token: env_or("GALLERY_DISCORD_BOT_TOKEN", ""),
            ai_training_examples_limit: env_i("GALLERY_AI_TRAINING_EXAMPLES_LIMIT", 300).clamp(0, 1000),
            telemetry_enabled: env_b("GALLERY_TELEMETRY_ENABLED", true),
            telemetry_retention_days: env_i("GALLERY_TELEMETRY_RETENTION_DAYS", 14).max(1),
            deleted_media_retention_days: env_i("GALLERY_DELETED_MEDIA_RETENTION_DAYS", 10).max(1),
            deleted_media_purge_enabled: env_b("GALLERY_ENABLE_DELETED_MEDIA_PURGE", true),
            cache_orphan_sweep_enabled: env_b("GALLERY_ENABLE_CACHE_ORPHAN_SWEEP", true),
            media_expiry_sweep_enabled: env_b("GALLERY_ENABLE_MEDIA_EXPIRY_SWEEP", true),
            thumb_backfill_sweep_enabled: env_b("GALLERY_ENABLE_THUMB_BACKFILL_SWEEP", true),
            media_warmer_enabled: env_b("GALLERY_ENABLE_MEDIA_WARMER", true),
            transcode_cleanup_enabled: env_b("GALLERY_ENABLE_TRANSCODE_CLEANUP", true),
            vaapi_device: env_or("GALLERY_VAAPI_DEVICE", "/dev/dri/renderD128"),
            exec_concurrency: env_i("GALLERY_EXEC_CONCURRENCY", 1).max(1) as usize,
            vapid_subject: env_or("GALLERY_VAPID_SUBJECT", "mailto:admin@localhost"),
            smtp_host: env_or("SMTP_HOST", ""),
            smtp_port: env_i("SMTP_PORT", 587) as u16,
            smtp_username: env_or("SMTP_USERNAME", ""),
            smtp_password: env_or("SMTP_PASSWORD", ""),
            smtp_from_email: env_or("SMTP_FROM_EMAIL", ""),
            smtp_use_tls: env_b("SMTP_USE_TLS", true),
            gh_token: env_or("GH_TOKEN", ""),
            static_dir: env_or("GALLERY_STATIC_DIR", "/static"),
        }
    }
}
