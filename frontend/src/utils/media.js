import { apiUrl, postClientDiagnostic } from "../api.js";

const preloadedMedia = new Set();
const preloadQueue = [];
let activePreloads = 0;
const MAX_PRELOADS = 2;
const MAX_SEEN_PRELOADS = 700;
const reportedMediaDiagnostics = new Set();
const MAX_SEEN_DIAGNOSTICS = 800;

// Widths the grid cards request. Shared with preloadMediaAssets so a
// preload warms the exact URL the card will ask for -- they used to differ
// (preload 360/640 vs card 640/720), so every preload was a wasted
// download followed by a second fetch of a different size.
export const CARD_IMAGE_WIDTH = 640;
export const CARD_VIDEO_THUMB_WIDTH = 420;

export function isPerfLiteRuntime() {
  if (typeof document === "undefined") return false;
  return document.documentElement.classList.contains("perf-lite");
}

function defaultThumbWidth() {
  return isPerfLiteRuntime() ? 360 : 640;
}

function scheduleIdle(callback) {
  if (typeof window === "undefined") return;
  if ("requestIdleCallback" in window) {
    window.requestIdleCallback(callback, { timeout: 1600 });
  } else {
    window.setTimeout(callback, 80);
  }
}

function pumpPreloadQueue() {
  if (typeof Image === "undefined") return;
  while (activePreloads < MAX_PRELOADS && preloadQueue.length) {
    const src = preloadQueue.shift();
    activePreloads += 1;
    const image = new Image();
    image.decoding = "async";
    image.loading = "eager";
    image.onload = image.onerror = () => {
      activePreloads = Math.max(0, activePreloads - 1);
      scheduleIdle(pumpPreloadQueue);
    };
    image.src = src;
  }
}

export function thumbUrl(item, width = defaultThumbWidth()) {
  if (!item || item.locked) return "";
  if (isGifMedia(item)) return item.url || item.preview_url || "";
  if (item.thumb_url) return withQuery(item.thumb_url, { w: width });
  if (item.media_kind === "image" && item.preview_url) return withQuery(item.preview_url, { size: "card" });
  if ((item.media_kind === "image" || item.media_kind === "video") && item.id) return apiUrl(`/api/media/${item.id}/thumb?w=${width}`);
  return "";
}

export function isGifMedia(item) {
  const mime = String(item?.mime_type || "").toLowerCase();
  const name = String(item?.original_filename || item?.storage_path || item?.url || "").toLowerCase();
  return mime === "image/gif" || name.endsWith(".gif");
}

function withQuery(url, params) {
  if (!url) return "";
  try {
    const absolute = /^https?:\/\//i.test(url);
    const parsed = new URL(url, window.location.origin);
    Object.entries(params || {}).forEach(([key, value]) => {
      if (value !== undefined && value !== null && value !== "") parsed.searchParams.set(key, String(value));
    });
    return absolute ? parsed.toString() : parsed.pathname + parsed.search + parsed.hash;
  } catch (_error) {
    const separator = url.includes("?") ? "&" : "?";
    return `${url}${separator}${new URLSearchParams(params).toString()}`;
  }
}

export function mediaImageSources(item, options = {}) {
  if (!item || item.locked) return [];
  const width = options.width || defaultThumbWidth();
  const urls = [];
  const push = (value) => {
    const url = String(value || "").trim();
    if (!url || urls.includes(url)) return;
    urls.push(url);
  };
  if (isGifMedia(item)) {
    push(item.url);
    push(item.preview_url);
    push(item.thumb_url);
    return urls;
  }
  if (item.media_kind === "video") {
    push(item.thumb_url ? withQuery(item.thumb_url, { w: width }) : (item.id ? apiUrl(`/api/media/${item.id}/thumb?w=${width}`) : ""));
    return urls;
  }
  if (item.media_kind === "image") {
    push(item.thumb_url ? withQuery(item.thumb_url, { w: width }) : (item.id ? apiUrl(`/api/media/${item.id}/thumb?w=${width}`) : ""));
    push(withQuery(item.preview_url || (item.id ? apiUrl(`/api/media/${item.id}/preview`) : ""), { size: options.previewSize || "detail" }));
    push(item.url || (item.id ? apiUrl(`/api/media/${item.id}/file`) : ""));
    return urls;
  }
  push(item.thumb_url);
  push(item.preview_url);
  push(item.url);
  return urls;
}

function sourceLabel(src) {
  const value = String(src || "").trim();
  if (!value) return "missing";
  try {
    const parsed = new URL(value, window.location.origin);
    const path = parsed.pathname.toLowerCase();
    if (path.includes("/thumb")) return "thumb";
    if (path.includes("/preview")) return `preview:${parsed.searchParams.get("size") || "card"}`;
    if (path.includes("/file")) return `file:${parsed.searchParams.get("quality") || "original"}`;
    if (path.endsWith(".gif")) return "gif";
    return "original";
  } catch (_error) {
    if (value.includes("/thumb")) return "thumb";
    if (value.includes("/preview")) return "preview";
    if (value.includes("/file")) return "file";
    return "original";
  }
}

export function reportMediaLoadDiagnostic({
  mediaId,
  mediaKind = "",
  context = "",
  outcome = "",
  sourceIndex = 0,
  sources = [],
}) {
  const normalizedMediaId = Number(mediaId || 0);
  if (!normalizedMediaId || !outcome || !context) return;
  const labels = (sources || []).map((value) => sourceLabel(typeof value === "string" ? value : value?.src)).filter(Boolean);
  const chosenSource = labels[sourceIndex] || "";
  const failedSources = outcome === "all-failed" ? labels : labels.slice(0, Math.max(0, sourceIndex));
  const signature = [
    normalizedMediaId,
    String(context).trim().toLowerCase(),
    String(outcome).trim().toLowerCase(),
    chosenSource,
    failedSources.join(">"),
  ].join("|");
  if (reportedMediaDiagnostics.has(signature)) return;
  reportedMediaDiagnostics.add(signature);
  // Evict the single oldest entry (Set iteration order = insertion order)
  // instead of clearing the whole set -- a wholesale clear meant every
  // already-reported media on the page would re-fire its diagnostic beacon
  // the instant the cap was hit, in a burst, rather than just the normal
  // one-eviction-per-new-entry steady state this keeps instead.
  if (reportedMediaDiagnostics.size > MAX_SEEN_DIAGNOSTICS) {
    const oldest = reportedMediaDiagnostics.values().next().value;
    if (oldest !== undefined) reportedMediaDiagnostics.delete(oldest);
  }
  postClientDiagnostic(`/api/media/${normalizedMediaId}/diagnostics/load`, {
    context,
    outcome,
    media_kind: mediaKind,
    selected_source: chosenSource,
    failed_sources: failedSources,
    source_count: labels.length,
  });
}

// Video/HLS playback telemetry -- companion to reportMediaLoadDiagnostic
// above, for the richer set of events only a <video>/hls.js instance can
// observe. No dedup needed (unlike the load diagnostic's signature-based
// one): callers fire this at most once per playback session, on teardown.
export function reportMediaPlaybackDiagnostic({
  mediaId,
  outcome = "",
  quality = "",
  timeToFirstFrameMs = null,
  stallCount = 0,
  stallTotalMs = 0,
  qualityDowngradeCount = 0,
  usingHlsJs = false,
}) {
  const normalizedMediaId = Number(mediaId || 0);
  if (!normalizedMediaId || !outcome) return;
  postClientDiagnostic(`/api/media/${normalizedMediaId}/diagnostics/playback`, {
    outcome,
    quality,
    time_to_first_frame_ms: timeToFirstFrameMs,
    stall_count: stallCount,
    stall_total_ms: stallTotalMs,
    quality_downgrade_count: qualityDowngradeCount,
    using_hls_js: usingHlsJs,
  });
}

export function imageQualityUrl(item, quality = "medium") {
  if (!item || item.locked) return "";
  if (isGifMedia(item)) return item.url || item.preview_url || "";
  if (quality === "high") return item.url || item.preview_url || "";
  if (quality === "low") return withQuery(item.preview_url || thumbUrl(item, 520), { size: "card" });
  return withQuery(item.preview_url || thumbUrl(item, 1280), { size: "detail" });
}

// Lightweight muted/looping grid-card hover previews use a plain <video>
// tag with no hls.js attached (spinning up a full HLS instance per card
// in a scrollable grid would be wasteful) -- these keep using the
// original single-file, Range-served endpoint rather than HLS.
export function videoPreviewUrl(item, quality = "low") {
  if (!item || item.locked) return "";
  return withQuery(item.url || "", { quality });
}

// Real HLS instead of a single Range-served file: "original"/"high" (no
// explicit quality) used to point at the master playlist for "genuine"
// adaptive bitrate, letting hls.js's own ABR heuristic pick a rendition.
// Reverted: hls.js has no bandwidth history on a cold connection, so its
// default estimate (~500kbps) sits below every transcoded rendition
// except 144p -- on a video nobody has watched yet, EVERY rendition is
// cold, so this meant first playback almost always landed on 144p and
// still paid the full cold-transcode wait, while the one rendition that's
// actually fast regardless of file size (original/"-c copy", pure remux,
// see routes.lua's ensure_hls_variant) sat unused in the master playlist
// nobody ever actually watched via. "Original"/no quality picked now goes
// straight at that single fast rendition instead of gambling through ABR
// -- master.m3u8 was never exposed as its own "Auto" option in
// MediaDetailPage's qualityOptions anyway, so nothing that picked
// "original" wanted ABR specifically; they wanted the source quality.
export function videoQualityUrl(item, quality = "original") {
  if (!item || item.locked || !item.url) return "";
  try {
    const absolute = /^https?:\/\//i.test(item.url);
    const parsed = new URL(item.url, window.location.origin);
    if (!parsed.pathname.endsWith("/file")) return item.url;
    const base = parsed.pathname.slice(0, -"/file".length);
    // "auto" is the one quality that points at the MASTER playlist and
    // lets the player adapt across the whole ladder. It is offered only
    // on the hls.js path (see VideoPlayer.jsx's `abrAvailable`), where
    // the starting rendition can be pinned so a cold connection can't
    // open on 144p -- the failure that got ABR reverted the first time.
    if (quality === "auto") {
      parsed.pathname = `${base}/hls/master.m3u8`;
      return absolute ? parsed.toString() : parsed.pathname + parsed.search + parsed.hash;
    }
    const rendition = (!quality || quality === "original" || quality === "high") ? "original" : quality;
    // Browser-safe MP4 (H.264/AAC, flagged direct_play by the server):
    // play the stored file itself, Range-streamed. The HLS "original" would
    // be a full copy of the video written to the uploads drive first. If a
    // browser can't decode it anyway, VideoPlayer's error path drops to a
    // transcoded quality the same as before.
    if (rendition === "original" && item.direct_play) return item.url;
    parsed.pathname = `${base}/hls/${rendition}/playlist.m3u8`;
    return absolute ? parsed.toString() : parsed.pathname + parsed.search + parsed.hash;
  } catch (_error) {
    return item.url;
  }
}

// Offset paging over a live feed can repeat a post at the page seam (a new
// upload shifts everything down by one between requests), so appended pages
// skip ids that are already on screen instead of rendering duplicate keys.
export function appendUniqueMedia(rows, nextRows) {
  const seen = new Set(rows.map((item) => Number(item.id)));
  return [...rows, ...nextRows.filter((item) => !seen.has(Number(item.id)))];
}

export function replaceMedia(rows, updated) {
  if (!updated) return rows;
  return rows.map((item) => Number(item.id) === Number(updated.id) ? updated : item);
}

export function preloadMediaAssets(items, options = {}) {
  if (typeof Image === "undefined") return;
  // Respect a viewer who asked the browser to save data.
  if (typeof navigator !== "undefined" && navigator.connection?.saveData) return;
  const perfLite = isPerfLiteRuntime();
  const limit = Math.max(0, Math.min(Number(options.limit || (perfLite ? 2 : 6)), perfLite ? 3 : 12));
  for (const item of (items || []).slice(0, limit)) {
    // GIF "thumbnails" are the full animated file -- far too heavy to fetch
    // speculatively.
    if (!item || item.locked || isGifMedia(item)) continue;
    const src = item.media_kind === "video"
      ? mediaImageSources(item, { width: CARD_VIDEO_THUMB_WIDTH, previewSize: "card" })[0]
      : mediaImageSources(item, { width: options.width || CARD_IMAGE_WIDTH, previewSize: "detail" })[0];
    if (!src || preloadedMedia.has(src)) continue;
    preloadedMedia.add(src);
    preloadQueue.push(src);
  }
  if (preloadedMedia.size > MAX_SEEN_PRELOADS) {
    for (const src of preloadedMedia) {
      preloadedMedia.delete(src);
      if (preloadedMedia.size <= Math.floor(MAX_SEEN_PRELOADS * 0.7)) break;
    }
  }
  // Drop anything still queued past a sane depth (fast infinite scroll can
  // enqueue faster than two-at-a-time preloading drains).
  if (preloadQueue.length > 24) preloadQueue.splice(0, preloadQueue.length - 24);
  scheduleIdle(pumpPreloadQueue);
}
