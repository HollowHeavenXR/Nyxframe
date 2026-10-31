//! Browsing: categories, GET /api/media, the feeds (signal, following,
//! liked, trending, for-you), leaderboard, Studio lists, creator stats and
//! the year recap.

use crate::app::uid;
use crate::db::{J, P, Sql};
use crate::http::{R, Reply, Req};
use crate::media::{self, FROM_JOINS, bounded_limit, bounded_offset, fetch_feed, finish_rows, query_failed, select_cols, select_cols_own};
use crate::util::{cut, slugify, tobool};
use serde_json::{Value, json};
use std::collections::HashMap;

// ---- categories --------------------------------------------------------------------------------
pub async fn list_categories(req: Req) -> R<Reply> {
    let db = &req.app.db;
    let mut cats = db
        .all(
            "SELECT c.id, c.name, c.slug, c.media_kind, c.created_by, c.created_at, COUNT(m.id) AS media_count FROM categories c \
             LEFT JOIN media_items m ON m.category_id = c.id AND m.deleted_at IS NULL GROUP BY c.id ORDER BY c.name",
            &[],
        )
        .await;
    let subs = db
        .all(
            "SELECT s.id, s.category_id, s.name, s.slug, s.created_by, s.created_at, COUNT(m.id) AS media_count FROM subcategories s \
             LEFT JOIN media_item_subcategories ms ON ms.subcategory_id = s.id LEFT JOIN media_items m ON m.id = ms.media_id AND m.deleted_at IS NULL \
             GROUP BY s.id ORDER BY s.name",
            &[],
        )
        .await;
    let mut grouped: HashMap<i64, Vec<Value>> = HashMap::new();
    for s in subs {
        grouped.entry(s.i("category_id").unwrap_or(0)).or_default().push(s);
    }
    for c in &mut cats {
        c["subcategories"] = json!(grouped.remove(&c.i("id").unwrap_or(0)).unwrap_or_default());
    }
    Ok(Reply::ok(json!({ "categories": cats })))
}

pub const MEDIA_KINDS: &[&str] = &["image", "video", "mixed"];

pub async fn create_category(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    req.app.rate_check(&format!("category_create:{}", uid(&user)), 20, 3600).await?;
    let name = cut(req.js("name").unwrap_or_default().trim(), 80);
    let kind = req.js("media_kind").unwrap_or_else(|| "mixed".into());
    if name.is_empty() {
        return Err(Reply::err(400, "Category name is required."));
    }
    if !MEDIA_KINDS.contains(&kind.as_str()) {
        return Err(Reply::err(400, "Category type must be image, video, or mixed."));
    }
    let slug = slugify(&name);
    let db = &req.app.db;
    if let Some(existing) = db.opt("SELECT * FROM categories WHERE name=$1 OR slug=$2", &[name.as_str().into(), slug.as_str().into()]).await {
        return Ok(Reply::ok(json!({ "category": existing })));
    }
    let row = db.opt("INSERT INTO categories (name, slug, media_kind, created_by) VALUES ($1, $2, $3, $4) RETURNING *", &[name.into(), slug.into(), kind.into(), uid(&user).into()]).await;
    Ok(Reply::ok(json!({ "category": row })))
}

// ---- tag queries -----------------------------------------------------------------------------------
/// Booru-style tags: "a b" = both, "a OR b" = either, "-a" = not a.
pub fn parse_tag_query(input: &str) -> (Vec<Vec<String>>, Vec<String>) {
    let tokens: Vec<&str> = input.split_whitespace().take(40).collect();
    let (mut groups, mut nots) = (Vec::new(), Vec::new());
    let mut i = 0;
    while i < tokens.len() {
        let t = tokens[i];
        if t.starts_with('-') && t.len() > 1 {
            nots.push(cut(&t[1..].to_lowercase(), 60));
            i += 1;
        } else {
            let mut g = vec![cut(&t.to_lowercase(), 60)];
            i += 1;
            while i + 1 < tokens.len() && tokens[i].to_uppercase() == "OR" {
                g.push(cut(&tokens[i + 1].to_lowercase(), 60));
                i += 2;
            }
            groups.push(g);
        }
    }
    (groups, nots)
}

fn tag_clause(q: &mut Sql, tags: &[String], negate: bool) -> String {
    let arr = tags.iter().map(|t| q.bind(t.as_str())).collect::<Vec<_>>().join(",");
    let test = format!("(m.tags::jsonb ?| ARRAY[{arr}]::text[])");
    if negate { format!("NOT {test}") } else { test }
}

pub fn like_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('%');
    for c in s.chars() {
        if c == '%' || c == '_' {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('%');
    out
}

const VALID_SORTS: &[&str] = &["new", "old", "popular", "views", "downloads", "trending"];

fn order_for(sort: &str) -> &'static str {
    match sort {
        "popular" => "m.pinned_at DESC NULLS LAST, like_count DESC, m.views DESC, m.created_at DESC",
        "downloads" => "m.pinned_at DESC NULLS LAST, m.downloads DESC, m.created_at DESC",
        "views" => "m.pinned_at DESC NULLS LAST, m.views DESC, m.created_at DESC",
        "old" => "m.created_at ASC",
        "trending" => "m.pinned_at DESC NULLS LAST, (m.views + (SELECT COUNT(DISTINCT lk.user_id) FROM media_likes lk WHERE lk.media_id = m.id) * 3) / POWER(EXTRACT(EPOCH FROM (now() - m.created_at)) / 3600 + 2, 1.5) DESC, m.created_at DESC",
        _ => "m.pinned_at DESC NULLS LAST, m.created_at DESC",
    }
}

/// Filters shared by GET /api/media and smart collections.
#[derive(Default, Clone)]
pub struct MediaFilter {
    pub media_kind: Option<String>,
    pub category_id: Option<i64>,
    pub subcategory_id: Option<i64>,
    pub q: String,
    pub uploader: String,
    pub min_size: Option<i64>,
    pub max_size: Option<i64>,
    pub date_from: Option<String>,
    pub date_to: Option<String>,
    pub adult: Option<String>,
    pub tags: Option<String>,
    pub color: Option<String>,
    pub color_tolerance: i64,
    pub sort: String,
}

impl MediaFilter {
    pub fn from_query(req: &Req) -> Self {
        let color = req.q("color").map(|c| c.trim_start_matches('#').to_string()).filter(|c| c.len() == 6 && c.chars().all(|x| x.is_ascii_hexdigit()));
        let sort = req.q("sort").filter(|s| VALID_SORTS.contains(&s.as_str())).unwrap_or_else(|| "new".into());
        MediaFilter {
            media_kind: req.q("media_kind"),
            category_id: req.qi("category_id"),
            subcategory_id: req.qi("subcategory_id"),
            q: cut(req.q("q").unwrap_or_default().trim(), 80),
            uploader: cut(req.q("uploader").unwrap_or_default().trim(), 80),
            min_size: req.qi("min_size"),
            max_size: req.qi("max_size"),
            date_from: req.q("date_from"),
            date_to: req.q("date_to"),
            adult: req.q("adult"),
            tags: req.q("tags"),
            color,
            color_tolerance: req.qi("color_tolerance").unwrap_or(40).clamp(4, 128),
            sort,
        }
    }
}

/// The page query for GET /api/media; returns (rows, effective sort).
pub async fn query_media(req: &Req, viewer: Option<i64>, adult_ok: bool, f: &MediaFilter, limit: i64, offset: i64) -> Result<(Vec<Value>, String), String> {
    let (vid, vtext) = media::viewer_keys(viewer);
    let mut q = Sql::new();
    let vt = q.bind(vtext);
    let vi = q.bind(vid);
    let mut c = vec!["m.deleted_at IS NULL".to_string(), format!("(m.visibility='public' OR m.user_id={vi})"), format!("(m.publish_at IS NULL OR m.publish_at <= now() OR m.user_id={vi})")];
    if viewer.is_some() {
        c.push(format!("m.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id={vi})"));
    }
    if let Some(k) = f.media_kind.as_deref().filter(|k| *k == "image" || *k == "video") {
        c.push(format!("m.media_kind={}", q.bind(k)));
    }
    if let Some(id) = f.category_id {
        c.push(format!("m.category_id={}", q.bind(id)));
    }
    if let Some(id) = f.subcategory_id {
        c.push(format!("EXISTS (SELECT 1 FROM media_item_subcategories ms WHERE ms.media_id=m.id AND ms.subcategory_id={})", q.bind(id)));
    }
    let mut qt = None;
    if !f.q.is_empty() {
        let t = q.bind(f.q.as_str());
        c.push(format!("(m.text_search @@ plainto_tsquery('english', {t}) OR m.tags ILIKE {})", q.bind(like_escape(&f.q))));
        qt = Some(t);
    }
    if !f.uploader.is_empty() {
        let n = q.bind(like_escape(&f.uploader));
        c.push(format!("(u.username ILIKE {n} OR u.display_name ILIKE {n})"));
    }
    if let Some(n) = f.min_size {
        c.push(format!("m.file_size >= {}", q.bind(n.max(0))));
    }
    if let Some(n) = f.max_size {
        c.push(format!("m.file_size <= {}", q.bind(n.max(0))));
    }
    if let Some(d) = &f.date_from {
        c.push(format!("m.created_at::date >= {}::date", q.bind(d.as_str())));
    }
    if let Some(d) = &f.date_to {
        c.push(format!("m.created_at::date <= {}::date", q.bind(d.as_str())));
    }
    if !adult_ok {
        c.push("m.is_adult=false".into());
    } else if f.adult.as_deref() == Some("only") {
        c.push("m.is_adult=true".into());
    } else if f.adult.as_deref() == Some("hide") {
        c.push("m.is_adult=false".into());
    }
    if let Some(t) = &f.tags {
        let (groups, nots) = parse_tag_query(t);
        for g in &groups {
            c.push(tag_clause(&mut q, g, false));
        }
        if !nots.is_empty() {
            c.push(tag_clause(&mut q, &nots, true));
        }
    }
    if let Some(hex) = &f.color {
        let ch = |i: usize| i64::from_str_radix(&hex[i..i + 2], 16).unwrap_or(0);
        let tol = f.color_tolerance;
        let byte = |n: usize| format!("get_byte(decode(substring(m.dominant_color from 2), 'hex'), {n})");
        let (r, g, b, t1, t2, t3) = (q.bind(ch(0)), q.bind(ch(2)), q.bind(ch(4)), q.bind(tol), q.bind(tol), q.bind(tol));
        c.push(format!("m.dominant_color IS NOT NULL AND ABS({} - {r}) <= {t1} AND ABS({} - {g}) <= {t2} AND ABS({} - {b}) <= {t3}", byte(0), byte(1), byte(2)));
    }
    let (mut order, mut sort) = (order_for(&f.sort).to_string(), f.sort.clone());
    if let Some(t) = qt.filter(|_| f.sort.is_empty() || f.sort == "new") {
        order = format!("ts_rank(m.text_search, plainto_tsquery('english', {t})) DESC, m.pinned_at DESC NULLS LAST, m.created_at DESC");
        sort = "relevance".into();
    }
    let (l, o) = (q.bind(limit), q.bind(offset));
    let sql = format!("{} {FROM_JOINS} WHERE {} ORDER BY {order} LIMIT {l} OFFSET {o}", select_cols(&vt), c.join(" AND "));
    let mut rows = req.app.db.query(&sql, &q.params).await?;
    finish_rows(req, &mut rows, adult_ok).await;
    Ok((rows, sort))
}

pub async fn list_media(req: Req) -> R<Reply> {
    let viewer = req.viewer().await;
    let adult_ok = req.app.viewer_adult_allowed(viewer).await;
    let f = MediaFilter::from_query(&req);
    let max = req.app.settings.media_page_limit;
    let limit = bounded_limit(req.qi("limit"), 60, max);
    let offset = bounded_offset(req.qi("offset"));
    let (rows, sort) = query_media(&req, viewer, adult_ok, &f, limit, offset).await.map_err(query_failed)?;
    Ok(Reply::ok(json!({ "media": rows, "limit": limit, "offset": offset, "sort": sort })))
}

// ---- feeds -------------------------------------------------------------------------------------------
pub async fn feed_signal(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = uid(&user);
    let adult_ok = !user["age_verified_at"].is_null() && tobool(user.get("adult_content_consent"));
    let mut c = vec![
        "m.deleted_at IS NULL".to_string(),
        "(m.visibility='public' OR m.user_id=$1)".into(),
        "(m.publish_at IS NULL OR m.publish_at <= now() OR m.user_id=$1)".into(),
        "m.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id=$1)".into(),
    ];
    if !adult_ok {
        c.push("m.is_adult=false".into());
    }
    if req.q("kind").as_deref() == Some("liked") {
        c.push("EXISTS (SELECT 1 FROM media_likes ml WHERE ml.media_id=m.id AND ml.user_id=$1)".into());
    } else {
        c.push("m.user_id IN (SELECT followed_id FROM user_follows WHERE follower_id=$1)".into());
    }
    let sql = format!("SELECT COUNT(*) AS count, MAX(m.created_at) AS latest FROM media_items m WHERE {}", c.join(" AND "));
    let row = req.app.db.one(&sql, &[id.into()]).await.map_err(query_failed)?;
    Ok(Reply::ok(json!({ "count": row.as_ref().and_then(|r| r.i("count")).unwrap_or(0), "latest": row.as_ref().map(|r| r["latest"].clone()) })))
}

const RECENT: &str = "m.pinned_at DESC NULLS LAST, m.created_at DESC";

pub async fn feed_following(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = uid(&user);
    let max = req.app.settings.media_page_limit;
    let (limit, offset) = (bounded_limit(req.qi("limit"), 60, max), bounded_offset(req.qi("offset")));
    let rows = fetch_feed(&req, Some(id), |q| Some(format!("m.user_id IN (SELECT followed_id FROM user_follows WHERE follower_id={})", q.bind(id))), RECENT, limit, offset).await.map_err(query_failed)?;
    Ok(Reply::ok(json!({ "media": rows, "limit": limit, "offset": offset })))
}

pub async fn feed_liked(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = uid(&user);
    let max = req.app.settings.media_page_limit;
    let (limit, offset) = (bounded_limit(req.qi("limit"), 60, max), bounded_offset(req.qi("offset")));
    let rows = fetch_feed(&req, Some(id), |q| Some(format!("EXISTS (SELECT 1 FROM media_likes ml WHERE ml.media_id=m.id AND ml.user_id={})", q.bind(id))), RECENT, limit, offset).await.map_err(query_failed)?;
    Ok(Reply::ok(json!({ "media": rows, "limit": limit, "offset": offset })))
}

pub async fn media_trending(req: Req) -> R<Reply> {
    let viewer = req.viewer().await;
    let days = req.q("days").filter(|d| matches!(d.as_str(), "1" | "7" | "30")).unwrap_or_else(|| "7".into());
    let limit = bounded_limit(req.qi("limit"), 30, req.app.settings.media_page_limit);
    let d = days.clone();
    let rows = fetch_feed(
        &req,
        viewer,
        move |q| Some(format!("m.created_at > now() - ({} || ' days')::interval", q.bind(d))),
        "(m.views + (SELECT COUNT(DISTINCT lk.user_id) FROM media_likes lk WHERE lk.media_id = m.id) * 3 + (SELECT COUNT(*) FROM media_comments cmc WHERE cmc.media_id = m.id) * 2) DESC, m.created_at DESC",
        limit,
        0,
    )
    .await
    .map_err(query_failed)?;
    Ok(Reply::ok(json!({ "media": rows, "days": days.parse::<i64>().unwrap_or(7), "limit": limit })))
}

pub async fn feed_for_you(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = uid(&user);
    let db = &req.app.db;
    let max = req.app.settings.media_page_limit;
    let (limit, offset) = (bounded_limit(req.qi("limit"), 30, max), bounded_offset(req.qi("offset")));
    let followed: Vec<String> = db.all("SELECT followed_id FROM user_follows WHERE follower_id=$1", &[id.into()]).await.iter().filter_map(|r| r.i("followed_id")).map(|i| i.to_string()).collect();
    let followed_csv = if followed.is_empty() { "-1".to_string() } else { followed.join(",") };
    let tags: Vec<String> = db
        .all(
            "SELECT tag, COUNT(*) AS n FROM media_likes ml JOIN media_items m ON m.id = ml.media_id AND m.deleted_at IS NULL \
             CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(m.tags::jsonb, '[]'::jsonb)) AS tag WHERE ml.user_id=$1 GROUP BY tag ORDER BY n DESC LIMIT 8",
            &[id.into()],
        )
        .await
        .iter()
        .filter_map(|r| r.s("tag"))
        .collect();
    let rows = feed_with_order(&req, Some(id), &tags, &followed_csv, limit, offset).await.map_err(query_failed)?;
    Ok(Reply::ok(json!({ "media": rows, "limit": limit, "offset": offset })))
}

/// fetch_media_feed with the for-you ranking (followed creators, liked tags, engagement, age decay).
async fn feed_with_order(req: &Req, viewer: Option<i64>, tags: &[String], followed_csv: &str, limit: i64, offset: i64) -> Result<Vec<Value>, String> {
    let adult_ok = req.app.viewer_adult_allowed(viewer).await;
    let (vid, vtext) = media::viewer_keys(viewer);
    let mut q = Sql::new();
    let vt = q.bind(vtext);
    let vi = q.bind(vid);
    let mut c = vec![
        "m.deleted_at IS NULL".to_string(),
        format!("(m.visibility='public' OR m.user_id={vi})"),
        format!("(m.publish_at IS NULL OR m.publish_at <= now() OR m.user_id={vi})"),
        format!("m.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id={vi})"),
    ];
    if !adult_ok {
        c.push("m.is_adult=false".into());
    }
    let arr = if tags.is_empty() { "ARRAY[]::text[]".to_string() } else { format!("ARRAY[{}]::text[]", tags.iter().map(|t| q.bind(t.as_str())).collect::<Vec<_>>().join(",")) };
    let order = format!(
        "((CASE WHEN m.user_id IN ({followed_csv}) THEN 50 ELSE 0 END) + (CASE WHEN m.tags IS NOT NULL AND m.tags::jsonb ?| {arr} THEN 20 ELSE 0 END) \
         + (m.views * 0.05 + (SELECT COUNT(DISTINCT lk.user_id) FROM media_likes lk WHERE lk.media_id = m.id) * 3 + (SELECT COUNT(*) FROM media_comments cmc WHERE cmc.media_id = m.id) * 2)) \
         / (1 + EXTRACT(EPOCH FROM (now() - m.created_at)) / 86400.0) DESC, m.created_at DESC"
    );
    let (l, o) = (q.bind(limit), q.bind(offset));
    let sql = format!("{} {FROM_JOINS} WHERE {} ORDER BY {order} LIMIT {l} OFFSET {o}", select_cols(&vt), c.join(" AND "));
    let mut rows = req.app.db.query(&sql, &q.params).await?;
    finish_rows(req, &mut rows, adult_ok).await;
    Ok(rows)
}

pub async fn leaderboard(req: Req) -> R<Reply> {
    let window = req.q("window").filter(|w| matches!(w.as_str(), "7d" | "30d" | "all")).unwrap_or_else(|| "30d".into());
    let days = match window.as_str() {
        "7d" => Some("7"),
        "30d" => Some("30"),
        _ => None,
    };
    let (main_w, sub_w) = if days.is_some() { ("AND m.created_at > now() - ($1 || ' days')::interval", "AND lm.created_at > now() - ($1 || ' days')::interval") } else { ("", "") };
    let sql = format!(
        "SELECT u.id, u.username, CASE WHEN u.public_profile THEN u.display_name ELSE u.username END AS display_name, \
           CASE WHEN u.public_profile THEN u.avatar_path ELSE NULL END AS user_avatar_path, u.profile_color, u.public_profile, \
           COALESCE(SUM(m.views), 0)::bigint AS total_views, COUNT(DISTINCT m.id) AS post_count, \
           (SELECT COUNT(*) FROM media_likes l JOIN media_items lm ON lm.id = l.media_id AND lm.deleted_at IS NULL WHERE lm.user_id = u.id {sub_w}) AS total_likes \
         FROM media_items m JOIN users u ON u.id = m.user_id \
         WHERE m.deleted_at IS NULL AND m.visibility='public' AND (m.publish_at IS NULL OR m.publish_at <= now()) {main_w} \
         GROUP BY u.id \
         ORDER BY (COALESCE(SUM(m.views), 0) + (SELECT COUNT(*) FROM media_likes l JOIN media_items lm ON lm.id = l.media_id AND lm.deleted_at IS NULL WHERE lm.user_id = u.id {sub_w}) * 3) DESC \
         LIMIT 25"
    );
    let params: Vec<P> = days.map(|d| vec![P::Text(d.into())]).unwrap_or_default();
    let mut rows = req.app.db.query(&sql, &params).await.map_err(query_failed)?;
    let origin = req.origin();
    for r in &mut rows {
        r["public_profile"] = json!(tobool(r.get("public_profile")));
        if let Some(o) = r.as_object_mut() {
            if o.remove("user_avatar_path").is_some() {
                let id = o.get("id").cloned().unwrap_or(json!(0));
                o.insert("user_avatar_url".into(), json!(format!("{origin}/api/users/{id}/avatar")));
            }
        }
    }
    Ok(Reply::ok(json!({ "window": window, "creators": rows })))
}

// ---- Studio --------------------------------------------------------------------------------------
fn own_adult_ok(user: &Value) -> bool {
    !user["age_verified_at"].is_null() && tobool(user.get("adult_content_consent"))
}

pub async fn my_media(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let include_deleted = !matches!(req.query.get("include_deleted").map(String::as_str), Some("false") | Some("0"));
    let id = uid(&user);
    let filter = if include_deleted { "m.user_id=$2" } else { "m.user_id=$2 AND m.deleted_at IS NULL" };
    let sql = format!("{}, m.deleted_at {FROM_JOINS} WHERE {filter} ORDER BY m.created_at DESC LIMIT 200", select_cols_own("$1"));
    let mut rows = req.app.db.query(&sql, &[id.to_string().into(), id.into()]).await.map_err(query_failed)?;
    finish_rows(&req, &mut rows, own_adult_ok(&user)).await;
    media::ok_media(rows)
}

pub async fn on_this_day(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = uid(&user);
    let sql = format!(
        "{}, EXTRACT(YEAR FROM m.created_at)::int AS years_ago_source {FROM_JOINS} WHERE m.user_id=$2 AND m.deleted_at IS NULL \
         AND EXTRACT(MONTH FROM m.created_at) = EXTRACT(MONTH FROM now()) AND EXTRACT(DAY FROM m.created_at) = EXTRACT(DAY FROM now()) \
         AND EXTRACT(YEAR FROM m.created_at) < EXTRACT(YEAR FROM now()) ORDER BY m.created_at DESC LIMIT 40",
        select_cols_own("$1")
    );
    let mut rows = req.app.db.query(&sql, &[id.to_string().into(), id.into()]).await.map_err(query_failed)?;
    finish_rows(&req, &mut rows, own_adult_ok(&user)).await;
    let this_year: i64 = chrono::Local::now().format("%Y").to_string().parse().unwrap_or(2026);
    for r in &mut rows {
        let src = r.i("years_ago_source").unwrap_or(this_year);
        r["years_ago"] = json!(this_year - src);
        r.as_object_mut().unwrap().remove("years_ago_source");
    }
    media::ok_media(rows)
}

/// Creator analytics (also used by the weekly Discord digest).
pub async fn creator_stats_for(app: &crate::app::App, user_id: i64, origin: &str) -> Result<Value, String> {
    let db = &app.db;
    let mut top = db
        .query(
            "SELECT m.id, m.title, m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.views, m.downloads, m.created_at, m.updated_at, m.visibility, \
               COUNT(DISTINCT l.user_id) AS like_count, COUNT(DISTINCT b.user_id) AS save_count, COUNT(DISTINCT cm.id) AS comment_count \
             FROM media_items m LEFT JOIN media_likes l ON l.media_id = m.id LEFT JOIN media_bookmarks b ON b.media_id = m.id LEFT JOIN media_comments cm ON cm.media_id = m.id \
             WHERE m.user_id = $1 AND m.deleted_at IS NULL GROUP BY m.id ORDER BY m.views DESC, m.created_at DESC LIMIT 20",
            &[user_id.into()],
        )
        .await?;
    for r in &mut top {
        let (id, kind) = (r.i("id").unwrap_or(0), r.s("media_kind").unwrap_or_default());
        if let Some(t) = media::thumb_url_for(origin, id, &kind, &r["updated_at"]) {
            r["thumb_url"] = json!(t);
        }
    }
    let daily = db
        .query(
            "SELECT date_trunc('day', mv.created_at) AS day, COUNT(*) AS new_viewers FROM media_views mv JOIN media_items m ON m.id = mv.media_id \
             WHERE m.user_id = $1 AND mv.created_at > now() - interval '30 days' GROUP BY 1 ORDER BY 1",
            &[user_id.into()],
        )
        .await?;
    let totals = db
        .opt(
            "SELECT COALESCE(SUM(m.views), 0) AS total_views, COUNT(DISTINCT l.user_id || ':' || l.media_id) AS total_likes, COUNT(DISTINCT b.user_id || ':' || b.media_id) AS total_saves \
             FROM media_items m LEFT JOIN media_likes l ON l.media_id = m.id LEFT JOIN media_bookmarks b ON b.media_id = m.id WHERE m.user_id = $1 AND m.deleted_at IS NULL",
            &[user_id.into()],
        )
        .await
        .unwrap_or_else(|| json!({}));
    Ok(json!({
        "top_posts": top,
        "daily_new_viewers": daily,
        "totals": {
            "total_views": totals.i("total_views").unwrap_or(0),
            "total_likes": totals.i("total_likes").unwrap_or(0),
            "total_saves": totals.i("total_saves").unwrap_or(0),
        },
    }))
}

pub async fn creator_stats(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let v = creator_stats_for(&req.app, uid(&user), &req.origin()).await.map_err(query_failed)?;
    Ok(Reply::ok(v))
}

pub async fn year_recap(req: Req) -> R<Reply> {
    let user = req.current_user().await?;
    let id = uid(&user);
    let current: i64 = chrono::Utc::now().format("%Y").to_string().parse().unwrap_or(2026);
    let year = req.qi("year").unwrap_or(current);
    if year < 2020 || year > current {
        return Err(Reply::err(400, "Invalid year."));
    }
    let db = &req.app.db;
    let yp = || -> P { P::Int(year) };
    if let Some(c) = db.opt("SELECT payload, computed_at, (now() - computed_at < interval '1 hour') AS fresh FROM user_year_recap_cache WHERE user_id=$1 AND year=$2", &[id.into(), yp()]).await {
        if year < current || tobool(c.get("fresh")) {
            if let Some(p) = c.s("payload").and_then(|p| serde_json::from_str::<Value>(&p).ok()) {
                return Ok(Reply::ok(p));
            }
        }
    }
    let origin = req.origin();
    let totals = db
        .opt(
            "SELECT COUNT(*) AS post_count, COALESCE(SUM(m.views), 0) AS total_views, COUNT(DISTINCT l.user_id || ':' || l.media_id) AS total_likes_received, COUNT(DISTINCT cm.id) AS total_comments_received \
             FROM media_items m LEFT JOIN media_likes l ON l.media_id = m.id LEFT JOIN media_comments cm ON cm.media_id = m.id \
             WHERE m.user_id=$1 AND m.deleted_at IS NULL AND EXTRACT(YEAR FROM m.created_at) = $2",
            &[id.into(), yp()],
        )
        .await
        .unwrap_or_else(|| json!({}));
    let top = db
        .opt(
            "SELECT m.id, m.title, m.media_kind, m.views, m.updated_at, COUNT(DISTINCT l.user_id) AS like_count FROM media_items m LEFT JOIN media_likes l ON l.media_id = m.id \
             WHERE m.user_id=$1 AND m.deleted_at IS NULL AND EXTRACT(YEAR FROM m.created_at) = $2 GROUP BY m.id ORDER BY like_count DESC, m.views DESC LIMIT 1",
            &[id.into(), yp()],
        )
        .await;
    let top_tag = db
        .opt(
            "SELECT tag, COUNT(*) AS n FROM media_items m CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(m.tags::jsonb, '[]'::jsonb)) AS tag \
             WHERE m.user_id=$1 AND m.deleted_at IS NULL AND EXTRACT(YEAR FROM m.created_at) = $2 GROUP BY tag ORDER BY n DESC LIMIT 1",
            &[id.into(), yp()],
        )
        .await
        .map(|r| r["tag"].clone())
        .unwrap_or(Value::Null);
    let likes_given = db
        .opt("SELECT COUNT(*) AS n FROM media_likes l JOIN media_items m ON m.id = l.media_id WHERE l.user_id=$1 AND EXTRACT(YEAR FROM l.created_at) = $2", &[id.into(), yp()])
        .await
        .and_then(|r| r.i("n"))
        .unwrap_or(0);
    let joined = db.opt("SELECT created_at FROM users WHERE id=$1", &[id.into()]).await.map(|r| r["created_at"].clone()).unwrap_or(Value::Null);
    let top_post = top.map(|t| {
        let tid = t.i("id").unwrap_or(0);
        let mut o = json!({ "id": tid, "title": t["title"], "views": t.i("views").unwrap_or(0), "like_count": t.i("like_count").unwrap_or(0) });
        if let Some(u) = media::thumb_url_for(&origin, tid, &t.s("media_kind").unwrap_or_default(), &t["updated_at"]) {
            o["thumb_url"] = json!(u);
        }
        o
    });
    let payload = json!({
        "year": year,
        "post_count": totals.i("post_count").unwrap_or(0),
        "total_views": totals.i("total_views").unwrap_or(0),
        "total_likes_received": totals.i("total_likes_received").unwrap_or(0),
        "total_comments_received": totals.i("total_comments_received").unwrap_or(0),
        "likes_given": likes_given,
        "top_tag": top_tag,
        "member_since": joined,
        "top_post": top_post,
    });
    let _ = db
        .exec(
            "INSERT INTO user_year_recap_cache (user_id, year, payload, computed_at) VALUES ($1, $2, $3, now()) ON CONFLICT (user_id, year) DO UPDATE SET payload=EXCLUDED.payload, computed_at=now()",
            &[id.into(), yp(), payload.to_string().into()],
        )
        .await;
    Ok(Reply::ok(payload))
}
