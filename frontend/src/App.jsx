import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Navigate, Route, Routes, useLocation, useNavigate } from "react-router-dom";
import { apiFetch, cachedApiFetch, clearApiCache, forceRefreshRemoteOrigin, prefetchApi, readStoredUser, readToken, resolveApiUrl, toQuery, writeStoredUser, writeToken } from "./api.js";
import { Shell } from "./components/Shell.jsx";
import { BackgroundMusicPlayer } from "./components/BackgroundMusicPlayer.jsx";
import { CommandPalette } from "./components/CommandPalette.jsx";
import { ErrorBoundary } from "./components/ErrorBoundary.jsx";
import { ScrollManager } from "./components/ScrollManager.jsx";
import { NotFound, SkeletonGrid } from "./components/ui.jsx";
import { DEFAULT_SETTINGS, PAGE_SIZE, setRuntimeMaxUploadBytes } from "./config.js";
import { useLiveRefresh } from "./hooks/useLiveRefresh.js";
import { galleryClassName, galleryStyle } from "./utils/appearance.js";
import { reconcileValue } from "./utils/reconcile.js";
// The home page ships in the main bundle so the first paint never waits on
// a second request; every other route (and the lightbox, which pulls in the
// whole video player + hls.js) is split into its own chunk and fetched the
// first time it's needed.
import { DiscoverPage } from "./pages/DiscoverPage.jsx";

// Named exports -> default-export shape React.lazy expects. A failed chunk
// load (a deploy replaced the hashed files under an open tab) reloads the
// page once to pick up the new build instead of leaving a dead route.
//
// Once a chunk has loaded (prefetched at idle, or opened before) the page
// renders directly instead of through React.lazy: lazy always suspends on
// first render, and React holds a suspended reveal for ~300ms, which was
// most of the delay opening the first post in the lightbox.
function lazyPage(loader, name) {
  let Loaded = null;
  const load = () => loader().then((module) => {
    Loaded = module[name];
    return module;
  });
  const Lazy = lazy(() => load().then(
    (module) => ({ default: module[name] }),
    (error) => {
      const flag = "nyxframe_chunk_reload";
      try {
        if (!sessionStorage.getItem(flag)) {
          sessionStorage.setItem(flag, "1");
          window.location.reload();
          return new Promise(() => {});
        }
        sessionStorage.removeItem(flag);
      } catch (_storageError) {
        // Storage unavailable -- fall through to the error boundary.
      }
      throw error;
    },
  ));
  function Page(props) {
    // Fixed per mount, so a chunk finishing mid-render never swaps the
    // element type (which would remount the page and drop its state).
    const [Direct] = useState(() => Loaded);
    return Direct ? <Direct {...props} /> : <Lazy {...props} />;
  }
  Page.preload = () => load().catch(() => {});
  return Page;
}

const AdminPage = lazyPage(() => import("./pages/AdminPage.jsx"), "AdminPage");
const AuthPage = lazyPage(() => import("./pages/AuthPage.jsx"), "AuthPage");
const CategoryPage = lazyPage(() => import("./pages/CategoryPage.jsx"), "CategoryPage");
const CollectionsPage = lazyPage(() => import("./pages/CollectionsPage.jsx"), "CollectionsPage");
const FeedPage = lazyPage(() => import("./pages/FeedPage.jsx"), "FeedPage");
const FriendsPage = lazyPage(() => import("./pages/FriendsPage.jsx"), "FriendsPage");
const MediaDetailPage = lazyPage(() => import("./pages/MediaDetailPage.jsx"), "MediaDetailPage");
const MessagesPage = lazyPage(() => import("./pages/MessagesPage.jsx"), "MessagesPage");
const OtherProjectsPage = lazyPage(() => import("./pages/OtherProjectsPage.jsx"), "OtherProjectsPage");
const ProfilePage = lazyPage(() => import("./pages/ProfilePage.jsx"), "ProfilePage");
const SearchPage = lazyPage(() => import("./pages/SearchPage.jsx"), "SearchPage");
const SettingsPage = lazyPage(() => import("./pages/SettingsPage.jsx"), "SettingsPage");
const SimilarMediaPage = lazyPage(() => import("./pages/SimilarMediaPage.jsx"), "SimilarMediaPage");
const VisualSearchPage = lazyPage(() => import("./pages/VisualSearchPage.jsx"), "VisualSearchPage");
const StudioPage = lazyPage(() => import("./pages/StudioPage.jsx"), "StudioPage");
const TrendingPage = lazyPage(() => import("./pages/TrendingPage.jsx"), "TrendingPage");
const UploadPage = lazyPage(() => import("./pages/UploadPage.jsx"), "UploadPage");
const UsersPage = lazyPage(() => import("./pages/UsersPage.jsx"), "UsersPage");
const StatusPage = lazyPage(() => import("./pages/StatusPage.jsx"), "StatusPage");
const ApiDocsPage = lazyPage(() => import("./pages/ApiDocsPage.jsx"), "ApiDocsPage");
const YearRecapPage = lazyPage(() => import("./pages/YearRecapPage.jsx"), "YearRecapPage");
const Lightbox = lazyPage(() => import("./components/Lightbox.jsx"), "Lightbox");

// Cold load straight onto a lazy route (a shared /media/123 link, a search
// URL): main.jsx waits for that page's chunk before the first render, so it
// mounts directly instead of suspending (React holds a suspended reveal for
// ~300ms even after the chunk arrives). The chunk download is the same
// either way; only the forced wait goes away.
const ROUTE_CHUNKS = [
  [/^\/media\/[^/]+\/similar/, () => SimilarMediaPage],
  [/^\/media\//, () => MediaDetailPage],
  [/^\/category\//, () => CategoryPage],
  [/^\/(following|liked|for-you)\b/, () => FeedPage],
  [/^\/trending\b/, () => TrendingPage],
  [/^\/search\b/, () => SearchPage],
  [/^\/users\/[^/]+/, () => ProfilePage],
  [/^\/users\b/, () => UsersPage],
  [/^\/collections\b/, () => CollectionsPage],
  [/^\/visual-search\b/, () => VisualSearchPage],
  [/^\/friends\b/, () => FriendsPage],
  [/^\/messages\b/, () => MessagesPage],
  [/^\/studio\b/, () => StudioPage],
  [/^\/upload\b/, () => UploadPage],
  [/^\/settings\b/, () => SettingsPage],
  [/^\/admin\b/, () => AdminPage],
  [/^\/other-projects\b/, () => OtherProjectsPage],
  [/^\/status\b/, () => StatusPage],
  [/^\/api-docs\b/, () => ApiDocsPage],
  [/^\/year-recap\b/, () => YearRecapPage],
  [/^\/login\b/, () => AuthPage],
];

export function preloadRouteFor(pathname) {
  const match = ROUTE_CHUNKS.find(([pattern]) => pattern.test(pathname || "/"));
  return match ? match[1]().preload() : Promise.resolve();
}

// Warm the chunks people are most likely to open next once the app is idle,
// so the first click into a post or a feed doesn't wait on a download.
function prefetchLikelyRoutes() {
  const run = () => {
    [Lightbox, MediaDetailPage, TrendingPage, ProfilePage, CategoryPage, SearchPage].forEach((page) => page.preload());
  };
  if (typeof window === "undefined") return;
  if (navigator.connection?.saveData) return;
  if ("requestIdleCallback" in window) window.requestIdleCallback(run, { timeout: 4000 });
  else window.setTimeout(run, 2500);
}

function RouteFallback() {
  return <div className="page"><SkeletonGrid count={8} /></div>;
}

const BOOT_TIPS = [
  "Video thumbnails are pre-warmed in the background so gallery cards do not wait on first open.",
  "The detail player now remounts when you switch quality, so medium and low really swap sources.",
  "Discover and user search are prefetched while the overlay is up so the first deck lands faster.",
  "Muted preview clips now lean on the lighter video ladder instead of reaching for the largest file first.",
];
const SITE_BACKGROUND_KEY = "image_gallery_site_background";
const SITE_BACKGROUND_REFRESH_MS = 5 * 60_000;

function readSiteBackground() {
  try {
    const raw = localStorage.getItem(SITE_BACKGROUND_KEY);
    return raw ? JSON.parse(raw) : null;
  } catch (_error) {
    return null;
  }
}

function writeSiteBackground(background) {
  try {
    if (background) localStorage.setItem(SITE_BACKGROUND_KEY, JSON.stringify(background));
    else localStorage.removeItem(SITE_BACKGROUND_KEY);
  } catch (_error) {
    // Storage can be unavailable in hardened browser contexts.
  }
}

function clearSiteBackground() {
  writeSiteBackground(null);
  document.documentElement.style.setProperty("--site-background-image", "none");
  document.body.dataset.backgroundReady = "0";
}

function galleryPageSize(settings) {
  const parsed = Number(settings?.items_per_page);
  if (!Number.isFinite(parsed)) return PAGE_SIZE;
  return Math.min(60, Math.max(12, Math.round(parsed)));
}

const QUICK_THEME_KEY = "ig_quick_theme";
const QUICK_THEME_CYCLE = { "": "dark", "dark": "light", "light": "" };

function App() {
  const navigate = useNavigate();
  const location = useLocation();
  const [token, setTokenState] = useState(() => readToken());
  const [user, setUserState] = useState(() => readStoredUser());
  const [lookups, setLookups] = useState({ categories: [], tags: [], live: null });
  const [toast, setToast] = useState(null);
  // readStoredUser(), not readToken(): the web app no longer persists a
  // bearer token at all (see loginWith below), so readToken() is now
  // permanently empty for browser sessions -- the cached user object
  // (still written on every login, cookie or not) is the actual signal
  // that a still-possibly-valid cookie session might exist to restore via
  // refreshMe()'s unconditional /api/me call further down.
  const [bootPhase, setBootPhase] = useState(() => readStoredUser() ? "Checking your gallery access" : "Opening public gallery");
  const [bootTipIndex, setBootTipIndex] = useState(0);
  const [bootDismissed, setBootDismissed] = useState(false);
  const [bootLeaving, setBootLeaving] = useState(false);
  const [sessionReady, setSessionReady] = useState(() => !readStoredUser());
  const [lookupsReady, setLookupsReady] = useState(false);
  const bootMountedAt = useRef(performance.now());
  const [deckPrimed, setDeckPrimed] = useState(false);
  const [lightbox, setLightbox] = useState(null);
  const [quickTheme, setQuickTheme] = useState(() => localStorage.getItem(QUICK_THEME_KEY) || "");

  const showToast = useCallback((message, kind = "info") => {
    setToast({ message, kind, id: Date.now() });
  }, []);

  const openLightbox = useCallback((items, index, options) => setLightbox({ items, index: index ?? 0, autoplay: !!options?.autoplay }), []);
  const closeLightbox = useCallback(() => setLightbox(null), []);
  const cycleTheme = useCallback(() => {
    setQuickTheme((current) => {
      const next = QUICK_THEME_CYCLE[current] ?? "";
      if (next) localStorage.setItem(QUICK_THEME_KEY, next);
      else localStorage.removeItem(QUICK_THEME_KEY);
      return next;
    });
  }, []);

  // The /api/me poll (every 45s) and the lookups poll (every 30s) almost
  // always return exactly what's already in state. Handing React a fresh
  // object anyway rebuilt `ctx`, which every page and every memoized
  // MediaCard receives -- i.e. the entire visible app re-rendered twice a
  // minute for no change at all. Keep the old identity when nothing moved.
  const setSessionUser = useCallback((nextUser) => {
    setUserState((current) => reconcileValue(current, nextUser ?? null));
    writeStoredUser(nextUser);
  }, []);

  const logout = useCallback((withNotice = true) => {
    void apiFetch("/api/auth/logout", { method: "POST", timeoutMs: 5000 }).catch(() => null);
    writeToken("");
    writeStoredUser(null);
    clearApiCache();
    setTokenState("");
    setUserState(null);
    setSessionReady(true);
    if (withNotice) showToast("Signed out.", "success");
    navigate("/");
  }, [navigate, showToast]);

  const refreshLookups = useCallback(async () => {
    try {
      const [categories, tags, live] = await Promise.allSettled([
        cachedApiFetch("/api/categories", { ttl: 10 * 60_000, staleTtl: 60 * 60_000, storage: "local" }),
        cachedApiFetch("/api/tags", { ttl: 10 * 60_000, staleTtl: 60 * 60_000, storage: "local" }),
        cachedApiFetch("/api/live/checks", { ttl: 30_000, staleTtl: 5 * 60_000 }),
      ]);
      if (live.status === "fulfilled") setRuntimeMaxUploadBytes(live.value?.max_upload_bytes);
      // When the live-checks call fails (tunnel down / backend restart), force the
      // remote-origin cache to expire so the very next API request re-reads
      // live-config.json and picks up the rotated tunnel URL immediately.
      if (live.status === "rejected") forceRefreshRemoteOrigin();
      setLookups((current) => {
        // A failed refresh keeps the last good categories/tags rather than
        // blanking every category pill and filter until the next poll.
        const next = {
          categories: categories.status === "fulfilled" ? categories.value.categories || [] : current.categories,
          tags: tags.status === "fulfilled" ? tags.value.tags || [] : current.tags,
          // server_time ticks on every response; nothing reads it, and
          // keeping it would make every health poll look like a change.
          live: live.status === "fulfilled" && live.value ? { ...live.value, server_time: undefined } : null,
        };
        const merged = {
          categories: reconcileValue(current.categories, next.categories),
          tags: reconcileValue(current.tags, next.tags),
          live: reconcileValue(current.live, next.live),
        };
        const unchanged = merged.categories === current.categories && merged.tags === current.tags && merged.live === current.live;
        return unchanged ? current : merged;
      });
    } finally {
      setLookupsReady(true);
    }
  }, []);

  const loginWith = useCallback((payload) => {
    // The web app never stores payload.token as a bearer credential: the
    // login/2FA response that hands us this payload already came with a
    // Set-Cookie (HttpOnly, Secure, SameSite=None -- see gallery_auth.lua's
    // session_cookie()), and every apiFetch already sends credentials:
    // "include", so the cookie alone carries the session from here.
    // Deliberately NOT the same tradeoff as the iOS app, which has no
    // shared cookie jar with the site and genuinely needs the bearer
    // token in GalleryAPIClient.swift -- that path (options.token /
    // readToken() in api.js) stays fully intact for it. A localStorage-
    // held bearer token is readable by any script that runs on the page
    // (XSS), unlike an HttpOnly cookie the page's own JS can't touch --
    // no reason for the browser session to take on that exposure when
    // the cookie the backend already issues does the job. "cookie-session"
    // is the same sentinel refreshMe() already falls back to below; this
    // just makes it the normal path instead of a rarely-hit fallback.
    writeToken("");
    writeStoredUser(payload.user);
    clearApiCache();
    setTokenState("cookie-session");
    setUserState(payload.user);
    setSessionReady(true);
    setLookupsReady(false);
    setDeckPrimed(false);
    bootMountedAt.current = performance.now();
    setBootDismissed(false);
    setBootLeaving(false);
    setBootPhase("Curating your live feed");
    setBootTipIndex(0);
    showToast(`Welcome, ${payload.user?.display_name || payload.user?.username || "friend"}.`, "success");
    refreshLookups();
    navigate("/");
  }, [navigate, refreshLookups, showToast]);

  const refreshMe = useCallback(async () => {
    try {
      const data = await apiFetch("/api/me");
      setSessionUser(data.user);
      if (!readToken() && data.user) setTokenState("cookie-session");
    } catch (error) {
      if (error.status === 401) {
        writeToken("");
        writeStoredUser(null);
        setTokenState("");
        setSessionUser(null);
      }
    } finally {
      setSessionReady(true);
    }
  }, [setSessionUser]);

  useEffect(() => {
    refreshMe();
    refreshLookups();
    prefetchLikelyRoutes();
  }, [refreshMe, refreshLookups]);

  useLiveRefresh(refreshLookups, { interval: 30_000 });
  useLiveRefresh(refreshMe, { enabled: Boolean(token), interval: 45_000 });

  useEffect(() => {
    if (!toast) return undefined;
    const timer = window.setTimeout(() => setToast(null), 3600);
    return () => window.clearTimeout(timer);
  }, [toast]);

  useEffect(() => {
    if (bootDismissed) return undefined;
    const timer = window.setInterval(() => {
      setBootTipIndex((current) => (current + 1) % BOOT_TIPS.length);
    }, 3200);
    return () => window.clearInterval(timer);
  }, [bootDismissed]);

  useEffect(() => {
    let cancelled = false;
    let refreshTimer = 0;

    const scheduleRefresh = (delay) => {
      window.clearTimeout(refreshTimer);
      refreshTimer = window.setTimeout(() => {
        void refreshSiteBackground({ force: true });
      }, Math.max(30_000, Number(delay) || SITE_BACKGROUND_REFRESH_MS));
    };

    const applySiteBackground = async (background, { persist = true } = {}) => {
      const rawUrl = String(background?.url || "").trim();
      if (!rawUrl) return false;
      const resolvedUrl = await resolveApiUrl(rawUrl);
      if (!resolvedUrl || cancelled) return false;
      const withBust = `${resolvedUrl}${resolvedUrl.includes("?") ? "&" : "?"}bg=${background?.id || Date.now()}`;
      await new Promise((resolve) => {
        const preload = new Image();
        preload.decoding = "async";
        preload.onload = () => {
          if (!cancelled) {
            const root = document.documentElement;
            const nextImage = `url("${withBust.replace(/["\\]/g, "\\$&")}")`;
            const previousImage = root.style.getPropertyValue("--site-background-image");
            const hasPrevious = document.body.dataset.backgroundReady === "1" && previousImage && previousImage !== "none";
            if (hasPrevious) {
              // Show the outgoing image on the ::after layer at full opacity (no
              // transition), swap ::before to the new image underneath it, then
              // fade ::after out over 8s to reveal the new image.
              root.style.setProperty("--site-background-image-prev", previousImage);
              root.classList.add("bg-no-prev-transition");
              document.body.classList.add("bg-prev-visible");
              void root.offsetHeight; // force reflow before re-enabling the transition
              root.classList.remove("bg-no-prev-transition");
              root.style.setProperty("--site-background-image", nextImage);
              requestAnimationFrame(() => {
                document.body.classList.remove("bg-prev-visible");
              });
            } else {
              root.style.setProperty("--site-background-image", nextImage);
            }
            document.body.dataset.backgroundReady = "1";
            if (persist) writeSiteBackground({ ...background, url: rawUrl, appliedAt: Date.now() });
          }
          resolve(null);
        };
        preload.onerror = () => resolve(null);
        preload.src = withBust;
      });
      return !cancelled;
    };

    const refreshSiteBackground = async ({ force = false } = {}) => {
      const cached = readSiteBackground();
      const cachedAge = Date.now() - Number(cached?.appliedAt || 0);
      if (!force && cached?.url && cachedAge < SITE_BACKGROUND_REFRESH_MS) {
        await applySiteBackground(cached, { persist: false });
        scheduleRefresh(SITE_BACKGROUND_REFRESH_MS - cachedAge);
        return;
      }
      try {
        const data = await apiFetch("/api/site/background");
        if (cancelled) return;
        if (data?.background?.url) {
          await applySiteBackground(data.background);
          scheduleRefresh((Number(data.refresh_after_seconds) || 300) * 1000);
          return;
        }
      } catch (_error) {
        // Background rotation is decorative; the gallery should remain quiet if it fails.
      }
      if (cached?.url) {
        await applySiteBackground(cached, { persist: false });
        scheduleRefresh(60_000);
        return;
      }
      clearSiteBackground();
      scheduleRefresh(SITE_BACKGROUND_REFRESH_MS);
    };

    void refreshSiteBackground();
    return () => {
      cancelled = true;
      window.clearTimeout(refreshTimer);
    };
  }, []);

  useEffect(() => {
    if (bootDismissed) return;
    if (!lookupsReady) {
      setBootPhase("Mapping categories and tags");
      return;
    }
    if (!sessionReady) {
      setBootPhase(readStoredUser() ? "Checking your gallery access" : "Opening public gallery");
    }
  }, [bootDismissed, lookupsReady, sessionReady]);

  // Priming the first gallery page used to wait for /api/categories (the
  // biggest lookup) before even starting, then held the overlay for a fixed
  // 600ms floor. Now the deck fetch starts as soon as the session is known,
  // in parallel with the lookups, and the overlay only stays up as long as
  // the data actually takes. The overlay itself fades in after ~300ms (CSS),
  // so a warm load never shows it at all.
  useEffect(() => {
    if (bootDismissed || !sessionReady) return undefined;
    let cancelled = false;
    const settings = { ...DEFAULT_SETTINGS, ...(user?.user_settings || {}) };
    const pageSize = galleryPageSize(settings);
    const sort = settings.default_sort || DEFAULT_SETTINGS.default_sort || "new";
    const discoverQuery = toQuery({ limit: pageSize + 1, offset: 0, adult: "show", sort });

    // Only the home page shows the deck; any other route (a shared link,
    // search, a profile) lifts the overlay without waiting for it and
    // primes the deck in the background instead.
    const onHome = (window.location.pathname.replace(/\/+$/, "") || "/") === "/"
      || window.location.pathname.replace(/\/+$/, "") === "/static/react";
    if (!onHome) setDeckPrimed(true);

    const primeDeck = async () => {
      if (!onHome) {
        await new Promise((resolve) => (window.requestIdleCallback || ((fn) => window.setTimeout(fn, 1500)))(resolve));
        if (cancelled) return;
      }
      setBootPhase(user ? "Curating your live feed" : "Developing preview wall");
      await Promise.allSettled([
        cachedApiFetch(`/api/media${discoverQuery}`, { ttl: 20_000, staleTtl: 5 * 60_000, storage: "session" }),
        cachedApiFetch(`/api/users/search${toQuery({ limit: 12 })}`, { ttl: 15_000, staleTtl: 3 * 60_000, storage: "session" }),
        user ? cachedApiFetch("/api/collections?mine=true", { ttl: 20_000, staleTtl: 3 * 60_000, storage: "session" }) : Promise.resolve(null),
        user ? cachedApiFetch(`/api/feed/following${toQuery({ limit: pageSize + 1, offset: 0 })}`, { ttl: 20_000, staleTtl: 3 * 60_000, storage: "session" }) : Promise.resolve(null),
      ]);
      if (cancelled) return;
      setDeckPrimed(true);
      // The next page is only needed once the viewer scrolls; fetch it when
      // the browser is idle so it doesn't compete with first-screen thumbs.
      const idle = window.requestIdleCallback || ((fn) => window.setTimeout(fn, 1200));
      idle(() => {
        prefetchApi(`/api/media${toQuery({ limit: pageSize + 1, offset: pageSize, adult: "show", sort })}`, { ttl: 60_000, staleTtl: 0, storage: "session" });
        if (user) {
          prefetchApi(`/api/feed/following${toQuery({ limit: pageSize + 1, offset: pageSize })}`, { ttl: 20_000, staleTtl: 3 * 60_000, storage: "session" });
        }
      });
    };

    primeDeck();
    return () => {
      cancelled = true;
    };
  }, [bootDismissed, sessionReady, user]);

  useEffect(() => {
    if (bootDismissed || !deckPrimed || !lookupsReady || !sessionReady) return undefined;
    let cancelled = false;
    setBootPhase("Developing preview wall");
    // Overlay not visible yet (CSS delays it ~300ms): drop it immediately.
    // Once visible, keep it up briefly so it doesn't flash, then fade.
    const shownFor = performance.now() - bootMountedAt.current - 300;
    const hold = shownFor <= 0 ? 0 : Math.max(0, 250 - shownFor);
    const timer = window.setTimeout(() => {
      if (cancelled) return;
      if (shownFor <= 0) {
        setBootDismissed(true);
        return;
      }
      setBootLeaving(true);
      window.setTimeout(() => {
        setBootDismissed(true);
        setBootLeaving(false);
      }, 300);
    }, hold);
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [bootDismissed, deckPrimed, lookupsReady, sessionReady]);

  const baseSettings = useMemo(
    () => ({ ...DEFAULT_SETTINGS, ...(user?.user_settings || {}) }),
    [user],
  );
  const effectiveSettings = useMemo(
    () => (quickTheme ? { ...baseSettings, theme_mode: quickTheme } : baseSettings),
    [baseSettings, quickTheme],
  );

  // ─── Command palette ──────────────────────────────────────────────────
  // Owned here, not in Shell, because two very different things open it:
  // the global Ctrl/Cmd+K accelerator, and the topbar's search affordance
  // (which on a phone is the ONLY search entry point, since the field
  // itself doesn't fit). Both funnel through ctx.
  const [paletteOpen, setPaletteOpen] = useState(false);
  const openCommandPalette = useCallback(() => setPaletteOpen(true), []);
  const closeCommandPalette = useCallback(() => setPaletteOpen(false), []);

  useEffect(() => {
    function onKey(event) {
      if (event.key !== "k" && event.key !== "K") return;
      if (!event.metaKey && !event.ctrlKey) return;
      // Cmd+K is unclaimed in browsers; Ctrl+K focuses the address bar in
      // Firefox/Chrome, which is exactly the gesture being replaced here,
      // so taking it over is the point rather than a collision.
      event.preventDefault();
      setPaletteOpen((value) => !value);
    }
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);

  const ctx = useMemo(() => ({
    token,
    user,
    settings: effectiveSettings,
    lookups,
    loginWith,
    logout,
    refreshMe,
    refreshLookups,
    setSessionUser,
    showToast,
    openLightbox,
    closeLightbox,
    quickTheme,
    cycleTheme,
    openCommandPalette,
  }), [closeLightbox, cycleTheme, effectiveSettings, loginWith, logout, lookups, openCommandPalette, openLightbox, quickTheme, refreshLookups, refreshMe, setSessionUser, showToast, token, user]);

  return (
    <Shell ctx={ctx} className={galleryClassName(ctx.settings)} style={galleryStyle(ctx.settings)}>
      {/* Personal "custom CSS" override -- applies only to the logged-in
          viewer's own session, since effectiveSettings only ever reflects
          the current user's own user_settings (never another user's, even
          on someone else's profile page). Equivalent to a self-applied
          browser userstyle: it can restyle what YOU see, it can never
          affect what anyone else sees, so there's no cross-user styling/
          exfiltration surface to worry about here. */}
      {effectiveSettings.custom_css ? <style>{effectiveSettings.custom_css.slice(0, 4000)}</style> : null}
      <ScrollManager />
      <CommandPalette ctx={ctx} open={paletteOpen} onClose={closeCommandPalette} />
      <ErrorBoundary resetKey={location.pathname}>
      <Suspense fallback={<RouteFallback />}>
      <Routes>
        <Route path="/" element={<DiscoverPage ctx={ctx} />} />
        <Route path="/trending" element={<TrendingPage ctx={ctx} />} />
        <Route path="/category/:categoryId" element={<CategoryPage ctx={ctx} />} />
        <Route path="/following" element={<FeedPage ctx={ctx} mode="following" />} />
        <Route path="/liked" element={<FeedPage ctx={ctx} mode="liked" />} />
        <Route path="/for-you" element={<FeedPage ctx={ctx} mode="for-you" />} />
        <Route path="/media/:mediaId" element={<MediaDetailPage ctx={ctx} />} />
        <Route path="/media/:mediaId/similar" element={<SimilarMediaPage ctx={ctx} />} />
        <Route path="/visual-search" element={<VisualSearchPage ctx={ctx} />} />
        <Route path="/collections" element={<CollectionsPage ctx={ctx} />} />
        <Route path="/users" element={<UsersPage ctx={ctx} />} />
        <Route path="/users/:username" element={<ProfilePage ctx={ctx} />} />
        <Route path="/friends" element={<FriendsPage ctx={ctx} />} />
        <Route path="/messages" element={<MessagesPage ctx={ctx} />} />
        <Route path="/studio" element={<StudioPage ctx={ctx} />} />
        <Route path="/profile" element={ctx.user ? <Navigate to={`/users/${ctx.user.username}`} replace /> : <Navigate to="/login" replace />} />
        <Route path="/upload" element={<UploadPage ctx={ctx} />} />
        <Route path="/search" element={<SearchPage ctx={ctx} />} />
        <Route path="/settings" element={<SettingsPage ctx={ctx} />} />
        <Route path="/admin" element={<AdminPage ctx={ctx} />} />
        <Route path="/other-projects" element={<OtherProjectsPage ctx={ctx} />} />
        <Route path="/status" element={<StatusPage ctx={ctx} />} />
        <Route path="/api-docs" element={<ApiDocsPage ctx={ctx} />} />
        <Route path="/year-recap" element={<YearRecapPage ctx={ctx} />} />
        <Route path="/login" element={<AuthPage ctx={ctx} />} />
        <Route path="*" element={<NotFound />} />
      </Routes>
      </Suspense>
      </ErrorBoundary>
      <BackgroundMusicPlayer />
      {!bootDismissed ? (
        <GalleryBootOverlay
          authenticated={Boolean(token && user)}
          leaving={bootLeaving}
          phase={bootPhase}
          tip={BOOT_TIPS[bootTipIndex]}
        />
      ) : null}
      {lightbox ? (
        <ErrorBoundary resetKey={lightbox} fallback={null} onError={closeLightbox}>
          <Suspense fallback={null}>
            <Lightbox ctx={ctx} lightbox={lightbox} />
          </Suspense>
        </ErrorBoundary>
      ) : null}
      {toast ? (
        <div className={`toast toast-${toast.kind}`} role="status" aria-live="polite">
          <span className="toast-message">{toast.message}</span>
          <button
            className="toast-dismiss"
            type="button"
            aria-label="Dismiss notification"
            onClick={() => setToast(null)}
          >×</button>
        </div>
      ) : null}
    </Shell>
  );
}

function GalleryBootOverlay({ phase, tip, authenticated, leaving }) {
  return (
    <div
      aria-busy="true"
      aria-live="polite"
      className={`gallery-loading-screen ${leaving ? "is-leaving" : ""}`}
      role="status"
    >
      <div className="gallery-loading-backdrop" />
      <section className="gallery-loading-panel">
        <div className="gallery-loading-hero">
          <div className="gallery-loading-lightbox" aria-hidden="true">
            <span className="gallery-loading-frame frame-back" />
            <span className="gallery-loading-frame frame-mid" />
            <span className="gallery-loading-frame frame-front" />
            <span className="gallery-loading-beam" />
            <span className="gallery-loading-core" />
          </div>
          <div className="gallery-loading-copy">
            <span className="gallery-loading-kicker">Nyxframe // Curated Media Deck</span>
            <strong>{phase}</strong>
            <p>
              {authenticated
                ? "Your studio, feed, and profile surfaces are loading behind the glass while previews and search caches come online."
                : "The public gallery deck is indexing categories, tags, and featured posts before it fades in."}
            </p>
          </div>
        </div>
        <div className="gallery-loading-status-grid">
          <article>
            <span>Deck</span>
            <strong>{authenticated ? "Signed In" : "Guest View"}</strong>
            <small>{authenticated ? "Personal feed and studio routes are being prepared." : "Public browsing tools are coming online."}</small>
          </article>
          <article>
            <span>Preview Lab</span>
            <strong>Hydrating</strong>
            <small>Thumb caches, user search, and category rails are being staged in the background.</small>
          </article>
          <article>
            <span>Tip Deck</span>
            <strong>Rotating</strong>
            <small>{tip}</small>
          </article>
        </div>
        <div className="gallery-loading-progress" aria-hidden="true">
          <span />
        </div>
      </section>
    </div>
  );
}

export default App;
