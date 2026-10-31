//! Uploads (port of routes.lua's upload section): direct multipart and
//! chunked sessions (streamed to disk, never buffered whole), background
//! finalize jobs with retries + crash recovery (same job-file format as
//! the Lua build), moderation, duplicate/visual search, MP4 fast-start
//! remux, AI suggestions, and the fast-disk ("hot") tier mover.

use crate::ai;
use crate::app::{App, AppRef, uid};
use crate::db::{J, P, Sql};
use crate::http::{R, Reply, Req};
use crate::media::{self, decode_media_row, fetch_by_id};
use crate::media_files::{self as mf, file_size};
use crate::routes::notify;
use crate::serve::staging_dir;
use crate::util::{append_query, cut, tobool, vnum, vstr};
use axum::body::Body;
use axum::extract::Request;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use tokio::io::AsyncWriteExt;

const MAX_CHUNK: usize = 16 * 1024 * 1024;
const FINALIZE_MAX: usize = 3;
static ACTIVE_JOBS: AtomicUsize = AtomicUsize::new(0);
static BOOT_ID: std::sync::OnceLock<String> = std::sync::OnceLock::new();

pub fn boot_id() -> &'static str {
    BOOT_ID.get_or_init(|| crate::auth::random_hex(8))
}

fn rid() -> String {
    crate::auth::random_hex(16)
}

pub fn limit_label(app: &App) -> String {
    let b = app.settings.max_upload_bytes as f64;
    let gb = b / (1024.0 * 1024.0 * 1024.0);
    if gb >= 1.0 {
        if gb.fract() == 0.0 { format!("{} GB", gb as i64) } else { format!("{gb:.1} GB") }
    } else {
        format!("{} MB", (b / (1024.0 * 1024.0)).floor() as i64)
    }
}

fn form_bool(v: Option<&String>, default: bool) -> bool {
    match v {
        None => default,
        Some(s) => matches!(s.as_str(), "true" | "1" | "on"),
    }
}

// ---- job files -----------------------------------------------------------------------------------
fn job_path(app: &App, id: &str) -> String {
    format!("{}/_upload_jobs_{id}.json", staging_dir(app))
}
fn session_path(app: &App, id: &str) -> String {
    format!("{}/_upload_sessions_{id}.json", staging_dir(app))
}
fn boot_path(app: &App) -> String {
    format!("{}/_upload_worker_{}.boot", staging_dir(app), app.settings.port)
}

async fn write_json(path: &str, v: &Value) -> bool {
    crate::serve::write_atomic(path, v.to_string().as_bytes()).await
}
async fn read_json(path: &str) -> Option<Value> {
    serde_json::from_slice::<Value>(&tokio::fs::read(path).await.ok()?).ok().filter(Value::is_object)
}

/// Startup: write this process's boot id (jobs owned by an older boot get resumed).
pub async fn configure(app: &App) {
    let _ = tokio::fs::create_dir_all(staging_dir(app)).await;
    if !app.settings.hot_dir.is_empty() {
        let _ = tokio::fs::create_dir_all(format!("{}/media", app.settings.hot_dir)).await;
    }
    let _ = tokio::fs::write(boot_path(app), boot_id()).await;
}

// ---- moderation / fingerprints ------------------------------------------------------------------------
const ADULT_KEYWORDS: &[&str] = &[
    "18plus", "18+", "adult", "nsfw", "not safe for work", "nude", "nudity", "explicit", "porn", "porno", "sex", "sexual", "hentai", "ecchi", "lewd", "erotic", "fetish", "onlyfans", "camgirl", "cam boy",
    "xxx", "sexy", "sexually", "nudes", "pornographic", "pornhub", "erotica", "fetishes", "lewds", "hardcore", "xrated",
];

pub struct Moderation {
    pub is_adult: bool,
    pub by_user: bool,
    pub by_ai: bool,
    pub status: &'static str,
    pub score: f64,
    pub reason: Option<String>,
}

pub fn moderate(title: &str, desc: &str, tags: &[String], filename: &str, mime: &str, user_marked: bool) -> Moderation {
    let combined = [title, desc, &tags.join(" "), filename, mime].join(" ").to_lowercase();
    let normalized = format!(" {} ", combined.split(|c: char| !c.is_ascii_alphanumeric()).filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" "));
    let hits: Vec<&str> = ADULT_KEYWORDS
        .iter()
        .copied()
        .filter(|w| if w.chars().all(|c| c.is_ascii_alphanumeric()) { normalized.contains(&format!(" {w} ")) } else { combined.contains(w) })
        .collect();
    let by_ai = !hits.is_empty();
    let is_adult = user_marked || by_ai;
    let mut parts = vec![];
    if user_marked {
        parts.push("Uploader marked this post as 18+.".to_string());
    }
    if by_ai {
        parts.push(format!("Automatic moderation matched: {}.", hits.join(", ")));
    }
    Moderation {
        is_adult,
        by_user: user_marked,
        by_ai,
        status: if is_adult { "adult" } else { "clear" },
        score: if by_ai { 0.96 } else if user_marked { 0.75 } else { 0.0 },
        reason: (!parts.is_empty()).then(|| cut(&parts.join(" "), 300)),
    }
}

pub fn hamming(a: &str, b: &str) -> Option<u32> {
    let (a, b) = (a.trim().to_lowercase(), b.trim().to_lowercase());
    if a.is_empty() || a.len() != b.len() || a.len() % 8 != 0 {
        return None;
    }
    let mut d = 0;
    for i in (0..a.len()).step_by(8) {
        let x = u32::from_str_radix(&a[i..i + 8], 16).ok()? ^ u32::from_str_radix(&b[i..i + 8], 16).ok()?;
        d += x.count_ones();
    }
    Some(d)
}

fn best_distance(app: &App, ph: Option<&str>, dh: Option<&str>, row: &Value) -> Option<u32> {
    let s = &app.settings;
    let p = ph.and_then(|h| hamming(h, &row.s("image_phash").unwrap_or_default())).filter(|d| (*d as i64) <= s.visual_phash_max_distance);
    let d = dh.and_then(|h| hamming(h, &row.s("image_dhash").unwrap_or_default())).filter(|d| (*d as i64) <= s.visual_dhash_max_distance);
    match (p, d) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (a, b) => a.or(b),
    }
}

pub async fn possible_duplicates(req: &Req, user_id: i64, fp: Option<&mf::Fingerprint>, limit: usize, site: bool) -> Vec<Value> {
    let Some(fp) = fp else { return vec![] };
    if fp.phash.is_none() && fp.dhash.is_none() {
        return vec![];
    }
    let rows = if site {
        let sql = format!(
            "SELECT id, title, image_phash, image_dhash FROM media_items WHERE user_id != $1 AND deleted_at IS NULL AND media_kind='image' AND visibility='public' \
             AND (image_phash IS NOT NULL OR image_dhash IS NOT NULL) AND created_at > now() - ({} || ' days')::interval ORDER BY created_at DESC LIMIT 1500",
            req.app.settings.dedup_scan_window_days
        );
        req.app.db.all(&sql, &[user_id.into()]).await
    } else {
        req.app
            .db
            .all("SELECT id, title, image_phash, image_dhash FROM media_items WHERE user_id=$1 AND deleted_at IS NULL AND media_kind='image' AND (image_phash IS NOT NULL OR image_dhash IS NOT NULL) ORDER BY created_at DESC LIMIT 1500", &[user_id.into()])
            .await
    };
    let mut scored: Vec<(u32, Value)> = rows.into_iter().filter_map(|r| best_distance(&req.app, fp.phash.as_deref(), fp.dhash.as_deref(), &r).map(|d| (d, r))).collect();
    scored.sort_by_key(|s| s.0);
    let origin = req.origin();
    scored
        .into_iter()
        .take(limit)
        .map(|(d, r)| {
            let id = r.i("id").unwrap_or(0);
            json!({ "id": id, "title": r["title"], "thumb_url": append_query(&format!("{origin}/api/media/{id}/thumb"), "w", "640"), "distance": d })
        })
        .collect()
}

async fn visual_search_run(req: &Req, ph: Option<String>, dh: Option<String>, viewer: Option<i64>, adult: bool, exclude: Option<i64>) -> Vec<Value> {
    let mut q = Sql::new();
    let v = q.bind(viewer.unwrap_or(0));
    let mut c = vec!["m.deleted_at IS NULL".to_string(), "m.media_kind='image'".into(), "(m.image_phash IS NOT NULL OR m.image_dhash IS NOT NULL)".into(), format!("(m.visibility='public' AND (m.publish_at IS NULL OR m.publish_at <= now()) OR m.user_id={v})")];
    if !adult {
        c.push("m.is_adult=false".into());
    }
    if viewer.is_some() {
        c.push(format!("m.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id={v})"));
    }
    if let Some(e) = exclude {
        c.push(format!("m.id != {}", q.bind(e)));
    }
    let sql = format!(
        "SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.is_adult, m.created_at, m.views, m.image_phash, m.image_dhash \
         FROM media_items m WHERE {} LIMIT 5000",
        c.join(" AND ")
    );
    let rows = req.app.db.all(&sql, &q.params).await;
    let mut scored: Vec<(u32, Value)> = rows.into_iter().filter_map(|r| best_distance(&req.app, ph.as_deref(), dh.as_deref(), &r).map(|d| (d, r))).collect();
    scored.sort_by_key(|s| s.0);
    let mut out: Vec<Value> = scored
        .into_iter()
        .take(60)
        .map(|(d, mut r)| {
            let o = r.as_object_mut().unwrap();
            o.remove("image_phash");
            o.remove("image_dhash");
            r["is_adult"] = json!(tobool(r.get("is_adult")));
            r["match_distance"] = json!(d);
            media::with_urls(req, &mut r, adult);
            r
        })
        .collect();
    media::attach_subcategories(req, &mut out).await;
    out
}

pub async fn visual_search(req: Req) -> R<Reply> {
    let viewer = req.viewer().await;
    let adult = req.app.viewer_adult_allowed(viewer).await;
    let key = viewer.map(|v| v.to_string()).unwrap_or_else(|| req.client_ip.clone());
    req.app.rate_check(&format!("visual_search:{key}"), 30, 3600).await?;
    let Some(f) = req.file("file").filter(|f| !f.data.is_empty()) else { return Err(Reply::err(400, "Upload an image to search with.")) };
    if f.data.len() > 15 * 1024 * 1024 {
        return Err(Reply::err(413, "Search image must be 15MB or smaller."));
    }
    if !matches!(crate::sniff::sniff_magic(&f.data), Some((_, "image"))) {
        return Err(Reply::err(400, "That file doesn't look like an image."));
    }
    let tmp = mf::tmp_path("");
    let _ = tokio::fs::write(&tmp, &f.data).await;
    let fp = mf::image_fingerprint_from_path(&tmp).await;
    let _ = tokio::fs::remove_file(&tmp).await;
    let Some(fp) = fp.filter(|f| f.phash.is_some() || f.dhash.is_some()) else { return Err(Reply::err(400, "Could not read that image.")) };
    let rows = visual_search_run(&req, fp.phash, fp.dhash, viewer, adult, None).await;
    media::ok_media(rows)
}

pub async fn visual_search_from_media(req: Req) -> R<Reply> {
    let id = req.pi("media_id").ok_or_else(|| Reply::err(404, "Media not found."))?;
    let viewer = req.viewer().await;
    let adult = req.app.viewer_adult_allowed(viewer).await;
    let seed = fetch_by_id(&req, id, viewer).await;
    media::ensure_visible(&req, seed.as_ref(), viewer).await?;
    if seed.as_ref().and_then(|s| s.s("media_kind")).as_deref() != Some("image") {
        return Err(Reply::err(400, "That post has no visual fingerprint to search with."));
    }
    let h = req.app.db.opt("SELECT image_phash, image_dhash FROM media_items WHERE id=$1", &[id.into()]).await.unwrap_or_else(|| json!({}));
    let (ph, dh) = (h.s("image_phash"), h.s("image_dhash"));
    if ph.is_none() && dh.is_none() {
        return Err(Reply::err(400, "That post has no visual fingerprint to search with."));
    }
    media::ok_media(visual_search_run(&req, ph, dh, viewer, adult, Some(id)).await)
}

// ---- fast start -------------------------------------------------------------------------------------
fn faststart_tmp(app: &App, suffix: &str) -> String {
    let dir = if app.settings.hot_dir.is_empty() { format!("{}/_upload_tmp", app.settings.uploads_dir) } else { format!("{}/staging", app.settings.hot_dir) };
    let _ = std::fs::create_dir_all(&dir);
    format!("{dir}/faststart_{}{suffix}", rand::random_range(100000000..999999999))
}

/// Move the MP4 index to the front so playback starts before the whole file downloads.
async fn faststart(app: &App, path: &str, mime: &str) -> Option<(String, u64)> {
    if !matches!(mime, "video/mp4" | "video/quicktime" | "video/x-m4v") {
        return None;
    }
    let layout = mf::mp4_layout(path)?;
    if layout.faststart == Some(true) {
        return None;
    }
    let out = faststart_tmp(app, ".out");
    let container = if mime == "video/quicktime" { "mov" } else { "mp4" };
    let remux = |flags: Vec<String>| {
        let mut c = mf::ffmpeg_cmd(15);
        c.args(["-y", "-hide_banner", "-loglevel", "error", "-i"]).arg(path).args(["-map", "0:v:0", "-map", "0:a:0?", "-c", "copy"]).args(flags).args(["-f", container]).arg(&out);
        c
    };
    let mut ok = false;
    if let Some(moov) = layout.moov_size {
        let size = ((moov as f64) * 1.05).floor() as u64 + 65536;
        ok = mf::run_ok(remux(vec!["-moov_size".into(), size.to_string()])).await && mf::mp4_layout(&out).and_then(|l| l.faststart) == Some(true);
        if !ok {
            let _ = tokio::fs::remove_file(&out).await;
        }
    }
    if !ok {
        ok = mf::run_ok(remux(vec!["-movflags".into(), "+faststart".into()])).await;
    }
    let size = file_size(&out);
    if ok && size > 0 {
        let _ = tokio::fs::remove_file(path).await;
        Some((out, size))
    } else {
        let _ = tokio::fs::remove_file(&out).await;
        None
    }
}

// ---- finalize -----------------------------------------------------------------------------------------
pub type Form = HashMap<String, String>;

pub enum Stage<'a> {
    Stage(&'a str),
    Media(i64),
    Source(String, u64),
}

async fn parse_publish_at(app: &App, raw: Option<&String>) -> Result<Option<String>, String> {
    let Some(raw) = raw.map(|s| s.trim().to_string()).filter(|s| !s.is_empty()) else { return Ok(None) };
    match app.db.one("SELECT ($1::text::timestamp > now()) AS in_future", &[raw.as_str().into()]).await {
        Ok(Some(r)) if tobool(r.get("in_future")) => Ok(Some(raw)),
        Ok(Some(_)) => Err("Scheduled time must be in the future.".into()),
        _ => Err("Invalid schedule date.".into()),
    }
}

fn plain_json_list(s: Option<&String>) -> Vec<Value> {
    s.and_then(|s| serde_json::from_str::<Value>(s).ok()).and_then(|v| v.as_array().cloned()).unwrap_or_default()
}

/// finalize_upload: validate, analyze, store, insert, notify. (status, body)
pub async fn finalize(req: &Req, user: &Value, mut path: String, mut size: u64, filename: &str, form: &Form, mut stage: impl FnMut(Stage)) -> (u16, Value) {
    let app = req.app.clone();
    let uid_ = uid(user);
    let err = |s: u16, d: &str| (s, json!({ "detail": d }));
    let prefix = {
        use tokio::io::AsyncReadExt;
        let mut buf = vec![0u8; 512];
        let n = match tokio::fs::File::open(&path).await {
            Ok(mut f) => f.read(&mut buf).await.unwrap_or(0),
            Err(_) => 0,
        };
        buf.truncate(n);
        buf
    };
    let Some((mime, kind)) = crate::sniff::sniff_magic(&prefix) else { return err(400, "Unsupported or invalid file bytes.") };
    let Some(ext) = crate::sniff::safe_extension(filename, mime) else { return err(400, "Unsupported file extension.") };
    if kind == "video" {
        stage(Stage::Stage("optimizing"));
        if let Some((p, s)) = faststart(&app, &path, mime).await {
            path = p;
            size = s;
            stage(Stage::Source(path.clone(), size));
        }
    }
    // Hash + fingerprint in parallel with the AI call.
    let (hp, hk) = (path.clone(), kind);
    let pre = tokio::spawn(async move {
        let sha = mf::sha256_file(&hp).await;
        let fp = if hk == "image" { mf::image_fingerprint_from_path(&hp).await } else { None };
        (sha, fp)
    });
    let title_raw = cut(form.get("title").map(|s| s.trim()).unwrap_or(""), 160);
    let desc_raw = form.get("description").map(|s| s.trim().to_string()).unwrap_or_default();
    let source_url = match crate::routes::media_actions::normalize_source_url(form.get("source_url").map(|s| json!(s)).as_ref()) {
        Ok(u) => u,
        Err(e) => return err(400, &e),
    };
    let youtube = source_url.as_deref().and_then(youtube_id);
    let tags_hint = media::parse_tags(form.get("tags").map(String::as_str).unwrap_or(""), app.settings.max_tag_length, app.settings.max_tags_per_upload);
    let visibility = form.get("visibility").map(|v| v.to_lowercase()).unwrap_or_else(|| "public".into());
    if !matches!(visibility.as_str(), "public" | "unlisted" | "private") {
        return err(400, "Visibility must be public, unlisted, or private.");
    }
    let publish_at = match parse_publish_at(&app, form.get("publish_at")).await {
        Ok(p) => p,
        Err(e) => return err(400, &e),
    };
    let mut expires_at = None;
    if let Some(h) = form.get("expires_in_hours").and_then(|v| v.trim().parse::<f64>().ok()) {
        if !(1.0..=168.0).contains(&h) {
            return err(400, "expires_in_hours must be between 1 and 168 (7 days).");
        }
        expires_at = app.db.opt("SELECT (now() + ($1::text || ' hours')::interval)::timestamp::text AS ts", &[P::Text(crate::media_files::fmt_num(h))]).await.and_then(|r| r.s("ts"));
    }
    let comments = form_bool(form.get("comments_enabled"), true);
    let downloads = form_bool(form.get("downloads_enabled"), true);
    let adult_input = form_bool(form.get("is_adult"), false);
    let mut analysis = None;
    if form_bool(form.get("auto_ai"), true) && app.settings.ai_enabled {
        stage(Stage::Stage("analyzing"));
        let t0 = std::time::Instant::now();
        let a = ai::analyze(&app.http, &app.settings, ai::AnalyzeInput { file_path: &path, filename, mime, kind, title_hint: &title_raw, desc_hint: &desc_raw, tags_hint: &tags_hint }).await;
        app.telemetry.record("upload", Some("ai_analyze"), Some("success"), Some(t0.elapsed().as_millis() as i64), Some(json!({ "provider": app.settings.ai_provider, "media_kind": kind })));
        analysis = Some(a);
    }
    let confident = analysis.as_ref().is_some_and(|a| a.confidence >= 0.6);
    let title = if !title_raw.is_empty() { title_raw.clone() } else { analysis.as_ref().map(|a| a.title.clone()).unwrap_or_default() };
    if title.is_empty() {
        return err(400, "Title is required.");
    }
    let description = (!desc_raw.is_empty()).then(|| cut(&desc_raw, 2000));
    let tags = if confident && !analysis.as_ref().unwrap().tags.is_empty() { analysis.as_ref().unwrap().tags.clone() } else { tags_hint.clone() };
    let mut category_id = form.get("category_id").and_then(|v| v.trim().parse::<f64>().ok()).map(|f| f as i64).filter(|n| *n > 0);
    if category_id.is_none() {
        let ck = form.get("category_kind").cloned().unwrap_or_else(|| if kind == "video" { "video".into() } else { "image".into() });
        let cn = form.get("category_name").filter(|n| !n.trim().is_empty()).cloned().or_else(|| analysis.as_ref().and_then(|a| a.category_name.clone()));
        category_id = match cn {
            Some(n) => media::find_or_create_category(&app.db, &n, &ck, uid_).await,
            None => None,
        };
        if category_id.is_none() {
            return err(400, "Category is required.");
        }
    }
    let category_id = category_id.unwrap();
    let mut ids_raw = plain_json_list(form.get("subcategory_ids_json"));
    if let Some(s) = form.get("subcategory_id").and_then(|v| v.trim().parse::<f64>().ok()).filter(|n| *n > 0.0) {
        ids_raw.insert(0, json!(s));
    }
    let ids = media::normalize_subcategory_ids(Some(&json!(ids_raw)));
    let mut names_raw = plain_json_list(form.get("subcategory_names_json"));
    if let Some(n) = form.get("subcategory_name").filter(|n| !n.trim().is_empty()) {
        names_raw.insert(0, json!(n));
    }
    if ids.is_empty() && names_raw.is_empty() && confident {
        names_raw.extend(analysis.as_ref().unwrap().subcategory_names.iter().map(|n| json!(n)));
    }
    let names = media::normalize_subcategory_names(Some(&json!(names_raw)));
    let subs = match media::resolve_subcategory_ids(&app.db, category_id, ids, names, uid_).await {
        Ok(s) => s,
        Err(e) => return err(400, &e),
    };
    stage(Stage::Stage("fingerprinting"));
    let (sha, fp) = pre.await.unwrap_or((None, None));
    let Some(sha) = sha else { return err(500, "Could not store uploaded file: hash failed") };
    let moderation = moderate(&title, description.as_deref().unwrap_or(""), &tags, filename, mime, adult_input || analysis.as_ref().is_some_and(|a| a.is_adult));
    let dups = possible_duplicates(req, uid_, fp.as_ref(), 3, false).await;
    let site_dups = if form_bool(form.get("check_site_duplicates"), false) { possible_duplicates(req, uid_, fp.as_ref(), 3, true).await } else { vec![] };
    stage(Stage::Stage("saving"));
    let stored = match mf::save_to_disk(&app.settings.uploads_dir, &sha, &ext, Some(&path), None).await {
        Ok(s) => s,
        Err(e) => return err(500, &format!("Could not store uploaded file: {e}")),
    };
    println!("[nyxframe] finalize_upload insert: user_id={uid_} category_id={category_id} file_size={size} media_kind={kind}");
    let row = app
        .db
        .one(
            "INSERT INTO media_items (user_id, category_id, subcategory_id, title, description, tags, media_kind, mime_type, original_filename, storage_path, file_size, media_file_id, content_sha256, \
               visibility, comments_enabled, downloads_enabled, is_adult, adult_marked_by_user, adult_marked_by_ai, moderation_status, moderation_score, moderation_reason, moderated_at, \
               image_phash, image_dhash, image_width, image_height, dominant_color, publish_at, source_url, expires_at, youtube_video_id) \
             VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,NULL,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,now(),$22,$23,$24,$25,$26,$27::text::timestamp,$28,$29::text::timestamp,$30) RETURNING id",
            &[
                uid_.into(),
                category_id.into(),
                subs.first().copied().into(),
                title.as_str().into(),
                description.clone().into(),
                json!(tags).to_string().into(),
                kind.into(),
                mime.into(),
                filename.into(),
                stored.storage_path.as_str().into(),
                (size as i64).into(),
                sha.as_str().into(),
                visibility.as_str().into(),
                comments.into(),
                downloads.into(),
                moderation.is_adult.into(),
                moderation.by_user.into(),
                moderation.by_ai.into(),
                moderation.status.into(),
                moderation.score.into(),
                moderation.reason.clone().into(),
                fp.as_ref().and_then(|f| f.phash.clone()).into(),
                fp.as_ref().and_then(|f| f.dhash.clone()).into(),
                fp.as_ref().and_then(|f| f.width).into(),
                fp.as_ref().and_then(|f| f.height).into(),
                fp.as_ref().and_then(|f| f.dominant_color.clone()).into(),
                publish_at.clone().into(),
                source_url.clone().into(),
                expires_at.into(),
                youtube.into(),
            ],
        )
        .await;
    let media_id = match row {
        Ok(Some(r)) => r.i("id").unwrap_or(0),
        Ok(None) => return err(500, "Could not save media: nil"),
        Err(e) => return err(500, &format!("Could not save media: {e}")),
    };
    media::write_subcategories(&app.db, media_id, &subs).await;
    if kind == "video" {
        if let Some(p) = mf::legacy_upload_path(&app.settings.uploads_dir, &stored.storage_path) {
            if let Some(c) = crate::video::probe_codecs(&p).await {
                let _ = app.db.exec("UPDATE media_items SET video_codecs=$1 WHERE id=$2", &[c.into(), media_id.into()]).await;
            }
        }
    }
    if let Some(t) = form.get("thumbnail_token").filter(|t| !t.is_empty()) {
        crate::serve::attach_staged_thumbnail(&app, uid_, media_id, t, kind == "video").await;
    }
    stage(Stage::Media(media_id));
    stage(Stage::Stage("finishing"));
    let Some(mut item) = fetch_by_id(req, media_id, Some(uid_)).await else { return err(500, "Could not save media: row vanished") };
    let raw = item.clone();
    let adult = req.app.viewer_adult_allowed(Some(uid_)).await;
    decode_media_row(req, &mut item, adult);
    let appref = app.clone();
    if kind == "image" {
        let r = raw.clone();
        tokio::spawn(async move { crate::jobs::warm_image_renditions(&appref, &r, 15).await });
    } else {
        let r = raw.clone();
        tokio::spawn(async move { crate::serve::prewarm_video_thumb(&appref, media_id, &r).await });
    }
    notify_discord_upload(req, user, &item);
    if visibility == "public" && publish_at.is_none() {
        notify::notify_matching_saved_searches(&app, uid_, &item).await;
        for f in app.db.all("SELECT follower_id FROM user_follows WHERE followed_id=$1 AND notifications_muted=false", &[uid_.into()]).await {
            notify::create(&app, f.i("follower_id").unwrap_or(0), Some(uid_), "new_upload", Some(media_id), Some(&title)).await;
        }
    }
    (200, json!({ "media": item, "possible_duplicates": dups, "possible_site_duplicates": site_dups }))
}

pub fn youtube_id(url: &str) -> Option<String> {
    let rest = url.strip_prefix("https://").or_else(|| url.strip_prefix("http://"))?;
    let (host, path) = rest.split_once(['/', '?', '#']).map(|(h, _)| (h, &rest[h.len()..])).unwrap_or((rest, ""));
    let host = host.to_lowercase();
    let host = host.strip_prefix("www.").unwrap_or(&host);
    let host = host.strip_prefix("m.").unwrap_or(host);
    let idchars = |s: &str| s.chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-').collect::<String>();
    let id = if host == "youtu.be" {
        idchars(path.trim_start_matches('/'))
    } else if host == "youtube.com" || host == "music.youtube.com" {
        if let Some(i) = path.find("v=").filter(|i| *i > 0 && matches!(path.as_bytes()[i - 1], b'?' | b'&')) {
            idchars(&path[i + 2..])
        } else if let Some(i) = path.find("/shorts/") {
            idchars(&path[i + 8..])
        } else if let Some(i) = path.find("/embed/") {
            idchars(&path[i + 7..])
        } else {
            String::new()
        }
    } else {
        String::new()
    };
    (!id.is_empty()).then_some(id)
}

fn notify_discord_upload(req: &Req, uploader: &Value, item: &Value) {
    let Some(url) = uploader["user_settings"].get("discord_webhook_url").and_then(Value::as_str).filter(|u| !u.is_empty()) else { return };
    let mut embed = json!({
        "title": cut(&item.s("title").unwrap_or_else(|| "New upload".into()), 256),
        "url": format!("{}/media/{}", req.origin().trim_end_matches('/'), item.i("id").unwrap_or(0)),
        "color": 0x37c9a7,
        "author": { "name": uploader.s("display_name").or(uploader.s("username")).unwrap_or_else(|| "Someone".into()) },
    });
    if let Some(d) = item.s("description").map(|d| d.trim().to_string()).filter(|d| !d.is_empty()) {
        embed["description"] = json!(cut(&d, 300));
    }
    match (item.s("url").or(item.s("preview_url")), item.s("media_kind").as_deref()) {
        (Some(u), Some(k)) if k != "video" => embed["image"] = json!({ "url": u }),
        _ => {
            if let Some(t) = item.s("thumb_url") {
                embed["thumbnail"] = json!({ "url": t });
            }
        }
    }
    crate::discord::webhook_send(&req.app, url, json!([embed]));
}

// ---- jobs ----------------------------------------------------------------------------------------------
fn safe_headers(req: &Req) -> Value {
    json!({ "host": req.header("host"), "x-forwarded-proto": req.header("x-forwarded-proto"), "x-forwarded-host": req.header("x-forwarded-host") })
}

/// Rebuild a Req (origin headers only) for a background job.
fn job_req(app: &AppRef, headers: &Value) -> Req {
    let mut h = axum::http::HeaderMap::new();
    for k in ["host", "x-forwarded-proto", "x-forwarded-host"] {
        if let Some(v) = headers.get(k).and_then(Value::as_str).and_then(|v| v.parse().ok()) {
            h.insert(k, v);
        }
    }
    Req {
        app: app.clone(),
        method: axum::http::Method::POST,
        path: "/api/media/upload/finish".into(),
        query: HashMap::new(),
        params: HashMap::new(),
        headers: h,
        cookies: HashMap::new(),
        raw_body: Default::default(),
        json: json!({}),
        form: HashMap::new(),
        files: vec![],
        client_ip: "job".into(),
    }
}

async fn precheck(app: &App, path: &str, filename: &str, form: &Form) -> Result<(), Reply> {
    let prefix = {
        use tokio::io::AsyncReadExt;
        let mut b = vec![0u8; 512];
        let n = match tokio::fs::File::open(path).await {
            Ok(mut f) => f.read(&mut b).await.unwrap_or(0),
            Err(_) => 0,
        };
        b.truncate(n);
        b
    };
    let Some((mime, _)) = crate::sniff::sniff_magic(&prefix) else { return Err(Reply::err(400, "Unsupported or invalid file bytes.")) };
    if crate::sniff::safe_extension(filename, mime).is_none() {
        return Err(Reply::err(400, "Unsupported file extension."));
    }
    let vis = form.get("visibility").map(|v| v.to_lowercase()).unwrap_or_else(|| "public".into());
    if !matches!(vis.as_str(), "public" | "unlisted" | "private") {
        return Err(Reply::err(400, "Visibility must be public, unlisted, or private."));
    }
    parse_publish_at(app, form.get("publish_at")).await.map_err(|e| Reply::err(400, e))?;
    let auto_ai = form_bool(form.get("auto_ai"), true);
    if form.get("title").is_none_or(|t| t.trim().is_empty()) && !auto_ai {
        return Err(Reply::err(400, "Title is required."));
    }
    let has_cat = form.get("category_id").and_then(|v| v.trim().parse::<f64>().ok()).is_some_and(|n| n > 0.0) || form.get("category_name").is_some_and(|n| !n.trim().is_empty());
    if !has_cat && !auto_ai {
        return Err(Reply::err(400, "Category is required."));
    }
    Ok(())
}

async fn start_job(req: &Req, user: &Value, path: String, size: u64, filename: &str, form: Form) -> R<Reply> {
    if let Err(e) = precheck(&req.app, &path, filename, &form).await {
        let _ = tokio::fs::remove_file(&path).await;
        return Err(e);
    }
    let id = rid();
    let now = crate::util::now();
    let job = json!({
        "user_id": uid(user), "status": "queued", "stage": "queued", "created_at": now, "heartbeat": now, "filename": filename, "size": size,
        "owner_port": req.app.settings.port, "owner_boot": boot_id(),
        "input": { "temp_path": path, "total_size": size, "filename": filename, "form": form, "headers": safe_headers(req) },
    });
    if !write_json(&job_path(&req.app, &id), &job).await {
        let _ = tokio::fs::remove_file(&path).await;
        return Err(Reply::err(500, "Could not queue upload for processing: write failed"));
    }
    let (app, user, jid) = (req.app.clone(), user.clone(), id.clone());
    let headers = safe_headers(req);
    tokio::spawn(async move { run_job(app, jid, job, user, headers).await });
    Ok(Reply::json(202, json!({ "status": "processing", "job_id": id })))
}

fn merge_fields(job: &mut Value, fields: Value) {
    if let (Some(o), Some(f)) = (job.as_object_mut(), fields.as_object()) {
        for (k, v) in f {
            o.insert(k.clone(), v.clone());
        }
        o.insert("heartbeat".into(), json!(crate::util::now()));
    }
}

async fn run_job(app: AppRef, id: String, job: Value, user: Value, headers: Value) {
    let path = job_path(&app, &id);
    let job = std::sync::Arc::new(std::sync::Mutex::new(job));
    let persist = |fields: Value| {
        let snap = {
            let mut j = job.lock().unwrap();
            merge_fields(&mut j, fields);
            j.clone()
        };
        let p = path.clone();
        async move {
            write_json(&p, &snap).await;
        }
    };
    while ACTIVE_JOBS.load(Ordering::SeqCst) >= FINALIZE_MAX {
        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        persist(json!({})).await;
    }
    ACTIVE_JOBS.fetch_add(1, Ordering::SeqCst);
    persist(json!({ "status": "processing", "stage": "starting" })).await;
    let req = job_req(&app, &headers);
    let input = job.lock().unwrap()["input"].clone();
    let mut temp = input["temp_path"].as_str().unwrap_or("").to_string();
    let mut size = input["total_size"].as_u64().unwrap_or(0);
    let filename = input["filename"].as_str().unwrap_or("upload").to_string();
    let form: Form = input["form"].as_object().map(|o| o.iter().filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string()))).collect()).unwrap_or_default();
    let backoff = [3u64, 10];
    let mut attempt = 1;
    loop {
        let t0 = std::time::Instant::now();
        let src = std::sync::Arc::new(std::sync::Mutex::new(None::<(String, u64)>));
        let (status, body) = {
            let (job, path, src) = (job.clone(), path.clone(), src.clone());
            finalize(&req, &user, temp.clone(), size, &filename, &form, move |s| {
                let snap = {
                    let mut j = job.lock().unwrap();
                    match s {
                        Stage::Stage(n) => merge_fields(&mut j, json!({ "status": "processing", "stage": n, "retrying": false })),
                        Stage::Media(m) => j["media_id"] = json!(m),
                        Stage::Source(p, z) => {
                            j["input"]["temp_path"] = json!(p);
                            j["input"]["total_size"] = json!(z);
                            *src.lock().unwrap() = Some((p, z));
                        }
                    }
                    j.clone()
                };
                let p = path.clone();
                tokio::spawn(async move { write_json(&p, &snap).await });
            })
            .await
        };
        if let Some((p, z)) = src.lock().unwrap().take() {
            temp = p;
            size = z;
        }
        let ms = t0.elapsed().as_millis() as i64;
        if status == 200 {
            app.telemetry.record("upload", Some("chunked"), Some("success"), Some(ms), Some(json!({ "bytes": size, "media_id": body["media"]["id"], "attempts": attempt })));
            job.lock().unwrap().as_object_mut().unwrap().remove("input");
            persist(json!({ "status": "done", "stage": "done", "response": body, "attempts": attempt })).await;
            break;
        }
        let detail = body.s("detail").unwrap_or_else(|| "Upload failed.".into());
        app.telemetry.record("upload", Some("chunked"), Some("error"), Some(ms), Some(json!({ "bytes": size, "status": status, "detail": cut(&detail, 300), "attempt": attempt })));
        let media_id = job.lock().unwrap()["media_id"].as_i64();
        if let Some(m) = media_id {
            if let Some(mut item) = fetch_by_id(&req, m, Some(uid(&user))).await {
                let adult = app.viewer_adult_allowed(Some(uid(&user))).await;
                decode_media_row(&req, &mut item, adult);
                job.lock().unwrap().as_object_mut().unwrap().remove("input");
                persist(json!({ "status": "done", "stage": "done", "response": { "media": item, "possible_duplicates": [], "possible_site_duplicates": [] }, "attempts": attempt })).await;
                break;
            }
        }
        if status < 500 || file_size(&temp) == 0 || attempt >= 3 {
            job.lock().unwrap().as_object_mut().unwrap().remove("input");
            persist(json!({ "status": "error", "detail": detail, "attempts": attempt, "retrying": false })).await;
            break;
        }
        persist(json!({ "status": "error", "detail": detail, "attempts": attempt, "retrying": true })).await;
        tokio::time::sleep(std::time::Duration::from_secs(backoff[(attempt - 1).min(1)])).await;
        attempt += 1;
    }
    let _ = tokio::fs::remove_file(&temp).await;
    ACTIVE_JOBS.fetch_sub(1, Ordering::SeqCst);
}

/// Resume (or fail cleanly) jobs whose process restarted mid-finalize.
pub async fn recover_jobs(app: &AppRef) {
    let dir = staging_dir(app);
    let Ok(mut rd) = tokio::fs::read_dir(&dir).await else { return };
    while let Ok(Some(e)) = rd.next_entry().await {
        let name = e.file_name().to_string_lossy().to_string();
        let Some(id) = name.strip_prefix("_upload_jobs_").and_then(|n| n.strip_suffix(".json")).map(str::to_string) else { continue };
        let Some(mut job) = read_json(&e.path().to_string_lossy()).await else { continue };
        let st = job.s("status").unwrap_or_default();
        let unfinished = job.get("input").is_some() && (st == "queued" || st == "processing" || (st == "error" && job["retrying"].as_bool() == Some(true)));
        if !unfinished {
            continue;
        }
        let owner_boot_file = format!("{dir}/_upload_worker_{}.boot", vstr(job.get("owner_port")).unwrap_or_default());
        let current = tokio::fs::read_to_string(&owner_boot_file).await.unwrap_or_default();
        if job.s("owner_boot").as_deref() == Some(current.as_str()) {
            continue;
        }
        let user = match job.i("user_id") {
            Some(u) => app.get_user(u).await,
            None => None,
        };
        let headers = job["input"]["headers"].clone();
        let src_ok = job["input"]["temp_path"].as_str().is_some_and(|p| file_size(p) > 0);
        let path = job_path(app, &id);
        match user {
            Some(u) if src_ok => {
                println!("[nyxframe] resuming upload job {id} (its worker restarted)");
                job["owner_port"] = json!(app.settings.port);
                job["owner_boot"] = json!(boot_id());
                job["status"] = json!("queued");
                job["stage"] = json!("queued");
                job["retrying"] = json!(false);
                write_json(&path, &job).await;
                let a = app.clone();
                tokio::spawn(async move { run_job(a, id, job, u, headers).await });
            }
            _ => {
                job.as_object_mut().unwrap().remove("input");
                job["status"] = json!("error");
                job["retrying"] = json!(false);
                job["detail"] = json!("Processing was interrupted by a server restart. Please upload the file again.");
                write_json(&path, &job).await;
            }
        }
    }
}

/// Delete abandoned sessions/staging files (sessions after 2h, leftovers after 24h).
pub async fn prune(app: &App) {
    let dir = staging_dir(app);
    let Ok(mut rd) = tokio::fs::read_dir(&dir).await else { return };
    let now = std::time::SystemTime::now();
    while let Ok(Some(e)) = rd.next_entry().await {
        let name = e.file_name().to_string_lossy().to_string();
        let Ok(age) = e.metadata().await.and_then(|m| m.modified()).map(|m| now.duration_since(m).unwrap_or_default().as_secs()) else { continue };
        let p = e.path();
        if name.starts_with("_upload_sessions_") && name.ends_with(".part") && age > 2 * 3600 {
            let _ = tokio::fs::remove_file(&p).await;
            let _ = tokio::fs::remove_file(format!("{}.log", p.to_string_lossy())).await;
            if let Some(sid) = name.strip_prefix("_upload_sessions_").and_then(|n| n.strip_suffix(".part")) {
                let _ = tokio::fs::remove_file(session_path(app, sid)).await;
            }
        } else if age > 86400
            && (name.starts_with("_upload_direct_") && name.ends_with(".part")
                || name.starts_with("faststart_")
                || name.contains(".tmp.")
                || name.starts_with("_thumb_stage_")
                || (name.starts_with("_upload_jobs_") || name.starts_with("_upload_sessions_")) && name.ends_with(".json"))
        {
            let _ = tokio::fs::remove_file(&p).await;
        }
    }
}

// ---- handlers ------------------------------------------------------------------------------------
/// Stream a multipart body: text fields into a map, the `file` part to `dest`.
async fn stream_multipart(headers: &axum::http::HeaderMap, body: Body, dest: &str, max: u64) -> Result<(Form, Option<(String, u64)>), Reply> {
    let ct = headers.get(axum::http::header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).unwrap_or("");
    let boundary = multer::parse_boundary(ct).map_err(|_| Reply::err(400, "Upload is empty."))?;
    let mut mp = multer::Multipart::new(body.into_data_stream(), boundary);
    let mut form = Form::new();
    let mut file = None;
    while let Ok(Some(mut field)) = mp.next_field().await {
        let name = field.name().unwrap_or("").to_string();
        if let Some(fname) = field.file_name().map(str::to_string) {
            if name != "file" || file.is_some() {
                while let Ok(Some(_)) = field.chunk().await {}
                continue;
            }
            let mut out = tokio::fs::File::create(dest).await.map_err(|e| Reply::err(500, format!("Could not stage upload: {e}")))?;
            let mut n = 0u64;
            loop {
                match field.chunk().await {
                    Ok(Some(c)) => {
                        n += c.len() as u64;
                        if n > max {
                            drop(out);
                            let _ = tokio::fs::remove_file(dest).await;
                            return Err(Reply::err(413, "too large"));
                        }
                        out.write_all(&c).await.map_err(|e| Reply::err(500, format!("Could not stage upload: {e}")))?;
                    }
                    Ok(None) => break,
                    Err(_) => {
                        drop(out);
                        let _ = tokio::fs::remove_file(dest).await;
                        return Err(Reply::err(400, "Upload was interrupted."));
                    }
                }
            }
            out.flush().await.ok();
            file = Some((fname, n));
        } else if let Ok(t) = field.text().await {
            form.insert(name, t);
        }
    }
    Ok((form, file))
}

pub async fn upload_media(request: Request) -> R<Reply> {
    let (req, body) = Req::split(request).await;
    let user = req.current_user().await?;
    let app = req.app.clone();
    let dir = staging_dir(&app);
    let _ = tokio::fs::create_dir_all(&dir).await;
    let temp = format!("{dir}/_upload_direct_{}.part", rid());
    let (form, file) = stream_multipart(&req.headers, body, &temp, app.settings.max_upload_bytes as u64).await.map_err(|r| if r.status == 413 { Reply::err(413, format!("Uploads must be {} or smaller.", limit_label(&app))) } else { r })?;
    let Some((fname, size)) = file.filter(|f| f.1 > 0) else {
        let _ = tokio::fs::remove_file(&temp).await;
        return Err(Reply::err(400, "Upload is empty."));
    };
    if let Err(e) = app.rate_check(&format!("upload:{}", uid(&user)), app.settings.upload_rate_limit_per_hour, 3600).await {
        let _ = tokio::fs::remove_file(&temp).await;
        return Err(e);
    }
    let filename = crate::sniff::clean_filename(&fname, "upload");
    if form_bool(form.get("defer"), false) {
        let mut f = form.clone();
        f.remove("defer");
        return start_job(&req, &user, temp, size, &filename, f).await;
    }
    let t0 = std::time::Instant::now();
    let (status, body) = finalize(&req, &user, temp.clone(), size, &filename, &form, |_| {}).await;
    let _ = tokio::fs::remove_file(&temp).await;
    app.telemetry.record("upload", Some("direct"), Some(if status == 200 { "success" } else { "error" }), Some(t0.elapsed().as_millis() as i64), Some(json!({ "bytes": size, "media_id": body["media"]["id"], "status": status })));
    Ok(Reply::json(status, body))
}

fn free_bytes(path: &str) -> Option<u64> {
    let out = std::process::Command::new("df").args(["-k", path]).output().ok()?;
    let s = String::from_utf8_lossy(&out.stdout);
    let line = s.lines().last()?;
    line.split_whitespace().nth(3)?.parse::<u64>().ok().map(|k| k * 1024)
}

pub async fn chunk_init(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let app = req.app.clone();
    app.rate_check(&format!("upload:{}", uid(&user)), app.settings.upload_rate_limit_per_hour, 3600).await?;
    let a2 = app.clone();
    tokio::spawn(async move { prune(&a2).await });
    let total = vnum(req.json.get("total_size")).map(|f| f as i64).filter(|t| *t > 0).ok_or_else(|| Reply::err(400, "total_size is required."))?;
    let filename = crate::sniff::clean_filename(&req.js("filename").unwrap_or_else(|| "upload".into()), "upload");
    if total > app.settings.max_upload_bytes {
        return Err(Reply::err(413, format!("Uploads must be {} or smaller.", limit_label(&app))));
    }
    let dir = staging_dir(&app);
    let _ = tokio::fs::create_dir_all(&dir).await;
    if free_bytes(&dir).is_some_and(|f| f < total as u64 * 2 + 2 * 1024 * 1024 * 1024) {
        return Err(Reply::err(507, "The server is low on storage space right now. Please try again later or upload a smaller file."));
    }
    let sid = rid();
    let temp = format!("{dir}/_upload_sessions_{sid}.part");
    tokio::fs::File::create(&temp).await.map_err(|e| Reply::err(500, format!("Could not start upload: {e}")))?;
    let session = json!({ "user_id": uid(&user), "temp_path": temp, "filename": filename, "total_size": total, "received_bytes": 0, "next_index": 0, "created_at": crate::util::now() });
    if !write_json(&session_path(&app, &sid), &session).await {
        let _ = tokio::fs::remove_file(&temp).await;
        return Err(Reply::err(500, "Could not persist upload session: write failed"));
    }
    Ok(Reply::ok(json!({ "session_id": sid, "chunk_size": 4 * 1024 * 1024, "max_chunk_size": MAX_CHUNK, "parallel": true })))
}

pub async fn chunk_append(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let app = req.app.clone();
    let nf = || Reply::err(404, "Upload session not found or expired.");
    let sid = req.q("session_id").filter(|s| s.chars().all(|c| c.is_ascii_hexdigit())).ok_or_else(nf)?;
    let mut session = read_json(&session_path(&app, &sid)).await.filter(|s| s.i("user_id") == Some(uid(&user))).ok_or_else(nf)?;
    let chunk = &req.raw_body;
    if chunk.is_empty() {
        return Err(Reply::err(400, "Empty chunk."));
    }
    if chunk.len() > MAX_CHUNK {
        return Err(Reply::err(413, "Chunk is too large."));
    }
    let temp = session.s("temp_path").unwrap_or_default();
    let total = session.i("total_size").unwrap_or(0);
    if let Some(off) = req.q("offset").and_then(|o| o.parse::<f64>().ok()) {
        if off < 0.0 || off.fract() != 0.0 || off as i64 + chunk.len() as i64 > total {
            return Err(Reply::err(400, "Chunk falls outside the file size declared at upload start."));
        }
        use tokio::io::AsyncSeekExt;
        let mut f = tokio::fs::OpenOptions::new().write(true).open(&temp).await.map_err(|_| nf())?;
        f.seek(std::io::SeekFrom::Start(off as u64)).await.map_err(|e| Reply::err(500, format!("Could not write chunk: {e}")))?;
        f.write_all(chunk).await.map_err(|e| Reply::err(500, format!("Could not write chunk: {e}")))?;
        let mut log = tokio::fs::OpenOptions::new().create(true).append(true).open(format!("{temp}.log")).await.map_err(|e| Reply::err(500, format!("Could not record chunk: {e}")))?;
        log.write_all(format!("{} {}\n", off as i64, chunk.len()).as_bytes()).await.map_err(|e| Reply::err(500, format!("Could not record chunk: {e}")))?;
        return Ok(Reply::ok(json!({ "ok": true })));
    }
    let index = req.qi("index");
    let next = session.i("next_index").unwrap_or(0);
    let received = session.i("received_bytes").unwrap_or(0);
    if index == Some(next - 1) && session.i("last_chunk_bytes") == Some(chunk.len() as i64) {
        return Ok(Reply::ok(json!({ "ok": true, "received_bytes": received, "duplicate": true })));
    }
    if index != Some(next) {
        return Err(Reply::err(409, "Chunks must be uploaded in order, starting at 0."));
    }
    if received + chunk.len() as i64 > total {
        let _ = tokio::fs::remove_file(&temp).await;
        let _ = tokio::fs::remove_file(session_path(&app, &sid)).await;
        return Err(Reply::err(413, "Received more bytes than declared at upload start."));
    }
    let mut f = tokio::fs::OpenOptions::new().append(true).open(&temp).await.map_err(|e| Reply::err(500, format!("Could not write chunk: {e}")))?;
    f.write_all(chunk).await.map_err(|e| Reply::err(500, format!("Could not write chunk: {e}")))?;
    session["received_bytes"] = json!(received + chunk.len() as i64);
    session["next_index"] = json!(next + 1);
    session["last_chunk_bytes"] = json!(chunk.len());
    if !write_json(&session_path(&app, &sid), &session).await {
        return Err(Reply::err(500, "Could not persist upload progress: write failed"));
    }
    Ok(Reply::ok(json!({ "ok": true, "received_bytes": received + chunk.len() as i64 })))
}

pub async fn chunk_finish(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let app = req.app.clone();
    let nf = || Reply::err(404, "Upload session not found or expired.");
    let sid = req.js("session_id").filter(|s| s.chars().all(|c| c.is_ascii_hexdigit())).ok_or_else(nf)?;
    let session = read_json(&session_path(&app, &sid)).await.filter(|s| s.i("user_id") == Some(uid(&user))).ok_or_else(nf)?;
    let temp = session.s("temp_path").unwrap_or_default();
    let total = session.i("total_size").unwrap_or(0);
    if total == 0 {
        let _ = tokio::fs::remove_file(&temp).await;
        let _ = tokio::fs::remove_file(session_path(&app, &sid)).await;
        return Err(Reply::err(400, "Upload is empty."));
    }
    if let Ok(log) = tokio::fs::read_to_string(format!("{temp}.log")).await {
        let mut ranges: Vec<(i64, i64)> = log.lines().filter_map(|l| l.split_once(' ').and_then(|(a, b)| Some((a.parse().ok()?, b.parse().ok()?)))).collect();
        ranges.sort();
        let mut covered = 0;
        for (o, l) in ranges {
            if o > covered {
                break;
            }
            covered = covered.max(o + l);
        }
        if covered < total {
            return Err(Reply::json(400, json!({ "detail": format!("Upload is incomplete: missing data from byte {covered} of {total}."), "missing_from": covered })));
        }
        let _ = tokio::fs::remove_file(format!("{temp}.log")).await;
    } else if session.i("received_bytes") != Some(total) {
        return Err(Reply::err(400, format!("Upload is incomplete: expected {total} bytes, received {}.", session.i("received_bytes").unwrap_or(0))));
    }
    let _ = tokio::fs::remove_file(session_path(&app, &sid)).await;
    let form: Form = req
        .json
        .as_object()
        .map(|o| {
            o.iter()
                .filter(|(_, v)| !v.is_null())
                .map(|(k, v)| {
                    let s = match v {
                        Value::Bool(b) => b.to_string(),
                        Value::String(s) => s.clone(),
                        Value::Array(_) | Value::Object(_) => v.to_string(),
                        other => vstr(Some(other)).unwrap_or_default(),
                    };
                    (k.clone(), s)
                })
                .collect()
        })
        .unwrap_or_default();
    let filename = session.s("filename").unwrap_or_else(|| "upload".into());
    start_job(&req, &user, temp, total as u64, &filename, form).await
}

pub async fn job_status(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let nf = || Reply::err(404, "Upload job not found or expired.");
    let id = req.params.get("job_id").filter(|s| !s.is_empty() && s.chars().all(|c| c.is_ascii_hexdigit())).ok_or_else(nf)?.clone();
    let job = read_json(&job_path(&req.app, &id)).await.filter(|j| vstr(j.get("user_id")) == Some(uid(&user).to_string())).ok_or_else(nf)?;
    let arr = |v: &Value| if v.is_array() { v.clone() } else { json!([]) };
    match job.s("status").as_deref() {
        Some("done") => {
            let r = job.get("response").cloned().unwrap_or_else(|| json!({}));
            let mut m = r.get("media").cloned();
            if let Some(m) = m.as_mut() {
                for k in ["tags", "subcategories", "subcategory_ids", "subcategory_names"] {
                    m[k] = arr(&m[k]);
                }
            }
            Ok(Reply::ok(json!({ "status": "done", "media": m, "possible_duplicates": arr(&r["possible_duplicates"]), "possible_site_duplicates": arr(&r["possible_site_duplicates"]) })))
        }
        Some("error") => Ok(Reply::ok(json!({ "status": "error", "detail": job.s("detail").unwrap_or_else(|| "Upload failed.".into()), "retrying": job["retrying"].as_bool().unwrap_or(false), "attempts": job["attempts"] }))),
        _ => Ok(Reply::ok(json!({ "status": "processing", "stage": job.s("stage").unwrap_or_else(|| "queued".into()), "queued": job.s("status").as_deref() == Some("queued") }))),
    }
}

pub async fn analyze_media(request: Request) -> R<Reply> {
    let (req, body) = Req::split(request).await;
    let user = req.current_user().await?;
    let app = req.app.clone();
    let temp = mf::tmp_path(".analyze");
    let (form, file) = stream_multipart(&req.headers, body, &temp, app.settings.max_upload_bytes as u64).await.map_err(|r| if r.status == 413 { Reply::err(413, format!("Uploads must be {} or smaller.", limit_label(&app))) } else { r })?;
    let guard = TempFile(temp.clone());
    let Some((fname, _)) = file.filter(|f| f.1 > 0) else { return Err(Reply::err(400, "Upload is empty.")) };
    app.rate_check(&format!("analyze:{}", uid(&user)), app.settings.analyze_rate_limit_per_hour, 3600).await?;
    let prefix = tokio::fs::read(&temp).await.map(|b| b[..b.len().min(512)].to_vec()).unwrap_or_default();
    let Some((mime, kind)) = crate::sniff::sniff_magic(&prefix) else { return Err(Reply::err(400, "Unsupported or invalid file bytes.")) };
    let filename = crate::sniff::clean_filename(&fname, "upload");
    let title_hint = cut(form.get("title").map(|s| s.trim()).unwrap_or(""), 160);
    let desc_hint = form.get("description").map(|s| s.trim().to_string()).unwrap_or_default();
    let tags_hint = media::parse_tags(form.get("tags").map(String::as_str).unwrap_or(""), app.settings.max_tag_length, app.settings.max_tags_per_upload);
    let a = if app.settings.ai_enabled {
        ai::analyze(&app.http, &app.settings, ai::AnalyzeInput { file_path: &temp, filename: &filename, mime, kind, title_hint: &title_hint, desc_hint: &desc_hint, tags_hint: &tags_hint }).await
    } else {
        let size = mf::media_dimensions_from_path(&temp).await;
        ai::heuristic(&filename, mime, kind, &title_hint, &desc_hint, &tags_hint, size)
    };
    let fp = if kind == "image" { mf::image_fingerprint_from_path(&temp).await } else { None };
    let dups = possible_duplicates(&req, uid(&user), fp.as_ref(), 3, false).await;
    drop(guard);
    let mut analysis = a.to_json();
    analysis.as_object_mut().map(|o| o.remove("suggested_filename_base"));
    Ok(Reply::ok(json!({ "analysis": analysis, "media_kind": kind, "mime_type": mime, "original_filename": filename, "possible_duplicates": dups })))
}

struct TempFile(String);
impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}


// ---- hot tier ---------------------------------------------------------------------------------------
/// Move the oldest originals from the fast disk to the uploads drive when over the cap.
pub async fn hot_tier_pass(app: &App) -> usize {
    let hot = app.settings.hot_dir.clone();
    if hot.is_empty() {
        return 0;
    }
    let media_dir = format!("{hot}/media");
    let mut files: Vec<(std::time::SystemTime, u64, std::path::PathBuf)> = Vec::new();
    let mut stack = vec![std::path::PathBuf::from(&media_dir)];
    while let Some(d) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&d) else { continue };
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
            } else if !p.to_string_lossy().contains(".tmp.") {
                if let Ok(m) = e.metadata() {
                    files.push((m.modified().unwrap_or(std::time::UNIX_EPOCH), m.len(), p));
                }
            }
        }
    }
    let mut used: u64 = files.iter().map(|f| f.1).sum();
    let mut free = free_bytes(&hot).unwrap_or(u64::MAX);
    let max = app.settings.hot_max_gb as u64 * 1024 * 1024 * 1024;
    let min_free = app.settings.hot_min_free_gb as u64 * 1024 * 1024 * 1024;
    if used <= max && free >= min_free {
        return 0;
    }
    let target = max / 10 * 8;
    files.sort_by_key(|f| f.0);
    let mut moved = 0;
    for (_, size, path) in files {
        if used <= target && free >= min_free {
            break;
        }
        let rel = path.to_string_lossy()[hot.len() + 1..].to_string();
        let cold = format!("{}/{rel}", app.settings.uploads_dir);
        if !std::path::Path::new(&cold).exists() {
            if let Some(d) = std::path::Path::new(&cold).parent() {
                let _ = tokio::fs::create_dir_all(d).await;
            }
            let tmp = format!("{cold}.tmp.{}", rand::random_range(100000..999999));
            let mut c = tokio::process::Command::new("nice");
            c.args(["-n", "19", "ionice", "-c3", "cp", "-f"]).arg(&path).arg(&tmp);
            if !mf::run_ok(c).await || tokio::fs::rename(&tmp, &cold).await.is_err() {
                let _ = tokio::fs::remove_file(&tmp).await;
                println!("[nyxframe] hot tier: could not move {rel} to the uploads drive");
                break;
            }
        }
        let _ = tokio::fs::remove_file(&path).await;
        moved += 1;
        used = used.saturating_sub(size);
        free = free.saturating_add(size);
    }
    moved
}

