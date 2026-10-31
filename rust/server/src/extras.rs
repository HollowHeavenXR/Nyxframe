//! Per-video extras (port of video_extras.lua): seek-preview sprite sheets
//! + WebVTT, auto captions (whisper.cpp), and the caption-aware playlists
//! AVPlayer needs. Jobs run in the background off a finished HLS rendition.

use crate::app::App;
use crate::http::{R, Reply, Req};
use crate::media_files::{exists, ffmpeg_bin, ffprobe_bin, run_out};
use crate::serve::{file_reply, hls_access};
use crate::video;
use serde_json::{Value, json};
use std::process::Stdio;
use tokio::process::Command;

const COLS: i64 = 10;
const ROWS: i64 = 10;
const TILE_W: i64 = 160;
const MAX_TILES: i64 = COLS * ROWS;
const JOB_STALE: i64 = 30 * 60;
const CAPTION_MAX_SECS: f64 = 45.0 * 60.0;

fn whisper_bin() -> String {
    std::env::var("GALLERY_WHISPER_BIN").unwrap_or_else(|_| "whisper-cli".into())
}
fn whisper_model() -> String {
    std::env::var("GALLERY_WHISPER_MODEL").unwrap_or_else(|_| format!("{}/.cache/llm-eval/ggml-base.en.bin", std::env::var("HOME").unwrap_or_else(|_| "/root".into())))
}

fn source_playlist(app: &App, id: i64, item: &Value) -> Option<String> {
    let seed = video::digest_seed(id, item);
    ["480p", "720p", "144p", "1080p", "original"].iter().map(|q| video::variant_dir(app, id, q, &seed)).find(|d| video::variant_ready(d)).map(|d| format!("{d}/playlist.m3u8"))
}

async fn probe_duration(path: &str) -> Option<f64> {
    let mut c = Command::new(ffprobe_bin());
    c.args(["-v", "error", "-allowed_extensions", "ALL", "-show_entries", "format=duration", "-of", "csv=p=0"]).arg(path);
    run_out(c).await?.lines().next()?.trim().parse::<f64>().ok().filter(|d| *d > 0.0)
}

fn mtime(path: &str) -> Option<i64> {
    std::fs::metadata(path).ok()?.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok().map(|d| d.as_secs() as i64)
}

fn claim(marker: &str) -> bool {
    if mtime(marker).is_some_and(|t| crate::util::now() - t < JOB_STALE) {
        return false;
    }
    if let Some(d) = std::path::Path::new(marker).parent() {
        let _ = std::fs::create_dir_all(d);
    }
    let _ = std::fs::remove_file(marker);
    std::fs::OpenOptions::new().write(true).create_new(true).open(marker).map(|mut f| {
        use std::io::Write;
        let _ = f.write_all(crate::util::now().to_string().as_bytes());
    }).is_ok()
}

struct Paths {
    dir: String,
}
impl Paths {
    fn new(app: &App, id: i64, item: &Value) -> Self {
        Paths { dir: video::extras_dir(app, id, &video::digest_seed(id, item)) }
    }
    fn f(&self, name: &str) -> String {
        format!("{}/{name}", self.dir)
    }
}

fn vtt_time(s: f64) -> String {
    let h = (s / 3600.0).floor();
    let m = ((s % 3600.0) / 60.0).floor();
    format!("{:02}:{:02}:{:06.3}", h as i64, m as i64, s % 60.0)
}

fn write_sprite_vtt(path: &str, duration: f64, interval: i64, tile_h: i64) {
    let mut lines = vec!["WEBVTT".to_string(), String::new()];
    let tiles = MAX_TILES.min(((duration / interval as f64).ceil() as i64).max(1));
    for i in 0..tiles {
        let start = (i * interval) as f64;
        let end = duration.min(start + interval as f64);
        if end <= start {
            break;
        }
        lines.push(format!("{} --> {}", vtt_time(start), vtt_time(end)));
        lines.push(format!("sprite.jpg#xywh={},{},{TILE_W},{tile_h}", (i % COLS) * TILE_W, (i / COLS) * tile_h));
        lines.push(String::new());
    }
    let _ = std::fs::write(path, lines.join("\n"));
}

async fn ensure_sprite(app: &App, id: i64, item: &Value) -> &'static str {
    let p = Paths::new(app, id, item);
    if exists(&p.f("sprite.jpg")) && exists(&p.f("sprite.vtt")) {
        return "ready";
    }
    let Some(src) = source_playlist(app, id, item) else { return "pending" };
    let Some(duration) = probe_duration(&src).await else { return "pending" };
    if !claim(&p.f("sprite.pending")) {
        return "pending";
    }
    let interval = 1.max((duration / MAX_TILES as f64).ceil() as i64);
    let _ = std::fs::write(p.f("sprite.meta"), format!("{interval}\n{duration:.3}\n"));
    let mut c = Command::new("nice");
    c.args(["-n", "15", "ionice", "-c2", "-n6"]).arg(ffmpeg_bin()).args(["-nostdin", "-v", "error", "-allowed_extensions", "ALL", "-skip_frame", "nokey", "-i"]).arg(&src);
    c.arg("-vf").arg(format!("fps=1/{interval},scale={TILE_W}:-2,tile={COLS}x{ROWS}")).args(["-frames:v", "1", "-q:v", "6"]).arg(p.f("sprite.jpg")).arg("-y");
    c.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    let marker = p.f("sprite.pending");
    if let Ok(mut child) = c.spawn() {
        tokio::spawn(async move {
            let _ = child.wait().await;
            let _ = tokio::fs::remove_file(marker).await;
        });
    }
    "pending"
}

async fn finalize_sprite_vtt(app: &App, id: i64, item: &Value) {
    let p = Paths::new(app, id, item);
    let (sheet, vtt) = (p.f("sprite.jpg"), p.f("sprite.vtt"));
    if exists(&vtt) || !exists(&sheet) {
        return;
    }
    let Ok(meta) = std::fs::read_to_string(p.f("sprite.meta")) else { return };
    let mut it = meta.split_whitespace();
    let (Some(interval), Some(duration)) = (it.next().and_then(|v| v.parse::<i64>().ok()), it.next().and_then(|v| v.parse::<f64>().ok())) else { return };
    if let Some((_, h)) = video::probe_dims(&sheet).await.filter(|d| d.1 > 0) {
        write_sprite_vtt(&vtt, duration, interval, h / ROWS);
    }
}

fn captions_ready(app: &App, id: i64, item: &Value) -> bool {
    exists(&Paths::new(app, id, item).f("captions.vtt"))
}

async fn ensure_captions(app: &App, id: i64, item: &Value) -> &'static str {
    let p = Paths::new(app, id, item);
    let (vtt, none) = (p.f("captions.vtt"), p.f("captions.none"));
    if exists(&vtt) {
        return "ready";
    }
    if exists(&none) {
        return "unavailable";
    }
    let Some(src) = source_playlist(app, id, item) else { return "pending" };
    if probe_duration(&src).await.is_some_and(|d| d > CAPTION_MAX_SECS) {
        let _ = std::fs::create_dir_all(&p.dir);
        let _ = std::fs::write(&none, "too_long");
        return "unavailable";
    }
    if !claim(&p.f("captions.pending")) {
        return "pending";
    }
    let (wav, stem, marker) = (p.f("audio.wav"), p.f("captions"), p.f("captions.pending"));
    tokio::spawn(async move {
        let mut a = Command::new("nice");
        a.args(["-n", "15", "ionice", "-c2", "-n6"]).arg(ffmpeg_bin()).args(["-nostdin", "-v", "error", "-allowed_extensions", "ALL", "-i"]).arg(&src);
        a.args(["-vn", "-ac", "1", "-ar", "16000", "-f", "wav"]).arg(&wav).arg("-y").stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        if crate::media_files::run_ok(a).await {
            let mut w = Command::new("nice");
            w.args(["-n", "15"]).arg(whisper_bin()).arg("-m").arg(whisper_model()).arg("-f").arg(&wav).args(["-ovtt", "-of"]).arg(&stem).args(["-np", "-t", "2"]);
            w.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
            crate::media_files::run_ok(w).await;
        }
        if crate::media_files::file_size(&vtt) == 0 {
            let _ = tokio::fs::write(&none, "").await;
        }
        let _ = tokio::fs::remove_file(&wav).await;
        let _ = tokio::fs::remove_file(&marker).await;
    });
    "pending"
}

fn qs(req: &Req) -> String {
    req.q("access").map(|a| format!("?access={a}")).unwrap_or_default()
}

fn cc(public: bool) -> String {
    if public { "public, max-age=604800, immutable".into() } else { "private, max-age=604800".into() }
}

fn mid(req: &Req) -> R<i64> {
    req.pi("media_id").ok_or_else(|| Reply::err(404, "Media not found."))
}

pub async fn playback_extras(req: Req) -> R<Reply> {
    let id = mid(&req)?;
    let (item, _) = hls_access(&req, id).await?;
    let app = req.app.clone();
    finalize_sprite_vtt(&app, id, &item).await;
    let mut sprite = ensure_sprite(&app, id, &item).await;
    let captions = ensure_captions(&app, id, &item).await;
    let p = Paths::new(&app, id, &item);
    if !(exists(&p.f("sprite.jpg")) && exists(&p.f("sprite.vtt"))) {
        sprite = "pending";
    }
    let q = qs(&req);
    let mut s = json!({ "status": sprite });
    if sprite == "ready" {
        s["sheet_url"] = json!(format!("/api/media/{id}/sprite.jpg{q}"));
        s["vtt_url"] = json!(format!("/api/media/{id}/sprite.vtt{q}"));
    }
    let mut c = json!({ "status": captions, "language": "en", "auto_generated": true });
    if captions == "ready" {
        c["vtt_url"] = json!(format!("/api/media/{id}/captions/en.vtt{q}"));
    }
    Ok(Reply::ok(json!({ "sprite": s, "captions": c })))
}

pub async fn sprite_sheet(req: Req) -> R<Reply> {
    let id = mid(&req)?;
    let (item, public) = hls_access(&req, id).await?;
    let path = Paths::new(&req.app, id, &item).f("sprite.jpg");
    if !exists(&path) {
        return Err(Reply::err(404, "No preview sprite for this video yet."));
    }
    file_reply(&req, &path, "image/jpeg", &[("Cache-Control", cc(public))], false).await
}

pub async fn sprite_vtt(req: Req) -> R<Reply> {
    let id = mid(&req)?;
    let (item, public) = hls_access(&req, id).await?;
    finalize_sprite_vtt(&req.app, id, &item).await;
    let path = Paths::new(&req.app, id, &item).f("sprite.vtt");
    if !exists(&path) {
        return Err(Reply::err(404, "No preview sprite for this video yet."));
    }
    file_reply(&req, &path, "text/vtt; charset=utf-8", &[("Cache-Control", cc(public))], false).await
}

pub async fn captions(req: Req) -> R<Reply> {
    let id = mid(&req)?;
    let (item, public) = hls_access(&req, id).await?;
    let path = Paths::new(&req.app, id, &item).f("captions.vtt");
    if !exists(&path) {
        return Err(Reply::err(404, "No captions for this video."));
    }
    file_reply(&req, &path, "text/vtt; charset=utf-8", &[("Cache-Control", cc(public))], false).await
}

pub async fn captions_playlist(req: Req) -> R<Reply> {
    let id = mid(&req)?;
    let (item, public) = hls_access(&req, id).await?;
    let app = req.app.clone();
    if !captions_ready(&app, id, &item) {
        return Err(Reply::err(404, "No captions for this video."));
    }
    let duration = match source_playlist(&app, id, &item) {
        Some(s) => probe_duration(&s).await.unwrap_or(3600.0),
        None => 3600.0,
    };
    let q = qs(&req);
    let lines = [
        "#EXTM3U".to_string(),
        "#EXT-X-VERSION:3".into(),
        "#EXT-X-PLAYLIST-TYPE:VOD".into(),
        format!("#EXT-X-TARGETDURATION:{}", duration.ceil() as i64),
        "#EXT-X-MEDIA-SEQUENCE:0".into(),
        format!("#EXTINF:{duration:.3},"),
        format!("/api/media/{id}/captions/en.vtt{q}"),
        "#EXT-X-ENDLIST".into(),
    ];
    Ok(Reply::text(200, lines.join("\n") + "\n", "application/vnd.apple.mpegurl").header("Cache-Control", if public { "public, max-age=3600" } else { "no-cache" }))
}

pub async fn quality_master(req: Req) -> R<Reply> {
    let id = mid(&req)?;
    let (item, public) = hls_access(&req, id).await?;
    let quality = req.p("quality");
    let quality = if quality.is_empty() { "original".to_string() } else { quality };
    let q = qs(&req);
    let has = captions_ready(&req.app, id, &item);
    let mut lines = vec!["#EXTM3U".to_string(), "#EXT-X-VERSION:6".into()];
    if has {
        lines.push(format!(
            "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"English (auto)\",LANGUAGE=\"en\",DEFAULT=NO,AUTOSELECT=YES,FORCED=NO,URI=\"/api/media/{id}/captions/subs.m3u8{q}\""
        ));
    }
    lines.push(format!("#EXT-X-STREAM-INF:BANDWIDTH=8000000{}", if has { ",SUBTITLES=\"subs\"" } else { "" }));
    lines.push(format!("/api/media/{id}/hls/{quality}/playlist.m3u8{q}"));
    Ok(Reply::text(200, lines.join("\n") + "\n", "application/vnd.apple.mpegurl").header("Cache-Control", if public { "public, max-age=60" } else { "no-cache" }))
}
