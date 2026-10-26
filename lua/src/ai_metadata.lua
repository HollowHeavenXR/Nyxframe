-- Media title/tag/category classification. Mirrors app/ai_metadata.py, but
-- deliberately scoped down: this port implements the heuristic (no-network)
-- analyzer, the filename/text domain-hint matcher, and ONE real vision
-- provider (Gemini, since that's what this deployment's .env actually
-- configures -- see GALLERY_AI_PROVIDER/GALLERY_GEMINI_API_KEY). NOT
-- ported: Ollama and OpenAI-compatible vision calls, the local CLIP
-- classifier subprocess, visual-hash/training-example lookup matching
-- (needs the AI training-examples table, itself populated by a pipeline
-- this file doesn't implement), and the per-provider failure-backoff
-- window. If GALLERY_AI_PROVIDER resolves to anything other than "gemini",
-- or no Gemini key is configured, analysis gracefully degrades to the
-- heuristic/domain-hint result with a reason explaining why -- it never
-- errors the upload.
--
-- Image/video preview generation and dimension probing use ffmpeg/ffprobe
-- (media_files.lua's jpeg_preview_base64/media_dimensions) instead of PIL,
-- same rationale as elsewhere in this rewrite.

local classification = require("classification")
local media_files = require("media_files")
local cjson = require("cjson.safe")

local M = {}

-- ---------------------------------------------------------------------------
-- Constants (mirror the module-level constants in app/ai_metadata.py)
-- ---------------------------------------------------------------------------

local STOP_TAGS = {}
for _, w in ipairs({
  "the", "and", "for", "with", "from", "fullview", "generated", "image",
  "standard", "lite", "upscayl", "wallpaper", "desktop", "phone",
  "background", "backgrounds", "version", "text", "movie", "poster", "upload",
  "artwork", "fanart", "pic", "photo", "picture",
  "by", "artist", "source", "ai", "enhanced", "upscaled", "upscale", "compressed", "icloud",
}) do STOP_TAGS[w] = true end

local GENERIC_SUBCATEGORY_LABELS = {}
for _, w in ipairs({
  "wallpaper", "wallpapers", "background", "backgrounds", "desktop background",
  "desktop backgrounds", "phone background", "phone backgrounds", "image",
  "images", "art", "artwork", "profile picture", "profile pictures",
}) do GENERIC_SUBCATEGORY_LABELS[w] = true end

local GENERIC_TITLE_PHRASES = {}
for _, w in ipairs({
  "background", "backgrounds", "wallpaper", "wallpapers", "image", "images",
  "photo", "photos", "picture", "pictures", "art", "artwork", "fanart",
  "render", "renders", "edit", "edits", "desktop background", "phone background",
  "desktop wallpaper", "phone wallpaper", "imported media", "imported image",
  "imported video", "imported gif",
}) do GENERIC_TITLE_PHRASES[w] = true end

local KNOWN_CATEGORIES = {
  "My Little Pony", "FNAF", "GIFs", "KPOP Demon Hunters", "Videos", "Crossovers",
  "Hyperdimension Neptunia", "Profile Pictures", "Cartoon", "Memes", "Resident Evil",
  "Final Fantasy", "Xenoblade", "Sonic", "Desktop Backgrounds", "Phone Backgrounds", "Wallpapers",
}

local CHARACTER_RECOGNITION_GUIDE = {
  { "My Little Pony / Equestria Girls", {
    "Aria Blaze", "Adagio Dazzle", "Sonata Dusk", "Dazzlings", "Sunset Shimmer",
    "Twilight Sparkle", "Fluttershy", "Rainbow Dash", "Pinkie Pie", "Rarity", "Applejack",
    "Starlight Glimmer", "Trixie", "Princess Celestia", "Princess Luna",
  } },
  { "Five Nights at Freddy's", { "Freddy Fazbear", "Bonnie", "Chica", "Foxy", "Roxanne Wolf", "Roxy", "Frenni" } },
  { "Final Fantasy", { "Cloud Strife", "Tifa Lockhart", "Aerith Gainsborough", "Sephiroth" } },
  { "Resident Evil", { "Leon Kennedy", "Ada Wong", "Jill Valentine", "Claire Redfield", "Ashley Graham", "Albert Wesker" } },
  { "Sonic", { "Sonic", "Shadow", "Amy Rose", "Tails", "Knuckles", "Rouge" } },
  { "Xenoblade", { "Pyra", "Mythra", "Nia", "Mio", "Eunie", "Noah" } },
  { "Hyperdimension Neptunia", { "Neptune", "Nepgear", "Noire", "Blanc", "Vert", "Uzume", "Plutia" } },
  { "KPOP Demon Hunters", { "Huntrix", "Mira", "Zoey", "Rumi" } },
  { "Date A Live", { "Kurumi Tokisaki", "Tohka Yatogami", "Kotori Itsuka", "Origami Tobiichi", "Yoshino", "Miku Izayoi", "Natsumi", "Mukuro Hoshimiya", "Kaguya Yamai", "Shido Itsuka" } },
}

-- alias -> { display_name, category_name, subcategory_name, {tags} }
local DOMAIN_CHARACTER_ALIASES = {
  ["dazzlings"] = { "The Dazzlings", "My Little Pony", "Equestria Girls", { "dazzlings", "mlp", "equestria girls" } },
  ["aria blaze"] = { "Aria Blaze", "My Little Pony", "Equestria Girls", { "aria blaze", "dazzlings", "mlp", "equestria girls" } },
  ["adagio dazzle"] = { "Adagio Dazzle", "My Little Pony", "Equestria Girls", { "adagio dazzle", "dazzlings", "mlp", "equestria girls" } },
  ["sonata dusk"] = { "Sonata Dusk", "My Little Pony", "Equestria Girls", { "sonata dusk", "dazzlings", "mlp", "equestria girls" } },
  ["sunset shimmer"] = { "Sunset Shimmer", "My Little Pony", "Equestria Girls", { "sunset shimmer", "mlp", "equestria girls" } },
  ["twilight sparkle"] = { "Twilight Sparkle", "My Little Pony", "Equestria Girls", { "twilight sparkle", "mlp", "equestria girls" } },
  ["rainbow dash"] = { "Rainbow Dash", "My Little Pony", "Mane Six", { "rainbow dash", "mlp", "mane six" } },
  ["pinkie pie"] = { "Pinkie Pie", "My Little Pony", "Mane Six", { "pinkie pie", "mlp", "mane six" } },
  ["fluttershy"] = { "Fluttershy", "My Little Pony", "Mane Six", { "fluttershy", "mlp", "mane six" } },
  ["applejack"] = { "Applejack", "My Little Pony", "Mane Six", { "applejack", "mlp", "mane six" } },
  ["rarity"] = { "Rarity", "My Little Pony", "Mane Six", { "rarity", "mlp", "mane six" } },
  ["spike"] = { "Spike", "My Little Pony", "Mane Six", { "spike", "mlp" } },
  ["starlight glimmer"] = { "Starlight Glimmer", "My Little Pony", "Equestria Girls", { "starlight glimmer", "mlp" } },
  ["trixie"] = { "Trixie", "My Little Pony", "Equestria Girls", { "trixie", "mlp" } },
  ["derpy"] = { "Derpy", "My Little Pony", "Mane Six", { "derpy", "mlp" } },
  ["huntrix"] = { "Huntrix", "KPOP Demon Hunters", "Huntrix", { "huntrix", "kpop demon hunters" } },
  ["rumi"] = { "Rumi", "KPOP Demon Hunters", "Huntrix", { "rumi", "huntrix", "kpop demon hunters" } },
  ["mira"] = { "Mira", "KPOP Demon Hunters", "Huntrix", { "mira", "huntrix", "kpop demon hunters" } },
  ["zoey"] = { "Zoey", "KPOP Demon Hunters", "Huntrix", { "zoey", "huntrix", "kpop demon hunters" } },
  ["saja boys"] = { "Saja Boys", "KPOP Demon Hunters", "Saja Boys", { "saja boys", "kpop demon hunters" } },
  -- Date A Live (2026-10-26): both name orders -- booru/Japanese sources
  -- write the family name first ("tokisaki kurumi").
  ["kurumi tokisaki"] = { "Kurumi Tokisaki", "Date A Live", "Kurumi Tokisaki", { "kurumi tokisaki", "date a live" } },
  ["tokisaki kurumi"] = { "Kurumi Tokisaki", "Date A Live", "Kurumi Tokisaki", { "kurumi tokisaki", "date a live" } },
  ["tohka yatogami"] = { "Tohka Yatogami", "Date A Live", "Tohka Yatogami", { "tohka yatogami", "date a live" } },
  ["yatogami tohka"] = { "Tohka Yatogami", "Date A Live", "Tohka Yatogami", { "tohka yatogami", "date a live" } },
  ["kotori itsuka"] = { "Kotori Itsuka", "Date A Live", "Kotori Itsuka", { "kotori itsuka", "date a live" } },
  ["itsuka kotori"] = { "Kotori Itsuka", "Date A Live", "Kotori Itsuka", { "kotori itsuka", "date a live" } },
  ["origami tobiichi"] = { "Origami Tobiichi", "Date A Live", "Origami Tobiichi", { "origami tobiichi", "date a live" } },
  ["tobiichi origami"] = { "Origami Tobiichi", "Date A Live", "Origami Tobiichi", { "origami tobiichi", "date a live" } },
  ["miku izayoi"] = { "Miku Izayoi", "Date A Live", "Miku Izayoi", { "miku izayoi", "date a live" } },
  ["izayoi miku"] = { "Miku Izayoi", "Date A Live", "Miku Izayoi", { "miku izayoi", "date a live" } },
  ["mukuro hoshimiya"] = { "Mukuro Hoshimiya", "Date A Live", "Mukuro Hoshimiya", { "mukuro hoshimiya", "date a live" } },
  ["hoshimiya mukuro"] = { "Mukuro Hoshimiya", "Date A Live", "Mukuro Hoshimiya", { "mukuro hoshimiya", "date a live" } },
  ["kaguya yamai"] = { "Kaguya Yamai", "Date A Live", "Kaguya Yamai", { "kaguya yamai", "date a live" } },
  ["yamai kaguya"] = { "Kaguya Yamai", "Date A Live", "Kaguya Yamai", { "kaguya yamai", "date a live" } },
  ["shido itsuka"] = { "Shido Itsuka", "Date A Live", "Shido Itsuka", { "shido itsuka", "date a live" } },
  ["itsuka shido"] = { "Shido Itsuka", "Date A Live", "Shido Itsuka", { "shido itsuka", "date a live" } },
}
-- Preserve insertion order for domain-hint matching (Lua tables have no
-- guaranteed iteration order; Python's dict does).
local DOMAIN_CHARACTER_ALIAS_ORDER = {
  "dazzlings", "aria blaze", "adagio dazzle", "sonata dusk", "sunset shimmer",
  "twilight sparkle", "rainbow dash", "pinkie pie", "fluttershy", "applejack",
  "rarity", "spike", "starlight glimmer", "trixie", "derpy",
  "huntrix", "rumi", "mira", "zoey", "saja boys",
  "kurumi tokisaki", "tokisaki kurumi", "tohka yatogami", "yatogami tohka", "kotori itsuka", "itsuka kotori", "origami tobiichi", "tobiichi origami", "miku izayoi", "izayoi miku", "mukuro hoshimiya", "hoshimiya mukuro", "kaguya yamai", "yamai kaguya", "shido itsuka", "itsuka shido",
}

local MAX_ANALYSIS_SUBCATEGORIES = 3

-- ---------------------------------------------------------------------------
-- Small text helpers
-- ---------------------------------------------------------------------------

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function collapse_ws(s) return (trim(s):gsub("%s+", " ")) end

local function compact_label(value)
  return (tostring(value or ""):lower():gsub("[^%a%d]+", ""))
end

-- Mirrors _is_noise_token(): approximated with direct pattern checks rather
-- than a literal NOISE_TOKEN_RE alternation port (Lua patterns have no
-- alternation) -- good enough for this advisory auto-tagging feature.
local function is_noise_token(value)
  local token = tostring(value or ""):lower():gsub("_", "-")
  if token == "" then return true end
  local compact = token:gsub("[^%a%d]", "")
  if compact == "" then return true end
  if compact:match("^%d+$") and #compact >= 2 then return true end
  if compact:match("^%x+$") and compact:match("%d") and #compact >= 4 then return true end
  local function noisy(s)
    if s == "" then return false end
    if s:match("^wp%d+$") then return true end
    if s:match("^img[_%-]?%d+$") then return true end
    if s:match("^dsc[_%-]?%d+$") then return true end
    if s:match("^pxl[_%-]?%d+$") then return true end
    if s:match("^mvimg[_%-]?%d+$") then return true end
    if s:match("^screenshot[_%-]?%d+$") then return true end
    if s:match("^photo[_%-]?%d+$") then return true end
    if s:match("^image[_%-]?%d+$") then return true end
    if s:match("^%d%d+$") then return true end
    if s:match("^%x+$") and #s >= 8 then return true end
    if s:match("^%d%d%d%d?x%d%d%d%d?$") then return true end
    if s:match("^%d%d%d%d?p$") then return true end
    if s == "4k" or s == "8k" or s == "uhd" or s == "fhd" or s == "qhd" then return true end
    if s == "desktop" or s == "phone" then return true end
    if s == "background" or s == "backgrounds" then return true end
    if s == "wallpaper" or s == "wallpapers" then return true end
    return false
  end
  return noisy(token) or noisy(compact)
end

local function clean_label(value)
  local cleaned = collapse_ws(value):sub(1, 80)
  if cleaned == "" or is_noise_token(cleaned) then return nil end
  return cleaned
end

local function clean_reason_text(value)
  return collapse_ws(value):sub(1, 240)
end

local function clean_filename_base(value)
  local cleaned = tostring(value or ""):lower():gsub("[^a-z0-9-]+", "-")
  cleaned = cleaned:gsub("-+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  return cleaned:sub(1, 90)
end

-- Mirrors _clean_title().
local function clean_title(value)
  local text = collapse_ws(value):sub(1, 160)
  text = text:gsub("%d%d%d%d?x%d%d%d%d?", "")
  text = text:gsub("%d%d%d%d?p", "")
  text = text:gsub("[48]k", "")
  text = text:gsub("[uUfFqQ][hH][dD]", "")
  text = text:gsub("[wW][pP]%d+", "")
  text = text:gsub("[iI][mM][gG][_%-]?%d+", "")
  text = text:gsub("[dD][sS][cC][_%-]?%d+", "")
  text = text:gsub("[pP][xX][lL][_%-]?%d+", "")
  text = text:gsub("[mM][vV][iI][mM][gG][_%-]?%d+", "")
  text = text:gsub("[sS][cC][rR][eE][eE][nN][sS][hH][oO][tT][_%-]?%d+", "")
  text = text:gsub("[pP][hH][oO][tT][oO][_%-]?%d+", "")
  text = text:gsub("[iI][mM][aA][gG][eE][_%-]?%d+", "")
  text = text:gsub("%d%d+", "")
  text = text:gsub("%s+", " ")
  text = trim(text):gsub("^[-_ ]+", ""):gsub("[-_ ]+$", "")
  return text:sub(1, 160)
end

local function normalize_tags(values)
  local candidates = {}
  if type(values) == "string" then
    for tok in values:gmatch("[^,#%s]+") do candidates[#candidates + 1] = tok end
  elseif type(values) == "table" then
    for _, v in ipairs(values) do candidates[#candidates + 1] = v end
  end
  local normalized, seen = {}, {}
  for _, raw in ipairs(candidates) do
    local raw_tag = tostring(raw or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", "-")
    local tag = raw_tag:gsub("[^a-z0-9_.%-]+", ""):sub(1, 32)
    if tag ~= "" and not STOP_TAGS[tag] and #tag >= 2 and not seen[tag] and not is_noise_token(tag) then
      seen[tag] = true
      normalized[#normalized + 1] = tag
      if #normalized >= 12 then break end
    end
  end
  return normalized
end

local function merge_tags(primary, secondary)
  local merged, seen = {}, {}
  local all = {}
  for _, v in ipairs(primary or {}) do all[#all + 1] = v end
  for _, v in ipairs(secondary or {}) do all[#all + 1] = v end
  for _, raw in ipairs(all) do
    for _, tag in ipairs(normalize_tags({ raw })) do
      if not seen[tag] then
        seen[tag] = true
        merged[#merged + 1] = tag
        if #merged >= 12 then return merged end
      end
    end
  end
  return merged
end

local function normalize_tokens(value)
  local results = {}
  for _, token in ipairs(classification.clean_tokens(value)) do
    if not STOP_TAGS[token] and #token >= 3 and not is_noise_token(token) then
      results[#results + 1] = token
    end
  end
  return results
end

-- Mirrors _normalize_subcategory_names(primary first, then values, deduped, max 3).
local function normalize_subcategory_names(values, primary)
  local names, seen = {}, {}
  local all = { primary }
  for _, v in ipairs(values or {}) do all[#all + 1] = v end
  for _, raw in ipairs(all) do
    local cleaned = clean_label(raw)
    if cleaned then
      local lowered = cleaned:lower()
      if not seen[lowered] then
        seen[lowered] = true
        names[#names + 1] = cleaned
        if #names >= MAX_ANALYSIS_SUBCATEGORIES then break end
      end
    end
  end
  return names
end

local function sanitize_subcategory_names(values, primary, category_name)
  local raw_values = {}
  if type(values) == "string" then
    raw_values = { values }
  elseif type(values) == "table" then
    for _, v in ipairs(values) do raw_values[#raw_values + 1] = v end
  end
  if primary then raw_values[#raw_values + 1] = primary end
  local names = normalize_subcategory_names(raw_values)
  if #names == 0 then return {} end
  local blocked = { [compact_label(category_name)] = true }
  for label in pairs(GENERIC_SUBCATEGORY_LABELS) do blocked[compact_label(label)] = true end
  local sanitized, seen = {}, {}
  for _, name in ipairs(names) do
    local compact = compact_label(name)
    if compact ~= "" and not blocked[compact] and not seen[compact] then
      seen[compact] = true
      sanitized[#sanitized + 1] = name
      if #sanitized >= MAX_ANALYSIS_SUBCATEGORIES then break end
    end
  end
  return sanitized
end

local function clamp_float(value, minimum, maximum, default)
  local n = tonumber(value)
  if not n then return default end
  return math.max(minimum, math.min(maximum, n))
end

-- ---------------------------------------------------------------------------
-- Title/tag composition
-- ---------------------------------------------------------------------------

local function is_low_signal_filename(filename)
  local stem = tostring(filename or ""):match("([^/\\]+)$") or filename or ""
  stem = trim(stem:match("^(.*)%.[^.]+$") or stem)
  if stem == "" then return true end
  local lowered = stem:lower()
  local compact = lowered:gsub("[^a-z0-9]", "")
  -- Mirrors LOW_SIGNAL_RE's `[ _-]*\d*` -- an optional separator run, then
  -- an optional digit run, after one of these known camera/app prefixes.
  local sep_digits = "[ _%-]*%d*$"
  if lowered:match("^img" .. sep_digits) or lowered:match("^dsc" .. sep_digits) or lowered:match("^pxl" .. sep_digits)
    or lowered:match("^mvimg" .. sep_digits) or lowered:match("^screenshot" .. sep_digits) or lowered:match("^image" .. sep_digits)
    or lowered:match("^photo" .. sep_digits) or lowered:match("^video" .. sep_digits) or lowered:match("^scan" .. sep_digits)
    or lowered:match("^untitled" .. sep_digits) or lowered:match("^temp" .. sep_digits)
    or lowered:match("^whatsapp image" .. sep_digits) or lowered:match("^snapchat" .. sep_digits) or lowered:match("^signal" .. sep_digits)
  then
    return true
  end
  if compact:match("^%x+$") and #compact >= 8 then return true end
  if compact:match("^%d+$") and #compact >= 2 then return true end
  if lowered:match("^[0-9a-f%-]+$") and #lowered >= 16 then return true end
  return false
end
M.is_low_signal_filename = is_low_signal_filename

local function is_generic_title(value)
  local original = collapse_ws(value)
  local cleaned = clean_title(original)
  if original == "" or cleaned == "" then return true end
  if is_noise_token(original) or is_noise_token(cleaned) then return true end
  local lowered = cleaned:lower()
  if GENERIC_TITLE_PHRASES[lowered] then return true end
  if lowered == "desktop backgrounds" or lowered == "phone backgrounds" or lowered == "wallpapers" then return true end
  local meaningful = {}
  for part in lowered:gmatch("%S+") do
    if not STOP_TAGS[part] and not is_noise_token(part) then meaningful[#meaningful + 1] = part end
  end
  if #meaningful == 0 then return true end
  local generic_subject_words = {}
  for _, w in ipairs({
    "media", "upload", "background", "backgrounds", "wallpaper", "wallpapers",
    "image", "images", "photo", "photos", "picture", "pictures", "profile",
    "art", "artwork", "render", "renders", "edit", "edits", "graphic", "graphics",
    "illustration", "portrait", "landscape", "desktop", "phone", "uncategorized",
  }) do generic_subject_words[w] = true end
  return #meaningful == 1 and generic_subject_words[meaningful[1]] == true
end

local function title_is_category_or_subcategory(title, category_name, subcategory_name)
  local compact_title = compact_label(title)
  if compact_title == "" then return true end
  local blocked = {
    [compact_label(category_name)] = true,
    [compact_label(subcategory_name)] = true,
    [compact_label(tostring(category_name or ""):gsub("Backgrounds", "Background"))] = true,
    [compact_label(tostring(category_name or ""):gsub("Pictures", "Picture"))] = true,
    phonebackground = true, phonebackgrounds = true, desktopbackground = true, desktopbackgrounds = true,
    profile = true, profilepicture = true, profilepictures = true, wallpaper = true, wallpapers = true,
    background = true, backgrounds = true, image = true, images = true, artwork = true, media = true,
  }
  blocked[""] = nil
  return blocked[compact_title] == true
end

local function is_bad_subject_title(title, category_name, subcategory_name)
  if is_generic_title(title) then return true end
  if title_is_category_or_subcategory(title, category_name, subcategory_name) then return true end
  return false
end

local function category_suffix(category_name, media_kind)
  if category_name == "Phone Backgrounds" then return "Phone Background" end
  if category_name == "Desktop Backgrounds" then return "Desktop Background" end
  if category_name == "Wallpapers" then return "Wallpaper" end
  if category_name == "Profile Pictures" then return "Profile Picture" end
  if media_kind == "video" then return "Video" end
  return "Artwork"
end

local UPPER_TAG_WORDS = { mlp = true, fnaf = true, kpop = true, vr = true, sfm = true, eqg = true, ai = true, ["4k"] = true }

local function pretty_tag(tag)
  local text = tostring(tag or ""):gsub("_", " "):gsub("%-", " ")
  local words = {}
  for w in text:gmatch("%S+") do
    if not STOP_TAGS[w] and not is_noise_token(w) then words[#words + 1] = w end
  end
  if #words == 0 then return "" end
  local out = {}
  for _, w in ipairs(words) do
    if UPPER_TAG_WORDS[w:lower()] then
      out[#out + 1] = w:upper()
    else
      out[#out + 1] = w:sub(1, 1):upper() .. w:sub(2)
    end
  end
  return table.concat(out, " ")
end

local filename_subject_text -- defined below; used by compose_specific_title

local function compose_specific_title(title, filename, category_name, subcategory_name, tags, media_kind)
  local ct = clean_title(title)
  if ct ~= "" and not is_bad_subject_title(ct, category_name, subcategory_name) then return ct:sub(1, 160) end

  local subject = clean_label(subcategory_name)
  if subject and not is_bad_subject_title(subject, category_name, nil) then
    return (subject .. " " .. category_suffix(category_name, media_kind)):sub(1, 160)
  end

  local generic_title_tags = {}
  for _, w in ipairs({
    "landscape", "portrait", "square", "1080p", "1440p", "4k", "video", "gif", "profile",
    "profiles", "picture", "pictures", "desktop", "phone", "background", "backgrounds",
    "wallpaper", "wallpapers",
  }) do generic_title_tags[w] = true end
  for _, t in ipairs(normalize_tokens(category_name or "")) do generic_title_tags[t] = true end
  for _, t in ipairs(normalize_tokens(subcategory_name or "")) do generic_title_tags[t] = true end

  local preferred_tags, seen_lower = {}, {}
  for _, tag in ipairs(tags or {}) do
    if not generic_title_tags[tag] then
      local pretty = pretty_tag(tag)
      local pl = pretty:lower()
      if pretty ~= "" and pl ~= "background" and pl ~= "backgrounds" and pl ~= "wallpaper"
        and pl ~= "wallpapers" and pl ~= "desktop" and pl ~= "phone" and not seen_lower[pl] then
        seen_lower[pl] = true
        preferred_tags[#preferred_tags + 1] = pretty
      end
    end
    if #preferred_tags >= 2 then break end
  end

  if #preferred_tags > 0 then
    if #preferred_tags >= 2 then
      -- Two words that sit next to each other in the filename are almost
      -- always one name ("tokisaki_kurumi"), not two subjects -- real pairs
      -- are written "a_and_b". Keep them together.
      local subject = " " .. filename_subject_text(filename):lower():gsub("[^a-z0-9]+", " ") .. " "
      if subject:find(" " .. preferred_tags[1]:lower() .. " " .. preferred_tags[2]:lower() .. " ", 1, true) then
        return (preferred_tags[1] .. " " .. preferred_tags[2] .. " " .. category_suffix(category_name, media_kind)):sub(1, 160)
      end
      return (preferred_tags[1] .. " and " .. preferred_tags[2] .. " " .. category_suffix(category_name, media_kind)):sub(1, 160)
    end
    return (preferred_tags[1] .. " " .. category_suffix(category_name, media_kind)):sub(1, 160)
  end

  if category_name == "Phone Backgrounds" or category_name == "Desktop Backgrounds"
    or category_name == "Wallpapers" or category_name == "Profile Pictures" then
    return ("Uncategorized " .. category_suffix(category_name, media_kind)):sub(1, 160)
  end

  local fallback = category_name or (media_kind == "video" and "Video" or "Media")
  if title_is_category_or_subcategory(fallback, category_name, subcategory_name) then fallback = "Media" end
  return ("Uncategorized " .. fallback):sub(1, 160)
end

local ADULT_KEYWORDS = {
  "18plus", "18+", "adult", "nsfw", "not safe for work", "nude", "nudity",
  "explicit", "porn", "porno", "sex", "sexual", "hentai", "ecchi", "lewd",
  "erotic", "fetish", "onlyfans", "xxx",
}

-- Mirrors _looks_adult(): word-boundary keyword search over combined text.
local function looks_adult(title, description, tags, filename, mime_type)
  local combined = table.concat({ title or "", description or "", table.concat(tags or {}, " "), filename or "", mime_type or "" }, " "):lower()
  local normalized = " " .. combined:gsub("[^a-z0-9+]+", " ") .. " "
  for _, word in ipairs(ADULT_KEYWORDS) do
    if normalized:find(" " .. word .. " ", 1, true) then return true end
  end
  return false
end

local function suggest_filename(title, source_filename, mime_type, category_name, subcategory_name, suggested_base)
  local suffix = tostring(source_filename or "upload"):match("(%.[^./\\]+)$")
  suffix = suffix and suffix:lower() or ""
  if suffix == "" then
    local ext_map = { ["image/jpeg"] = ".jpg", ["image/png"] = ".png", ["image/webp"] = ".webp", ["image/gif"] = ".gif", ["video/mp4"] = ".mp4" }
    suffix = ext_map[mime_type] or ""
  end
  if suffix == ".jpe" then suffix = ".jpg" end
  local base = suggested_base or ""
  if base == "" then
    local stem = tostring(source_filename or ""):match("([^/\\]+)$") or ""
    stem = stem:match("^(.*)%.[^.]+$") or stem
    local seed = title
    if not seed or seed == "" then seed = subcategory_name end
    if not seed or seed == "" then seed = category_name end
    if not seed or seed == "" then seed = (stem ~= "" and stem) or "media" end
    base = seed:lower():gsub("[^a-z0-9]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  end
  if base == "" then base = "media" end
  if is_low_signal_filename(source_filename) and (base == "imported-media" or base == "media" or base == "upload") then
    local stem = tostring(source_filename or ""):match("([^/\\]+)$") or ""
    stem = (stem:match("^(.*)%.[^.]+$") or stem):sub(1, 8):lower()
    base = (base .. "-" .. stem):gsub("^%-+", ""):gsub("%-+$", "")
  end
  return base:sub(1, 90) .. suffix
end

-- ---------------------------------------------------------------------------
-- Tag building
-- ---------------------------------------------------------------------------

-- Mirrors _filename_subject_text(): a cleaned, credit-tail-stripped subject
-- string derived from the filename stem, or "" if the stem carries no real
-- signal (camera-generated names, hex hashes, etc).
function filename_subject_text(filename)
  local stem = tostring(filename or ""):match("([^/\\]+)$") or ""
  stem = stem:match("^(.*)%.[^.]+$") or stem
  if stem == "" then return "" end
  stem = stem:gsub("__%x%x%x%x%x%x%x%x+$", "")
  stem = stem:gsub("[Aa][Ii][_ %-]?[Ee][Nn][Hh][Aa][Nn][Cc][Ee][Dd]", " ")
  stem = stem:gsub("[Uu][Pp][Ss][Cc][Aa][Yy][Ll]", " ")
  stem = stem:gsub("[Uu][Pp][Ss][Cc][Aa][Ll][Ee][Dd]", " ")
  stem = stem:gsub("[Cc][Oo][Mm][Pp][Rr][Ee][Ss][Ss][Ee][Dd]", " ")
  stem = stem:gsub("[Ff][Ii][Nn][Aa][Ll]", " ")
  stem = stem:gsub("[Ff][Uu][Ll][Ll][Vv][Ii][Ee][Ww]", " ")
  stem = stem:gsub("%d%d%d%d?x%d%d%d%d?", " ")
  stem = stem:gsub("%d%d%d%d?p", " ")
  stem = stem:gsub("[48]k", " ")
  -- Discard the credit tail after "_by_"/"-by-"/" by ".
  local lowered = stem:lower()
  local s1 = lowered:find("_by_")
  local s2 = lowered:find("%-by%-")
  local s3 = lowered:find(" by ")
  local best_s
  for _, s in ipairs({ s1, s2, s3 }) do
    if s and (not best_s or s < best_s) then best_s = s end
  end
  if best_s then stem = stem:sub(1, best_s - 1) end
  stem = stem:gsub("%x%x%x%x%x%x%x%x+[%-_]%x%x%x%x+", " ")
  stem = stem:gsub("%x%x%x%x%x%x%x%x%x%x+", " ")
  local cleaned = trim((stem:gsub("[^%a%d]+", " ")))
  local compact = cleaned:lower():gsub("[^a-z0-9]", "")
  if cleaned == "" or is_low_signal_filename(cleaned) or (compact:match("^%x+$") and #compact >= 8) then
    return ""
  end
  return cleaned
end

-- ---------------------------------------------------------------------------
-- Booru-style filenames (2026-10-26)
-- ---------------------------------------------------------------------------
-- Danbooru saves files as
--   __<characters>_<copyrights>_drawn_by_<artist>__<md5>.jpg
-- e.g. __tokisaki_kurumi_date_a_live_drawn_by_hci__sample-887b....jpg.
-- Characters are family-name-first and multi-word, so the generic
-- word-per-tag fallback split "tokisaki_kurumi" into two "subjects" and
-- titled the post "Tokisaki and Kurumi Phone Background". This parser keeps
-- names whole: known characters are resolved to their gallery display name
-- (Western order, matching the existing subcategories), known series are
-- peeled off the end, and anything left over is kept as one name.

-- booru name (underscored) -> { display name, series display name }
local BOORU_CHARACTERS = {
  tokisaki_kurumi = { "Kurumi Tokisaki", "Date A Live" },
  yatogami_tohka = { "Tohka Yatogami", "Date A Live" },
  itsuka_kotori = { "Kotori Itsuka", "Date A Live" },
  itsuka_shidou = { "Shido Itsuka", "Date A Live" },
  tobiichi_origami = { "Origami Tobiichi", "Date A Live" },
  himekawa_yoshino = { "Yoshino", "Date A Live" },
  yoshino_date_a_live = { "Yoshino", "Date A Live" },
  izayoi_miku = { "Miku Izayoi", "Date A Live" },
  natsumi_date_a_live = { "Natsumi", "Date A Live" },
  hoshimiya_mukuro = { "Mukuro Hoshimiya", "Date A Live" },
  yamai_kaguya = { "Kaguya Yamai", "Date A Live" },
  yamai_yuzuru = { "Yuzuru Yamai", "Date A Live" },
  takamiya_mana = { "Mana Takamiya", "Date A Live" },
  takamiya_mio = { "Mio Takamiya", "Date A Live" },
  murasame_reine = { "Reine Murasame", "Date A Live" },
  honjou_nia = { "Nia Honjou", "Date A Live" },
  hornet_hollow_knight = { "Hornet", "Hollow Knight" },
  hornet = { "Hornet", nil },
}
-- Longest first, so "yamai_kaguya" wins over a shorter prefix.
local BOORU_CHARACTER_KEYS = {}
for k in pairs(BOORU_CHARACTERS) do BOORU_CHARACTER_KEYS[#BOORU_CHARACTER_KEYS + 1] = k end
table.sort(BOORU_CHARACTER_KEYS, function(a, b) return #a > #b end)

-- booru copyright tag -> display name
local BOORU_COPYRIGHTS = {
  date_a_live = "Date A Live", azur_lane = "Azur Lane", punishing_gray_raven = "Punishing: Gray Raven",
  hollow_knight = "Hollow Knight", zenless_zone_zero = "Zenless Zone Zero", genshin_impact = "Genshin Impact",
  honkai_star_rail = "Honkai: Star Rail", honkai_impact_3rd = "Honkai Impact 3rd", blue_archive = "Blue Archive",
  goddess_of_victory_nikke = "Nikke", arknights = "Arknights", wuthering_waves = "Wuthering Waves",
  xenoblade_chronicles_2 = "Xenoblade Chronicles 2", xenoblade_chronicles_3 = "Xenoblade Chronicles 3",
  xenoblade_chronicles = "Xenoblade", kpop_demon_hunters = "KPOP Demon Hunters",
  my_little_pony = "My Little Pony", my_little_pony_equestria_girls = "My Little Pony",
  my_little_pony_friendship_is_magic = "My Little Pony", resident_evil = "Resident Evil",
  final_fantasy_vii = "Final Fantasy", final_fantasy_vii_remake = "Final Fantasy", final_fantasy = "Final Fantasy",
  sonic_the_hedgehog = "Sonic", sonic_series = "Sonic", overwatch = "Overwatch", overwatch_2 = "Overwatch",
  fate_grand_order = "Fate/Grand Order", fate_series = "Fate", hololive = "Hololive", pokemon = "Pokemon",
  street_fighter = "Street Fighter", street_fighter_6 = "Street Fighter", monster_hunter = "Monster Hunter",
  doki_doki_literature_club = "Doki Doki Literature Club", bayonetta = "Bayonetta", bayonetta_series = "Bayonetta",
  kingdom_hearts = "Kingdom Hearts", dragon_ball = "Dragon Ball", dragon_ball_z = "Dragon Ball",
  super_smash_bros = "Super Smash Bros.", mario_series = "Mario", super_mario_bros = "Mario",
  neptune_series = "Hyperdimension Neptunia", re_zero_kara_hajimeru_isekai_seikatsu = "Re:Zero",
  sword_art_online = "Sword Art Online", darling_in_the_franxx = "Darling in the Franxx",
  spy_x_family = "Spy x Family", chainsaw_man = "Chainsaw Man", jujutsu_kaisen = "Jujutsu Kaisen",
  touhou = "Touhou", vocaloid = "Vocaloid", kantai_collection = "KanColle", girls_frontline = "Girls' Frontline",
  five_nights_at_freddy_s = "FNAF", five_nights_at_freddys = "FNAF", original = nil,
}
local BOORU_COPYRIGHT_KEYS = {}
for k in pairs(BOORU_COPYRIGHTS) do BOORU_COPYRIGHT_KEYS[#BOORU_COPYRIGHT_KEYS + 1] = k end
table.sort(BOORU_COPYRIGHT_KEYS, function(a, b) return #a > #b end)

local function title_case_words(s)
  return (tostring(s):gsub("_", " "):gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end

-- "a" / "a and b" / "a, b and c" / "a, b, c and others"
local function join_names(names)
  local n = #names
  if n == 0 then return "" end
  if n == 1 then return names[1] end
  if n == 2 then return names[1] .. " and " .. names[2] end
  if n == 3 then return names[1] .. ", " .. names[2] .. " and " .. names[3] end
  return names[1] .. ", " .. names[2] .. ", " .. names[3] .. " and others"
end
M.join_names = join_names

-- Returns nil for non-booru filenames, otherwise
-- { characters = {display...}, series = {display...}, artist = "x"|nil, known = bool }
local function parse_booru_filename(filename)
  local stem = tostring(filename or ""):match("([^/\\]+)$") or ""
  stem = (stem:match("^(.*)%.[^.]+$") or stem):lower()
  if not (stem:match("^__.+__") or stem:find("_drawn_by_", 1, true)) then return nil end
  stem = stem:gsub("^_+", "")
  stem = stem:gsub("__sample%-%x+$", ""):gsub("__%x+$", ""):gsub("__.*$", "")
  local artist
  local body, art = stem:match("^(.-)_drawn_by_(.+)$")
  if body then stem, artist = body, art end
  -- "_and_1_more" etc. stand for copyrights/characters that didn't fit
  stem = stem:gsub("_and_%d+_more", "")
  stem = "_" .. stem .. "_"

  -- Peel known series off the end (Danbooru puts copyrights last).
  local series, seen_series = {}, {}
  local peeled = true
  while peeled do
    peeled = false
    for _, key in ipairs(BOORU_COPYRIGHT_KEYS) do
      local suffix = "_" .. key .. "_"
      if #stem > #suffix and stem:sub(-#suffix) == suffix then
        local display = BOORU_COPYRIGHTS[key]
        if display and not seen_series[display] then
          seen_series[display] = true
          table.insert(series, 1, display)
        end
        stem = stem:sub(1, #stem - #suffix + 1)
        peeled = true
        break
      end
    end
  end

  -- Walk the character part left to right: known names first, then
  -- "_and_" separated leftovers kept whole.
  local characters, seen_chars, known = {}, {}, false
  local function add(name)
    if name ~= "" and not seen_chars[name:lower()] then
      seen_chars[name:lower()] = true
      characters[#characters + 1] = name
    end
  end
  local rest = stem:gsub("^_+", ""):gsub("_+$", "")
  local pending = {}
  local function flush_pending()
    if #pending > 0 then
      local phrase = table.concat(pending, "_")
      for part in (phrase .. "_and_"):gmatch("(.-)_and_") do
        if part ~= "" and not part:match("^%d+$") then add(title_case_words(part)) end
      end
      pending = {}
    end
  end
  while rest ~= "" do
    local matched = false
    for _, key in ipairs(BOORU_CHARACTER_KEYS) do
      if rest == key or rest:sub(1, #key + 1) == key .. "_" then
        flush_pending()
        local entry = BOORU_CHARACTERS[key]
        add(entry[1])
        if entry[2] and not seen_series[entry[2]] then
          seen_series[entry[2]] = true
          series[#series + 1] = entry[2]
        end
        known = true
        rest = rest:sub(#key + 2)
        matched = true
        break
      end
    end
    if not matched then
      local word, after = rest:match("^([^_]+)_?(.*)$")
      if word == "and" then
        flush_pending()
      else
        pending[#pending + 1] = word
      end
      rest = after or ""
    end
  end
  flush_pending()
  if #characters == 0 and #series == 0 then return nil end
  if artist then artist = artist:gsub("_", " ") end
  return { characters = characters, series = series, artist = artist, known = known or #series > 0 }
end
M.parse_booru_filename = parse_booru_filename

local function booru_tags(parsed)
  local tags = {}
  for _, c in ipairs(parsed.characters) do tags[#tags + 1] = c:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "") end
  for _, s in ipairs(parsed.series) do tags[#tags + 1] = s:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "") end
  return tags
end

local function build_tags(filename, title, description, category_name, subcategory_name, media_kind, size, tags_hint)
  local tags = {}
  if category_name then for _, t in ipairs(normalize_tokens(category_name)) do tags[#tags + 1] = t end end
  if subcategory_name then for _, t in ipairs(normalize_tokens(subcategory_name)) do tags[#tags + 1] = t end end
  if media_kind == "video" then tags[#tags + 1] = "video" end
  if tostring(filename or ""):lower():match("%.gif$") then tags[#tags + 1] = "gif" end
  if size then
    local width, height = size[1], size[2]
    if width > height then tags[#tags + 1] = "landscape"
    elseif height > width then tags[#tags + 1] = "portrait"
    else tags[#tags + 1] = "square" end
    if width >= 3840 or height >= 2160 then tags[#tags + 1] = "4k"
    elseif width >= 2560 or height >= 1440 then tags[#tags + 1] = "1440p"
    elseif width >= 1920 or height >= 1080 then tags[#tags + 1] = "1080p" end
  end
  for _, value in ipairs({ title, description, filename_subject_text(filename) }) do
    for _, t in ipairs(normalize_tokens(value or "")) do tags[#tags + 1] = t end
  end
  for _, t in ipairs(normalize_tags(tags_hint)) do tags[#tags + 1] = t end
  return merge_tags(tags, {})
end

-- ---------------------------------------------------------------------------
-- Heuristic (no-network) analysis
-- ---------------------------------------------------------------------------

local function heuristic_analysis(filename, mime_type, media_kind, title_hint, description_hint, tags_hint, size)
  local clean_hint_title = clean_title(title_hint)
  local category_name, subcategory_name = classification.canonical_category_pair(
    classification.infer_category_pair({
      filename = filename,
      media_kind = media_kind,
      title = (clean_hint_title ~= "" and clean_hint_title) or filename,
      size = size,
    })
  )
  local tags = build_tags(filename, clean_hint_title, description_hint, category_name, subcategory_name, media_kind, size, tags_hint)
  local booru = parse_booru_filename(filename)
  local confidence = 0.45
  local subcategory_names = nil
  local title
  if clean_hint_title ~= "" and not is_bad_subject_title(clean_hint_title, category_name, subcategory_name) then
    title = clean_hint_title
  elseif booru and #booru.characters > 0 then
    -- Booru filenames carry curated character/series tags: use them whole
    -- (see parse_booru_filename) instead of splitting names into words.
    title = join_names(booru.characters) .. " — " .. category_suffix(category_name, media_kind)
    if booru.artist and booru.artist ~= "" then title = title .. " by " .. booru.artist end
    title = title:sub(1, 160)
    -- Replace the word-split filename tokens with the parsed names.
    local keep = {}
    for _, t in ipairs(tags) do
      if t == "landscape" or t == "portrait" or t == "square" or t == "4k" or t == "1440p" or t == "1080p"
        or t == "video" or t == "gif" then keep[#keep + 1] = t end
    end
    tags = merge_tags(booru_tags(booru), merge_tags(keep, normalize_tags(tags_hint)))
    if booru.known then
      confidence = 0.62
      local home_series = nil
      for _, entry in pairs(BOORU_CHARACTERS) do
        if entry[1] == booru.characters[1] and entry[2] then home_series = entry[2] break end
      end
      subcategory_names = normalize_subcategory_names({ home_series or booru.series[1], booru.characters[1] })
    end
  else
    title = compose_specific_title("", filename, category_name, subcategory_name, tags, media_kind)
  end
  local suggested_filename = suggest_filename(title, filename, mime_type, category_name, subcategory_name)
  return {
    title = title,
    suggested_filename = suggested_filename,
    tags = tags,
    category_name = category_name,
    subcategory_name = subcategory_name,
    subcategory_names = subcategory_names or normalize_subcategory_names({}, subcategory_name),
    is_adult = looks_adult(title, description_hint, tags, filename, mime_type),
    source = (booru and booru.known) and "booru-filename" or "heuristic",
    confidence = confidence,
    size = size,
  }
end
M.heuristic_analysis = heuristic_analysis

-- ---------------------------------------------------------------------------
-- Domain-hint (character/franchise alias) matching from text only
-- ---------------------------------------------------------------------------

local function domain_hint_analysis_from_text(filename, title_hint, description_hint, tags_hint, fallback)
  if fallback and fallback.source == "booru-filename" then return nil end
  local text = table.concat({ filename_subject_text(filename), title_hint or "", description_hint or "", table.concat(tags_hint or {}, " ") }, " "):lower()
  text = " " .. (text:gsub("[^a-z0-9]+", " ")) .. " "
  if trim(text) == "" then return nil end

  local matches = {}
  for _, alias in ipairs(DOMAIN_CHARACTER_ALIAS_ORDER) do
    local alias_text = alias:gsub("_", " "):gsub("%-", " ")
    if text:find(" " .. alias_text .. " ", 1, true) then
      matches[#matches + 1] = DOMAIN_CHARACTER_ALIASES[alias]
    end
  end
  if text:find(" aria ", 1, true) and text:find("dazzlings", 1, true) then matches[#matches + 1] = DOMAIN_CHARACTER_ALIASES["aria blaze"] end
  if text:find(" adagio ", 1, true) and text:find("dazzlings", 1, true) then matches[#matches + 1] = DOMAIN_CHARACTER_ALIASES["adagio dazzle"] end
  if text:find(" sonata ", 1, true) and text:find("dazzlings", 1, true) then matches[#matches + 1] = DOMAIN_CHARACTER_ALIASES["sonata dusk"] end
  if text:find(" dashie ", 1, true) then matches[#matches + 1] = DOMAIN_CHARACTER_ALIASES["rainbow dash"] end
  if text:find("kpop demon hunters", 1, true) or text:find("k pop demon hunters", 1, true) then
    matches[#matches + 1] = { "KPop Demon Hunters", "KPOP Demon Hunters", "Huntrix", { "kpop demon hunters", "huntrix" } }
  end
  if #matches == 0 then return nil end

  local unique, seen_names = {}, {}
  for _, m in ipairs(matches) do
    local lowered = m[1]:lower()
    if not seen_names[lowered] then
      seen_names[lowered] = true
      unique[#unique + 1] = m
      if #unique >= 4 then break end
    end
  end
  local names = {}
  for _, m in ipairs(unique) do names[#names + 1] = m[1] end
  local category = unique[1][2]
  local subcategory = unique[1][3]
  local subcategory_names = normalize_subcategory_names(names, subcategory)

  local name_set = {}
  for _, n in ipairs(names) do name_set[n] = true end
  local title, tags
  if (name_set["Aria Blaze"] and name_set["Adagio Dazzle"] and name_set["Sonata Dusk"]) or name_set["The Dazzlings"] then
    title = "The Dazzlings"
    tags = { "the dazzlings", "aria blaze", "adagio dazzle", "sonata dusk", "mlp", "equestria girls" }
    subcategory = "Equestria Girls"
    subcategory_names = normalize_subcategory_names({ "Aria Blaze", "Adagio Dazzle" }, subcategory)
  elseif #names > 2 then
    title = string.format("%s, %s, and %d more", names[1], names[2], #names - 2)
    tags = {}
    for i = 1, math.min(6, #unique) do
      for _, t in ipairs(unique[i][4]) do tags[#tags + 1] = t end
    end
  elseif #names == 2 then
    title = names[1] .. " and " .. names[2]
    tags = {}
    for i = 1, math.min(4, #unique) do
      for _, t in ipairs(unique[i][4]) do tags[#tags + 1] = t end
    end
  else
    title = names[1]
    tags = {}
    for _, t in ipairs(unique[1][4]) do tags[#tags + 1] = t end
  end

  return {
    title = title,
    suggested_filename_base = "",
    tags = tags,
    category_name = category,
    subcategory_name = subcategory,
    subcategory_names = subcategory_names,
    is_adult = fallback.is_adult,
    confidence = 0.66,
    reason = "Matched a known franchise/character alias from user-provided metadata hints.",
    source = "domain-hint",
  }
end
M.domain_hint_analysis_from_text = domain_hint_analysis_from_text

-- ---------------------------------------------------------------------------
-- Merge AI/domain-hint result with the heuristic fallback
-- ---------------------------------------------------------------------------

local function merge_analysis(ai_result, fallback, filename, mime_type, media_kind, provider)
  local confidence = clamp_float(ai_result.confidence, 0.0, 1.0, fallback.confidence)
  local ai_title = clean_title(ai_result.title)
  local ai_category = clean_label(ai_result.category_name)
  local ai_subcategory = clean_label(ai_result.subcategory_name)
  local ai_subcategory_names = sanitize_subcategory_names(ai_result.subcategory_names, ai_subcategory, ai_category or fallback.category_name)

  local category_name, subcategory_name = classification.canonical_category_pair(
    ai_category or fallback.category_name, ai_subcategory or fallback.subcategory_name
  )
  local subcategory_names
  if confidence < 0.45 then
    category_name = fallback.category_name
    subcategory_name = fallback.subcategory_name
    subcategory_names = fallback.subcategory_names
  else
    subcategory_names = sanitize_subcategory_names(ai_subcategory_names, subcategory_name, category_name)
    if #subcategory_names == 0 then subcategory_names = fallback.subcategory_names end
  end

  local tags = merge_tags(normalize_tags(ai_result.tags), fallback.tags)
  if #tags == 0 then tags = fallback.tags end

  local raw_title = (ai_title ~= "" and ai_title) or fallback.title
  local title
  if is_bad_subject_title(raw_title, category_name, subcategory_name) then
    title = compose_specific_title(raw_title, filename, category_name, subcategory_name, tags, media_kind)
  else
    title = raw_title
  end
  if is_bad_subject_title(title, category_name, subcategory_name) then
    title = compose_specific_title("", filename, category_name, subcategory_name, tags, media_kind)
  end

  local suggested_filename = suggest_filename(
    title, filename, mime_type, category_name, subcategory_name, clean_filename_base(ai_result.suggested_filename_base)
  )

  local inferred_source = (clean_label(ai_result.source) or ""):lower()
  local source
  if inferred_source ~= "" and confidence >= 0.45 then
    source = inferred_source
  elseif provider == "gemini" and confidence >= 0.45 then
    source = "google-gemini"
  else
    source = fallback.source
  end
  local ai_description = trim(tostring(ai_result.description or "")):sub(1, 500)

  return {
    title = title,
    suggested_filename = suggested_filename,
    tags = tags,
    category_name = category_name,
    subcategory_name = subcategory_name,
    subcategory_names = subcategory_names,
    is_adult = (ai_result.is_adult and true or false) or fallback.is_adult,
    source = source,
    confidence = math.max(confidence, confidence < 0.45 and fallback.confidence or 0.0),
    size = fallback.size,
    reason = (clean_reason_text(ai_result.reason) ~= "" and clean_reason_text(ai_result.reason)) or fallback.reason,
    description = (ai_description ~= "" and ai_description) or nil,
  }
end
M.merge_analysis = merge_analysis

-- ---------------------------------------------------------------------------
-- Vision provider: Gemini only (see module header for what's not ported)
-- ---------------------------------------------------------------------------

local function character_guide_text()
  local lines = {}
  for _, entry in ipairs(CHARACTER_RECOGNITION_GUIDE) do
    lines[#lines + 1] = entry[1] .. ": " .. table.concat(entry[2], ", ")
  end
  return table.concat(lines, " | ")
end

local function vision_prompt_rules()
  return "Never use generic titles like Backgrounds, Wallpaper, Image, Art, or Artwork. "
    .. "Never use the filename, upload number, random code, or numeric ID as the title. "
    .. "Make the title natural, short, and focused on the visible subject. "
    .. "Do not write a description paragraph inside the title or reason. "
    .. "Create up to 12 short lowercase tags; skip generic wallpaper/background tags unless they add real search value. "
    .. "Prefer existing gallery-style categories when they are clearly the best fit, especially Phone Backgrounds, Desktop Backgrounds, Profile Pictures, Wallpapers, GIFs, and Videos. "
    .. "Use subcategories for franchise, series, character, form, or context beneath those broad categories. "
    .. "If none of the established categories fits well enough, you may create one new concise category name. "
    .. "You may also create new subcategory names when the visible subject is specific and reliable. "
    .. "Do not invent brand-new taxonomy when the image is ambiguous or when a broader existing category is still clearly correct. "
    .. "Use up to 3 ordered subcategories only when each one adds distinct value. "
    .. "Order subcategories from broad to specific: series or group first, then character or subject, then variant, form, or context. "
    .. "Do not repeat the main category as a subcategory. "
    .. "Do not guess names when identity is unclear; use visible traits instead. "
end

-- Mirrors _sanitize_ai_error_text(): pulls a short human-readable message out
-- of a JSON (or plain-text) error body.
local function sanitize_ai_error_text(value)
  local text = trim(tostring(value or ""))
  if text == "" then return "" end
  local ok, payload = pcall(cjson.decode, text)
  if ok and type(payload) == "table" then
    if type(payload.error) == "table" then
      local parts = { tostring(payload.error.message or "") }
      if payload.error.status and payload.error.status ~= "" then
        parts[#parts + 1] = "status=" .. tostring(payload.error.status)
      end
      text = table.concat(parts, " ")
    elseif payload.message then
      text = tostring(payload.message)
    end
  end
  return collapse_ws(text)
end

-- Redacts likely-sensitive substrings (API keys/tokens) from an error string
-- before it can end up in a client-visible response.
local function safe_ai_error(message)
  local text = sanitize_ai_error_text(message)
  text = text:gsub("[Bb]earer%s+%S+", "[REDACTED]")
  text = text:gsub("sk%-%S+", "[REDACTED]")
  text = text:gsub("[Aa][Pp][Ii][_%-]?[Kk][Ee][Yy][=:%s]+%S+", "[REDACTED]")
  text = text:gsub("[Tt]oken[=:%s]+%S+", "[REDACTED]")
  if text == "" then return "Unknown error" end
  return text
end

-- Mirrors _looks_placeholder_ai_result(): rejects a response that's clearly
-- just the JSON schema's own field names/types echoed back.
local function looks_placeholder_ai_result(payload)
  local title = clean_title(payload.title or ""):lower()
  local reason = clean_title(payload.reason or ""):lower()
  local category = (clean_label(payload.category_name) or ""):lower()
  local subcategory = (clean_label(payload.subcategory_name) or ""):lower()
  local filename_base = clean_filename_base(payload.suggested_filename_base):lower()
  if title == "string" or title == "title" then return true end
  if reason == "string" or reason == "reason" then return true end
  if category == "string" or category == "category" or category == "category-name" then return true end
  if subcategory == "string" or subcategory == "subcategory" or subcategory == "subcategory-name" then return true end
  if filename_base == "string" or filename_base == "filename" or filename_base == "suggested-filename" or filename_base == "suggested_filename" then return true end
  local sub_names = sanitize_subcategory_names(payload.subcategory_names, payload.subcategory_name, nil)
  if #sub_names > 0 then
    local all_placeholder = true
    for _, n in ipairs(sub_names) do
      local nl = n:lower()
      if nl ~= "subcategory" and nl ~= "subcategories" and nl ~= "string" and nl ~= "subcategory-name" then
        all_placeholder = false
        break
      end
    end
    if all_placeholder then return true end
  end
  local tags = normalize_tags(payload.tags)
  if #tags > 0 then
    local all_placeholder = true
    for _, t in ipairs(tags) do
      if t ~= "tag" and t ~= "tags" and t ~= "string" then all_placeholder = false; break end
    end
    if all_placeholder then return true end
  end
  return false
end

-- Mirrors _parse_model_json_response(): strips a markdown code fence if
-- present, decodes JSON, and normalizes subcategory_name/subcategory_names.
local function parse_model_json_response(text, provider_name)
  local candidate = trim(text or "")
  if candidate == "" then return nil, provider_name .. " response did not include structured text." end
  local fenced = candidate:match("```json%s*(%b{})%s*```") or candidate:match("```%s*(%b{})%s*```")
  if fenced then candidate = trim(fenced) end
  local ok, payload = pcall(cjson.decode, candidate)
  if not ok or type(payload) ~= "table" then
    local object_match = candidate:match("(%b{})")
    if not object_match then return nil, provider_name .. " returned invalid JSON." end
    local ok2, payload2 = pcall(cjson.decode, object_match)
    if not ok2 or type(payload2) ~= "table" then return nil, provider_name .. " returned invalid JSON." end
    payload = payload2
  end
  payload.subcategory_names = sanitize_subcategory_names(payload.subcategory_names, payload.subcategory_name, payload.category_name)
  if #payload.subcategory_names > 0 and not clean_label(payload.subcategory_name) then
    payload.subcategory_name = payload.subcategory_names[1]
  elseif #payload.subcategory_names == 0 then
    payload.subcategory_name = nil
  end
  if looks_placeholder_ai_result(payload) then
    return nil, provider_name .. " returned placeholder schema values."
  end
  return payload
end

-- Performs the actual Gemini generateContent HTTP call. Returns (payload) on
-- success or (nil, error_message) on failure -- never raises, so callers
-- can always fall back gracefully.
local function gemini_vision_analysis(opts)
  local prompt = "You analyze media uploads for a personal gallery. Return JSON only. "
    .. vision_prompt_rules()
    .. "Identify visible characters, franchises, subjects, and backgrounds when evidence is strong. "
    .. "Create tags for characters, franchises, moods, props, or setting only when they are reliable. "
    .. "Use this local recognition guide as hints, not proof: " .. character_guide_text() .. ". "
    .. "Prefer these main categories when they fit: " .. table.concat(KNOWN_CATEGORIES, ", ")
    .. ". If it looks like a phone wallpaper use Phone Backgrounds and place the franchise or subject inside subcategories; "
    .. "desktop wallpaper use Desktop Backgrounds and place the franchise or subject inside subcategories. "
    .. "Write the description field as 1-2 natural sentences describing what's shown — character, scene, mood, or subject. "
    .. "Do not mention AI, pipelines, gallery systems, or tools. Write as if describing the media to another person. "
    .. 'Return exactly this JSON schema: {"title":"string","description":"1-2 sentence natural description of what\'s shown",'
    .. '"suggested_filename_base":"string","tags":["tag"],"category_name":"string","subcategory_name":"string",'
    .. '"subcategory_names":["string"],"is_adult":false,"confidence":0.0,"reason":"string"}\n\n'
    .. "Filename: " .. tostring(opts.filename) .. "\n"
    .. "MIME type: " .. tostring(opts.mime_type) .. "\n"
    .. "Media kind: " .. tostring(opts.media_kind) .. "\n"
    .. "Existing title hint: " .. ((clean_title(opts.title_hint) ~= "" and clean_title(opts.title_hint)) or "(none)") .. "\n"
    .. "Existing description hint: " .. ((clean_title(opts.description_hint) ~= "" and clean_title(opts.description_hint)) or "(none)") .. "\n"
    .. "Existing tags hint: " .. ((#normalize_tags(opts.tags_hint) > 0 and table.concat(normalize_tags(opts.tags_hint), ", ")) or "(none)") .. "\n"
    .. "Local analyzer fallback title: " .. tostring(opts.fallback.title) .. "\n"
    .. "Local analyzer fallback category: " .. tostring(opts.fallback.category_name or "Wallpapers") .. "\n"
    .. "Local analyzer fallback subcategory: " .. tostring(opts.fallback.subcategory_name or "(none)")

  local payload = cjson.encode({
    contents = { { role = "user", parts = { { text = prompt }, { inline_data = { mime_type = "image/jpeg", data = opts.preview_image_b64 } } } } },
    generationConfig = { temperature = 0.15, responseMimeType = "application/json" },
  })

  -- copas.http, not ssl.https directly: this call runs inside an HTTP
  -- request handler on the shared single-threaded copas event loop, and a
  -- plain ssl.https.request blocks that OS thread (and therefore every
  -- other in-flight request this server is handling) for the full duration
  -- of the network call. copas.http yields back to the scheduler while
  -- waiting on socket I/O instead.
  --
  -- http_retry.request (not a bare copas_http.request) so a single transient
  -- timeout against Gemini doesn't immediately demote this upload to the
  -- heuristic fallback -- up to 3 attempts total, only retrying the
  -- "no response at all" case (see http_retry.lua's header comment).
  local http_retry = require("http_retry")
  local ltn12 = require("ltn12")
  local url = string.format(
    "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s",
    opts.model:gsub("[^%w%-%.]", function(c) return string.format("%%%02X", c:byte()) end),
    opts.api_key:gsub("[^%w%-%.]", function(c) return string.format("%%%02X", c:byte()) end)
  )
  local ok, status, raw = http_retry.request(function()
    local chunks = {}
    return {
      url = url,
      method = "POST",
      headers = { ["Content-Type"] = "application/json", ["Content-Length"] = tostring(#payload) },
      source = ltn12.source.string(payload),
      sink = ltn12.sink.table(chunks),
      timeout = opts.timeout_seconds,
    }, chunks
  end)
  if not ok or type(status) ~= "number" or status < 200 or status >= 300 then
    return nil, string.format("Gemini API error %s: %s", tostring(status), sanitize_ai_error_text(raw):sub(1, 180))
  end

  local decode_ok, data = pcall(cjson.decode, raw ~= "" and raw or "{}")
  if not decode_ok or type(data) ~= "table" then
    return nil, "Gemini response was not valid JSON."
  end
  local candidates = data.candidates or {}
  local parts = (candidates[1] and candidates[1].content and candidates[1].content.parts) or {}
  local texts = {}
  for _, part in ipairs(parts) do
    if part.text and part.text ~= "" then texts[#texts + 1] = trim(part.text) end
  end
  local text = trim(table.concat(texts, "\n"))
  if text == "" then
    local block_reason = (data.promptFeedback and data.promptFeedback.blockReason)
      or (candidates[1] and candidates[1].finishReason) or ""
    if block_reason ~= "" then
      return nil, "Gemini response was blocked or empty: " .. tostring(block_reason)
    end
    return nil, "Gemini response did not include structured text."
  end
  return parse_model_json_response(text, "Gemini")
end

-- ---------------------------------------------------------------------------
-- Provider selection (simplified -- see module header)
-- ---------------------------------------------------------------------------

-- Returns "gemini" if that's what settings/env resolve to (and a key is
-- available to actually use it), or "unsupported" otherwise -- meaning
-- "no real vision call will be attempted, only heuristic/domain-hint."
local function select_vision_provider(settings)
  local provider = tostring(settings.ai_provider or ""):lower()
  if provider == "google" or provider == "google-gemini" then provider = "gemini" end
  if provider == "gemini" then return "gemini" end
  if provider == "" and settings.ai_api_key and settings.ai_api_key ~= "" then return "gemini" end
  return "unsupported"
end
M.select_vision_provider = select_vision_provider

-- ---------------------------------------------------------------------------
-- Top-level entry point
-- ---------------------------------------------------------------------------

-- opts: { content, filename, mime_type, media_kind, title_hint,
--         description_hint, tags_hint, settings }
-- `opts.file_path` may be given instead of `opts.content` -- used by the
-- streaming (chunked) upload path so a large video's bytes never have to
-- be pulled fully into memory just to extract a small preview frame; both
-- media_dimensions/jpeg_preview_base64 (in-memory) and their
-- _from_path siblings (file already on disk) shell out to the same
-- ffmpeg/ffprobe commands either way.
-- Returns an analysis table shaped like SmartMediaAnalysis.to_dict().
function M.analyze_media_bytes(opts)
  local settings = opts.settings
  local size = opts.file_path and media_files.media_dimensions_from_path(opts.file_path) or media_files.media_dimensions(opts.content)
  local fallback = heuristic_analysis(
    opts.filename, opts.mime_type, opts.media_kind, opts.title_hint or "",
    opts.description_hint or "", opts.tags_hint or {}, size
  )
  local domain_hint_result = domain_hint_analysis_from_text(
    opts.filename, opts.title_hint or "", opts.description_hint or "", opts.tags_hint or {}, fallback
  )

  local provider = select_vision_provider(settings)
  local enabled = settings.ai_enabled
  if not enabled or provider ~= "gemini" then
    if domain_hint_result then
      return merge_analysis(domain_hint_result, fallback, opts.filename, opts.mime_type, opts.media_kind, provider)
    end
    return fallback
  end

  local preview_b64 = opts.file_path and media_files.jpeg_preview_base64_from_path(opts.file_path) or media_files.jpeg_preview_base64(opts.content)
  if not preview_b64 then
    if domain_hint_result then
      return merge_analysis(domain_hint_result, fallback, opts.filename, opts.mime_type, opts.media_kind, provider)
    end
    return fallback
  end

  local api_key = trim(settings.ai_api_key or "")
  if api_key == "" then
    if domain_hint_result then
      domain_hint_result.reason = (domain_hint_result.reason or "Learned gallery correction used.")
        .. " Gemini is selected, but no Gemini API key is configured."
      return merge_analysis(domain_hint_result, fallback, opts.filename, opts.mime_type, opts.media_kind, "gemini")
    end
    fallback.reason = "Gemini is selected, but no Gemini API key is configured."
    return fallback
  end

  -- Hard-capped at 30s regardless of what GALLERY_AI_TIMEOUT_SECONDS says --
  -- this call runs synchronously on the request that triggered it (an
  -- upload or the standalone /api/media/analyze preview), so whatever this
  -- is set to is directly how long that request's own client can be left
  -- waiting. Confirmed live: .env had this at 300 (5 minutes) inherited
  -- from an earlier default, which is exactly the freeze duration reported
  -- for a real upload -- auto-fill AI is best-effort by design (see the
  -- fallback/heuristic paths throughout this file), so it should never be
  -- allowed to make "upload a video" feel broken.
  local timeout_seconds = math.min(30, math.max(10, tonumber(settings.ai_timeout_seconds) or 20))
  local ai_result, err = gemini_vision_analysis({
    preview_image_b64 = preview_b64,
    filename = opts.filename,
    mime_type = opts.mime_type,
    media_kind = opts.media_kind,
    title_hint = opts.title_hint or "",
    description_hint = opts.description_hint or "",
    tags_hint = opts.tags_hint or {},
    fallback = fallback,
    api_key = api_key,
    model = settings.ai_model or "gemini-2.5-flash",
    timeout_seconds = timeout_seconds,
  })

  if not ai_result then
    local safe_err = safe_ai_error(err)
    if domain_hint_result then
      domain_hint_result.reason = (domain_hint_result.reason or "Learned gallery correction used.") .. " Primary AI unavailable: " .. safe_err
      return merge_analysis(domain_hint_result, fallback, opts.filename, opts.mime_type, opts.media_kind, "gemini")
    end
    fallback.reason = "AI suggestion unavailable, using local analyzer: " .. safe_err
    return fallback
  end

  ai_result.source = ai_result.source or "google-gemini"
  if domain_hint_result then
    local domain_confidence = clamp_float(domain_hint_result.confidence, 0.0, 1.0, 0.0)
    local ai_confidence = clamp_float(ai_result.confidence, 0.0, 1.0, 0.0)
    if ai_confidence < 0.55 then ai_result = domain_hint_result end
  end
  return merge_analysis(ai_result, fallback, opts.filename, opts.mime_type, opts.media_kind, "gemini")
end

return M
