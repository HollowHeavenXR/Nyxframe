//! RFC 6238 TOTP (port of totp.lua): 6 digits, 30s steps, SHA-1, +-1 step.

use hmac::{Hmac, Mac};
use sha1::Sha1;

const DIGITS: u32 = 6;
pub const PERIOD: i64 = 30;
const ALPHABET: base32::Alphabet = base32::Alphabet::Rfc4648 { padding: false };

fn decode_secret(secret: &str) -> Option<Vec<u8>> {
    let clean: String = secret.to_uppercase().chars().filter(|c| c.is_ascii_uppercase() || ('2'..='7').contains(c)).collect();
    base32::decode(ALPHABET, &clean)
}

fn hotp(key: &[u8], counter: i64) -> String {
    let mut m = Hmac::<Sha1>::new_from_slice(key).expect("hmac key");
    m.update(&(counter as u64).to_be_bytes());
    let d = m.finalize().into_bytes();
    let off = (d[19] & 0x0f) as usize;
    let n = (u32::from(d[off] & 0x7f) << 24) | (u32::from(d[off + 1]) << 16) | (u32::from(d[off + 2]) << 8) | u32::from(d[off + 3]);
    format!("{:06}", n % 10u32.pow(DIGITS))
}

pub fn verify_code(secret: &str, code: &str, at: i64) -> bool {
    let digits: String = code.chars().filter(char::is_ascii_digit).collect();
    if digits.len() != DIGITS as usize {
        return false;
    }
    let Some(key) = decode_secret(secret) else { return false };
    let counter = at.div_euclid(PERIOD);
    (-1..=1).any(|o| hotp(&key, counter + o) == digits)
}

pub fn generate_secret() -> String {
    let raw: [u8; 20] = rand::random();
    base32::encode(ALPHABET, &raw)
}

fn urlenc(s: &str) -> String {
    s.bytes().map(|b| if b.is_ascii_alphanumeric() || b"-._~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect()
}

pub fn provisioning_uri(secret: &str, account: &str, issuer: &str) -> String {
    format!("otpauth://totp/{}?secret={secret}&issuer={}&algorithm=SHA1&digits={DIGITS}&period={PERIOD}", urlenc(&format!("{issuer}:{account}")), urlenc(issuer))
}

pub fn recovery_codes(n: usize) -> Vec<String> {
    (0..n).map(|_| format!("{}-{}", crate::auth::random_hex(3), crate::auth::random_hex(3))).collect()
}

#[cfg(test)]
mod tests {
    #[test]
    fn rfc_vector() {
        // RFC 6238 SHA-1 secret "12345678901234567890" at t=59 -> 94287082 (last 6: 287082).
        let secret = base32::encode(super::ALPHABET, b"12345678901234567890");
        assert!(super::verify_code(&secret, "287082", 59));
        assert!(!super::verify_code(&secret, "000000", 59));
    }
}
