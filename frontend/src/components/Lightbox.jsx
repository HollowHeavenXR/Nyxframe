import { useCallback, useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { Bookmark, ChevronLeft, ChevronRight, Copy, Download, ExternalLink, Heart, Pause, Play, X } from "lucide-react";
import { apiFetch } from "../api.js";
import { useMediaActions } from "../hooks/useMediaActions.js";
import { Avatar, ChipRow, glassPointerMove, ProgressiveImage, ResilientImage, StatsRow } from "./ui.jsx";
import { VideoPlayer } from "./VideoPlayer.jsx";
import { isGifMedia, mediaImageSources, thumbUrl, videoQualityUrl } from "../utils/media.js";

// `lightbox` is a prop rather than part of ctx: ctx is handed to every
// card on the page, so carrying the lightbox state in it re-rendered the
// whole grid behind the overlay on every open, close and swipe.
export function Lightbox({ ctx, lightbox: lightboxProp }) {
  const lightbox = lightboxProp ?? ctx.lightbox;
  const { closeLightbox } = ctx;
  const items = lightbox?.items || [];

  const [currentIndex, setCurrentIndex] = useState(lightbox?.index ?? 0);
  const [item, setItem] = useState(() => items[lightbox?.index ?? 0] || null);
  const [videoQuality, setVideoQuality] = useState("original");
  // "Play all" slideshow: auto-advances every `slideshowSeconds` while
  // playing. Stops (doesn't loop) at the end of the list -- a surprise
  // infinite loop is worse than just stopping and leaving the last item on
  // screen, same reasoning a real slideshow/presentation tool would use.
  // Left deliberately independent of BackgroundMusicPlayer (no shared
  // play-trigger exists between them, and forcing one wasn't worth adding
  // a fragile cross-component coupling for) -- if music happens to already
  // be playing, it simply continues in the background unaffected.
  const [slideshowPlaying, setSlideshowPlaying] = useState(false);
  const [slideshowSeconds, setSlideshowSeconds] = useState(5);
  const cacheRef = useRef(new Map());
  const currentIndexRef = useRef(currentIndex);
  currentIndexRef.current = currentIndex;
  const itemRef = useRef(item);
  itemRef.current = item;

  // Reset when lightbox opens with a new payload
  useEffect(() => {
    if (!lightbox) return;
    const idx = lightbox.index ?? 0;
    setCurrentIndex(idx);
    setItem(lightbox.items[idx] || null);
    setVideoQuality("original");
    setSlideshowPlaying(!!lightbox.autoplay);
  }, [lightbox]);

  const actions = useMediaActions(ctx, (updated) => {
    if (!updated) return;
    cacheRef.current.set(updated.id, updated);
    setItem((current) => (current?.id === updated.id ? updated : current));
  });

  // Load full API detail for richer data (like counts, description, tags)
  useEffect(() => {
    const target = items[currentIndex];
    if (!target) return;
    const { id } = target;
    if (cacheRef.current.has(id)) {
      setItem(cacheRef.current.get(id));
      return;
    }
    let cancelled = false;
    apiFetch(`/api/media/${id}`).then((data) => {
      if (cancelled) return;
      const m = data.media || target;
      cacheRef.current.set(id, m);
      setItem(m);
    }).catch(() => {
      if (!cancelled) {
        cacheRef.current.set(id, target);
      }
    });
    return () => { cancelled = true; };
  }, [currentIndex, items]);

  // Warm the next/previous image so arrow-key/swipe navigation is instant.
  useEffect(() => {
    if (typeof Image === "undefined") return;
    [currentIndex + 1, currentIndex - 1].forEach((i) => {
      const neighbour = items[i];
      if (!neighbour || neighbour.locked || neighbour.media_kind !== "image" || isGifMedia(neighbour)) return;
      const src = thumbUrl(neighbour, 1280);
      if (!src) return;
      const img = new Image();
      img.decoding = "async";
      img.src = src;
    });
  }, [currentIndex, items]);

  const goTo = useCallback((idx) => {
    if (!lightbox) return;
    if (idx < 0 || idx >= lightbox.items.length) return;
    setCurrentIndex(idx);
    setItem(lightbox.items[idx] || null);
    setVideoQuality("original");
  }, [lightbox]);

  // Auto-advance one slide every `slideshowSeconds`. Re-arms on every
  // currentIndex change so each slide gets its own full interval; stops
  // (doesn't loop) once the last item is reached.
  useEffect(() => {
    if (!slideshowPlaying) return;
    const timer = setTimeout(() => {
      if (currentIndexRef.current >= items.length - 1) {
        setSlideshowPlaying(false);
        return;
      }
      goTo(currentIndexRef.current + 1);
    }, slideshowSeconds * 1000);
    return () => clearTimeout(timer);
  }, [slideshowPlaying, slideshowSeconds, currentIndex, items.length, goTo]);

  // Keyboard navigation — use refs so effect is stable.
  // Skip arrow keys when current item is a video: the VideoPlayer's own keyboard
  // handler handles ArrowLeft/ArrowRight for seeking, and both handlers would fire.
  useEffect(() => {
    const onKey = (e) => {
      if (e.key === "Escape") { closeLightbox(); return; }
      if (itemRef.current?.media_kind === "video") return;
      if (e.key === "ArrowLeft") goTo(currentIndexRef.current - 1);
      if (e.key === "ArrowRight") goTo(currentIndexRef.current + 1);
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [closeLightbox, goTo]);

  // Body scroll lock
  useEffect(() => {
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => { document.body.style.overflow = prev; };
  }, []);

  if (!lightbox || !item) return null;

  const gif = isGifMedia(item);
  const isVideo = item.media_kind === "video";
  const imageSources = gif
    ? [item.url, item.preview_url, item.thumb_url].filter(Boolean)
    : mediaImageSources(item, { width: 1280, previewSize: "detail" });
  const videoSrc = isVideo ? videoQualityUrl(item, videoQuality) : "";
  const chips = [item.category_name, ...(item.tags || [])].filter(Boolean);
  const canPrev = currentIndex > 0;
  const canNext = currentIndex < items.length - 1;

  return (
    <div
      className="lb-backdrop"
      onClick={closeLightbox}
      role="dialog"
      aria-modal="true"
      aria-label="Media preview"
    >
      <div className="lb-panel liquid-glass" onClick={(e) => e.stopPropagation()} onPointerMove={glassPointerMove}>
        <button className="lb-close icon-button liquid-glass" type="button" onClick={closeLightbox} aria-label="Close preview" onPointerMove={glassPointerMove}>
          <X size={18} />
        </button>

        {canPrev && (
          <button className="lb-nav lb-nav-prev liquid-glass" type="button" onClick={() => goTo(currentIndex - 1)} aria-label="Previous media" onPointerMove={glassPointerMove}>
            <ChevronLeft size={24} />
          </button>
        )}
        {canNext && (
          <button className="lb-nav lb-nav-next liquid-glass" type="button" onClick={() => goTo(currentIndex + 1)} aria-label="Next media" onPointerMove={glassPointerMove}>
            <ChevronRight size={24} />
          </button>
        )}

        <div className="lb-media">
          {isVideo ? (
            <VideoPlayer
              src={videoSrc}
              poster={thumbUrl(item, 1024)}
              quality={videoQuality}
              onQualityChange={setVideoQuality}
              qualityOptions={[["original", "Original"], ["1080p", "1080p HD"], ["720p", "720p"], ["480p", "480p"]]}
              title={item.title}
              mediaId={item.id}
            />
          ) : (
            gif ? (
              <ResilientImage className="gif-full" sources={imageSources} alt={item.title || ""} />
            ) : (
              <ProgressiveImage
                className="lb-img"
                placeholder={thumbUrl(item, 640)}
                sources={imageSources}
                alt={item.title || ""}
                decoding="async"
              />
            )
          )}
        </div>

        <div className="lb-info">
          <div className="lb-info-top">
            <Link className="lb-user" to={`/users/${item.username || ""}`} onClick={closeLightbox}>
              <Avatar user={item} compact />
              <span>{item.display_name || item.username || "User"}</span>
            </Link>
            <Link
              className="button-link lb-fullpage"
              to={`/media/${item.id}`}
              state={{ siblingIds: items.map((row) => row.id), atIndex: currentIndex }}
              onClick={closeLightbox}
            >
              <ExternalLink size={13} />Full page
            </Link>
          </div>
          <h2 className="lb-title">{item.title || "Untitled"}</h2>
          {item.description ? <p className="lb-desc">{item.description}</p> : null}
          {item.source_url ? (
            <p className="lb-source">
              <span>Original source: </span>
              {/* Uploader-supplied outbound link: no referrer, no ranking passed.
                  The server only ever stores http/https here. */}
              <a href={item.source_url} target="_blank" rel="noopener noreferrer nofollow"
                 onClick={(event) => event.stopPropagation()}>
                {(() => {
                  try { return new URL(item.source_url).hostname.replace(/^www\./, ""); }
                  catch { return item.source_url; }
                })()}
              </a>
            </p>
          ) : null}
          <StatsRow item={item} />
          {chips.length ? <ChipRow values={chips} /> : null}
          <div className="lb-actions">
            <button type="button" className={item.liked_by_me ? "primary" : ""} onClick={() => actions.toggleLike(item)}>
              <Heart size={15} className={item.liked_by_me ? "filled" : ""} />
              {item.liked_by_me ? "Unlike" : "Like"}
            </button>
            <button type="button" className={item.bookmarked_by_me ? "primary" : ""} onClick={() => actions.toggleBookmark(item)}>
              <Bookmark size={15} className={item.bookmarked_by_me ? "filled" : ""} />
              {item.bookmarked_by_me ? "Saved" : "Save"}
            </button>
            <button type="button" onClick={() => actions.download(item)}>
              <Download size={15} />Download
            </button>
            <button type="button" onClick={() => actions.copyAddress(item)}>
              <Copy size={15} />Copy URL
            </button>
          </div>
          {items.length > 1 ? (
            <div className="lb-counter">
              <button type="button" className="lb-counter-prev" disabled={!canPrev} onClick={() => goTo(currentIndex - 1)}>‹</button>
              <span>{currentIndex + 1} / {items.length}</span>
              <button type="button" className="lb-counter-next" disabled={!canNext} onClick={() => goTo(currentIndex + 1)}>›</button>
            </div>
          ) : null}
          {items.length > 1 ? (
            <div className="lb-slideshow">
              <button
                type="button"
                className="lb-slideshow-toggle"
                onClick={() => setSlideshowPlaying((playing) => !playing)}
                aria-label={slideshowPlaying ? "Pause slideshow" : "Play all"}
              >
                {slideshowPlaying ? <Pause size={14} /> : <Play size={14} />}
                {slideshowPlaying ? "Pause" : "Play all"}
              </button>
              <select
                className="lb-slideshow-speed"
                value={slideshowSeconds}
                onChange={(e) => setSlideshowSeconds(Number(e.target.value))}
                aria-label="Slideshow speed"
              >
                <option value={3}>3s</option>
                <option value={5}>5s</option>
                <option value={10}>10s</option>
                <option value={15}>15s</option>
              </select>
            </div>
          ) : null}
        </div>
      </div>
    </div>
  );
}
