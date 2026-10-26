import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { Link, NavLink, useLocation } from "react-router-dom";
import { Activity, AlertTriangle, Code2, Folder, Gift, Grid3X3, Heart, Home, Image as ImageIcon, LogIn, LogOut, MessageCircle, Moon, MoreHorizontal, Rocket, Search as SearchIcon, Settings, ShieldAlert, Sparkles, Sun, SunMoon, TrendingUp, Upload, UserPlus, Users, Wand2, X as XIcon } from "lucide-react";
import { apiFetch, cachedApiFetch, clearApiCache } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { getPendingUploadJobs, removePendingUploadJob } from "../uploadJobs.js";
import { Avatar, BackToTop, GlassFilterDefs, glassPointerMove } from "./ui.jsx";
import { NotificationBell } from "./NotificationBell.jsx";
import { reconcileValue } from "../utils/reconcile.js";

// The primary nav has grown to eleven entries for a signed-in owner.
// That is fine on a wide screen and impossible on a phone: the fixed
// bottom bar laid them out in a single row of 66px-minimum cells, which
// measured 436px of content in a 412px viewport -- "Discover" was
// clipped off the left edge and the last label was truncated, on the
// default phone size, signed out. Rather than shrink everything until it
// stops overflowing (and becomes unreadable and untappable), the bar now
// carries a fixed handful of primary destinations plus a "More" sheet
// holding the rest. `primary` is that split, and it only matters below
// the breakpoint -- the desktop nav still renders every item inline.
const NAV_ITEMS = [
  { to: "/", icon: Home, label: "Discover", primary: true },
  { to: "/trending", icon: TrendingUp, label: "Trending", primary: true },
  { to: "/collections", icon: Folder, label: "Collections" },
  { to: "/users", icon: Users, label: "Users" },
  { to: "/following", icon: Sparkles, label: "Following" },
  { to: "/for-you", icon: Wand2, label: "For You", auth: true },
  { to: "/liked", icon: Heart, label: "Liked" },
  { to: "/year-recap", icon: Gift, label: "Year in Review", auth: true },
  { to: "/friends", icon: UserPlus, label: "Friends", auth: true },
  { to: "/messages", icon: MessageCircle, label: "Messages", auth: true },
  { to: "/studio", icon: Grid3X3, label: "Studio", auth: true },
  { to: "/upload", icon: Upload, label: "Upload", auth: true, accent: true, primary: true },
  { to: "/admin", icon: ShieldAlert, label: "Admin", owner: true },
  { to: "/other-projects", icon: Rocket, label: "My Other Projects" },
];

const THEME_ICONS = { dark: Moon, light: Sun, "": SunMoon };
const THEME_LABELS = { dark: "Switch to light theme", light: "Switch to system theme", "": "Switch to dark theme" };

export function Shell({ ctx, children, className = "", style }) {
  const liveOk = ctx.lookups.live?.ok ?? ctx.lookups.live?.check_map?.db ?? ctx.lookups.live?.check_map?.api;
  const healthText = liveOk ? "Live" : "Checking";
  const username = ctx.user?.username || "guest";
  const [site, setSite] = useState(null);
  const [bannerDismissed, setBannerDismissed] = useState(false);
  const [moreOpen, setMoreOpen] = useState(false);
  // Browser URL at the moment the sheet was opened -- see the close-on-
  // navigation effect below.
  const moreOpenedAtRef = useRef("");
  const location = useLocation();

  const navItems = NAV_ITEMS.filter((item) => {
    if (item.owner) return Boolean(ctx.user?.site_owner);
    if (item.auth) return Boolean(ctx.user);
    return true;
  });
  // Everything that isn't pinned to the phone bar goes in the sheet --
  // including, deliberately, whichever page you're currently on, so the
  // "More" button can show an active state instead of the viewer losing
  // all sense of where they are.
  const overflowItems = navItems.filter((item) => !item.primary);
  const overflowActive = overflowItems.some((item) => item.to !== "/" && location.pathname.startsWith(item.to));

  // Any navigation closes the sheet -- without this it stays open on top
  // of the page it just sent you to (e.g. the browser back button while it's
  // open). But only a navigation that happened *after* it opened: React
  // Router updates the address bar first and commits the new route in a
  // transition a beat later, so a "More" tap landing in that gap (a slow
  // phone rendering the next page) used to open the sheet and then have
  // this effect snap it shut the moment the route committed.
  useEffect(() => {
    if (window.location.href !== moreOpenedAtRef.current) setMoreOpen(false);
  }, [location.pathname]);

  function toggleMore() {
    setMoreOpen((value) => {
      if (!value) moreOpenedAtRef.current = window.location.href;
      return !value;
    });
  }

  // ─── Does the nav actually fit? ──────────────────────────────────────
  // .primary-nav has `overflow-x: auto`, so when it doesn't fit it simply
  // clips -- the last destination vanishes behind the account controls
  // with no scrollbar and no hint anything is there. (Seen at 1360px:
  // "My Other Projects" cut mid-word.) A fixed breakpoint can't decide
  // this, because the item count isn't fixed: a signed-out visitor has
  // seven destinations and a signed-in owner has twelve, so any width
  // that's comfortable for one is wrong for the other.
  //
  // So measure. With labels shown, is the content wider than the track?
  // If so, drop to icons only (names stay available via title= and to a
  // screen reader). No feedback loop: the nav's width comes from the
  // topbar's `1fr` grid track, so shrinking its contents never changes
  // its own box, which is what the observer watches.
  const navRef = useRef(null);
  const [navCompact, setNavCompact] = useState(false);
  const measureNav = useCallback(() => {
    const nav = navRef.current;
    if (!nav) return;
    // Measure uncompacted, always: otherwise the nav could never
    // discover that it has room to show its labels again.
    nav.classList.remove("nav-compact");
    const overflows = nav.scrollWidth > nav.clientWidth + 1;
    setNavCompact(overflows);
    if (overflows) nav.classList.add("nav-compact");
  }, []);

  // Layout effect, not a plain one: measuring after paint would show one
  // frame of clipped nav on every load.
  useLayoutEffect(() => {
    measureNav();
    const nav = navRef.current;
    if (!nav || typeof ResizeObserver === "undefined") {
      window.addEventListener("resize", measureNav);
      return () => window.removeEventListener("resize", measureNav);
    }
    const observer = new ResizeObserver(measureNav);
    observer.observe(nav);
    return () => observer.disconnect();
  }, [measureNav, navItems.length]);

  useLiveRefresh(async () => {
    try {
      const next = await cachedApiFetch("/api/site/announcement", { ttl: 30_000 });
      setSite((current) => reconcileValue(current, next));
    } catch (_error) {
      // Non-critical — keep the last known state rather than erroring the shell.
    }
  }, { interval: 60_000, immediate: true });

  // Backgrounded uploads (UploadPage's chunked path hands off to
  // upload_chunk_finish's background job once its fast dry-run passes, then
  // navigates away immediately) get polled here instead of on the upload
  // page itself, since the whole point is the uploader no longer has to
  // stay there. Lives in Shell rather than UploadPage so a job queued
  // before navigating away still gets its completion toast wherever the
  // user ends up. Short interval, but the callback itself no-ops in one
  // localStorage read when nothing's pending, so this is cheap at idle.
  useLiveRefresh(async () => {
    const jobs = getPendingUploadJobs();
    if (!jobs.length) return;
    // Polled in parallel, not one-at-a-time: with N pending jobs, an
    // await-in-a-for-loop turned every 6s tick into N sequential round
    // trips (N x latency instead of ~1x) -- harmless for the common
    // single-upload case, but needlessly slow whenever more than one
    // upload is in flight at once.
    await Promise.all(jobs.map(async (job) => {
      try {
        const data = await apiFetch(`/api/media/upload/job/${encodeURIComponent(job.jobId)}`);
        // "error" + retrying=true means the backend hit a transient failure
        // but is auto-retrying the same job (up to 3 attempts, see
        // upload_chunk_finish in routes.lua) -- not a final outcome yet, so
        // this keeps polling exactly like "processing" instead of flashing
        // a premature failure toast that a moment later gets contradicted
        // by a success one.
        if (data.status === "processing" || (data.status === "error" && data.retrying)) return;
        removePendingUploadJob(job.jobId);
        if (data.status === "done") {
          ctx.showToast(`"${job.filename}" is ready.`, "success");
          // Lists cached before the post existed (profile, home) would
          // otherwise keep showing the gallery without it.
          clearApiCache();
          ctx.refreshLookups();
        } else {
          ctx.showToast(`Upload of "${job.filename}" failed: ${data.detail || "unknown error"}`, "error");
        }
      } catch (_error) {
        // Job lookup itself failed (expired past the 24h job TTL, or a
        // network blip) -- drop it rather than retrying forever. The
        // actual upload already ran (or is running) server-side regardless
        // of whether anyone's still watching for the result; losing just
        // the toast isn't losing the upload.
        removePendingUploadJob(job.jobId);
      }
    }));
  }, { interval: 6_000, immediate: true, enabled: Boolean(ctx.user) });

  useEffect(() => {
    setBannerDismissed(false);
  }, [site?.announcement_message]);

  const isOwner = Boolean(ctx.user?.site_owner);
  if (site?.maintenance_mode && !isOwner) {
    return (
      <div className={`app-shell ${className}`.trim()} style={style}>
        <main className="main-stage maintenance-gate">
          <div className="locked-state">
            <AlertTriangle size={42} />
            <h2>Under maintenance</h2>
            <p>{site.maintenance_message || "Nyxframe is temporarily unavailable. Please check back soon."}</p>
          </div>
        </main>
      </div>
    );
  }

  return (
    <div className={`app-shell ${className}`.trim()} style={style}>
      {/* Keyboard users hit up to twelve nav destinations plus the
          account controls before reaching the content, on every single
          page. Standard escape hatch: visually hidden until focused,
          which is the first Tab stop on the page. */}
      <a className="skip-link" href="#main-content">Skip to content</a>
      <GlassFilterDefs />
      {site?.announcement_active && site.announcement_message && !bannerDismissed ? (
        <div className={`site-announcement-banner level-${site.announcement_level || "info"}`}>
          <span>{site.announcement_message}</span>
          <button type="button" className="icon-button" onClick={() => setBannerDismissed(true)} title="Dismiss">
            <XIcon size={16} />
          </button>
        </div>
      ) : null}
      <header className="topbar liquid-glass" onPointerMove={glassPointerMove}>
        <Link className="brand" to="/">
          <span className="brand-mark"><ImageIcon size={18} /></span>
          <span className="brand-copy">
            <strong>Nyxframe</strong>
            <small>Curated Media Deck</small>
          </span>
        </Link>
        <nav className={`primary-nav${navCompact ? " nav-compact" : ""}`} aria-label="Main" ref={navRef}>
          {navItems.map((item) => (
            <NavItem
              key={item.to}
              to={item.to}
              icon={item.icon}
              label={item.label}
              accent={item.accent}
              // Hidden by CSS below the breakpoint rather than unmounted:
              // the desktop nav wants every item, and swapping the list
              // on a resize would remount the whole bar.
              className={item.primary ? "" : "nav-item-overflow"}
            />
          ))}
          <button
            type="button"
            className={`nav-item nav-item-more${overflowActive ? " active" : ""}`}
            onClick={toggleMore}
            aria-expanded={moreOpen}
            aria-label="More navigation"
          >
            <MoreHorizontal size={18} />
            <span>More</span>
          </button>
        </nav>
        <div className="account-actions">
          {/* Search had no entry point anywhere in the chrome before
              this. A real field on a wide screen, and the same palette
              behind an icon where a field won't fit -- both open the one
              command palette rather than two divergent search UIs. */}
          <button type="button" className="topbar-search" onClick={ctx.openCommandPalette} title="Search (Ctrl+K)">
            <SearchIcon size={16} />
            <span className="topbar-search-label">Search</span>
            <kbd>{typeof navigator !== "undefined" && navigator.platform?.includes("Mac") ? "⌘K" : "Ctrl K"}</kbd>
          </button>
          <span className={`health-pill ${liveOk ? "is-live" : ""}`}>{healthText}</span>
          <ThemeToggle quickTheme={ctx.quickTheme} onCycle={ctx.cycleTheme} />
          <NotificationBell ctx={ctx} />
          {ctx.user ? (
            <>
              <Link className="account-badge" to={`/users/${ctx.user.username}`} title="Profile">
                <span className="account-badge-kicker">@{username}</span>
                <strong>{ctx.user.display_name || ctx.user.username}</strong>
              </Link>
              <Link className="avatar-link" to={`/users/${ctx.user.username}`} title="Profile">
                <Avatar user={ctx.user} />
              </Link>
              <IconButton to="/settings" icon={Settings} label="Settings" />
              <button className="icon-button" type="button" onClick={() => ctx.logout()} title="Logout">
                <LogOut size={18} />
                <span className="sr-only">Logout</span>
              </button>
            </>
          ) : (
            <Link className="auth-link" to="/login">
              <LogIn size={18} />
              <span>Login</span>
            </Link>
          )}
        </div>
      </header>
      {moreOpen ? (
        <>
          <div className="nav-more-scrim" role="presentation" onClick={() => setMoreOpen(false)} />
          <div className="nav-more-sheet" role="menu" aria-label="More navigation">
            {overflowItems.map((item) => (
              <NavLink key={item.to} className="nav-more-item" to={item.to} role="menuitem" onClick={() => setMoreOpen(false)}>
                <item.icon size={18} />
                <span>{item.label}</span>
              </NavLink>
            ))}
          </div>
        </>
      ) : null}
      <main className="main-stage" id="main-content" tabIndex={-1}>{children}</main>
      <BackToTop />
      <footer className="site-footer">
        <span>Nyxframe // HollowHeavenXR</span>
        <Link to="/status"><Activity size={14} />Status</Link>
        <Link to="/api-docs"><Code2 size={14} />API</Link>
        <a href="https://discord.com/users/1304564041863266347" target="_blank" rel="noreferrer">Discord</a>
      </footer>
    </div>
  );
}

function NavItem({ to, icon: Icon, label, accent = false, className = "" }) {
  return (
    <NavLink
      className={({ isActive }) => `nav-item ${isActive ? "active" : ""} ${accent ? "accent liquid-glass" : ""} ${className}`}
      to={to}
      end={to === "/"}
      onPointerMove={accent ? glassPointerMove : undefined}
      // Carries the name when the label is visually hidden at
      // icon-only widths (see the 1181-1400px rule in styles.css).
      title={label}
    >
      <Icon size={18} />
      <span className="nav-item-label">{label}</span>
    </NavLink>
  );
}

function IconButton({ to, icon: Icon, label }) {
  return (
    <Link className="icon-button" to={to} title={label}>
      <Icon size={18} />
      <span className="sr-only">{label}</span>
    </Link>
  );
}

function ThemeToggle({ quickTheme, onCycle }) {
  const Icon = THEME_ICONS[quickTheme] ?? SunMoon;
  const label = THEME_LABELS[quickTheme] ?? "Toggle theme";
  return (
    <button className="icon-button theme-toggle" type="button" onClick={onCycle} title={label} aria-label={label}>
      <Icon size={16} />
    </button>
  );
}
