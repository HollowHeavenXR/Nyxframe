//! Upload metadata suggestions (port of ai_metadata.lua + classification.lua):
//! local heuristics (filename/booru parsing, category inference, tag and
//! title cleanup), franchise alias hints, and Gemini vision analysis merged
//! on top.

use crate::config::Settings;
use crate::util::cut;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::LazyLock;

const MAX_SUBS: usize = 3;

const STOP_TAGS: &[&str] = &[
    "the", "and", "for", "with", "from", "fullview", "generated", "image", "standard", "lite", "upscayl", "wallpaper", "desktop", "phone", "background", "backgrounds", "version", "text", "movie",
    "poster", "upload", "artwork", "fanart", "pic", "photo", "picture", "by", "artist", "source", "ai", "enhanced", "upscaled", "upscale", "compressed", "icloud",
];
const GENERIC_SUB_LABELS: &[&str] = &["wallpaper", "wallpapers", "background", "backgrounds", "desktop background", "desktop backgrounds", "phone background", "phone backgrounds", "image", "images", "art", "artwork", "profile picture", "profile pictures"];
const GENERIC_TITLE_PHRASES: &[&str] = &[
    "background", "backgrounds", "wallpaper", "wallpapers", "image", "images", "photo", "photos", "picture", "pictures", "art", "artwork", "fanart", "render", "renders", "edit", "edits",
    "desktop background", "phone background", "desktop wallpaper", "phone wallpaper", "imported media", "imported image", "imported video", "imported gif",
];
const KNOWN_CATEGORIES: &[&str] = &[
    "My Little Pony", "FNAF", "GIFs", "KPOP Demon Hunters", "Videos", "Crossovers", "Hyperdimension Neptunia", "Profile Pictures", "Cartoon", "Memes", "Resident Evil", "Final Fantasy", "Xenoblade",
    "Sonic", "Desktop Backgrounds", "Phone Backgrounds", "Wallpapers",
];
const GUIDE: &[(&str, &[&str])] = &[
    ("My Little Pony / Equestria Girls", &["Aria Blaze", "Adagio Dazzle", "Sonata Dusk", "Dazzlings", "Sunset Shimmer", "Twilight Sparkle", "Fluttershy", "Rainbow Dash", "Pinkie Pie", "Rarity", "Applejack", "Starlight Glimmer", "Trixie", "Princess Celestia", "Princess Luna"]),
    ("Five Nights at Freddy's", &["Freddy Fazbear", "Bonnie", "Chica", "Foxy", "Roxanne Wolf", "Roxy", "Frenni"]),
    ("Final Fantasy", &["Cloud Strife", "Tifa Lockhart", "Aerith Gainsborough", "Sephiroth"]),
    ("Resident Evil", &["Leon Kennedy", "Ada Wong", "Jill Valentine", "Claire Redfield", "Ashley Graham", "Albert Wesker"]),
    ("Sonic", &["Sonic", "Shadow", "Amy Rose", "Tails", "Knuckles", "Rouge"]),
    ("Xenoblade", &["Pyra", "Mythra", "Nia", "Mio", "Eunie", "Noah"]),
    ("Hyperdimension Neptunia", &["Neptune", "Nepgear", "Noire", "Blanc", "Vert", "Uzume", "Plutia"]),
    ("KPOP Demon Hunters", &["Huntrix", "Mira", "Zoey", "Rumi"]),
    ("Date A Live", &["Kurumi Tokisaki", "Tohka Yatogami", "Kotori Itsuka", "Origami Tobiichi", "Yoshino", "Miku Izayoi", "Natsumi", "Mukuro Hoshimiya", "Kaguya Yamai", "Shido Itsuka"]),
];

type Alias = (&'static str, &'static str, &'static str, &'static [&'static str]);
const ALIASES: &[(&str, Alias)] = &[
    ("dazzlings", ("The Dazzlings", "My Little Pony", "Equestria Girls", &["dazzlings", "mlp", "equestria girls"])),
    ("aria blaze", ("Aria Blaze", "My Little Pony", "Equestria Girls", &["aria blaze", "dazzlings", "mlp", "equestria girls"])),
    ("adagio dazzle", ("Adagio Dazzle", "My Little Pony", "Equestria Girls", &["adagio dazzle", "dazzlings", "mlp", "equestria girls"])),
    ("sonata dusk", ("Sonata Dusk", "My Little Pony", "Equestria Girls", &["sonata dusk", "dazzlings", "mlp", "equestria girls"])),
    ("sunset shimmer", ("Sunset Shimmer", "My Little Pony", "Equestria Girls", &["sunset shimmer", "mlp", "equestria girls"])),
    ("twilight sparkle", ("Twilight Sparkle", "My Little Pony", "Equestria Girls", &["twilight sparkle", "mlp", "equestria girls"])),
    ("rainbow dash", ("Rainbow Dash", "My Little Pony", "Mane Six", &["rainbow dash", "mlp", "mane six"])),
    ("pinkie pie", ("Pinkie Pie", "My Little Pony", "Mane Six", &["pinkie pie", "mlp", "mane six"])),
    ("fluttershy", ("Fluttershy", "My Little Pony", "Mane Six", &["fluttershy", "mlp", "mane six"])),
    ("applejack", ("Applejack", "My Little Pony", "Mane Six", &["applejack", "mlp", "mane six"])),
    ("rarity", ("Rarity", "My Little Pony", "Mane Six", &["rarity", "mlp", "mane six"])),
    ("spike", ("Spike", "My Little Pony", "Mane Six", &["spike", "mlp"])),
    ("starlight glimmer", ("Starlight Glimmer", "My Little Pony", "Equestria Girls", &["starlight glimmer", "mlp"])),
    ("trixie", ("Trixie", "My Little Pony", "Equestria Girls", &["trixie", "mlp"])),
    ("derpy", ("Derpy", "My Little Pony", "Mane Six", &["derpy", "mlp"])),
    ("huntrix", ("Huntrix", "KPOP Demon Hunters", "Huntrix", &["huntrix", "kpop demon hunters"])),
    ("rumi", ("Rumi", "KPOP Demon Hunters", "Huntrix", &["rumi", "huntrix", "kpop demon hunters"])),
    ("mira", ("Mira", "KPOP Demon Hunters", "Huntrix", &["mira", "huntrix", "kpop demon hunters"])),
    ("zoey", ("Zoey", "KPOP Demon Hunters", "Huntrix", &["zoey", "huntrix", "kpop demon hunters"])),
    ("saja boys", ("Saja Boys", "KPOP Demon Hunters", "Saja Boys", &["saja boys", "kpop demon hunters"])),
    ("kurumi tokisaki", ("Kurumi Tokisaki", "Date A Live", "Kurumi Tokisaki", &["kurumi tokisaki", "date a live"])),
    ("tokisaki kurumi", ("Kurumi Tokisaki", "Date A Live", "Kurumi Tokisaki", &["kurumi tokisaki", "date a live"])),
    ("tohka yatogami", ("Tohka Yatogami", "Date A Live", "Tohka Yatogami", &["tohka yatogami", "date a live"])),
    ("yatogami tohka", ("Tohka Yatogami", "Date A Live", "Tohka Yatogami", &["tohka yatogami", "date a live"])),
    ("kotori itsuka", ("Kotori Itsuka", "Date A Live", "Kotori Itsuka", &["kotori itsuka", "date a live"])),
    ("itsuka kotori", ("Kotori Itsuka", "Date A Live", "Kotori Itsuka", &["kotori itsuka", "date a live"])),
    ("origami tobiichi", ("Origami Tobiichi", "Date A Live", "Origami Tobiichi", &["origami tobiichi", "date a live"])),
    ("tobiichi origami", ("Origami Tobiichi", "Date A Live", "Origami Tobiichi", &["origami tobiichi", "date a live"])),
    ("miku izayoi", ("Miku Izayoi", "Date A Live", "Miku Izayoi", &["miku izayoi", "date a live"])),
    ("izayoi miku", ("Miku Izayoi", "Date A Live", "Miku Izayoi", &["miku izayoi", "date a live"])),
    ("mukuro hoshimiya", ("Mukuro Hoshimiya", "Date A Live", "Mukuro Hoshimiya", &["mukuro hoshimiya", "date a live"])),
    ("hoshimiya mukuro", ("Mukuro Hoshimiya", "Date A Live", "Mukuro Hoshimiya", &["mukuro hoshimiya", "date a live"])),
    ("kaguya yamai", ("Kaguya Yamai", "Date A Live", "Kaguya Yamai", &["kaguya yamai", "date a live"])),
    ("yamai kaguya", ("Kaguya Yamai", "Date A Live", "Kaguya Yamai", &["kaguya yamai", "date a live"])),
    ("shido itsuka", ("Shido Itsuka", "Date A Live", "Shido Itsuka", &["shido itsuka", "date a live"])),
    ("itsuka shido", ("Shido Itsuka", "Date A Live", "Shido Itsuka", &["shido itsuka", "date a live"])),
];

fn alias(key: &str) -> Alias {
    ALIASES.iter().find(|(k, _)| *k == key).map(|(_, a)| *a).unwrap()
}

const BOORU_CHARACTERS: &[(&str, &str, Option<&str>)] = &[
    ("tokisaki_kurumi", "Kurumi Tokisaki", Some("Date A Live")),
    ("yatogami_tohka", "Tohka Yatogami", Some("Date A Live")),
    ("itsuka_kotori", "Kotori Itsuka", Some("Date A Live")),
    ("itsuka_shidou", "Shido Itsuka", Some("Date A Live")),
    ("tobiichi_origami", "Origami Tobiichi", Some("Date A Live")),
    ("himekawa_yoshino", "Yoshino", Some("Date A Live")),
    ("yoshino_date_a_live", "Yoshino", Some("Date A Live")),
    ("izayoi_miku", "Miku Izayoi", Some("Date A Live")),
    ("natsumi_date_a_live", "Natsumi", Some("Date A Live")),
    ("hoshimiya_mukuro", "Mukuro Hoshimiya", Some("Date A Live")),
    ("yamai_kaguya", "Kaguya Yamai", Some("Date A Live")),
    ("yamai_yuzuru", "Yuzuru Yamai", Some("Date A Live")),
    ("takamiya_mana", "Mana Takamiya", Some("Date A Live")),
    ("takamiya_mio", "Mio Takamiya", Some("Date A Live")),
    ("murasame_reine", "Reine Murasame", Some("Date A Live")),
    ("honjou_nia", "Nia Honjou", Some("Date A Live")),
    ("hornet_hollow_knight", "Hornet", Some("Hollow Knight")),
    ("hornet", "Hornet", None),
];

const BOORU_COPYRIGHTS: &[(&str, Option<&str>)] = &[
    ("date_a_live", Some("Date A Live")), ("azur_lane", Some("Azur Lane")), ("punishing_gray_raven", Some("Punishing: Gray Raven")), ("hollow_knight", Some("Hollow Knight")),
    ("zenless_zone_zero", Some("Zenless Zone Zero")), ("genshin_impact", Some("Genshin Impact")), ("honkai_star_rail", Some("Honkai: Star Rail")), ("honkai_impact_3rd", Some("Honkai Impact 3rd")),
    ("blue_archive", Some("Blue Archive")), ("goddess_of_victory_nikke", Some("Nikke")), ("arknights", Some("Arknights")), ("wuthering_waves", Some("Wuthering Waves")),
    ("xenoblade_chronicles_2", Some("Xenoblade Chronicles 2")), ("xenoblade_chronicles_3", Some("Xenoblade Chronicles 3")), ("xenoblade_chronicles", Some("Xenoblade")),
    ("kpop_demon_hunters", Some("KPOP Demon Hunters")), ("my_little_pony", Some("My Little Pony")), ("my_little_pony_equestria_girls", Some("My Little Pony")),
    ("my_little_pony_friendship_is_magic", Some("My Little Pony")), ("resident_evil", Some("Resident Evil")), ("final_fantasy_vii", Some("Final Fantasy")),
    ("final_fantasy_vii_remake", Some("Final Fantasy")), ("final_fantasy", Some("Final Fantasy")), ("sonic_the_hedgehog", Some("Sonic")), ("sonic_series", Some("Sonic")),
    ("overwatch", Some("Overwatch")), ("overwatch_2", Some("Overwatch")), ("fate_grand_order", Some("Fate/Grand Order")), ("fate_series", Some("Fate")), ("hololive", Some("Hololive")),
    ("pokemon", Some("Pokemon")), ("street_fighter", Some("Street Fighter")), ("street_fighter_6", Some("Street Fighter")), ("monster_hunter", Some("Monster Hunter")),
    ("doki_doki_literature_club", Some("Doki Doki Literature Club")), ("bayonetta", Some("Bayonetta")), ("bayonetta_series", Some("Bayonetta")), ("kingdom_hearts", Some("Kingdom Hearts")),
    ("dragon_ball", Some("Dragon Ball")), ("dragon_ball_z", Some("Dragon Ball")), ("super_smash_bros", Some("Super Smash Bros.")), ("mario_series", Some("Mario")), ("super_mario_bros", Some("Mario")),
    ("neptune_series", Some("Hyperdimension Neptunia")), ("re_zero_kara_hajimeru_isekai_seikatsu", Some("Re:Zero")), ("sword_art_online", Some("Sword Art Online")),
    ("darling_in_the_franxx", Some("Darling in the Franxx")), ("spy_x_family", Some("Spy x Family")), ("chainsaw_man", Some("Chainsaw Man")), ("jujutsu_kaisen", Some("Jujutsu Kaisen")),
    ("touhou", Some("Touhou")), ("vocaloid", Some("Vocaloid")), ("kantai_collection", Some("KanColle")), ("girls_frontline", Some("Girls' Frontline")),
    ("five_nights_at_freddy_s", Some("FNAF")), ("five_nights_at_freddys", Some("FNAF")), ("original", None),
];

static CHAR_KEYS: LazyLock<Vec<&'static str>> = LazyLock::new(|| {
    let mut k: Vec<&str> = BOORU_CHARACTERS.iter().map(|c| c.0).collect();
    k.sort_by_key(|s| std::cmp::Reverse(s.len()));
    k
});
static COPY_KEYS: LazyLock<Vec<&'static str>> = LazyLock::new(|| {
    let mut k: Vec<&str> = BOORU_COPYRIGHTS.iter().map(|c| c.0).collect();
    k.sort_by_key(|s| std::cmp::Reverse(s.len()));
    k
});

// ---- small text helpers ------------------------------------------------------------------------
fn collapse_ws(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn compact_label(s: &str) -> String {
    s.to_lowercase().chars().filter(char::is_ascii_alphanumeric).collect()
}

fn is_hex(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_hexdigit())
}
fn is_digits(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_digit())
}

/// "prefix" + optional [_-] + digits+
fn prefixed_num(s: &str, prefix: &str) -> bool {
    let Some(rest) = s.strip_prefix(prefix) else { return false };
    let rest = rest.strip_prefix(['_', '-']).unwrap_or(rest);
    is_digits(rest)
}

fn is_noise_token(v: &str) -> bool {
    let token = v.to_lowercase().replace('_', "-");
    if token.is_empty() {
        return true;
    }
    let compact: String = token.chars().filter(char::is_ascii_alphanumeric).collect();
    if compact.is_empty() {
        return true;
    }
    if is_digits(&compact) && compact.len() >= 2 {
        return true;
    }
    if is_hex(&compact) && compact.chars().any(|c| c.is_ascii_digit()) && compact.len() >= 4 {
        return true;
    }
    let noisy = |s: &str| -> bool {
        if s.is_empty() {
            return false;
        }
        if s.strip_prefix("wp").is_some_and(is_digits) {
            return true;
        }
        if ["img", "dsc", "pxl", "mvimg", "screenshot", "photo", "image"].iter().any(|p| prefixed_num(s, p)) {
            return true;
        }
        if is_digits(s) && s.len() >= 2 {
            return true;
        }
        if is_hex(s) && s.len() >= 8 {
            return true;
        }
        if let Some((a, b)) = s.split_once('x') {
            if (3..=4).contains(&a.len()) && (3..=4).contains(&b.len()) && is_digits(a) && is_digits(b) {
                return true;
            }
        }
        if let Some(n) = s.strip_suffix('p') {
            if (3..=4).contains(&n.len()) && is_digits(n) {
                return true;
            }
        }
        matches!(s, "4k" | "8k" | "uhd" | "fhd" | "qhd" | "desktop" | "phone" | "background" | "backgrounds" | "wallpaper" | "wallpapers")
    };
    noisy(&token) || noisy(&compact)
}

fn clean_label(v: Option<&str>) -> Option<String> {
    let c = cut(&collapse_ws(v.unwrap_or("")), 80);
    (!c.is_empty() && !is_noise_token(&c)).then_some(c)
}

fn clean_filename_base(v: &str) -> String {
    let mut out = String::new();
    for c in v.to_lowercase().chars() {
        if c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' {
            out.push(c);
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    let mut squashed = String::new();
    for c in out.chars() {
        if !(c == '-' && squashed.ends_with('-')) {
            squashed.push(c);
        }
    }
    cut(squashed.trim_matches('-'), 90)
}

/// Remove every match of a simple pattern from `text` (case-insensitive for letters).
fn strip_matches(text: &str, matcher: impl Fn(&[u8], usize) -> Option<usize>) -> String {
    let b = text.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if let Some(len) = matcher(b, i).filter(|l| *l > 0) {
            i += len;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn digits_at(b: &[u8], i: usize) -> usize {
    b[i..].iter().take_while(|c| c.is_ascii_digit()).count()
}

fn word_num_at(b: &[u8], i: usize, word: &str) -> Option<usize> {
    let w = word.as_bytes();
    if b.len() < i + w.len() || !b[i..i + w.len()].eq_ignore_ascii_case(w) {
        return None;
    }
    let mut j = i + w.len();
    if j < b.len() && (b[j] == b'_' || b[j] == b'-') && j + 1 < b.len() && b[j + 1].is_ascii_digit() {
        j += 1;
    }
    let d = digits_at(b, j);
    (d > 0).then_some(j + d - i)
}

fn res_at(b: &[u8], i: usize) -> Option<usize> {
    let a = digits_at(b, i);
    if !(3..=4).contains(&a) {
        return None;
    }
    let j = i + a;
    if j < b.len() && b[j] == b'x' {
        let c = digits_at(b, j + 1);
        if (3..=4).contains(&c) {
            return Some(a + 1 + c);
        }
    }
    None
}

fn clean_title(v: &str) -> String {
    let mut t = cut(&collapse_ws(v), 160);
    t = strip_matches(&t, res_at);
    t = strip_matches(&t, |b, i| {
        let a = digits_at(b, i);
        ((3..=4).contains(&a) && b.get(i + a) == Some(&b'p')).then_some(a + 1)
    });
    t = strip_matches(&t, |b, i| ((b[i] == b'4' || b[i] == b'8') && b.get(i + 1) == Some(&b'k')).then_some(2));
    t = strip_matches(&t, |b, i| (b.len() >= i + 3 && b"uUfFqQ".contains(&b[i]) && b[i + 1].eq_ignore_ascii_case(&b'h') && b[i + 2].eq_ignore_ascii_case(&b'd')).then_some(3));
    t = strip_matches(&t, |b, i| {
        if b.len() >= i + 2 && b[i].eq_ignore_ascii_case(&b'w') && b[i + 1].eq_ignore_ascii_case(&b'p') {
            let d = digits_at(b, i + 2);
            (d > 0).then_some(2 + d)
        } else {
            None
        }
    });
    for w in ["img", "dsc", "pxl", "mvimg", "screenshot", "photo", "image"] {
        t = strip_matches(&t, |b, i| word_num_at(b, i, w));
    }
    t = strip_matches(&t, |b, i| {
        let d = digits_at(b, i);
        (d >= 2).then_some(d)
    });
    let t = collapse_ws(&t);
    let t = t.trim().trim_start_matches(['-', '_', ' ']).trim_end_matches(['-', '_', ' ']);
    cut(t, 160)
}

fn normalize_tags_list(items: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for raw in items {
        let t = raw.trim().to_lowercase().split_whitespace().collect::<Vec<_>>().join("-");
        let t: String = t.chars().filter(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "_.-".contains(*c)).collect();
        let t = cut(&t, 32);
        if !t.is_empty() && !STOP_TAGS.contains(&t.as_str()) && t.len() >= 2 && !out.contains(&t) && !is_noise_token(&t) {
            out.push(t);
            if out.len() >= 12 {
                break;
            }
        }
    }
    out
}

fn tags_from_value(v: Option<&Value>) -> Vec<String> {
    match v {
        Some(Value::String(s)) => s.split(|c: char| c == ',' || c == '#' || c.is_whitespace()).filter(|t| !t.is_empty()).map(str::to_string).collect(),
        Some(Value::Array(a)) => a.iter().filter_map(|x| crate::util::vstr(Some(x))).collect(),
        _ => vec![],
    }
}

fn merge_tags(primary: &[String], secondary: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for raw in primary.iter().chain(secondary) {
        for t in normalize_tags_list(std::slice::from_ref(raw)) {
            if !out.contains(&t) {
                out.push(t);
                if out.len() >= 12 {
                    return out;
                }
            }
        }
    }
    out
}

/// classification.clean_tokens: [a-z0-9]{2,} runs.
pub fn clean_tokens(parts: &[&str]) -> Vec<String> {
    let raw = parts.iter().filter(|p| !p.is_empty()).map(|p| p.to_lowercase()).collect::<Vec<_>>().join(" ");
    raw.split(|c: char| !c.is_ascii_alphanumeric()).filter(|t| t.len() >= 2).map(str::to_string).collect()
}

fn normalize_tokens(v: &str) -> Vec<String> {
    clean_tokens(&[v]).into_iter().filter(|t| !STOP_TAGS.contains(&t.as_str()) && t.len() >= 3 && !is_noise_token(t)).collect()
}

fn normalize_sub_names(values: &[String], primary: Option<&str>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for raw in primary.into_iter().map(str::to_string).chain(values.iter().cloned()) {
        if let Some(c) = clean_label(Some(&raw)) {
            if !out.iter().any(|o| o.to_lowercase() == c.to_lowercase()) {
                out.push(c);
                if out.len() >= MAX_SUBS {
                    break;
                }
            }
        }
    }
    out
}

fn sanitize_sub_names(values: Option<&Value>, primary: Option<&str>, category: Option<&str>) -> Vec<String> {
    let mut raw: Vec<String> = match values {
        Some(Value::String(s)) => vec![s.clone()],
        Some(Value::Array(a)) => a.iter().filter_map(|x| crate::util::vstr(Some(x))).collect(),
        _ => vec![],
    };
    if let Some(p) = primary {
        raw.push(p.to_string());
    }
    let names = normalize_sub_names(&raw, None);
    let mut blocked: HashSet<String> = GENERIC_SUB_LABELS.iter().map(|l| compact_label(l)).collect();
    blocked.insert(compact_label(category.unwrap_or("")));
    let mut out: Vec<String> = Vec::new();
    let mut seen = HashSet::new();
    for n in names {
        let c = compact_label(&n);
        if !c.is_empty() && !blocked.contains(&c) && seen.insert(c) {
            out.push(n);
            if out.len() >= MAX_SUBS {
                break;
            }
        }
    }
    out
}

fn stem_of(filename: &str) -> String {
    let base = filename.rsplit(['/', '\\']).next().unwrap_or(filename);
    match base.rfind('.') {
        Some(i) if i > 0 || base.len() > 1 => base[..i].to_string(),
        _ => base.to_string(),
    }
}

pub fn is_low_signal_filename(filename: &str) -> bool {
    let stem = stem_of(filename).trim().to_string();
    if stem.is_empty() {
        return true;
    }
    let low = stem.to_lowercase();
    let compact: String = low.chars().filter(char::is_ascii_alphanumeric).collect();
    for p in ["img", "dsc", "pxl", "mvimg", "screenshot", "image", "photo", "video", "scan", "untitled", "temp", "whatsapp image", "snapchat", "signal"] {
        if let Some(rest) = low.strip_prefix(p) {
            let rest = rest.trim_start_matches([' ', '_', '-']);
            if rest.is_empty() || is_digits(rest) {
                return true;
            }
        }
    }
    (is_hex(&compact) && compact.len() >= 8) || (is_digits(&compact) && compact.len() >= 2) || (low.len() >= 16 && low.chars().all(|c| c.is_ascii_hexdigit() || c == '-'))
}

fn is_generic_title(v: &str) -> bool {
    let original = collapse_ws(v);
    let cleaned = clean_title(&original);
    if original.is_empty() || cleaned.is_empty() || is_noise_token(&original) || is_noise_token(&cleaned) {
        return true;
    }
    let low = cleaned.to_lowercase();
    if GENERIC_TITLE_PHRASES.contains(&low.as_str()) || matches!(low.as_str(), "desktop backgrounds" | "phone backgrounds" | "wallpapers") {
        return true;
    }
    let meaningful: Vec<&str> = low.split_whitespace().filter(|p| !STOP_TAGS.contains(p) && !is_noise_token(p)).collect();
    if meaningful.is_empty() {
        return true;
    }
    const GENERIC_SUBJECT: &[&str] = &[
        "media", "upload", "background", "backgrounds", "wallpaper", "wallpapers", "image", "images", "photo", "photos", "picture", "pictures", "profile", "art", "artwork", "render", "renders", "edit",
        "edits", "graphic", "graphics", "illustration", "portrait", "landscape", "desktop", "phone", "uncategorized",
    ];
    meaningful.len() == 1 && GENERIC_SUBJECT.contains(&meaningful[0])
}

fn title_is_category(title: &str, cat: Option<&str>, sub: Option<&str>) -> bool {
    let ct = compact_label(title);
    if ct.is_empty() {
        return true;
    }
    let c = cat.unwrap_or("");
    let mut blocked: HashSet<String> = [compact_label(c), compact_label(sub.unwrap_or("")), compact_label(&c.replace("Backgrounds", "Background")), compact_label(&c.replace("Pictures", "Picture"))].into_iter().collect();
    for b in ["phonebackground", "phonebackgrounds", "desktopbackground", "desktopbackgrounds", "profile", "profilepicture", "profilepictures", "wallpaper", "wallpapers", "background", "backgrounds", "image", "images", "artwork", "media"] {
        blocked.insert(b.into());
    }
    blocked.remove("");
    blocked.contains(&ct)
}

fn is_bad_subject_title(t: &str, cat: Option<&str>, sub: Option<&str>) -> bool {
    is_generic_title(t) || title_is_category(t, cat, sub)
}

fn category_suffix(cat: Option<&str>, kind: &str) -> &'static str {
    match cat {
        Some("Phone Backgrounds") => "Phone Background",
        Some("Desktop Backgrounds") => "Desktop Background",
        Some("Wallpapers") => "Wallpaper",
        Some("Profile Pictures") => "Profile Picture",
        _ if kind == "video" => "Video",
        _ => "Artwork",
    }
}

fn pretty_tag(tag: &str) -> String {
    let text = tag.replace(['_', '-'], " ");
    let words: Vec<&str> = text.split_whitespace().filter(|w| !STOP_TAGS.contains(w) && !is_noise_token(w)).collect();
    words
        .iter()
        .map(|w| {
            if ["mlp", "fnaf", "kpop", "vr", "sfm", "eqg", "ai", "4k"].contains(&w.to_lowercase().as_str()) {
                w.to_uppercase()
            } else {
                let mut c = w.chars();
                c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn filename_subject_text(filename: &str) -> String {
    let mut stem = stem_of(filename);
    if stem.is_empty() {
        return String::new();
    }
    // trailing __<hex8+>
    if let Some(i) = stem.rfind("__") {
        if stem[i + 2..].len() >= 8 && is_hex(&stem[i + 2..]) {
            stem.truncate(i);
        }
    }
    let ci_replace = |s: &str, pat: &str| -> String {
        let low = s.to_lowercase();
        let mut out = String::new();
        let mut i = 0;
        while i < s.len() {
            if low[i..].starts_with(pat) {
                out.push(' ');
                i += pat.len();
            } else {
                let ch = s[i..].chars().next().unwrap();
                out.push(ch);
                i += ch.len_utf8();
            }
        }
        out
    };
    for pat in ["ai_enhanced", "ai-enhanced", "ai enhanced", "aienhanced", "upscayl", "upscaled", "compressed", "final", "fullview"] {
        stem = ci_replace(&stem, pat);
    }
    stem = strip_matches(&stem, res_at);
    stem = strip_matches(&stem, |b, i| {
        let a = digits_at(b, i);
        ((3..=4).contains(&a) && b.get(i + a) == Some(&b'p')).then_some(a + 1)
    });
    stem = strip_matches(&stem, |b, i| ((b[i] == b'4' || b[i] == b'8') && b.get(i + 1) == Some(&b'k')).then_some(2));
    let low = stem.to_lowercase();
    let cutpos = ["_by_", "-by-", " by "].iter().filter_map(|p| low.find(p)).min();
    if let Some(p) = cutpos {
        stem.truncate(p);
    }
    let cleaned = collapse_ws(&stem.chars().map(|c| if c.is_alphanumeric() { c } else { ' ' }).collect::<String>());
    let compact: String = cleaned.to_lowercase().chars().filter(char::is_ascii_alphanumeric).collect();
    if cleaned.is_empty() || is_low_signal_filename(&cleaned) || (is_hex(&compact) && compact.len() >= 8) {
        return String::new();
    }
    cleaned
}

fn compose_specific_title(title: &str, filename: &str, cat: Option<&str>, sub: Option<&str>, tags: &[String], kind: &str) -> String {
    let ct = clean_title(title);
    if !ct.is_empty() && !is_bad_subject_title(&ct, cat, sub) {
        return cut(&ct, 160);
    }
    if let Some(s) = clean_label(sub).filter(|s| !is_bad_subject_title(s, cat, None)) {
        return cut(&format!("{s} {}", category_suffix(cat, kind)), 160);
    }
    let mut generic: HashSet<String> = [
        "landscape", "portrait", "square", "1080p", "1440p", "4k", "video", "gif", "profile", "profiles", "picture", "pictures", "desktop", "phone", "background", "backgrounds", "wallpaper",
        "wallpapers",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    generic.extend(normalize_tokens(cat.unwrap_or("")));
    generic.extend(normalize_tokens(sub.unwrap_or("")));
    let mut preferred: Vec<String> = Vec::new();
    for t in tags {
        if !generic.contains(t) {
            let p = pretty_tag(t);
            let pl = p.to_lowercase();
            if !p.is_empty() && !["background", "backgrounds", "wallpaper", "wallpapers", "desktop", "phone"].contains(&pl.as_str()) && !preferred.iter().any(|x| x.to_lowercase() == pl) {
                preferred.push(p);
            }
        }
        if preferred.len() >= 2 {
            break;
        }
    }
    let suffix = category_suffix(cat, kind);
    if preferred.len() >= 2 {
        let subject = format!(" {} ", filename_subject_text(filename).to_lowercase().split(|c: char| !c.is_ascii_alphanumeric()).filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" "));
        let pair = format!(" {} {} ", preferred[0].to_lowercase(), preferred[1].to_lowercase());
        let t = if subject.contains(&pair) { format!("{} {} {suffix}", preferred[0], preferred[1]) } else { format!("{} and {} {suffix}", preferred[0], preferred[1]) };
        return cut(&t, 160);
    }
    if let Some(p) = preferred.first() {
        return cut(&format!("{p} {suffix}"), 160);
    }
    if matches!(cat, Some("Phone Backgrounds" | "Desktop Backgrounds" | "Wallpapers" | "Profile Pictures")) {
        return cut(&format!("Uncategorized {suffix}"), 160);
    }
    let mut fallback = cat.map(str::to_string).unwrap_or_else(|| if kind == "video" { "Video".into() } else { "Media".into() });
    if title_is_category(&fallback, cat, sub) {
        fallback = "Media".into();
    }
    cut(&format!("Uncategorized {fallback}"), 160)
}

fn looks_adult(title: &str, desc: &str, tags: &[String], filename: &str, mime: &str) -> bool {
    let combined = [title, desc, &tags.join(" "), filename, mime].join(" ").to_lowercase();
    let norm = format!(" {} ", combined.split(|c: char| !(c.is_ascii_lowercase() || c.is_ascii_digit() || c == '+')).filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" "));
    ["18plus", "18+", "adult", "nsfw", "not safe for work", "nude", "nudity", "explicit", "porn", "porno", "sex", "sexual", "hentai", "ecchi", "lewd", "erotic", "fetish", "onlyfans", "xxx"]
        .iter()
        .any(|w| norm.contains(&format!(" {w} ")))
}

fn slug_dash(s: &str) -> String {
    let mut out = String::new();
    for c in s.to_lowercase().chars() {
        if c.is_ascii_lowercase() || c.is_ascii_digit() {
            out.push(c);
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    out.trim_matches('-').to_string()
}

fn suggest_filename(title: &str, source: &str, mime: &str, cat: Option<&str>, sub: Option<&str>, base: &str) -> String {
    let file = source.rsplit(['/', '\\']).next().unwrap_or(source);
    let mut suffix = file.rfind('.').map(|i| file[i..].to_lowercase()).filter(|s| !s[1..].contains(['/', '\\'])).unwrap_or_default();
    if suffix.is_empty() {
        suffix = match mime {
            "image/jpeg" => ".jpg",
            "image/png" => ".png",
            "image/webp" => ".webp",
            "image/gif" => ".gif",
            "video/mp4" => ".mp4",
            _ => "",
        }
        .into();
    }
    if suffix == ".jpe" {
        suffix = ".jpg".into();
    }
    let mut base = base.to_string();
    if base.is_empty() {
        let stem = stem_of(source);
        let seed = [Some(title), sub, cat].into_iter().flatten().find(|s| !s.is_empty()).map(str::to_string).unwrap_or_else(|| if stem.is_empty() { "media".into() } else { stem.clone() });
        base = slug_dash(&seed);
    }
    if base.is_empty() {
        base = "media".into();
    }
    if is_low_signal_filename(source) && matches!(base.as_str(), "imported-media" | "media" | "upload") {
        let stem = cut(&stem_of(source), 8).to_lowercase();
        base = format!("{base}-{stem}").trim_matches('-').to_string();
    }
    format!("{}{suffix}", cut(&base, 90))
}

fn title_case_words(s: &str) -> String {
    s.replace('_', " ")
        .split(' ')
        .map(|w| {
            let mut c = w.chars();
            match c.next() {
                Some(f) if f.is_ascii_alphabetic() => f.to_uppercase().collect::<String>() + c.as_str(),
                Some(f) => f.to_string() + c.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn join_names(n: &[String]) -> String {
    match n.len() {
        0 => String::new(),
        1 => n[0].clone(),
        2 => format!("{} and {}", n[0], n[1]),
        3 => format!("{}, {} and {}", n[0], n[1], n[2]),
        _ => format!("{}, {}, {} and others", n[0], n[1], n[2]),
    }
}

struct Booru {
    characters: Vec<String>,
    series: Vec<String>,
    artist: Option<String>,
    known: bool,
}

fn parse_booru(filename: &str) -> Option<Booru> {
    let mut stem = stem_of(filename).to_lowercase();
    if !((stem.starts_with("__") && stem[2..].contains("__")) || stem.contains("_drawn_by_")) {
        return None;
    }
    stem = stem.trim_start_matches('_').to_string();
    if let Some(i) = stem.find("__") {
        stem.truncate(i);
    }
    let mut artist = None;
    if let Some(i) = stem.find("_drawn_by_") {
        artist = Some(stem[i + 10..].to_string());
        stem.truncate(i);
    }
    // "_and_N_more"
    while let Some(i) = stem.find("_and_") {
        let rest = &stem[i + 5..];
        let d = rest.chars().take_while(char::is_ascii_digit).count();
        if d > 0 && rest[d..].starts_with("_more") {
            stem.replace_range(i..i + 5 + d + 5, "");
        } else {
            break;
        }
    }
    let mut stem = format!("_{stem}_");
    let (mut series, mut seen_series): (Vec<String>, HashSet<String>) = (vec![], HashSet::new());
    let mut peeled = true;
    while peeled {
        peeled = false;
        for key in COPY_KEYS.iter() {
            let suffix = format!("_{key}_");
            if stem.len() > suffix.len() && stem.ends_with(&suffix) {
                if let Some(Some(display)) = BOORU_COPYRIGHTS.iter().find(|c| c.0 == *key).map(|c| c.1) {
                    if seen_series.insert(display.to_string()) {
                        series.insert(0, display.to_string());
                    }
                }
                stem.truncate(stem.len() - suffix.len() + 1);
                peeled = true;
                break;
            }
        }
    }
    let mut chars: Vec<String> = Vec::new();
    let mut known = false;
    let add = |chars: &mut Vec<String>, n: String| {
        if !n.is_empty() && !chars.iter().any(|c| c.to_lowercase() == n.to_lowercase()) {
            chars.push(n);
        }
    };
    let mut rest = stem.trim_matches('_').to_string();
    let mut pending: Vec<String> = Vec::new();
    let flush = |pending: &mut Vec<String>, chars: &mut Vec<String>| {
        if !pending.is_empty() {
            let phrase = pending.join("_");
            for part in format!("{phrase}_and_").split("_and_") {
                if !part.is_empty() && !is_digits(part) {
                    add(chars, title_case_words(part));
                }
            }
            pending.clear();
        }
    };
    while !rest.is_empty() {
        let mut matched = false;
        for key in CHAR_KEYS.iter() {
            if rest == *key || rest.starts_with(&format!("{key}_")) {
                flush(&mut pending, &mut chars);
                let entry = BOORU_CHARACTERS.iter().find(|c| c.0 == *key).unwrap();
                add(&mut chars, entry.1.to_string());
                if let Some(s) = entry.2 {
                    if seen_series.insert(s.to_string()) {
                        series.push(s.to_string());
                    }
                }
                known = true;
                rest = rest.get(key.len() + 1..).unwrap_or("").to_string();
                matched = true;
                break;
            }
        }
        if !matched {
            let (word, after) = rest.split_once('_').map(|(a, b)| (a.to_string(), b.to_string())).unwrap_or((rest.clone(), String::new()));
            if word == "and" {
                flush(&mut pending, &mut chars);
            } else {
                pending.push(word);
            }
            rest = after;
        }
    }
    flush(&mut pending, &mut chars);
    if chars.is_empty() && series.is_empty() {
        return None;
    }
    let known = known || !series.is_empty();
    Some(Booru { characters: chars, series, artist: artist.map(|a| a.replace('_', " ")), known })
}

fn booru_tags(b: &Booru) -> Vec<String> {
    b.characters.iter().chain(&b.series).map(|s| slug_dash(s)).collect()
}

// ---- classification.lua ---------------------------------------------------------------------------
pub fn canonical_pair(cat: Option<&str>, sub: Option<&str>) -> (Option<String>, Option<String>) {
    let main = cut(&collapse_ws(cat.unwrap_or("")), 80);
    let sub = cut(&collapse_ws(sub.unwrap_or("")), 80);
    let sub = (!sub.is_empty()).then_some(sub);
    if main.is_empty() {
        return (None, sub);
    }
    let mapped = match main.as_str() {
        "Aria Blaze (Solo)" => Some(("My Little Pony", "Aria Blaze")),
        "Sonata Dusk" => Some(("My Little Pony", "Sonata Dusk")),
        "Dazzlings" => Some(("My Little Pony", "Dazzlings")),
        "My Little Pony (Fluttershy)" => Some(("My Little Pony", "Fluttershy")),
        "My Little Pony (Mane 6)" => Some(("My Little Pony", "Mane 6")),
        "My Little Pony (Equestria Girls)" => Some(("My Little Pony", "Equestria Girls")),
        "KPOP Demon Hunters (Huntrix)" => Some(("KPOP Demon Hunters", "Huntrix")),
        "KPOP Demon Hunters (Mira)" => Some(("KPOP Demon Hunters", "Mira")),
        "Resident Evil (Leon)" => Some(("Resident Evil", "Leon")),
        "Final Fantasy (Cloud)" => Some(("Final Fantasy", "Cloud Strife")),
        _ => None,
    };
    match mapped {
        Some((a, b)) => (Some(a.into()), Some(b.into())),
        None => (Some(main), sub),
    }
}

pub fn infer_category(filename: &str, kind: &str, title: &str, size: Option<(i64, i64)>) -> (Option<String>, Option<String>) {
    let tokens: HashSet<String> = clean_tokens(&[&stem_of(filename).to_lowercase(), title]).into_iter().collect();
    let has = |set: &[&str]| set.iter().any(|t| tokens.contains(*t));
    let all = |set: &[&str]| set.iter().all(|t| tokens.contains(*t));
    let single = |m: &[(&str, &[&str])]| m.iter().find(|(_, s)| has(s)).map(|(n, _)| n.to_string());
    let hits = |m: &[(&str, &[&str])]| m.iter().filter(|(_, s)| has(s)).map(|(n, _)| n.to_string()).collect::<Vec<_>>();
    let one_or_none = |h: Vec<String>| if h.len() > 1 { None } else { h.into_iter().next() };
    let s = |a: &str| Some(a.to_string());
    const MLP: &[&str] = &["mlp", "pony", "ponies", "equestria", "rainbooms", "mane", "cutie", "cmc", "twilight", "pinkie", "fluttershy", "rarity", "applejack", "scootaloo", "rainbow", "dash", "derpy", "sunset", "starlight", "trixie", "celestia", "luna", "discord", "spike"];
    const DAZZ: &[&str] = &["dazzlings", "adagio", "aria", "sonata"];
    const FNAF: &[&str] = &["fnaf", "freddy", "bonnie", "chica", "foxy", "roxanne", "roxy", "fazbear", "animatronic", "frenni", "bonfie"];
    const NEP: &[&str] = &["neptunia", "neptune", "nepgear", "noire", "blanc", "vert", "uzume", "plutia"];
    const XENO: &[&str] = &["xenoblade", "pyra", "mythra", "nia", "mio", "eunie", "taion", "lanz", "noah"];
    const SONIC: &[&str] = &["sonic", "tails", "amy", "shadow", "knuckles", "rouge"];
    const RE: &[&str] = &["resident", "evil", "leon", "ada", "jill", "claire", "wesker", "ashley"];
    const FF: &[&str] = &["final", "fantasy", "cloud", "strife", "tifa", "aerith", "sephiroth", "ff7", "ffvii"];
    const KPOP: &[&str] = &["kpop", "demon", "hunters", "huntrix", "mira", "zoey", "rumi"];
    let mlp_subs: &[(&str, &[&str])] = &[
        ("Aria Blaze", &["aria"]), ("Sonata Dusk", &["sonata"]), ("Adagio Dazzle", &["adagio"]), ("Fluttershy", &["fluttershy", "flutter", "fluttertone", "flutterwitch", "flutterfrolic", "appleshy"]),
        ("Twilight Sparkle", &["twilight", "twilights"]), ("Rainbow Dash", &["dashie", "rainbowdash"]), ("Pinkie Pie", &["pinkie"]), ("Rarity", &["rarity"]), ("Applejack", &["applejack"]),
        ("Sunset Shimmer", &["sunset"]), ("Starlight Glimmer", &["starlight"]), ("Scootaloo", &["scootaloo"]), ("Derpy", &["derpy"]), ("Trixie", &["trixie"]), ("Princess Celestia", &["celestia"]),
        ("Princess Luna", &["luna"]), ("Discord", &["discord"]), ("Spike", &["spike"]),
    ];
    let sonic_subs: &[(&str, &[&str])] = &[("Sonic", &["sonic"]), ("Shadow", &["shadow"]), ("Amy", &["amy"]), ("Tails", &["tails"]), ("Knuckles", &["knuckles"]), ("Rouge", &["rouge"])];
    let ext = filename.rsplit(['/', '\\']).next().unwrap_or("").rfind('.').map(|i| filename.rsplit(['/', '\\']).next().unwrap()[i..].to_lowercase()).unwrap_or_default();
    if ext == ".gif" {
        return (s("GIFs"), None);
    }
    if has(KPOP) {
        return (s("KPOP Demon Hunters"), single(&[("Huntrix", &["huntrix"]), ("Mira", &["mira"]), ("Zoey", &["zoey"]), ("Rumi", &["rumi"])]));
    }
    if has(RE) {
        return (s("Resident Evil"), single(&[("Leon", &["leon"]), ("Ada Wong", &["ada"]), ("Jill Valentine", &["jill"]), ("Claire Redfield", &["claire"]), ("Albert Wesker", &["wesker"]), ("Ashley Graham", &["ashley"])]));
    }
    if has(FF) {
        return (s("Final Fantasy"), single(&[("Cloud Strife", &["cloud", "strife"]), ("Tifa Lockhart", &["tifa"]), ("Aerith Gainsborough", &["aerith"]), ("Sephiroth", &["sephiroth"])]));
    }
    if has(NEP) {
        return (s("Hyperdimension Neptunia"), one_or_none(hits(&[("Neptune", &["neptune"]), ("Nepgear", &["nepgear"]), ("Noire", &["noire"]), ("Blanc", &["blanc"]), ("Vert", &["vert"]), ("Uzume", &["uzume"]), ("Plutia", &["plutia"])])));
    }
    if has(XENO) {
        return (s("Xenoblade"), one_or_none(hits(&[("Pyra", &["pyra"]), ("Mythra", &["mythra"]), ("Nia", &["nia"]), ("Mio", &["mio"]), ("Eunie", &["eunie"]), ("Taion", &["taion"]), ("Lanz", &["lanz"]), ("Noah", &["noah"])])));
    }
    if has(FNAF) {
        return (s("FNAF"), one_or_none(hits(&[("Freddy", &["freddy"]), ("Bonnie", &["bonnie", "bonfie"]), ("Chica", &["chica"]), ("Foxy", &["foxy"]), ("Frenni", &["frenni"]), ("Roxanne Wolf", &["roxanne", "roxy"])])));
    }
    if has(SONIC) && has(MLP) {
        return (s("Crossovers"), single(sonic_subs).or_else(|| single(mlp_subs)));
    }
    if has(MLP) || has(DAZZ) {
        let mut dh = vec![];
        if tokens.contains("aria") {
            dh.push("Aria Blaze");
        }
        if tokens.contains("sonata") {
            dh.push("Sonata Dusk");
        }
        if tokens.contains("adagio") {
            dh.push("Adagio Dazzle");
        }
        let mlp = s("My Little Pony");
        if has(DAZZ) {
            if dh.len() > 1 || tokens.contains("dazzlings") {
                return (mlp, s("Dazzlings"));
            }
            if let Some(h) = dh.first() {
                return (mlp, s(h));
            }
        }
        if all(&["equestria", "girls"]) || all(&["equestrian", "girls"]) || tokens.contains("eqg") || all(&["rainbow", "rocks"]) || all(&["crystal", "prep"]) {
            return (mlp, s(if dh.is_empty() { "Equestria Girls" } else { "Dazzlings" }));
        }
        let mut ch: Vec<String> = vec![];
        if (all(&["rainbow", "dash"]) || tokens.contains("dashie") || tokens.contains("rainbowdash") || tokens.contains("dash")) && !all(&["rainbow", "rocks"]) {
            ch.push("Rainbow Dash".into());
        }
        for (n, set) in mlp_subs {
            if *n != "Rainbow Dash" && has(set) {
                ch.push(n.to_string());
            }
        }
        if all(&["cutie", "mark", "crusaders"]) || tokens.contains("crusaders") || tokens.contains("cmc") {
            return (mlp, s("Cutie Mark Crusaders"));
        }
        if all(&["mane", "6"]) || all(&["mane", "six"]) {
            return (mlp, s("Mane 6"));
        }
        let core = ["Fluttershy", "Twilight Sparkle", "Rainbow Dash", "Pinkie Pie", "Rarity", "Applejack"];
        let core_hits: HashSet<&String> = ch.iter().filter(|h| core.contains(&h.as_str())).collect();
        if core_hits.len() >= 2 {
            return (mlp, s("Mane 6"));
        }
        let mut uniq: Vec<String> = vec![];
        for h in ch {
            if !uniq.contains(&h) {
                uniq.push(h);
            }
        }
        return (mlp, if uniq.len() == 1 { uniq.into_iter().next() } else { None });
    }
    if has(SONIC) {
        return (s("Sonic"), single(sonic_subs));
    }
    if has(&["boondocks", "cartoon", "anime"]) {
        return (s("Cartoon"), None);
    }
    if has(&["meme", "memes", "funny", "reaction"]) {
        return (s("Memes"), None);
    }
    if let Some((w, h)) = size.filter(|(w, h)| *w > 0 && *h > 0) {
        let r = w as f64 / h.max(1) as f64;
        if (0.9..=1.1).contains(&r) && w.max(h) <= 2048 {
            return (s("Profile Pictures"), None);
        } else if r < 0.85 {
            return (s("Phone Backgrounds"), None);
        } else if r >= 1.2 {
            return (s("Desktop Backgrounds"), None);
        }
    }
    if kind == "video" {
        return (s("Videos"), None);
    }
    (s("Wallpapers"), None)
}

// ---- analyses --------------------------------------------------------------------------------------
#[derive(Clone, Debug, Default)]
pub struct Analysis {
    pub title: String,
    pub suggested_filename: String,
    pub tags: Vec<String>,
    pub category_name: Option<String>,
    pub subcategory_name: Option<String>,
    pub subcategory_names: Vec<String>,
    pub is_adult: bool,
    pub source: String,
    pub confidence: f64,
    pub reason: Option<String>,
    pub description: Option<String>,
}

impl Analysis {
    pub fn to_json(&self) -> Value {
        let mut v = json!({
            "title": self.title,
            "suggested_filename": self.suggested_filename,
            "tags": self.tags,
            "subcategory_names": self.subcategory_names,
            "is_adult": self.is_adult,
            "source": self.source,
            "confidence": self.confidence,
        });
        for (k, o) in [("category_name", &self.category_name), ("subcategory_name", &self.subcategory_name), ("reason", &self.reason), ("description", &self.description)] {
            if let Some(x) = o {
                v[k] = json!(x);
            }
        }
        v
    }
}

fn build_tags(filename: &str, title: &str, desc: &str, cat: Option<&str>, sub: Option<&str>, kind: &str, size: Option<(i64, i64)>, hint: &[String]) -> Vec<String> {
    let mut t: Vec<String> = Vec::new();
    t.extend(normalize_tokens(cat.unwrap_or("")));
    t.extend(normalize_tokens(sub.unwrap_or("")));
    if kind == "video" {
        t.push("video".into());
    }
    if filename.to_lowercase().ends_with(".gif") {
        t.push("gif".into());
    }
    if let Some((w, h)) = size {
        t.push(if w > h { "landscape" } else if h > w { "portrait" } else { "square" }.into());
        if w >= 3840 || h >= 2160 {
            t.push("4k".into());
        } else if w >= 2560 || h >= 1440 {
            t.push("1440p".into());
        } else if w >= 1920 || h >= 1080 {
            t.push("1080p".into());
        }
    }
    for v in [title.to_string(), desc.to_string(), filename_subject_text(filename)] {
        t.extend(normalize_tokens(&v));
    }
    t.extend(normalize_tags_list(hint));
    merge_tags(&t, &[])
}

pub fn heuristic(filename: &str, mime: &str, kind: &str, title_hint: &str, desc_hint: &str, tags_hint: &[String], size: Option<(i64, i64)>) -> Analysis {
    let hint_title = clean_title(title_hint);
    let (ic, is) = infer_category(filename, kind, if hint_title.is_empty() { filename } else { &hint_title }, size);
    let (cat, sub) = canonical_pair(ic.as_deref(), is.as_deref());
    let mut tags = build_tags(filename, &hint_title, desc_hint, cat.as_deref(), sub.as_deref(), kind, size, tags_hint);
    let booru = parse_booru(filename);
    let mut confidence = 0.45;
    let mut sub_names = None;
    let title = if !hint_title.is_empty() && !is_bad_subject_title(&hint_title, cat.as_deref(), sub.as_deref()) {
        hint_title.clone()
    } else if let Some(b) = booru.as_ref().filter(|b| !b.characters.is_empty()) {
        let mut t = format!("{} — {}", join_names(&b.characters), category_suffix(cat.as_deref(), kind));
        if let Some(a) = b.artist.as_ref().filter(|a| !a.is_empty()) {
            t = format!("{t} by {a}");
        }
        let keep: Vec<String> = tags.iter().filter(|t| ["landscape", "portrait", "square", "4k", "1440p", "1080p", "video", "gif"].contains(&t.as_str())).cloned().collect();
        tags = merge_tags(&booru_tags(b), &merge_tags(&keep, &normalize_tags_list(tags_hint)));
        if b.known {
            confidence = 0.62;
            let home = BOORU_CHARACTERS.iter().find(|c| Some(c.1) == b.characters.first().map(String::as_str) && c.2.is_some()).and_then(|c| c.2).map(str::to_string);
            let first = home.or_else(|| b.series.first().cloned());
            sub_names = Some(normalize_sub_names(&[first, b.characters.first().cloned()].into_iter().flatten().collect::<Vec<_>>(), None));
        }
        cut(&t, 160)
    } else {
        compose_specific_title("", filename, cat.as_deref(), sub.as_deref(), &tags, kind)
    };
    let suggested = suggest_filename(&title, filename, mime, cat.as_deref(), sub.as_deref(), "");
    Analysis {
        is_adult: looks_adult(&title, desc_hint, &tags, filename, mime),
        suggested_filename: suggested,
        subcategory_names: sub_names.unwrap_or_else(|| normalize_sub_names(&[], sub.as_deref())),
        source: if booru.as_ref().is_some_and(|b| b.known) { "booru-filename".into() } else { "heuristic".into() },
        title,
        tags,
        category_name: cat,
        subcategory_name: sub,
        confidence,
        reason: None,
        description: None,
    }
}

/// Raw (pre-merge) suggestion, from aliases or the model.
#[derive(Default, Clone)]
struct Suggestion {
    title: String,
    suggested_filename_base: String,
    tags: Vec<String>,
    category_name: Option<String>,
    subcategory_name: Option<String>,
    subcategory_names: Option<Value>,
    is_adult: bool,
    confidence: Option<f64>,
    reason: String,
    source: String,
    description: String,
}

fn domain_hint(filename: &str, title_hint: &str, desc_hint: &str, tags_hint: &[String], fallback: &Analysis) -> Option<Suggestion> {
    if fallback.source == "booru-filename" {
        return None;
    }
    let text = [filename_subject_text(filename), title_hint.into(), desc_hint.into(), tags_hint.join(" ")].join(" ").to_lowercase();
    let text = format!(" {} ", text.split(|c: char| !(c.is_ascii_lowercase() || c.is_ascii_digit())).filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" "));
    if text.trim().is_empty() {
        return None;
    }
    let mut matches: Vec<Alias> = ALIASES.iter().filter(|(k, _)| text.contains(&format!(" {} ", k.replace(['_', '-'], " ")))).map(|(_, a)| *a).collect();
    if text.contains(" aria ") && text.contains("dazzlings") {
        matches.push(alias("aria blaze"));
    }
    if text.contains(" adagio ") && text.contains("dazzlings") {
        matches.push(alias("adagio dazzle"));
    }
    if text.contains(" sonata ") && text.contains("dazzlings") {
        matches.push(alias("sonata dusk"));
    }
    if text.contains(" dashie ") {
        matches.push(alias("rainbow dash"));
    }
    if text.contains("kpop demon hunters") || text.contains("k pop demon hunters") {
        matches.push(("KPop Demon Hunters", "KPOP Demon Hunters", "Huntrix", &["kpop demon hunters", "huntrix"]));
    }
    if matches.is_empty() {
        return None;
    }
    let mut uniq: Vec<Alias> = vec![];
    for m in matches {
        if !uniq.iter().any(|u| u.0.to_lowercase() == m.0.to_lowercase()) {
            uniq.push(m);
            if uniq.len() >= 4 {
                break;
            }
        }
    }
    let names: Vec<String> = uniq.iter().map(|u| u.0.to_string()).collect();
    let mut sub = uniq[0].2.to_string();
    let mut sub_names = normalize_sub_names(&names, Some(&sub));
    let set: HashSet<&str> = names.iter().map(String::as_str).collect();
    let tags_of = |n: usize| uniq.iter().take(n).flat_map(|u| u.3.iter().map(|s| s.to_string())).collect::<Vec<_>>();
    let (title, tags) = if (set.contains("Aria Blaze") && set.contains("Adagio Dazzle") && set.contains("Sonata Dusk")) || set.contains("The Dazzlings") {
        sub = "Equestria Girls".into();
        sub_names = normalize_sub_names(&["Aria Blaze".into(), "Adagio Dazzle".into()], Some(&sub));
        ("The Dazzlings".to_string(), ["the dazzlings", "aria blaze", "adagio dazzle", "sonata dusk", "mlp", "equestria girls"].iter().map(|s| s.to_string()).collect())
    } else if names.len() > 2 {
        (format!("{}, {}, and {} more", names[0], names[1], names.len() - 2), tags_of(6))
    } else if names.len() == 2 {
        (format!("{} and {}", names[0], names[1]), tags_of(4))
    } else {
        (names[0].clone(), tags_of(1))
    };
    Some(Suggestion {
        title,
        tags,
        category_name: Some(uniq[0].1.to_string()),
        subcategory_name: Some(sub),
        subcategory_names: Some(json!(sub_names)),
        is_adult: fallback.is_adult,
        confidence: Some(0.66),
        reason: "Matched a known franchise/character alias from user-provided metadata hints.".into(),
        source: "domain-hint".into(),
        ..Default::default()
    })
}

fn merge(ai: &Suggestion, fb: &Analysis, filename: &str, mime: &str, kind: &str, provider: &str) -> Analysis {
    let conf = ai.confidence.map(|c| c.clamp(0.0, 1.0)).unwrap_or(fb.confidence);
    let ai_title = clean_title(&ai.title);
    let ai_cat = clean_label(ai.category_name.as_deref());
    let ai_sub = clean_label(ai.subcategory_name.as_deref());
    let ai_subs = sanitize_sub_names(ai.subcategory_names.as_ref(), ai_sub.as_deref(), ai_cat.as_deref().or(fb.category_name.as_deref()));
    let (mut cat, mut sub) = canonical_pair(ai_cat.as_deref().or(fb.category_name.as_deref()), ai_sub.as_deref().or(fb.subcategory_name.as_deref()));
    let subs = if conf < 0.45 {
        cat = fb.category_name.clone();
        sub = fb.subcategory_name.clone();
        fb.subcategory_names.clone()
    } else {
        let s = sanitize_sub_names(Some(&json!(ai_subs)), sub.as_deref(), cat.as_deref());
        if s.is_empty() { fb.subcategory_names.clone() } else { s }
    };
    let mut tags = merge_tags(&normalize_tags_list(&ai.tags), &fb.tags);
    if tags.is_empty() {
        tags = fb.tags.clone();
    }
    let raw_title = if ai_title.is_empty() { fb.title.clone() } else { ai_title };
    let mut title = if is_bad_subject_title(&raw_title, cat.as_deref(), sub.as_deref()) { compose_specific_title(&raw_title, filename, cat.as_deref(), sub.as_deref(), &tags, kind) } else { raw_title };
    if is_bad_subject_title(&title, cat.as_deref(), sub.as_deref()) {
        title = compose_specific_title("", filename, cat.as_deref(), sub.as_deref(), &tags, kind);
    }
    let suggested = suggest_filename(&title, filename, mime, cat.as_deref(), sub.as_deref(), &clean_filename_base(&ai.suggested_filename_base));
    let inferred = clean_label(Some(&ai.source)).unwrap_or_default().to_lowercase();
    let source = if !inferred.is_empty() && conf >= 0.45 {
        inferred
    } else if provider == "gemini" && conf >= 0.45 {
        "google-gemini".into()
    } else {
        fb.source.clone()
    };
    let reason = cut(&collapse_ws(&ai.reason), 240);
    let desc = cut(ai.description.trim(), 500);
    Analysis {
        title,
        suggested_filename: suggested,
        tags,
        category_name: cat,
        subcategory_name: sub,
        subcategory_names: subs,
        is_adult: ai.is_adult || fb.is_adult,
        source,
        confidence: conf.max(if conf < 0.45 { fb.confidence } else { 0.0 }),
        reason: if reason.is_empty() { fb.reason.clone() } else { Some(reason) },
        description: (!desc.is_empty()).then_some(desc),
    }
}

// ---- Gemini -------------------------------------------------------------------------------------------
fn prompt_rules() -> &'static str {
    "Never use generic titles like Backgrounds, Wallpaper, Image, Art, or Artwork. Never use the filename, upload number, random code, or numeric ID as the title. \
     Make the title natural, short, and focused on the visible subject. Do not write a description paragraph inside the title or reason. \
     Create up to 12 short lowercase tags; skip generic wallpaper/background tags unless they add real search value. \
     Prefer existing gallery-style categories when they are clearly the best fit, especially Phone Backgrounds, Desktop Backgrounds, Profile Pictures, Wallpapers, GIFs, and Videos. \
     Use subcategories for franchise, series, character, form, or context beneath those broad categories. \
     If none of the established categories fits well enough, you may create one new concise category name. \
     You may also create new subcategory names when the visible subject is specific and reliable. \
     Do not invent brand-new taxonomy when the image is ambiguous or when a broader existing category is still clearly correct. \
     Use up to 3 ordered subcategories only when each one adds distinct value. \
     Order subcategories from broad to specific: series or group first, then character or subject, then variant, form, or context. \
     Do not repeat the main category as a subcategory. Do not guess names when identity is unclear; use visible traits instead. "
}

fn sanitize_error(raw: &str) -> String {
    let t = raw.trim();
    let text = match serde_json::from_str::<Value>(t) {
        Ok(v) if v["error"].is_object() => {
            let mut s = crate::util::vstr(v["error"].get("message")).unwrap_or_default();
            if let Some(st) = crate::util::vstr(v["error"].get("status")).filter(|s| !s.is_empty()) {
                s = format!("{s} status={st}");
            }
            s
        }
        Ok(v) if v.get("message").is_some() => crate::util::vstr(v.get("message")).unwrap_or_default(),
        _ => t.to_string(),
    };
    collapse_ws(&text)
}

fn safe_error(raw: &str) -> String {
    static RES: LazyLock<Vec<regex::Regex>> = LazyLock::new(|| {
        [r"[Bb]earer\s+\S+", r"sk-\S+", r"(?i)api[_-]?key[=:\s]+\S+", r"[Tt]oken[=:\s]+\S+", r"key=[A-Za-z0-9_\-]+"].iter().map(|p| regex::Regex::new(p).unwrap()).collect()
    });
    let mut t = sanitize_error(raw);
    for r in RES.iter() {
        t = r.replace_all(&t, "[REDACTED]").into_owned();
    }
    if t.is_empty() { "Unknown error".into() } else { t }
}

fn looks_placeholder(p: &Suggestion) -> bool {
    let title = clean_title(&p.title).to_lowercase();
    let reason = clean_title(&p.reason).to_lowercase();
    let cat = clean_label(p.category_name.as_deref()).unwrap_or_default().to_lowercase();
    let sub = clean_label(p.subcategory_name.as_deref()).unwrap_or_default().to_lowercase();
    let fb = clean_filename_base(&p.suggested_filename_base).to_lowercase();
    if ["string", "title"].contains(&title.as_str()) || ["string", "reason"].contains(&reason.as_str()) || ["string", "category", "category-name"].contains(&cat.as_str()) {
        return true;
    }
    if ["string", "subcategory", "subcategory-name"].contains(&sub.as_str()) || ["string", "filename", "suggested-filename", "suggested_filename"].contains(&fb.as_str()) {
        return true;
    }
    let subs = sanitize_sub_names(p.subcategory_names.as_ref(), p.subcategory_name.as_deref(), None);
    if !subs.is_empty() && subs.iter().all(|n| ["subcategory", "subcategories", "string", "subcategory-name"].contains(&n.to_lowercase().as_str())) {
        return true;
    }
    let tags = normalize_tags_list(&p.tags);
    !tags.is_empty() && tags.iter().all(|t| ["tag", "tags", "string"].contains(&t.as_str()))
}

fn parse_model_json(text: &str) -> Result<Suggestion, String> {
    let c = text.trim();
    if c.is_empty() {
        return Err("Gemini response did not include structured text.".into());
    }
    let mut cand = c.to_string();
    if let Some(i) = c.find("```") {
        let after = c[i + 3..].trim_start_matches("json");
        if let Some(j) = after.find("```") {
            cand = after[..j].trim().to_string();
        }
    }
    let v: Value = match serde_json::from_str::<Value>(&cand).ok().filter(Value::is_object) {
        Some(v) => v,
        None => {
            let (Some(a), Some(b)) = (cand.find('{'), cand.rfind('}')) else { return Err("Gemini returned invalid JSON.".into()) };
            serde_json::from_str::<Value>(&cand[a..=b]).ok().filter(Value::is_object).ok_or("Gemini returned invalid JSON.")?
        }
    };
    let s = |k: &str| crate::util::vstr(v.get(k));
    let mut sug = Suggestion {
        title: s("title").unwrap_or_default(),
        suggested_filename_base: s("suggested_filename_base").unwrap_or_default(),
        tags: tags_from_value(v.get("tags")),
        category_name: s("category_name"),
        subcategory_name: s("subcategory_name"),
        subcategory_names: None,
        is_adult: v.get("is_adult").and_then(Value::as_bool).unwrap_or(false),
        confidence: crate::util::vnum(v.get("confidence")),
        reason: s("reason").unwrap_or_default(),
        source: s("source").unwrap_or_default(),
        description: s("description").unwrap_or_default(),
    };
    let subs = sanitize_sub_names(v.get("subcategory_names"), sug.subcategory_name.as_deref(), sug.category_name.as_deref());
    if !subs.is_empty() && clean_label(sug.subcategory_name.as_deref()).is_none() {
        sug.subcategory_name = Some(subs[0].clone());
    } else if subs.is_empty() {
        sug.subcategory_name = None;
    }
    sug.subcategory_names = Some(json!(subs));
    if looks_placeholder(&sug) {
        return Err("Gemini returned placeholder schema values.".into());
    }
    Ok(sug)
}

struct GeminiOpts<'a> {
    preview_b64: String,
    filename: &'a str,
    mime: &'a str,
    kind: &'a str,
    title_hint: &'a str,
    desc_hint: &'a str,
    tags_hint: &'a [String],
    fallback: &'a Analysis,
    api_key: String,
    model: String,
    timeout: u64,
}

async fn gemini(http: &reqwest::Client, o: GeminiOpts<'_>) -> Result<Suggestion, String> {
    let guide = GUIDE.iter().map(|(g, n)| format!("{g}: {}", n.join(", "))).collect::<Vec<_>>().join(" | ");
    let hint = |s: &str| {
        let c = clean_title(s);
        if c.is_empty() { "(none)".to_string() } else { c }
    };
    let tags = normalize_tags_list(o.tags_hint);
    let prompt = format!(
        "You analyze media uploads for a personal gallery. Return JSON only. {}Identify visible characters, franchises, subjects, and backgrounds when evidence is strong. \
         Create tags for characters, franchises, moods, props, or setting only when they are reliable. Use this local recognition guide as hints, not proof: {guide}. \
         Prefer these main categories when they fit: {}. If it looks like a phone wallpaper use Phone Backgrounds and place the franchise or subject inside subcategories; \
         desktop wallpaper use Desktop Backgrounds and place the franchise or subject inside subcategories. \
         Write the description field as 1-2 natural sentences describing what's shown — character, scene, mood, or subject. \
         Do not mention AI, pipelines, gallery systems, or tools. Write as if describing the media to another person. \
         Return exactly this JSON schema: {{\"title\":\"string\",\"description\":\"1-2 sentence natural description of what's shown\",\"suggested_filename_base\":\"string\",\"tags\":[\"tag\"],\"category_name\":\"string\",\"subcategory_name\":\"string\",\"subcategory_names\":[\"string\"],\"is_adult\":false,\"confidence\":0.0,\"reason\":\"string\"}}\n\n\
         Filename: {}\nMIME type: {}\nMedia kind: {}\nExisting title hint: {}\nExisting description hint: {}\nExisting tags hint: {}\n\
         Local analyzer fallback title: {}\nLocal analyzer fallback category: {}\nLocal analyzer fallback subcategory: {}",
        prompt_rules(),
        KNOWN_CATEGORIES.join(", "),
        o.filename,
        o.mime,
        o.kind,
        hint(o.title_hint),
        hint(o.desc_hint),
        if tags.is_empty() { "(none)".into() } else { tags.join(", ") },
        o.fallback.title,
        o.fallback.category_name.as_deref().unwrap_or("Wallpapers"),
        o.fallback.subcategory_name.as_deref().unwrap_or("(none)"),
    );
    let body = json!({
        "contents": [{ "role": "user", "parts": [{ "text": prompt }, { "inline_data": { "mime_type": "image/jpeg", "data": o.preview_b64 } }] }],
        "generationConfig": { "temperature": 0.15, "responseMimeType": "application/json" },
    });
    let url = format!("https://generativelanguage.googleapis.com/v1beta/models/{}:generateContent?key={}", urlencoding::encode(&o.model), urlencoding::encode(&o.api_key));
    let mut last = String::new();
    for attempt in 0..3u32 {
        match http.post(&url).json(&body).timeout(std::time::Duration::from_secs(o.timeout)).send().await {
            Ok(r) => {
                let status = r.status().as_u16();
                let raw = r.text().await.unwrap_or_default();
                if (200..300).contains(&status) {
                    let data: Value = serde_json::from_str(&raw).map_err(|_| "Gemini response was not valid JSON.".to_string())?;
                    let parts = data["candidates"][0]["content"]["parts"].as_array().cloned().unwrap_or_default();
                    let text = parts.iter().filter_map(|p| p["text"].as_str()).map(str::trim).filter(|t| !t.is_empty()).collect::<Vec<_>>().join("\n");
                    if text.trim().is_empty() {
                        let block = data["promptFeedback"]["blockReason"].as_str().or(data["candidates"][0]["finishReason"].as_str()).unwrap_or("");
                        return Err(if block.is_empty() { "Gemini response did not include structured text.".into() } else { format!("Gemini response was blocked or empty: {block}") });
                    }
                    return parse_model_json(&text);
                }
                last = format!("Gemini API error {status}: {}", cut(&sanitize_error(&raw), 180));
                if status != 429 && status < 500 {
                    return Err(last);
                }
            }
            Err(e) => last = format!("Gemini API error nil: {e}"),
        }
        tokio::time::sleep(std::time::Duration::from_millis(800 * 2u64.pow(attempt))).await;
    }
    Err(last)
}

pub struct AnalyzeInput<'a> {
    pub file_path: &'a str,
    pub filename: &'a str,
    pub mime: &'a str,
    pub kind: &'a str,
    pub title_hint: &'a str,
    pub desc_hint: &'a str,
    pub tags_hint: &'a [String],
}

fn provider(s: &Settings) -> &'static str {
    let p = s.ai_provider.to_lowercase();
    if matches!(p.as_str(), "gemini" | "google" | "google-gemini") || (p.is_empty() && !s.ai_api_key.is_empty()) { "gemini" } else { "unsupported" }
}

pub async fn analyze(http: &reqwest::Client, s: &Settings, i: AnalyzeInput<'_>) -> Analysis {
    let size = crate::media_files::media_dimensions_from_path(i.file_path).await;
    let mut fb = heuristic(i.filename, i.mime, i.kind, i.title_hint, i.desc_hint, i.tags_hint, size);
    let mut dh = domain_hint(i.filename, i.title_hint, i.desc_hint, i.tags_hint, &fb);
    let prov = provider(s);
    if !s.ai_enabled || prov != "gemini" {
        return match dh {
            Some(d) => merge(&d, &fb, i.filename, i.mime, i.kind, prov),
            None => fb,
        };
    }
    let Some(preview) = crate::media_files::jpeg_preview_base64_from_path(i.file_path).await else {
        return match dh {
            Some(d) => merge(&d, &fb, i.filename, i.mime, i.kind, prov),
            None => fb,
        };
    };
    let key = s.ai_api_key.trim().to_string();
    if key.is_empty() {
        if let Some(mut d) = dh {
            d.reason = format!("{} Gemini is selected, but no Gemini API key is configured.", d.reason);
            return merge(&d, &fb, i.filename, i.mime, i.kind, "gemini");
        }
        fb.reason = Some("Gemini is selected, but no Gemini API key is configured.".into());
        return fb;
    }
    let model = if s.ai_model.is_empty() || s.ai_model == "gpt-4o-mini" { "gemini-2.5-flash".to_string() } else { s.ai_model.clone() };
    let res = gemini(
        http,
        GeminiOpts {
            preview_b64: preview,
            filename: i.filename,
            mime: i.mime,
            kind: i.kind,
            title_hint: i.title_hint,
            desc_hint: i.desc_hint,
            tags_hint: i.tags_hint,
            fallback: &fb,
            api_key: key,
            model,
            timeout: s.ai_timeout_seconds.clamp(10, 30) as u64,
        },
    )
    .await;
    match res {
        Err(e) => {
            let safe = safe_error(&e);
            if let Some(mut d) = dh.take() {
                d.reason = format!("{} Primary AI unavailable: {safe}", d.reason);
                return merge(&d, &fb, i.filename, i.mime, i.kind, "gemini");
            }
            fb.reason = Some(format!("AI suggestion unavailable, using local analyzer: {safe}"));
            fb
        }
        Ok(mut ai) => {
            if ai.source.is_empty() {
                ai.source = "google-gemini".into();
            }
            if let Some(d) = dh {
                if ai.confidence.unwrap_or(0.0).clamp(0.0, 1.0) < 0.55 {
                    ai = d;
                }
            }
            merge(&ai, &fb, i.filename, i.mime, i.kind, "gemini")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn booru() {
        let b = parse_booru("__tokisaki_kurumi_date_a_live_drawn_by_someone__abc123.jpg").unwrap();
        assert_eq!(b.characters, vec!["Kurumi Tokisaki"]);
        assert_eq!(b.series, vec!["Date A Live"]);
        assert_eq!(b.artist.as_deref(), Some("someone"));
    }
    #[test]
    fn titles_and_tags() {
        assert_eq!(clean_title("Cool Art 1920x1080 IMG_1234"), "Cool Art");
        assert!(is_noise_token("IMG_2041"));
        assert!(is_low_signal_filename("IMG_2041.jpg"));
        let a = heuristic("fluttershy_and_rarity.png", "image/png", "image", "", "", &[], Some((1080, 2400)));
        assert_eq!(a.category_name.as_deref(), Some("My Little Pony"));
    }
}
