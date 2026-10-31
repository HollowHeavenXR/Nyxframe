//! Client-reported diagnostics (media load, playback, uploads) -> telemetry rows.

use crate::http::{R, Reply, Req};
use crate::util::{cut, truthy, vnum, vstr};
use serde_json::{Value, json};

fn field(req: &Req, k: &str, n: usize) -> String {
    cut(&vstr(req.json.get(k)).unwrap_or_default().to_lowercase(), n)
}

fn some(s: String) -> Value {
    if s.is_empty() { Value::Null } else { json!(s) }
}

fn num(req: &Req, k: &str) -> Option<i64> {
    vnum(req.json.get(k)).map(|f| f.floor() as i64)
}

pub async fn media_load(req: Req) -> R<Reply> {
    let id = req.p("media_id");
    let viewer = req.viewer().await;
    let (ctx, outcome, kind, sel) = (field(&req, "context", 48), field(&req, "outcome", 32), field(&req, "media_kind", 16), field(&req, "selected_source", 32));
    println!(
        "[nyxframe] media load diagnostic media_id={id} outcome={} context={} selected={} media_kind={} viewer_id={}",
        if outcome.is_empty() { "unknown" } else { &outcome },
        if ctx.is_empty() { "unknown" } else { &ctx },
        if sel.is_empty() { "none" } else { &sel },
        if kind.is_empty() { "unknown" } else { &kind },
        viewer.unwrap_or(0)
    );
    let out = if outcome.is_empty() { "unknown".to_string() } else { outcome };
    req.app.telemetry.record("media_load", Some(&id), Some(&out), None, Some(json!({ "context": some(ctx), "selected_source": some(sel), "media_kind": some(kind), "viewer_id": viewer })));
    Ok(Reply::ok(json!({ "ok": true })))
}

pub async fn media_playback(req: Req) -> R<Reply> {
    let id = req.p("media_id");
    let viewer = req.viewer().await;
    let outcome = field(&req, "outcome", 32);
    let quality = field(&req, "quality", 16);
    let meta = json!({
        "quality": some(quality),
        "stall_count": num(&req, "stall_count").unwrap_or(0).max(0),
        "stall_total_ms": num(&req, "stall_total_ms").unwrap_or(0).max(0),
        "quality_downgrade_count": num(&req, "quality_downgrade_count").unwrap_or(0).max(0),
        "using_hls_js": truthy(req.json.get("using_hls_js")),
        "viewer_id": viewer,
    });
    let out = if outcome.is_empty() { "unknown".to_string() } else { outcome };
    req.app.telemetry.record("media_playback", Some(&id), Some(&out), num(&req, "time_to_first_frame_ms"), Some(meta));
    Ok(Reply::ok(json!({ "ok": true })))
}

pub async fn upload_diagnostic(req: Req) -> R<Reply> {
    let viewer = req.viewer().await;
    let outcome = field(&req, "outcome", 32);
    let method = field(&req, "method", 16);
    let meta = json!({
        "bytes": num(&req, "bytes"),
        "chunk_count": num(&req, "chunk_count"),
        "retry_count": num(&req, "retry_count"),
        "error": vstr(req.json.get("error_message")).map(|e| cut(&e, 300)),
        "viewer_id": viewer,
    });
    let subject = format!("client_{}", if method.is_empty() { "unknown" } else { &method });
    let out = if outcome.is_empty() { "unknown".to_string() } else { outcome };
    req.app.telemetry.record("upload", Some(&subject), Some(&out), num(&req, "duration_ms"), Some(meta));
    Ok(Reply::ok(json!({ "ok": true })))
}
