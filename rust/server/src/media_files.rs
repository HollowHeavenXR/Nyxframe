//! Media storage + ffmpeg rendering (port of media_files.lua).
//!
//! Bytes live on disk (`media/<hh>/<sha256><ext>` under the uploads dir,
//! or the fast "hot" tier when configured) or, for a few legacy rows, in
//! Postgres (`media_files` + `media_file_chunks`). ffmpeg/ffprobe run as
//! async child processes at low CPU/IO priority, so a render never blocks
//! request handling.

use crate::db::{Db, J, P};
use serde_json::Value;
use std::path::Path;
use std::process::Stdio;
use std::sync::RwLock;
use tokio::process::Command;

static HOT_ROOT: RwLock<Option<String>> = RwLock::new(None);

pub fn set_hot_root(root: Option<String>) {
    *HOT_ROOT.write().unwrap() = root;
}
pub fn hot_root() -> Option<String> {
    HOT_ROOT.read().unwrap().clone()
}

pub fn ffmpeg_bin() -> String {
    std::env::var("GALLERY_FFMPEG_BIN").unwrap_or_else(|_| "ffmpeg".into())
}
pub fn ffprobe_bin() -> String {
    std::env::var("GALLERY_FFPROBE_BIN").unwrap_or_else(|_| "ffprobe".into())
}

/// `nice -n 15 ionice -c2 -n6 ffmpeg ...` with stdio closed.
pub fn ffmpeg_cmd(nice: i32) -> Command {
    let mut c = Command::new("nice");
    c.args(["-n", &nice.to_string(), "ionice", "-c2", "-n6"]).arg(ffmpeg_bin());
    c.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).kill_on_drop(true);
    c
}

pub async fn run_ok(mut c: Command) -> bool {
    c.status().await.map(|s| s.success()).unwrap_or(false)
}

/// Run and capture stdout (stderr discarded).
pub async fn run_out(mut c: Command) -> Option<String> {
    c.stdin(Stdio::null()).stderr(Stdio::null()).kill_on_drop(true);
    let out = c.output().await.ok()?;
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}

pub fn exists(p: &str) -> bool {
    Path::new(p).is_file()
}

pub fn file_size(p: &str) -> u64 {
    std::fs::metadata(p).map(|m| m.len()).unwrap_or(0)
}

/// SHA-256 of a file, streamed (SHA-NI accelerated), off the async threads.
pub async fn sha256_file(path: &str) -> Option<String> {
    let path = path.to_string();
    tokio::task::spawn_blocking(move || {
        use sha2::{Digest, Sha256};
        use std::io::Read;
        let mut f = std::fs::File::open(&path).ok()?;
        let mut h = Sha256::new();
        let mut buf = vec![0u8; 4 * 1024 * 1024];
        loop {
            let n = f.read(&mut buf).ok()?;
            if n == 0 {
                break;
            }
            h.update(&buf[..n]);
        }
        Some(hex::encode(h.finalize()))
    })
    .await
    .ok()
    .flatten()
}

pub fn sha256_bytes(b: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    hex::encode(Sha256::digest(b))
}

// ---- database blobs ------------------------------------------------------------------------------
pub async fn get_media_file_info(db: &Db, media_id: i64) -> Option<Value> {
    db.opt(
        "SELECT f.id, f.sha256, f.mime_type, f.original_filename, f.media_kind, f.file_size, octet_length(f.content) AS inline_size \
         FROM media_files f JOIN media_items m ON m.media_file_id = f.id WHERE m.id = $1",
        &[media_id.into()],
    )
    .await
}

/// (info row, full content) for a database-stored media file.
pub async fn get_media_file(db: &Db, media_id: i64) -> Option<(Value, Vec<u8>)> {
    let info = db
        .opt("SELECT f.id, f.sha256, f.mime_type, f.original_filename, f.media_kind, f.file_size FROM media_files f JOIN media_items m ON m.media_file_id = f.id WHERE m.id = $1", &[media_id.into()])
        .await?;
    let fid = info.i("id")?;
    let size = info.i("file_size").unwrap_or(0);
    let mut content = db.bytes("SELECT content FROM media_files WHERE id=$1", &[fid.into()]).await.ok().flatten().unwrap_or_default();
    if content.len() as i64 != size {
        let chunks = db.bytes_all("SELECT content FROM media_file_chunks WHERE file_id=$1 ORDER BY chunk_index ASC", &[fid.into()]).await.unwrap_or_default();
        if !chunks.is_empty() {
            content = chunks.concat();
        }
    }
    Some((info, content))
}

pub async fn get_avatar_file(db: &Db, user_id: i64) -> Option<(Value, Vec<u8>)> {
    let info = db
        .opt("SELECT f.id, f.sha256, f.mime_type, f.original_filename, f.file_size FROM user_avatar_files f JOIN users u ON u.avatar_file_id = f.id WHERE u.id = $1", &[user_id.into()])
        .await?;
    let content = db.bytes("SELECT content FROM user_avatar_files WHERE id=$1", &[info.i("id")?.into()]).await.ok().flatten()?;
    Some((info, content))
}

pub async fn save_avatar_file(db: &Db, user_id: i64, content: &[u8], sha256: &str, mime: &str, filename: &str) -> Result<i64, String> {
    let row = db
        .one(
            "INSERT INTO user_avatar_files (user_id, sha256, mime_type, original_filename, file_size, content) VALUES ($1, $2, $3, $4, $5, $6) \
             ON CONFLICT (user_id, sha256) DO UPDATE SET created_at = now() RETURNING id",
            &[user_id.into(), sha256.into(), crate::util::cut(mime, 120).into(), crate::util::cut(filename, 255).into(), (content.len() as i64).into(), P::Bytes(content.to_vec())],
        )
        .await?
        .ok_or("avatar insert returned nothing")?;
    let fid = row.i("id").ok_or("avatar insert returned no id")?;
    db.exec(
        "UPDATE users SET avatar_file_id=$1, avatar_path=$2, avatar_mime_type=$3, avatar_original_filename=$4 WHERE id=$5",
        &[fid.into(), format!("avatar-db://{fid}").into(), crate::util::cut(mime, 120).into(), crate::util::cut(filename, 255).into(), user_id.into()],
    )
    .await?;
    Ok(fid)
}

// ---- disk files ------------------------------------------------------------------------------------
/// Absolute path of an on-disk upload (hot tier first), or None.
pub fn legacy_upload_path(uploads_dir: &str, storage_path: &str) -> Option<String> {
    if storage_path.is_empty() || storage_path.starts_with("db://") || storage_path.starts_with("avatar-db://") {
        return None;
    }
    let raw = storage_path.replace('\\', "/");
    let raw = raw.trim_start_matches('/');
    if raw.contains("..") {
        return None;
    }
    if let Some(h) = hot_root() {
        let p = format!("{h}/{raw}");
        if exists(&p) {
            return Some(p);
        }
    }
    let p = format!("{}/{raw}", uploads_dir.trim_end_matches('/'));
    exists(&p).then_some(p)
}

pub struct Stored {
    pub storage_path: String,
    pub duplicate: bool,
}

/// Move (or write) an upload into `media/<hh>/<sha256><ext>`.
pub async fn save_to_disk(uploads_dir: &str, sha256: &str, ext: &str, source_path: Option<&str>, content: Option<&[u8]>) -> Result<Stored, String> {
    let rel_dir = format!("media/{}", &sha256[..2.min(sha256.len())]);
    let rel = format!("{rel_dir}/{sha256}{ext}");
    let uploads_dir = uploads_dir.trim_end_matches('/');
    if legacy_upload_path(uploads_dir, &rel).is_some() {
        if let Some(s) = source_path {
            let _ = tokio::fs::remove_file(s).await;
        }
        return Ok(Stored { storage_path: rel, duplicate: true });
    }
    let root = hot_root().unwrap_or_else(|| uploads_dir.to_string());
    let full_dir = format!("{root}/{rel_dir}");
    let full = format!("{root}/{rel}");
    tokio::fs::create_dir_all(&full_dir).await.map_err(|e| format!("Could not create storage dir: {e}"))?;
    let tmp = format!("{full}.tmp.{}", rand::random_range(100000..999999));
    if let Some(src) = source_path {
        if tokio::fs::rename(src, &full).await.is_err() {
            // Different filesystem: copy then rename into place.
            if let Err(e) = tokio::fs::copy(src, &tmp).await {
                let _ = tokio::fs::remove_file(&tmp).await;
                return Err(format!("Could not finalize stored file: {e} (check disk space)"));
            }
            tokio::fs::rename(&tmp, &full).await.map_err(|e| format!("Could not finalize stored file: {e}"))?;
            let _ = tokio::fs::remove_file(src).await;
        }
        return Ok(Stored { storage_path: rel, duplicate: false });
    }
    tokio::fs::write(&tmp, content.unwrap_or_default()).await.map_err(|e| format!("Could not open destination file: {e}"))?;
    if let Err(e) = tokio::fs::rename(&tmp, &full).await {
        let _ = tokio::fs::remove_file(&tmp).await;
        return Err(format!("Could not finalize stored file: {e}"));
    }
    Ok(Stored { storage_path: rel, duplicate: false })
}

pub fn tmp_path(suffix: &str) -> String {
    let dir = std::env::temp_dir();
    dir.join(format!("nyx-{}{suffix}", crate::auth::random_hex(8))).to_string_lossy().into_owned()
}

// ---- rendering -------------------------------------------------------------------------------------
fn scale(max_edge: i64) -> String {
    format!("scale='min({max_edge},iw)':-2:flags=lanczos")
}

fn webp_args(c: &mut Command, src: &str, dst: &str, max_edge: i64, quality: i64, seek: Option<f64>) {
    c.args(["-y", "-hide_banner", "-loglevel", "error"]);
    if let Some(s) = seek {
        c.arg("-ss").arg(fmt_num(s));
    }
    c.arg("-i").arg(src).args(["-frames:v", "1", "-vf"]).arg(scale(max_edge));
    c.args(["-c:v", "libwebp", "-compression_level", "5", "-quality"]).arg(quality.to_string()).args(["-f", "webp"]).arg(dst);
}

pub fn fmt_num(f: f64) -> String {
    if f.fract() == 0.0 { format!("{}", f as i64) } else { format!("{f}") }
}

/// One webp frame of `src` into `dst` (atomic via a .tmp.webp sibling).
pub async fn render_webp(src: &str, dst: &str, max_edge: i64, quality: i64, seek: Option<f64>) -> bool {
    let tmp = format!("{dst}.tmp.webp");
    let mut c = ffmpeg_cmd(15);
    webp_args(&mut c, src, &tmp, max_edge, quality, seek);
    if run_ok(c).await && file_size(&tmp) > 0 && tokio::fs::rename(&tmp, dst).await.is_ok() {
        return true;
    }
    let _ = tokio::fs::remove_file(&tmp).await;
    false
}

/// Video poster: first scene change in the opening 20s, else the frame at `fallback_seek`.
pub async fn render_webp_scene_aware(src: &str, dst: &str, max_edge: i64, quality: i64, fallback_seek: Option<f64>) -> bool {
    let tmp = format!("{dst}.tmp.webp");
    let mut c = ffmpeg_cmd(15);
    c.args(["-y", "-hide_banner", "-loglevel", "error", "-i"]).arg(src).args(["-t", "20", "-vf"]).arg(format!("select='gt(scene\\,0.3)',{}", scale(max_edge)));
    c.args(["-frames:v", "1", "-c:v", "libwebp", "-compression_level", "5", "-quality"]).arg(quality.to_string()).args(["-f", "webp"]).arg(&tmp);
    if run_ok(c).await && file_size(&tmp) > 0 && tokio::fs::rename(&tmp, dst).await.is_ok() {
        return true;
    }
    let _ = tokio::fs::remove_file(&tmp).await;
    render_webp(src, dst, max_edge, quality, fallback_seek).await
}

pub struct WebpOut {
    pub dst: String,
    pub max_edge: i64,
    pub quality: i64,
    pub compression_level: i64,
}

/// Several webp sizes from one decode. Returns per-output success.
pub async fn render_webp_multi(src: &str, outs: &[WebpOut], nice: i32) -> Vec<bool> {
    let n = outs.len();
    let mut parts = Vec::new();
    if n > 1 {
        parts.push(format!("[0:v]split={n}{}", (1..=n).map(|i| format!("[s{i}]")).collect::<String>()));
    }
    for (i, o) in outs.iter().enumerate() {
        let input = if n > 1 { format!("[s{}]", i + 1) } else { "[0:v]".into() };
        parts.push(format!("{input}scale='min({},iw)':-2:flags=lanczos[o{}]", o.max_edge, i + 1));
    }
    let mut c = ffmpeg_cmd(nice);
    c.args(["-y", "-hide_banner", "-loglevel", "error", "-i"]).arg(src).arg("-filter_complex").arg(parts.join(";"));
    for (i, o) in outs.iter().enumerate() {
        c.arg("-map").arg(format!("[o{}]", i + 1)).args(["-frames:v", "1", "-c:v", "libwebp", "-compression_level"]).arg(o.compression_level.to_string());
        c.arg("-quality").arg(o.quality.to_string()).args(["-f", "webp"]).arg(format!("{}.tmp.webp", o.dst));
    }
    run_ok(c).await;
    let mut ok = Vec::with_capacity(n);
    for o in outs {
        let tmp = format!("{}.tmp.webp", o.dst);
        if file_size(&tmp) > 0 {
            ok.push(tokio::fs::rename(&tmp, &o.dst).await.is_ok());
        } else {
            let _ = tokio::fs::remove_file(&tmp).await;
            ok.push(false);
        }
    }
    ok
}

pub async fn render_webp_bytes_from_path(src: &str, max_edge: i64, quality: i64) -> Option<Vec<u8>> {
    let dst = tmp_path(".webp");
    let ok = render_webp(src, &dst, max_edge, quality, None).await;
    let out = if ok { tokio::fs::read(&dst).await.ok() } else { None };
    let _ = tokio::fs::remove_file(&dst).await;
    out
}

pub async fn render_webp_from_bytes(content: &[u8], max_edge: i64, quality: i64, seek: Option<f64>) -> Option<Vec<u8>> {
    let src = tmp_path("");
    tokio::fs::write(&src, content).await.ok()?;
    let dst = tmp_path(".webp");
    let ok = render_webp(&src, &dst, max_edge, quality, seek).await;
    let _ = tokio::fs::remove_file(&src).await;
    let out = if ok { tokio::fs::read(&dst).await.ok() } else { None };
    let _ = tokio::fs::remove_file(&dst).await;
    out
}

pub fn video_placeholder_svg(width: i64) -> String {
    let height = 120.max(width * 9 / 16);
    format!(
        "<svg xmlns='http://www.w3.org/2000/svg' width='{width}' height='{height}' viewBox='0 0 {width} {height}'><rect width='100%' height='100%' fill='#18212d'/><circle cx='50%' cy='50%' r='48' fill='none' stroke='rgba(255,255,255,.62)' stroke-width='4'/><path d='M46% 42%v16l16-8z' fill='rgba(255,255,255,.72)'/></svg>"
    )
}

// ---- probes ----------------------------------------------------------------------------------------
pub async fn media_dimensions_from_path(src: &str) -> Option<(i64, i64)> {
    let mut c = Command::new(ffprobe_bin());
    c.args(["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0:s=x"]).arg(src);
    let out = run_out(c).await?;
    let line = out.lines().next()?.trim().to_string();
    let (w, h) = line.split_once('x')?;
    Some((w.parse().ok()?, h.parse().ok()?))
}

pub struct Fingerprint {
    pub phash: Option<String>,
    pub dhash: Option<String>,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub dominant_color: Option<String>,
}

fn pack_bits(get: impl Fn(usize) -> bool) -> String {
    let mut v: u64 = 0;
    for i in 0..64 {
        v = (v << 1) | get(i) as u64;
    }
    format!("{:016x}", v)
}

/// Perceptual hash (8x8 average), difference hash (9x8) and mean color,
/// computed from ffmpeg-scaled raw frames exactly like the Lua build.
pub async fn image_fingerprint_from_path(src: &str) -> Option<Fingerprint> {
    let dims = media_dimensions_from_path(src).await;
    let base = tmp_path("");
    let (pp, dp, cp) = (format!("{base}.p.raw"), format!("{base}.d.raw"), format!("{base}.c.raw"));
    let mut c = ffmpeg_cmd(15);
    c.args(["-y", "-hide_banner", "-loglevel", "error", "-i"]).arg(src).arg("-filter_complex");
    c.arg("[0:v]split=3[a][b][c0];[a]scale=8:8:flags=lanczos,format=gray[p];[b]scale=9:8:flags=lanczos,format=gray[d];[c0]scale=8:8:flags=lanczos,format=rgb24[c]");
    c.args(["-map", "[p]", "-frames:v", "1", "-f", "rawvideo"]).arg(&pp);
    c.args(["-map", "[d]", "-frames:v", "1", "-f", "rawvideo"]).arg(&dp);
    c.args(["-map", "[c]", "-frames:v", "1", "-f", "rawvideo"]).arg(&cp);
    run_ok(c).await;
    async fn slurp(p: &str, want: usize) -> Option<Vec<u8>> {
        let b = tokio::fs::read(p).await.ok();
        let _ = tokio::fs::remove_file(p).await;
        b.filter(|b| b.len() == want)
    }
    let (p, d, rgb) = (slurp(&pp, 64).await, slurp(&dp, 72).await, slurp(&cp, 192).await);
    if p.is_none() && d.is_none() {
        return None;
    }
    let phash = p.map(|px| {
        let avg = px.iter().map(|&b| b as f64).sum::<f64>() / px.len() as f64;
        pack_bits(|i| px[i] as f64 >= avg)
    });
    let dhash = d.map(|px| {
        pack_bits(|i| {
            let (row, col) = (i / 8, i % 8);
            let o = row * 9 + col;
            px[o] > px[o + 1]
        })
    });
    let dominant_color = rgb.map(|px| {
        let (mut r, mut g, mut b) = (0u32, 0u32, 0u32);
        for c in px.chunks(3) {
            r += c[0] as u32;
            g += c[1] as u32;
            b += c[2] as u32;
        }
        let avg = |x: u32| ((x as f64 / 64.0) + 0.5).floor() as u32;
        format!("#{:02x}{:02x}{:02x}", avg(r), avg(g), avg(b))
    });
    Some(Fingerprint { phash, dhash, width: dims.map(|d| d.0), height: dims.map(|d| d.1), dominant_color })
}

pub struct Mp4Layout {
    pub faststart: Option<bool>,
    pub moov_size: Option<u64>,
}

/// Walk top-level MP4 boxes: is `moov` before `mdat`?
pub fn mp4_layout(path: &str) -> Option<Mp4Layout> {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = std::fs::File::open(path).ok()?;
    let size = f.seek(SeekFrom::End(0)).ok()?;
    let (mut pos, mut result, mut moov_size, mut seen_mdat) = (0u64, None, None, false);
    for _ in 0..64 {
        if pos + 8 > size {
            break;
        }
        f.seek(SeekFrom::Start(pos)).ok()?;
        let mut h = [0u8; 8];
        if f.read_exact(&mut h).is_err() {
            break;
        }
        let mut box_size = u32::from_be_bytes([h[0], h[1], h[2], h[3]]) as u64;
        let kind = &h[4..8];
        if box_size == 1 {
            let mut e = [0u8; 8];
            if f.read_exact(&mut e).is_err() {
                break;
            }
            box_size = u64::from_be_bytes(e);
        } else if box_size == 0 {
            box_size = size - pos;
        }
        if kind == b"moov" {
            moov_size = Some(box_size);
            if result.is_none() {
                result = Some(true);
            }
            break;
        }
        if kind == b"mdat" && !seen_mdat {
            seen_mdat = true;
            result = Some(false);
        }
        if box_size < 8 {
            break;
        }
        pos += box_size;
    }
    Some(Mp4Layout { faststart: result, moov_size })
}

/// Base64 JPEG (<=1600px) of the first frame, for vision-model prompts.
pub async fn jpeg_preview_base64_from_path(src: &str) -> Option<String> {
    use base64::Engine;
    let dst = tmp_path(".jpg");
    let mut c = ffmpeg_cmd(15);
    c.args(["-y", "-hide_banner", "-loglevel", "error", "-i"]).arg(src).args(["-frames:v", "1", "-vf"]);
    c.arg("scale='min(1600,iw)':'min(1600,ih)':force_original_aspect_ratio=decrease:flags=lanczos").args(["-q:v", "3", "-f", "mjpeg"]).arg(&dst);
    let ok = run_ok(c).await;
    let bytes = if ok { tokio::fs::read(&dst).await.ok() } else { None };
    let _ = tokio::fs::remove_file(&dst).await;
    bytes.filter(|b| !b.is_empty()).map(|b| base64::engine::general_purpose::STANDARD.encode(b))
}

