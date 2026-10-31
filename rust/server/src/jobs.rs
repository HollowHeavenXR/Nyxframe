//! Background loops (one process, so no primary-worker gating): GPU warmer,
//! image rendition warmer, stale-transcode cleanup, HLS idle reaper,
//! deleted-media purge, cache-orphan sweep, expiry sweep, thumbnail and
//! codec backfills, upload recovery, hot-tier mover, weekly digest.

use crate::app::{App, AppRef};
use crate::db::J;
use crate::media_files as mf;
use crate::serve;
use crate::video::{self, HlsOpts};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant, SystemTime};

fn secs(n: u64) -> Duration {
    Duration::from_secs(n)
}

fn load1() -> Option<f64> {
    std::fs::read_to_string("/proc/loadavg").ok()?.split_whitespace().next()?.parse().ok()
}

fn ncpu() -> f64 {
    std::thread::available_parallelism().map(|n| n.get() as f64).unwrap_or(1.0)
}

fn system_busy() -> bool {
    load1().is_some_and(|l| l > ncpu() * 0.7)
}

fn env_num(k: &str, d: f64) -> f64 {
    std::env::var(k).ok().and_then(|v| v.parse().ok()).unwrap_or(d)
}

fn age_secs(p: &std::path::Path) -> Option<u64> {
    std::fs::metadata(p).ok()?.modified().ok().and_then(|m| SystemTime::now().duration_since(m).ok()).map(|d| d.as_secs())
}

fn dir_size(p: &std::path::Path) -> u64 {
    let mut total = 0;
    let mut stack = vec![p.to_path_buf()];
    while let Some(d) = stack.pop() {
        if let Ok(rd) = std::fs::read_dir(&d) {
            for e in rd.flatten() {
                match e.metadata() {
                    Ok(m) if m.is_dir() => stack.push(e.path()),
                    Ok(m) => total += m.len(),
                    _ => {}
                }
            }
        }
    }
    total
}

/// Run `f` forever with `pause` between runs; telemetry records each run.
fn spawn_loop<F, Fut>(app: &AppRef, name: &'static str, first_delay: u64, pause: u64, f: F)
where
    F: Fn(AppRef) -> Fut + Send + 'static,
    Fut: std::future::Future<Output = Option<Value>> + Send,
{
    let app = app.clone();
    tokio::spawn(async move {
        tokio::time::sleep(secs(first_delay)).await;
        loop {
            let t0 = Instant::now();
            let summary = f(app.clone()).await;
            app.telemetry.job_result(name, true, t0.elapsed().as_millis() as i64, summary);
            tokio::time::sleep(secs(pause)).await;
        }
    });
}

// ---- image renditions ------------------------------------------------------------------------------
/// Pre-render grid (640), lightbox (1280) and detail preview sizes in one ffmpeg pass.
pub async fn warm_image_renditions(app: &App, item: &Value, nice: i32) -> usize {
    let id = item.i("id").unwrap_or(0);
    let mime = item.s("mime_type").unwrap_or_default().to_lowercase();
    let name = item.s("original_filename").or(item.s("storage_path")).unwrap_or_default().to_lowercase();
    if mime == "image/gif" || name.ends_with(".gif") {
        return 0;
    }
    let (de, dq) = serve::preview_size("detail").unwrap();
    let wanted = [
        (serve::image_thumb_path(app, id, serve::GRID_WIDTH), serve::GRID_WIDTH, 84),
        (serve::image_thumb_path(app, id, serve::LIGHTBOX_WIDTH), serve::LIGHTBOX_WIDTH, 84),
        (video::preview_cache_path(app, id, item, "detail"), de, dq),
    ];
    let missing: Vec<mf::WebpOut> = wanted.into_iter().filter(|(p, _, _)| !mf::exists(p)).map(|(dst, max_edge, quality)| mf::WebpOut { dst, max_edge, quality, compression_level: 4 }).collect();
    if missing.is_empty() {
        return 0;
    }
    let Some(src) = serve::source_path(app, item) else { return 0 };
    for o in &missing {
        if let Some(d) = std::path::Path::new(&o.dst).parent() {
            let _ = tokio::fs::create_dir_all(d).await;
        }
    }
    mf::render_webp_multi(&src, &missing, nice).await.into_iter().filter(|b| *b).count()
}

fn start_image_warmer(app: &AppRef) {
    let app = app.clone();
    tokio::spawn(async move {
        tokio::time::sleep(secs(30)).await;
        let cols = "m.id, m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.created_at, m.updated_at";
        let base = "m.media_kind = 'image' AND m.deleted_at IS NULL";
        let (mut cursor, mut total) = (None::<i64>, 0usize);
        loop {
            let t0 = Instant::now();
            let recent = app.db.all(&format!("SELECT {cols} FROM media_items m WHERE {base} AND m.created_at > now() - interval '15 minutes' ORDER BY m.id DESC LIMIT 50"), &[]).await;
            let rows = match cursor {
                Some(c) => app.db.all(&format!("SELECT {cols} FROM media_items m WHERE {base} AND m.id < $1 ORDER BY m.id DESC LIMIT 25"), &[c.into()]).await,
                None => app.db.all(&format!("SELECT {cols} FROM media_items m WHERE {base} ORDER BY m.id DESC LIMIT 25"), &[]).await,
            };
            for r in recent.iter().chain(rows.iter()) {
                while system_busy() {
                    tokio::time::sleep(secs(20)).await;
                }
                let n = warm_image_renditions(&app, r, 19).await;
                if n > 0 {
                    total += n;
                    tokio::time::sleep(Duration::from_millis(250)).await;
                }
            }
            if rows.is_empty() {
                if total > 0 {
                    println!("[nyxframe] image warmer: pass done, {total} renditions");
                }
                app.telemetry.job_result("image_warmer", true, t0.elapsed().as_millis() as i64, Some(json!({ "event": "pass_done", "rendered": total })));
                cursor = None;
                total = 0;
                tokio::time::sleep(secs(60)).await;
                continue;
            }
            cursor = rows.last().and_then(|r| r.i("id"));
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
    });
}

// ---- GPU warmer ---------------------------------------------------------------------------------------
fn start_media_warmer(app: &AppRef) {
    let app = app.clone();
    tokio::spawn(async move {
        let max_load = env_num("GALLERY_WARMER_MAX_LOAD", 4.0);
        let watch_idle = env_num("GALLERY_WARMER_WATCH_IDLE_SECONDS", 120.0) as i64;
        let revalidate = env_num("GALLERY_WARMER_REVALIDATE_SECONDS", 1800.0) as u64;
        let mut ready: HashSet<String> = HashSet::new();
        let mut ready_since = Instant::now();
        let mut cursor = 0i64;
        loop {
            let t0 = Instant::now();
            if ready_since.elapsed().as_secs() >= revalidate || ready.len() >= 5000 {
                ready.clear();
                ready_since = Instant::now();
            }
            let status: &str = 'pass: {
                if load1().is_some_and(|l| l > max_load) || video::active_slots(&app) > 0 {
                    break 'pass "busy";
                }
                let rows = app
                    .db
                    .all(
                        "SELECT id, user_id, storage_path, mime_type, original_filename, file_size, media_kind, updated_at, created_at, content_sha256, video_codecs \
                         FROM media_items WHERE media_kind='video' AND deleted_at IS NULL AND id > $1 ORDER BY id ASC LIMIT 25",
                        &[cursor.into()],
                    )
                    .await;
                if rows.is_empty() {
                    cursor = 0;
                    break 'pass "wrap";
                }
                for item in rows {
                    let id = item.i("id").unwrap_or(0);
                    cursor = id;
                    let size = item.i("file_size").unwrap_or(0);
                    let seed = video::digest_seed(id, &item);
                    let mut todo: Vec<&str> = vec![];
                    if size > 0 && size <= video::TRANSCODE_SIZE_LIMIT {
                        todo.extend(["480p", "720p", "1080p", "144p"]);
                    }
                    if !crate::media::direct_playable(&item) {
                        todo.push("original");
                    }
                    for q in todo {
                        let dir = video::variant_dir(&app, id, q, &seed);
                        if ready.contains(&dir) {
                            continue;
                        }
                        if video::variant_ready(&dir) {
                            ready.insert(dir);
                            continue;
                        }
                        if !video::slot_available(&app) || video::someone_is_watching(&app, watch_idle.max(60)) {
                            break 'pass "busy";
                        }
                        let _ = video::ensure_hls_variant(&app, id, &item, q, HlsOpts { warmer: true, source_path: serve::source_path(&app, &item) }).await;
                        break 'pass "launched";
                    }
                }
                "batch_done"
            };
            let summary = (status == "launched").then(|| json!({ "event": "launched", "cursor": cursor }));
            app.telemetry.job_result("media_warmer", true, t0.elapsed().as_millis() as i64, summary);
            let pause = match status {
                "wrap" => 120,
                "busy" => 60,
                "launched" => 15,
                _ => 1,
            };
            tokio::time::sleep(secs(pause)).await;
        }
    });
}

// ---- cleanup / reaper ---------------------------------------------------------------------------------
async fn stale_cleanup(app: AppRef) -> Option<Value> {
    let up = app.settings.uploads_dir.clone();
    let res = tokio::task::spawn_blocking(move || {
        let (mut removed, mut freed) = (0u64, 0u64);
        let mut sweep = |dir: String, pred: &dyn Fn(&str) -> bool| {
            if let Ok(rd) = std::fs::read_dir(&dir) {
                for e in rd.flatten() {
                    let n = e.file_name().to_string_lossy().to_string();
                    let p = e.path();
                    if p.is_file() && pred(&n) && age_secs(&p).is_some_and(|a| a > 3600) {
                        let s = std::fs::metadata(&p).map(|m| m.len()).unwrap_or(0);
                        if std::fs::remove_file(&p).is_ok() {
                            removed += 1;
                            freed += s;
                        }
                    }
                }
            }
        };
        sweep(format!("{up}/_video_cache"), &|n| n.ends_with(".pending") || (n.contains(".src.") && n.ends_with(".bin")) || (n.contains(".tmp.") && n.ends_with(".mp4")));
        sweep(format!("{up}/_upload_tmp"), &|n| n.ends_with(".src") || n.ends_with(".out"));
        if let Ok(rd) = std::fs::read_dir(format!("{up}/_hls_cache")) {
            for e in rd.flatten() {
                let n = e.file_name().to_string_lossy().to_string();
                let Some(variant) = n.strip_suffix(".pending") else { continue };
                let vdir = format!("{up}/_hls_cache/{variant}");
                if age_secs(&e.path()).is_some_and(|a| a > 3600) && !video::variant_ready(&vdir) {
                    freed += dir_size(std::path::Path::new(&vdir));
                    let _ = std::fs::remove_dir_all(&vdir);
                    let _ = std::fs::remove_file(e.path());
                    removed += 1;
                }
            }
        }
        (removed, freed)
    })
    .await
    .unwrap_or((0, 0));
    (res.0 > 0).then(|| {
        println!("[nyxframe] stale transcode cleanup: removed {} item(s), freed {} bytes", res.0, res.1);
        json!({ "removed": res.0, "freed_bytes": res.1 })
    })
}

async fn reap_idle(app: AppRef) -> Option<Value> {
    let root = format!("{}/_hls_cache", app.settings.uploads_dir);
    let now = crate::util::now();
    let mut reaped = 0;
    let mut viewers: Option<bool> = None;
    let Ok(rd) = std::fs::read_dir(&root) else { return None };
    let dirs: Vec<String> = rd.flatten().filter(|e| e.path().join(".pid").exists()).map(|e| e.path().to_string_lossy().to_string()).collect();
    let read_num = |p: String| std::fs::read_to_string(p).ok().and_then(|s| s.trim().chars().take_while(|c| c.is_ascii_digit() || *c == '.').collect::<String>().parse::<f64>().ok());
    for dir in dirs {
        tokio::task::yield_now().await;
        let Some(pid) = read_num(format!("{dir}/.pid")).map(|p| p as i64) else { continue };
        if !video::ffmpeg_running(pid) || video::variant_ready(&dir) {
            continue;
        }
        let last = read_num(format!("{dir}/.last_watched")).map(|t| t as i64);
        let warm = std::path::Path::new(&format!("{dir}/.warm")).exists();
        let kill = if last.is_none() && warm {
            *viewers.get_or_insert_with(|| video::someone_is_watching(&app, 120))
        } else if let Some(l) = last {
            let just_launched = read_num(format!("{dir}.pending")).is_some_and(|t| now - (t as i64) < 90);
            let nearly_done = match (read_num(format!("{dir}/.expected_duration")), std::fs::read_to_string(format!("{dir}/playlist.m3u8"))) {
                (Some(e), Ok(t)) if e > 0.0 => video::playlist_duration(&t) >= e * 0.8,
                _ => false,
            };
            now - l > 25 && !just_launched && !nearly_done
        } else {
            false
        };
        if kill && video::ffmpeg_running(pid) && std::process::Command::new("kill").args(["-TERM", &pid.to_string()]).status().is_ok_and(|s| s.success()) {
            reaped += 1;
        }
    }
    (reaped > 0).then(|| {
        println!("[nyxframe] hls idle reaper: stopped {reaped} abandoned transcode(s)");
        json!({ "reaped": reaped })
    })
}

// ---- storage sweeps -----------------------------------------------------------------------------------
async fn deleted_purge(app: AppRef) -> Option<Value> {
    let days = app.settings.deleted_media_retention_days.max(1);
    let rows = app.db.all("SELECT id, storage_path FROM media_items WHERE deleted_at IS NOT NULL AND deleted_at < now() - ($1 || ' days')::interval", &[days.to_string().into()]).await;
    let (mut rows_n, mut files, mut freed) = (0u64, 0u64, 0u64);
    let roots: Vec<String> = [Some(app.settings.uploads_dir.clone()), mf::hot_root()].into_iter().flatten().collect();
    for r in rows {
        let id = r.i("id").unwrap_or(0);
        if app.db.exec("DELETE FROM media_items WHERE id=$1 AND deleted_at IS NOT NULL", &[id.into()]).await.unwrap_or(0) == 0 {
            continue;
        }
        rows_n += 1;
        let Some(sp) = r.s("storage_path") else { continue };
        if app.db.opt("SELECT id FROM media_items WHERE storage_path=$1 LIMIT 1", &[sp.as_str().into()]).await.is_some() || sp.contains("..") {
            continue;
        }
        for root in &roots {
            let p = format!("{root}/{sp}");
            let s = mf::file_size(&p);
            if std::fs::remove_file(&p).is_ok() {
                files += 1;
                freed += s;
            }
        }
    }
    if rows_n == 0 {
        return None;
    }
    println!("[nyxframe] deleted-media purge: permanently removed {rows_n} post(s), {files} file(s), freed {freed} bytes");
    crate::routes::admin::audit(&app, None, "deleted_media_purge", "storage", None, Some(format!("removed={rows_n} files={files} bytes={freed}"))).await;
    Some(json!({ "removed_rows": rows_n, "removed_files": files, "freed_bytes": freed }))
}

async fn orphan_sweep(app: AppRef) -> Option<Value> {
    let rows = app.db.all("SELECT id, content_sha256, updated_at, created_at FROM media_items WHERE deleted_at IS NULL", &[]).await;
    let mut tkeys: HashMap<String, String> = HashMap::new();
    let mut okeys: HashMap<String, String> = HashMap::new();
    for r in &rows {
        let id = r.i("id").unwrap_or(0);
        tkeys.insert(id.to_string(), crate::auth::sha256_hex(&video::digest_seed(id, r))[..16].to_string());
        let oseed = r.s("updated_at").or(r.s("created_at")).unwrap_or_else(|| id.to_string());
        okeys.insert(id.to_string(), crate::auth::sha256_hex(&oseed)[..16].to_string());
    }
    let up = app.settings.uploads_dir.clone();
    let (removed, freed) = tokio::task::spawn_blocking(move || {
        let (mut removed, mut freed) = (0u64, 0u64);
        // "<id>_<quality>_<key>[.ext]" or "<id>_<key>[.ext]"
        let parse = |name: &str, quality_style: bool| -> Option<(String, String)> {
            let stem = name.rsplit_once('.').map(|(s, _)| s).unwrap_or(name);
            let parts: Vec<&str> = stem.split('_').collect();
            let (id, key) = if quality_style && parts.len() == 3 { (parts[0], parts[2]) } else if !quality_style && parts.len() == 2 { (parts[0], parts[1]) } else { return None };
            (id.chars().all(|c| c.is_ascii_digit()) && !id.is_empty() && key.chars().all(|c| c.is_ascii_hexdigit()) && !key.is_empty()).then(|| (id.to_string(), key.to_string()))
        };
        let mut sweep = |dir: &str, keys: &HashMap<String, String>, quality_style: bool, dirs: bool| {
            let Ok(rd) = std::fs::read_dir(dir) else { return };
            for e in rd.flatten() {
                let p = e.path();
                if p.is_dir() != dirs {
                    continue;
                }
                let name = e.file_name().to_string_lossy().to_string();
                let Some((id, key)) = parse(&name, quality_style) else { continue };
                if !age_secs(&p).is_some_and(|a| a > 86400) {
                    continue;
                }
                let purge = match keys.get(&id) {
                    None => true,
                    Some(k) => *k != key,
                };
                if purge {
                    let s = if dirs { dir_size(&p) } else { std::fs::metadata(&p).map(|m| m.len()).unwrap_or(0) };
                    let ok = if dirs { std::fs::remove_dir_all(&p).is_ok() } else { std::fs::remove_file(&p).is_ok() };
                    if ok {
                        removed += 1;
                        freed += s;
                    }
                }
            }
        };
        sweep(&format!("{up}/_video_cache"), &tkeys, true, false);
        sweep(&format!("{up}/_hls_cache"), &tkeys, true, true);
        if let Ok(rd) = std::fs::read_dir(format!("{up}/_original_cache")) {
            for e in rd.flatten().filter(|e| e.path().is_dir()) {
                sweep(&e.path().to_string_lossy(), &okeys, false, false);
            }
        }
        (removed, freed)
    })
    .await
    .unwrap_or((0, 0));
    if removed == 0 {
        return None;
    }
    println!("[nyxframe] cache orphan sweep: removed {removed} item(s), freed {freed} bytes");
    crate::routes::admin::audit(&app, None, "cache_orphan_sweep", "storage", None, Some(format!("removed={removed} bytes={freed}"))).await;
    Some(json!({ "removed": removed, "freed_bytes": freed }))
}

async fn expiry_sweep(app: AppRef) -> Option<Value> {
    let rows = app.db.all("UPDATE media_items SET deleted_at=now(), visibility='private' WHERE expires_at IS NOT NULL AND expires_at <= now() AND deleted_at IS NULL RETURNING id", &[]).await;
    (!rows.is_empty()).then(|| {
        println!("[nyxframe] media expiry sweep: expired {} post(s)", rows.len());
        json!({ "expired": rows.len() })
    })
}

// ---- one-shot backfills ----------------------------------------------------------------------------
fn start_thumb_backfill(app: &AppRef) {
    let app = app.clone();
    tokio::spawn(async move {
        let rows = app.db.all("SELECT id, updated_at, created_at, mime_type, original_filename, storage_path, youtube_video_id FROM media_items WHERE media_kind = 'video' AND deleted_at IS NULL ORDER BY id", &[]).await;
        let (mut queued, mut skipped) = (0, 0);
        for r in &rows {
            let id = r.i("id").unwrap_or(0);
            let cached = mf::exists(&format!("{}/_thumb_cache/{}/{id}_520.webp", app.settings.uploads_dir, video::shard(id)));
            if cached || serve::video_master(&app, id).is_some() {
                skipped += 1;
                continue;
            }
            serve::prewarm_video_thumb(&app, id, r).await;
            queued += 1;
            tokio::time::sleep(secs(4)).await;
        }
        println!("[nyxframe] thumb_backfill_sweep: done -- queued {queued}, already cached {skipped}, total {}", rows.len());
    });
}

fn start_codec_backfill(app: &AppRef) {
    let app = app.clone();
    tokio::spawn(async move {
        tokio::time::sleep(secs(60)).await;
        let rows = app.db.all("SELECT id, storage_path FROM media_items WHERE media_kind='video' AND video_codecs IS NULL AND deleted_at IS NULL ORDER BY id DESC LIMIT 500", &[]).await;
        let n = rows.len();
        for r in rows {
            let path = r.s("storage_path").and_then(|sp| mf::legacy_upload_path(&app.settings.uploads_dir, &sp));
            let codecs = match path {
                Some(p) => video::probe_codecs(&p).await,
                None => None,
            };
            let _ = app.db.exec("UPDATE media_items SET video_codecs=$1 WHERE id=$2", &[codecs.unwrap_or_else(|| "unknown".into()).into(), r.i("id").unwrap_or(0).into()]).await;
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
        if n > 0 {
            println!("[nyxframe] video codec backfill: probed {n} videos");
        }
    });
}

// ---- weekly digest ----------------------------------------------------------------------------------
async fn digest(app: AppRef) -> Option<Value> {
    use chrono::Datelike;
    let now = chrono::Utc::now();
    let wday = now.weekday().number_from_sunday() as i64;
    if wday != app.settings.digest_send_weekday || (now.format("%H").to_string().parse::<i64>().unwrap_or(0)) < app.settings.digest_send_hour {
        return None;
    }
    let monday = now.date_naive() - chrono::Duration::days(now.weekday().num_days_from_monday() as i64);
    let week = monday.format("%Y-%m-%d").to_string();
    let rows = app.db.all("SELECT id, user_settings FROM users WHERE user_settings::jsonb->>'discord_webhook_url' IS NOT NULL AND user_settings::jsonb->>'discord_webhook_url' != ''", &[]).await;
    let mut sent = 0;
    for r in rows {
        let settings = crate::util::json_obj(r.get("user_settings"));
        let Some(url) = settings["discord_webhook_url"].as_str().filter(|u| crate::discord::webhook_valid(u)).map(str::to_string) else { continue };
        let uid = r.i("id").unwrap_or(0);
        if app.db.opt("INSERT INTO digest_sends (user_id, week_start) VALUES ($1, $2::date) ON CONFLICT DO NOTHING RETURNING user_id", &[uid.into(), week.as_str().into()]).await.is_none() {
            continue;
        }
        let Ok(stats) = crate::routes::browse::creator_stats_for(&app, uid, &app.settings.public_origin).await else { continue };
        let tv = stats["totals"]["total_views"].as_i64().unwrap_or(0);
        let top = stats["top_posts"].as_array().cloned().unwrap_or_default();
        if tv == 0 && top.is_empty() {
            continue;
        }
        let fields: Vec<Value> = top
            .iter()
            .take(3)
            .map(|p| json!({ "name": p.s("title").filter(|t| !t.is_empty()).unwrap_or_else(|| "Untitled".into()), "value": format!("{} views · {} likes", p.i("views").unwrap_or(0), p.i("like_count").unwrap_or(0)) }))
            .collect();
        let t = &stats["totals"];
        crate::discord::webhook_send(
            &app,
            &url,
            json!([{ "title": "Your weekly gallery stats", "description": format!("Total views: {}\nTotal likes: {}\nTotal saves: {}", tv, t["total_likes"], t["total_saves"]), "fields": fields, "color": 0x37c9a7 }]),
        );
        sent += 1;
    }
    (sent > 0).then(|| json!({ "sent": sent }))
}

pub fn start(app: &AppRef) {
    let s = app.settings.clone();
    app.telemetry.start_pruner(s.telemetry_retention_days);
    spawn_loop(app, "weekly_digest", 30, 21600, digest);
    if s.media_warmer_enabled {
        start_media_warmer(app);
    }
    if s.transcode_cleanup_enabled {
        spawn_loop(app, "stale_transcode_cleanup", 60, 1800, stale_cleanup);
    }
    if std::env::var("GALLERY_ENABLE_HLS_IDLE_REAPER").map(|v| matches!(v.to_lowercase().as_str(), "true" | "1" | "yes")).unwrap_or(true) {
        spawn_loop(app, "hls_idle_reaper", 10, 10, reap_idle);
    }
    if s.deleted_media_purge_enabled {
        spawn_loop(app, "deleted_media_purge", 300, 21600, deleted_purge);
    }
    if s.cache_orphan_sweep_enabled {
        spawn_loop(app, "cache_orphan_sweep", 600, 21600, orphan_sweep);
    }
    if s.media_expiry_sweep_enabled {
        spawn_loop(app, "media_expiry_sweep", 20, 300, expiry_sweep);
    }
    if s.thumb_backfill_sweep_enabled {
        start_thumb_backfill(app);
    }
    if std::env::var("GALLERY_ENABLE_IMAGE_WARMER").map(|v| matches!(v.to_lowercase().as_str(), "true" | "1" | "yes")).unwrap_or(true) {
        start_image_warmer(app);
    }
    start_codec_backfill(app);
    // Upload job recovery, staging prune and the hot-tier mover.
    let a = app.clone();
    tokio::spawn(async move {
        tokio::time::sleep(secs(5)).await;
        loop {
            crate::upload::recover_jobs(&a).await;
            crate::upload::prune(&a).await;
            tokio::time::sleep(secs(60)).await;
        }
    });
    if !s.hot_dir.is_empty() {
        let a = app.clone();
        tokio::spawn(async move {
            tokio::time::sleep(secs(120)).await;
            loop {
                let n = crate::upload::hot_tier_pass(&a).await;
                if n > 0 {
                    println!("[nyxframe] hot tier: moved {n} originals to the uploads drive");
                }
                tokio::time::sleep(secs(600)).await;
            }
        });
    }
}
