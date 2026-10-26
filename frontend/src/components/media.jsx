import { memo, useCallback, useMemo, useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { Bookmark, Copy, Download, ExternalLink, Film, FolderPlus, Heart, Image as ImageIcon, Link as LinkIcon, Lock, RefreshCw, Save, Trash2 } from "lucide-react";
import { apiFetch, clearApiCache } from "../api.js";
import { useMediaActions } from "../hooks/useMediaActions.js";
import { formatBytes, formatDate, numberish } from "../utils/format.js";
import { CARD_IMAGE_WIDTH, CARD_VIDEO_THUMB_WIDTH, isGifMedia, isPerfLiteRuntime, mediaImageSources, thumbUrl, videoPreviewUrl } from "../utils/media.js";
import { observeViewport } from "../utils/viewport.js";
import { Avatar, EmptyState, ResilientImage, SkeletonGrid, StatsRow } from "./ui.jsx";

function subcategoryNames(item) {
  if (Array.isArray(item?.subcategory_names) && item.subcategory_names.length) return item.subcategory_names;
  if (Array.isArray(item?.subcategories) && item.subcategories.length) return item.subcategories.map((row) => row?.name).filter(Boolean);
  return item?.subcategory_name ? [item.subcategory_name] : [];
}

export function MediaGrid({ ctx, items, loading = false, emptyTitle = "No media", onItemUpdated, onOpen, extraClass = "" }) {
  // Cards get one stable open handler plus their index, instead of a fresh
  // `() => onOpen(items, index)` closure per card per render -- that new
  // function identity defeated MediaCard's memo(), so every append, like
  // or background refresh re-rendered every card in the grid.
  const itemsRef = useRef(items);
  itemsRef.current = items;
  const onOpenRef = useRef(onOpen);
  onOpenRef.current = onOpen;
  const hasOpen = Boolean(onOpen);
  const openAt = useCallback((index) => onOpenRef.current?.(itemsRef.current, index), []);
  if (loading) return <SkeletonGrid count={8} />;
  if (!items?.length) return <EmptyState title={emptyTitle} />;
  const eagerCount = isPerfLiteRuntime() ? 2 : 4;
  const densityClass = `media-grid-${ctx.settings.grid_density || "comfortable"}`;
  const layoutClass = ctx.settings.grid_layout === "masonry" ? "media-grid-layout-masonry" : "";
  return (
    <div className={["media-grid", densityClass, layoutClass, extraClass].filter(Boolean).join(" ")}>
      {items.map((item, index) => (
        <MediaCard
          ctx={ctx}
          item={item}
          key={item.id}
          index={index}
          eager={index < eagerCount}
          onItemUpdated={onItemUpdated}
          onOpenAt={hasOpen ? openAt : undefined}
        />
      ))}
    </div>
  );
}

export const MediaCard = memo(function MediaCard({ ctx, item, index = 0, eager = false, onItemUpdated, onOpenAt, onOpen: onOpenProp }) {
  const onOpen = onOpenAt ? () => onOpenAt(index) : onOpenProp;
  const actions = useMediaActions(ctx, onItemUpdated);
  const thumb = useMemo(() => (item.media_kind === "video" ? thumbUrl(item, CARD_VIDEO_THUMB_WIDTH) : thumbUrl(item)), [item]);
  const mutedPreview = ctx.settings.muted_previews !== false;
  // NOT !isPerfLiteRuntime() -- perf-lite auto-activates on ANY coarse-
  // pointer device or a viewport <=820px wide (main.jsx's mobileQuery:
  // "(max-width: 820px), (pointer: coarse)"), which is effectively every
  // phone. That unconditionally disabled video previews on mobile
  // regardless of the autoplay_previews setting, while GIFs (plain <img>
  // tags, no preview machinery involved) kept animating as normal --
  // reported as "scrolling through Discover, only gifs are actually
  // playing," on both web and the iOS app, and confirmed live: this
  // account has autoplay_previews genuinely turned on. perf-lite bundling
  // "mobile" in with "reduce visual load" made sense before this feature
  // had any viewport-gating/debounce of its own; now that MediaCard
  // itself only mounts a preview once a card has actually settled in
  // view (see the effect below) and un-mounts on scroll-out, blanket-
  // disabling on mobile is redundant and actively works against a
  // setting the viewer explicitly turned on for exactly this device.
  // prefers-reduced-motion is still honored -- that's an accessibility
  // signal ("don't show me autoplaying motion"), not a performance one,
  // and stays real via the app's own reduce_motion setting rather than
  // perf-lite's system-level media-query mirror of the same intent.
  const previewEligible = item.media_kind === "video" && ctx.settings.autoplay_previews && item.url && !ctx.settings.reduce_motion;
  // Every MediaCard in a grid mounts at once (no virtualization), so an
  // unconditional autoplay <video> here meant every video on the page --
  // often dozens, on/off-screen alike -- started fetching a preview
  // simultaneously the instant the grid rendered. Each of those hits
  // ensure_video_quality_cache() on a cold cache, which falls back to
  // streaming the ENTIRE original file (not a trimmed-down preview) while
  // the real low-quality transcode runs in the background -- so a big
  // grid of freshly-uploaded (never-yet-transcoded) videos could fire off
  // that many full-file downloads at once, saturating the connection and
  // the backend's single-threaded request loop, and making unrelated
  // video loads (including the one the viewer actually opened) stall or
  // fail. Only mount the live preview once the card has actually scrolled
  // into view, same as "hover preview" already implied but never enforced.
  //
  // Two more things this same effect fixes, reported as "little stutters
  // and freezes when scrolling": (1) inView used to be a one-way latch --
  // once true, a preview stayed mounted and playing forever even after
  // scrolling far away, so a long scroll session accumulated more and more
  // simultaneously-decoding <video> elements instead of settling back
  // down. Now it un-mounts again on scroll-out, same idea as the iOS grid
  // preview's onDisappear cleanup. (2) inView flipped true the instant a
  // card crossed the 200px margin, with no debounce -- fast-scrolling past
  // a whole row of video cards fired off that many real network requests
  // (each potentially a full original file, per the fallback above) for
  // cards the viewer never actually stopped on. A short settle delay,
  // cancelled if the card leaves the viewport before it elapses, mirrors
  // the same-length debounce used for this exact reason in the iOS app's
  // MediaCard.
  const cardRef = useRef(null);
  const [inView, setInView] = useState(eager);
  useEffect(() => {
    if (!previewEligible) return undefined;
    const node = cardRef.current;
    if (!node) return undefined;
    let settleTimer = null;
    const unsubscribe = observeViewport(node, (entry) => {
      if (entry.isIntersecting) {
        // 150ms, not the original 350 -- long enough to skip a card that
        // flashes past mid-fling, but 350 turned out to routinely be
        // longer than a card stays continuously visible during a normal
        // scroll flick, so previews rarely got the chance to start at
        // all ("only gifs are actually playing" while scrolling, since
        // GIFs need no such gate). Tightened on both platforms together.
        if (!settleTimer) settleTimer = window.setTimeout(() => { settleTimer = null; setInView(true); }, 150);
      } else {
        if (settleTimer) { window.clearTimeout(settleTimer); settleTimer = null; }
        setInView(false);
      }
    }, { rootMargin: "200px" });
    return () => {
      if (settleTimer) window.clearTimeout(settleTimer);
      unsubscribe();
    };
  }, [previewEligible]);
  const liveVideoPreview = previewEligible && inView;
  const previewSrc = useMemo(() => (liveVideoPreview ? videoPreviewUrl(item, "low") : ""), [liveVideoPreview, item]);
  const categoryLine = useMemo(() => [item.category_name || "Unsorted", ...subcategoryNames(item)].filter(Boolean).join(" / "), [item]);
  const imageSources = useMemo(() => mediaImageSources(item, { width: CARD_IMAGE_WIDTH, previewSize: "detail" }), [item]);
  const videoThumbSources = useMemo(() => mediaImageSources(item, { width: CARD_VIDEO_THUMB_WIDTH, previewSize: "card" }), [item]);
  return (
    <article ref={cardRef} className={`media-card ${item.locked ? "is-locked" : ""}`}>
      <Link
        className="media-link"
        to={`/media/${item.id}`}
        aria-label={item.title || `Open media ${item.id}`}
        onClick={onOpen ? (e) => { if (!e.ctrlKey && !e.metaKey && !e.shiftKey && !e.altKey) { e.preventDefault(); onOpen(); } } : undefined}
      >
        <div className="thumb-frame" style={!item.locked && /^#[0-9a-f]{6}$/i.test(item.dominant_color || "") ? { backgroundColor: item.dominant_color } : undefined}>
          {item.locked ? <Lock size={34} /> : item.media_kind === "video" ? (
            liveVideoPreview ? (
              <video
                className={`video-thumb ${ctx.settings.blur_video_previews ? "blurred-video-thumb" : ""}`}
                key={previewSrc}
                src={previewSrc}
                poster={thumb}
                muted={mutedPreview}
                autoPlay={mutedPreview}
                controls={!mutedPreview}
                loop
                playsInline
                preload="metadata"
              />
            ) : thumb ? <ResilientImage className={`video-thumb ${ctx.settings.blur_video_previews ? "blurred-video-thumb" : ""}`} sources={videoThumbSources} diagnostics={{ mediaId: item.id, mediaKind: item.media_kind, context: "grid-video-thumb" }} alt="" loading={eager ? "eager" : "lazy"} decoding="async" fetchPriority={eager ? "high" : "auto"} fallback={<div className="video-thumb-placeholder"><Film size={34} /></div>} /> : <div className="video-thumb-placeholder"><Film size={34} /></div>
          ) : <ResilientImage className={isGifMedia(item) ? "gif-thumb" : ""} sources={imageSources} diagnostics={{ mediaId: item.id, mediaKind: item.media_kind, context: "grid-image" }} alt={item.title || ""} loading={eager ? "eager" : "lazy"} decoding="async" fetchPriority={eager ? "high" : "auto"} fallback={<div className="video-thumb-placeholder"><ImageIcon size={34} /></div>} />}
          <span className="kind-badge">{item.media_kind === "video" ? <Film size={14} /> : <ImageIcon size={14} />}{item.media_kind || "image"}</span>
        </div>
        <div className="media-copy">
          <h3>{item.title || "Untitled"}</h3>
          <p>{categoryLine}</p>
        </div>
      </Link>
      <div className="card-meta">
        <Link to={`/users/${item.username || ""}`} className="user-chip"><Avatar user={item} compact />{item.display_name || item.username || "User"}</Link>
        <span>{formatDate(item.created_at || item.uploaded_at)}</span>
      </div>
      <div className="card-actions">
        <button type="button" onClick={() => actions.toggleLike(item)} title={item.liked_by_me ? "Unlike" : "Like"}><Heart size={16} className={item.liked_by_me ? "filled" : ""} />{numberish(item.likes || item.like_count)}</button>
        <button type="button" onClick={() => actions.toggleBookmark(item)} title={item.bookmarked_by_me ? "Remove bookmark" : "Bookmark"}><Bookmark size={16} className={item.bookmarked_by_me ? "filled" : ""} /></button>
        <button type="button" onClick={() => actions.download(item)} title="Download"><Download size={16} /></button>
        <button type="button" onClick={() => actions.copyAddress(item)} title="Copy media URL"><Copy size={16} /></button>
        <CollectionSaveControl ctx={ctx} media={item} compact />
      </div>
    </article>
  );
});

export function CollectionSaveControl({ ctx, media, compact = false, openLabel = "Collect" }) {
  const [open, setOpen] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const [collections, setCollections] = useState([]);
  const [collectionId, setCollectionId] = useState("");

  async function loadCollections() {
    if (!ctx.user) return;
    setLoading(true);
    try {
      const data = await apiFetch("/api/collections?mine=true");
      // Smart collections are populated live from their saved filter, not manual adds.
      const rows = (data.collections || []).filter((collection) => !collection.is_smart);
      setCollections(rows);
      setCollectionId((current) => current || String(rows[0]?.id || ""));
      setLoaded(true);
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setLoading(false);
    }
  }

  async function togglePanel() {
    if (!ctx.user) {
      ctx.showToast("Login required to use collections.", "error");
      return;
    }
    const nextOpen = !open;
    setOpen(nextOpen);
    if (nextOpen && !loaded && !loading) await loadCollections();
  }

  async function saveToCollection() {
    if (!collectionId || !media?.id) return;
    setSaving(true);
    try {
      await apiFetch(`/api/collections/${collectionId}/items`, {
        method: "POST",
        body: JSON.stringify({ media_id: media.id, saved: true }),
      });
      clearApiCache();
      const target = collections.find((collection) => String(collection.id) === String(collectionId));
      ctx.showToast(`Added to ${target?.name || "collection"}.`, "success");
      setOpen(false);
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setSaving(false);
    }
  }

  return (
    <>
      <button className="collection-save-toggle" type="button" onClick={togglePanel} title="Add to collection">
        <FolderPlus size={16} />{compact ? <span className="sr-only">{openLabel}</span> : openLabel}
      </button>
      {open ? (
        <div className="collection-inline-panel">
          <strong>Add this post to a collection</strong>
          {loading ? <p>Loading collections…</p> : collections.length ? (
            <div className="inline-controls collection-save-controls">
              <select value={collectionId} onChange={(event) => setCollectionId(event.target.value)} aria-label="Choose collection">
                {collections.map((collection) => <option key={collection.id} value={collection.id}>{collection.name}</option>)}
              </select>
              <button type="button" onClick={saveToCollection} disabled={saving || !collectionId}>
                <Save size={16} />{saving ? "Adding" : "Add"}
              </button>
            </div>
          ) : (
            <div className="collection-empty-hint">
              <p>You do not have any collections yet.</p>
              <Link className="button-link" to="/collections">Create one</Link>
            </div>
          )}
        </div>
      ) : null}
    </>
  );
}

const SUBCATEGORY_SLOT_COUNT = 20;

// Same auto-grow rule as the upload form: one empty row after the last one
// used, so twenty slots are available without rendering twenty empty rows.
function visibleSlotCount(ids, names) {
  let last = -1;
  const mark = (arr) => (Array.isArray(arr) ? arr : []).forEach((v, i) => {
    if (String(v || "").trim()) last = i;
  });
  mark(ids); mark(names);
  return Math.min(SUBCATEGORY_SLOT_COUNT, Math.max(1, last + 2));
}

function slots(values) {
  const out = Array.isArray(values) ? values.slice(0, SUBCATEGORY_SLOT_COUNT).map((v) => String(v ?? "")) : [];
  while (out.length < SUBCATEGORY_SLOT_COUNT) out.push("");
  return out;
}

function draftFromMedia(media) {
  return {
    title: media.title || "",
    description: media.description || "",
    tags: Array.isArray(media.tags) ? media.tags.join(", ") : "",
    category_id: String(media.category_id || ""),
    subcategory_ids: slots(media.subcategory_ids),
    subcategory_names: slots([]),
    is_adult: Boolean(media.is_adult),
    source_url: media.source_url || "",
  };
}

// Full post editor.
//
// Until now the only thing a user could change about a post after uploading
// it was the four switches in MediaControls below -- visibility, comments,
// downloads, pinned. Title, description, tags and category were frozen at
// upload time: PATCH /api/media/:id has supported editing all of them the
// whole time, but nothing in the web app (or the iOS app) ever called it, so
// a typo in a title was permanent short of deleting and re-uploading.
//
// The endpoint replaces the whole post record rather than patching named
// fields -- omit visibility and it resets to public, omit is_adult and the
// post is silently un-marked as 18+ -- so every control value is echoed back
// unchanged alongside the fields actually being edited. publish_at is the one
// exception: it is explicitly-only on the server, so leaving it out here
// preserves whatever schedule MediaControls set.
export function MediaEditor({ ctx, media, onChanged }) {
  const [draft, setDraft] = useState(() => draftFromMedia(media));
  const [busy, setBusy] = useState(false);
  const prefillRef = useRef(null); // uncontrolled -- "Prefill from post" input, read on click only

  useEffect(() => { setDraft(draftFromMedia(media)); }, [media]);

  const categories = ctx.lookups?.categories || [];
  const selectedCategory = categories.find((row) => String(row.id) === String(draft.category_id));
  const subcategories = selectedCategory?.subcategories || selectedCategory?.children || [];

  function set(key, value) { setDraft((current) => ({ ...current, [key]: value })); }

  // Same "Prefill from post" capability as UploadPage.jsx's upload form --
  // see its header comment. Duplicated rather than shared as a hook since
  // the two forms use different state shapes (draft/set here vs form/update
  // there) for a handful of lines of logic.
  async function prefillTagsFromPost() {
    const idMatch = prefillRef.current?.value.match(/(\d+)\s*$/);
    const mediaId = idMatch && idMatch[1];
    if (!mediaId) return ctx.showToast("Enter a post id or paste a post URL.", "error");
    try {
      const data = await apiFetch(`/api/media/${mediaId}`);
      const tags = Array.isArray(data.tags) ? data.tags : [];
      if (!tags.length) return ctx.showToast(`"${data.title || `Post #${mediaId}`}" has no tags to copy.`, "info");
      set("tags", tags.join(", "));
      ctx.showToast(`Copied ${tags.length} tag${tags.length === 1 ? "" : "s"} from "${data.title || `Post #${mediaId}`}".`, "success");
    } catch (error) {
      ctx.showToast(error.message || "Could not load that post.", "error");
    }
  }

  function setSlot(kind, index, value) {
    setDraft((current) => {
      const next = slots(current[kind]);
      next[index] = value;
      return { ...current, [kind]: next };
    });
  }

  async function save() {
    if (!draft.title.trim()) { ctx.showToast("Title is required.", "error"); return; }
    if (!draft.category_id) { ctx.showToast("A category is required.", "error"); return; }
    setBusy(true);
    try {
      const data = await apiFetch(`/api/media/${media.id}`, {
        method: "PATCH",
        body: JSON.stringify({
          title: draft.title,
          description: draft.description,
          tags: draft.tags.split(",").map((tag) => tag.trim()).filter(Boolean),
          category_id: Number(draft.category_id),
          subcategory_ids: slots(draft.subcategory_ids).filter(Boolean).map(Number),
          subcategory_names: slots(draft.subcategory_names).map((v) => v.trim()).filter(Boolean),
          is_adult: draft.is_adult,
          // Explicit null rather than "" so the server's sparse contract
          // reads it as "clear it" instead of "leave it alone" -- otherwise
          // emptying the box in the UI would silently do nothing.
          source_url: draft.source_url.trim() || null,
          // Echoed, not edited -- see this component's header comment.
          visibility: media.visibility || "public",
          comments_enabled: media.comments_enabled !== false,
          downloads_enabled: media.downloads_enabled !== false,
          pinned: Boolean(media.pinned_at || media.pinned),
        }),
      });
      clearApiCache();
      onChanged(data.media);
      ctx.showToast("Post updated.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="side-box">
      <h3>Edit Post</h3>
      <label className="field"><span>Title</span><input value={draft.title} onChange={(event) => set("title", event.target.value)} maxLength={160} /></label>
      <label className="field"><span>Description</span><textarea value={draft.description} onChange={(event) => set("description", event.target.value)} rows={4} maxLength={2000} /></label>
      <label className="field"><span>Tags</span><input value={draft.tags} onChange={(event) => set("tags", event.target.value)} placeholder="comma separated" /></label>
      <div className="field upload-prefill-tags">
        <span className="field-head">Reuse tags from another post</span>
        <div className="upload-prefill-tags-row">
          <input ref={prefillRef} type="text" placeholder="Post id or URL" aria-label="Post id or URL to copy tags from" />
          <button type="button" onClick={prefillTagsFromPost}><Copy size={15} />Prefill from post</button>
        </div>
      </div>
      <label className="field"><span>Original source</span><input value={draft.source_url} onChange={(event) => set("source_url", event.target.value)} type="url" inputMode="url" maxLength={500} placeholder="https://… where this came from" /></label>
      <label className="field"><span>Category</span>
        <select value={draft.category_id} onChange={(event) => setDraft((current) => ({ ...current, category_id: event.target.value, subcategory_ids: slots([]) }))}>
          <option value="">Select a category</option>
          {categories.map((category) => <option key={category.id} value={category.id}>{category.name}</option>)}
        </select>
      </label>
      {slots(draft.subcategory_ids)
        .slice(0, visibleSlotCount(draft.subcategory_ids, draft.subcategory_names))
        .map((value, index) => (
        <div className="field" key={`subcat-${index}`}>
          <span>{index === 0 ? "Subcategories" : ""}</span>
          <select value={value} onChange={(event) => setSlot("subcategory_ids", index, event.target.value)} disabled={!subcategories.length}>
            <option value="">None</option>
            {subcategories.map((row) => <option key={row.id} value={row.id}>{row.name}</option>)}
          </select>
          <input value={slots(draft.subcategory_names)[index]} onChange={(event) => setSlot("subcategory_names", index, event.target.value)} placeholder="or type a new one" />
        </div>
      ))}
      <label className="check-row"><input checked={draft.is_adult} onChange={(event) => set("is_adult", event.target.checked)} type="checkbox" />Mark as 18+</label>
      <div className="inline-controls">
        <button type="button" onClick={save} disabled={busy}><Save size={16} />{busy ? "Saving..." : "Save Post"}</button>
        <button type="button" onClick={() => setDraft(draftFromMedia(media))} disabled={busy}><RefreshCw size={16} />Reset</button>
      </div>
    </section>
  );
}

// The server stores publish_at as naive UTC (same convention as created_at);
// <input type="datetime-local"> speaks naive LOCAL. Converting through Date
// in both directions keeps a schedule from drifting by the viewer's UTC
// offset when it is saved and read back.
function publishInputValue(value) {
  if (!value) return "";
  const parsed = new Date(String(value).replace(" ", "T") + (/[Z+]/.test(String(value)) ? "" : "Z"));
  if (Number.isNaN(parsed.getTime())) return "";
  const local = new Date(parsed.getTime() - parsed.getTimezoneOffset() * 60000);
  return local.toISOString().slice(0, 16);
}

function publishPayloadValue(inputValue) {
  if (!inputValue) return null;
  const parsed = new Date(inputValue);
  if (Number.isNaN(parsed.getTime())) return null;
  return parsed.toISOString().slice(0, 19);
}

// onDeleted: optional -- a list view (Studio) passes it to drop the row;
// without it, onChanged(null) tells a single-post view the post is gone.
export function MediaControls({ ctx, media, onChanged, onDeleted }) {
  const [draft, setDraft] = useState({
    visibility: media.visibility || "public",
    comments_enabled: media.comments_enabled !== false,
    downloads_enabled: media.downloads_enabled !== false,
    pinned: Boolean(media.pinned_at || media.pinned),
    publish_at: publishInputValue(media.publish_at),
  });

  useEffect(() => {
    setDraft({
      visibility: media.visibility || "public",
      comments_enabled: media.comments_enabled !== false,
      downloads_enabled: media.downloads_enabled !== false,
      pinned: Boolean(media.pinned_at || media.pinned),
      publish_at: publishInputValue(media.publish_at),
    });
  }, [media]);

  async function save() {
    try {
      const data = await apiFetch(`/api/media/${media.id}/controls`, {
        method: "PATCH",
        body: JSON.stringify({ ...draft, publish_at: publishPayloadValue(draft.publish_at) }),
      });
      clearApiCache();
      onChanged(data.media);
      ctx.showToast("Controls saved.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  async function remove() {
    if (!window.confirm("Delete this post? This cannot be undone from here.")) return;
    try {
      await apiFetch(`/api/media/${media.id}`, { method: "DELETE" });
      clearApiCache();
      ctx.showToast("Post deleted.", "success");
      if (onDeleted) onDeleted(media.id);
      else onChanged(null);
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  async function restore() {
    try {
      const data = await apiFetch(`/api/media/${media.id}/restore`, { method: "POST" });
      clearApiCache();
      onChanged(data.media);
      ctx.showToast("Post restored.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  return (
    <section className="side-box">
      <h3>Controls</h3>
      <label className="field"><span>Visibility</span><select value={draft.visibility} onChange={(event) => setDraft((current) => ({ ...current, visibility: event.target.value }))}><option value="public">Public</option><option value="unlisted">Unlisted</option><option value="private">Private</option></select></label>
      <label className="check-row"><input checked={draft.comments_enabled} onChange={(event) => setDraft((current) => ({ ...current, comments_enabled: event.target.checked }))} type="checkbox" />Comments</label>
      <label className="check-row"><input checked={draft.downloads_enabled} onChange={(event) => setDraft((current) => ({ ...current, downloads_enabled: event.target.checked }))} type="checkbox" />Downloads</label>
      <label className="check-row"><input checked={draft.pinned} onChange={(event) => setDraft((current) => ({ ...current, pinned: event.target.checked }))} type="checkbox" />Pinned</label>
      <label className="field"><span>Publish at</span><input type="datetime-local" value={draft.publish_at} onChange={(event) => setDraft((current) => ({ ...current, publish_at: event.target.value }))} /></label>
      {draft.publish_at && new Date(draft.publish_at) > new Date()
        ? <p className="field-hint">Hidden from everyone but you until then.</p>
        : <p className="field-hint">Leave empty to publish immediately.</p>}
      <div className="inline-controls">
        <button type="button" onClick={save}><Save size={16} />Save</button>
        {media.deleted_at ? <button type="button" onClick={restore}><RefreshCw size={16} />Restore</button> : <button type="button" className="danger" onClick={remove}><Trash2 size={16} />Delete</button>}
      </div>
    </section>
  );
}

const EDIT_HISTORY_FIELD_LABELS = {
  title: "Title",
  description: "Description",
  tags: "Tags",
  category_id: "Category",
  visibility: "Visibility",
  is_adult: "18+ flag",
};

function editHistoryValueText(ctx, field, value) {
  if (value === null || value === undefined || value === "") return "(empty)";
  if (field === "category_id") {
    const match = ctx.lookups.categories.find((c) => String(c.id) === String(value));
    return match ? match.name : `#${value}`;
  }
  if (field === "tags") {
    try {
      const tags = JSON.parse(value);
      return Array.isArray(tags) && tags.length ? tags.join(", ") : "(none)";
    } catch {
      return String(value);
    }
  }
  if (field === "is_adult") return value ? "Yes" : "No";
  return String(value);
}

// Owner-only: fetched eagerly like MediaEditor/MediaControls above, since
// this sits behind its own collapsed <details> disclosure already -- no
// extra lazy-load gate needed on top of that.
export function MediaEditHistory({ ctx, media }) {
  const [entries, setEntries] = useState(null);
  const [error, setError] = useState("");

  useEffect(() => {
    let cancelled = false;
    setEntries(null);
    setError("");
    apiFetch(`/api/media/${media.id}/history`).then((data) => {
      if (!cancelled) setEntries(data.history || []);
    }).catch((err) => {
      if (!cancelled) setError(err.message);
    });
    return () => { cancelled = true; };
  }, [media.id]);

  if (error) return <section className="side-box"><p className="field-hint">{error}</p></section>;
  if (!entries) return <section className="side-box"><p className="field-hint">Loading…</p></section>;
  if (!entries.length) return <section className="side-box"><p className="field-hint">No edits yet.</p></section>;

  return (
    <section className="side-box edit-history-list">
      {entries.map((entry) => (
        <article key={entry.id} className="edit-history-entry">
          <header>
            <strong>{entry.display_name || entry.username}</strong>
            <time>{formatDate(entry.created_at)}</time>
          </header>
          <ul>
            {Object.entries(entry.changes).map(([field, change]) => (
              <li key={field}>
                <span className="edit-history-field">{EDIT_HISTORY_FIELD_LABELS[field] || field}:</span>{" "}
                {editHistoryValueText(ctx, field, change.from)} → {editHistoryValueText(ctx, field, change.to)}
              </li>
            ))}
          </ul>
        </article>
      ))}
    </section>
  );
}

export function MediaActionPanel({ ctx, media, actions }) {
  return (
    <section className="side-box media-action-panel">
      <h3>Post Actions</h3>
      <button type="button" onClick={() => actions.copyAddress(media)}><Copy size={16} />Copy Media URL</button>
      <button type="button" onClick={() => actions.copyPageLink(media)}><LinkIcon size={16} />Copy Page Link</button>
      <button type="button" onClick={() => actions.openOriginal(media)}><ExternalLink size={16} />Open Original</button>
      <button type="button" onClick={() => actions.download(media)}><Download size={16} />Save File</button>
      <CollectionSaveControl ctx={ctx} media={media} openLabel="Add to Collection" />
    </section>
  );
}

export function StudioItem({ ctx, item, onChanged, onRemoved, selected = false, onToggleSelect }) {
  return (
    <article className={`studio-item ${selected ? "is-selected" : ""}`}>
      {onToggleSelect ? (
        <label className="studio-select">
          <input type="checkbox" checked={selected} onChange={onToggleSelect} aria-label={`Select ${item.title || "post"}`} />
        </label>
      ) : null}
      <Link to={`/media/${item.id}`} className="studio-thumb">
        {item.media_kind === "video"
          ? <ResilientImage className={ctx.settings.blur_video_previews ? "blurred-video-thumb" : ""} sources={mediaImageSources(item, { width: 420, previewSize: "card" })} diagnostics={{ mediaId: item.id, mediaKind: item.media_kind, context: "studio-video-thumb" }} alt="" loading="lazy" decoding="async" fallback={<div className="video-thumb-placeholder"><Film size={34} /></div>} />
          : <ResilientImage sources={mediaImageSources(item, { width: 640, previewSize: "detail" })} diagnostics={{ mediaId: item.id, mediaKind: item.media_kind, context: "studio-image" }} alt="" loading="lazy" decoding="async" fallback={<div className="video-thumb-placeholder"><ImageIcon size={34} /></div>} />}
      </Link>
      <div className="studio-info">
        <h3>{item.title || "Untitled"}</h3>
        <p>{item.visibility || "public"} / {formatBytes(item.file_size)} / {formatDate(item.created_at || item.uploaded_at)}</p>
        {item.publish_at && new Date(item.publish_at) > new Date() ? (
          <span className="report-status-pill">Scheduled for {formatDate(item.publish_at)}</span>
        ) : null}
        <StatsRow item={item} compact />
      </div>
      {/* One Delete, inside Controls. There used to be a second one here:
          the two disagreed -- this one dropped the row, the Controls one
          deleted server-side but left the post on screen. */}
      <div className="studio-actions">
        <MediaControls ctx={ctx} media={item} onChanged={onChanged} onDeleted={onRemoved} />
      </div>
    </article>
  );
}
