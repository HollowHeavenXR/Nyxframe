import { useCallback, useRef } from "react";
import { useNavigate } from "react-router-dom";
import { apiFetch, clearApiCache, resolveApiUrl } from "../api.js";

export function useMediaActions(ctx, onItemUpdated) {
  const navigate = useNavigate();
  // Stable refs so action callbacks never go stale without triggering re-renders
  const ctxRef = useRef(ctx);
  ctxRef.current = ctx;
  const onItemUpdatedRef = useRef(onItemUpdated);
  onItemUpdatedRef.current = onItemUpdated;

  const requireAuth = useCallback(() => {
    if (ctxRef.current.user) return true;
    navigate("/login");
    return false;
  }, [navigate]);

  // Only the caches a post can appear in -- clearing everything also threw
  // away categories/tags and prefetched pages after every like.
  const clearPostCaches = useCallback(() => {
    ["/api/media", "/api/feed", "/api/users", "/api/collections", "/api/me"].forEach((prefix) => clearApiCache(prefix));
  }, []);

  const update = useCallback((item) => {
    clearPostCaches();
    onItemUpdatedRef.current?.(item);
  }, [clearPostCaches]);

  // Like/bookmark flip in the UI immediately (the round trip through the
  // tunnel is ~150ms) and roll back if the server rejects it.
  const toggleLike = useCallback(async (item) => {
    if (!requireAuth()) return;
    const liked = !item.liked_by_me;
    const count = Number(item.like_count ?? item.likes ?? 0);
    const optimistic = { ...item, liked_by_me: liked, like_count: Math.max(0, count + (liked ? 1 : -1)) };
    if ("likes" in item) optimistic.likes = optimistic.like_count;
    onItemUpdatedRef.current?.(optimistic);
    try {
      const data = await apiFetch(`/api/media/${item.id}/like`, {
        method: "POST",
        body: JSON.stringify({ liked }),
      });
      update(data.media || optimistic);
    } catch (error) {
      onItemUpdatedRef.current?.(item);
      ctxRef.current.showToast(error.message, "error");
    }
  }, [requireAuth, update]);

  const toggleBookmark = useCallback(async (item) => {
    if (!requireAuth()) return;
    const bookmarked = !item.bookmarked_by_me;
    onItemUpdatedRef.current?.({ ...item, bookmarked_by_me: bookmarked });
    try {
      const data = await apiFetch(`/api/media/${item.id}/bookmark`, {
        method: "POST",
        body: JSON.stringify({ bookmarked }),
      });
      update(data.media || { ...item, bookmarked_by_me: bookmarked });
    } catch (error) {
      onItemUpdatedRef.current?.(item);
      ctxRef.current.showToast(error.message, "error");
    }
  }, [requireAuth, update]);

  const download = useCallback((item) => {
    const ctx = ctxRef.current;
    if (!item.downloads_enabled && Number(item.user_id) !== Number(ctx.user?.id)) {
      ctx.showToast("Downloads are disabled for this post.", "error");
      return;
    }
    window.open(item.download_url || `/api/media/${item.id}/download`, "_blank", "noopener,noreferrer");
  }, []);

  const copyAddress = useCallback(async (item) => {
    const raw = item?.url || item?.preview_url || item?.thumb_url || `/api/media/${item.id}/file`;
    try {
      const url = await resolveApiUrl(raw);
      await navigator.clipboard.writeText(url || raw);
      ctxRef.current.showToast("Media address copied.", "success");
    } catch (error) {
      ctxRef.current.showToast(error.message || "Could not copy media address.", "error");
    }
  }, []);

  const copyPageLink = useCallback(async (item) => {
    try {
      // Always resolve against the real backend origin, never window.location.origin:
      // on the GitHub Pages mirror that's a static host that can't render the
      // per-post Open Graph tags Discord/social previews need, but the backend
      // (which also serves this same SPA) can.
      const resolved = await resolveApiUrl(`/media/${item.id}`);
      const url = /^https?:\/\//i.test(resolved) ? resolved : new URL(resolved, window.location.origin).toString();
      await navigator.clipboard.writeText(url);
      ctxRef.current.showToast("Post link copied.", "success");
    } catch (error) {
      ctxRef.current.showToast(error.message || "Could not copy post link.", "error");
    }
  }, []);

  // open_original_in_new_tab was stored/editable on the Settings page
  // (SettingsPage.jsx) and even summarized in a status readout there, but
  // never actually consulted here -- this always opened a new tab
  // regardless of the setting, same class of bug as show_liked_count/
  // profile_show_follow_counts/profile_show_joined_date, which routes.lua's
  // decode_user already documents fixing server-side. This one's purely
  // client-side (no privacy/leak angle, just an inert preference), so the
  // fix is just: actually branch on it.
  const openOriginal = useCallback(async (item) => {
    const raw = item?.url || item?.preview_url || `/api/media/${item.id}/file`;
    const url = await resolveApiUrl(raw).catch(() => raw);
    if (ctxRef.current.settings?.open_original_in_new_tab) {
      window.open(url, "_blank", "noopener,noreferrer");
    } else {
      window.location.href = url;
    }
  }, []);

  return { toggleLike, toggleBookmark, download, copyAddress, copyPageLink, openOriginal };
}
