const TOKEN_KEY = "image_gallery_token";
const USER_KEY = "image_gallery_user";
const API_CACHE_TTL = 30_000;
const API_CACHE_STALE_TTL = 5 * 60_000;
const API_CACHE_VERSION = "v5";
const API_CACHE_STORE_PREFIX = "image_gallery_api_cache:";
const MAX_STORED_CACHE_BYTES = 700_000;
// Upper bound on in-memory GET cache entries. Every paginated feed page,
// profile, search and detail view gets its own key, so a long browsing
// session otherwise grows this map (and the payloads it pins) forever.
const MAX_MEMORY_CACHE_ENTRIES = 250;
const REMOTE_ORIGIN_KEY = "image_gallery_remote_origin";
const REMOTE_ORIGIN_TTL = 20_000;
const REMOTE_ORIGIN_STALE_TTL = 3 * 60_000;
const API_FETCH_TIMEOUT_MS = 12_000;
const REMOTE_CONFIG_TIMEOUT_MS = 8_000;
// How often to re-check live-config.json while the backend is known offline.
const REMOTE_ORIGIN_RECOVERY_POLL_MS = 5_000;
// Minimum gap between forced origin refreshes triggered by failed requests.
// Without this, N concurrent failures each spawn their own live-config.json
// GET and the console fills with duplicate fetches of the same file.
const FORCE_REFRESH_MIN_INTERVAL_MS = 4_000;

// Debug/testing aid: a scoped read-only API key (see M.resolve_api_key /
// auth_optional() in routes.lua) can be handed to the SPA via `?key=gk_...`
// on the FIRST page load, letting an automated tool (or the account owner
// on a browser the extension can't reach) render logged-in pages for
// layout/rendering checks without ever touching a password or session
// cookie. Picked up once here, stashed in sessionStorage, and stripped
// from the visible URL so it doesn't linger in the address bar/history.
// This is NOT a general auth mechanism: it only reaches the read-only
// surface auth_optional() resolves server-side (GET/detail/media-serving
// routes) -- every mutation route authenticates via a real cookie/bearer
// session directly and 401s regardless of this key, so nothing rendered
// this way can actually save/delete/upload anything.
const DEBUG_API_KEY_STORAGE = "image_gallery_debug_api_key";

function pickUpDebugApiKeyFromUrl() {
  if (typeof window === "undefined") return;
  try {
    const params = new URLSearchParams(window.location.search);
    const urlKey = params.get("key");
    if (!urlKey || !urlKey.startsWith("gk_")) return;
    sessionStorage.setItem(DEBUG_API_KEY_STORAGE, urlKey);
    params.delete("key");
    const cleaned = window.location.pathname + (params.toString() ? `?${params}` : "") + window.location.hash;
    window.history.replaceState(null, "", cleaned);
  } catch (_error) {
    // Storage/history can be unavailable in hardened browser contexts.
  }
}
pickUpDebugApiKeyFromUrl();

function debugApiKey() {
  try {
    return sessionStorage.getItem(DEBUG_API_KEY_STORAGE) || "";
  } catch (_error) {
    return "";
  }
}

function withDebugApiKey(url) {
  const key = debugApiKey();
  if (!key) return url;
  try {
    const parsed = new URL(url, window.location.origin);
    if (!parsed.searchParams.has("key")) parsed.searchParams.set("key", key);
    return parsed.toString();
  } catch (_error) {
    return url;
  }
}

const memoryCache = new Map();
const inFlightFetches = new Map();
let remoteOriginPromise = null;
let remoteOriginRefreshAfter = 0;
let remoteConfig = null;
// Timestamp of when the backend was last seen offline (via live-config status
// field or via network failure).  Used to switch to fast-poll mode.
let remoteOriginOfflineSince = 0;
let _lastForceRefreshAt = 0;

export function readToken() {
  try {
    return localStorage.getItem(TOKEN_KEY) || "";
  } catch (_error) {
    return "";
  }
}

export function writeToken(token) {
  try {
    if (token) localStorage.setItem(TOKEN_KEY, token);
    else localStorage.removeItem(TOKEN_KEY);
  } catch (_error) {
    // Storage can be unavailable in hardened browser contexts.
  }
}

export function readStoredUser() {
  try {
    const raw = localStorage.getItem(USER_KEY);
    return raw ? JSON.parse(raw) : null;
  } catch (_error) {
    return null;
  }
}

export function writeStoredUser(user) {
  try {
    if (user) localStorage.setItem(USER_KEY, JSON.stringify(user));
    else localStorage.removeItem(USER_KEY);
  } catch (_error) {
    // Storage can be unavailable in hardened browser contexts.
  }
}

export function clearApiCache(prefix = "") {
  for (const key of Array.from(memoryCache.keys())) {
    if (!prefix || key.includes(`|${prefix}`)) memoryCache.delete(key);
  }
  for (const storage of [safeStorage(browserStorage("session")), safeStorage(browserStorage("local"))]) {
    if (!storage) continue;
    for (let index = storage.length - 1; index >= 0; index -= 1) {
      const key = storage.key(index);
      if (!key?.startsWith(API_CACHE_STORE_PREFIX)) continue;
      if (!prefix || key.includes(`|${prefix}`)) storage.removeItem(key);
    }
  }
}

export function apiUrl(path) {
  if (/^https?:\/\//i.test(path)) return withDebugApiKey(path);
  const normalized = path.startsWith("/") ? path : `/${path}`;
  return withDebugApiKey(`${currentApiOrigin()}${normalized}`);
}

export async function apiFetch(path, options = {}) {
  const headers = new Headers(options.headers || {});
  const token = options.token ?? readToken();
  if (token) headers.set("Authorization", `Bearer ${token}`);
  if (!headers.has("Accept")) headers.set("Accept", "application/json");
  if (options.body && !(options.body instanceof FormData) && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }
  let response = await takeEarlyResponse(path, options, token);
  try {
    if (!response) response = await fetchWithRemoteRetry(path, options, headers);
  } catch (error) {
    if (error?.name === "AbortError") {
      if (callerAborted(options)) throw error;
      throw new Error("Request timed out. Please try again.");
    }
    throw error;
  }
  const contentType = response.headers.get("content-type") || "";
  const isJson = contentType.includes("application/json");
  const payload = isJson ? await response.json().catch(() => null) : await response.text();
  if (!response.ok) {
    const error = new Error(errorMessage(payload, response.status));
    error.status = response.status;
    error.payload = payload;
    throw error;
  }
  return payload;
}

// Responses the inline script in index.html started before this bundle
// loaded. Each is used once, only for a plain anonymous GET of the same path.
async function takeEarlyResponse(path, options, token) {
  const early = window.__nyxEarly;
  if (!early || token || !Object.prototype.hasOwnProperty.call(early, path)) return null;
  if (options.method && String(options.method).toUpperCase() !== "GET") return null;
  const pending = early[path];
  delete early[path];
  try {
    return (await pending) || null;
  } catch (_error) {
    return null;
  }
}

export async function apiFetchBlob(path, options = {}) {
  const headers = new Headers(options.headers || {});
  const token = options.token ?? readToken();
  if (token) headers.set("Authorization", `Bearer ${token}`);
  if (options.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  const response = await fetchWithRemoteRetry(path, options, headers);
  if (!response.ok) {
    const contentType = response.headers.get("content-type") || "";
    const payload = contentType.includes("application/json") ? await response.json().catch(() => null) : await response.text();
    const error = new Error(errorMessage(payload, response.status));
    error.status = response.status;
    throw error;
  }
  const filename = /filename="?([^";]+)"?/.exec(response.headers.get("content-disposition") || "")?.[1] || "download";
  return { blob: await response.blob(), filename };
}

export function downloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

export function postClientDiagnostic(path, payload) {
  const headers = new Headers({ "Content-Type": "application/json" });
  const token = readToken();
  if (token) headers.set("Authorization", `Bearer ${token}`);
  resolveApiUrl(path)
    .then((url) => fetch(url, {
      method: "POST",
      headers,
      body: JSON.stringify(payload || {}),
      credentials: "include",
      keepalive: true,
    }))
    .catch(() => {});
}

function errorMessage(payload, status) {
  const raw = payload?.detail || payload?.message || payload;
  if (!raw) return `Request failed (${status})`;
  if (Array.isArray(raw)) {
    return raw.map((item) => item?.msg || item?.message || JSON.stringify(item)).join("; ");
  }
  if (typeof raw === "object") {
    return raw.msg || raw.message || JSON.stringify(raw);
  }
  return String(raw);
}

export async function cachedApiFetch(path, options = {}) {
  const method = String(options.method || "GET").toUpperCase();
  if (method !== "GET") return apiFetch(path, options);
  const ttl = options.ttl ?? API_CACHE_TTL;
  const staleTtl = options.staleTtl ?? API_CACHE_STALE_TTL;
  const token = options.token ?? readToken();
  const storage = options.storage === "local" ? safeStorage(browserStorage("local")) : safeStorage(browserStorage("session"));
  const cacheKey = `${API_CACHE_VERSION}|${path}|${token ? "auth" : "anon"}`;
  const now = Date.now();

  const cached = memoryCache.get(cacheKey) || readStoredCache(storage, cacheKey);
  if (cached) {
    rememberInMemory(cacheKey, cached);
    if (cached.expires > now) return cached.value;
    if (cached.staleUntil > now && options.allowStale !== false) {
      // Fire-and-forget background refresh -- the caller already got
      // `cached.value` and isn't awaiting this one, unlike the `return
      // revalidateCache(...)` path below. Needs its own .catch(): a
      // network hiccup/timeout here has nowhere else to land, and
      // without this it surfaced as a genuine uncaught promise
      // rejection ("Request timed out. Please try again.") -- confirmed
      // live via Shell.jsx's site-announcement poll (cachedApiFetch with
      // a live TTL) hitting exactly this branch.
      revalidateCache(cacheKey, path, options, ttl, staleTtl, storage).catch(() => {});
      return cached.value;
    }
  }

  return revalidateCache(cacheKey, path, options, ttl, staleTtl, storage);
}

export function prefetchApi(path, options = {}) {
  cachedApiFetch(path, { ...options, allowStale: false }).catch(() => {});
}

// Keys are sorted so the same request always produces the same URL --
// cachedApiFetch keys on the path, and the home page used to download its
// first page twice because two callers listed the same params in a
// different order.
export function toQuery(params) {
  const query = new URLSearchParams();
  Object.entries(params).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).forEach(([key, value]) => {
    if (value === undefined || value === null || value === "") return;
    query.set(key, String(value));
  });
  const serialized = query.toString();
  return serialized ? `?${serialized}` : "";
}

export async function resolveApiUrl(path) {
  if (/^https?:\/\//i.test(path)) return path;
  await ensureRemoteOrigin();
  return apiUrl(path);
}

function currentApiOrigin() {
  return String(window.IMAGE_GALLERY_API_ORIGIN || "").replace(/\/+$/, "");
}

function isRemoteStaticHost() {
  return Boolean(window.IMAGE_GALLERY_REMOTE_MODE) || window.location.hostname.endsWith("github.io");
}

function staticSiteBase() {
  const configured = String(window.IMAGE_GALLERY_BASENAME || "").replace(/\/+$/, "");
  if (configured) return configured;
  if (window.location.hostname.endsWith("github.io")) {
    const first = window.location.pathname.split("/").filter(Boolean)[0];
    return first ? `/${first}` : "";
  }
  return "";
}

function remoteConfigUrl() {
  if (window.IMAGE_GALLERY_CONFIG_URL) return window.IMAGE_GALLERY_CONFIG_URL;
  const basename = staticSiteBase();
  if (basename) return `${basename}/live-config.json`;
  return "live-config.json";
}

async function ensureRemoteOrigin() {
  if (!isRemoteStaticHost()) return currentApiOrigin();
  if (currentApiOrigin() && remoteOriginRefreshAfter > Date.now()) return currentApiOrigin();
  if (!remoteOriginPromise) {
    remoteOriginPromise = loadRemoteOrigin().finally(() => {
      remoteOriginPromise = null;
    });
  }
  return remoteOriginPromise;
}

async function refreshRemoteOrigin() {
  if (!isRemoteStaticHost()) return currentApiOrigin();
  // Reuse any in-flight refresh — concurrent failed requests must not each
  // spawn their own live-config.json GET; they all share the same promise.
  if (remoteOriginPromise) return remoteOriginPromise;
  // Rate-limit forced refreshes.  When the tunnel is dead but live-config.json
  // hasn't been updated yet, rapid retries would hammer GitHub Pages CDN for
  // the same stale JSON without any benefit.
  const now = Date.now();
  if (now - _lastForceRefreshAt < FORCE_REFRESH_MIN_INTERVAL_MS && currentApiOrigin()) {
    return currentApiOrigin();
  }
  _lastForceRefreshAt = now;
  remoteOriginPromise = loadRemoteOrigin({ force: true }).finally(() => {
    remoteOriginPromise = null;
  });
  return remoteOriginPromise;
}

export function forceRefreshRemoteOrigin() {
  remoteOriginRefreshAfter = 0;
}

let _pollTimer = null;
let _pollFast = false;

export function startRemoteOriginPolling() {
  if (_pollTimer !== null || typeof window === "undefined" || !isRemoteStaticHost()) return;

  const runPoll = () => {
    _pollTimer = null;
    const isOffline = remoteOriginOfflineSince > 0;
    const interval = isOffline ? REMOTE_ORIGIN_RECOVERY_POLL_MS : REMOTE_ORIGIN_TTL;
    if (remoteOriginPromise) {
      // A request-triggered refresh is already in-flight; skip this tick and
      // reschedule so the two paths don't race to fetch the same file.
      _pollFast = isOffline;
      _pollTimer = window.setTimeout(runPoll, interval);
      return;
    }
    // Allow the periodic poll to bypass the per-request rate limit so recovery
    // is detected on schedule even when no user requests are in-flight.
    _lastForceRefreshAt = 0;
    loadRemoteOrigin({ force: true })
      .catch(() => {})
      .finally(() => {
        // Use a faster interval while the backend is known offline so recovery
        // is detected within ~5 s instead of the normal 20 s cadence.
        const stillOffline = remoteOriginOfflineSince > 0;
        _pollFast = stillOffline;
        _pollTimer = window.setTimeout(runPoll, stillOffline ? REMOTE_ORIGIN_RECOVERY_POLL_MS : REMOTE_ORIGIN_TTL);
      });
  };

  _pollFast = false;
  _pollTimer = window.setTimeout(runPoll, REMOTE_ORIGIN_TTL);
}

async function loadRemoteOrigin({ force = false } = {}) {
  const cached = readRemoteOriginCache();
  if (!force && cached?.origin && cached.updatedAt && Date.now() - cached.updatedAt < REMOTE_ORIGIN_TTL) {
    applyRemoteOrigin(cached);
    return cached.origin;
  }
  try {
    const response = await fetchWithTimeout(`${remoteConfigUrl()}?t=${Date.now()}`, { cache: "no-store" }, REMOTE_CONFIG_TIMEOUT_MS);
    if (!response.ok) throw new Error(`Remote config failed (${response.status})`);
    const text = await response.text();
    const config = parseRemoteConfig(text);
    const origin = validApiOrigin(config.gallery_url || config.api_url);
    if (origin) {
      // Backend is live — clear the offline marker.
      remoteOriginOfflineSince = 0;
      const entry = { origin, localUrls: normalizeLocalUrls(config.local_urls), updatedAt: Date.now() };
      applyRemoteOrigin(entry);
      writeRemoteOriginCache(entry);
      return origin;
    }
    // gallery_url is empty: the tunnel script has written an offline config
    // (status: "offline").  Keep the stale cached URL alive so in-flight
    // requests can still fall back to it while the new tunnel URL is being
    // negotiated — only drop it once the stale TTL has expired.
    remoteConfig = config || null;
    if (!remoteOriginOfflineSince) remoteOriginOfflineSince = Date.now();
    if (cached?.origin && (!cached.updatedAt || Date.now() - cached.updatedAt < REMOTE_ORIGIN_STALE_TTL)) {
      // Also try to fetch live-config from the stale backend origin itself —
      // if the backend is still up (e.g., tunnel rotated but the old URL still
      // briefly works, or a named tunnel with stable URL restarted) we can get
      // the freshest config directly without waiting for the git push.
      const backendOrigin = await fetchLiveConfigFromBackend(cached.origin);
      if (backendOrigin && backendOrigin !== cached.origin) {
        remoteOriginOfflineSince = 0;
        const freshEntry = { origin: backendOrigin, localUrls: normalizeLocalUrls(config.local_urls), updatedAt: Date.now() };
        applyRemoteOrigin(freshEntry);
        writeRemoteOriginCache(freshEntry);
        return backendOrigin;
      }
      applyRemoteOrigin(cached);
      return cached.origin;
    }
  } catch (_error) {
    // Network error fetching live-config.json itself (e.g., GitHub Pages down).
    // Fall back to the stale cache without marking offline.
    if (cached?.origin && (!cached.updatedAt || Date.now() - cached.updatedAt < REMOTE_ORIGIN_STALE_TTL)) {
      applyRemoteOrigin(cached);
      return cached.origin;
    }
  }
  clearRemoteOriginCache();
  return "";
}

/**
 * Ask the backend itself for the latest live-config via /api/live/config.
 * Returns the new gallery_url origin if it differs from the one we asked, or
 * "" if the backend is unreachable or returns the same/empty URL.
 */
async function fetchLiveConfigFromBackend(backendOrigin) {
  if (!backendOrigin) return "";
  try {
    const url = `${backendOrigin}/api/live/config?t=${Date.now()}`;
    const response = await fetchWithTimeout(url, { cache: "no-store", credentials: "omit" }, REMOTE_CONFIG_TIMEOUT_MS);
    if (!response.ok) return "";
    const text = await response.text();
    const config = parseRemoteConfig(text);
    return validApiOrigin(config.gallery_url || config.api_url);
  } catch (_error) {
    return "";
  }
}

async function fetchWithRemoteRetry(path, options, headers) {
  const target = await resolveApiUrl(path);
  options = { ...options, __path: path };
  try {
    const response = await fetchWithTimeout(target, { ...options, headers }, options.timeoutMs || API_FETCH_TIMEOUT_MS);
    // 503 + Retry-After is this backend's "didn't do anything, nothing to
    // undo, try again shortly" signal (e.g. upload_chunk_finish's
    // per-worker concurrency guardrail in routes.lua) -- unlike a bare
    // network timeout, a 503 means the server definitely answered without
    // starting the work, so retrying is safe for any method, not just
    // idempotent ones. Bounded to the server's own Retry-After value
    // (capped so a misbehaving/huge value can't stall the page).
    if (response.status === 503) {
      const retryAfterMs = Math.min(15_000, Math.max(0, (Number(response.headers.get("Retry-After")) || 0) * 1000));
      if (retryAfterMs > 0) {
        await new Promise((resolve) => window.setTimeout(resolve, retryAfterMs));
        return fetchWithTimeout(target, { ...options, headers }, options.timeoutMs || API_FETCH_TIMEOUT_MS);
      }
    }
    if (shouldRefreshRemoteAfterStatus(response.status, options)) {
      const retryTarget = await retryTargetFor(path, target, options);
      if (retryTarget && retryTarget !== target) {
        return fetchWithTimeout(retryTarget, { ...options, headers }, options.timeoutMs || API_FETCH_TIMEOUT_MS);
      }
    }
    return response;
  } catch (error) {
    // The page cancelled this request itself (navigated away, typed a new
    // query) -- not a network failure, so no offline marking and no retry.
    if (callerAborted(options)) throw error;
    // Plain request timeout against the CURRENT (presumably still-correct)
    // origin -- distinct from the tunnel-rotation case retryTargetFor exists
    // for below, which only helps when a DIFFERENT origin is the fix.
    // iOS/tvOS already retry their own request timeouts (GalleryAPIClient.
    // sendWithRetry); this brings web to the same behavior instead of
    // surfacing a transient timeout as a hard failure on the first miss.
    // Same-target only, and only for idempotent/side-effect-safe requests
    // (mirrors canRetryWithFreshRemote's own method gating below) so a
    // retried POST can't ever double-submit.
    if (isTimeoutError(error, options) && isSafeToRetrySameTarget(options)) {
      for (const delayMs of [500, 1500]) {
        await new Promise((resolve) => window.setTimeout(resolve, delayMs));
        try {
          return await fetchWithTimeout(target, { ...options, headers }, options.timeoutMs || API_FETCH_TIMEOUT_MS);
        } catch (retryError) {
          if (!isTimeoutError(retryError, options)) { error = retryError; break; }
          error = retryError;
        }
      }
    }
    // Network-level error — mark the backend as offline so the adaptive poller
    // switches to fast mode (5 s), then re-fetch live-config.json to pick up a
    // rotated Cloudflare tunnel URL and retry up to twice with increasing delay.
    if (isRemoteStaticHost() && !remoteOriginOfflineSince) remoteOriginOfflineSince = Date.now();
    const retryTarget = await retryTargetFor(path, target, options);
    if (retryTarget && retryTarget !== target) {
      try {
        return await fetchWithTimeout(retryTarget, { ...options, headers }, options.timeoutMs || API_FETCH_TIMEOUT_MS);
      } catch (_retryError) {
        // Second retry: pause 600 ms, force another config refresh, try once more.
        await new Promise((resolve) => window.setTimeout(resolve, 600));
        const retryTarget2 = await retryTargetFor(path, retryTarget, options);
        if (retryTarget2) {
          return fetchWithTimeout(retryTarget2, { ...options, headers }, options.timeoutMs || API_FETCH_TIMEOUT_MS);
        }
      }
    }
    throw error;
  }
}

async function retryTargetFor(path, failedTarget, options) {
  if (!canRetryWithFreshRemote(options)) return "";
  const failedOrigin = originFromUrl(failedTarget) || currentApiOrigin();
  await refreshRemoteOrigin();
  const refreshed = apiUrl(path);
  if (refreshed && refreshed !== failedTarget) return refreshed;
  return fallbackApiUrl(path, failedOrigin);
}

function shouldRefreshRemoteAfterStatus(status, options) {
  if (!canRetryWithFreshRemote(options)) return false;
  return status === 404 || status === 405 || status === 502 || status === 503 || status === 504 || (status >= 520 && status <= 526);
}

function canRetryWithFreshRemote(options) {
  const method = String(options.method || "GET").toUpperCase();
  // Always allow retry for remote-static mode.
  if (isRemoteStaticHost()) {
    if (method === "GET" || method === "HEAD") return true;
    const path = String(options.__path || "");
    if (method === "POST" && isSafeRemoteRetryPost(path)) return true;
    return false;
  }
  // In local/hybrid mode: allow a retry if live-config.json advertises a
  // gallery_url that differs from the current origin — this covers the case
  // where the Cloudflare Tunnel URL has rotated and the in-memory origin is
  // stale.  Only safe idempotent methods are retried.
  if (method === "GET" || method === "HEAD") return true;
  return false;
}

function isSafeRemoteRetryPost(path) {
  return /^\/api\/auth\/(login|register|resend-verification)(?:$|[/?#])/.test(path);
}

function fallbackApiUrl(path, failedOrigin) {
  const origin = localOriginFallback(failedOrigin);
  if (!origin) return "";
  const normalized = path.startsWith("/") ? path : `/${path}`;
  return `${origin}${normalized}`;
}

function localOriginFallback(failedOrigin) {
  const localUrls = normalizeLocalUrls(remoteConfig?.local_urls);
  for (const origin of localUrls) {
    if (!origin || origin === failedOrigin) continue;
    if (window.location.protocol === "https:" && !/^http:\/\/(localhost|127\.0\.0\.1|\[::1\])(?::|$)/i.test(origin)) continue;
    return origin;
  }
  return "";
}

function applyRemoteOrigin(entry) {
  const origin = String(entry?.origin || "").replace(/\/+$/, "");
  const current = currentApiOrigin();
  window.IMAGE_GALLERY_API_ORIGIN = origin;
  remoteOriginRefreshAfter = Date.now() + REMOTE_ORIGIN_TTL;
  remoteConfig = { ...(remoteConfig || {}), local_urls: normalizeLocalUrls(entry?.localUrls || entry?.local_urls) };
  if (origin && current && current !== origin) clearApiCache();
}

function readRemoteOriginCache() {
  const raw = readStorageValue(REMOTE_ORIGIN_KEY);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw);
    if (parsed?.origin) {
      return {
        origin: String(parsed.origin).replace(/\/+$/, ""),
        localUrls: normalizeLocalUrls(parsed.localUrls || parsed.local_urls),
        updatedAt: Number(parsed.updatedAt || 0),
      };
    }
  } catch (_error) {
    return { origin: raw.replace(/\/+$/, ""), localUrls: [], updatedAt: 0 };
  }
  return null;
}

function writeRemoteOriginCache(entry) {
  try {
    localStorage.setItem(REMOTE_ORIGIN_KEY, JSON.stringify(entry));
  } catch (_error) {
    // Storage can be unavailable in hardened browser contexts.
  }
}

function clearRemoteOriginCache() {
  window.IMAGE_GALLERY_API_ORIGIN = "";
  remoteOriginRefreshAfter = 0;
  try {
    localStorage.removeItem(REMOTE_ORIGIN_KEY);
  } catch (_error) {
    // Storage can be unavailable in hardened browser contexts.
  }
}

function parseRemoteConfig(text) {
  const raw = String(text || "").trim();
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch (_error) {
    const extracted = extractFirstJsonObject(raw);
    if (extracted) {
      try {
        return JSON.parse(extracted);
      } catch (_innerError) {
        // Fall through to field-level salvage below.
      }
    }
    return salvageRemoteConfig(raw);
  }
}

function extractFirstJsonObject(raw) {
  const start = raw.indexOf("{");
  if (start < 0) return "";
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let index = start; index < raw.length; index += 1) {
    const ch = raw[index];
    if (inString) {
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') inString = true;
    else if (ch === "{") depth += 1;
    else if (ch === "}") {
      depth -= 1;
      if (depth === 0) return raw.slice(start, index + 1);
    }
  }
  return "";
}

function salvageRemoteConfig(raw) {
  const pick = (name) => {
    const match = raw.match(new RegExp(`"${name}"\\s*:\\s*"([^"]*)"`));
    return match ? match[1] : "";
  };
  let localUrls = [];
  const localMatch = raw.match(/"local_urls"\s*:\s*(\[[\s\S]*?\])/);
  if (localMatch) {
    try {
      const parsed = JSON.parse(localMatch[1]);
      if (Array.isArray(parsed)) localUrls = parsed;
    } catch (_error) {
      localUrls = [];
    }
  }
  return {
    gallery_url: pick("gallery_url"),
    api_url: pick("api_url"),
    status: pick("status"),
    local_urls: localUrls,
    updated_at: pick("updated_at"),
  };
}

function normalizeLocalUrls(urls) {
  if (!Array.isArray(urls)) return [];
  return urls.map((url) => validApiOrigin(url)).filter(Boolean);
}

function validApiOrigin(value) {
  const raw = String(value || "").trim();
  if (!raw) return "";
  try {
    const parsed = new URL(raw, window.location.href);
    if (!["http:", "https:"].includes(parsed.protocol)) return "";
    const host = parsed.hostname.toLowerCase();
    const isLocal = host === "localhost" || host === "127.0.0.1" || host === "::1" || /^10\./.test(host) || /^192\.168\./.test(host) || /^172\.(1[6-9]|2\d|3[01])\./.test(host);
    if (window.location.protocol === "https:" && parsed.protocol !== "https:" && !isLocal) return "";
    return parsed.origin.replace(/\/+$/, "");
  } catch (_error) {
    return "";
  }
}

// The timeout always applies, even when the caller brings its own abort
// signal (it used to be dropped entirely in that case, so a request a page
// could cancel could also hang forever). Both are merged into one signal.
async function fetchWithTimeout(url, options = {}, timeoutMs = API_FETCH_TIMEOUT_MS) {
  const controller = new AbortController();
  const external = options.signal;
  const forwardAbort = () => controller.abort(external?.reason);
  if (external) {
    if (external.aborted) forwardAbort();
    else external.addEventListener("abort", forwardAbort, { once: true });
  }
  const timer = window.setTimeout(() => controller.abort(), Math.max(1000, Number(timeoutMs) || API_FETCH_TIMEOUT_MS));
  // Internal bookkeeping keys never go to fetch().
  const { __path: _path, timeoutMs: _timeout, token: _token, ttl: _ttl, staleTtl: _staleTtl, storage: _storage, allowStale: _allowStale, ...fetchOptions } = options;
  try {
    return await fetch(url, { credentials: "include", ...fetchOptions, signal: controller.signal });
  } finally {
    window.clearTimeout(timer);
    if (external) external.removeEventListener("abort", forwardAbort);
  }
}

function callerAborted(options) {
  return Boolean(options?.signal?.aborted);
}

// fetchWithTimeout's internal AbortController fires with no `reason` on a
// plain timeout, so "AbortError + the caller's own signal isn't what fired
// it" is what actually distinguishes a timeout from the page cancelling the
// request itself (callerAborted already covers the latter).
function isTimeoutError(error, options) {
  return error?.name === "AbortError" && !callerAborted(options);
}

function isSafeToRetrySameTarget(options) {
  const method = String(options.method || "GET").toUpperCase();
  if (method === "GET" || method === "HEAD") return true;
  return isSafeRemoteRetryPost(String(options.__path || ""));
}

function originFromUrl(url) {
  try {
    return new URL(url, window.location.href).origin.replace(/\/+$/, "");
  } catch (_error) {
    return "";
  }
}

function revalidateCache(cacheKey, path, options, ttl, staleTtl, storage) {
  if (inFlightFetches.has(cacheKey)) return inFlightFetches.get(cacheKey);
  // The promise is shared with every concurrent caller of the same key, so
  // one caller's abort signal must not cancel it for the others.
  const promise = apiFetch(path, { ...options, signal: undefined })
    .then((value) => {
      if (ttl > 0) {
        const entry = {
          value,
          expires: Date.now() + ttl,
          staleUntil: Date.now() + ttl + Math.max(0, staleTtl),
        };
        rememberInMemory(cacheKey, entry);
        writeStoredCache(storage, cacheKey, entry);
      }
      return value;
    })
    .finally(() => inFlightFetches.delete(cacheKey));
  inFlightFetches.set(cacheKey, promise);
  return promise;
}

// Map insertion order doubles as LRU order: re-inserting on every hit moves
// the entry to the back, so the front is always the least recently used.
function rememberInMemory(cacheKey, entry) {
  memoryCache.delete(cacheKey);
  memoryCache.set(cacheKey, entry);
  while (memoryCache.size > MAX_MEMORY_CACHE_ENTRIES) {
    const oldest = memoryCache.keys().next().value;
    if (oldest === undefined) break;
    memoryCache.delete(oldest);
  }
}

function readStorageValue(key) {
  try {
    return localStorage.getItem(key) || "";
  } catch (_error) {
    return "";
  }
}


// Probing storage is a synchronous write+delete against disk-backed
// storage; cachedApiFetch runs it on every call, so remember the answer per
// storage object instead of re-probing on every request.
const storageUsable = new WeakMap();
// Merely touching window.localStorage throws in some hardened contexts
// (sandboxed iframes, blocked site data), so resolve it defensively.
function browserStorage(kind) {
  try {
    return kind === "local" ? window.localStorage : window.sessionStorage;
  } catch (_error) {
    return null;
  }
}
function safeStorage(storage) {
  try {
    if (!storage) return null;
    if (storageUsable.has(storage)) return storageUsable.get(storage) ? storage : null;
    const probe = "__image_gallery_cache_probe__";
    storage.setItem(probe, "1");
    storage.removeItem(probe);
    storageUsable.set(storage, true);
    return storage;
  } catch (_error) {
    try { if (storage) storageUsable.set(storage, false); } catch (_ignored) { /* noop */ }
    return null;
  }
}

function readStoredCache(storage, cacheKey) {
  if (!storage) return null;
  try {
    const raw = storage.getItem(API_CACHE_STORE_PREFIX + cacheKey);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    if (!parsed || parsed.staleUntil <= Date.now()) {
      storage.removeItem(API_CACHE_STORE_PREFIX + cacheKey);
      return null;
    }
    return parsed;
  } catch (_error) {
    return null;
  }
}

function writeStoredCache(storage, cacheKey, entry) {
  if (!storage) return;
  try {
    const raw = JSON.stringify(entry);
    if (raw.length > MAX_STORED_CACHE_BYTES) return;
    storage.setItem(API_CACHE_STORE_PREFIX + cacheKey, raw);
  } catch (_error) {
    pruneStoredCache(storage);
  }
}

function pruneStoredCache(storage) {
  try {
    const cacheKeys = [];
    for (let index = 0; index < storage.length; index += 1) {
      const key = storage.key(index);
      if (key?.startsWith(API_CACHE_STORE_PREFIX)) cacheKeys.push(key);
    }
    cacheKeys.slice(0, Math.ceil(cacheKeys.length / 3)).forEach((key) => storage.removeItem(key));
  } catch (_error) {
    // Storage quota cleanup is best-effort.
  }
}
