//! AI vision status and per-user training examples (corrections).

use crate::app::uid;
use crate::db::J;
use crate::http::{R, Reply, Req};
use crate::util::{cut, json_list, truthy, vnum, vstr};
use serde_json::{Value, json};

fn provider(req: &Req) -> String {
    let p = req.app.settings.ai_provider.to_lowercase();
    match p.as_str() {
        "google" | "google-gemini" => "gemini".into(),
        "" => "heuristic-only".into(),
        _ => p,
    }
}

pub async fn vision_status(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let s = req.app.settings.clone();
    let p = provider(&req);
    let n = req.app.db.all("SELECT id FROM ai_vision_training_examples WHERE user_id=$1 ORDER BY created_at DESC LIMIT 1000", &[uid(&user).into()]).await.len();
    let model = match s.ai_provider.as_str() {
        "ollama" => s.ai_ollama_model.clone(),
        _ => s.ai_model.clone(),
    };
    let mut v = json!({
        "provider": p, "ai_enabled": s.ai_enabled, "training_examples_loaded_limit": s.ai_training_examples_limit, "training_examples_available": n,
        "active_model": model, "gemini_key_configured": !s.ai_api_key.is_empty() && p == "gemini",
    });
    if p == "gemini" {
        v["active_base_url"] = json!("https://generativelanguage.googleapis.com");
        if s.ai_api_key.is_empty() {
            v["reachable"] = json!(false);
            v["reason"] = json!("Gemini provider is selected but no Gemini API key is configured.");
        }
    } else if p == "ollama" {
        let base = s.ai_ollama_base_url.trim_end_matches('/').to_string();
        v["active_base_url"] = json!(base);
        match req.app.http.get(format!("{base}/api/tags")).timeout(std::time::Duration::from_secs(3)).send().await {
            Ok(r) if r.status().as_u16() == 200 => {
                let d: Value = r.json().await.unwrap_or_else(|_| json!({}));
                let models: Vec<Value> = d["models"].as_array().into_iter().flatten().filter_map(|m| m["name"].as_str().filter(|n| !n.is_empty()).map(|n| json!(n))).take(50).collect();
                v["reachable"] = json!(true);
                v["models"] = json!(models);
            }
            Ok(r) => {
                v["reachable"] = json!(false);
                v["reason"] = json!(format!("HTTP {}", r.status().as_u16()));
            }
            Err(e) => {
                v["reachable"] = json!(false);
                v["reason"] = json!(cut(&e.to_string(), 240));
            }
        }
    }
    Ok(Reply::ok(json!({ "vision": v })))
}

fn decode(mut r: Value) -> Value {
    for k in ["source_tags", "corrected_tags"] {
        r[k] = json_list(r.get(k));
    }
    r["corrected_is_adult"] = json!(crate::util::tobool(r.get("corrected_is_adult")));
    r
}

pub async fn list_training(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let limit = req.qi("limit").unwrap_or(50).clamp(1, 80);
    let rows: Vec<Value> = req.app.db.all("SELECT * FROM ai_vision_training_examples WHERE user_id=$1 ORDER BY created_at DESC LIMIT $2", &[uid(&user).into(), limit.into()]).await.into_iter().map(decode).collect();
    Ok(Reply::ok(json!({ "training_examples": rows })))
}

pub async fn export_training(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let limit = req.qi("limit").unwrap_or(500).clamp(1, 5000);
    let rows = req
        .app
        .db
        .all("SELECT t.*, m.media_kind, m.mime_type FROM ai_vision_training_examples t LEFT JOIN media_items m ON m.id = t.media_id WHERE t.user_id=$1 ORDER BY t.created_at DESC LIMIT $2", &[uid(&user).into(), limit.into()])
        .await;
    let mut body = rows.into_iter().map(|r| decode(r).to_string()).collect::<Vec<_>>().join("\n");
    if !body.is_empty() {
        body.push('\n');
    }
    Ok(Reply::text(200, body, "application/x-ndjson; charset=utf-8").header("Content-Disposition", "attachment; filename=\"gallery-ai-vision-training.jsonl\""))
}

fn clean_text(v: Option<String>, n: usize) -> Option<String> {
    Some(cut(&v.unwrap_or_default().split_whitespace().collect::<Vec<_>>().join(" "), n)).filter(|s| !s.is_empty())
}

fn clean_ai_tags(v: Option<&Value>) -> Vec<String> {
    let items: Vec<String> = match v {
        Some(Value::String(s)) => s.split(|c: char| c == ',' || c == '#' || c.is_whitespace()).filter(|t| !t.is_empty()).map(str::to_string).collect(),
        Some(Value::Array(a)) => a.iter().filter_map(|x| vstr(Some(x))).collect(),
        _ => vec![],
    };
    let mut out: Vec<String> = Vec::new();
    for raw in items {
        let t: String = raw.trim().chars().filter(|c| c.is_ascii_alphanumeric() || "_.-".contains(*c)).collect();
        let t = cut(&t, 32);
        if !t.is_empty() && !out.iter().any(|o| o.to_lowercase() == t.to_lowercase()) {
            out.push(t);
            if out.len() >= 12 {
                break;
            }
        }
    }
    out
}

pub async fn train_media(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    let id = req.pi("media_id").ok_or_else(|| Reply::err(404, "Media not found."))?;
    let item = crate::media::fetch_by_id(&req, id, Some(u)).await.ok_or_else(|| Reply::err(404, "Media not found."))?;
    let title = clean_text(req.js("title"), 160).ok_or_else(|| Reply::err(400, "Title is required."))?;
    let db = &req.app.db;
    let row = db.opt("SELECT id, user_id FROM media_items WHERE id=$1 AND deleted_at IS NULL", &[id.into()]).await.ok_or_else(|| Reply::err(404, "Media not found."))?;
    if row.i("user_id") != Some(u) {
        return Err(Reply::err(403, "You can only train AI using your own media."));
    }
    let cat = clean_text(req.js("category_name"), 80);
    let sub = clean_text(req.js("subcategory_name"), 80);
    let tags = clean_ai_tags(req.json.get("tags"));
    let src_tags = clean_ai_tags(Some(&json_list(item.get("tags"))));
    let fname = clean_text(item.s("original_filename"), 255);
    let (s_title, s_cat, s_sub) = (clean_text(item.s("title"), 160), clean_text(item.s("category_name"), 80), clean_text(item.s("subcategory_name"), 80));
    let notes = clean_text(req.js("notes"), 500);
    let adult = truthy(req.json.get("is_adult"));
    let conf = vnum(req.json.get("training_confidence")).unwrap_or(0.72).clamp(0.0, 1.0);
    let key = crate::auth::sha256_hex(
        &[u.to_string(), id.to_string(), fname.clone().unwrap_or_default(), title.clone(), cat.clone().unwrap_or_default(), sub.clone().unwrap_or_default(), tags.join(","), String::new(), String::new()].join("|"),
    );
    let tid = match db.opt("SELECT id FROM ai_vision_training_examples WHERE dedupe_key=$1 LIMIT 1", &[key.as_str().into()]).await.and_then(|r| r.i("id")) {
        Some(t) => {
            let _ = db
                .exec(
                    "UPDATE ai_vision_training_examples SET source_title=COALESCE($1, source_title), source_category_name=COALESCE($2, source_category_name), \
                       source_subcategory_name=COALESCE($3, source_subcategory_name), source_tags=$4, corrected_title=$5, corrected_category_name=COALESCE($6, corrected_category_name), \
                       corrected_subcategory_name=COALESCE($7, corrected_subcategory_name), corrected_tags=$8, corrected_is_adult=$9, notes=COALESCE($10, notes), \
                       original_filename=COALESCE($11, original_filename), training_confidence=GREATEST(training_confidence, $12) WHERE id=$13",
                    &[s_title.into(), s_cat.into(), s_sub.into(), json!(src_tags).to_string().into(), title.into(), cat.into(), sub.into(), json!(tags).to_string().into(), adult.into(), notes.into(), fname.into(), conf.into(), t.into()],
                )
                .await;
            t
        }
        None => db
            .one(
                "INSERT INTO ai_vision_training_examples (user_id, media_id, original_filename, source_title, source_category_name, source_subcategory_name, source_tags, corrected_title, \
                   corrected_category_name, corrected_subcategory_name, corrected_tags, corrected_is_adult, notes, dedupe_key, training_confidence) \
                 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15) RETURNING id",
                &[u.into(), id.into(), fname.into(), s_title.into(), s_cat.into(), s_sub.into(), json!(src_tags).to_string().into(), title.into(), cat.into(), sub.into(), json!(tags).to_string().into(), adult.into(), notes.into(), key.into(), conf.into()],
            )
            .await
            .map_err(|e| Reply::err(400, format!("Could not save training example: {e}")))?
            .and_then(|r| r.i("id"))
            .unwrap_or(0),
    };
    let ex = db.opt("SELECT * FROM ai_vision_training_examples WHERE id=$1", &[tid.into()]).await.map(decode);
    Ok(Reply::ok(json!({ "training_example": ex })))
}
