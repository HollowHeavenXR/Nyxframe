//! Media bytes: thumbnails, previews, originals (Range), downloads, zips,
//! avatars, HLS playlists/segments and custom video thumbnails. Files are
//! streamed from disk; nothing large is held in memory.

use crate::app::{App, uid};
use crate::auth::media_access_token;
use crate::db::J;
use crate::http::{R, Reply, Req};
use crate::media::{decode_media_row, fetch_by_id};
use crate::media_files::{self as mf, exists, file_size, legacy_upload_path};
use crate::util::{tobool, vstr};
use crate::video::{self, HlsErr, HlsOpts, shard};
use axum::body::Body;
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncSeekExt};

pub const THUMB_WIDTHS: [i64; 11] = [160, 240, 320, 420, 520, 640, 720, 960, 1024, 1280, 1440];
pub const THUMB_MASTER_WIDTH: i64 = 1440;
pub const GRID_WIDTH: i64 = 640;
pub const LIGHTBOX_WIDTH: i64 = 1280;

pub fn preview_size(name: &str) -> Option<(i64, i64)> {
    match name {
        "mini" => Some((360, 78)),
        "card" => Some((880, 86)),
        "detail" => Some((1920, 92)),
        _ => None,
    }
}

pub fn snap_width(requested: i64) -> i64 {
    let r = requested.clamp(160, 1440);
    THUMB_WIDTHS.iter().copied().find(|w| *w >= r).unwrap_or(1440)
}

fn mid(req: &Req) -> R<i64> {
    req.pi("media_id").ok_or_else(|| Reply::err(404, "Media not found."))
}

// ---- rows + access -----------------------------------------------------------------------------
/// Slim row for byte routes (no counts/subcategories).
pub async fn fetch_for_bytes(app: &App, id: i64) -> Option<Value> {
    app.db
        .opt(
            "SELECT m.id, m.user_id, m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.file_size, m.created_at, m.updated_at, m.visibility, m.is_adult, \
               m.youtube_video_id, m.deleted_at, m.expires_at, m.content_sha256, m.custom_thumb_path, m.downloads_enabled \
             FROM media_items m JOIN users u ON u.id = m.user_id WHERE m.id = $1",
            &[id.into()],
        )
        .await
}

fn token_ok(req: &Req, id: i64) -> bool {
    req.q("access").is_some_and(|a| a == media_access_token(req.app.secret(), id))
}

/// Private/18+ rules for byte routes (session owner, or the URL's access token).
async fn check_access(req: &Req, item: &Value, viewer: Option<i64>) -> R<bool> {
    let id = item.i("id").unwrap_or(0);
    let owner = viewer.is_some() && item.i("user_id") == viewer;
    if item.s("visibility").as_deref() == Some("private") && !owner && !token_ok(req, id) {
        return Err(Reply::err(403, "This post is private."));
    }
    if tobool(item.get("is_adult")) && !token_ok(req, id) && !req.app.viewer_adult_allowed(viewer).await {
        return Err(Reply::err(403, "Age verification required for this 18+ post."));
    }
    Ok(owner)
}

pub fn image_cache_control(item: &Value, max_age: i64) -> String {
    let shareable = item.s("visibility").as_deref() == Some("public") && !tobool(item.get("is_adult")) && item["expires_at"].is_null();
    format!("{}, max-age={max_age}, immutable", if shareable { "public" } else { "private" })
}

/// Write a DB-stored original to the original-bytes cache; returns its path.
pub async fn db_blob_to_cache(app: &App, id: i64, item: &Value) -> Option<String> {
    let path = video::original_cache_path(app, id, item);
    if file_size(&path) > 0 {
        return Some(path);
    }
    mf::get_media_file_info(&app.db, id).await?;
    let (_, content) = mf::get_media_file(&app.db, id).await?;
    if content.is_empty() {
        return None;
    }
    write_atomic(&path, &content).await.then_some(path)
}

/// A path ffmpeg / the streamer can read: original cache, else the upload on disk.
pub fn source_path(app: &App, item: &Value) -> Option<String> {
    let id = item.i("id")?;
    let cache = video::original_cache_path(app, id, item);
    if file_size(&cache) > 0 {
        return Some(cache);
    }
    legacy_upload_path(&app.settings.uploads_dir, &item.s("storage_path").unwrap_or_default())
}

/// source_path, falling back to materializing a DB blob.
pub async fn source_or_blob(app: &App, item: &Value) -> Option<String> {
    if let Some(p) = source_path(app, item) {
        return Some(p);
    }
    db_blob_to_cache(app, item.i("id")?, item).await
}

pub async fn write_atomic(path: &str, bytes: &[u8]) -> bool {
    if let Some(dir) = std::path::Path::new(path).parent() {
        let _ = tokio::fs::create_dir_all(dir).await;
    }
    let tmp = format!("{path}.part{}", rand::random_range(100000..999999));
    if tokio::fs::write(&tmp, bytes).await.is_err() {
        return false;
    }
    tokio::fs::rename(&tmp, path).await.is_ok()
}

// ---- streaming ------------------------------------------------------------------------------------
/// (status, start, end) for a Range header against `total` bytes.
fn parse_range(h: Option<&str>, total: u64) -> (u16, u64, u64) {
    let full = (200, 0, total.saturating_sub(1));
    let Some(r) = h.and_then(|r| r.strip_prefix("bytes=")) else { return full };
    let Some((s, e)) = r.split_once('-') else { return full };
    if s.is_empty() && e.is_empty() || !s.chars().chain(e.chars()).all(|c| c.is_ascii_digit()) {
        return full;
    }
    let (start, mut end) = if s.is_empty() {
        let n: u64 = e.parse().unwrap_or(0);
        (total.saturating_sub(n), total.saturating_sub(1))
    } else {
        (s.parse().unwrap_or(0), if e.is_empty() { total.saturating_sub(1) } else { e.parse().unwrap_or(0) })
    };
    end = end.min(total.saturating_sub(1));
    if total == 0 || start > end || start >= total {
        return (416, 0, 0);
    }
    (206, start, end)
}

/// Stream a file (optionally honoring Range) with the given headers.
pub async fn file_reply(req: &Req, path: &str, ctype: &str, headers: &[(&str, String)], ranges: bool) -> R<Reply> {
    let mut f = tokio::fs::File::open(path).await.map_err(|_| Reply::err(404, "File is missing."))?;
    let total = f.metadata().await.map(|m| m.len()).unwrap_or(0);
    let (status, start, end) = if ranges { parse_range(req.header("range"), total) } else { (200, 0, total.saturating_sub(1)) };
    let mut r = if status == 416 {
        Reply::bytes(416, vec![], ctype).header("Content-Range", format!("bytes */{total}"))
    } else {
        if start > 0 {
            let _ = f.seek(std::io::SeekFrom::Start(start)).await;
        }
        let len = if total == 0 { 0 } else { end - start + 1 };
        let stream = tokio_util::io::ReaderStream::with_capacity(f.take(len), 256 * 1024);
        let mut r = Reply::stream(status, Body::from_stream(stream), ctype).header("Content-Length", len.to_string());
        if status == 206 {
            r = r.header("Content-Range", format!("bytes {start}-{end}/{total}"));
        }
        r
    };
    if ranges {
        r = r.header("Accept-Ranges", "bytes");
    }
    for (k, v) in headers {
        r = r.header(k, v.clone());
    }
    Ok(r)
}

fn webp(bytes: Vec<u8>, cc: String) -> Reply {
    Reply::bytes(200, bytes, "image/webp").header("Cache-Control", cc)
}

fn placeholder(width: i64) -> Reply {
    Reply::text(200, mf::video_placeholder_svg(width), "image/svg+xml").header("Cache-Control", "public, max-age=20")
}

// ---- thumbnails ------------------------------------------------------------------------------------
pub fn image_thumb_path(app: &App, id: i64, w: i64) -> String {
    format!("{}/_thumb_cache/{id}_{w}.webp", app.settings.uploads_dir)
}

pub fn video_master_path(app: &App, id: i64) -> String {
    format!("{}/_thumb_cache/{}/{id}_master.webp", app.settings.uploads_dir, shard(id))
}

/// The video's master poster (or the largest cached width >= 520).
pub fn video_master(app: &App, id: i64) -> Option<String> {
    let m = video_master_path(app, id);
    if exists(&m) {
        return Some(m);
    }
    THUMB_WIDTHS.iter().rev().take_while(|w| **w >= 520).map(|w| format!("{}/_thumb_cache/{}/{id}_{w}.webp", app.settings.uploads_dir, shard(id))).find(|p| exists(p))
}

pub async fn youtube_thumb_bytes(app: &App, vid: &str) -> Option<Vec<u8>> {
    for variant in ["maxresdefault", "hqdefault"] {
        let url = format!("https://img.youtube.com/vi/{vid}/{variant}.jpg");
        for _ in 0..2 {
            if let Ok(r) = app.http.get(&url).timeout(std::time::Duration::from_secs(10)).send().await {
                if r.status().as_u16() == 200 {
                    if let Ok(b) = r.bytes().await {
                        if b.len() >= 2000 {
                            return Some(b.to_vec());
                        }
                    }
                    break;
                }
                if r.status().is_client_error() {
                    break;
                }
            }
        }
    }
    None
}

pub async fn make_youtube_master(app: &App, id: i64, vid: &str) -> Option<String> {
    let bytes = youtube_thumb_bytes(app, vid).await?;
    let rendered = mf::render_webp_from_bytes(&bytes, THUMB_MASTER_WIDTH, 90, None).await?;
    let path = video_master_path(app, id);
    write_atomic(&path, &rendered).await.then_some(path)
}

async fn render_from_image(src: &str, width: i64, cache: &str) -> Option<Vec<u8>> {
    let bytes = mf::render_webp_bytes_from_path(src, width, 86).await?;
    write_atomic(cache, &bytes).await;
    Some(bytes)
}

/// Render the master poster for a video in the background (shares the transcode cap).
pub fn spawn_video_master(app: &crate::app::AppRef, id: i64, item: Value, wait_for_slot: bool) {
    let app = app.clone();
    tokio::spawn(async move {
        let master = video_master_path(&app, id);
        let marker = format!("{master}.pending");
        if let Some(d) = std::path::Path::new(&master).parent() {
            let _ = tokio::fs::create_dir_all(d).await;
        }
        if let Ok(t) = tokio::fs::read_to_string(&marker).await {
            if t.trim().parse::<i64>().is_ok_and(|t| crate::util::now() - t < 120) || wait_for_slot {
                return;
            }
        }
        let mut slot = video::acquire_transcode_slot(&app);
        if wait_for_slot {
            for _ in 0..120 {
                if slot.is_some() {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                slot = video::acquire_transcode_slot(&app);
            }
        }
        let Some(slot) = slot else { return };
        let _ = tokio::fs::write(&marker, crate::util::now().to_string()).await;
        if let Some(src) = source_or_blob(&app, &item).await {
            mf::render_webp_scene_aware(&src, &master, THUMB_MASTER_WIDTH, 90, Some(0.35)).await;
        }
        let _ = tokio::fs::remove_file(&marker).await;
        let _ = tokio::fs::remove_file(&slot).await;
    });
}

/// Upload-time / backfill poster render (no-op when one exists or a custom thumb is set).
pub async fn prewarm_video_thumb(app: &crate::app::AppRef, id: i64, item: &Value) {
    let custom = app.db.opt("SELECT custom_thumb_path FROM media_items WHERE id=$1", &[id.into()]).await.and_then(|r| r.s("custom_thumb_path"));
    if custom.is_some() || video_master(app, id).is_some() {
        return;
    }
    if let Some(y) = item.s("youtube_video_id") {
        make_youtube_master(app, id, &y).await;
        return;
    }
    spawn_video_master(app, id, item.clone(), true);
}

pub async fn thumb(req: Req) -> R<Reply> {
    let id = mid(&req)?;
    let viewer = req.viewer().await;
    let app = req.app.clone();
    let item = fetch_for_bytes(&app, id).await.ok_or_else(|| Reply::err(404, "Media not found."))?;
    check_access(&req, &item, viewer).await?;
    let width = snap_width(req.qi("w").unwrap_or(520));
    let kind = item.s("media_kind").unwrap_or_default().to_lowercase();
    let cache = if kind == "video" { format!("{}/_thumb_cache/{}/{id}_{width}.webp", app.settings.uploads_dir, shard(id)) } else { image_thumb_path(&app, id, width) };
    let cc = image_cache_control(&item, 604800);
    if exists(&cache) {
        return file_reply(&req, &cache, "image/webp", &[("Cache-Control", cc)], false).await;
    }
    if kind == "video" {
        if let Some(src) = item.s("custom_thumb_path").and_then(|c| legacy_upload_path(&app.settings.uploads_dir, &c)) {
            if let Some(b) = render_from_image(&src, width, &cache).await {
                return Ok(webp(b, cc));
            }
        }
        let mut master = video_master(&app, id);
        if master.is_none() {
            if let Some(y) = item.s("youtube_video_id") {
                master = make_youtube_master(&app, id, &y).await;
            }
        }
        if let Some(m) = master {
            if let Some(b) = render_from_image(&m, width, &cache).await {
                return Ok(webp(b, cc));
            }
        }
        if item.s("youtube_video_id").is_none() {
            spawn_video_master(&app, id, item, false);
        }
        return Ok(placeholder(width));
    }
    let mut rendered = match source_path(&app, &item) {
        Some(src) => mf::render_webp_bytes_from_path(&src, width, 84).await,
        None => None,
    };
    if rendered.is_none() {
        if let Some(src) = db_blob_to_cache(&app, id, &item).await {
            rendered = mf::render_webp_bytes_from_path(&src, width, 84).await;
        }
    }
    match rendered {
        Some(b) => {
            write_atomic(&cache, &b).await;
            Ok(webp(b, cc))
        }
        None => Err(Reply::err(404, "File missing from database.")),
    }
}

pub async fn preview(req: Req) -> R<Reply> {
    let id = mid(&req)?;
    let viewer = req.viewer().await;
    let app = req.app.clone();
    let item = fetch_for_bytes(&app, id).await.filter(|i| i["deleted_at"].is_null()).ok_or_else(|| Reply::err(404, "Media not found."))?;
    check_access(&req, &item, viewer).await?;
    if item.s("media_kind").as_deref() != Some("image") {
        return file_response(req, id, false, None).await;
    }
    let size = req.q("size").filter(|s| preview_size(s).is_some()).unwrap_or_else(|| "card".into());
    let (edge, q) = preview_size(&size).unwrap();
    let cc = image_cache_control(&item, 604800);
    let cache = video::preview_cache_path(&app, id, &item, &size);
    if exists(&cache) {
        return file_reply(&req, &cache, "image/webp", &[("Cache-Control", cc)], false).await;
    }
    let src = source_or_blob(&app, &item).await.ok_or_else(|| Reply::err(404, "Preview is missing. Re-upload this post once so it can be saved into the new DB-backed file store."))?;
    match mf::render_webp_bytes_from_path(&src, edge, q).await {
        Some(b) => {
            write_atomic(&cache, &b).await;
            Ok(webp(b, cc))
        }
        None => file_reply(&req, &src, &item.s("mime_type").unwrap_or_else(|| "application/octet-stream".into()), &[("Cache-Control", "private, max-age=86400".into())], false).await,
    }
}

// ---- originals / downloads -----------------------------------------------------------------------
fn attachment(name: &str) -> String {
    format!("attachment; filename=\"{}\"", name.replace('"', ""))
}

async fn file_response(req: Req, id: i64, download: bool, quality: Option<String>) -> R<Reply> {
    let viewer = req.viewer().await;
    let app = req.app.clone();
    let item = fetch_by_id(&req, id, viewer).await.filter(|i| i["deleted_at"].is_null()).ok_or_else(|| Reply::err(404, "Media not found."))?;
    let owner = check_access_private_first(&req, &item, viewer, download).await?;
    let _ = owner;
    let mime = item.s("mime_type").unwrap_or_else(|| "application/octet-stream".into());
    let src = source_or_blob(&app, &item).await.ok_or_else(|| Reply::err(404, "File is missing. Re-upload this post once so it can be saved into the new DB-backed file store."))?;
    if download {
        let _ = app.db.exec("UPDATE media_items SET downloads=downloads+1 WHERE id=$1", &[id.into()]).await;
        let name = item.s("original_filename").unwrap_or_else(|| "download".into());
        return file_reply(&req, &src, &mime, &[("Content-Disposition", attachment(&name)), ("Cache-Control", "private, max-age=0, no-cache".into())], false).await;
    }
    let q = video::normalize_quality(quality.as_deref());
    if item.s("media_kind").as_deref() == Some("video") && q != "original" {
        if let Some(t) = video::ensure_quality_cache(&app, id, &item, &q, &src).await {
            return file_reply(&req, &t, "video/mp4", &[("Cache-Control", "public, max-age=86400".into()), ("X-Video-Quality", q), ("X-Video-Codec", "h264/aac".into())], true).await;
        }
    }
    file_reply(&req, &src, &mime, &[("Cache-Control", "public, max-age=86400".into())], true).await
}

/// serve_media_bytes_response's order: private, downloads-disabled, then 18+.
async fn check_access_private_first(req: &Req, item: &Value, viewer: Option<i64>, download: bool) -> R<bool> {
    let id = item.i("id").unwrap_or(0);
    let owner = viewer.is_some() && item.i("user_id") == viewer;
    if item.s("visibility").as_deref() == Some("private") && !owner && !token_ok(req, id) {
        return Err(Reply::err(403, "This post is private."));
    }
    if download && !tobool(item.get("downloads_enabled")) && !owner {
        return Err(Reply::err(403, "Downloads are disabled for this post."));
    }
    if tobool(item.get("is_adult")) && !token_ok(req, id) && !req.app.viewer_adult_allowed(viewer).await {
        return Err(Reply::err(403, "Age verification required for this 18+ post."));
    }
    Ok(owner)
}

pub async fn file(req: Req) -> R<Reply> {
    let id = mid(&req)?;
    let q = req.q("quality");
    file_response(req, id, false, q).await
}

pub async fn download(req: Req) -> R<Reply> {
    let id = mid(&req)?;
    file_response(req, id, true, None).await
}

/// Zip (store-only) of the allowed items; returns the temp zip path.
async fn build_zip(app: &App, items: &[Value], viewer: Option<i64>) -> Option<String> {
    let dir = mf::tmp_path(".zipdir");
    tokio::fs::create_dir_all(&dir).await.ok()?;
    let mut names = Vec::new();
    for it in items {
        let owner = viewer.is_some() && it.i("user_id") == viewer;
        if (it.s("visibility").as_deref() == Some("private") && !owner) || (!tobool(it.get("downloads_enabled")) && !owner) {
            continue;
        }
        let id = it.i("id").unwrap_or(0);
        let base = it.s("original_filename").unwrap_or_else(|| format!("media-{id}")).replace(['/', '\\'], "_");
        let name = format!("{id}-{base}");
        if let Some(src) = source_or_blob(app, it).await {
            if std::os::unix::fs::symlink(&src, format!("{dir}/{name}")).is_ok() {
                names.push(name);
            }
        }
    }
    let zip = format!("{dir}.zip");
    let ok = !names.is_empty() && {
        let mut c = tokio::process::Command::new("nice");
        c.args(["-n", "10", "zip", "-0", "-q"]).arg(&zip).args(&names).current_dir(&dir).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
        mf::run_ok(c).await && file_size(&zip) > 0
    };
    let _ = tokio::fs::remove_dir_all(&dir).await;
    if ok {
        Some(zip)
    } else {
        let _ = tokio::fs::remove_file(&zip).await;
        None
    }
}

/// Stream a temp zip and delete it once the response finished.
async fn zip_reply(req: &Req, zip: String, filename: &str) -> R<Reply> {
    let r = file_reply(req, &zip, "application/zip", &[("Content-Disposition", format!("attachment; filename=\"{filename}\""))], false).await;
    // The open file handle keeps the bytes readable after the unlink.
    let _ = tokio::fs::remove_file(&zip).await;
    r
}

pub async fn download_batch(req: Req) -> R<Reply> {
    let viewer = req.viewer().await;
    let key = viewer.map(|v| v.to_string()).unwrap_or_else(|| req.client_ip.clone());
    req.app.rate_check(&format!("download_batch:{key}"), 30, 3600).await?;
    let ids: Vec<i64> = req.json.get("media_ids").and_then(Value::as_array).into_iter().flatten().filter_map(|v| crate::util::vint(Some(v))).collect();
    if ids.is_empty() {
        return Err(Reply::err(400, "No posts selected."));
    }
    if ids.len() > 50 {
        return Err(Reply::err(400, "Select 50 or fewer posts at a time."));
    }
    let mut items = Vec::new();
    for id in ids {
        if let Some(it) = fetch_by_id(&req, id, viewer).await.filter(|i| i["deleted_at"].is_null()) {
            items.push(it);
        }
    }
    let zip = build_zip(&req.app, &items, viewer).await.ok_or_else(|| Reply::err(404, "None of the selected posts could be downloaded."))?;
    zip_reply(&req, zip, "gallery-selection.zip").await
}

pub async fn download_collection(req: Req) -> R<Reply> {
    let viewer = req.viewer().await;
    let detail = crate::routes::collections::detail_json(&req).await?;
    let items = detail["media"].as_array().cloned().unwrap_or_default();
    if items.is_empty() {
        return Err(Reply::err(404, "This collection has no downloadable posts."));
    }
    // The detail rows are already shaped; re-read raw rows for paths.
    let mut raw = Vec::new();
    for it in &items {
        if let Some(r) = fetch_by_id(&req, it.i("id").unwrap_or(0), viewer).await {
            raw.push(r);
        }
    }
    let zip = build_zip(&req.app, &raw, viewer).await.ok_or_else(|| Reply::err(404, "None of the posts in this collection could be downloaded."))?;
    let name = vstr(detail["collection"].get("name")).unwrap_or_else(|| "collection".into());
    let safe: String = name.chars().filter(|c| c.is_ascii_alphanumeric() || "-_ ".contains(*c)).collect();
    let safe = crate::util::cut(&safe.split_whitespace().collect::<Vec<_>>().join("-"), 60);
    let safe = if safe.is_empty() { "collection".to_string() } else { safe };
    zip_reply(&req, zip, &format!("{safe}.zip")).await
}

// ---- avatars ----------------------------------------------------------------------------------------
pub async fn avatar(req: Req) -> R<Reply> {
    let Some(uid_) = req.pi("user_id") else { return Err(Reply::err(404, "User not found.")) };
    let app = req.app.clone();
    let cc = "public, max-age=86400".to_string();
    let meta = app.db.opt("SELECT f.id, f.sha256, f.mime_type FROM user_avatar_files f JOIN users u ON u.avatar_file_id = f.id WHERE u.id = $1", &[uid_.into()]).await;
    if let Some(m) = meta.as_ref().filter(|m| m.s("mime_type").as_deref() != Some("image/gif")) {
        let sha = m.s("sha256").unwrap_or_default();
        let path = format!("{}/_preview_cache/avatars/{uid_}_{}_{}.webp", app.settings.uploads_dir, m.i("id").unwrap_or(0), crate::util::cut(sha.trim(), 12));
        if exists(&path) {
            return file_reply(&req, &path, "image/webp", &[("Cache-Control", cc)], false).await;
        }
        if let Some((_, content)) = mf::get_avatar_file(&app.db, uid_).await {
            if let Some(r) = mf::render_webp_from_bytes(&content, 256, 86, None).await.filter(|r| !r.is_empty() && r.len() < content.len()) {
                write_atomic(&path, &r).await;
                return Ok(webp(r, cc));
            }
            let mime = m.s("mime_type").unwrap_or_else(|| "image/jpeg".into());
            return Ok(Reply::bytes(200, content, &mime).header("Cache-Control", cc));
        }
    }
    if let Some((info, content)) = mf::get_avatar_file(&app.db, uid_).await.filter(|(_, c)| !c.is_empty()) {
        return Ok(Reply::bytes(200, content, &info.s("mime_type").unwrap_or_else(|| "image/jpeg".into())).header("Cache-Control", cc));
    }
    if let Some(u) = app.get_user(uid_).await {
        if let Some(p) = u.s("avatar_path").and_then(|p| legacy_upload_path(&app.settings.uploads_dir, &p)) {
            let mime = u.s("avatar_mime_type").unwrap_or_else(|| "image/jpeg".into());
            return file_reply(&req, &p, &mime, &[("Cache-Control", cc)], false).await;
        }
    }
    let svg = format!(
        "<svg xmlns='http://www.w3.org/2000/svg' width='128' height='128' viewBox='0 0 128 128'><rect width='128' height='128' rx='64' fill='#202832'/><text x='64' y='74' text-anchor='middle' font-family='Inter,Arial,sans-serif' font-size='34' font-weight='800' fill='#9ba8b7'>U{uid_}</text></svg>"
    );
    Ok(Reply::text(200, svg, "image/svg+xml").header("Cache-Control", "public, max-age=3600"))
}

// ---- HLS -----------------------------------------------------------------------------------------
fn propagated_qs(req: &Req) -> String {
    if let Some(a) = req.q("access") {
        return format!("?access={a}");
    }
    req.q("key").map(|k| format!("?key={k}")).unwrap_or_default()
}

/// (stream row, publicly cacheable) after the byte-route access rules.
pub async fn hls_access(req: &Req, id: i64) -> R<(Value, bool)> {
    let viewer = req.viewer().await;
    let item = req
        .app
        .db
        .opt(
            "SELECT id, user_id, media_kind, mime_type, original_filename, storage_path, file_size, created_at, updated_at, visibility, is_adult, deleted_at, content_sha256 FROM media_items WHERE id = $1",
            &[id.into()],
        )
        .await
        .filter(|i| i["deleted_at"].is_null())
        .ok_or_else(|| Reply::err(404, "Media not found."))?;
    check_access(req, &item, viewer).await?;
    if item.s("media_kind").as_deref() != Some("video") {
        return Err(Reply::err(404, "Not a video."));
    }
    let public = item.s("visibility").as_deref() != Some("private") && (!tobool(item.get("is_adult")) || token_ok(req, id));
    Ok((item, public))
}

const M3U8: &str = "application/vnd.apple.mpegurl";

pub async fn hls_master(req: Req) -> R<Reply> {
    let id = mid(&req)?;
    let (_, public) = hls_access(&req, id).await?;
    let qs = propagated_qs(&req);
    let mut lines = vec!["#EXTM3U".to_string(), "#EXT-X-VERSION:6".into(), "#EXT-X-STREAM-INF:BANDWIDTH=8000000,NAME=\"Original\"".into(), format!("/api/media/{id}/hls/original/playlist.m3u8{qs}")];
    for q in video::QUALITIES {
        lines.push(format!("#EXT-X-STREAM-INF:BANDWIDTH={},NAME=\"{q}\"", video::bandwidth(q)));
        lines.push(format!("/api/media/{id}/hls/{q}/playlist.m3u8{qs}"));
    }
    Ok(Reply::text(200, lines.join("\n") + "\n", M3U8).header("Cache-Control", if public { "public, max-age=31536000, immutable" } else { "no-cache" }))
}

fn best_ready(app: &App, id: i64, item: &Value, quality: &str) -> Option<String> {
    let ladder = ["144p", "480p", "720p", "1080p", "original"];
    let seed = video::digest_seed(id, item);
    let at = ladder.iter().position(|q| *q == quality);
    let mut order: Vec<&str> = ladder[..at.unwrap_or(ladder.len())].iter().rev().copied().collect();
    if let Some(a) = at {
        order.extend(ladder[a + 1..].iter().copied());
    }
    order.into_iter().find(|q| video::variant_ready(&video::variant_dir(app, id, q, &seed))).map(str::to_string)
}

fn redirect_quality(id: i64, q: &str, qs: &str) -> Reply {
    Reply { status: 302, payload: crate::http::Payload::Empty, headers: vec![("Location".into(), format!("/api/media/{id}/hls/{q}/playlist.m3u8{qs}")), ("Cache-Control".into(), "no-store".into())] }
}

pub async fn hls_playlist(req: Req) -> R<Reply> {
    let id = mid(&req)?;
    let quality = video::normalize_quality(Some(&req.p("quality")));
    let (item, public) = hls_access(&req, id).await?;
    let app = req.app.clone();
    let qs = propagated_qs(&req);
    let dir = match video::ensure_hls_variant(&app, id, &item, &quality, HlsOpts { warmer: false, source_path: source_path(&app, &item) }).await {
        Ok(d) => d,
        Err(HlsErr::Missing) => return Err(Reply::err(404, "File is missing.")),
        Err(e @ (HlsErr::Busy | HlsErr::Gpu)) => {
            if let Some(q) = best_ready(&app, id, &item, &quality).filter(|q| *q != quality) {
                return Ok(redirect_quality(id, &q, &qs));
            }
            let (msg, retry) = match e {
                HlsErr::Busy => ("Server is busy transcoding other videos right now. Try again in a few seconds.", "5"),
                _ => ("Video transcoding hardware is temporarily unavailable. Try again later.", "15"),
            };
            return Err(Reply::err(503, msg).header("Retry-After", retry));
        }
        Err(HlsErr::Unavailable) => return Err(Reply::err(404, "This quality is not available for this video.")),
    };
    if !video::variant_ready(&dir) {
        if let Some(q) = best_ready(&app, id, &item, &quality).filter(|q| *q != quality) {
            return Ok(redirect_quality(id, &q, &qs));
        }
    }
    video::touch_heartbeat(&dir);
    let path = format!("{dir}/playlist.m3u8");
    for _ in 0..80 {
        if let Ok(text) = tokio::fs::read_to_string(&path).await {
            if text.contains("#EXTINF") {
                let text = if qs.is_empty() {
                    text
                } else {
                    text.lines().map(|l| if l.starts_with("seg_") && l.ends_with(".ts") { format!("{l}{qs}") } else { l.to_string() }).collect::<Vec<_>>().join("\n") + "\n"
                };
                let cc = if public && video::variant_ready(&dir) { "public, max-age=31536000, immutable" } else { "no-cache" };
                return Ok(Reply::text(200, text, M3U8).header("Cache-Control", cc));
            }
        }
        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
    }
    Err(Reply::err(503, "This video is still starting up -- try again in a moment.").header("Retry-After", "3"))
}

pub async fn hls_segment(req: Req) -> R<Reply> {
    let id = mid(&req)?;
    let quality = video::normalize_quality(Some(&req.p("quality")));
    let seg = req.p("segment");
    let valid = seg.strip_prefix("seg_").and_then(|r| r.strip_suffix(".ts")).is_some_and(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()));
    if !valid {
        return Err(Reply::err(404, "Not found."));
    }
    let (item, public) = hls_access(&req, id).await?;
    let dir = video::variant_dir(&req.app, id, &quality, &video::digest_seed(id, &item));
    let path = format!("{dir}/{seg}");
    if !exists(&path) {
        return Err(Reply::err(404, "Segment not found."));
    }
    video::touch_heartbeat(&dir);
    file_reply(&req, &path, "video/mp2t", &[("Cache-Control", format!("{}, max-age=86400", if public { "public" } else { "private" }))], false).await
}

// ---- custom video thumbnails ------------------------------------------------------------------------
fn custom_thumb_ext(content: &[u8]) -> Result<&'static str, String> {
    if content.is_empty() {
        return Err("Choose an image for the thumbnail.".into());
    }
    if content.len() > 15 * 1024 * 1024 {
        return Err("Thumbnail images must be 15MB or smaller.".into());
    }
    match crate::sniff::sniff_magic(&content[..content.len().min(512)]) {
        Some(("image/jpeg", _)) => Ok(".jpg"),
        Some(("image/png", _)) => Ok(".png"),
        Some(("image/webp", _)) => Ok(".webp"),
        Some(("image/gif", _)) => Ok(".gif"),
        _ => Err("Thumbnails must be a JPEG, PNG, WEBP or GIF image.".into()),
    }
}

fn clear_thumb_cache(app: &App, id: i64) {
    let base = format!("{}/_thumb_cache", app.settings.uploads_dir);
    let prefix = format!("{id}_");
    for dir in [format!("{base}/{}", shard(id)), base] {
        if let Ok(rd) = std::fs::read_dir(&dir) {
            for e in rd.flatten() {
                if e.file_name().to_string_lossy().starts_with(&prefix) && e.path().is_file() {
                    let _ = std::fs::remove_file(e.path());
                }
            }
        }
    }
}

pub async fn set_custom_thumb(app: &App, id: i64, content: Option<&[u8]>, ext: &str) -> Result<(), String> {
    let mut rel = None;
    if let Some(c) = content {
        let r = format!("custom_thumbs/{}/{id}_{}{ext}", shard(id), &mf::sha256_bytes(c)[..16]);
        let root = mf::hot_root().unwrap_or_else(|| app.settings.uploads_dir.clone());
        if !write_atomic(&format!("{root}/{r}"), c).await {
            return Err("Could not save thumbnail: write failed".into());
        }
        rel = Some(r);
    }
    let old = app.db.opt("SELECT custom_thumb_path FROM media_items WHERE id=$1", &[id.into()]).await.and_then(|r| r.s("custom_thumb_path"));
    app.db.exec("UPDATE media_items SET custom_thumb_path=$1, updated_at=now() WHERE id=$2", &[rel.clone().into(), id.into()]).await.map_err(|e| format!("Could not save thumbnail: {e}"))?;
    if let Some(o) = old.filter(|o| Some(o) != rel.as_ref()) {
        for root in [Some(app.settings.uploads_dir.clone()), mf::hot_root()].into_iter().flatten() {
            let _ = std::fs::remove_file(format!("{root}/{o}"));
        }
    }
    clear_thumb_cache(app, id);
    Ok(())
}

async fn owned_video(req: &Req) -> R<(Value, i64)> {
    let user = req.current_user().await?;
    let id = req.pi("media_id");
    let row = match id {
        Some(i) => req.app.db.opt("SELECT id, user_id, media_kind, deleted_at FROM media_items WHERE id=$1", &[i.into()]).await,
        None => None,
    };
    let row = row.filter(|r| r["deleted_at"].is_null()).ok_or_else(|| Reply::err(404, "Media not found."))?;
    if row.i("user_id") != Some(uid(&user)) {
        return Err(Reply::err(403, "Only the uploader can change this post's thumbnail."));
    }
    if row.s("media_kind").as_deref() != Some("video") {
        return Err(Reply::err(400, "Custom thumbnails are for videos."));
    }
    Ok((user, id.unwrap()))
}

async fn media_out(req: &Req, user: &Value, id: i64) -> R<Reply> {
    let u = uid(user);
    let mut item = fetch_by_id(req, id, Some(u)).await.ok_or_else(|| Reply::err(404, "Media not found."))?;
    let adult = req.app.viewer_adult_allowed(Some(u)).await;
    decode_media_row(req, &mut item, adult);
    Ok(Reply::ok(json!({ "media": item })))
}

pub async fn set_thumbnail(req: Req) -> R<Reply> {
    let (user, id) = owned_video(&req).await?;
    let content = req.file("file").map(|f| f.data.to_vec()).unwrap_or_default();
    let ext = custom_thumb_ext(&content).map_err(|e| Reply::err(400, e))?;
    set_custom_thumb(&req.app, id, Some(&content), ext).await.map_err(|e| Reply::err(500, e))?;
    media_out(&req, &user, id).await
}

pub async fn clear_thumbnail(req: Req) -> R<Reply> {
    let (user, id) = owned_video(&req).await?;
    set_custom_thumb(&req.app, id, None, "").await.map_err(|e| Reply::err(500, e))?;
    media_out(&req, &user, id).await
}

pub fn staging_dir(app: &App) -> String {
    if app.settings.hot_dir.is_empty() { app.settings.uploads_dir.clone() } else { format!("{}/staging", app.settings.hot_dir) }
}

pub async fn stage_thumbnail(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let content = req.file("file").map(|f| f.data.to_vec()).unwrap_or_default();
    let ext = custom_thumb_ext(&content).map_err(|e| Reply::err(400, e))?;
    let token = crate::auth::random_hex(16);
    let dir = staging_dir(&req.app);
    let _ = tokio::fs::create_dir_all(&dir).await;
    let path = format!("{dir}/_thumb_stage_{}_{token}{ext}", uid(&user));
    tokio::fs::write(&path, &content).await.map_err(|e| Reply::err(500, format!("Could not stage thumbnail: {e}")))?;
    Ok(Reply::ok(json!({ "thumbnail_token": token })))
}

/// Attach a thumbnail staged before the upload finished.
pub async fn attach_staged_thumbnail(app: &App, user_id: i64, media_id: i64, token: &str, is_video: bool) {
    if token.is_empty() || !token.chars().all(|c| c.is_ascii_hexdigit()) {
        return;
    }
    for ext in [".jpg", ".png", ".webp", ".gif"] {
        let path = format!("{}/_thumb_stage_{user_id}_{token}{ext}", staging_dir(app));
        if let Ok(content) = tokio::fs::read(&path).await {
            let _ = tokio::fs::remove_file(&path).await;
            if is_video {
                if let Ok(e) = custom_thumb_ext(&content) {
                    let _ = set_custom_thumb(app, media_id, Some(&content), e).await;
                }
            }
            return;
        }
    }
}

pub async fn media_picker(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    let q = crate::util::cut(req.q("q").unwrap_or_default().trim(), 120);
    let limit = req.qi("limit").unwrap_or(36).clamp(1, 60);
    let offset = req.qi("offset").unwrap_or(0).clamp(0, 100000);
    let direct = q.trim_start_matches('#').parse::<i64>().ok().filter(|_| q.trim_start_matches('#').chars().all(|c| c.is_ascii_digit())).or_else(|| {
        q.find("/media/").and_then(|i| q[i + 7..].chars().take_while(char::is_ascii_digit).collect::<String>().parse().ok())
    });
    let mut s = crate::db::Sql::new();
    let mut w = vec![format!("m.user_id={}", s.bind(u)), "m.deleted_at IS NULL".into(), "jsonb_array_length(COALESCE(m.tags::jsonb, '[]'::jsonb)) > 0".into()];
    if let Some(d) = direct {
        w.push(format!("m.id={}", s.bind(d)));
    } else if !q.is_empty() {
        let mut like = String::from("%");
        for c in q.chars() {
            if "%_\\".contains(c) {
                like.push('\\');
            }
            like.push(c);
        }
        like.push('%');
        let p = s.bind(like);
        w.push(format!("(m.title ILIKE {p} OR m.tags::text ILIKE {p})"));
    }
    let (l, o) = (s.bind(limit + 1), s.bind(offset));
    let sql = format!(
        "SELECT m.id, m.user_id, m.title, m.tags, m.media_kind, m.mime_type, m.original_filename, m.updated_at, m.created_at, m.visibility, m.is_adult, c.name AS category_name \
         FROM media_items m JOIN categories c ON c.id = m.category_id WHERE {} ORDER BY m.created_at DESC, m.id DESC LIMIT {l} OFFSET {o}",
        w.join(" AND ")
    );
    let rows = req.app.db.query(&sql, &s.params).await.map_err(crate::media::query_failed)?;
    let adult = req.app.viewer_adult_allowed(Some(u)).await;
    let has_more = rows.len() as i64 > limit;
    let items: Vec<Value> = rows
        .into_iter()
        .take(limit as usize)
        .map(|mut r| {
            r["is_adult"] = json!(tobool(r.get("is_adult")));
            let tags = crate::util::json_list(r.get("tags"));
            crate::media::with_urls(&req, &mut r, adult);
            json!({ "id": r["id"], "title": r["title"], "media_kind": r["media_kind"], "category_name": r["category_name"], "created_at": r["created_at"], "visibility": r["visibility"], "tags": tags, "thumb_url": r["thumb_url"] })
        })
        .collect();
    Ok(Reply::ok(json!({ "items": items, "has_more": has_more })))
}
