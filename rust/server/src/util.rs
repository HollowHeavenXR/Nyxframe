//! Small shared helpers (string/JSON idioms from routes.lua, colorutil.lua).

use serde_json::{Value, json};

/// First `n` bytes, cut on a char boundary (Lua's s:sub(1, n)).
pub fn cut(s: &str, n: usize) -> String {
    if s.len() <= n {
        return s.to_string();
    }
    let mut end = n;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    s[..end].to_string()
}

pub fn now() -> i64 {
    chrono::Utc::now().timestamp()
}

/// "2026-10-31T12:00:00Z" (os.date("!%Y-%m-%dT%H:%M:%S") .. "Z").
pub fn iso_now() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

/// HTML-escape (for strings built outside maud).
pub fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&#39;")
}


/// A JSON value as Lua's tostring() would print it (None for null/missing).
pub fn vstr(v: Option<&Value>) -> Option<String> {
    match v? {
        Value::Null => None,
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.as_i64().map(|i| i.to_string()).unwrap_or_else(|| n.to_string())),
        other => Some(other.to_string()),
    }
}

/// Lua tonumber() on a JSON value (numbers or numeric strings).
pub fn vnum(v: Option<&Value>) -> Option<f64> {
    match v? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse::<f64>().ok().filter(|f| f.is_finite()),
        _ => None,
    }
}

pub fn vint(v: Option<&Value>) -> Option<i64> {
    vnum(v).map(|f| f.floor() as i64)
}

/// Lua truthiness of a decoded JSON value (nil/null/false are falsy).
pub fn truthy(v: Option<&Value>) -> bool {
    !matches!(v, None | Some(Value::Null) | Some(Value::Bool(false)))
}

/// db.tobool: true / "t" / "true" / "1" / 1.
pub fn tobool(v: Option<&Value>) -> bool {
    match v {
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_f64() == Some(1.0),
        Some(Value::String(s)) => matches!(s.as_str(), "t" | "true" | "1"),
        _ => false,
    }
}

/// Coerce the named fields of a row to booleans in place.
pub fn bools(row: &mut Value, fields: &[&str]) {
    for f in fields {
        if let Some(v) = row.get(*f) {
            let b = tobool(Some(v));
            row[*f] = json!(b);
        }
    }
}

/// A text column holding a JSON array ("tags", "featured_tags") as a list.
pub fn json_list(v: Option<&Value>) -> Value {
    match v {
        Some(Value::String(s)) => match serde_json::from_str::<Value>(s) {
            Ok(Value::Array(a)) => Value::Array(a),
            Ok(Value::Object(o)) if o.is_empty() => json!([]),
            _ => json!([]),
        },
        Some(Value::Array(a)) => Value::Array(a.clone()),
        _ => json!([]),
    }
}

/// A text column holding a JSON object; {} when absent or invalid.
pub fn json_obj(v: Option<&Value>) -> Value {
    match v {
        Some(Value::String(s)) => serde_json::from_str::<Value>(s).ok().filter(Value::is_object).unwrap_or_else(|| json!({})),
        Some(Value::Object(o)) => Value::Object(o.clone()),
        _ => json!({}),
    }
}

pub fn append_query(url: &str, key: &str, value: &str) -> String {
    format!("{url}{}{key}={value}", if url.contains('?') { "&" } else { "?" })
}

/// Lua's `s:gsub("%D", "")`.
pub fn digits(s: &str) -> String {
    s.chars().filter(char::is_ascii_digit).collect()
}

pub fn slugify(name: &str) -> String {
    let mut out = String::new();
    let mut dash = false;
    for c in name.to_lowercase().chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c);
            dash = false;
        } else if !dash {
            out.push('-');
            dash = true;
        }
    }
    let s = out.trim_matches('-').to_string();
    cut(if s.is_empty() { "category" } else { &s }, 80)
}

// ---- colorutil.lua ------------------------------------------------------------------------
fn hex_rgb(hex: &str) -> Option<(f64, f64, f64)> {
    let h = hex.trim_start_matches('#');
    let h = if h.len() == 3 { h.chars().flat_map(|c| [c, c]).collect::<String>() } else { h.to_string() };
    if h.len() != 6 || !h.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let p = |i: usize| u8::from_str_radix(&h[i..i + 2], 16).ok().map(f64::from);
    Some((p(0)?, p(2)?, p(4)?))
}

fn rgb_hex(r: f64, g: f64, b: f64) -> String {
    let c = |x: f64| ((x / 255.0).clamp(0.0, 1.0) * 255.0 + 0.5).floor() as u8;
    format!("#{:02x}{:02x}{:02x}", c(r), c(g), c(b))
}

pub fn contrast_text(hex: &str) -> &'static str {
    let Some((r, g, b)) = hex_rgb(hex) else { return "#ffffff" };
    let lin = |c: f64| {
        let c = c / 255.0;
        if c <= 0.03928 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
    };
    let l = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
    if (l + 0.05) / 0.05 > 1.05 / (l + 0.05) { "#0b0e18" } else { "#ffffff" }
}

pub fn auto_secondary(hex: &str) -> String {
    let Some((r, g, b)) = hex_rgb(hex) else { return "#7c3aed".into() };
    let (r, g, b) = (r / 255.0, g / 255.0, b / 255.0);
    let (mx, mn) = (r.max(g).max(b), r.min(g).min(b));
    let (mut h, mut s, l) = (0.0, 0.0, (mx + mn) / 2.0);
    let d = mx - mn;
    if d != 0.0 {
        s = if l > 0.5 { d / (2.0 - mx - mn) } else { d / (mx + mn) };
        h = if mx == r { (g - b) / d + if g < b { 6.0 } else { 0.0 } } else if mx == g { (b - r) / d + 2.0 } else { (r - g) / d + 4.0 };
        h /= 6.0;
    }
    let h = (h + 150.0 / 360.0) % 1.0;
    let l = (l * 0.7 + 0.15).clamp(0.0, 1.0);
    let s = s.max(0.45);
    let hue = |p: f64, q: f64, mut t: f64| {
        if t < 0.0 {
            t += 1.0;
        }
        if t > 1.0 {
            t -= 1.0;
        }
        if t < 1.0 / 6.0 {
            p + (q - p) * 6.0 * t
        } else if t < 0.5 {
            q
        } else if t < 2.0 / 3.0 {
            p + (q - p) * (2.0 / 3.0 - t) * 6.0
        } else {
            p
        }
    };
    let q = if l < 0.5 { l * (1.0 + s) } else { l + s - l * s };
    let p = 2.0 * l - q;
    rgb_hex(hue(p, q, h + 1.0 / 3.0) * 255.0, hue(p, q, h) * 255.0, hue(p, q, h - 1.0 / 3.0) * 255.0)
}

pub fn gradient(a: &str, b: &str) -> String {
    format!("linear-gradient(135deg, {a}, {b})")
}

#[cfg(test)]
mod tests {
    #[test]
    fn slug() {
        assert_eq!(super::slugify("  Hello, World!! "), "hello-world");
        assert_eq!(super::slugify("!!!"), "category");
    }
}
