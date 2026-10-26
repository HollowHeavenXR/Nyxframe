import { useCallback, useEffect, useRef, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { Bell, Columns2, Grid2X2, RefreshCw, Save, Search, SlidersHorizontal, Sparkles, X as XIcon } from "lucide-react";
import { apiFetch, cachedApiFetch, clearApiCache, prefetchApi, toQuery } from "../api.js";
import { PAGE_SIZE } from "../config.js";
import { CategoryPills, DiscoverContinueWatching, DiscoverMemories, DiscoverTrending } from "../components/discover.jsx";
import { MediaGrid } from "../components/media.jsx";
import { EmptyState, Notice, Page, Segmented, TagCloud } from "../components/ui.jsx";
import { retryDelayMs, useAutoRetry } from "../hooks/useAutoRetry.js";
import { appendUniqueMedia, preloadMediaAssets, replaceMedia } from "../utils/media.js";

function timeOfDayGreeting(user) {
  if (!user) return "Welcome to Nyxframe";
  const name = user.display_name || user.username;
  const hour = new Date().getHours();
  if (hour < 5) return `Still up, ${name}?`;
  if (hour < 12) return `Good morning, ${name}`;
  if (hour < 17) return `Good afternoon, ${name}`;
  if (hour < 22) return `Good evening, ${name}`;
  return `Still up, ${name}?`;
}

const VIEW_MODE_KEY = "ig_discover_view";
// Shell.jsx's "Discover" nav item always links to a bare "/" -- clicking it
// (or the browser back/forward across a route change, which unmounts this
// whole component) loses whatever's in the URL's query string, so a filter
// applied here, then abandoned by switching to another tab and back, read
// as silently reset even though nothing about the filter itself was ever
// cleared. Mirrors VIEW_MODE_KEY's approach just above -- sessionStorage
// (not localStorage: a filter feels like "this browsing session," not a
// standing preference that should still be there after a fresh visit
// days later) as the fallback source when the URL itself arrives empty,
// kept in sync every time the URL is.
const FILTERS_SESSION_KEY = "nyxframe_discover_filters";

function readStoredFilters() {
  try {
    const raw = sessionStorage.getItem(FILTERS_SESSION_KEY);
    return raw ? JSON.parse(raw) : null;
  } catch (_error) {
    return null;
  }
}

const SORT_OPTIONS = [
  ["new", "Newest"],
  ["trending", "Trending"],
  ["popular", "Most liked"],
  ["downloads", "Most downloaded"],
  ["views", "Most viewed"],
  ["old", "Oldest"],
];

// Heading over the results grid -- says what the grid is actually showing,
// since the controls that shape it now live in a compact bar, not a sidebar.
const SORT_HEADINGS = {
  new: "Latest uploads",
  trending: "Trending now",
  popular: "Most liked",
  downloads: "Most downloaded",
  views: "Most viewed",
  old: "From the archive",
};

// The "More filters" panel's fields -- the ones with no always-visible
// control in the browse bar. Drives the Filters button's badge and whether
// the panel starts open (a shared link with an uploader filter shouldn't
// hide the field that explains the results).
function advancedFilterCount(f) {
  return ["uploader", "min_size", "max_size", "date_from", "date_to"].filter((key) => f[key]).length
    + (f.adult && f.adult !== "show" ? 1 : 0);
}

function isTypingTarget(target) {
  if (!target) return false;
  const tag = target.tagName;
  return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || target.isContentEditable;
}

function pageSizeFor(settings) {
  const parsed = Number(settings?.items_per_page);
  if (!Number.isFinite(parsed)) return PAGE_SIZE;
  return Math.min(60, Math.max(12, Math.round(parsed)));
}

function getFilterChips(filters, categories) {
  const chips = [];
  if (filters.q) chips.push({ key: "q", label: `"${filters.q}"`, clear: { q: "" } });
  if (filters.media_kind) {
    chips.push({ key: "media_kind", label: filters.media_kind === "image" ? "Images & GIFs" : "Videos", clear: { media_kind: "" } });
  }
  if (filters.category_id) {
    const cat = categories.find((c) => String(c.id) === String(filters.category_id));
    chips.push({ key: "category_id", label: cat?.name || `Category ${filters.category_id}`, clear: { category_id: "", subcategory_id: "" } });
  }
  if (filters.subcategory_id) chips.push({ key: "subcategory_id", label: `Sub ${filters.subcategory_id}`, clear: { subcategory_id: "" } });
  if (filters.uploader) chips.push({ key: "uploader", label: `By ${filters.uploader}`, clear: { uploader: "" } });
  if (filters.min_size) chips.push({ key: "min_size", label: `≥${filters.min_size} MB`, clear: { min_size: "" } });
  if (filters.max_size) chips.push({ key: "max_size", label: `≤${filters.max_size} MB`, clear: { max_size: "" } });
  if (filters.date_from) chips.push({ key: "date_from", label: `From ${filters.date_from}`, clear: { date_from: "" } });
  if (filters.date_to) chips.push({ key: "date_to", label: `To ${filters.date_to}`, clear: { date_to: "" } });
  if (filters.adult !== "show") {
    chips.push({ key: "adult", label: filters.adult === "hide" ? "No 18+" : "Only 18+", clear: { adult: "show" } });
  }
  if (filters.sort && filters.sort !== "new") {
    const sortLabels = { trending: "Trending", popular: "Most liked", downloads: "Most downloaded", views: "Most viewed", old: "Oldest" };
    chips.push({ key: "sort", label: sortLabels[filters.sort] || filters.sort, clear: { sort: "new" } });
  }
  return chips;
}

export function DiscoverPage({ ctx }) {
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const [filters, setFilters] = useState(() => {
    // A real (bookmarked/shared) URL with its own query string always wins;
    // sessionStorage is only consulted when the URL arrives with nothing
    // filter-related in it at all, which is exactly what a bare nav-link
    // navigation back to "/" looks like -- see FILTERS_SESSION_KEY's doc
    // comment above.
    const hasUrlFilters = [...searchParams.keys()].length > 0;
    const stored = !hasUrlFilters ? readStoredFilters() : null;
    return {
      q: searchParams.get("q") || stored?.q || "",
      media_kind: searchParams.get("media_kind") || stored?.media_kind || "",
      category_id: searchParams.get("category_id") || stored?.category_id || "",
      subcategory_id: searchParams.get("subcategory_id") || stored?.subcategory_id || "",
      uploader: searchParams.get("uploader") || stored?.uploader || "",
      min_size: searchParams.get("min_size") || stored?.min_size || "",
      max_size: searchParams.get("max_size") || stored?.max_size || "",
      date_from: searchParams.get("date_from") || stored?.date_from || "",
      date_to: searchParams.get("date_to") || stored?.date_to || "",
      adult: searchParams.get("adult") || stored?.adult || "show",
      sort: searchParams.get("sort") || stored?.sort || ctx.settings.default_sort || "new",
    };
  });
  const [items, setItems] = useState([]);
  const [hasNext, setHasNext] = useState(false);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState("");
  const [randomPending, setRandomPending] = useState(false);
  const [viewMode, setViewMode] = useState(() => localStorage.getItem(VIEW_MODE_KEY) || "grid");
  const [savingSmart, setSavingSmart] = useState(false);
  const [savingAlert, setSavingAlert] = useState(false);
  const [filtersOpen, setFiltersOpen] = useState(() => advancedFilterCount(filters) > 0);
  const searchRef = useRef(null);

  const pageRef = useRef(1);
  const filtersRef = useRef(filters);
  filtersRef.current = filters;
  const sentinelRef = useRef(null);
  // Bumped on every fresh (page 1) load. A response that comes back after
  // the filters changed again belongs to a query nobody is looking at any
  // more -- without this guard, a slow earlier search could land last and
  // overwrite the results of the newer one, or append its page onto them.
  const generationRef = useRef(0);
  // Set when loading the next page fails; stops the scroll sentinel from
  // re-firing the same failing request in a tight loop. useAutoRetry below
  // retries it on a backoff instead (moreFailures = consecutive failures).
  const [moreError, setMoreError] = useState("");
  const [moreFailures, setMoreFailures] = useState(0);

  const pageSize = pageSizeFor(ctx.settings);

  const handleItemUpdated = useCallback((item) => setItems((rows) => replaceMedia(rows, item)), []);

  const selectedCategory = ctx.lookups.categories.find(
    (c) => String(c.id) === String(filters.category_id),
  );
  const subcategories = selectedCategory?.subcategories || selectedCategory?.children || [];

  const loadMedia = useCallback(async ({ page = 1, append = false } = {}) => {
    const f = filtersRef.current;
    const queryParams = {
      q: f.q,
      media_kind: f.media_kind,
      category_id: f.category_id,
      subcategory_id: f.subcategory_id,
      uploader: f.uploader,
      min_size: f.min_size ? Number(f.min_size) * 1024 * 1024 : "",
      max_size: f.max_size ? Number(f.max_size) * 1024 * 1024 : "",
      date_from: f.date_from,
      date_to: f.date_to,
      adult: f.adult,
      sort: f.sort,
      limit: pageSize + 1,
      offset: (page - 1) * pageSize,
    };
    const path = `/api/media${toQuery(queryParams)}`;
    const generation = append ? generationRef.current : ++generationRef.current;
    const isCurrent = () => generation === generationRef.current;
    try {
      // Appends read the cache too (no stale fallback), so the page that was
      // prefetched in the background shows instantly when the viewer scrolls.
      const data = append
        ? await cachedApiFetch(path, { ttl: 60_000, staleTtl: 0, allowStale: false, storage: "session" })
        : await cachedApiFetch(path, { ttl: 20_000, staleTtl: 5 * 60_000, storage: "session" });
      if (!isCurrent()) return;
      const rows = data.media || [];
      const pageItems = rows.slice(0, pageSize);
      if (append) {
        setMoreError("");
        setMoreFailures(0);
        setItems((prev) => appendUniqueMedia(prev, pageItems));
      } else {
        setItems(pageItems);
      }
      setHasNext(rows.length > pageSize);
      preloadMediaAssets(rows, { limit: 6 });
      if (rows.length > pageSize) {
        const nextPath = `/api/media${toQuery({ ...queryParams, offset: page * pageSize })}`;
        const idle = window.requestIdleCallback || ((fn) => window.setTimeout(fn, 800));
        idle(() => prefetchApi(nextPath, { ttl: 60_000, staleTtl: 0, storage: "session" }));
      }
    } catch (err) {
      if (!isCurrent()) return;
      if (!append) { setError(err.message); setItems([]); setHasNext(false); }
      else {
        // Roll the page counter back so a retry asks for the same page.
        pageRef.current = Math.max(1, page - 1);
        setMoreError(err.message || "Could not load more posts.");
        setMoreFailures((count) => count + 1);
      }
    } finally {
      if (!append) { if (isCurrent()) setLoading(false); }
      else setLoadingMore(false);
    }
  }, [pageSize]);

  // Filter change → reset and reload. Debounced so typing in the search box
  // or the uploader/size/date text fields doesn't fire an API call per keystroke.
  // The first load and dropdown/chip changes (sort, kind, category, 18+)
  // run immediately -- the 300ms wait used to delay every home page load.
  const prevFiltersRef = useRef(null);
  useEffect(() => {
    setLoading(true);
    const prev = prevFiltersRef.current;
    prevFiltersRef.current = filters;
    const typed = ["q", "uploader", "min_size", "max_size", "date_from", "date_to"];
    const delay = prev && typed.some((key) => prev[key] !== filters[key]) ? 300 : 0;
    const timer = window.setTimeout(() => {
      pageRef.current = 1;
      setHasNext(false);
      setMoreError("");
      setMoreFailures(0);
      setError("");
      setItems([]);
      loadMedia({ page: 1, append: false });

      const next = { ...filters };
      Object.keys(next).forEach((key) => {
        if (next[key] === "" || (key === "adult" && next[key] === "show") || (key === "sort" && next[key] === "new")) {
          delete next[key];
        }
      });
      setSearchParams(next, { replace: true });
      try {
        if (Object.keys(next).length > 0) {
          sessionStorage.setItem(FILTERS_SESSION_KEY, JSON.stringify(next));
        } else {
          sessionStorage.removeItem(FILTERS_SESSION_KEY);
        }
      } catch (_error) {
        // Private-browsing/storage-disabled -- filters just won't survive a
        // tab switch in that case, same as before this fix.
      }
    }, delay);
    return () => window.clearTimeout(timer);
  }, [filters]); // intentionally omit loadMedia/setSearchParams — stable refs

  // "/" jumps to the search box from anywhere on the page (Ctrl+K still opens
  // the site-wide command palette).
  useEffect(() => {
    function onKeyDown(event) {
      if (event.key !== "/" || event.ctrlKey || event.metaKey || event.altKey) return;
      if (isTypingTarget(event.target)) return;
      event.preventDefault();
      searchRef.current?.focus();
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  const loadNextPage = useCallback(() => {
    const nextPage = pageRef.current + 1;
    pageRef.current = nextPage;
    setLoadingMore(true);
    loadMedia({ page: nextPage, append: true });
  }, [loadMedia]);

  useAutoRetry({
    failures: moreFailures,
    enabled: hasNext && !loading && !loadingMore,
    onRetry: loadNextPage,
  });

  // Infinite scroll sentinel
  useEffect(() => {
    const sentinel = sentinelRef.current;
    if (!sentinel) return;
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting && hasNext && !loadingMore && !loading && !moreError) {
          loadNextPage();
        }
      },
      { rootMargin: "300px" },
    );
    observer.observe(sentinel);
    return () => observer.disconnect();
  }, [hasNext, loadingMore, loading, loadNextPage, moreError]);

  function updateFilter(key, value) {
    setFilters((current) => ({
      ...current,
      [key]: value,
      ...(key === "category_id" ? { subcategory_id: "" } : {}),
    }));
  }

  function applyFilterClear(patch) {
    setFilters((current) => ({ ...current, ...patch }));
  }

  function clearAllFilters() {
    setFilters({
      q: "", media_kind: "", category_id: "", subcategory_id: "", uploader: "",
      min_size: "", max_size: "", date_from: "", date_to: "",
      adult: "show", sort: ctx.settings.default_sort || "new",
    });
  }

  async function openRandom() {
    if (randomPending) return;
    setRandomPending(true);
    try {
      const data = await apiFetch("/api/media/random");
      navigate(`/media/${data.media.id}`);
    } catch (randomError) {
      ctx.showToast(randomError.message, "error");
    } finally {
      setRandomPending(false);
    }
  }

  function refreshFeed() {
    pageRef.current = 1;
    setMoreError("");
    setMoreFailures(0);
    setItems([]);
    setHasNext(false);
    setLoadingMore(false);
    setLoading(true);
    setError("");
    clearApiCache("/api/media");
    loadMedia({ page: 1, append: false });
  }

  function changeViewMode(mode) {
    setViewMode(mode);
    localStorage.setItem(VIEW_MODE_KEY, mode);
  }

  function filterPayloadFromFilters(f) {
    return {
      q: f.q || undefined,
      media_kind: f.media_kind || undefined,
      category_id: f.category_id || undefined,
      subcategory_id: f.subcategory_id || undefined,
      uploader: f.uploader || undefined,
      min_size: f.min_size ? Number(f.min_size) * 1024 * 1024 : undefined,
      max_size: f.max_size ? Number(f.max_size) * 1024 * 1024 : undefined,
      date_from: f.date_from || undefined,
      date_to: f.date_to || undefined,
      adult: f.adult && f.adult !== "show" ? f.adult : undefined,
      sort: f.sort && f.sort !== "new" ? f.sort : undefined,
    };
  }

  async function saveSmartCollection() {
    if (!ctx.user) {
      ctx.showToast("Login required to save collections.", "error");
      return;
    }
    if (!filterChips.length) {
      ctx.showToast("Set at least one filter before saving it as a smart collection.", "error");
      return;
    }
    const name = window.prompt("Name this smart collection", filters.q || "My smart collection");
    if (!name || !name.trim()) return;
    setSavingSmart(true);
    try {
      await apiFetch("/api/collections", {
        method: "POST",
        body: JSON.stringify({ name: name.trim(), is_public: true, is_smart: true, filter_json: filterPayloadFromFilters(filters) }),
      });
      clearApiCache("/api/collections");
      ctx.showToast(`Saved "${name.trim()}" as a smart collection.`, "success");
    } catch (saveError) {
      ctx.showToast(saveError.message, "error");
    } finally {
      setSavingSmart(false);
    }
  }

  async function saveSearchAlert() {
    if (!ctx.user) {
      ctx.showToast("Login required to save alerts.", "error");
      return;
    }
    if (!filterChips.length) {
      ctx.showToast("Set at least one filter before saving it as an alert.", "error");
      return;
    }
    const name = window.prompt("Name this saved search / alert", filters.q || "My saved search");
    if (!name || !name.trim()) return;
    setSavingAlert(true);
    try {
      await apiFetch("/api/saved-searches", {
        method: "POST",
        body: JSON.stringify({ name: name.trim(), filter_json: filterPayloadFromFilters(filters) }),
      });
      ctx.showToast(`Saved "${name.trim()}" — you'll be notified when new matches are uploaded.`, "success");
    } catch (saveError) {
      ctx.showToast(saveError.message, "error");
    } finally {
      setSavingAlert(false);
    }
  }

  const openLightbox = ctx.openLightbox;
  const filterChips = getFilterChips(filters, ctx.lookups.categories);
  const gridExtraClass = viewMode === "masonry" ? "media-grid-masonry" : "";
  const advancedCount = advancedFilterCount(filters);
  const popularTags = (ctx.lookups.tags || []).slice(0, 6).map((tag) => tag.name || tag.tag || String(tag));
  const resultsHeading = filters.q
    ? `Results for “${filters.q}”`
    : `${SORT_HEADINGS[filters.sort] || "Latest uploads"}${selectedCategory ? ` in ${selectedCategory.name}` : ""}`;

  const hero = (
    <header className="discover-hero">
      <div className="discover-hero-top">
        <div className="discover-hero-copy">
          <p className="discover-hero-kicker">Discover</p>
          <h1>{timeOfDayGreeting(ctx.user)}</h1>
          <span className="discover-hero-lede">Here&rsquo;s what the archive&rsquo;s been up to.</span>
        </div>
        <div className="discover-hero-actions">
          <button type="button" onClick={openRandom} disabled={randomPending}>
            <Sparkles size={16} />{randomPending ? "Loading" : "Surprise me"}
          </button>
          <button type="button" className="icon-button" onClick={refreshFeed} disabled={loading} title="Refresh" aria-label="Refresh">
            <RefreshCw size={16} />
          </button>
        </div>
      </div>
      <label className="discover-search">
        <Search size={20} />
        <input
          ref={searchRef}
          value={filters.q}
          onChange={(e) => updateFilter("q", e.target.value)}
          type="search"
          placeholder="Search wallpapers, memes, tags…"
          aria-label="Search the gallery"
        />
        {filters.q ? (
          <button type="button" className="discover-search-clear" onClick={() => updateFilter("q", "")} aria-label="Clear search">
            <XIcon size={16} />
          </button>
        ) : (
          <kbd className="discover-search-hint" aria-hidden="true">/</kbd>
        )}
      </label>
      {popularTags.length ? (
        <div className="discover-hero-tags">
          <span>Popular</span>
          {popularTags.map((name) => (
            <button type="button" key={name} className={filters.q === name ? "active" : ""} onClick={() => updateFilter("q", filters.q === name ? "" : name)}>
              #{name}
            </button>
          ))}
        </div>
      ) : null}
    </header>
  );

  return (
    <Page title="Discover" header={hero} className="page-discover">
      {!filterChips.length ? <DiscoverContinueWatching ctx={ctx} /> : null}
      {!filterChips.length ? <DiscoverTrending /> : null}
      {!filterChips.length ? <DiscoverMemories ctx={ctx} /> : null}

      <section className="discover-browse" aria-label="Browse the gallery">
        <div className="discover-browse-bar">
          <CategoryPills
            categories={ctx.lookups.categories}
            selectedId={filters.category_id}
            onSelect={(categoryId) => updateFilter("category_id", categoryId)}
          />
          <div className="discover-browse-controls">
            <Segmented
              value={filters.media_kind}
              onChange={(value) => updateFilter("media_kind", value)}
              options={[["", "All"], ["image", "Images"], ["video", "Videos"]]}
            />
            <label className="discover-sort">
              <span className="sr-only">Sort</span>
              <select value={filters.sort} onChange={(e) => updateFilter("sort", e.target.value)}>
                {SORT_OPTIONS.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
              </select>
            </label>
            <button
              type="button"
              className={`discover-filters-toggle ${filtersOpen ? "active" : ""}`}
              onClick={() => setFiltersOpen((open) => !open)}
              aria-expanded={filtersOpen}
              aria-controls="discover-filter-panel"
            >
              <SlidersHorizontal size={16} />
              <span>Filters</span>
              {advancedCount ? <span className="discover-filters-count">{advancedCount}</span> : null}
            </button>
            <div className="view-toggle">
              <button
                type="button"
                className={`icon-button ${viewMode === "grid" ? "active" : ""}`}
                onClick={() => changeViewMode("grid")}
                title="Grid view"
                aria-label="Grid view"
              >
                <Grid2X2 size={16} />
              </button>
              <button
                type="button"
                className={`icon-button ${viewMode === "masonry" ? "active" : ""}`}
                onClick={() => changeViewMode("masonry")}
                title="Masonry view"
                aria-label="Masonry view"
              >
                <Columns2 size={16} />
              </button>
            </div>
          </div>
        </div>

        {subcategories.length ? (
          <div className="category-pills subcategory-pills" aria-label={`${selectedCategory?.name || "Category"} subcategories`}>
            <button type="button" className={`category-pill ${!filters.subcategory_id ? "active" : ""}`} onClick={() => updateFilter("subcategory_id", "")}>
              All {selectedCategory?.name}
            </button>
            {subcategories.map((sub) => (
              <button
                type="button"
                key={sub.id}
                className={`category-pill ${String(filters.subcategory_id) === String(sub.id) ? "active" : ""}`}
                onClick={() => updateFilter("subcategory_id", sub.id)}
              >
                {sub.name}
              </button>
            ))}
          </div>
        ) : null}

        {filtersOpen ? (
          <section className="discover-filter-panel" id="discover-filter-panel" aria-label="More filters">
            <div className="discover-filter-grid">
              <label className="field"><span>Uploader</span><input value={filters.uploader} onChange={(e) => updateFilter("uploader", e.target.value)} placeholder="username" /></label>
              <label className="field"><span>Min MB</span><input value={filters.min_size} onChange={(e) => updateFilter("min_size", e.target.value)} type="number" min="0" /></label>
              <label className="field"><span>Max MB</span><input value={filters.max_size} onChange={(e) => updateFilter("max_size", e.target.value)} type="number" min="0" /></label>
              <label className="field"><span>From</span><input value={filters.date_from} onChange={(e) => updateFilter("date_from", e.target.value)} type="date" /></label>
              <label className="field"><span>To</span><input value={filters.date_to} onChange={(e) => updateFilter("date_to", e.target.value)} type="date" /></label>
              <label className="field">
                <span>18+ posts</span>
                <select value={filters.adult} onChange={(e) => updateFilter("adult", e.target.value)}>
                  <option value="show">Show when allowed</option>
                  <option value="hide">Hide 18+</option>
                  <option value="only">Only 18+</option>
                </select>
              </label>
            </div>
            <TagCloud tags={ctx.lookups.tags} onPick={(tag) => updateFilter("q", tag.name || tag.tag || tag)} />
          </section>
        ) : null}

        <section className="content-panel discover-results">
          <div className="discover-results-head">
            <h2>{resultsHeading}</h2>
            {filterChips.length > 0 ? (
              <div className="active-filters">
                {filterChips.map((chip) => (
                  <button
                    key={chip.key}
                    type="button"
                    className="filter-chip"
                    onClick={() => applyFilterClear(chip.clear)}
                    title={`Remove: ${chip.label}`}
                  >
                    {chip.label}
                    <XIcon size={12} />
                  </button>
                ))}
                <button type="button" className="filter-chip filter-chip-clear" onClick={clearAllFilters}>
                  Clear all
                </button>
                {ctx.user ? (
                  <button type="button" className="filter-chip filter-chip-save" onClick={saveSmartCollection} disabled={savingSmart}>
                    <Save size={12} />{savingSmart ? "Saving…" : "Save as smart collection"}
                  </button>
                ) : null}
                {ctx.user ? (
                  <button type="button" className="filter-chip filter-chip-save" onClick={saveSearchAlert} disabled={savingAlert}>
                    <Bell size={12} />{savingAlert ? "Saving…" : "Save as alert"}
                  </button>
                ) : null}
              </div>
            ) : null}
          </div>

          {error ? (
            <Notice kind="error" onRetry={() => { clearApiCache("/api/media"); setError(""); setLoading(true); loadMedia({ page: 1, append: false }); }}>
              {error}
            </Notice>
          ) : null}
          {/* An empty grid caused by the filter rail used to be a dead
              end -- "No posts match this view" and nothing to act on, on
              the one page where the cause is almost always a filter the
              viewer set several interactions ago and can no longer see
              the whole of. */}
          {!loading && !items.length && filterChips.length > 0 ? (
            <EmptyState
              title="No posts match these filters"
              hint="Try widening the search, or clear the filters to see everything again."
              action={<button type="button" className="button-link" onClick={clearAllFilters}>Clear all filters</button>}
            />
          ) : (
            <MediaGrid
              ctx={ctx}
              items={items}
              loading={loading}
              emptyTitle="No posts here yet"
              onItemUpdated={handleItemUpdated}
              onOpen={openLightbox}
              extraClass={gridExtraClass}
            />
          )}

          {/* Infinite scroll sentinel */}
          <div ref={sentinelRef} className="scroll-sentinel" aria-hidden="true" />
          {loadingMore ? (
            <div className="load-more-spinner" aria-label="Loading more posts">
              <span className="spinner-ring" />
              <span>Loading more</span>
            </div>
          ) : null}
          {/* A real control alongside the sentinel, not instead of it.
              Infinite scroll on its own is unreachable by keyboard and
              silently does nothing if IntersectionObserver never fires
              (a short viewport where the sentinel starts on screen, a
              restored scroll position that lands past it); this always
              works, and pressing it is also how a screen-reader user
              gets to page two at all. */}
          {moreError && !loadingMore ? (
            <Notice kind="error">
              {moreError} Retrying automatically in {Math.round(retryDelayMs(moreFailures) / 1000)}s.
            </Notice>
          ) : null}
          {hasNext && !loadingMore && !loading ? (
            <div className="load-more-row">
              <button
                type="button"
                onClick={loadNextPage}
              >
                {moreError ? "Retry now" : "Load more"}
              </button>
            </div>
          ) : null}
          {!hasNext && !loading && items.length > 0 ? (
            <div className="scroll-end">All caught up</div>
          ) : null}
        </section>
      </section>
    </Page>
  );
}
