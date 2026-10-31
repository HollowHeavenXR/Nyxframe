//! Collections (manual and smart/filter-based) and tag-based suggestions.

use crate::app::uid;
use crate::db::{J, Sql};
use crate::http::{R, Reply, Req};
use crate::media::{FROM_JOINS, fetch_by_id, finish_rows, select_cols};
use crate::routes::browse::{MediaFilter, query_media};
use crate::routes::notify::sanitize_smart_filter;
use crate::util::{append_query, bools, cut, tobool, vstr};
use serde_json::{Value, json};
use std::collections::HashMap;

const COLLECTION_SELECT: &str = "SELECT mc.*, u.username, u.display_name, u.avatar_path AS user_avatar_path, COUNT(mi.id) AS item_count, \
     MAX(mi.storage_path) AS cover_path, MAX(mi.media_kind) AS cover_media_kind, MAX(mi.id) AS cover_media_id, \
     MAX(CASE WHEN mi.is_adult THEN 1 ELSE 0 END) AS cover_is_adult \
   FROM media_collections mc JOIN users u ON u.id = mc.user_id \
   LEFT JOIN media_collection_items mci ON mci.collection_id = mc.id \
   LEFT JOIN media_items mi ON mi.id = mci.media_id AND mi.deleted_at IS NULL AND (mi.visibility='public' OR mi.user_id=$1 OR mc.user_id=$1)";

fn clean(v: Option<String>, max: usize) -> String {
    cut(&v.unwrap_or_default().split_whitespace().collect::<Vec<_>>().join(" "), max)
}

fn decode(mut r: Value) -> Value {
    bools(&mut r, &["is_public", "is_smart", "cover_is_adult"]);
    for k in ["is_public", "is_smart", "cover_is_adult"] {
        if r.get(k).is_none() {
            r[k] = json!(false);
        }
    }
    let filter = if tobool(r.get("is_smart")) { r.s("filter_json").and_then(|f| serde_json::from_str::<Value>(&f).ok()).filter(Value::is_object) } else { None };
    r["filter"] = filter.unwrap_or_else(|| json!({}));
    r
}

fn with_urls(req: &Req, mut c: Value, adult: bool) -> Value {
    let origin = req.origin();
    let cover_adult = tobool(c.get("cover_is_adult"));
    let o = c.as_object_mut().unwrap();
    if o.contains_key("cover_path") && (adult || !cover_adult) {
        if let Some(id) = o.get("cover_media_id").cloned() {
            o.insert("cover_url".into(), json!(format!("{origin}/api/media/{}/file", vstr(Some(&id)).unwrap_or_default())));
        }
    } else if cover_adult {
        o.remove("cover_path");
        o.remove("cover_url");
        o.insert("cover_locked".into(), json!(true));
    }
    if o.contains_key("user_avatar_path") {
        let id = o.get("user_id").or(o.get("id")).cloned().unwrap_or(json!(0));
        o.insert("user_avatar_url".into(), json!(format!("{origin}/api/users/{}/avatar", vstr(Some(&id)).unwrap_or_default())));
    }
    c
}

async fn fetch(req: &Req, id: i64, viewer: Option<i64>) -> Option<Value> {
    let v = viewer.unwrap_or(0);
    req.app.db.opt(&format!("{COLLECTION_SELECT} WHERE mc.id=$2 AND (mc.is_public OR mc.user_id=$1) GROUP BY mc.id, u.id"), &[v.into(), id.into()]).await
}

pub async fn suggestions(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    let db = &req.app.db;
    let existing = db.all(&format!("{COLLECTION_SELECT} WHERE mc.user_id=$1 GROUP BY mc.id, u.id"), &[u.into()]).await;
    let covered: Vec<String> = existing
        .iter()
        .filter(|r| tobool(r.get("is_smart")))
        .filter_map(|r| r.s("filter_json").and_then(|f| serde_json::from_str::<Value>(&f).ok()))
        .filter_map(|f| vstr(f.get("q")).map(|q| q.to_lowercase()))
        .collect();
    let rows = db.all("SELECT id, tags FROM media_items WHERE user_id=$1 AND deleted_at IS NULL AND tags IS NOT NULL ORDER BY created_at DESC LIMIT 1000", &[u.into()]).await;
    let (mut counts, mut sample): (HashMap<String, i64>, HashMap<String, i64>) = Default::default();
    for r in rows {
        for t in r.s("tags").and_then(|t| serde_json::from_str::<Vec<Value>>(&t).ok()).unwrap_or_default() {
            let n = cut(&vstr(Some(&t)).unwrap_or_default().trim().to_lowercase(), 32);
            if n.is_empty() {
                continue;
            }
            *counts.entry(n.clone()).or_insert(0) += 1;
            sample.entry(n).or_insert(r.i("id").unwrap_or(0));
        }
    }
    let mut order: Vec<&String> = counts.iter().filter(|(t, c)| **c >= 4 && !covered.contains(t)).map(|(t, _)| t).collect();
    order.sort_by(|a, b| counts[*b].cmp(&counts[*a]).then_with(|| a.cmp(b)));
    let origin = req.origin();
    let out: Vec<Value> = order.iter().take(8).map(|t| json!({ "tag": t, "count": counts[*t], "thumb_url": append_query(&format!("{origin}/api/media/{}/thumb", sample[*t]), "w", "640") })).collect();
    Ok(Reply::ok(json!({ "suggestions": out })))
}

pub async fn list(req: Req) -> R<Reply> {
    let viewer = req.viewer().await;
    let adult = req.app.viewer_adult_allowed(viewer).await;
    let mine = matches!(req.query.get("mine").map(String::as_str), Some("true") | Some("1"));
    if mine && viewer.is_none() {
        return Err(Reply::err(401, "Login required"));
    }
    let filter = if mine { "mc.user_id=$1" } else { "(mc.is_public OR mc.user_id=$1)" };
    let rows = req.app.db.all(&format!("{COLLECTION_SELECT} WHERE {filter} GROUP BY mc.id, u.id ORDER BY mc.updated_at DESC, mc.created_at DESC LIMIT 100"), &[viewer.unwrap_or(0).into()]).await;
    let out: Vec<Value> = rows.into_iter().map(|r| with_urls(&req, decode(r), adult)).collect();
    Ok(Reply::ok(json!({ "collections": out })))
}

pub async fn create(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    let name = clean(req.js("name"), 100);
    if name.is_empty() {
        return Err(Reply::err(400, "Name is required."));
    }
    let desc = Some(clean(req.js("description"), 500)).filter(|d| !d.is_empty());
    let is_public = req.json.get("is_public").is_none_or(|v| v.is_null() || tobool(Some(v)));
    let is_smart = tobool(req.json.get("is_smart"));
    let stored = is_smart.then(|| cut(&sanitize_smart_filter(req.json.get("filter_json")).to_string(), 8000));
    let id = req
        .app
        .db
        .opt(
            "INSERT INTO media_collections (user_id, name, description, is_public, is_smart, filter_json) VALUES ($1, $2, $3, $4, $5, $6) RETURNING id",
            &[u.into(), name.into(), desc.into(), is_public.into(), is_smart.into(), stored.into()],
        )
        .await
        .and_then(|r| r.i("id"))
        .ok_or_else(|| Reply::err(500, "Could not create collection."))?;
    let adult = req.app.viewer_adult_allowed(Some(u)).await;
    let c = fetch(&req, id, Some(u)).await.map(|c| with_urls(&req, decode(c), adult));
    Ok(Reply::ok(json!({ "collection": c })))
}

pub async fn detail(req: Req) -> R<Reply> {
    Ok(Reply::ok(detail_json(&req).await?))
}

/// { collection, media } for one collection (also used by the zip download).
pub async fn detail_json(req: &Req) -> R<Value> {
    let req = req;
    let Some(cid) = req.pi("collection_id") else { return Err(Reply::err(404, "Collection not found.")) };
    let viewer = req.viewer().await;
    let adult = req.app.viewer_adult_allowed(viewer).await;
    let c = decode(fetch(&req, cid, viewer).await.ok_or_else(|| Reply::err(404, "Collection not found."))?);
    let media = if tobool(c.get("is_smart")) {
        let f = &c["filter"];
        let mf = MediaFilter {
            media_kind: vstr(f.get("media_kind")),
            category_id: crate::util::vint(f.get("category_id")),
            subcategory_id: crate::util::vint(f.get("subcategory_id")),
            q: cut(vstr(f.get("q")).unwrap_or_default().trim(), 80),
            uploader: cut(vstr(f.get("uploader")).unwrap_or_default().trim(), 80),
            min_size: crate::util::vint(f.get("min_size")),
            max_size: crate::util::vint(f.get("max_size")),
            date_from: vstr(f.get("date_from")),
            date_to: vstr(f.get("date_to")),
            adult: vstr(f.get("adult")),
            tags: None,
            color: None,
            color_tolerance: 40,
            sort: vstr(f.get("sort")).filter(|s| ["new", "old", "popular", "views", "downloads", "trending"].contains(&s.as_str())).unwrap_or_else(|| "new".into()),
        };
        let limit = 120.min(req.app.settings.media_page_limit);
        query_media(req, viewer, adult, &mf, limit, 0).await.map(|(r, _)| r).unwrap_or_default()
    } else {
        let mut q = Sql::new();
        let vt = q.bind(viewer.unwrap_or(0).to_string());
        let c_id = q.bind(cid);
        let adult_clause = if adult { "" } else { "AND m.is_adult=false" };
        let sql = format!(
            "{} {} JOIN media_collection_items mci ON mci.media_id = m.id WHERE mci.collection_id={c_id} AND m.deleted_at IS NULL AND (m.visibility='public' OR m.user_id::text={vt}) {adult_clause} ORDER BY mci.added_at DESC LIMIT 120",
            select_cols(&vt),
            FROM_JOINS
        );
        let mut rows = req.app.db.all(&sql, &q.params).await;
        finish_rows(req, &mut rows, adult).await;
        rows
    };
    Ok(json!({ "collection": with_urls(req, c, adult), "media": media }))
}

pub async fn save_item(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let u = uid(&user);
    let Some(cid) = req.pi("collection_id") else { return Err(Reply::err(404, "Collection not found.")) };
    let Some(mid) = req.ji("media_id") else { return Err(Reply::err(400, "media_id is required.")) };
    let saved = req.json.get("saved").is_none_or(|v| v.is_null() || tobool(Some(v)));
    let nf = || Reply::err(404, "Collection not found.");
    let c = fetch(&req, cid, Some(u)).await.filter(|c| c.i("user_id") == Some(u)).ok_or_else(nf)?;
    let _ = c;
    let m = fetch_by_id(&req, mid, Some(u)).await.filter(|m| m["deleted_at"].is_null()).ok_or_else(nf)?;
    if m.s("visibility").as_deref() == Some("private") && m.i("user_id") != Some(u) {
        return Err(nf());
    }
    let db = &req.app.db;
    let sql = if saved { "INSERT INTO media_collection_items (collection_id, media_id) VALUES ($1, $2) ON CONFLICT (collection_id, media_id) DO NOTHING" } else { "DELETE FROM media_collection_items WHERE collection_id=$1 AND media_id=$2" };
    let _ = db.exec(sql, &[cid.into(), mid.into()]).await;
    let _ = db.exec("UPDATE media_collections SET updated_at=CURRENT_TIMESTAMP WHERE id=$1", &[cid.into()]).await;
    let adult = req.app.viewer_adult_allowed(Some(u)).await;
    let c = fetch(&req, cid, Some(u)).await.map(|c| with_urls(&req, decode(c), adult));
    Ok(Reply::ok(json!({ "collection": c })))
}

/// A profile's visible collections (newest first).
pub async fn for_profile(req: &Req, owner: i64, viewer: Option<i64>, adult: bool, limit: i64) -> Vec<Value> {
    let rows = req
        .app
        .db
        .all(
            &format!("{COLLECTION_SELECT} WHERE mc.user_id=$2 AND (mc.is_public OR mc.user_id=$1) GROUP BY mc.id, u.id ORDER BY mc.updated_at DESC, mc.created_at DESC LIMIT $3"),
            &[viewer.unwrap_or(0).into(), owner.into(), limit.into()],
        )
        .await;
    rows.into_iter().map(|r| with_urls(req, decode(r), adult)).collect()
}
