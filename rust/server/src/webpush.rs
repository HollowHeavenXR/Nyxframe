//! Web Push (port of webpush.lua): VAPID (RFC 8292) ES256 JWTs and
//! aes128gcm payload encryption (RFC 8291), done in-process. The VAPID
//! keypair stays in `<uploads>/_vapid/` so existing browser subscriptions
//! keep working.

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes128Gcm, Nonce};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use hkdf::Hkdf;
use p256::ecdsa::{Signature, SigningKey, signature::Signer};
use p256::elliptic_curve::sec1::ToEncodedPoint;
use p256::pkcs8::{DecodePrivateKey, EncodePrivateKey, LineEnding};
use p256::{PublicKey, SecretKey};
use serde_json::{Value, json};
use sha2::Sha256;
use std::sync::OnceLock;

struct Vapid {
    key: SecretKey,
    pub_raw: Vec<u8>,
}

static VAPID: OnceLock<Result<Vapid, String>> = OnceLock::new();

fn load_or_create(uploads_dir: &str) -> Result<Vapid, String> {
    let dir = format!("{uploads_dir}/_vapid");
    let (priv_path, pub_path) = (format!("{dir}/private.pem"), format!("{dir}/public.raw"));
    if let (Ok(pem), Ok(pub_raw)) = (std::fs::read_to_string(&priv_path), std::fs::read(&pub_path)) {
        if pub_raw.len() == 65 {
            let key = SecretKey::from_pkcs8_pem(&pem).map_err(|e| format!("bad VAPID private key: {e}"))?;
            return Ok(Vapid { key, pub_raw });
        }
    }
    let key = SecretKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
    let pub_raw = key.public_key().to_encoded_point(false).as_bytes().to_vec();
    let pem = key.to_pkcs8_pem(LineEnding::LF).map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("could not persist VAPID keys to {dir}: {e}"))?;
    std::fs::write(&priv_path, pem.as_bytes()).map_err(|e| format!("could not persist VAPID keys to {dir}: {e}"))?;
    std::fs::write(&pub_path, &pub_raw).map_err(|e| format!("could not persist VAPID keys to {dir}: {e}"))?;
    Ok(Vapid { key, pub_raw })
}

fn vapid(uploads_dir: &str) -> Result<&'static Vapid, String> {
    VAPID.get_or_init(|| load_or_create(uploads_dir)).as_ref().map_err(Clone::clone)
}

pub fn public_key_b64url(uploads_dir: &str) -> Result<String, String> {
    Ok(URL_SAFE_NO_PAD.encode(&vapid(uploads_dir)?.pub_raw))
}

fn jwt(v: &Vapid, audience: &str, subject: &str) -> String {
    let header = URL_SAFE_NO_PAD.encode(json!({ "typ": "JWT", "alg": "ES256" }).to_string());
    let claims = URL_SAFE_NO_PAD.encode(json!({ "aud": audience, "exp": crate::util::now() + 12 * 3600, "sub": subject }).to_string());
    let input = format!("{header}.{claims}");
    let sig: Signature = SigningKey::from(&v.key).sign(input.as_bytes());
    format!("{input}.{}", URL_SAFE_NO_PAD.encode(sig.to_bytes()))
}

fn hkdf(ikm: &[u8], salt: &[u8], info: &[u8], len: usize) -> Vec<u8> {
    let mut out = vec![0u8; len];
    Hkdf::<Sha256>::new(Some(salt), ikm).expand(info, &mut out).expect("hkdf length");
    out
}

/// RFC 8291 aes128gcm body for one subscriber.
fn encrypt(payload: &[u8], sub_pub: &[u8], auth: &[u8]) -> Result<Vec<u8>, String> {
    let peer = PublicKey::from_sec1_bytes(sub_pub).map_err(|_| "invalid peer public key")?;
    let eph = p256::ecdh::EphemeralSecret::random(&mut p256::elliptic_curve::rand_core::OsRng);
    let eph_pub = eph.public_key().to_encoded_point(false).as_bytes().to_vec();
    let shared = eph.diffie_hellman(&peer);
    let mut key_info = b"WebPush: info\0".to_vec();
    key_info.extend_from_slice(sub_pub);
    key_info.extend_from_slice(&eph_pub);
    let ikm = hkdf(shared.raw_secret_bytes(), auth, &key_info, 32);
    let salt: [u8; 16] = rand::random();
    let cek = hkdf(&ikm, &salt, b"Content-Encoding: aes128gcm\0", 16);
    let nonce = hkdf(&ikm, &salt, b"Content-Encoding: nonce\0", 12);
    let mut plain = payload.to_vec();
    plain.push(2);
    let ct = Aes128Gcm::new_from_slice(&cek).map_err(|e| e.to_string())?.encrypt(&Nonce::clone_from_slice(&nonce), plain.as_slice()).map_err(|_| "encryption failed")?;
    let mut body = salt.to_vec();
    body.extend_from_slice(&4096u32.to_be_bytes());
    body.push(eph_pub.len() as u8);
    body.extend_from_slice(&eph_pub);
    body.extend_from_slice(&ct);
    Ok(body)
}

/// Send one notification; Ok(HTTP status) once the push service answered.
pub async fn send(http: &reqwest::Client, uploads_dir: &str, subject: &str, sub: &Value, payload: &Value) -> Result<u16, String> {
    let dec = |k: &str| sub.get(k).and_then(Value::as_str).and_then(|s| URL_SAFE_NO_PAD.decode(s.trim_end_matches('=')).ok());
    let (Some(p256dh), Some(auth)) = (dec("p256dh"), dec("auth")) else { return Err("malformed subscription keys".into()) };
    if p256dh.len() != 65 || auth.len() != 16 {
        return Err("malformed subscription keys".into());
    }
    let endpoint = sub.get("endpoint").and_then(Value::as_str).unwrap_or("");
    let origin = endpoint.find("://").and_then(|i| endpoint[i + 3..].find('/').map(|j| &endpoint[..i + 3 + j]).or(Some(endpoint))).filter(|o| o.starts_with("http")).ok_or("invalid endpoint URL")?;
    let body = encrypt(payload.to_string().as_bytes(), &p256dh, &auth)?;
    let v = vapid(uploads_dir)?;
    let token = jwt(v, origin, subject);
    let resp = http
        .post(endpoint)
        .header("Content-Type", "application/octet-stream")
        .header("Content-Encoding", "aes128gcm")
        .header("TTL", "86400")
        .header("Urgency", "normal")
        .header("Authorization", format!("vapid t={token}, k={}", URL_SAFE_NO_PAD.encode(&v.pub_raw)))
        .body(body)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    Ok(resp.status().as_u16())
}

#[cfg(test)]
mod tests {
    #[test]
    fn encrypts_to_rfc_layout() {
        let sk = p256::SecretKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
        use p256::elliptic_curve::sec1::ToEncodedPoint;
        let pubk = sk.public_key().to_encoded_point(false).as_bytes().to_vec();
        let body = super::encrypt(b"{}", &pubk, &[7u8; 16]).unwrap();
        // salt(16) + rs(4) + idlen(1) + key(65) + ciphertext(2+1) + tag(16)
        assert_eq!(body.len(), 16 + 4 + 1 + 65 + 3 + 16);
        assert_eq!(body[20], 65);
    }
}
