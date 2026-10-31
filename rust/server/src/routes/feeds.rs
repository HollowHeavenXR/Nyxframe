//! RSS feeds, sitemap and the Open Graph preview crawlers get for /media/:id.

use crate::db::{J, P};
use crate::http::{R, Reply, Req};
use crate::util::{cut, esc, tobool};
use serde_json::Value;

const SELECT: &str = "SELECT m.id, m.title, m.description, m.created_at, to_char(m.created_at, 'Dy, DD Mon YYYY HH24:MI:SS') AS pub_date FROM media_items m";
const PUBLIC: &str = "m.deleted_at IS NULL AND m.visibility='public' AND m.is_adult=false AND (m.publish_at IS NULL OR m.publish_at <= now())";

fn item(origin: &str, r: &Value) -> String {
    let id = r.i("id").unwrap_or(0);
    let link = format!("{origin}/media/{id}");
    let thumb = format!("{origin}/api/media/{id}/thumb?w=800");
    format!(
        "  <item>\n    <title>{}</title>\n    <link>{}</link>\n    <guid isPermaLink=\"true\">{}</guid>\n    <pubDate>{}</pubDate>\n    <description>{}</description>\n    <enclosure url=\"{}\" type=\"image/webp\" />\n  </item>",
        esc(&r.s("title").unwrap_or_else(|| format!("Post #{id}"))),
        esc(&link),
        esc(&link),
        esc(&format!("{} +0000", r.s("pub_date").unwrap_or_default())),
        esc(&r.s("description").unwrap_or_default()),
        esc(&thumb)
    )
}

fn feed(origin: &str, title: &str, desc: &str, path: &str, rows: &[Value]) -> Reply {
    let items = rows.iter().map(|r| item(origin, r)).collect::<Vec<_>>().join("\n");
    let xml = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rss version=\"2.0\">\n<channel>\n  <title>{}</title>\n  <link>{}</link>\n  <atom:link href=\"{}{}\" rel=\"self\" type=\"application/rss+xml\" xmlns:atom=\"http://www.w3.org/2005/Atom\" />\n  <description>{}</description>\n{items}\n</channel>\n</rss>",
        esc(title), esc(origin), esc(origin), esc(path), esc(desc)
    );
    Reply::text(200, xml, "application/rss+xml; charset=utf-8")
}

fn not_found(msg: &str) -> Reply {
    Reply::text(404, msg, "text/plain")
}

fn strip_xml(s: &str) -> String {
    crate::http::url_decode(s.strip_suffix(".xml").unwrap_or(s))
}

pub async fn site(req: Req) -> R<Reply> {
    let rows = req.app.db.all(&format!("{SELECT} WHERE {PUBLIC} ORDER BY m.created_at DESC LIMIT 50"), &[]).await;
    Ok(feed(&req.origin(), "Nyxframe", "Recent public uploads", "/feed.xml", &rows))
}

pub async fn category(req: Req) -> R<Reply> {
    let slug = strip_xml(&req.p("file"));
    let Some(c) = req.app.db.opt("SELECT id, name FROM categories WHERE slug=$1", &[slug.as_str().into()]).await else { return Err(not_found("Category not found.")) };
    let name = c.s("name").unwrap_or_default();
    let rows = req.app.db.all(&format!("{SELECT} WHERE {PUBLIC} AND m.category_id=$1 ORDER BY m.created_at DESC LIMIT 50"), &[c.i("id").unwrap_or(0).into()]).await;
    Ok(feed(&req.origin(), &format!("Nyxframe: {name}"), &format!("Recent public uploads in {name}"), &format!("/feed/category/{slug}.xml"), &rows))
}

pub async fn user(req: Req) -> R<Reply> {
    let name = strip_xml(&req.p("file"));
    let u = req.app.db.opt("SELECT id, username, public_profile FROM users WHERE username=$1", &[name.as_str().into()]).await.filter(|u| tobool(u.get("public_profile")));
    let Some(u) = u else { return Err(not_found("User not found.")) };
    let un = u.s("username").unwrap_or_default();
    let rows = req.app.db.all(&format!("{SELECT} WHERE {PUBLIC} AND m.user_id=$1 ORDER BY m.created_at DESC LIMIT 50"), &[u.i("id").unwrap_or(0).into()]).await;
    Ok(feed(&req.origin(), &format!("Nyxframe: @{un}"), &format!("Recent public uploads by @{un}"), &format!("/feed/user/{name}.xml"), &rows))
}

pub async fn tag(req: Req) -> R<Reply> {
    let tag = cut(&strip_xml(&req.p("file")).to_lowercase(), 60);
    let rows = req.app.db.all(&format!("{SELECT} WHERE {PUBLIC} AND (m.tags::jsonb ? $1) ORDER BY m.created_at DESC LIMIT 50"), &[tag.as_str().into()]).await;
    Ok(feed(&req.origin(), &format!("Nyxframe: \"{tag}\""), &format!("Recent public uploads tagged {tag}"), &format!("/feed/tag/{tag}.xml"), &rows))
}

pub async fn personal(req: Req) -> R<Reply> {
    let uid = match req.q("key") {
        Some(k) => req.app.resolve_api_key(&k).await,
        None => None,
    };
    let Some(uid) = uid else { return Err(Reply::text(401, "Invalid or revoked API key.", "text/plain")) };
    let rows = req.app.db.all(&format!("{SELECT} WHERE m.user_id=$1 AND m.deleted_at IS NULL ORDER BY m.created_at DESC LIMIT 100"), &[P::Int(uid)]).await;
    Ok(feed(&req.origin(), "My Nyxframe uploads", "All of your uploads, any visibility", "/feed/me.xml", &rows))
}

pub async fn sitemap(req: Req) -> R<Reply> {
    let origin = req.origin();
    let rows = req
        .app
        .db
        .all("SELECT id, updated_at FROM media_items WHERE deleted_at IS NULL AND visibility='public' AND is_adult=false AND (publish_at IS NULL OR publish_at <= now()) ORDER BY created_at DESC LIMIT 5000", &[])
        .await;
    let mut urls = vec![format!("  <url><loc>{}/</loc></url>", esc(&origin))];
    for r in rows {
        urls.push(format!("  <url><loc>{}/media/{}</loc><lastmod>{}</lastmod></url>", esc(&origin), r.i("id").unwrap_or(0), esc(&cut(&r.s("updated_at").unwrap_or_default(), 10))));
    }
    let xml = format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n{}\n</urlset>", urls.join("\n"));
    Ok(Reply::text(200, xml, "application/xml; charset=utf-8"))
}

const CRAWLERS: &[&str] = &["discordbot", "twitterbot", "facebookexternalhit", "slackbot", "telegrambot", "whatsapp", "linkedinbot", "pinterestbot", "redditbot", "skypeuripreview", "vkshare", "embedly", "googlebot", "bingbot"];

pub fn is_crawler(ua: Option<&str>) -> bool {
    let ua = ua.unwrap_or("").to_lowercase();
    !ua.is_empty() && CRAWLERS.iter().any(|c| ua.contains(c))
}

/// Link-preview HTML for a public, non-adult post (None otherwise).
pub async fn media_preview(req: &Req, id: i64) -> Option<String> {
    let r = req.app.db.opt("SELECT m.id, m.title, m.description, m.is_adult, m.visibility, m.deleted_at, m.media_kind, u.username FROM media_items m JOIN users u ON u.id = m.user_id WHERE m.id=$1", &[id.into()]).await?;
    if !r["deleted_at"].is_null() || r.s("visibility").as_deref() != Some("public") || tobool(r.get("is_adult")) {
        return None;
    }
    let origin = req.origin();
    let user = r.s("username").unwrap_or_default();
    let title = esc(&r.s("title").filter(|t| !t.is_empty()).unwrap_or_else(|| format!("Post by @{user}")));
    let desc = esc(&r.s("description").filter(|d| !d.is_empty()).unwrap_or_else(|| format!("Shared by @{user} on Nyxframe")));
    let thumb = esc(&format!("{origin}/api/media/{id}/thumb?w=1200"));
    let url = esc(&format!("{origin}/media/{id}"));
    Some(format!(
        "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>{title}</title>\n<meta property=\"og:type\" content=\"website\">\n<meta property=\"og:site_name\" content=\"Nyxframe\">\n\
         <meta property=\"og:title\" content=\"{title}\">\n<meta property=\"og:description\" content=\"{desc}\">\n<meta property=\"og:image\" content=\"{thumb}\">\n<meta property=\"og:url\" content=\"{url}\">\n\
         <meta name=\"twitter:card\" content=\"summary_large_image\">\n<meta name=\"twitter:title\" content=\"{title}\">\n<meta name=\"twitter:description\" content=\"{desc}\">\n<meta name=\"twitter:image\" content=\"{thumb}\">\n\
         <link rel=\"canonical\" href=\"{url}\">\n</head>\n<body><p><a href=\"{url}\">{title}</a></p></body>\n</html>"
    ))
}
