//! Shell chrome endpoints: tag cloud, announcement banner, rotating background.

use crate::db::J;
use crate::http::{R, Reply, Req};
use crate::util::{append_query, cut, tobool};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Mutex;

pub async fn tag_cloud(req: Req) -> R<Reply> {
    let rows = req.app.db.all("SELECT tags FROM media_items WHERE tags IS NOT NULL AND deleted_at IS NULL AND visibility='public' ORDER BY created_at DESC LIMIT 500", &[]).await;
    let mut counts: HashMap<String, i64> = HashMap::new();
    let mut order: Vec<String> = Vec::new();
    for r in rows {
        let Some(list) = r.s("tags").and_then(|t| serde_json::from_str::<Vec<Value>>(&t).ok()) else { continue };
        for t in list {
            let n = cut(crate::util::vstr(Some(&t)).unwrap_or_default().trim(), 32);
            if n.is_empty() {
                continue;
            }
            let c = counts.entry(n.clone()).or_insert(0);
            if *c == 0 {
                order.push(n);
            }
            *c += 1;
        }
    }
    order.sort_by(|a, b| counts[b].cmp(&counts[a]).then_with(|| a.to_lowercase().cmp(&b.to_lowercase())));
    let out: Vec<Value> = order.iter().take(30).map(|t| json!({ "tag": t, "count": counts[t] })).collect();
    Ok(Reply::ok(json!({ "tags": out })))
}

pub async fn announcement(req: Req) -> R<Reply> {
    let row = req.app.db.opt("SELECT announcement_message, announcement_level, announcement_active, maintenance_mode, maintenance_message FROM site_settings WHERE id=1", &[]).await.unwrap_or_else(|| json!({}));
    let mut out = json!({
        "announcement_level": row.s("announcement_level").unwrap_or_else(|| "info".into()),
        "announcement_active": tobool(row.get("announcement_active")),
        "maintenance_mode": tobool(row.get("maintenance_mode")),
    });
    for k in ["announcement_message", "maintenance_message"] {
        if let Some(v) = row.s(k) {
            out[k] = json!(v);
        }
    }
    Ok(Reply::ok(out))
}

const ROTATE_SECS: i64 = 300;

#[derive(Default)]
struct Bg {
    candidates: Option<(i64, Vec<Value>)>,
    item: Option<Value>,
    picked_at: i64,
}
static BG: Mutex<Option<Bg>> = Mutex::new(None);

async fn candidates(req: &Req) -> Vec<Value> {
    let now = crate::util::now();
    if let Some((at, items)) = BG.lock().unwrap().as_ref().and_then(|b| b.candidates.clone()) {
        if now - at < ROTATE_SECS {
            return items;
        }
    }
    let rows = req
        .app
        .db
        .all(
            "SELECT m.id, m.title, m.original_filename, m.mime_type, m.image_width, m.image_height, c.name AS category_name, sc.name AS subcategory_name, \
               u.username, CASE WHEN u.public_profile THEN u.display_name ELSE u.username END AS display_name \
             FROM media_items m JOIN categories c ON c.id = m.category_id LEFT JOIN subcategories sc ON sc.id = m.subcategory_id JOIN users u ON u.id = m.user_id \
             WHERE m.deleted_at IS NULL AND m.visibility='public' AND m.media_kind='image' AND m.is_adult=false \
               AND m.image_width IS NOT NULL AND m.image_height IS NOT NULL AND m.image_width > m.image_height \
             ORDER BY COALESCE(m.pinned_at, m.created_at) DESC, m.created_at DESC LIMIT 180",
            &[],
        )
        .await;
    BG.lock().unwrap().get_or_insert_with(Bg::default).candidates = Some((now, rows.clone()));
    rows
}

pub async fn background(req: Req) -> R<Reply> {
    let now = crate::util::now();
    let needs = BG.lock().unwrap().as_ref().is_none_or(|b| b.item.is_none() || b.picked_at == 0 || now - b.picked_at >= ROTATE_SECS);
    if needs {
        let c = candidates(&req).await;
        let mut g = BG.lock().unwrap();
        let st = g.get_or_insert_with(Bg::default);
        if c.is_empty() {
            st.item = None;
        } else {
            let prev = st.item.as_ref().and_then(|i| i.i("id"));
            let pool: Vec<&Value> = c.iter().filter(|i| i.i("id") != prev).collect();
            let pool = if pool.is_empty() { c.iter().collect() } else { pool };
            st.item = Some(pool[rand::random_range(0..pool.len())].clone());
        }
        st.picked_at = now;
    }
    let (item, picked_at) = {
        let g = BG.lock().unwrap();
        let st = g.as_ref().unwrap();
        (st.item.clone(), st.picked_at)
    };
    let Some(item) = item else {
        return Ok(Reply::ok(json!({
            "enabled": false, "background": null, "background_url": null, "url": null, "updated_at": null, "status": "disabled", "refresh_after_seconds": ROTATE_SECS,
        })));
    };
    let origin = req.origin();
    let id = item.i("id").unwrap_or(0);
    let mime = item.s("mime_type").unwrap_or_default().to_lowercase();
    let name = item.s("original_filename").unwrap_or_default().to_lowercase();
    let url = if mime == "image/gif" || name.ends_with(".gif") { format!("{origin}/api/media/{id}/file") } else { append_query(&format!("{origin}/api/media/{id}/thumb.webp"), "w", "1440") };
    let title = item.s("title").or(item.s("original_filename")).unwrap_or_else(|| format!("Background {id}"));
    Ok(Reply::ok(json!({
        "enabled": true,
        "status": "active",
        "background": {
            "id": id, "title": title, "username": item["username"], "display_name": item["display_name"],
            "category_name": item["category_name"], "subcategory_name": item["subcategory_name"],
            "width": item["image_width"], "height": item["image_height"], "url": url,
        },
        "updated_at": picked_at,
        "refresh_after_seconds": (ROTATE_SECS - (now - picked_at)).max(1),
    })))
}
