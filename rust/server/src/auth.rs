//! Password hashing + stateless session tokens (port of auth.lua).
//! Token = base64url(json) "." base64url(HMAC-SHA256(secret, base64url(json))),
//! byte-compatible with the Lua build so existing sessions keep working.

use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use hmac::{Hmac, Mac};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

type HmacSha256 = Hmac<Sha256>;
pub const PBKDF2_ITERATIONS: u32 = 260_000;

pub fn sha256_hex(s: &str) -> String {
    hex::encode(Sha256::digest(s.as_bytes()))
}

pub fn verification_code() -> String {
    format!("{:08}", rand::random_range(0..100_000_000u32))
}

fn hmac(key: &[u8], msg: &[u8]) -> Vec<u8> {
    let mut m = HmacSha256::new_from_slice(key).expect("hmac key");
    m.update(msg);
    m.finalize().into_bytes().to_vec()
}

fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

pub fn password_hash(password: &str) -> String {
    let salt: [u8; 16] = rand::random();
    let mut dk = [0u8; 32];
    pbkdf2::pbkdf2_hmac::<Sha256>(password.as_bytes(), &salt, PBKDF2_ITERATIONS, &mut dk);
    format!("pbkdf2_sha256${PBKDF2_ITERATIONS}${}${}", STANDARD.encode(salt), STANDARD.encode(dk))
}

pub fn verify_password_hash(password: &str, stored: &str) -> bool {
    let parts: Vec<&str> = stored.split('$').collect();
    if parts.len() != 4 || parts[0] != "pbkdf2_sha256" {
        return false;
    }
    let (Ok(iter), Ok(salt), Ok(expected)) = (parts[1].parse::<u32>(), STANDARD.decode(parts[2]), STANDARD.decode(parts[3])) else { return false };
    if expected.is_empty() || iter == 0 {
        return false;
    }
    let mut dk = vec![0u8; expected.len()];
    pbkdf2::pbkdf2_hmac::<Sha256>(password.as_bytes(), &salt, iter, &mut dk);
    ct_eq(&dk, &expected)
}

/// CPU-heavy (260k rounds): run off the async threads.
pub async fn verify_password_async(password: String, stored: String) -> bool {
    tokio::task::spawn_blocking(move || verify_password_hash(&password, &stored)).await.unwrap_or(false)
}
pub async fn password_hash_async(password: String) -> String {
    tokio::task::spawn_blocking(move || password_hash(&password)).await.unwrap_or_default()
}

pub fn hmac_hex(key: &str, msg: &str) -> String {
    hex::encode(hmac(key.as_bytes(), msg.as_bytes()))
}

/// Hex HMAC of the media id: the `?access=` capability for <img>/<video> tags.
pub fn media_access_token(secret: &str, media_id: i64) -> String {
    hmac_hex(secret, &media_id.to_string())
}

pub fn issue_token(secret: &str, mut payload: Value, ttl: i64) -> String {
    payload["exp"] = json!(crate::util::now() + ttl);
    let part = URL_SAFE_NO_PAD.encode(payload.to_string());
    let sig = URL_SAFE_NO_PAD.encode(hmac(secret.as_bytes(), part.as_bytes()));
    format!("{part}.{sig}")
}

/// Decoded payload, or None if missing/invalid/expired.
pub fn verify_token(secret: &str, token: &str) -> Option<Value> {
    let (part, sig) = token.split_once('.')?;
    if part.is_empty() || sig.is_empty() || sig.contains('.') {
        return None;
    }
    let expected = hmac(secret.as_bytes(), part.as_bytes());
    let given = URL_SAFE_NO_PAD.decode(sig.trim_end_matches('=')).ok()?;
    if !ct_eq(&expected, &given) {
        return None;
    }
    let raw = URL_SAFE_NO_PAD.decode(part.trim_end_matches('=')).ok()?;
    let v: Value = serde_json::from_slice(&raw).ok()?;
    if !v.is_object() {
        return None;
    }
    if v.get("exp").and_then(Value::as_f64).is_some_and(|e| (crate::util::now() as f64) > e) {
        return None;
    }
    Some(v)
}

/// Session token payload: {id, username, display_name}.
pub fn issue_session(secret: &str, user: &Value, ttl: i64) -> String {
    let id = match &user["id"] {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    };
    issue_token(secret, json!({ "id": id, "username": user["username"], "display_name": user["display_name"] }), ttl)
}

const TOTP_PENDING_SUFFIX: &str = "#image_gallery_2fa_pending";

pub fn issue_2fa_pending(secret: &str, user_id: i64) -> String {
    issue_token(&format!("{secret}{TOTP_PENDING_SUFFIX}"), json!({ "id": user_id.to_string() }), 300)
}

pub fn verify_2fa_pending(secret: &str, token: &str) -> Option<i64> {
    let v = verify_token(&format!("{secret}{TOTP_PENDING_SUFFIX}"), token)?;
    id_of(&v["id"])
}

/// A token's `id` (string or number) as an integer.
pub fn id_of(v: &Value) -> Option<i64> {
    match v {
        Value::String(s) => s.trim().parse().ok(),
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        _ => None,
    }
}

pub fn bearer(header: Option<&str>) -> Option<String> {
    let h = header?.trim();
    let rest = h.strip_prefix("Bearer ").or_else(|| h.strip_prefix("bearer "))?;
    Some(rest.trim().to_string()).filter(|t| !t.is_empty())
}

pub fn random_hex(bytes: usize) -> String {
    let v: Vec<u8> = (0..bytes).map(|_| rand::random::<u8>()).collect();
    hex::encode(v)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn token_roundtrip() {
        let t = issue_session("s3cret", &json!({ "id": 42, "username": "bob", "display_name": "Bob" }), 60);
        let v = verify_token("s3cret", &t).unwrap();
        assert_eq!(v["id"], "42");
        assert!(verify_token("other", &t).is_none());
        let p = issue_2fa_pending("s3cret", 7);
        assert_eq!(verify_2fa_pending("s3cret", &p), Some(7));
        assert!(verify_token("s3cret", &p).is_none());
    }
    #[test]
    fn password() {
        let h = password_hash("hunter2");
        assert!(verify_password_hash("hunter2", &h));
        assert!(!verify_password_hash("nope", &h));
    }
}
