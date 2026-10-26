import React from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import App, { preloadRouteFor } from "./App.jsx";
import "./styles.css";
import { startRemoteOriginPolling } from "./api.js";

function runtimeBasename() {
  const configured = String(window.IMAGE_GALLERY_BASENAME || "").replace(/\/+$/, "");
  if (configured) return configured;
  const path = window.location.pathname.replace(/\/+$/, "");
  if (window.location.hostname.endsWith("github.io")) {
    const first = path.split("/").filter(Boolean)[0];
    if (first) return `/${first}`;
  }
  if (path.startsWith("/static/react")) return "/static/react";
  return "";
}

function applyRuntimeClasses() {
  const root = document.documentElement;
  const userAgent = navigator.userAgent || "";
  const isOpera = /\bOPR\//.test(userAgent) || /\bOpera\//.test(userAgent);
  const mobileQuery = window.matchMedia("(max-width: 820px), (pointer: coarse)");
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  root.classList.toggle("is-opera", isOpera);
  root.classList.toggle("is-mobile-runtime", mobileQuery.matches);
  root.classList.toggle("perf-lite", isOpera || mobileQuery.matches || reducedMotion.matches);
  const refresh = () => {
    root.classList.toggle("is-mobile-runtime", mobileQuery.matches);
    root.classList.toggle("perf-lite", isOpera || mobileQuery.matches || reducedMotion.matches);
  };
  mobileQuery.addEventListener?.("change", refresh);
  reducedMotion.addEventListener?.("change", refresh);
}

applyRuntimeClasses();
startRemoteOriginPolling();

// The service worker + manifest are served from site root by the Lua backend
// (see lua/src/static.lua; the Vite dev server doesn't, so this 404s harmlessly
// there). The static GitHub Pages mirror doesn't have that backend, so
// registering there would just 404 against an unrelated root — skip it.
if ("serviceWorker" in navigator && !window.location.hostname.endsWith("github.io")) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/service-worker.js").catch(() => {});
  });
  // Clicking a push notification (service-worker.js's notificationclick)
  // posts {type:"navigate", url} to an already-open tab instead of
  // navigating it directly -- a service worker has no access to this
  // page's react-router instance, so it hands off here. A hard navigation
  // (not useNavigate) is deliberate: this listener sits outside the
  // Router entirely, and a full load is a reasonable, simple trade-off for
  // what's already a rare, intentional jump rather than in-app browsing.
  navigator.serviceWorker.addEventListener("message", (event) => {
    if (event.data?.type === "navigate" && typeof event.data.url === "string") {
      window.location.href = event.data.url;
    }
  });
}

document.addEventListener("contextmenu", (event) => {
  event.preventDefault();
}, { capture: true });

const basename = runtimeBasename();
const routePath = window.location.pathname.slice(basename.length) || "/";
const renderApp = () => createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <BrowserRouter basename={basename}>
      <App />
    </BrowserRouter>
  </React.StrictMode>,
);
// Wait (briefly) for the current route's chunk; see preloadRouteFor.
Promise.race([
  preloadRouteFor(routePath),
  new Promise((resolve) => window.setTimeout(resolve, 2500)),
]).then(renderApp, renderApp);
