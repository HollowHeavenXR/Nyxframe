import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link, useLocation, useNavigate, useParams } from "react-router-dom";
import { Bookmark, ChevronLeft, ChevronRight, Copy, Download, Eye, Heart, Image as ImageIcon, Link as LinkIcon, Lock, MessageCircle, Reply, Tag, Trash2, X as XIcon } from "lucide-react";
import { apiFetch } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { useMediaActions } from "../hooks/useMediaActions.js";
import { MediaActionPanel, MediaControls, MediaEditHistory, MediaEditor } from "../components/media.jsx";
import { VideoPlayer } from "../components/VideoPlayer.jsx";
import { Avatar, ChipRow, EmptyState, glassPointerMove, Notice, NotFound, Page, ProgressiveImage, ResilientImage, SkeletonGrid, StatsRow, UserLine } from "../components/ui.jsx";
import { imageQualityUrl, isGifMedia, thumbUrl, videoQualityUrl } from "../utils/media.js";
import { getPlayerPref, setPlayerPref } from "../utils/playerPrefs.js";

const REACTION_EMOJIS = ["👍", "❤️", "😂", "😮", "😢", "🔥"];

function subcategoryNames(item) {
  if (Array.isArray(item?.subcategory_names) && item.subcategory_names.length) return item.subcategory_names;
  if (Array.isArray(item?.subcategories) && item.subcategories.length) return item.subcategories.map((row) => row?.name).filter(Boolean);
  return item?.subcategory_name ? [item.subcategory_name] : [];
}

export function MediaDetailPage({ ctx }) {
  const { mediaId } = useParams();
  const location = useLocation();
  const navigate = useNavigate();
  const siblingIds = useMemo(() => (Array.isArray(location.state?.siblingIds) ? location.state.siblingIds : []), [location.state]);
  const siblingIndex = useMemo(() => siblingIds.findIndex((id) => String(id) === String(mediaId)), [siblingIds, mediaId]);
  const [media, setMedia] = useState(null);
  const [comments, setComments] = useState([]);
  const [openCommentReactionPicker, setOpenCommentReactionPicker] = useState(null);
  const [commentBody, setCommentBody] = useState("");
  const [replyTo, setReplyTo] = useState(null);
  const [reactions, setReactions] = useState({ counts: {}, my_reaction: null });
  const [similar, setSimilar] = useState([]);
  const [personalTags, setPersonalTags] = useState([]);
  const [personalTagInput, setPersonalTagInput] = useState("");
  const [report, setReport] = useState({ reason: "", details: "" });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [imageQuality, setImageQuality] = useState("medium");
  // Seeded from the viewer's own last explicit choice: someone on a
  // capped connection who picks 480p meant it for their connection, not
  // for that one post, and re-picking it on every video was busywork.
  // Only ever written from a real menu pick (see changeVideoQuality) --
  // the player also calls onQualityChange by itself to escape an
  // undecodable codec, and remembering THAT would pin an unrelated
  // fallback quality across the whole site.
  const [videoQuality, setVideoQuality] = useState(() => getPlayerPref("quality", "original"));
  const actions = useMediaActions(ctx, (updated) => setMedia(updated));
  const abortRef = useRef(null);

  const loadDetail = useCallback(async ({ background = false } = {}) => {
    if (abortRef.current) abortRef.current.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    if (!background) {
      setLoading(true);
      setError("");
    }
    try {
      const data = await apiFetch(`/api/media/${mediaId}`, { signal: controller.signal });
      if (controller.signal.aborted) return;
      setMedia(data.media);
      setComments(data.comments || []);
      setReactions(data.reactions || { counts: {}, my_reaction: null });
      setSimilar(data.similar || []);
      setPersonalTags(data.personal_tags || []);
    } catch (fetchError) {
      if (controller.signal.aborted) return;
      if (!background) {
        setError(fetchError.message);
        setMedia(null);
      }
    } finally {
      if (!controller.signal.aborted && !background) setLoading(false);
    }
  }, [mediaId]);

  useEffect(() => {
    loadDetail();
    return () => { if (abortRef.current) abortRef.current.abort(); };
  }, [loadDetail]);

  const changeVideoQuality = useCallback((value, options) => {
    setVideoQuality(value);
    if (options?.userInitiated) setPlayerPref("quality", value);
  }, []);

  useEffect(() => {
    setVideoQuality(getPlayerPref("quality", "original"));
    setImageQuality("medium");
  }, [mediaId]);

  useLiveRefresh(() => loadDetail({ background: true }), { enabled: Boolean(mediaId) && media?.media_kind !== "video", interval: 45_000 });

  // "N people viewing this now" -- a heartbeat, not a one-shot fetch:
  // every ~15s tells the backend "still here," and media_active_viewers
  // ages a viewer out automatically if the heartbeats stop (tab closed,
  // navigated away) rather than needing an explicit leave signal. Pausing
  // while backgrounded (useLiveRefresh's own behavior) is correct here
  // too -- someone who switched tabs isn't actively viewing either.
  const [viewingNow, setViewingNow] = useState(null);
  const sendViewingHeartbeat = useCallback(async () => {
    if (!mediaId) return;
    try {
      const data = await apiFetch(`/api/media/${mediaId}/viewing`, { method: "POST" });
      setViewingNow(typeof data.viewing_now === "number" ? data.viewing_now : null);
    } catch {
      // A missed heartbeat (403 on an adult post before verification, a
      // transient network blip) just means the count doesn't show this
      // tick -- not worth surfacing as a page error for a decorative stat.
    }
  }, [mediaId]);
  useEffect(() => { setViewingNow(null); }, [mediaId]);
  useLiveRefresh(sendViewingHeartbeat, { enabled: Boolean(mediaId), interval: 15_000, immediate: true });

  const goToSibling = useCallback((nextIndex) => {
    if (nextIndex < 0 || nextIndex >= siblingIds.length) return;
    navigate(`/media/${siblingIds[nextIndex]}`, { state: { siblingIds, atIndex: nextIndex }, replace: true });
  }, [navigate, siblingIds]);

  // Stable identities: the player registers these as OS media-session
  // handlers and re-binds its keyboard listener whenever they change, so
  // a fresh closure on every render would churn both on every keystroke
  // in the comment box.
  const hasPrevious = siblingIndex > 0;
  const hasNext = siblingIndex >= 0 && siblingIndex < siblingIds.length - 1;
  const goToPreviousSibling = useCallback(() => goToSibling(siblingIndex - 1), [goToSibling, siblingIndex]);
  const goToNextSibling = useCallback(() => goToSibling(siblingIndex + 1), [goToSibling, siblingIndex]);

  useEffect(() => {
    if (siblingIndex < 0 || siblingIds.length < 2) return undefined;
    const onKey = (event) => {
      const target = event.target;
      const typing = target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.isContentEditable);
      if (typing || media?.media_kind === "video") return;
      if (event.key === "ArrowLeft") goToSibling(siblingIndex - 1);
      if (event.key === "ArrowRight") goToSibling(siblingIndex + 1);
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [goToSibling, media?.media_kind, siblingIndex, siblingIds.length]);

  async function addComment(event) {
    event.preventDefault();
    if (!media || !commentBody.trim()) return;
    try {
      const data = await apiFetch(`/api/media/${media.id}/comments`, {
        method: "POST",
        body: JSON.stringify({ body: commentBody.trim(), parent_comment_id: replyTo?.id || null }),
      });
      setComments((rows) => [...rows, data.comment]);
      setCommentBody("");
      setReplyTo(null);
      ctx.showToast("Comment posted.", "success");
    } catch (commentError) {
      ctx.showToast(commentError.message, "error");
    }
  }

  async function react(emoji) {
    if (!media) return;
    try {
      const data = await apiFetch(`/api/media/${media.id}/react`, {
        method: "POST",
        body: JSON.stringify({ emoji }),
      });
      setReactions(data.reactions || { counts: {}, my_reaction: null });
    } catch (reactError) {
      ctx.showToast(reactError.message, "error");
    }
  }

  async function reactToComment(commentId, emoji) {
    try {
      const data = await apiFetch(`/api/comments/${commentId}/react`, {
        method: "POST",
        body: JSON.stringify({ emoji }),
      });
      const nextReactions = data.reactions || { counts: {}, my_reaction: null };
      setComments((rows) => rows.map((row) => (Number(row.id) === Number(commentId) ? { ...row, reactions: nextReactions } : row)));
    } catch (reactError) {
      ctx.showToast(reactError.message, "error");
    }
  }

  // Compact version of the post-level reaction tray: existing reactions
  // with a nonzero count always show as pills (click to toggle your own),
  // and a small "+" reveals the full emoji row to react for the first
  // time -- a comment row has far less width than the post header, so
  // always showing all 6 emojis per comment (like the post tray does)
  // would dominate the thread instead of the comments themselves.
  function renderCommentReactionRow(comment) {
    const counts = comment.reactions?.counts || {};
    const myReaction = comment.reactions?.my_reaction || null;
    const present = REACTION_EMOJIS.filter((emoji) => counts[emoji] || emoji === myReaction);
    const pickerOpen = openCommentReactionPicker === comment.id;
    if (!ctx.user) {
      return present.length ? (
        <div className="comment-reactions">
          {present.map((emoji) => (
            <span key={emoji} className="reaction-pill reaction-pill-static">{emoji} {counts[emoji] || ""}</span>
          ))}
        </div>
      ) : null;
    }
    return (
      <div className="comment-reactions">
        {present.map((emoji) => (
          <button
            key={emoji}
            type="button"
            className={`reaction-pill reaction-pill-sm ${myReaction === emoji ? "active" : ""}`}
            onClick={() => { reactToComment(comment.id, emoji); setOpenCommentReactionPicker(null); }}
          >
            {emoji} {counts[emoji] || ""}
          </button>
        ))}
        <button
          type="button"
          className="icon-button reaction-add-button"
          title="Add reaction"
          onClick={() => setOpenCommentReactionPicker(pickerOpen ? null : comment.id)}
        >
          +
        </button>
        {pickerOpen ? (
          <div className="comment-reaction-picker">
            {REACTION_EMOJIS.map((emoji) => (
              <button
                key={emoji}
                type="button"
                className="reaction-pill reaction-pill-sm"
                onClick={() => { reactToComment(comment.id, emoji); setOpenCommentReactionPicker(null); }}
              >
                {emoji}
              </button>
            ))}
          </div>
        ) : null}
      </div>
    );
  }

  async function deleteComment(commentId) {
    if (!window.confirm("Delete this comment?")) return;
    try {
      await apiFetch(`/api/comments/${commentId}`, { method: "DELETE" });
      setComments((rows) => rows.filter((comment) => Number(comment.id) !== Number(commentId)));
    } catch (deleteError) {
      ctx.showToast(deleteError.message, "error");
    }
  }

  async function reportMedia(event) {
    event.preventDefault();
    if (!report.reason.trim()) return;
    try {
      await apiFetch(`/api/media/${media.id}/report`, {
        method: "POST",
        body: JSON.stringify(report),
      });
      setReport({ reason: "", details: "" });
      ctx.showToast("Report sent.", "success");
    } catch (reportError) {
      ctx.showToast(reportError.message, "error");
    }
  }

  async function addPersonalTag(event) {
    event.preventDefault();
    const tag = personalTagInput.trim();
    if (!media || !tag) return;
    try {
      const data = await apiFetch(`/api/media/${media.id}/personal-tags`, {
        method: "POST",
        body: JSON.stringify({ tag }),
      });
      setPersonalTags(data.personal_tags || []);
      setPersonalTagInput("");
    } catch (tagError) {
      ctx.showToast(tagError.message, "error");
    }
  }

  async function removePersonalTag(tag) {
    if (!media) return;
    try {
      const data = await apiFetch(`/api/media/${media.id}/personal-tags/${encodeURIComponent(tag)}`, { method: "DELETE" });
      setPersonalTags(data.personal_tags || []);
    } catch (tagError) {
      ctx.showToast(tagError.message, "error");
    }
  }

  if (loading) return <Page title="Media" eyebrow="Loading"><SkeletonGrid count={1} /></Page>;
  if (error) return <Page title="Media" eyebrow="Error"><Notice kind="error" onRetry={() => loadDetail()}>{error}</Notice></Page>;
  if (!media) return <NotFound />;

  const isOwner = ctx.user && Number(ctx.user.id) === Number(media.user_id);
  const gif = isGifMedia(media);
  const videoSrc = media.media_kind === "video" ? videoQualityUrl(media, videoQuality) : "";
  const metadataChips = [media.category_name, ...subcategoryNames(media), ...(media.tags || [])].filter(Boolean);
  const detailImageSources = gif
    ? [media.url, media.preview_url, media.thumb_url].filter(Boolean)
    : (
        imageQuality === "high"
          ? [media.url, imageQualityUrl(media, "medium"), imageQualityUrl(media, "low")]
          : imageQuality === "low"
            ? [imageQualityUrl(media, "low"), imageQualityUrl(media, "medium"), media.url]
            : [imageQualityUrl(media, "medium"), imageQualityUrl(media, "low"), media.url]
      ).filter(Boolean);

  return (
    <Page title={media.title || `Media ${media.id}`} eyebrow={media.media_kind || "Media"} actions={(
      <>
        <button type="button" onClick={() => actions.toggleLike(media)}><Heart size={16} />{media.liked_by_me ? "Unlike" : "Like"}</button>
        <button type="button" onClick={() => actions.toggleBookmark(media)}><Bookmark size={16} />{media.bookmarked_by_me ? "Saved" : "Save"}</button>
        <button type="button" onClick={() => actions.copyAddress(media)}><Copy size={16} />Copy URL</button>
        <button type="button" onClick={() => actions.copyPageLink(media)}><LinkIcon size={16} />Copy Link</button>
        <button type="button" onClick={() => actions.download(media)}><Download size={16} />Download</button>
      </>
    )}>
      <section className="detail-layout">
        {/* Stage and comments share the left column so it isn't a short
            image beside a long side column with empty space under it. */}
        <div className="detail-main">
        <article className="media-stage">
          {siblingIndex >= 0 && siblingIds.length > 1 ? (
            <div className="detail-stage-nav">
              <button type="button" className="icon-button" disabled={siblingIndex <= 0} onClick={() => goToSibling(siblingIndex - 1)} aria-label="Previous media">
                <ChevronLeft size={18} />
              </button>
              <span>{siblingIndex + 1} / {siblingIds.length}</span>
              <button type="button" className="icon-button" disabled={siblingIndex >= siblingIds.length - 1} onClick={() => goToSibling(siblingIndex + 1)} aria-label="Next media">
                <ChevronRight size={18} />
              </button>
            </div>
          ) : null}
          {media.locked ? (
            <div className="locked-state"><Lock size={38} /><h2>Age verification required</h2></div>
          ) : media.media_kind === "video" ? (
            <VideoPlayer
              src={videoSrc}
              poster={thumbUrl(media, 640)}
              quality={videoQuality}
              onQualityChange={changeVideoQuality}
              qualityOptions={[["auto", "Auto"], ["original", "Original"], ["1080p", "1080p HD"], ["720p", "720p"], ["480p", "480p"], ["144p", "144p"]]}
              title={media.title}
              mediaId={media.id}
              author={media.display_name || media.username}
              onPrevious={hasPrevious ? goToPreviousSibling : undefined}
              onNext={hasNext ? goToNextSibling : undefined}
            />
          ) : (
            <>
              {!gif ? (
                <div className="quality-bar">
                  <span>Image quality</span>
                  <select value={imageQuality} onChange={(event) => setImageQuality(event.target.value)} aria-label="Image quality">
                    <option value="high">High / full</option>
                    <option value="medium">Medium</option>
                    <option value="low">Low</option>
                  </select>
                </div>
              ) : null}
              {gif ? (
                <ResilientImage className="gif-full" sources={detailImageSources} diagnostics={{ mediaId: media.id, mediaKind: media.media_kind, context: `detail-image-${imageQuality}` }} alt={media.title || ""} fallback={<div className="locked-state"><Notice kind="error">Media preview failed to load.</Notice></div>} />
              ) : (
                <ProgressiveImage placeholder={thumbUrl(media, 640)} sources={detailImageSources} diagnostics={{ mediaId: media.id, mediaKind: media.media_kind, context: `detail-image-${imageQuality}` }} alt={media.title || ""} decoding="async" fallback={<div className="locked-state"><Notice kind="error">Media preview failed to load.</Notice></div>} />
              )}
            </>
          )}
        </article>
        <section className="comments-panel">
          <div className="section-head"><h2>Comments</h2><span>{comments.length}</span></div>
          {ctx.user && media.comments_enabled !== false ? (
            <form className="comment-form" onSubmit={addComment}>
              {replyTo ? (
                <div className="reply-banner">
                  <span>Replying to {replyTo.display_name || replyTo.username}</span>
                  <button type="button" className="icon-button" onClick={() => setReplyTo(null)}>Cancel</button>
                </div>
              ) : null}
              <input value={commentBody} onChange={(event) => setCommentBody(event.target.value)} placeholder="Add a comment (@mention a username)" />
              <button type="submit"><MessageCircle size={16} />Post</button>
            </form>
          ) : null}
          <div className="comments-list">
            {comments.length ? comments.filter((comment) => !comment.parent_comment_id).map((comment) => {
              const replies = comments.filter((row) => Number(row.parent_comment_id) === Number(comment.id));
              const canDelete = ctx.user && (Number(ctx.user.id) === Number(comment.user_id) || Number(ctx.user.id) === Number(media.user_id));
              return (
                <div key={comment.id}>
                  <article className="comment">
                    <Avatar user={comment} compact />
                    <div>
                      <strong>{comment.display_name || comment.username || "User"}</strong>
                      <p>{comment.body}</p>
                      {renderCommentReactionRow(comment)}
                      {ctx.user ? <button type="button" className="icon-button" onClick={() => setReplyTo(comment)} title="Reply"><Reply size={14} /></button> : null}
                    </div>
                    {canDelete ? <button className="icon-button" type="button" onClick={() => deleteComment(comment.id)} title="Delete"><Trash2 size={16} /></button> : null}
                  </article>
                  {replies.length ? (
                    <div className="comment-replies">
                      {replies.map((reply) => {
                        const canDeleteReply = ctx.user && (Number(ctx.user.id) === Number(reply.user_id) || Number(ctx.user.id) === Number(media.user_id));
                        return (
                          <article className="comment comment-reply" key={reply.id}>
                            <Avatar user={reply} compact />
                            <div>
                              <strong>{reply.display_name || reply.username || "User"}</strong>
                              <p>{reply.body}</p>
                              {renderCommentReactionRow(reply)}
                            </div>
                            {canDeleteReply ? <button className="icon-button" type="button" onClick={() => deleteComment(reply.id)} title="Delete"><Trash2 size={16} /></button> : null}
                          </article>
                        );
                      })}
                    </div>
                  ) : null}
                </div>
              );
            }) : <EmptyState title="No comments yet" />}
          </div>
        </section>
        </div>
        <aside className="detail-side">
          <UserLine user={media} />
          {media.description ? <p className="description">{media.description}</p> : null}
          {media.source_url ? (
            <p className="media-source">
              <span>Original source: </span>
              {/* noopener+noreferrer+nofollow: this is an uploader-supplied
                  outbound link, so it must not leak the referrer or pass
                  ranking. The server only ever stores http/https here. */}
              <a href={media.source_url} target="_blank" rel="noopener noreferrer nofollow">
                {(() => { try { return new URL(media.source_url).hostname.replace(/^www\./, ""); } catch { return media.source_url; } })()}
              </a>
            </p>
          ) : null}
          <StatsRow item={media} />
          {viewingNow >= 2 ? (
            <p className="viewing-now-badge"><Eye size={14} /> {viewingNow} people viewing this now</p>
          ) : null}
          <ChipRow values={metadataChips} />
          {ctx.user ? (
            <div className="side-box personal-tags-box">
              <h3><Tag size={14} />Your private tags</h3>
              <p className="field-hint">Only visible to you — for your own organizing, never shown to anyone else.</p>
              {personalTags.length ? (
                <div className="chip-row">
                  {personalTags.map((tag) => (
                    <span key={tag}>
                      {tag}
                      <button type="button" onClick={() => removePersonalTag(tag)} aria-label={`Remove tag ${tag}`}><XIcon size={12} /></button>
                    </span>
                  ))}
                </div>
              ) : null}
              <form onSubmit={addPersonalTag} className="two-col">
                <input value={personalTagInput} onChange={(event) => setPersonalTagInput(event.target.value)} placeholder="Add a private tag" maxLength={32} />
                <button type="submit" disabled={!personalTagInput.trim()}>Add</button>
              </form>
            </div>
          ) : null}
          {ctx.user ? (
            <div className="reaction-tray">
              {REACTION_EMOJIS.map((emoji) => (
                <button
                  type="button"
                  key={emoji}
                  className={`reaction-pill ${reactions.my_reaction === emoji ? "active" : ""}`}
                  onClick={() => react(emoji)}
                >
                  {emoji} {reactions.counts?.[emoji] ? reactions.counts[emoji] : ""}
                </button>
              ))}
            </div>
          ) : null}
          <MediaActionPanel ctx={ctx} media={media} actions={actions} />
          {/* Owner tools and Report are occasional tasks: collapsed by
              default so they don't stretch the side column. */}
          {isOwner ? (
            <details className="side-disclosure">
              <summary>Edit post</summary>
              <MediaEditor ctx={ctx} media={media} onChanged={setMedia} />
            </details>
          ) : null}
          {isOwner ? (
            <details className="side-disclosure">
              <summary>Visibility &amp; controls</summary>
              <MediaControls ctx={ctx} media={media} onChanged={setMedia} />
            </details>
          ) : null}
          {isOwner ? (
            <details className="side-disclosure">
              <summary>Edit history</summary>
              <MediaEditHistory ctx={ctx} media={media} />
            </details>
          ) : null}
          {ctx.user ? (
            <details className="side-disclosure">
              <summary>Report this post</summary>
              <form className="side-box" onSubmit={reportMedia}>
                <input value={report.reason} onChange={(event) => setReport((current) => ({ ...current, reason: event.target.value }))} placeholder="Reason" />
                <textarea value={report.details} onChange={(event) => setReport((current) => ({ ...current, details: event.target.value }))} placeholder="Details" rows={3} />
                <button type="submit">Send</button>
              </form>
            </details>
          ) : null}
        </aside>
      </section>
      {similar.length ? (
        <section className="similar-media-panel">
          <div className="section-head">
            <h2>More like this</h2>
            <span className="section-head-links">
              {media.media_kind === "image" ? (
                <Link to={`/visual-search?mediaId=${media.id}`} className="similar-media-see-all">Find visually similar</Link>
              ) : null}
              <Link to={`/media/${media.id}/similar`} className="similar-media-see-all">See all</Link>
            </span>
          </div>
          <div className="similar-media-rail">
            {similar.map((item) => (
              <Link
                className={`profile-media-mini liquid-glass ${item.locked ? "is-locked" : ""}`}
                to={`/media/${item.id}`}
                key={item.id}
                onPointerMove={glassPointerMove}
              >
                {item.locked ? (
                  <div className="video-thumb-placeholder"><Lock size={28} /></div>
                ) : (
                  <ResilientImage
                    sources={[item.thumb_url, item.preview_url].filter(Boolean)}
                    diagnostics={{ mediaId: item.id, mediaKind: item.media_kind, context: "similar-media" }}
                    alt=""
                    loading="lazy"
                    decoding="async"
                    fallback={<div className="video-thumb-placeholder"><ImageIcon size={28} /></div>}
                  />
                )}
                <span>{item.locked ? "18+ content" : (item.title || "Untitled")}</span>
              </Link>
            ))}
          </div>
        </section>
      ) : null}
    </Page>
  );
}
