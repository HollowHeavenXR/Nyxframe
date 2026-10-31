//! Video pipeline (port of routes.lua's transcode/HLS section): quality
//! profiles, GPU (VAAPI) HLS renditions, the legacy MP4 quality cache,
//! global transcode slots, and the cache-path formulas (byte-identical to
//! the Lua build so existing caches keep working).

use crate::app::App;
use crate::db::J;
use crate::media_files::{exists, ffmpeg_bin, ffprobe_bin, run_out};
use serde_json::Value;
use std::path::Path;
use std::process::Stdio;
use tokio::process::Command;

pub const HLS_SEGMENT_SECONDS: u32 = 6;
pub const PENDING_STALE_SECS: i64 = 30 * 60;
pub const TRANSCODE_SIZE_LIMIT: i64 = 4 * 1024 * 1024 * 1024;
pub const MAX_CONCURRENT: usize = 2;
pub const QUALITIES: [&str; 4] = ["1080p", "720p", "480p", "144p"];

pub struct Profile {
    pub max_width: i64,
    pub audio_bitrate: &'static str,
    pub profile: &'static str,
    pub ceiling_bps: i64,
}

pub fn profile(q: &str) -> Option<Profile> {
    Some(match q {
        "1080p" => Profile { max_width: 1920, audio_bitrate: "320k", profile: "high", ceiling_bps: 8_000_000 },
        "720p" => Profile { max_width: 1280, audio_bitrate: "256k", profile: "high", ceiling_bps: 5_000_000 },
        "480p" => Profile { max_width: 854, audio_bitrate: "192k", profile: "high", ceiling_bps: 2_500_000 },
        "144p" => Profile { max_width: 256, audio_bitrate: "64k", profile: "baseline", ceiling_bps: 400_000 },
        _ => return None,
    })
}

pub fn bandwidth(q: &str) -> i64 {
    match q {
        "1080p" => 5_000_000,
        "720p" => 2_800_000,
        "480p" => 1_400_000,
        "144p" => 300_000,
        _ => 8_000_000,
    }
}

/// "medium"/"low"/"high" legacy names; anything unknown is "original".
pub fn normalize_quality(v: Option<&str>) -> String {
    let q = v.unwrap_or("high").to_lowercase();
    let q = match q.as_str() {
        "medium" => "720p".to_string(),
        "low" => "480p".to_string(),
        "high" | "original" => "original".to_string(),
        _ => q,
    };
    if q == "original" || profile(&q).is_some() { q } else { "original".into() }
}

fn sha16(s: &str) -> String {
    crate::auth::sha256_hex(s)[..16].to_string()
}

pub fn shard(id: i64) -> String {
    format!("{:02x}", id.rem_euclid(256))
}

/// content_sha256 (else updated_at/created_at/id) + "|wm=" (watermarks are off).
pub fn digest_seed(id: i64, item: &Value) -> String {
    let base = item.s("content_sha256").map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).or(item.s("updated_at")).or(item.s("created_at")).unwrap_or_else(|| id.to_string());
    format!("{base}|wm=")
}

pub fn variant_dir(app: &App, id: i64, quality: &str, seed: &str) -> String {
    format!("{}/_hls_cache/{id}_{quality}_{}", app.settings.uploads_dir, sha16(seed))
}

pub fn quality_cache_path(app: &App, id: i64, quality: &str, seed: &str) -> String {
    format!("{}/_video_cache/{id}_{quality}_{}.mp4", app.settings.uploads_dir, sha16(seed))
}

pub fn extras_dir(app: &App, id: i64, seed: &str) -> String {
    format!("{}/_extras_cache/{id}_{}", app.settings.uploads_dir, sha16(seed))
}

/// Original-bytes cache for DB-stored originals.
pub fn original_cache_path(app: &App, id: i64, item: &Value) -> String {
    let seed = item.s("updated_at").or(item.s("created_at")).unwrap_or_else(|| id.to_string());
    format!("{}/_original_cache/{}/{id}_{}.bin", app.settings.uploads_dir, shard(id), sha16(&seed))
}

pub fn preview_cache_path(app: &App, id: i64, item: &Value, size: &str) -> String {
    let seed = item.s("updated_at").or(item.s("created_at")).unwrap_or_else(|| id.to_string());
    format!("{}/_preview_cache/{}/{id}_{size}_{}.webp", app.settings.uploads_dir, shard(id), &crate::auth::sha256_hex(&seed)[..12])
}

fn read_num(path: &str) -> Option<f64> {
    let s = std::fs::read_to_string(path).ok()?;
    let t: String = s.trim().chars().take_while(|c| c.is_ascii_digit() || *c == '.').collect();
    t.parse().ok()
}

/// Finished rendition: ENDLIST present and >=97% of the expected duration.
pub fn variant_ready(dir: &str) -> bool {
    if exists(&format!("{dir}/.verified")) {
        return true;
    }
    let Ok(text) = std::fs::read_to_string(format!("{dir}/playlist.m3u8")) else { return false };
    if !text.contains("#EXT-X-ENDLIST") {
        return false;
    }
    if let Some(expected) = read_num(&format!("{dir}/.expected_duration")).filter(|e| *e > 0.0) {
        if playlist_duration(&text) < expected * 0.97 {
            return false;
        }
    }
    let _ = std::fs::write(format!("{dir}/.verified"), "1");
    true
}

pub fn playlist_duration(text: &str) -> f64 {
    text.lines().filter_map(|l| l.strip_prefix("#EXTINF:")).filter_map(|r| r.split(',').next()?.trim().parse::<f64>().ok()).sum()
}

pub fn ffmpeg_running(pid: i64) -> bool {
    std::fs::read(format!("/proc/{pid}/cmdline")).map(|c| String::from_utf8_lossy(&c).contains("ffmpeg")).unwrap_or(false)
}

// ---- slots ------------------------------------------------------------------------------------------
fn slots_dir(app: &App) -> String {
    let d = format!("{}/_transcode_slots", app.settings.uploads_dir);
    let _ = std::fs::create_dir_all(&d);
    d
}

fn claimed_at(path: &str) -> Option<i64> {
    let s = std::fs::read_to_string(path).ok()?;
    Some(s.trim().split_whitespace().next().and_then(|t| t.parse().ok()).unwrap_or_else(crate::util::now))
}

pub fn active_slots(app: &App) -> usize {
    let dir = slots_dir(app);
    let now = crate::util::now();
    (1..=MAX_CONCURRENT).filter(|i| claimed_at(&format!("{dir}/slot_{i}")).is_some_and(|t| now - t < PENDING_STALE_SECS)).count()
}

pub fn slot_available(app: &App) -> bool {
    active_slots(app) < MAX_CONCURRENT
}

/// Claim one of `count` slot files (`prefix`N) atomically; stale ones are reclaimed.
pub fn acquire_slot(app: &App, prefix: &str, count: usize) -> Option<String> {
    let dir = slots_dir(app);
    let now = crate::util::now();
    for i in 1..=count {
        let p = format!("{dir}/{prefix}{i}");
        if claimed_at(&p).is_some_and(|t| now - t >= PENDING_STALE_SECS) {
            let _ = std::fs::remove_file(&p);
        }
        if let Ok(mut f) = std::fs::OpenOptions::new().write(true).create_new(true).open(&p) {
            use std::io::Write;
            let _ = f.write_all(now.to_string().as_bytes());
            return Some(p);
        }
    }
    None
}

pub fn acquire_transcode_slot(app: &App) -> Option<String> {
    acquire_slot(app, "slot_", MAX_CONCURRENT)
}

pub fn warmer_jobs_max() -> usize {
    std::env::var("GALLERY_WARMER_MAX_JOBS").ok().and_then(|v| v.parse().ok()).unwrap_or(1)
}

pub fn vaapi_available(app: &App) -> bool {
    Path::new(&app.settings.vaapi_device).exists()
}

// ---- probes ---------------------------------------------------------------------------------------
pub async fn probe_dims(path: &str) -> Option<(i64, i64)> {
    let mut c = Command::new(ffprobe_bin());
    c.args(["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0"]).arg(path);
    let out = run_out(c).await?;
    let mut it = out.lines().next()?.split(',');
    Some((it.next()?.trim().parse().ok()?, it.next()?.trim().parse().ok()?))
}

pub async fn probe_duration_bitrate(path: &str) -> (Option<f64>, Option<i64>) {
    let mut c = Command::new(ffprobe_bin());
    c.args(["-v", "error", "-show_entries", "format=duration,bit_rate", "-of", "csv=p=0"]).arg(path);
    let out = run_out(c).await.unwrap_or_default();
    let line = out.lines().next().unwrap_or("");
    let mut it = line.split(',');
    let d = it.next().and_then(|s| s.trim().parse::<f64>().ok());
    let b = it.next().and_then(|s| s.trim().parse::<i64>().ok());
    (d, b)
}

/// "h264/yuv420p+aac"-style codec summary.
pub async fn probe_codecs(path: &str) -> Option<String> {
    let mut c = Command::new(ffprobe_bin());
    c.args(["-v", "error", "-show_entries", "stream=codec_type,codec_name,pix_fmt", "-of", "compact=p=0"]).arg(path);
    let out = run_out(c).await?;
    let (mut video, mut audio) = (None, None);
    for line in out.lines() {
        let field = |k: &str| line.split('|').find_map(|p| p.strip_prefix(&format!("{k}="))).map(str::to_string);
        match field("codec_type").as_deref() {
            Some("video") if video.is_none() => {
                if let Some(n) = field("codec_name") {
                    video = Some(format!("{n}/{}", field("pix_fmt").unwrap_or_else(|| "?".into())));
                }
            }
            Some("audio") if audio.is_none() => audio = field("codec_name"),
            _ => {}
        }
    }
    let v = video?;
    Some(match audio {
        Some(a) => format!("{v}+{a}"),
        None => v,
    })
}

fn scale_filter(src_w: Option<i64>, max_w: i64) -> String {
    match src_w {
        Some(w) if w > 0 && w < max_w => format!("scale={max_w}:-2:flags=lanczos,unsharp=5:5:0.8:5:5:0.0"),
        _ => format!("scale='min({max_w},iw)':-2:flags=lanczos"),
    }
}

fn nice_ffmpeg() -> Command {
    let mut c = Command::new("nice");
    c.args(["-n", "19", "ionice", "-c2", "-n7"]).arg(ffmpeg_bin());
    c.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    c
}

// ---- HLS -----------------------------------------------------------------------------------------
pub enum HlsErr {
    Busy,
    Gpu,
    Missing,
    Unavailable,
}

pub struct HlsOpts {
    pub warmer: bool,
    pub source_path: Option<String>,
}

/// Start (or find) the HLS rendition; Ok(dir) while encoding or when done.
pub async fn ensure_hls_variant(app: &App, id: i64, item: &Value, quality: &str, opts: HlsOpts) -> Result<String, HlsErr> {
    if quality != "original" && profile(quality).is_none() {
        return Err(HlsErr::Unavailable);
    }
    if quality != "original" && item.i("file_size").unwrap_or(0) > TRANSCODE_SIZE_LIMIT {
        return Err(HlsErr::Unavailable);
    }
    let seed = digest_seed(id, item);
    let dir = variant_dir(app, id, quality, &seed);
    // A finished rendition plays even while the GPU is unavailable.
    if variant_ready(&dir) {
        return Ok(dir);
    }
    if quality != "original" && !vaapi_available(app) {
        return Err(HlsErr::Gpu);
    }
    let pending = format!("{dir}.pending");
    let mut still = read_num(&pending).is_some_and(|t| crate::util::now() - (t as i64) < PENDING_STALE_SECS);
    if still {
        if let Some(pid) = read_num(&format!("{dir}/.pid")) {
            still = ffmpeg_running(pid as i64);
        }
    }
    if variant_ready(&dir) || still {
        return Ok(dir);
    }
    let _ = tokio::fs::remove_dir_all(&dir).await;
    let _ = tokio::fs::remove_file(&pending).await;
    let Some(cap_slot) = acquire_transcode_slot(app) else { return Err(HlsErr::Busy) };
    let warm_slot = if opts.warmer {
        match acquire_slot(app, "warm_", warmer_jobs_max()) {
            Some(s) => Some(s),
            None => {
                let _ = std::fs::remove_file(&cap_slot);
                return Err(HlsErr::Busy);
            }
        }
    } else {
        None
    };
    let release = |extra: &[&str]| {
        for p in [cap_slot.as_str()].iter().chain(extra.iter()).chain(warm_slot.as_deref().iter()) {
            let _ = std::fs::remove_file(p);
        }
    };
    let _ = tokio::fs::create_dir_all(&dir).await;
    let _ = tokio::fs::write(&pending, crate::util::now().to_string()).await;
    if opts.warmer {
        let _ = tokio::fs::write(format!("{dir}/.warm"), "1").await;
    }
    let src = format!("{dir}/source.bin");
    let mut linked = false;
    if let Some(sp) = opts.source_path.as_deref().filter(|p| exists(p)) {
        linked = std::fs::hard_link(sp, &src).is_ok() || std::os::unix::fs::symlink(sp, &src).is_ok() || tokio::fs::copy(sp, &src).await.is_ok();
    }
    if !linked {
        let ok = match crate::serve::db_blob_to_cache(app, id, item).await {
            Some(p) => std::fs::hard_link(&p, &src).is_ok() || tokio::fs::copy(&p, &src).await.is_ok(),
            None => false,
        };
        if !ok {
            release(&[pending.as_str()]);
            let _ = tokio::fs::remove_dir_all(&dir).await;
            return Err(HlsErr::Missing);
        }
    }
    let (duration, src_bitrate) = probe_duration_bitrate(&src).await;
    if let Some(d) = duration.filter(|d| *d > 0.0) {
        let _ = tokio::fs::write(format!("{dir}/.expected_duration"), format!("{d:.3}")).await;
    }
    let mut c = nice_ffmpeg();
    c.args(["-y", "-hide_banner", "-loglevel", "error"]);
    let keyframes = format!("expr:gte(t,n_forced*{HLS_SEGMENT_SECONDS})");
    if quality == "original" {
        c.arg("-i").arg(&src).args(["-map", "0:v:0", "-map", "0:a:0?", "-c", "copy"]);
    } else {
        let p = profile(quality).unwrap();
        c.args(["-hwaccel", "vaapi", "-hwaccel_output_format", "vaapi", "-vaapi_device"]).arg(&app.settings.vaapi_device);
        c.arg("-i").arg(&src);
        let dims = probe_dims(&src).await;
        match dims {
            Some((w, h)) if w >= p.max_width => {
                let out_w = p.max_width;
                let out_h = ((h as f64 * out_w as f64 / w as f64 / 2.0) + 0.5).floor() as i64 * 2;
                c.arg("-filter_complex").arg(format!("[0:v]scale_vaapi=w={out_w}:h={out_h}[v]")).args(["-map", "[v]", "-map", "0:a:0?"]);
            }
            _ => {
                let vf = format!("hwdownload,format=nv12,{},format=nv12,hwupload", scale_filter(dims.map(|d| d.0), p.max_width));
                c.args(["-map", "0:v:0", "-map", "0:a:0?", "-vf"]).arg(vf);
            }
        }
        let ceiling = src_bitrate.filter(|b| *b > 0).map(|b| b.min(p.ceiling_bps)).unwrap_or(p.ceiling_bps);
        let vprof = if p.profile == "baseline" { "constrained_baseline" } else { p.profile };
        c.arg("-force_key_frames").arg(&keyframes).args(["-c:v", "h264_vaapi", "-rc_mode", "VBR"]);
        c.arg("-b:v").arg(((ceiling as f64) * 0.7).floor().to_string()).arg("-maxrate").arg(ceiling.to_string()).arg("-bufsize").arg((ceiling * 2).to_string());
        c.args(["-profile:v", vprof, "-level", "4.1", "-c:a", "aac", "-b:a", p.audio_bitrate]);
    }
    c.args(["-f", "hls", "-hls_time", &HLS_SEGMENT_SECONDS.to_string(), "-hls_list_size", "0", "-hls_playlist_type", "event", "-hls_flags", "independent_segments+temp_file"]);
    c.arg("-hls_segment_filename").arg(format!("{dir}/seg_%05d.ts")).arg(format!("{dir}/playlist.m3u8"));
    let pid_file = format!("{dir}/.pid");
    match c.spawn() {
        Ok(mut child) => {
            if let Some(pid) = child.id() {
                let _ = tokio::fs::write(&pid_file, pid.to_string()).await;
            }
            let (src, pending, pid_file, cap, warm) = (src.clone(), pending.clone(), pid_file.clone(), cap_slot.clone(), warm_slot.clone());
            tokio::spawn(async move {
                let _ = child.wait().await;
                for p in [Some(src), Some(pending), Some(cap), Some(pid_file), warm].into_iter().flatten() {
                    let _ = tokio::fs::remove_file(p).await;
                }
            });
            Ok(dir)
        }
        Err(e) => {
            println!("[nyxframe] hls ffmpeg spawn failed: {e}");
            release(&[pending.as_str(), src.as_str()]);
            Err(HlsErr::Busy)
        }
    }
}

/// /file?quality=720p: the cached MP4 if present, else start a background encode.
pub async fn ensure_quality_cache(app: &App, id: i64, item: &Value, quality: &str, source: &str) -> Option<String> {
    let p = profile(quality)?;
    if !vaapi_available(app) {
        return None;
    }
    let sha = app.db.opt("SELECT content_sha256 FROM media_items WHERE id=$1", &[id.into()]).await;
    let mut seed_item = item.clone();
    if let Some(s) = sha.and_then(|r| r.s("content_sha256")) {
        seed_item["content_sha256"] = serde_json::json!(s);
    }
    let cache = quality_cache_path(app, id, quality, &digest_seed(id, &seed_item));
    if crate::media_files::file_size(&cache) > 0 {
        return Some(cache);
    }
    let pending = format!("{cache}.pending");
    if read_num(&pending).is_some_and(|t| crate::util::now() - (t as i64) < PENDING_STALE_SECS) {
        return None;
    }
    let slot = acquire_transcode_slot(app)?;
    let _ = tokio::fs::create_dir_all(format!("{}/_video_cache", app.settings.uploads_dir)).await;
    let _ = tokio::fs::write(&pending, crate::util::now().to_string()).await;
    let tmp = format!("{cache}.tmp.{}.mp4", rand::random_range(100000..999999));
    let dims = probe_dims(source).await;
    let mut c = nice_ffmpeg();
    c.args(["-y", "-hide_banner", "-loglevel", "error", "-vaapi_device"]).arg(&app.settings.vaapi_device).arg("-i").arg(source);
    c.args(["-map", "0:v:0", "-map", "0:a:0?", "-vf"]).arg(format!("{},format=nv12,hwupload", scale_filter(dims.map(|d| d.0), p.max_width)));
    let vprof = if p.profile == "baseline" { "constrained_baseline" } else { p.profile };
    c.args(["-c:v", "h264_vaapi", "-rc_mode", "VBR"]).arg("-b:v").arg(((p.ceiling_bps as f64) * 0.7).floor().to_string());
    c.arg("-maxrate").arg(p.ceiling_bps.to_string()).arg("-bufsize").arg((p.ceiling_bps * 2).to_string());
    c.args(["-profile:v", vprof, "-level", "4.1", "-c:a", "aac", "-b:a", p.audio_bitrate, "-movflags", "+faststart", "-f", "mp4"]).arg(&tmp);
    match c.spawn() {
        Ok(mut child) => {
            tokio::spawn(async move {
                let ok = child.wait().await.map(|s| s.success()).unwrap_or(false);
                if ok {
                    let _ = tokio::fs::rename(&tmp, &cache).await;
                }
                for f in [tmp, pending, slot] {
                    let _ = tokio::fs::remove_file(f).await;
                }
            });
        }
        Err(_) => {
            let _ = std::fs::remove_file(&pending);
            let _ = std::fs::remove_file(&slot);
        }
    }
    None
}

/// Any HLS rendition watched within `secs`? (warmers back off while someone watches)
pub fn someone_is_watching(app: &App, secs: i64) -> bool {
    let root = format!("{}/_hls_cache", app.settings.uploads_dir);
    let Ok(rd) = std::fs::read_dir(&root) else { return false };
    let now = std::time::SystemTime::now();
    for e in rd.flatten() {
        let p = e.path().join(".last_watched");
        if let Ok(m) = std::fs::metadata(&p).and_then(|m| m.modified()) {
            if now.duration_since(m).map(|d| d.as_secs() as i64 <= secs).unwrap_or(true) {
                return true;
            }
        }
    }
    false
}

pub fn touch_heartbeat(dir: &str) {
    let _ = std::fs::write(format!("{dir}/.last_watched"), crate::util::now().to_string());
}
