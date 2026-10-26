export const PAGE_SIZE = 24;
export const FALLBACK_MAX_UPLOAD_BYTES = 2 * 1024 * 1024 * 1024;
export let MAX_UPLOAD_BYTES = FALLBACK_MAX_UPLOAD_BYTES;

export function setRuntimeMaxUploadBytes(value) {
  const parsed = Number(value);
  if (Number.isFinite(parsed) && parsed > 0) MAX_UPLOAD_BYTES = parsed;
  return MAX_UPLOAD_BYTES;
}


export const DEFAULT_SETTINGS = {
  theme_mode: "system",
  accent_color: "#37c9a7",
  accent_secondary: "",
  gallery_bg_color: "",
  grid_density: "comfortable",
  default_sort: "new",
  items_per_page: PAGE_SIZE,
  autoplay_previews: false,
  muted_previews: true,
  reduce_motion: false,
  open_original_in_new_tab: false,
  blur_video_previews: false,
  profile_layout: "spotlight",
  profile_banner_style: "gradient",
  profile_card_style: "glass",
  profile_stat_style: "tiles",
  profile_content_focus: "balanced",
  profile_hero_alignment: "split",
  profile_avatar_shape: "circle",
  profile_media_shape: "soft",
  profile_surface_style: "standard",
  profile_social_layout: "rail",
  profile_featured_panel: "uploads",
  profile_backdrop_image_url: "",
  profile_backdrop_strength: 0.18,
  profile_surface_opacity: 1,
  profile_surface_blur: 0,
  custom_css: "",
  profile_show_joined_date: true,
  profile_show_uploads: true,
  profile_show_collections: true,
  profile_show_friends: true,
  profile_show_follow_counts: true,
  profile_name_style: "display",
  profile_header_style: "solid",
  profile_bg_color: "",
  card_hover_effect: "lift",
  card_aspect_ratio: "free",
  media_border_style: "none",
  gallery_font: "system",
  card_info_display: "below",
  column_gap: "normal",
  watermark_text: "",
};
