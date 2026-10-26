// Minimal, conservative PWA service worker.
//
// Scope is intentionally the whole site ("/"), served from the root so it can control
// navigations to client-routed pages like /media/123 and /users/alice -- a service
// worker's scope can never exceed the directory it's served from, so this file must be
// served at the site root, not under /static/react/.
//
// It never touches API requests or cross-origin requests (media/API can live on a
// different tunnel/CDN origin than the page) — it only helps the app shell and its
// built JS/CSS/image assets load instantly and survive brief offline blips.
const CACHE_VERSION = "gallery-shell-v1";

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) => Promise.all(
      keys.filter((key) => key !== CACHE_VERSION).map((key) => caches.delete(key)),
    ))
      // Navigation preload: the browser starts the page request while this
      // worker boots, instead of after (saves the worker startup time --
      // tens of ms on phones -- on every page load).
      .then(() => self.registration.navigationPreload?.enable().catch(() => {}))
      .then(() => self.clients.claim()),
  );
});

// Each deploy produces new hashed filenames, so without pruning the cache
// keeps every build's bundles forever. Oldest entries go first.
const MAX_HASHED_ASSETS = 60;

function isHashedAsset(url) {
  return url.pathname.startsWith("/static/react/assets/") && !url.pathname.endsWith(".map");
}

async function pruneAssets(cache) {
  const keys = await cache.keys();
  const hashed = keys.filter((request) => isHashedAsset(new URL(request.url)));
  const excess = hashed.length - MAX_HASHED_ASSETS;
  for (let index = 0; index < excess; index += 1) {
    await cache.delete(hashed[index]);
  }
}

function isCacheableAsset(url) {
  return url.pathname.startsWith("/static/react/assets/")
    || url.pathname.startsWith("/static/react/pwa-")
    || url.pathname === "/static/react/apple-touch-icon.png"
    || url.pathname === "/favicon.ico";
}

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith("/api/")) return;

  if (request.mode === "navigate") {
    event.respondWith((async () => {
      try {
        const preloaded = await event.preloadResponse;
        if (preloaded) return preloaded;
        return await fetch(request);
      } catch (_error) {
        return (await caches.match("/")) || Response.error();
      }
    })());
    return;
  }

  if (isHashedAsset(url)) {
    // Content-hashed build files never change under a given name: serve
    // straight from cache and only touch the network on a miss. (This used
    // to re-download every asset in the background on every page load.)
    event.respondWith(
      caches.open(CACHE_VERSION).then(async (cache) => {
        const cached = await cache.match(request);
        if (cached) return cached;
        const response = await fetch(request);
        if (response.ok) {
          event.waitUntil(cache.put(request, response.clone()).then(() => pruneAssets(cache)));
        }
        return response;
      }),
    );
    return;
  }

  if (isCacheableAsset(url)) {
    event.respondWith(
      caches.open(CACHE_VERSION).then(async (cache) => {
        const cached = await cache.match(request);
        const networkFetch = fetch(request).then((response) => {
          if (response.ok) cache.put(request, response.clone());
          return response;
        }).catch(() => cached);
        return cached || networkFetch;
      }),
    );
  }
});

// Web Push: the payload is the plain JSON object lua/src/webpush.lua's
// encrypt_payload() encrypts -- {title, body, url} -- the browser has
// already decrypted it (per RFC 8291) by the time this fires, so this is
// just "show it" plus a click handler to land on the right page.
self.addEventListener("push", (event) => {
  let data = { title: "Nyxframe", body: "You have a new notification.", url: "/" };
  try {
    if (event.data) data = { ...data, ...event.data.json() };
  } catch {
    // Not valid JSON (shouldn't happen -- we always send JSON) -- fall
    // back to the generic text above rather than throwing out of the
    // event handler, which would silently drop the notification entirely.
  }
  event.waitUntil(
    self.registration.showNotification(data.title, {
      body: data.body,
      icon: "/static/react/pwa-192.png",
      badge: "/static/react/pwa-192.png",
      data: { url: data.url || "/" },
    }),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const targetUrl = event.notification.data?.url || "/";
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clientList) => {
      for (const client of clientList) {
        // Reuse an already-open tab (just navigate it) rather than always
        // opening a new one -- the common case for someone who already has
        // the site open in a background tab.
        if ("focus" in client) {
          client.postMessage({ type: "navigate", url: targetUrl });
          return client.focus();
        }
      }
      if (self.clients.openWindow) return self.clients.openWindow(targetUrl);
    }),
  );
});

// Push subscriptions aren't forever -- the browser can drop and recreate
// one on its own (key rotation, storage pressure). Re-subscribing with the
// SAME applicationServerKey and re-POSTing is enough; the backend's
// ON CONFLICT (endpoint) upsert (see routes.lua's M.push_subscribe) treats
// a changed endpoint as a new row rather than erroring.
self.addEventListener("pushsubscriptionchange", (event) => {
  event.waitUntil(
    (async () => {
      try {
        const newSubscription = await self.registration.pushManager.subscribe(event.oldSubscription?.options || {});
        await fetch("/api/push/subscribe", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(newSubscription.toJSON()),
          credentials: "include",
        });
      } catch {
        // Best-effort: if this fails, the next time the app is open and
        // its own subscribe-on-load check runs, it'll notice push is no
        // longer subscribed and re-subscribe through the normal UI path.
      }
    })(),
  );
});
