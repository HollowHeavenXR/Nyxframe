//! Content-based type detection and safe extensions (routes.lua's
//! sniff_magic / safe_extension), so an upload can't lie about its type.

pub fn sniff_magic(content: &[u8]) -> Option<(&'static str, &'static str)> {
    let head = &content[..content.len().min(128)];
    let at = |a: usize, b: usize| head.get(a..b);
    if at(0, 4) == Some(b"RIFF") && at(8, 12) == Some(b"WEBP") {
        return Some(("image/webp", "image"));
    }
    if head.len() >= 12 && at(4, 8) == Some(b"ftyp") {
        let brands = String::from_utf8_lossy(&head[8..head.len().min(32)]).to_lowercase();
        if brands.contains("avif") || brands.contains("avis") {
            return Some(("image/avif", "image"));
        }
        return Some(("video/mp4", "video"));
    }
    if at(0, 4) == Some(b"\x1aE\xdf\xa3") {
        let first = String::from_utf8_lossy(&content[..content.len().min(256)]).to_lowercase();
        return Some((if first.contains("matroska") { "video/x-matroska" } else { "video/webm" }, "video"));
    }
    if at(0, 3) == Some(b"\xff\xd8\xff") {
        return Some(("image/jpeg", "image"));
    }
    if at(0, 8) == Some(b"\x89PNG\r\n\x1a\n") {
        return Some(("image/png", "image"));
    }
    if at(0, 6) == Some(b"GIF87a") || at(0, 6) == Some(b"GIF89a") {
        return Some(("image/gif", "image"));
    }
    if at(0, 4) == Some(b"OggS") {
        return Some(("video/ogg", "video"));
    }
    if at(0, 4) == Some(b"FLV\x01") {
        return Some(("video/x-flv", "video"));
    }
    None
}

const SAFE: &[&str] = &[".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif", ".bmp", ".mp4", ".webm", ".mov", ".m4v", ".ogg", ".flv", ".mkv"];

fn mime_ext(mime: &str) -> &'static str {
    match mime {
        "image/jpeg" => ".jpg",
        "image/png" => ".png",
        "image/webp" => ".webp",
        "image/gif" => ".gif",
        "image/avif" => ".avif",
        "image/bmp" => ".bmp",
        "video/mp4" => ".mp4",
        "video/webm" => ".webm",
        "video/quicktime" => ".mov",
        "video/x-m4v" => ".m4v",
        "video/ogg" => ".ogg",
        "video/x-flv" => ".flv",
        "video/x-matroska" => ".mkv",
        _ => "",
    }
}

pub fn safe_extension(filename: &str, mime: &str) -> Option<String> {
    let ext = filename.rfind('.').map(|i| &filename[i..]).filter(|e| !e[1..].contains(['/', '\\'])).map(str::to_lowercase).unwrap_or_default();
    let ext = if SAFE.contains(&ext.as_str()) { ext } else { mime_ext(mime).to_string() };
    SAFE.contains(&ext.as_str()).then_some(ext)
}

/// Basename of a client-supplied filename, cut to 255 bytes.
pub fn clean_filename(name: &str, fallback: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().filter(|s| !s.is_empty()).unwrap_or(fallback);
    crate::util::cut(base, 255)
}

#[cfg(test)]
mod tests {
    #[test]
    fn ext() {
        assert_eq!(super::safe_extension("a.PNG", "image/png").as_deref(), Some(".png"));
        assert_eq!(super::safe_extension("a.exe", "image/jpeg").as_deref(), Some(".jpg"));
        assert_eq!(super::safe_extension("a.exe", "text/plain"), None);
        assert_eq!(super::sniff_magic(b"\x89PNG\r\n\x1a\nxxxx"), Some(("image/png", "image")));
    }
}
