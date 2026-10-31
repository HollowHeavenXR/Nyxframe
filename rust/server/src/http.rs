//! Request/response plumbing (port of httpd.lua's contract). `Req` carries
//! what the Lua handlers got: query, path params, headers, cookies, JSON
//! body, multipart form/files and the client IP. `Reply` is (status, body,
//! headers). CORS, security headers and request stats run as middleware.

use crate::app::{App, AppRef};
use axum::body::{Body, Bytes};
use axum::extract::{ConnectInfo, FromRequest, MatchedPath, RawPathParams, Request};
use axum::http::{HeaderMap, HeaderValue, Method, StatusCode, header};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::time::Instant;

/// Largest non-streaming request body (upload chunks, avatars, JSON).
pub const MAX_BODY: usize = 96 * 1024 * 1024;

pub struct FilePart {
    pub name: String,
    pub filename: String,
    pub content_type: String,
    pub data: Bytes,
}

pub struct Req {
    pub app: AppRef,
    pub method: Method,
    pub path: String,
    pub query: HashMap<String, String>,
    pub params: HashMap<String, String>,
    pub headers: HeaderMap,
    pub cookies: HashMap<String, String>,
    pub raw_body: Bytes,
    pub json: Value,
    pub form: HashMap<String, String>,
    pub files: Vec<FilePart>,
    pub client_ip: String,
}

pub fn url_decode(s: &str) -> String {
    urlencoding::decode(&s.replace('+', " ")).map(|c| c.into_owned()).unwrap_or_else(|_| s.to_string())
}

pub fn parse_query(qs: &str) -> HashMap<String, String> {
    qs.split('&')
        .filter(|p| !p.is_empty())
        .filter_map(|p| {
            let (k, v) = p.split_once('=').unwrap_or((p, ""));
            (!k.is_empty()).then(|| (url_decode(k), url_decode(v)))
        })
        .collect()
}

/// Lua's `([%w_%-]+)=([^;]+)` cookie scan (values are not URL-decoded).
fn parse_cookies(h: Option<&str>) -> HashMap<String, String> {
    h.map(|h| {
        h.split(';')
            .filter_map(|p| p.trim().split_once('=').map(|(k, v)| (k.trim().to_string(), v.trim().to_string())))
            .filter(|(k, _)| !k.is_empty() && k.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-'))
            .collect()
    })
    .unwrap_or_default()
}

fn ip_in_cidr(ip: &IpAddr, cidr: &str) -> bool {
    let Some((net, bits)) = cidr.split_once('/') else { return cidr.parse::<IpAddr>().ok().as_ref() == Some(ip) };
    let (Ok(net), Ok(bits)) = (net.parse::<IpAddr>(), bits.parse::<u32>()) else { return false };
    match (ip, net) {
        (IpAddr::V4(a), IpAddr::V4(n)) => {
            if bits == 0 {
                return true;
            }
            let mask = u32::MAX.checked_shl(32 - bits.min(32)).unwrap_or(0);
            (u32::from(*a) & mask) == (u32::from(n) & mask)
        }
        (IpAddr::V6(a), IpAddr::V6(n)) => {
            if bits == 0 {
                return true;
            }
            let mask = u128::MAX.checked_shl(128 - bits.min(128)).unwrap_or(0);
            (u128::from(*a) & mask) == (u128::from(n) & mask)
        }
        _ => false,
    }
}

/// X-Forwarded-For is honored only from a trusted proxy peer.
pub fn client_ip(app: &App, headers: &HeaderMap, peer: Option<SocketAddr>) -> String {
    let Some(peer) = peer else { return "unknown".into() };
    let ip = peer.ip().to_canonical();
    if app.settings.trusted_proxy_cidrs.iter().any(|c| ip_in_cidr(&ip, c)) {
        if let Some(x) = headers.get("x-forwarded-for").and_then(|v| v.to_str().ok()).and_then(|v| v.split(',').next()).map(str::trim).filter(|v| !v.is_empty()) {
            return x.to_string();
        }
    }
    ip.to_string()
}

/// Minimal multipart/form-data parser (same shape as httpd.lua's).
pub fn parse_multipart(body: &Bytes, boundary: &str) -> (HashMap<String, String>, Vec<FilePart>) {
    let mut form = HashMap::new();
    let mut files = Vec::new();
    let delim = format!("--{boundary}");
    let d = delim.as_bytes();
    let find = |hay: &[u8], needle: &[u8], from: usize| -> Option<usize> {
        if needle.is_empty() || from >= hay.len() {
            return None;
        }
        hay[from..].windows(needle.len()).position(|w| w == needle).map(|p| p + from)
    };
    let mut pos = match find(body, d, 0) {
        Some(p) => p + d.len(),
        None => return (form, files),
    };
    loop {
        if body.get(pos..pos + 2) == Some(b"--") {
            break;
        }
        if body.get(pos..pos + 2) == Some(b"\r\n") {
            pos += 2;
        }
        let Some(next) = find(body, d, pos) else { break };
        let part_end = if next >= 2 && &body[next - 2..next] == b"\r\n" { next - 2 } else { next };
        if let Some(h_end) = find(&body[..part_end], b"\r\n\r\n", pos) {
            let head = String::from_utf8_lossy(&body[pos..h_end]).to_string();
            let attr = |name: &str| -> Option<String> {
                let key = format!("{name}=\"");
                let i = head.find(&key)? + key.len();
                let j = head[i..].find('"')?;
                Some(head[i..i + j].to_string())
            };
            let ctype = head
                .lines()
                .find(|l| l.to_ascii_lowercase().starts_with("content-type:"))
                .map(|l| l[13..].trim().to_string())
                .unwrap_or_default();
            if let Some(name) = attr("name") {
                let data = body.slice(h_end + 4..part_end);
                match attr("filename") {
                    Some(filename) => files.push(FilePart { name, filename, content_type: if ctype.is_empty() { "application/octet-stream".into() } else { ctype }, data }),
                    None => {
                        form.insert(name, String::from_utf8_lossy(&data).to_string());
                    }
                }
            }
        }
        pos = next + d.len();
    }
    (form, files)
}

pub fn boundary_of(ctype: &str) -> Option<String> {
    let i = ctype.find("boundary=")? + 9;
    let b = ctype[i..].split(';').next()?.trim().trim_matches('"');
    (!b.is_empty()).then(|| b.to_string())
}

impl<S: Send + Sync> FromRequest<S> for Req {
    type Rejection = Response;
    async fn from_request(req: Request, state: &S) -> Result<Self, Self::Rejection> {
        let (mut parts, body) = req.into_parts();
        let app = parts.extensions.get::<AppRef>().cloned().expect("app extension");
        let params: HashMap<String, String> = match <RawPathParams as axum::extract::FromRequestParts<S>>::from_request_parts(&mut parts, state).await {
            Ok(p) => p.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
            Err(_) => HashMap::new(),
        };
        let peer = parts.extensions.get::<ConnectInfo<SocketAddr>>().map(|c| c.0);
        let raw_body = axum::body::to_bytes(body, MAX_BODY).await.map_err(|_| Reply::err(413, "Request body too large").into_response())?;
        let ctype = parts.headers.get(header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
        let mut json = json!({});
        let (mut form, mut files) = (HashMap::new(), Vec::new());
        if !raw_body.is_empty() {
            if ctype.contains("application/json") {
                json = serde_json::from_slice(&raw_body).unwrap_or_else(|_| json!({}));
            } else if ctype.contains("multipart/form-data") {
                if let Some(b) = boundary_of(&ctype) {
                    (form, files) = parse_multipart(&raw_body, &b);
                }
            }
        }
        Ok(Req {
            client_ip: client_ip(&app, &parts.headers, peer),
            cookies: parse_cookies(parts.headers.get(header::COOKIE).and_then(|v| v.to_str().ok())),
            query: parse_query(parts.uri.query().unwrap_or("")),
            path: parts.uri.path().to_string(),
            method: parts.method,
            headers: parts.headers,
            params,
            raw_body,
            json,
            form,
            files,
            app,
        })
    }
}

impl Req {
    /// A Req for a streaming handler: everything but the body, which is returned as-is.
    pub async fn split(req: Request) -> (Req, Body) {
        let (mut parts, body) = req.into_parts();
        let app = parts.extensions.get::<AppRef>().cloned().expect("app extension");
        let params: HashMap<String, String> = match <RawPathParams as axum::extract::FromRequestParts<()>>::from_request_parts(&mut parts, &()).await {
            Ok(p) => p.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
            Err(_) => HashMap::new(),
        };
        let peer = parts.extensions.get::<ConnectInfo<SocketAddr>>().map(|c| c.0);
        let r = Req {
            client_ip: client_ip(&app, &parts.headers, peer),
            cookies: parse_cookies(parts.headers.get(header::COOKIE).and_then(|v| v.to_str().ok())),
            query: parse_query(parts.uri.query().unwrap_or("")),
            path: parts.uri.path().to_string(),
            method: parts.method,
            headers: parts.headers,
            params,
            raw_body: Bytes::new(),
            json: json!({}),
            form: HashMap::new(),
            files: Vec::new(),
            app,
        };
        (r, body)
    }

    pub fn header(&self, k: &str) -> Option<&str> {
        self.headers.get(k).and_then(|v| v.to_str().ok())
    }
    pub fn q(&self, k: &str) -> Option<String> {
        self.query.get(k).cloned().filter(|v| !v.is_empty())
    }
    pub fn qi(&self, k: &str) -> Option<i64> {
        self.query.get(k).and_then(|v| v.trim().parse::<f64>().ok()).map(|f| f.floor() as i64)
    }
    pub fn p(&self, k: &str) -> String {
        self.params.get(k).cloned().unwrap_or_default()
    }
    /// Path param as a number (Lua's tonumber(req.params.x)).
    pub fn pi(&self, k: &str) -> Option<i64> {
        self.params.get(k).and_then(|v| v.trim().parse::<f64>().ok()).filter(|f| f.is_finite()).map(|f| f.floor() as i64)
    }
    /// Body field as a string (numbers stringified), None for null/missing.
    pub fn js(&self, k: &str) -> Option<String> {
        match self.json.get(k)? {
            Value::Null => None,
            Value::String(s) => Some(s.clone()),
            other => Some(other.to_string()),
        }
    }
    pub fn jb(&self, k: &str) -> bool {
        self.json.get(k) == Some(&Value::Bool(true))
    }
    pub fn ji(&self, k: &str) -> Option<i64> {
        match self.json.get(k)? {
            Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f.floor() as i64)),
            Value::String(s) => s.trim().parse::<f64>().ok().map(|f| f.floor() as i64),
            _ => None,
        }
    }
    /// A body field that is present and not null.
    pub fn has(&self, k: &str) -> bool {
        self.json.get(k).is_some_and(|v| !v.is_null())
    }
    /// Form-encoded body (server-rendered <form method=post>).
    pub fn urlform(&self) -> HashMap<String, String> {
        parse_query(&String::from_utf8_lossy(&self.raw_body))
    }
    pub fn file(&self, name: &str) -> Option<&FilePart> {
        self.files.iter().find(|f| f.name == name)
    }
}

// ---- replies -------------------------------------------------------------------------------
pub enum Payload {
    Json(Value),
    Html(String),
    Bytes(Vec<u8>, String),
    Stream(Body, String),
    Empty,
}

pub struct Reply {
    pub status: u16,
    pub payload: Payload,
    pub headers: Vec<(String, String)>,
}

impl Reply {
    pub fn json(status: u16, v: Value) -> Self {
        Self { status, payload: Payload::Json(v), headers: Vec::new() }
    }
    pub fn ok(v: Value) -> Self {
        Self::json(200, v)
    }
    pub fn err(status: u16, detail: impl Into<String>) -> Self {
        Self::json(status, json!({ "detail": detail.into() }))
    }
    pub fn html(body: String) -> Self {
        Self { status: 200, payload: Payload::Html(body), headers: Vec::new() }
    }
    pub fn bytes(status: u16, body: Vec<u8>, ctype: &str) -> Self {
        Self { status, payload: Payload::Bytes(body, ctype.to_string()), headers: Vec::new() }
    }
    pub fn text(status: u16, body: impl Into<String>, ctype: &str) -> Self {
        Self::bytes(status, body.into().into_bytes(), ctype)
    }
    pub fn stream(status: u16, body: Body, ctype: &str) -> Self {
        Self { status, payload: Payload::Stream(body, ctype.to_string()), headers: Vec::new() }
    }
    pub fn redirect(to: &str) -> Self {
        Self { status: 303, payload: Payload::Empty, headers: vec![("Location".into(), to.into())] }
    }
    pub fn header(mut self, k: &str, v: impl Into<String>) -> Self {
        self.headers.push((k.to_string(), v.into()));
        self
    }
    pub fn cookie(self, v: String) -> Self {
        self.header("Set-Cookie", v)
    }
    pub fn status(mut self, s: u16) -> Self {
        self.status = s;
        self
    }
}

#[derive(Clone)]
struct ErrDetail(String);

impl IntoResponse for Reply {
    fn into_response(self) -> Response {
        let mut detail = None;
        let (body, ctype) = match self.payload {
            Payload::Json(v) => {
                let s = v.to_string();
                if self.status >= 400 {
                    detail = Some(crate::util::cut(&s, 500));
                }
                (Body::from(s), "application/json".to_string())
            }
            Payload::Html(h) => (Body::from(h), "text/html; charset=utf-8".to_string()),
            Payload::Bytes(b, c) => (Body::from(b), c),
            Payload::Stream(b, c) => (b, c),
            Payload::Empty => (Body::empty(), "application/json".to_string()),
        };
        let mut r = Response::new(body);
        *r.status_mut() = StatusCode::from_u16(self.status).unwrap_or(StatusCode::OK);
        r.headers_mut().insert(header::CONTENT_TYPE, HeaderValue::from_str(&ctype).unwrap_or(HeaderValue::from_static("application/octet-stream")));
        for (k, v) in self.headers {
            if let (Ok(k), Ok(v)) = (header::HeaderName::from_bytes(k.as_bytes()), HeaderValue::from_str(&v)) {
                if k == header::CONTENT_TYPE {
                    r.headers_mut().insert(k, v);
                } else {
                    r.headers_mut().append(k, v);
                }
            }
        }
        if let Some(d) = detail {
            r.extensions_mut().insert(ErrDetail(d));
        }
        r
    }
}

/// `?`-style early return for handlers: Err carries the Reply.
pub type R<T> = Result<T, Reply>;

// ---- middleware --------------------------------------------------------------------------------
fn origin_allowed(app: &App, origin: &str) -> bool {
    !origin.is_empty() && (app.cors_origins.iter().any(|o| o == origin) || app.tunnel_origin.as_ref().is_some_and(|r| r.is_match(origin)))
}


/// axum's "{param}" route syntax back to httpd.lua's ":param" (stats keys).
fn lua_pattern(p: &str) -> String {
    let mut out = String::with_capacity(p.len());
    let mut in_param = false;
    for c in p.chars() {
        match c {
            '{' => {
                in_param = true;
                out.push(':');
            }
            '}' if in_param => in_param = false,
            c => out.push(c),
        }
    }
    out
}

pub async fn middleware(axum::extract::State(app): axum::extract::State<AppRef>, mut req: Request, next: Next) -> Response {
    let start = Instant::now();
    app.count_request();
    req.extensions_mut().insert(app.clone());
    let origin = req.headers().get(header::ORIGIN).and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
    let method = req.method().clone();
    let path = req.uri().path().to_string();
    let is_ws = req.headers().get(header::UPGRADE).is_some_and(|v| v.as_bytes().eq_ignore_ascii_case(b"websocket"));

    let mut resp = if method == Method::OPTIONS { Response::builder().status(204).body(Body::empty()).unwrap() } else { next.run(req).await };
    let h = resp.headers_mut();
    h.insert("Strict-Transport-Security", HeaderValue::from_static("max-age=31536000; includeSubDomains; preload"));
    h.insert("X-Content-Type-Options", HeaderValue::from_static("nosniff"));
    if !h.contains_key("X-Frame-Options") {
        h.insert("X-Frame-Options", HeaderValue::from_static("DENY"));
    }
    h.insert("Referrer-Policy", HeaderValue::from_static("strict-origin-when-cross-origin"));
    if origin_allowed(&app, &origin) {
        h.insert("Access-Control-Allow-Origin", HeaderValue::from_str(&origin).unwrap_or(HeaderValue::from_static("null")));
        h.insert("Access-Control-Allow-Credentials", HeaderValue::from_static("true"));
        h.insert(header::VARY, HeaderValue::from_static("Origin"));
    }
    h.insert("Access-Control-Allow-Methods", HeaderValue::from_static("GET, POST, PUT, PATCH, DELETE, OPTIONS"));
    h.insert("Access-Control-Allow-Headers", HeaderValue::from_static("Authorization, Content-Type"));
    h.insert(header::SERVER, HeaderValue::from_static("Nyxframe-Rust"));
    if method == Method::OPTIONS || is_ws {
        return resp;
    }
    let status = resp.status().as_u16();
    if let Some(ErrDetail(d)) = resp.extensions().get::<ErrDetail>() {
        println!("[error-detail] {method} {path} -> {status}: {d}");
    }
    let pattern = resp.extensions().get::<Pattern>().map(|p| lua_pattern(&p.0)).unwrap_or(path);
    app.telemetry.record_request(method.as_str(), &pattern, status, start.elapsed().as_secs_f64() * 1000.0);
    resp
}

#[derive(Clone)]
pub struct Pattern(pub String);

/// route_layer: runs after routing, so the matched pattern is known.
pub async fn tag_pattern(req: Request, next: Next) -> Response {
    let pat = req.extensions().get::<MatchedPath>().map(|m| m.as_str().to_string());
    let mut resp = next.run(req).await;
    if let Some(p) = pat {
        resp.extensions_mut().insert(Pattern(p));
    }
    resp
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn multipart() {
        let body = Bytes::from_static(b"--XX\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nHello\r\n--XX\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.png\"\r\nContent-Type: image/png\r\n\r\n\x89PNG\r\n--XX--\r\n");
        let (f, files) = parse_multipart(&body, "XX");
        assert_eq!(f["title"], "Hello");
        assert_eq!(files[0].filename, "a.png");
        assert_eq!(&files[0].data[..], b"\x89PNG");
    }
    #[test]
    fn cidr() {
        let ip: IpAddr = "172.18.0.5".parse().unwrap();
        assert!(ip_in_cidr(&ip, "172.16.0.0/12"));
        assert!(!ip_in_cidr(&ip, "10.0.0.0/8"));
        assert!(ip_in_cidr(&"::1".parse().unwrap(), "::1/128"));
    }
    #[test]
    fn pattern() {
        assert_eq!(lua_pattern("/api/media/{media_id}/hls/{quality}/{segment}"), "/api/media/:media_id/hls/:quality/:segment");
    }
}
