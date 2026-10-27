import { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { Check, Film, Search, Tags, X } from "lucide-react";
import { apiFetch } from "../api.js";

const PAGE_SIZE = 36;

// Shown in the upload form and the post editor next to the tags field:
// opens a picker of the signed-in user's own posts (only ones that have
// tags), searchable by title or tag, or by pasting a post link/id. Clicking
// a post hands its tags to `onApply(tags, post, mode)`.
export function ReuseTagsField({ onApply, currentTags = [] }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="field reuse-tags-field">
      <span className="field-head">Reuse tags from one of your posts</span>
      <button type="button" className="reuse-tags-open" onClick={() => setOpen(true)}>
        <Tags size={15} />Choose a post…
      </button>
      {open ? (
        <PostPicker
          currentTags={currentTags}
          onClose={() => setOpen(false)}
          onPick={(post, mode) => {
            setOpen(false);
            onApply(post.tags || [], post, mode);
          }}
        />
      ) : null}
    </div>
  );
}

// Merges `incoming` into `current` (case-insensitive, order kept), or
// replaces it. Returns { tags, added }.
export function mergeTags(current, incoming, mode = "add") {
  const clean = (list) => (list || []).map((tag) => String(tag || "").trim()).filter(Boolean);
  if (mode === "replace") {
    const tags = clean(incoming);
    return { tags, added: tags.length };
  }
  const tags = clean(current);
  const seen = new Set(tags.map((tag) => tag.toLowerCase()));
  let added = 0;
  for (const tag of clean(incoming)) {
    if (seen.has(tag.toLowerCase())) continue;
    seen.add(tag.toLowerCase());
    tags.push(tag);
    added += 1;
  }
  return { tags, added };
}

export function PostPicker({ onPick, onClose, currentTags = [] }) {
  const [query, setQuery] = useState("");
  const [items, setItems] = useState([]);
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [mode, setMode] = useState("add");
  const inputRef = useRef(null);
  const sentinelRef = useRef(null);
  const requestRef = useRef(0);

  const load = useCallback(async (q, offset) => {
    const requestId = ++requestRef.current;
    setLoading(true);
    setError("");
    try {
      const params = new URLSearchParams({ limit: String(PAGE_SIZE), offset: String(offset) });
      if (q.trim()) params.set("q", q.trim());
      const data = await apiFetch(`/api/me/media/picker?${params}`);
      if (requestId !== requestRef.current) return; // a newer search replaced this one
      setItems((current) => (offset ? [...current, ...(data.items || [])] : data.items || []));
      setHasMore(Boolean(data.has_more));
    } catch (loadError) {
      if (requestId === requestRef.current) setError(loadError.message || "Could not load your posts.");
    } finally {
      if (requestId === requestRef.current) setLoading(false);
    }
  }, []);

  // Search as you type, settled for 250ms so each keystroke isn't a request.
  useEffect(() => {
    const timer = setTimeout(() => load(query, 0), query ? 250 : 0);
    return () => clearTimeout(timer);
  }, [query, load]);

  // Next page when the end of the grid scrolls into view.
  useEffect(() => {
    const node = sentinelRef.current;
    if (!node || !hasMore || loading) return undefined;
    const observer = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) load(query, items.length);
    }, { rootMargin: "300px" });
    observer.observe(node);
    return () => observer.disconnect();
  }, [hasMore, loading, items.length, query, load]);

  useEffect(() => {
    inputRef.current?.focus();
    const onKey = (event) => { if (event.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      window.removeEventListener("keydown", onKey);
      document.body.style.overflow = previousOverflow;
    };
  }, [onClose]);

  const current = new Set((currentTags || []).map((tag) => String(tag).toLowerCase()));

  // Portaled to <body>: the upload/edit panels use backdrop-filter, which
  // would otherwise turn this fixed overlay into one positioned inside them.
  return createPortal(
    <div className="post-picker-backdrop" role="presentation" onClick={onClose}>
      <div
        className="post-picker"
        role="dialog"
        aria-modal="true"
        aria-label="Choose a post to copy tags from"
        onClick={(event) => event.stopPropagation()}
      >
        <header className="post-picker-head">
          <div>
            <h2>Copy tags from a post</h2>
            <p>Pick one of your posts — its tags are added to this one.</p>
          </div>
          <button type="button" className="icon-button" onClick={onClose} aria-label="Close"><X size={18} /></button>
        </header>
        <div className="post-picker-search">
          <Search size={16} />
          <input
            ref={inputRef}
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Search by title or tag, or paste a post link"
            aria-label="Search your posts"
          />
          {query ? <button type="button" className="icon-button" onClick={() => setQuery("")} aria-label="Clear search"><X size={14} /></button> : null}
        </div>
        <div className="post-picker-mode" role="radiogroup" aria-label="How to apply tags">
          <label><input type="radio" name="post-picker-mode" checked={mode === "add"} onChange={() => setMode("add")} />Add to my tags</label>
          <label><input type="radio" name="post-picker-mode" checked={mode === "replace"} onChange={() => setMode("replace")} />Replace my tags</label>
        </div>

        <div className="post-picker-body">
          {error ? <p className="post-picker-empty">{error}</p> : null}
          {!error && !loading && !items.length ? (
            <p className="post-picker-empty">
              {query ? "No posts with tags match that search." : "None of your posts have tags yet."}
            </p>
          ) : null}
          <ul className="post-picker-grid">
            {items.map((post) => {
              const tags = post.tags || [];
              const newCount = tags.filter((tag) => !current.has(String(tag).toLowerCase())).length;
              return (
                <li key={post.id}>
                  <button type="button" className="post-picker-card" onClick={() => onPick(post, mode)}>
                    <span className="post-picker-thumb">
                      {post.thumb_url ? (
                        <img src={post.thumb_url.replace(/([?&])w=\d+/, "$1w=320")} alt="" loading="lazy" decoding="async" />
                      ) : null}
                      {post.media_kind === "video" ? <span className="post-picker-kind"><Film size={12} /></span> : null}
                    </span>
                    <span className="post-picker-title" title={post.title}>{post.title || `Post #${post.id}`}</span>
                    <span className="post-picker-tags">
                      {tags.slice(0, 4).map((tag) => <span key={tag} className="post-picker-tag">#{tag}</span>)}
                      {tags.length > 4 ? <span className="post-picker-tag is-more">+{tags.length - 4}</span> : null}
                    </span>
                    <span className="post-picker-meta">
                      {mode === "add" && !newCount ? <><Check size={12} />All tags already added</> : `${tags.length} tag${tags.length === 1 ? "" : "s"}${mode === "add" && newCount < tags.length ? ` · ${newCount} new` : ""}`}
                    </span>
                  </button>
                </li>
              );
            })}
          </ul>
          {loading ? <div className="post-picker-loading" aria-live="polite">Loading your posts…</div> : null}
          <div ref={sentinelRef} aria-hidden="true" />
        </div>
      </div>
    </div>,
    document.body,
  );
}
