//! Profile + appearance-settings validation (port of user_settings.lua).

use crate::util::{truthy, vnum, vstr};
use serde_json::{Map, Value, json};

pub fn defaults() -> Map<String, Value> {
    let v = json!({
        "theme_mode": "system", "accent_color": "#37c9a7", "accent_secondary": "", "gallery_bg_color": "",
        "grid_density": "comfortable", "grid_layout": "grid", "default_sort": "new", "items_per_page": 24,
        "autoplay_previews": false, "muted_previews": true, "reduce_motion": false,
        "open_original_in_new_tab": false, "blur_video_previews": false,
        "profile_show_uploads": true, "profile_show_collections": true, "profile_show_friends": true,
        "profile_show_follow_counts": true,
        "profile_layout": "spotlight", "profile_banner_style": "gradient", "profile_card_style": "glass",
        "profile_stat_style": "tiles", "profile_content_focus": "balanced", "profile_hero_alignment": "split",
        "profile_avatar_shape": "circle", "profile_media_shape": "soft", "profile_surface_style": "standard",
        "profile_social_layout": "rail", "profile_featured_panel": "uploads",
        "profile_backdrop_image_url": "", "profile_backdrop_strength": 0.18, "profile_show_joined_date": true,
        "profile_name_style": "display", "profile_header_style": "solid", "profile_bg_color": "",
        "card_hover_effect": "lift", "card_aspect_ratio": "free", "media_border_style": "none",
        "gallery_font": "system", "card_info_display": "below", "column_gap": "normal",
        "watermark_text": "", "discord_webhook_url": "",
        "profile_surface_opacity": 1, "profile_surface_blur": 0, "custom_css": ""
    });
    match v {
        Value::Object(m) => m,
        _ => unreachable!(),
    }
}

fn choices(key: &str) -> Option<&'static [&'static str]> {
    Some(match key {
        "theme_mode" => &["system", "dark", "light"],
        "grid_density" => &["compact", "comfortable", "wide"],
        "grid_layout" => &["grid", "masonry"],
        "default_sort" => &["new", "popular", "downloads", "views", "old"],
        "profile_layout" => &["spotlight", "magazine", "stack", "split", "mosaic", "timeline"],
        "profile_banner_style" => &["gradient", "mesh", "frame", "aurora", "spotlight", "poster"],
        "profile_card_style" => &["glass", "solid", "outline", "elevated", "soft", "edge"],
        "profile_stat_style" => &["tiles", "ribbon", "minimal"],
        "profile_content_focus" => &["balanced", "gallery", "collections", "social"],
        "profile_hero_alignment" => &["split", "start", "center"],
        "profile_avatar_shape" => &["circle", "rounded", "square"],
        "profile_media_shape" => &["soft", "crisp", "poster"],
        "profile_surface_style" => &["standard", "quiet", "contrast", "editorial"],
        "profile_social_layout" => &["rail", "cards", "compact"],
        "profile_featured_panel" => &["uploads", "collections", "friends"],
        "profile_name_style" => &["display", "gradient", "glow", "outline"],
        "profile_header_style" => &["solid", "glass", "blur", "transparent", "gradient"],
        "card_hover_effect" => &["lift", "zoom", "reveal", "glow", "none"],
        "card_aspect_ratio" => &["16:9", "4:3", "1:1", "3:4", "free"],
        "media_border_style" => &["none", "soft", "crisp", "glow", "neon"],
        "gallery_font" => &["system", "serif", "mono", "rounded"],
        "card_info_display" => &["overlay", "below", "hidden", "minimal"],
        "column_gap" => &["tight", "normal", "wide", "none"],
        _ => return None,
    })
}

pub fn clean_color(v: Option<&Value>) -> Result<String, String> {
    let c = vstr(v).unwrap_or_else(|| "#37c9a7".into()).trim().to_string();
    if c.len() == 7 && c.starts_with('#') && c[1..].chars().all(|ch| ch.is_ascii_hexdigit()) {
        Ok(c.to_lowercase())
    } else {
        Err("Color must be a hex value like #37c9a7.".into())
    }
}

/// Trim, collapse whitespace, cut to `max`; None when empty.
pub fn clean_text(v: Option<&Value>, max: usize, required: bool) -> Result<Option<String>, String> {
    let t = vstr(v).unwrap_or_default().split_whitespace().collect::<Vec<_>>().join(" ");
    if t.is_empty() {
        return if required { Err("Field is required.".into()) } else { Ok(None) };
    }
    Ok(Some(crate::util::cut(&t, max)))
}

fn clean_optional_url(v: Option<&Value>, max: usize) -> Result<Option<String>, String> {
    let Some(t) = clean_text(v, max, false)? else { return Ok(None) };
    if !(t.starts_with("http://") || t.starts_with("https://")) {
        return Err("URL must start with http:// or https://.".into());
    }
    Ok(Some(t))
}

pub fn clean_tags(v: Option<&Value>) -> Vec<String> {
    let list: Vec<String> = match v {
        Some(Value::String(s)) => s.split(|c: char| c == ',' || c == '#' || c.is_whitespace()).filter(|t| !t.is_empty()).map(str::to_string).collect(),
        Some(Value::Array(a)) => a.iter().map(|x| vstr(Some(x)).unwrap_or_default()).collect(),
        _ => vec![],
    };
    let mut out: Vec<String> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for raw in list {
        let tag: String = raw.trim().chars().filter(|c| c.is_ascii_alphanumeric() || "_.-".contains(*c)).collect();
        let tag = crate::util::cut(&tag, 32);
        if !tag.is_empty() && seen.insert(tag.to_lowercase()) {
            out.push(tag);
            if out.len() >= 12 {
                break;
            }
        }
    }
    out
}

pub fn is_valid_discord_webhook_url(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("https://") else { return false };
    let Some((host, path)) = rest.split_once('/') else { return false };
    if !matches!(host.to_lowercase().as_str(), "discord.com" | "www.discord.com" | "discordapp.com" | "www.discordapp.com") {
        return false;
    }
    let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
    parts.len() >= 4 && parts[0] == "api" && parts[1] == "webhooks"
}

pub fn clean_user_settings(payload: &Map<String, Value>, existing: &Value) -> Result<Value, String> {
    let defs = defaults();
    let mut s = defs.clone();
    if let Some(e) = existing.as_object() {
        for (k, v) in e {
            s.insert(k.clone(), v.clone());
        }
    }
    for key in defs.keys() {
        let Some(value) = payload.get(key) else { continue };
        let vref = Some(value);
        let out = if let Some(c) = choices(key) {
            let choice = vstr(vref).unwrap_or_default();
            if !c.contains(&choice.as_str()) {
                return Err(format!("Invalid {key}."));
            }
            json!(choice)
        } else if matches!(key.as_str(), "accent_color" | "accent_secondary" | "gallery_bg_color" | "profile_bg_color") {
            if truthy(vref) && value != "" { json!(clean_color(vref)?) } else { json!("") }
        } else {
            match key.as_str() {
                "items_per_page" => json!((vnum(vref).unwrap_or(24.0).floor() as i64).clamp(12, 60)),
                "profile_backdrop_image_url" => json!(clean_optional_url(vref, 500)?.unwrap_or_default()),
                "profile_backdrop_strength" => {
                    let n = vnum(vref);
                    if n.is_none() {
                        return Err("Backdrop strength must be a number.".into());
                    }
                    json!(n.unwrap().clamp(0.0, 0.55))
                }
                "watermark_text" => json!(crate::util::cut(vstr(vref).unwrap_or_default().trim(), 40)),
                "discord_webhook_url" => {
                    let t = crate::util::cut(vstr(vref).unwrap_or_default().trim(), 300);
                    if !t.is_empty() && !is_valid_discord_webhook_url(&t) {
                        return Err("Discord webhook URL must start with https://discord.com/api/webhooks/.".into());
                    }
                    json!(t)
                }
                "profile_surface_opacity" => {
                    let Some(n) = vnum(vref) else { return Err("Panel opacity must be a number.".into()) };
                    num(n.clamp(0.2, 1.0))
                }
                "profile_surface_blur" => {
                    let Some(n) = vnum(vref) else { return Err("Panel blur must be a number.".into()) };
                    num(n.clamp(0.0, 24.0))
                }
                "custom_css" => json!(crate::util::cut(&vstr(vref).unwrap_or_default(), 4000)),
                _ => json!(truthy(vref)),
            }
        };
        s.insert(key.clone(), out);
    }
    Ok(Value::Object(s))
}

/// Whole numbers as integers (cjson prints 1, not 1.0).
fn num(f: f64) -> Value {
    if f.fract() == 0.0 && f.abs() < 1e15 { json!(f as i64) } else { json!(f) }
}

pub struct ProfileUpdate {
    pub display_name: String,
    pub bio: Option<String>,
    pub profile_quote: Option<String>,
    pub website_url: Option<String>,
    pub location_label: Option<String>,
    pub profile_headline: Option<String>,
    pub featured_tags: String,
    pub profile_color: String,
    pub public_profile: bool,
    pub show_liked_count: bool,
    pub show_collections: bool,
    pub show_recent_uploads: bool,
    pub show_friends: bool,
}

pub fn clean_profile_updates(p: &Value) -> Result<ProfileUpdate, String> {
    let flag = |k: &str| match p.get(k) {
        None | Some(Value::Null) => true,
        v => truthy(v),
    };
    let tags = clean_tags(Some(p.get("featured_tags").filter(|v| !v.is_null()).unwrap_or(&json!([]))));
    let u = ProfileUpdate {
        display_name: clean_text(p.get("display_name"), 80, true)?.unwrap_or_default(),
        bio: clean_text(p.get("bio"), 500, false)?,
        profile_quote: clean_text(p.get("profile_quote"), 200, false)?,
        website_url: clean_text(p.get("website_url"), 300, false)?,
        location_label: clean_text(p.get("location_label"), 80, false)?,
        profile_headline: clean_text(p.get("profile_headline"), 120, false)?,
        featured_tags: json!(tags).to_string(),
        profile_color: clean_color(p.get("profile_color").filter(|v| !v.is_null()))?,
        public_profile: flag("public_profile"),
        show_liked_count: flag("show_liked_count"),
        show_collections: flag("show_collections"),
        show_recent_uploads: flag("show_recent_uploads"),
        show_friends: flag("show_friends"),
    };
    if let Some(w) = &u.website_url {
        if !(w.starts_with("http://") || w.starts_with("https://")) {
            return Err("Website must start with http:// or https://.".into());
        }
    }
    Ok(u)
}
