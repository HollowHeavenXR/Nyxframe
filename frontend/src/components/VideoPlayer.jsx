import { useCallback, useEffect, useRef, useState } from "react";
import { reportMediaPlaybackDiagnostic } from "../utils/media.js";
import { apiFetch, apiUrl } from "../api.js";
import { parseSpriteVtt, parseVtt, spriteTileAt } from "../utils/vtt.js";
import {
  clearResumePosition,
  getNumericPref,
  getPlayerPref,
  getResumePosition,
  saveResumePosition,
  setPlayerPref,
} from "../utils/playerPrefs.js";
import {
  Activity,
  AlertCircle,
  Captions,
  CaptionsOff,
  Gauge,
  Image as ImageIcon,
  Loader2,
  Maximize,
  Minimize,
  Pause,
  PictureInPicture2,
  Play,
  RefreshCw,
  Repeat,
  RotateCcw,
  SkipBack,
  SkipForward,
  SkipForward as NextIcon,
  Volume1,
  Volume2,
  VolumeX,
} from "lucide-react";

function formatTime(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00";
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  if (h > 0) return `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
  return `${m}:${String(s).padStart(2, "0")}`;
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

const SPEEDS = [0.5, 0.75, 1, 1.25, 1.5, 2];

// How long a tap waits to find out whether it's half of a double-tap.
const DOUBLE_TAP_MS = 300;

// The ?access= capability token that lets a private/adult post's
// sub-resources be fetched without a session, lifted off the stream URL
// the caller already built (see routes.lua's hls_propagated_qs). The
// sprite sheet is loaded as a plain <img>, which can attach no headers,
// so it needs the token in the URL the same way the HLS segments do.
function accessQuery(src) {
  if (!src) return "";
  try {
    const parsed = new URL(src, window.location.origin);
    const access = parsed.searchParams.get("access");
    return access ? `?access=${encodeURIComponent(access)}` : "";
  } catch (_error) {
    return "";
  }
}

// Autoplay policies reject an UNMUTED play() on a page the viewer hasn't
// interacted with, and the rejection is the only way to find out -- there
// is no reliable "am I allowed" query. So: try it the way the viewer
// asked for (see the restored `muted` preference in the src effect), and
// on refusal drop to muted and start anyway, which every browser permits.
// Without the retry, honouring a saved "unmuted" preference would mean
// some videos simply never started.
function attemptAutoplay(video) {
  const attempt = video.play();
  if (!attempt || typeof attempt.catch !== "function") return;
  attempt.catch(() => {
    if (video.muted) return;
    video.muted = true;
    video.play().catch(() => {});
  });
}

// "original"/"high" is a `-c copy` remux (see routes.lua's ensure_hls_variant)
// -- it plays back whatever codec the upload actually used, unlike every
// other quality option, which always transcodes through libx264/aac and so
// is guaranteed browser-safe regardless of source format. When the browser
// can't decode the source codec (HEVC/ProRes/etc. uploads are common from
// phones), the fix is exactly the same on every engine: drop to the first
// real transcoded rendition available. Shared so both the native-<video>
// error path (Safari) and the hls.js error path (Chrome/Firefox/Opera/
// Chromium/Edge) recover the same way instead of only one of them knowing
// how to.
function pickCompatFallbackQuality(currentQuality, options) {
  if (currentQuality && currentQuality !== "high" && currentQuality !== "original") return null;
  if (!options) return null;
  return options.find(([v]) => v === "1080p" || v === "720p" || v === "480p" || v === "144p");
}

export function VideoPlayer({
  src,
  poster,
  quality,
  onQualityChange,
  qualityOptions,
  title,
  mediaId,
  author,
  onNext,
  onPrevious,
}) {
  const videoRef = useRef(null);
  const containerRef = useRef(null);
  const controlsHideTimer = useRef(null);
  const seekBarRef = useRef(null);
  const volumeBarRef = useRef(null);

  const [playing, setPlaying] = useState(false);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(0);
  const [buffered, setBuffered] = useState(0);
  // Seeded from the last value this viewer actually chose, on any video --
  // a comfortable level (or a chosen speed) is a property of the person and
  // their speakers, not of one post, and having every video snap back to
  // 100% meant reaching for the slider on literally every playback. See
  // utils/playerPrefs.js for why this is device-local and best-effort.
  const [volume, setVolume] = useState(() => getNumericPref("volume", 1, 0, 1));
  // Starts muted, not because the user asked for that, but because it's
  // the only thing every browser's autoplay policy actually allows without
  // a prior click/tap: unmuted autoplay is blocked everywhere, muted
  // autoplay is allowed everywhere. See the fresh-load branch of the
  // `[src]` effect below, which is what actually starts playback.
  const [muted, setMuted] = useState(true);
  const [fullscreen, setFullscreen] = useState(false);
  const [showControls, setShowControls] = useState(true);
  const [buffering, setBuffering] = useState(false);
  const [bufferingLong, setBufferingLong] = useState(false);
  const [error, setError] = useState(null);
  const [speed, setSpeed] = useState(() => {
    const saved = getNumericPref("speed", 1, 0.25, 4);
    return SPEEDS.includes(saved) ? saved : 1;
  });
  const [showSpeedMenu, setShowSpeedMenu] = useState(false);
  const [showQualityMenu, setShowQualityMenu] = useState(false);
  const [seekHover, setSeekHover] = useState(null); // { x, time }
  const [pip, setPip] = useState(false);
  const [loop, setLoop] = useState(false);
  const [showRemaining, setShowRemaining] = useState(false);
  const [seeking, setSeeking] = useState(false);
  // { time } while the "we picked up where you left off" chip is showing.
  const [resumeNotice, setResumeNotice] = useState(null);
  // { dir, key } for the double-tap-to-seek ripple; `key` restarts the CSS
  // animation when the same side is tapped twice in a row.
  const [seekFlash, setSeekFlash] = useState(null);
  const [showStats, setShowStats] = useState(false);
  const [stats, setStats] = useState(null);
  const [autoplayNext, setAutoplayNext] = useState(() => getPlayerPref("autoplayNext", false) === true);
  // Resolved in an effect rather than read inline at render time: the
  // WebKit presentation-mode API lives on the <video> ELEMENT (not on
  // `document` like the standard one), so it can only be probed once the
  // ref is attached.
  const [pipSupported, setPipSupported] = useState(false);
  // { sheetUrl, cues } once the backend has a seek-preview sprite for
  // this video, null while it's still generating (or never will).
  const [sprite, setSprite] = useState(null);
  // { url, language, autoGenerated } for the auto-generated caption track.
  const [captions, setCaptions] = useState(null);
  const [captionsOn, setCaptionsOn] = useState(() => getPlayerPref("captions", false) === true);
  // Adaptive bitrate is only offered on the hls.js path -- see the
  // qualityOptions filter below for why Safari's native engine can't have it.
  const [abrAvailable, setAbrAvailable] = useState(false);

  // ─── Seek-restore state for quality switching ────────────────────────────────
  const pendingRestoreRef = useRef(null); // { time, wasPlaying }
  const bufferingTimerRef = useRef(null);
  const durationRef = useRef(0);
  // Native-HLS (Safari) retry counter for transient network errors — see
  // onError's code===2 branch below for why this exists.
  const nativeNetworkRetriesRef = useRef(0);
  // Same idea for a decode/unsupported-source error (code 3/4) — one
  // same-quality retry before assuming it's a genuine codec
  // incompatibility and auto-downgrading quality. See onError below.
  const decodeRetriesRef = useRef(0);
  // Throttles the resume-position write on `timeupdate` (which fires ~4x a
  // second) down to one localStorage round trip every few seconds.
  const lastResumeSaveRef = useRef(0);
  // Position this load should start at, consumed once by the src effect.
  const resumeAtRef = useRef(0);
  // Double-tap-to-seek bookkeeping: { t, side } of the previous tap, and
  // the deferred single-tap play toggle a second tap cancels.
  const lastTapRef = useRef({ t: 0, side: 0 });
  const singleTapTimerRef = useRef(null);
  // Keyboard shortcuts only apply to a player the viewer is actually
  // pointed at -- see the keydown effect for why a document-level handler
  // that didn't check this was stealing Space/arrows from the whole page.
  const pointerInsideRef = useRef(false);
  // Read from the once-mounted media-event effect, so they always see the
  // latest prop/state instead of first-render values.
  const onNextRef = useRef(onNext);
  onNextRef.current = onNext;
  const onPreviousRef = useRef(onPrevious);
  onPreviousRef.current = onPrevious;
  const autoplayNextRef = useRef(autoplayNext);
  autoplayNextRef.current = autoplayNext;
  const speedRef = useRef(speed);
  speedRef.current = speed;

  // ─── Auto-play tracking ──────────────────────────────────────────────────────
  // Set to true once the user has clicked play; thereafter onCanPlay will resume.
  const shouldAutoPlayRef = useRef(false);

  // ─── Playback telemetry (reportMediaPlaybackDiagnostic on unmount) ──────────
  // Accumulated for the whole component lifetime (a quality switch keeps
  // adding to the same session rather than resetting it) except
  // time-to-first-frame, which only makes sense for the very first load.
  // mediaId/quality read via refs so the unmount cleanup (below, in an
  // effect that only runs once) sees their latest values instead of
  // whatever they were on first render -- same pattern this file already
  // uses for volumeRef.
  const playbackStatsRef = useRef({
    loadStartedAt: null, firstFrameMs: null, stallCount: 0, stallStartedAt: null,
    stallTotalMs: 0, downgradeCount: 0, usingHlsJs: false, hasPlayedOnce: false, fatalError: false,
  });
  const mediaIdRef = useRef(mediaId);
  mediaIdRef.current = mediaId;
  const qualityRef = useRef(quality);
  qualityRef.current = quality;
  // Every terminal (non-recovered) failure in this component goes through
  // `error` state one way or another (onError's several branches, hls.js's
  // ERROR handler) -- watching it here instead of editing each of those
  // call sites individually is what lets this stay a single, low-risk
  // addition rather than touching the carefully-tuned recovery logic below.
  useEffect(() => {
    if (error) playbackStatsRef.current.fatalError = true;
  }, [error]);

  // ─── Controls auto-hide ─────────────────────────────────────────────────────
  const scheduleHide = useCallback(() => {
    if (controlsHideTimer.current) clearTimeout(controlsHideTimer.current);
    controlsHideTimer.current = setTimeout(() => {
      if (videoRef.current && !videoRef.current.paused) setShowControls(false);
    }, 2500);
  }, []);

  const revealControls = useCallback(() => {
    setShowControls(true);
    scheduleHide();
  }, [scheduleHide]);

  // ─── Video event handlers ────────────────────────────────────────────────────
  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;

    // BackgroundMusicPlayer listens for this globally to duck/restore its
    // own volume -- see its VIDEO_PLAYING_EVENT doc comment for why this is
    // a plain window event rather than threaded through context/props.
    //
    // "Audible", not just "playing": every video on this site autoplays
    // MUTED the moment its page opens (see the src-change effect below,
    // `shouldAutoPlayRef`/`video.muted = true` -- browsers block unmuted
    // autoplay everywhere, so this is the only way a video ever starts on
    // its own). Dispatching purely off play/pause meant BackgroundMusicPlayer
    // ducked down to near-silence the INSTANT any video page loaded, even
    // though the muted video wasn't making any sound yet -- so there was
    // never a perceptible fade-out tied to audio actually starting, and the
    // music sat ducked for as long as a viewer stayed on any video page
    // (reported live as "background music isn't constantly playing" and
    // "doesn't fade out/in"). Worse, unmuting an already-playing video (the
    // normal "tap for sound" flow) only fires `volumechange`, which never
    // touched this event at all -- so ducking never even started when sound
    // actually began, and never reversed when the viewer muted back.
    // `dispatchAudibleState` is the single source of truth now, called from
    // every event that can change either half of "is this video making
    // sound": play/pause/ended AND volumechange.
    const dispatchAudibleState = () => {
      const audible = !video.paused && !video.muted;
      window.dispatchEvent(new CustomEvent("nyxframe:video-playing", { detail: { playing: audible } }));
    };
    const onPlay = () => {
      setPlaying(true);
      setBuffering(false);
      scheduleHide();
      dispatchAudibleState();
      if (navigator.mediaSession) navigator.mediaSession.playbackState = "playing";
      const stats = playbackStatsRef.current;
      if (!stats.hasPlayedOnce) {
        stats.hasPlayedOnce = true;
        if (stats.firstFrameMs === null && stats.loadStartedAt !== null) {
          stats.firstFrameMs = Math.round(performance.now() - stats.loadStartedAt);
        }
      }
    };
    const onPause = () => {
      setPlaying(false);
      setShowControls(true);
      if (controlsHideTimer.current) clearTimeout(controlsHideTimer.current);
      dispatchAudibleState();
      if (navigator.mediaSession) navigator.mediaSession.playbackState = "paused";
      // Pausing is the single strongest signal that a viewer intends to
      // come back to this exact spot, so don't wait for the throttle.
      saveResumePosition(mediaIdRef.current, video.currentTime, durationRef.current);
    };
    const onTimeUpdate = () => {
      setCurrentTime(video.currentTime);
      if (video.buffered.length > 0) setBuffered(video.buffered.end(video.buffered.length - 1));
      // Resume bookkeeping. Throttled hard: `timeupdate` fires ~4x/sec and
      // every save is a JSON parse + stringify + localStorage write, which
      // is a synchronous main-thread operation -- doing that per event
      // would be janking the very playback it's trying to be helpful about.
      const now = performance.now();
      if (now - lastResumeSaveRef.current >= 5000) {
        lastResumeSaveRef.current = now;
        saveResumePosition(mediaIdRef.current, video.currentTime, durationRef.current);
      }
      // Lets the OS's own scrubber (lock screen, macOS Now Playing, a
      // Bluetooth headset display) track real progress rather than sitting
      // at zero. Throws on a non-finite duration or a negative rate, both
      // of which are normal transient states while a stream attaches.
      if (navigator.mediaSession?.setPositionState && Number.isFinite(video.duration) && video.duration > 0) {
        try {
          navigator.mediaSession.setPositionState({
            duration: video.duration,
            playbackRate: video.playbackRate > 0 ? video.playbackRate : 1,
            position: Math.min(video.currentTime, video.duration),
          });
        } catch (_error) { /* transient invalid state -- next tick will retry */ }
      }
    };
    const onDurationChange = () => { const d = video.duration || 0; setDuration(d); durationRef.current = d; };
    const onWaiting = () => {
      setBuffering(true);
      if (bufferingTimerRef.current) clearTimeout(bufferingTimerRef.current);
      bufferingTimerRef.current = setTimeout(() => setBufferingLong(true), 3000);
      const stats = playbackStatsRef.current;
      stats.stallCount += 1;
      if (stats.stallStartedAt === null) stats.stallStartedAt = performance.now();
    };
    const onCanPlay = () => {
      setBuffering(false);
      setBufferingLong(false);
      if (video.playbackRate !== speedRef.current) video.playbackRate = speedRef.current;
      nativeNetworkRetriesRef.current = 0;
      decodeRetriesRef.current = 0;
      if (bufferingTimerRef.current) { clearTimeout(bufferingTimerRef.current); bufferingTimerRef.current = null; }
      const stats = playbackStatsRef.current;
      if (stats.stallStartedAt !== null) {
        stats.stallTotalMs += Math.round(performance.now() - stats.stallStartedAt);
        stats.stallStartedAt = null;
      }
      // Restore seek position after quality switch
      if (pendingRestoreRef.current) {
        const { time, wasPlaying } = pendingRestoreRef.current;
        pendingRestoreRef.current = null;
        if (time > 0) video.currentTime = time;
        if (wasPlaying) attemptAutoplay(video);
        return;
      }
      // Auto-play if the user had previously started playing
      if (shouldAutoPlayRef.current) {
        attemptAutoplay(video);
      }
    };
    const onError = () => {
      const vid = videoRef.current;
      const code = vid?.error?.code;
      if (code === 2) {
        // MEDIA_ERR_NETWORK — on Safari's native HLS path (no hls.js
        // involved) this is what a transient 503 from the still-transcoding
        // HLS playlist route (see routes.lua's serve_hls_playlist) surfaces
        // as. Retry the load with backoff before giving up, same rationale
        // as hls.js's startLoad() recovery in the branch below for the
        // non-Safari path. Capped backoff (not unbounded linear) because a
        // higher-quality rendition (1080p scale+drawtext+libx264) can
        // legitimately take a couple minutes to produce its first segments
        // on a long source -- a handful of retries totaling a few seconds
        // gave up long before that finished.
        if (nativeNetworkRetriesRef.current < 40) {
          nativeNetworkRetriesRef.current += 1;
          setTimeout(() => {
            if (videoRef.current !== vid) return;
            vid.load();
            if (shouldAutoPlayRef.current) vid.play().catch(() => {});
          }, Math.min(500 * nativeNetworkRetriesRef.current, 3000));
          return;
        }
        setError("Network error — check your connection and try again.");
      }
      else if (code === 3 || code === 4) {
        // MEDIA_ERR_DECODE (3) / MEDIA_ERR_SRC_NOT_SUPPORTED (4) — Safari's
        // native HLS path surfaces an unsupported source codec as either,
        // depending on whether it fails at demux or decode. Both mean the
        // same thing here (see pickCompatFallbackQuality above), so both
        // get the same auto-fallback instead of only code 4 recovering
        // while code 3 just showed a dead end.
        //
        // BUT a genuinely unsupported codec fails immediately and
        // consistently from the very first load -- a decode error that
        // shows up mid-playback (a segment truncated by a server hiccup,
        // not a codec the browser has never seen) looks identical here,
        // and auto-downgrading on that read as "the format randomly
        // switches while watching" even though the actual video is fine.
        // One same-quality reload first (mirroring code 2's retry above)
        // separates the two: a real incompatibility fails again
        // immediately and still falls back; a one-off blip just recovers
        // silently.
        if (decodeRetriesRef.current < 1) {
          decodeRetriesRef.current += 1;
          setTimeout(() => {
            if (videoRef.current !== vid) return;
            vid.load();
            if (shouldAutoPlayRef.current) vid.play().catch(() => {});
          }, 400);
          return;
        }
        const fallback = pickCompatFallbackQuality(quality, qualityOptions);
        if (onQualityChange && fallback) {
          setError(`This format isn't supported by your browser. Switching to ${fallback[1] || fallback[0]}…`);
          playbackStatsRef.current.downgradeCount += 1;
          onQualityChange(fallback[0]);
        } else {
          setError("This format isn't supported by your browser. Try switching to a lower quality.");
        }
      } else setError("Playback error — the video could not be loaded.");
    };
    const onEnded = () => {
      setPlaying(false);
      setShowControls(true);
      dispatchAudibleState();
      if (navigator.mediaSession) navigator.mediaSession.playbackState = "paused";
      // Watched to the end: there is nothing left to resume, and leaving a
      // near-the-end entry behind would make the NEXT visit open with a
      // pointless "resumed at 9:52" of a 10:00 video.
      clearResumePosition(mediaIdRef.current);
      // `loop` is handled by the element's own loop attribute and never
      // fires `ended` at all, so this can't fight it.
      if (autoplayNextRef.current && onNextRef.current) onNextRef.current();
    };
    // The "tap for sound" unmute (and re-muting mid-playback) only ever
    // fires this event, never play/pause -- without it here, ducking would
    // never actually start when a viewer's video began making real sound,
    // and never reverse when they muted it again.
    const onVolumeChange = () => { setVolume(video.volume); setMuted(video.muted); dispatchAudibleState(); };
    // `document.fullscreenElement` alone misses both WebKit paths: older
    // Safari's vendor-prefixed document fullscreen, and iPhone's
    // video-element-only fullscreen (webkitEnterFullscreen), which never
    // touches any document-level fullscreen property at all -- see
    // toggleFullscreen for why the iPhone needs that path.
    const onFullscreenChange = () =>
      setFullscreen(Boolean(document.fullscreenElement || document.webkitFullscreenElement));
    const onWebkitBeginFullscreen = () => setFullscreen(true);
    const onWebkitEndFullscreen = () => setFullscreen(false);
    const onPipEnter = () => setPip(true);
    const onPipLeave = () => setPip(false);

    video.addEventListener("play", onPlay);
    video.addEventListener("pause", onPause);
    video.addEventListener("timeupdate", onTimeUpdate);
    video.addEventListener("durationchange", onDurationChange);
    video.addEventListener("waiting", onWaiting);
    video.addEventListener("canplay", onCanPlay);
    video.addEventListener("error", onError);
    video.addEventListener("ended", onEnded);
    video.addEventListener("volumechange", onVolumeChange);
    video.addEventListener("enterpictureinpicture", onPipEnter);
    video.addEventListener("leavepictureinpicture", onPipLeave);
    video.addEventListener("webkitbeginfullscreen", onWebkitBeginFullscreen);
    video.addEventListener("webkitendfullscreen", onWebkitEndFullscreen);
    document.addEventListener("fullscreenchange", onFullscreenChange);
    document.addEventListener("webkitfullscreenchange", onFullscreenChange);

    return () => {
      video.removeEventListener("play", onPlay);
      video.removeEventListener("pause", onPause);
      video.removeEventListener("timeupdate", onTimeUpdate);
      video.removeEventListener("durationchange", onDurationChange);
      video.removeEventListener("waiting", onWaiting);
      video.removeEventListener("canplay", onCanPlay);
      video.removeEventListener("error", onError);
      video.removeEventListener("ended", onEnded);
      video.removeEventListener("volumechange", onVolumeChange);
      video.removeEventListener("enterpictureinpicture", onPipEnter);
      video.removeEventListener("leavepictureinpicture", onPipLeave);
      video.removeEventListener("webkitbeginfullscreen", onWebkitBeginFullscreen);
      video.removeEventListener("webkitendfullscreen", onWebkitEndFullscreen);
      document.removeEventListener("fullscreenchange", onFullscreenChange);
      document.removeEventListener("webkitfullscreenchange", onFullscreenChange);
      clearTimeout(controlsHideTimer.current);
      if (bufferingTimerRef.current) clearTimeout(bufferingTimerRef.current);
      if (singleTapTimerRef.current) clearTimeout(singleTapTimerRef.current);
      // Navigating away mid-playback unmounts this without ever firing
      // "pause"/"ended" -- without this, BackgroundMusicPlayer could stay
      // ducked forever, permanently quiet, since it never sees a matching
      // "false" event. Unconditional now (was gated on `!video.paused`,
      // which missed the actually-common case: a still-playing but MUTED
      // video was never audible in the first place, so there was nothing
      // to un-duck, but sending "false" anyway is a harmless idempotent
      // no-op and removes any chance of this being the one path that
      // still gets the old play-vs-audible distinction wrong).
      window.dispatchEvent(new CustomEvent("nyxframe:video-playing", { detail: { playing: false } }));

      // Navigating away mid-video is the most common way a playback
      // session ends, and the throttled `timeupdate` save can be up to 5
      // seconds stale by then -- flush the exact final position here so
      // "resume" lands where the viewer actually left off.
      saveResumePosition(mediaIdRef.current, video.currentTime, durationRef.current);

      // This effect only mounts/unmounts once for the component's whole
      // lifetime (its dep, scheduleHide, is a stable useCallback with no
      // deps) -- so this cleanup running is a real player teardown, the
      // right (and only) point to report the accumulated session stats.
      const stats = playbackStatsRef.current;
      reportMediaPlaybackDiagnostic({
        mediaId: mediaIdRef.current,
        outcome: stats.fatalError ? "error" : stats.hasPlayedOnce ? "played" : "abandoned",
        quality: qualityRef.current,
        timeToFirstFrameMs: stats.firstFrameMs,
        stallCount: stats.stallCount,
        stallTotalMs: stats.stallTotalMs,
        qualityDowngradeCount: stats.downgradeCount,
        usingHlsJs: stats.usingHlsJs,
      });
    };
  }, [scheduleHide]);

  // On src change: save position/playing state, (re)attach the stream,
  // restore after canplay. `src` now points at a real HLS playlist
  // (master.m3u8 for adaptive, or a specific quality's own playlist.m3u8),
  // not a single progressively-downloaded file — Safari plays that
  // natively via <video src>, but Chrome/Firefox have no built-in HLS
  // support at all, hence hls.js: it demuxes segments into a MediaSource
  // buffer and dispatches the SAME native media events (canplay,
  // durationchange, waiting, timeupdate...) this component already
  // listens for above, so only the *attachment* mechanism differs — the
  // rest of this component doesn't need to know which path is active.
  const hlsRef = useRef(null);
  const prevSrcRef = useRef(src);
  useEffect(() => {
    const video = videoRef.current;
    if (!video || !src) return;
    let cancelled = false;
    setError(null);
    setBufferingLong(false);
    nativeNetworkRetriesRef.current = 0;
    if (bufferingTimerRef.current) { clearTimeout(bufferingTimerRef.current); bufferingTimerRef.current = null; }

    const isQualitySwitch = Boolean(prevSrcRef.current && prevSrcRef.current !== src);
    // Time-to-first-frame only means something for the very first load of a
    // playback session -- a quality switch's own "first frame" is really a
    // seek-restore, already tracked separately by pendingRestoreRef.
    if (!isQualitySwitch) playbackStatsRef.current.loadStartedAt = performance.now();
    let pendingRestore = null;
    if (isQualitySwitch) {
      const savedTime = video.currentTime || 0;
      const wasPlaying = !video.paused;
      if (savedTime > 0 || wasPlaying) pendingRestore = { time: savedTime, wasPlaying };
      // Not the stored resume point -- a quality switch resumes where the
      // viewer is RIGHT NOW, and this is what hls.js's startPosition below
      // reads.
      resumeAtRef.current = savedTime;
      video.pause();
    } else {
      setCurrentTime(0);
      setBuffered(0);
      setPlaying(false);
      // Autoplay the first time this player ever loads a video (not on a
      // quality switch or a same-session sibling nav, both of which take
      // the isQualitySwitch branch above and already carry playing state
      // forward on their own). Previously nothing here ever set
      // shouldAutoPlayRef, so a freshly opened video just sat on its
      // poster frame until the viewer clicked play themselves. Force
      // video.muted directly on the element -- browsers gate autoplay on
      // the element's actual muted property at play() time, not on
      // whatever React state/props say -- the mute button still works
      // normally afterward via toggleMute()/onVolumeChange.
      //
      // Muted UNLESS this viewer has previously unmuted a video on this
      // browser. Starting every video silent is right for a first-time
      // visitor (and is all an autoplay policy will allow them anyway),
      // but for someone who unmutes every single video it meant reaching
      // for the speaker icon on every post forever. When the policy does
      // refuse the unmuted start, attemptAutoplay below falls straight
      // back to muted, so the worst case is exactly the old behaviour.
      const startMuted = getPlayerPref("muted", true) !== false;
      video.muted = startMuted;
      video.volume = getNumericPref("volume", 1, 0, 1);
      setMuted(startMuted);
      shouldAutoPlayRef.current = true;
      // Pick up where this browser left off. Routed through the SAME
      // pendingRestoreRef the quality switcher uses rather than a second
      // mechanism: both want "seek here once the stream is actually
      // playable", and onCanPlay is the only moment where that's true on
      // either engine. hls.js additionally gets `startPosition` below so
      // it fetches the right segments up front instead of downloading the
      // opening of the video and immediately throwing it away.
      const resumeAt = getResumePosition(mediaId);
      resumeAtRef.current = resumeAt;
      if (resumeAt > 0) {
        pendingRestore = { time: resumeAt, wasPlaying: true };
        setResumeNotice({ time: resumeAt });
      } else {
        setResumeNotice(null);
      }
    }
    if (pendingRestore) pendingRestoreRef.current = pendingRestore;
    prevSrcRef.current = src;

    if (hlsRef.current) {
      hlsRef.current.destroy();
      hlsRef.current = null;
    }

    const isHlsSrc = src.includes(".m3u8");
    const hasNativeHls = video.canPlayType("application/vnd.apple.mpegurl") !== "";
    if (isHlsSrc && !hasNativeHls) {
      playbackStatsRef.current.usingHlsJs = true;
      // Deferred so pages with no video playing never pay hls.js's bundle
      // cost — only actually loaded once a real HLS source needs it.
      import("hls.js/light").then(({ default: Hls }) => {
        if (cancelled || !Hls.isSupported() || videoRef.current !== video) return;
        const hls = new Hls({
          enableWorker: true,
          // Start at the resume point instead of segment 0 -- without
          // this, hls.js loads the opening segments, then the seek in
          // onCanPlay throws that buffer away and re-fetches from the
          // real position. On this backend that wasted work isn't just
          // bandwidth: a segment request is what drives (and keeps alive)
          // the server-side transcode, see routes.lua's HLS heartbeat.
          startPosition: resumeAtRef.current > 0 ? resumeAtRef.current : -1,
          // ── Cold-start steering for the "Auto" (master playlist) mode ──
          // ABR was tried here once and reverted, for a good reason that
          // has since stopped being true. The reason: hls.js begins with
          // no bandwidth history, so its default estimate (~500kbps)
          // sits below every rendition except 144p, and first playback
          // of anything landed on 144p. The thing that changed: the
          // media warmer now actually warms the HLS ladder (it used to
          // fill the unrelated _video_cache/ while every _hls_cache/
          // directory stayed cold -- fixed since), so a switch now lands
          // on renditions that are already fully encoded on disk rather
          // than triggering a live transcode mid-playback. 394 warmed
          // variant directories on this host at the time of writing.
          //
          // startLevel 0 pins the FIRST rendition to the one the master
          // lists first, which serve_hls_master deliberately makes
          // "original" (a `-c copy` remux, always the quickest to be
          // ready). ABR then adapts from real measurements instead of
          // from a guess. The seeded estimate is a floor, not a
          // prediction: it stops the very first ABR decision -- made
          // before a single segment has been timed -- from being a panic
          // drop to 144p.
          startLevel: 0,
          abrEwmaDefaultEstimate: 3000000,
          // Defaults are 30s forward / 90s of back-buffer. The forward
          // number is the one that matters here: segments are 6s
          // (hls_time in ensure_hls_variant) and a cold rendition is
          // often being encoded barely ahead of playback off a ~23MB/s
          // USB disk, so 30s of runway is five segments -- one slow fetch
          // from exhausting it. Buffering further ahead converts a stall
          // into a silently absorbed hiccup. Trading that off against
          // back-buffer, trimmed to 30s: keeping a minute and a half of
          // already-watched video in the MediaSource buffer costs real
          // memory on a phone and buys only instant short rewinds.
          maxBufferLength: 90,
          maxMaxBufferLength: 240,
          backBufferLength: 30,
        });
        // The backend's playlist/segment routes 503 with "still starting
        // up" while a quality's HLS variant is mid-transcode (see
        // M.serve_hls_playlist's bounded poll in routes.lua) — that is a
        // routine, expected, retryable condition, not a real failure. Naive
        // "any fatal error -> permanent error banner" handling turned every
        // one of those transient 503s into a broken player, even though
        // hls.js itself ships recovery APIs for exactly this: startLoad()
        // re-kicks the network loader, recoverMediaError() re-attaches on a
        // decode error. Only give up (and show the banner) after repeated
        // recovery attempts for the same error type, capped and backed off
        // so a genuinely dead stream doesn't retry forever.
        // NETWORK_RETRIES is high (with backoff capped, not unbounded
        // linear) because a higher-quality rendition (1080p
        // scale+drawtext+libx264) can legitimately take a couple minutes to
        // produce its first segments on a long source -- 4 retries over ~5s
        // gave up long before a real transcode like that finished.
        let networkRetries = 0;
        let mediaRetries = 0;
        const MAX_NETWORK_RETRIES = 40;
        const MAX_MEDIA_RETRIES = 4;
        hls.on(Hls.Events.ERROR, (_event, data) => {
          if (!data.fatal) return;
          if (data.type === Hls.ErrorTypes.NETWORK_ERROR) {
            if (networkRetries < MAX_NETWORK_RETRIES) {
              networkRetries += 1;
              setTimeout(() => { if (!cancelled) hls.startLoad(); }, Math.min(500 * networkRetries, 3000));
              return;
            }
            setError("Network error — check your connection and try again.");
          } else if (data.type === Hls.ErrorTypes.MEDIA_ERROR) {
            if (mediaRetries < MAX_MEDIA_RETRIES) {
              mediaRetries += 1;
              hls.recoverMediaError();
              return;
            }
            // Exhausted recoverMediaError() retries -- for a genuinely
            // unsupported source codec (common on "original"/no re-encode
            // for an HEVC/ProRes phone upload) those retries were never
            // going to succeed, so fall back the same way the native-HLS
            // Safari path does instead of leaving a dead player behind.
            const fallback = pickCompatFallbackQuality(quality, qualityOptions);
            if (onQualityChange && fallback) {
              setError(`This format isn't supported by your browser. Switching to ${fallback[1] || fallback[0]}…`);
              playbackStatsRef.current.downgradeCount += 1;
              onQualityChange(fallback[0]);
            } else {
              setError("Decoding error — the video format may not be supported.");
            }
          } else {
            setError("Playback error — the video could not be loaded.");
          }
        });
        hls.on(Hls.Events.MANIFEST_PARSED, () => { networkRetries = 0; mediaRetries = 0; });
        hls.loadSource(src);
        hls.attachMedia(video);
        hlsRef.current = hls;
      });
    } else {
      video.src = src;
      video.load();
    }

    return () => { cancelled = true; };
  }, [src]);

  useEffect(() => () => { if (hlsRef.current) hlsRef.current.destroy(); }, []);

  // A persisted playback speed has to be pushed onto the element itself.
  // This effect covers a live change from the menu; the re-apply in
  // onCanPlay covers a new source, because attaching one resets the
  // element's rate to 1 -- and on the hls.js path that attach happens
  // asynchronously, after the dynamic import resolves, i.e. well after
  // this effect has already run for the new src. Confirmed live: without
  // the onCanPlay half, a saved 1.5x silently came back as 1x.
  useEffect(() => {
    const video = videoRef.current;
    if (video) video.playbackRate = speed;
  }, [speed, src]);

  // Probed once the ref exists rather than at render time: the WebKit PiP
  // API is a method on the <video> element, not a document property.
  useEffect(() => {
    const video = videoRef.current;
    const webkitPip =
      video &&
      typeof video.webkitSetPresentationMode === "function" &&
      (typeof video.webkitSupportsPresentationMode !== "function" ||
        video.webkitSupportsPresentationMode("picture-in-picture"));
    setPipSupported(Boolean(document.pictureInPictureEnabled || webkitPip));
    // Adaptive bitrate rides on hls.js, which is only used where the
    // browser has no HLS engine of its own -- the same condition the
    // attach effect below tests.
    setAbrAvailable(Boolean(video) && video.canPlayType("application/vnd.apple.mpegurl") === "");
  }, []);

  // ─── OS media integration (lock screen, media keys, headset buttons) ──────
  // Without this, a keyboard's play/pause key, a headset's pinch, the iOS
  // lock screen and macOS's Now Playing widget all either do nothing or
  // (worse) control some unrelated tab. Registering metadata + handlers
  // also makes this player the thing those surfaces name and show artwork
  // for, which matters here because the site's own BackgroundMusicPlayer
  // is otherwise the only audio the OS knows about.
  useEffect(() => {
    const session = navigator.mediaSession;
    if (!session) return undefined;
    if (typeof window.MediaMetadata === "function") {
      try {
        session.metadata = new window.MediaMetadata({
          title: title || "Nyxframe video",
          artist: author || "Nyxframe",
          artwork: poster ? [{ src: poster, sizes: "512x512", type: "image/jpeg" }] : [],
        });
      } catch (_error) { /* metadata is decoration -- never block playback for it */ }
    }
    const seekBy = (offset) => {
      const video = videoRef.current;
      if (!video) return;
      const total = durationRef.current || video.duration || 0;
      video.currentTime = clamp(video.currentTime + offset, 0, total);
    };
    const handlers = {
      play: () => { shouldAutoPlayRef.current = true; videoRef.current?.play().catch(() => {}); },
      pause: () => videoRef.current?.pause(),
      seekbackward: (details) => seekBy(-(details?.seekOffset || 10)),
      seekforward: (details) => seekBy(details?.seekOffset || 10),
      seekto: (details) => {
        const video = videoRef.current;
        if (!video || !Number.isFinite(details?.seekTime)) return;
        if (details.fastSeek && typeof video.fastSeek === "function") video.fastSeek(details.seekTime);
        else video.currentTime = details.seekTime;
      },
      // Passing null is what REMOVES a button from the OS surface, so a
      // post with no siblings correctly shows no skip controls instead of
      // dead ones.
      previoustrack: onPrevious || null,
      nexttrack: onNext || null,
    };
    for (const [action, handler] of Object.entries(handlers)) {
      // An unsupported action throws TypeError rather than being ignored,
      // and which ones exist varies by browser/version.
      try { session.setActionHandler(action, handler); } catch (_error) { /* unsupported here */ }
    }
    return () => {
      for (const action of Object.keys(handlers)) {
        try { session.setActionHandler(action, null); } catch (_error) { /* unsupported here */ }
      }
      session.playbackState = "none";
      session.metadata = null;
    };
  }, [author, onNext, onPrevious, poster, title]);

  // ─── Stats overlay sampling ───────────────────────────────────────────────
  // Only polls while the overlay is actually open -- this is a diagnostic
  // surface, and getVideoPlaybackQuality()/bandwidthEstimate on a 1s timer
  // shouldn't run for every viewer who never opens it.
  useEffect(() => {
    if (!showStats) { setStats(null); return undefined; }
    const sample = () => {
      const video = videoRef.current;
      if (!video) return;
      const quality = typeof video.getVideoPlaybackQuality === "function" ? video.getVideoPlaybackQuality() : null;
      const bufferedEnd = video.buffered.length > 0 ? video.buffered.end(video.buffered.length - 1) : 0;
      const hls = hlsRef.current;
      const level = hls && Array.isArray(hls.levels) ? hls.levels[hls.currentLevel] : null;
      const session = playbackStatsRef.current;
      setStats({
        resolution: video.videoWidth ? `${video.videoWidth}×${video.videoHeight}` : "—",
        bufferAhead: Math.max(0, bufferedEnd - video.currentTime),
        dropped: quality ? quality.droppedVideoFrames : null,
        totalFrames: quality ? quality.totalVideoFrames : null,
        estimateKbps: hls && hls.bandwidthEstimate ? Math.round(hls.bandwidthEstimate / 1000) : null,
        // Only meaningful on a multi-rendition master playlist. A single
        // per-quality playlist (what this player normally loads, see
        // utils/media.js videoQualityUrl) carries no RESOLUTION/BANDWIDTH
        // attributes at all, and printing the resulting "0p · 0 kbps" was
        // worse than printing nothing.
        levelLabel: level && level.height ? `${level.height}p · ${Math.round((level.bitrate || 0) / 1000)} kbps` : null,
        engine: hls ? "hls.js + MSE" : "native",
        firstFrameMs: session.firstFrameMs,
        stallCount: session.stallCount,
        stallTotalMs: session.stallTotalMs,
      });
    };
    sample();
    const timer = setInterval(sample, 1000);
    return () => clearInterval(timer);
  }, [showStats]);

  // Both of these are transient affordances that shouldn't need a click to
  // get rid of.
  useEffect(() => {
    if (!seekFlash) return undefined;
    const timer = setTimeout(() => setSeekFlash(null), 520);
    return () => clearTimeout(timer);
  }, [seekFlash]);

  // ─── Optional per-video extras: seek sprites and captions ────────────────
  // One endpoint reports both and starts whichever hasn't been generated
  // yet (see lua/src/video_extras.lua). Both are built from an
  // already-warm transcoded rendition, so "pending" usually resolves in
  // seconds -- polled with a widening gap, and given up on rather than
  // retried forever, because neither feature existing is a normal state
  // for plenty of videos (a clip with no speech genuinely has no
  // captions).
  useEffect(() => {
    if (!mediaId) return undefined;
    let cancelled = false;
    let timer = null;
    setSprite(null);
    setCaptions(null);
    let attempt = 0;
    const poll = async () => {
      attempt += 1;
      let data = null;
      try {
        data = await apiFetch(`/api/media/${mediaId}/playback-extras${accessQuery(src)}`);
      } catch (_error) {
        return; // Extras are optional; a failure here changes nothing about playback.
      }
      if (cancelled) return;
      if (data?.sprite?.status === "ready" && data.sprite.vtt_url && data.sprite.sheet_url) {
        try {
          // apiFetch, not fetch: it attaches the bearer token and returns
          // the body as text for a non-JSON content type, so this works
          // for a private post the same way the media itself does.
          const text = await apiFetch(data.sprite.vtt_url);
          // The SHEET is loaded by the browser as an image, which can
          // carry no Authorization header -- it relies on the ?access=
          // capability token the backend propagates onto these URLs,
          // exactly like the HLS playlists and segments already do.
          if (!cancelled) setSprite(parseSpriteVtt(text, apiUrl(data.sprite.sheet_url)));
        } catch (_error) { /* keep the plain time tooltip */ }
      }
      if (data?.captions?.status === "ready" && data.captions.vtt_url) {
        if (!cancelled) {
          setCaptions({
            url: data.captions.vtt_url,
            language: data.captions.language || "en",
            autoGenerated: Boolean(data.captions.auto_generated),
          });
        }
      }
      const stillPending = data?.sprite?.status === "pending" || data?.captions?.status === "pending";
      if (stillPending && attempt < 6 && !cancelled) {
        timer = setTimeout(poll, 2000 * attempt);
      }
    };
    poll();
    return () => { cancelled = true; if (timer) clearTimeout(timer); };
    // src only participates as the carrier of the ?access= token, which
    // doesn't change for a given mediaId.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mediaId]);

  // Captions are fetched and turned into cues by hand rather than being
  // hung off the element as a <track src>: see utils/vtt.js for why a
  // cross-origin <track> would have meant putting the whole video element
  // into CORS mode. addTextTrack gives the same native rendering (and the
  // same OS-level caption styling a viewer has configured) without that.
  const captionTrackRef = useRef(null);
  useEffect(() => {
    const video = videoRef.current;
    if (!video || !captions) return undefined;
    let cancelled = false;
    (async () => {
      let cues = [];
      try {
        cues = parseVtt(await apiFetch(captions.url));
      } catch (_error) {
        return;
      }
      if (cancelled || !cues.length || typeof window.VTTCue !== "function") return;
      const track = video.addTextTrack("captions", captions.autoGenerated ? "English (auto)" : "English", captions.language);
      for (const cue of cues) {
        try { track.addCue(new window.VTTCue(cue.start, cue.end, cue.text)); } catch (_error) { /* skip a bad cue */ }
      }
      captionTrackRef.current = track;
      track.mode = captionsOn ? "showing" : "hidden";
    })();
    return () => {
      cancelled = true;
      // A TextTrack added with addTextTrack can't be removed, only
      // silenced -- which is fine, because this only runs when the whole
      // player is going away or switching to a different video's track.
      if (captionTrackRef.current) captionTrackRef.current.mode = "disabled";
      captionTrackRef.current = null;
    };
    // captionsOn is applied by the effect below, not by re-fetching here.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [captions]);

  useEffect(() => {
    if (captionTrackRef.current) captionTrackRef.current.mode = captionsOn ? "showing" : "hidden";
  }, [captionsOn]);

  useEffect(() => {
    if (!resumeNotice) return undefined;
    const timer = setTimeout(() => setResumeNotice(null), 8000);
    return () => clearTimeout(timer);
  }, [resumeNotice]);

  // Sync loop attribute on video element when state changes
  useEffect(() => {
    const video = videoRef.current;
    if (video) video.loop = loop;
  }, [loop]);

  // Document-level mouseup to cancel drag-seek
  useEffect(() => {
    if (!seeking) return;
    const up = () => setSeeking(false);
    document.addEventListener("mouseup", up);
    document.addEventListener("touchend", up, { passive: true });
    return () => {
      document.removeEventListener("mouseup", up);
      document.removeEventListener("touchend", up);
    };
  }, [seeking]);

  // Touch seek — attached as non-passive so preventDefault() works on iOS Safari.
  // Uses refs (videoRef, seekBarRef, durationRef) to avoid stale closures since
  // the effect only re-runs when revealControls changes (which is stable).
  useEffect(() => {
    const bar = seekBarRef.current;
    if (!bar) return;
    const getTouchFraction = (e) => {
      const touch = e.touches[0];
      if (!touch) return null;
      const rect = bar.getBoundingClientRect();
      return clamp((touch.clientX - rect.left) / rect.width, 0, 1);
    };
    const applySeek = (fraction) => {
      const video = videoRef.current;
      const dur = durationRef.current;
      if (!video || !dur || fraction === null) return;
      video.currentTime = clamp(fraction * dur, 0, dur);
    };
    const onTouchStart = (e) => {
      e.preventDefault();
      setSeeking(true);
      applySeek(getTouchFraction(e));
      revealControls();
    };
    const onTouchMove = (e) => {
      e.preventDefault();
      applySeek(getTouchFraction(e));
    };
    bar.addEventListener("touchstart", onTouchStart, { passive: false });
    bar.addEventListener("touchmove", onTouchMove, { passive: false });
    return () => {
      bar.removeEventListener("touchstart", onTouchStart);
      bar.removeEventListener("touchmove", onTouchMove);
    };
  }, [revealControls]);

  // ─── Playback controls ───────────────────────────────────────────────────────
  function togglePlay() {
    const video = videoRef.current;
    if (!video || error) return;
    if (video.paused) {
      shouldAutoPlayRef.current = true;
      // If hls.js hasn't attached/buffered anything yet (readyState 0-2,
      // e.g. the click landed before the dynamic `import("hls.js")` even
      // resolved, or while a cold quality is still transcoding
      // server-side), video.play() silently no-ops -- no `waiting` event
      // fires because playback never actually started, so `buffering`
      // never turns on and the big Play button just sits there unchanged.
      // That looked like the click didn't register at all, and the fix
      // for "I have to hit play again" was users doing exactly that.
      // Surface the same spinner immediately instead of waiting on a
      // native event that isn't coming; onCanPlay/onPlaying clear it once
      // real playback starts (same as the `waiting` path already did).
      if (video.readyState < 3) {
        setBuffering(true);
        if (bufferingTimerRef.current) clearTimeout(bufferingTimerRef.current);
        bufferingTimerRef.current = setTimeout(() => setBufferingLong(true), 3000);
      }
      video.play().catch(() => {});
    } else {
      video.pause();
    }
  }

  function seek(fraction) {
    const video = videoRef.current;
    if (!video || !duration) return;
    video.currentTime = clamp(fraction * duration, 0, duration);
  }

  function nudge(seconds) {
    const video = videoRef.current;
    if (!video || !duration) return;
    video.currentTime = clamp(video.currentTime + seconds, 0, duration);
  }

  // Persisted from the gesture handlers, NOT from the `volumechange`
  // listener: that event also fires for the forced `video.muted = true`
  // every autoplay does (browser policy, see the src effect), and
  // persisting from there would overwrite the viewer's real choice with
  // "muted" on every single page load.
  function toggleMute() {
    const video = videoRef.current;
    if (!video) return;
    video.muted = !video.muted;
    setPlayerPref("muted", video.muted);
  }

  function changeVolume(fraction) {
    const video = videoRef.current;
    if (!video) return;
    const v = clamp(fraction, 0, 1);
    video.volume = v;
    video.muted = v === 0;
    setPlayerPref("volume", v);
    setPlayerPref("muted", video.muted);
  }

  function setPlaybackSpeed(s) {
    const video = videoRef.current;
    if (video) video.playbackRate = s;
    setSpeed(s);
    setPlayerPref("speed", s);
    setShowSpeedMenu(false);
  }

  // Shift+. / Shift+, walk the same discrete ladder the speed menu offers,
  // rather than inventing a second set of rates the UI can't display.
  function stepSpeed(direction) {
    const index = SPEEDS.indexOf(speed);
    const next = SPEEDS[clamp((index < 0 ? SPEEDS.indexOf(1) : index) + direction, 0, SPEEDS.length - 1)];
    setPlaybackSpeed(next);
    revealControls();
  }

  function toggleAutoplayNext() {
    setAutoplayNext((value) => {
      setPlayerPref("autoplayNext", !value);
      return !value;
    });
  }

  // iPhone Safari implements NONE of the standard Fullscreen API on
  // ordinary elements -- `container.requestFullscreen` is simply undefined
  // there, so this button used to throw (and then do nothing at all) on
  // every iPhone. The only fullscreen an iPhone offers is the <video>
  // element's own `webkitEnterFullscreen`, which hands playback to the
  // system player chrome rather than ours; that's a worse experience than
  // our own controls, but it is dramatically better than a dead button,
  // and it's exactly what every other iPhone video site falls back to.
  // Desktop Safari does support element fullscreen, but only under the
  // webkit- prefix on older versions, hence the middle branch.
  function toggleFullscreen() {
    const container = containerRef.current;
    const video = videoRef.current;
    if (document.fullscreenElement || document.webkitFullscreenElement) {
      if (document.exitFullscreen) document.exitFullscreen().catch(() => {});
      else if (document.webkitExitFullscreen) document.webkitExitFullscreen();
      return;
    }
    if (video?.webkitDisplayingFullscreen && video.webkitExitFullscreen) {
      video.webkitExitFullscreen();
      return;
    }
    if (container?.requestFullscreen) {
      container.requestFullscreen().catch(() => {});
    } else if (container?.webkitRequestFullscreen) {
      container.webkitRequestFullscreen();
    } else if (video?.webkitEnterFullscreen) {
      video.webkitEnterFullscreen();
    } else {
      setError("Fullscreen isn't supported in this browser.");
    }
  }

  function togglePip() {
    const video = videoRef.current;
    if (!video) return;
    // Safari (desktop AND iPad) ships PiP through
    // webkitSetPresentationMode, not the standard API -- checking only
    // `document.pictureInPictureEnabled` is why the button never appeared
    // there at all, even though PiP works fine.
    if (!document.pictureInPictureEnabled && typeof video.webkitSetPresentationMode === "function") {
      const mode = video.webkitPresentationMode === "picture-in-picture" ? "inline" : "picture-in-picture";
      try {
        video.webkitSetPresentationMode(mode);
        setPip(mode === "picture-in-picture");
      } catch (err) {
        setError(`Couldn't start Picture in Picture: ${err?.message || "try again in a moment."}`);
      }
      return;
    }
    if (document.pictureInPictureElement) {
      document.exitPictureInPicture().catch(() => {});
    } else {
      // A rejection here (readyState too low, a disallowed cross-origin
      // source, another tab already holding the one system-wide PiP
      // window, ...) previously vanished into a swallowed .catch(() =>
      // {}) -- the button just did nothing with no indication why.
      video.requestPictureInPicture().catch((err) => {
        setError(`Couldn't start Picture in Picture: ${err?.message || "try again in a moment."}`);
      });
    }
  }

  function retry() {
    const video = videoRef.current;
    if (!video) return;
    setError(null);
    shouldAutoPlayRef.current = true;
    video.load();
    video.play().catch(() => {});
  }

  // ─── Double-tap to seek (touch) ─────────────────────────────────────────────
  // The desktop player has ±10s buttons, but on a phone those live in a
  // control bar that auto-hides after 2.5s, so scrubbing back a few
  // seconds meant tap-to-reveal, then aim at a small button. Double-tap on
  // the left/right half is the gesture every mobile video app has trained
  // people to expect.
  //
  // Two things here are load-bearing, both found by driving a real touch
  // emulation rather than by reading the code:
  //
  //  1. preventDefault() on EVERY touchend, not just the second one. A
  //     touchend the browser doesn't have cancelled is followed by a
  //     synthetic click, and the video's own onClick toggles play -- so
  //     the first tap of a double-tap paused the video before the second
  //     tap ever arrived.
  //  2. Because of (1) the single-tap play toggle has to be re-issued
  //     here, and DEFERRED: committing it immediately is what made the
  //     pause fire, and pausing force-reveals the control bar (onPause),
  //     which then sits under the viewer's finger -- the measured result
  //     was the second tap landing on the SEEK BAR and jumping to 80% of
  //     the video instead of forward ten seconds. Holding the toggle for
  //     one double-tap window keeps the layout still between the two
  //     taps. This is the same deferral every mobile video player uses,
  //     and the ~300ms of play/pause latency it costs is only paid on
  //     touch.
  function onVideoTouchEnd(event) {
    const touch = event.changedTouches && event.changedTouches[0];
    const video = videoRef.current;
    if (!touch || !video) return;
    event.preventDefault();
    containerRef.current?.focus({ preventScroll: true });
    const rect = video.getBoundingClientRect();
    const side = touch.clientX - rect.left < rect.width / 2 ? -1 : 1;
    const now = Date.now();
    const previous = lastTapRef.current;
    if (now - previous.t < DOUBLE_TAP_MS && previous.side === side) {
      if (singleTapTimerRef.current) { clearTimeout(singleTapTimerRef.current); singleTapTimerRef.current = null; }
      lastTapRef.current = { t: 0, side: 0 };
      nudge(side * 10);
      setSeekFlash({ dir: side, key: now });
      revealControls();
      return;
    }
    lastTapRef.current = { t: now, side };
    if (singleTapTimerRef.current) clearTimeout(singleTapTimerRef.current);
    singleTapTimerRef.current = setTimeout(() => {
      singleTapTimerRef.current = null;
      togglePlay();
    }, DOUBLE_TAP_MS);
  }

  // ─── Seek bar interaction ────────────────────────────────────────────────────
  function seekBarFraction(clientX) {
    const bar = seekBarRef.current;
    if (!bar) return 0;
    const rect = bar.getBoundingClientRect();
    return clamp((clientX - rect.left) / rect.width, 0, 1);
  }

  function onSeekMouseDown(event) {
    setSeeking(true);
    seek(seekBarFraction(event.clientX));
    revealControls();
  }

  function onSeekMouseMove(event) {
    const bar = seekBarRef.current;
    if (!bar) return;
    const rect = bar.getBoundingClientRect();
    const fraction = clamp((event.clientX - rect.left) / rect.width, 0, 1);
    setSeekHover({ x: event.clientX - rect.left, time: fraction * duration });
    if (seeking) seek(fraction);
  }

  function onSeekMouseUp() {
    setSeeking(false);
  }

  // ─── Volume bar interaction ──────────────────────────────────────────────────
  function volumeBarFraction(event) {
    const bar = volumeBarRef.current;
    if (!bar) return 1;
    const rect = bar.getBoundingClientRect();
    return clamp((event.clientX - rect.left) / rect.width, 0, 1);
  }

  // ─── Keyboard shortcuts ──────────────────────────────────────────────────────
  // Use a ref to always see fresh volume so the effect never needs to re-run
  const volumeRef = useRef(volume);
  volumeRef.current = volume;

  useEffect(() => {
    function onKey(event) {
      const container = containerRef.current;
      if (!container) return;
      const target = event.target;
      if (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.tagName === "SELECT" || target.isContentEditable) return;
      // Was: `|| document.activeElement === document.body`, i.e. any page
      // containing a player swallowed Space, the arrow keys and every
      // digit for the WHOLE document as long as nothing else held focus.
      // On a media page that meant Space couldn't scroll the comments and
      // the left/right keys couldn't reach the sibling-navigation the
      // detail page binds -- for a player the viewer might never have
      // touched. Now the player has to actually be the thing you're
      // pointed at: hovered, or holding focus (the container is
      // focusable and takes focus on click, see onPlayerClick).
      if (!pointerInsideRef.current && !container.contains(document.activeElement)) return;
      // Let the browser's own accelerators through untouched.
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      if (event.shiftKey) {
        // Sibling navigation, shifted so it can't collide with the
        // unshifted single-letter shortcuts below.
        if (event.code === "KeyN" && onNext) { event.preventDefault(); onNext(); return; }
        if (event.code === "KeyP" && onPrevious) { event.preventDefault(); onPrevious(); return; }
        if (event.code === "Period") { event.preventDefault(); stepSpeed(1); return; }
        if (event.code === "Comma") { event.preventDefault(); stepSpeed(-1); return; }
        return;
      }
      switch (event.code) {
        case "Space": event.preventDefault(); togglePlay(); break;
        case "ArrowLeft": event.preventDefault(); nudge(-10); revealControls(); break;
        case "ArrowRight": event.preventDefault(); nudge(10); revealControls(); break;
        case "ArrowUp": event.preventDefault(); changeVolume(volumeRef.current + 0.1); revealControls(); break;
        case "ArrowDown": event.preventDefault(); changeVolume(volumeRef.current - 0.1); revealControls(); break;
        case "KeyM": toggleMute(); break;
        case "KeyF": toggleFullscreen(); break;
        case "KeyP": togglePip(); break;
        case "KeyL": setLoop((v) => !v); break;
        case "KeyI": setShowStats((v) => !v); break;
        // Frame stepping while paused -- the conventional , / . pair.
        // Approximated at 1/30s since the element exposes no frame rate;
        // exact enough to walk through a moment of motion.
        case "Comma": event.preventDefault(); nudge(-1 / 30); revealControls(); break;
        case "Period": event.preventDefault(); nudge(1 / 30); revealControls(); break;
        case "Home": event.preventDefault(); seek(0); revealControls(); break;
        case "End": event.preventDefault(); seek(0.95); revealControls(); break;
        default: {
          // 0–9 keys: seek to 0%–90%
          if (event.key >= "0" && event.key <= "9") {
            event.preventDefault();
            seek(Number(event.key) / 10);
            revealControls();
          }
          break;
        }
      }
    }
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
    // onNext/onPrevious/speed are read directly by the handler above, so
    // the listener has to be re-bound when they change -- otherwise
    // Shift+N would keep calling the first render's navigation callback.
  }, [revealControls, onNext, onPrevious, speed]);

  // "Auto" (real adaptive bitrate off the master playlist) is offered
  // only where hls.js is driving, because only there can the starting
  // rendition be pinned -- see the `startLevel` note in the attach
  // effect. Safari's native engine picks its own first level from a
  // bandwidth estimate it doesn't have yet on a cold connection, which is
  // exactly the failure that got ABR reverted the first time round, so it
  // keeps the explicit ladder.
  const visibleQualityOptions = (qualityOptions || []).filter(([value]) => value !== "auto" || abrAvailable);

  const progressPct = duration > 0 ? (currentTime / duration) * 100 : 0;
  const bufferedPct = duration > 0 ? (buffered / duration) * 100 : 0;
  const volumePct = muted ? 0 : volume * 100;
  const VolumeIcon = muted || volume === 0 ? VolumeX : volume < 0.5 ? Volume1 : Volume2;

  return (
    <div
      ref={containerRef}
      className={`vp-root${fullscreen ? " vp-fullscreen" : ""}${!showControls && playing ? " vp-controls-hidden" : ""}`}
      onMouseMove={revealControls}
      onMouseEnter={() => { pointerInsideRef.current = true; }}
      onMouseLeave={() => { pointerInsideRef.current = false; if (playing) setShowControls(false); }}
      onClick={(e) => {
        // Take focus on click so the keyboard shortcuts keep working once
        // the pointer leaves -- the keydown handler deliberately requires
        // hover OR focus now (see its comment), and a bare <div> never
        // receives focus from a click on its own.
        containerRef.current?.focus({ preventScroll: true });
        if (e.target === containerRef.current || e.target === videoRef.current) togglePlay();
      }}
      tabIndex={0}
      role="region"
      aria-label={title ? `Video player: ${title}` : "Video player"}
    >
      {/* Video element */}
      <video
        ref={videoRef}
        className="vp-video"
        poster={poster}
        playsInline
        preload="metadata"
        onClick={(e) => { e.stopPropagation(); containerRef.current?.focus({ preventScroll: true }); togglePlay(); }}
        onDoubleClick={toggleFullscreen}
        onTouchEnd={onVideoTouchEnd}
      />

      {/* Double-tap-to-seek feedback */}
      {seekFlash && (
        <div className={`vp-seek-flash${seekFlash.dir < 0 ? " vp-seek-flash-left" : " vp-seek-flash-right"}`} key={seekFlash.key} aria-hidden="true">
          {seekFlash.dir < 0 ? <SkipBack size={26} /> : <SkipForward size={26} />}
          <span>10s</span>
        </div>
      )}

      {/* Site watermark -- pointer-events:none so it never steals a click
          from the video underneath it, and stays up through fullscreen
          (same brand mark used in the topbar) since that's the point of a
          player watermark: it should still read as this site's player
          when a clip is captured, shared, or seen out of context. */}
      <div className="vp-watermark" aria-hidden="true">
        <span className="vp-watermark-mark"><ImageIcon size={12} /></span>
        <span>Nyxframe</span>
      </div>

      {/* Buffering spinner */}
      {buffering && !error && (
        <div className="vp-spinner-wrap" aria-label={bufferingLong ? "Transcoding" : "Buffering"}>
          <div className="vp-spinner" />
          {bufferingLong && (
            <div className="vp-transcoding-msg">
              <Loader2 size={14} className="vp-transcoding-spin" />
              Transcoding&hellip; this may take a moment
            </div>
          )}
        </div>
      )}

      {/* Error overlay */}
      {error && (
        <div className="vp-error">
          <AlertCircle size={36} />
          <p>{error}</p>
          <button type="button" className="vp-retry-btn" onClick={retry}>
            <RefreshCw size={16} /> Retry
          </button>
        </div>
      )}

      {/* Big centre play icon (shows briefly on pause) */}
      {!playing && !error && !buffering && currentTime === 0 && (
        <button type="button" className="vp-big-play" onClick={togglePlay} aria-label="Play">
          <Play size={48} />
        </button>
      )}

      {/* Autoplay always starts muted (browser policy) -- this is the
          affordance that tells the viewer sound is available and one tap
          away, since a silently-muted video with no indicator reads as
          broken rather than intentional. */}
      {playing && muted && !error && (
        <button type="button" className="vp-sound-hint" onClick={(e) => { e.stopPropagation(); toggleMute(); }} aria-label="Unmute">
          <VolumeX size={15} /> Tap for sound
        </button>
      )}

      {/* Picked-up-where-you-left-off affordance. Auto-resuming silently
          is disorienting ("why is this starting in the middle?"), and a
          blocking "Resume?" prompt in front of the video is worse -- this
          resumes immediately and offers one tap to undo it. */}
      {resumeNotice && !error && (
        <div className="vp-resume-chip">
          <span>Resumed from {formatTime(resumeNotice.time)}</span>
          <button
            type="button"
            onClick={(e) => {
              e.stopPropagation();
              setResumeNotice(null);
              clearResumePosition(mediaId);
              const video = videoRef.current;
              if (video) { video.currentTime = 0; video.play().catch(() => {}); }
            }}
          >
            <RotateCcw size={13} /> Start over
          </button>
        </div>
      )}

      {/* Playback stats ("i") -- the same numbers the playback telemetry
          beacon reports on teardown, made visible while diagnosing a
          stuttering stream instead of only readable in the database
          afterwards. */}
      {showStats && stats && (
        <div className="vp-stats" onClick={(e) => e.stopPropagation()}>
          <div className="vp-stats-head">
            <Activity size={13} /> Playback stats
            <button type="button" onClick={() => setShowStats(false)} aria-label="Close stats">×</button>
          </div>
          <dl>
            <dt>Engine</dt><dd>{stats.engine}</dd>
            <dt>Resolution</dt><dd>{stats.resolution}</dd>
            {stats.levelLabel ? (<><dt>Rendition</dt><dd>{stats.levelLabel}</dd></>) : null}
            {stats.estimateKbps ? (<><dt>Bandwidth est.</dt><dd>{stats.estimateKbps} kbps</dd></>) : null}
            <dt>Buffer ahead</dt><dd>{stats.bufferAhead.toFixed(1)}s</dd>
            {stats.dropped !== null ? (<><dt>Dropped frames</dt><dd>{stats.dropped} / {stats.totalFrames}</dd></>) : null}
            <dt>First frame</dt><dd>{stats.firstFrameMs === null ? "—" : `${stats.firstFrameMs} ms`}</dd>
            <dt>Stalls</dt><dd>{stats.stallCount} ({(stats.stallTotalMs / 1000).toFixed(1)}s)</dd>
          </dl>
        </div>
      )}

      {/* Controls overlay */}
      <div className="vp-controls" onClick={(e) => e.stopPropagation()}>
        {/* Seek bar */}
        <div className="vp-seek-wrap">
          {seekHover && duration > 0 && (() => {
            // A thumbnail needs more room than a timestamp, so the
            // tooltip's clamp has to widen with it -- otherwise the
            // preview for the first few seconds of a video hangs off the
            // left edge of the player.
            const tile = sprite ? spriteTileAt(sprite, seekHover.time) : null;
            const halfWidth = tile ? tile.width / 2 : 28;
            return (
              <div
                className={`vp-seek-tooltip${tile ? " vp-seek-tooltip-thumb" : ""}`}
                style={{ left: `${clamp(seekHover.x, halfWidth, 9999)}px` }}
              >
                {tile && (
                  <span
                    className="vp-seek-thumb-img"
                    style={{
                      width: `${tile.width}px`,
                      height: `${tile.height}px`,
                      backgroundImage: `url("${sprite.sheetUrl}")`,
                      backgroundPosition: `-${tile.x}px -${tile.y}px`,
                    }}
                  />
                )}
                <span className="vp-seek-tooltip-time">{formatTime(seekHover.time)}</span>
              </div>
            );
          })()}
          <div
            ref={seekBarRef}
            className="vp-seek-bar"
            role="slider"
            aria-label="Seek"
            aria-valuemin={0}
            aria-valuemax={100}
            aria-valuenow={Math.round(progressPct)}
            onMouseDown={onSeekMouseDown}
            onMouseMove={onSeekMouseMove}
            onMouseUp={onSeekMouseUp}
            onMouseLeave={() => setSeekHover(null)}
          >
            <div className="vp-seek-track">
              <div className="vp-seek-buffered" style={{ width: `${bufferedPct}%` }} />
              <div className="vp-seek-played" style={{ width: `${progressPct}%` }}>
                <div className="vp-seek-thumb" />
              </div>
            </div>
          </div>
        </div>

        {/* Bottom controls row */}
        <div className="vp-bottom">
          {/* Left cluster */}
          <div className="vp-cluster">
            <button type="button" className="vp-btn" onClick={() => nudge(-10)} title="Back 10s" aria-label="Seek back 10 seconds">
              <SkipBack size={18} />
            </button>
            <button type="button" className="vp-btn vp-play-btn" onClick={togglePlay} aria-label={playing ? "Pause" : "Play"}>
              {playing ? <Pause size={22} /> : <Play size={22} />}
            </button>
            <button type="button" className="vp-btn" onClick={() => nudge(10)} title="Forward 10s" aria-label="Seek forward 10 seconds">
              <SkipForward size={18} />
            </button>

            {/* Volume */}
            <div className="vp-volume-group">
              <button type="button" className="vp-btn" onClick={toggleMute} aria-label={muted ? "Unmute" : "Mute"}>
                <VolumeIcon size={18} />
              </button>
              <div
                ref={volumeBarRef}
                className="vp-volume-bar"
                role="slider"
                aria-label="Volume"
                aria-valuemin={0}
                aria-valuemax={100}
                aria-valuenow={Math.round(volumePct)}
                onClick={(e) => changeVolume(volumeBarFraction(e))}
              >
                <div className="vp-volume-track">
                  <div className="vp-volume-filled" style={{ width: `${volumePct}%` }} />
                  <div className="vp-volume-thumb" style={{ left: `${volumePct}%` }} />
                </div>
              </div>
            </div>

            {/* Time */}
            <span
              className="vp-time"
              onClick={() => setShowRemaining((v) => !v)}
              style={{ cursor: "pointer" }}
              title={showRemaining ? "Show elapsed time" : "Show remaining time"}
            >
              {showRemaining && duration > 0
                ? `-${formatTime(Math.max(0, duration - currentTime))} / ${formatTime(duration)}`
                : `${formatTime(currentTime)} / ${formatTime(duration)}`}
            </span>
          </div>

          {/* Right cluster */}
          <div className="vp-cluster">
            {/* Loop */}
            <button
              type="button"
              className={`vp-btn${loop ? " active" : ""}`}
              onClick={() => setLoop((v) => !v)}
              title="Loop"
              aria-label="Loop video"
            >
              <Repeat size={18} />
            </button>

            {/* Speed */}
            <div className="vp-menu-wrap">
              <button
                type="button"
                className={`vp-btn vp-speed-btn${showSpeedMenu ? " active" : ""}`}
                onClick={() => { setShowSpeedMenu((v) => !v); setShowQualityMenu(false); }}
                title="Playback speed"
                aria-label="Playback speed"
              >
                <Gauge size={18} />
                <span className="vp-speed-label">{speed}×</span>
              </button>
              {showSpeedMenu && (
                <div className="vp-menu vp-menu-up">
                  {SPEEDS.map((s) => (
                    <button
                      key={s}
                      type="button"
                      className={`vp-menu-item${speed === s ? " vp-menu-item-active" : ""}`}
                      onClick={() => setPlaybackSpeed(s)}
                    >
                      {s}×
                    </button>
                  ))}
                  {/* Lives here rather than as its own control-bar button:
                      it's a diagnostic, and the bar is already dense on a
                      phone. Also reachable with "i". */}
                  <button
                    type="button"
                    className={`vp-menu-item vp-menu-item-sep${showStats ? " vp-menu-item-active" : ""}`}
                    onClick={() => { setShowStats((v) => !v); setShowSpeedMenu(false); }}
                  >
                    Stats
                  </button>
                </div>
              )}
            </div>

            {/* Quality */}
            {visibleQualityOptions.length > 0 && onQualityChange && (
              <div className="vp-menu-wrap">
                <button
                  type="button"
                  className={`vp-btn${showQualityMenu ? " active" : ""}`}
                  onClick={() => { setShowQualityMenu((v) => !v); setShowSpeedMenu(false); }}
                  title="Quality"
                  aria-label="Video quality"
                >
                  <span className="vp-quality-label">{(visibleQualityOptions.find(([v]) => v === quality) || [])[1] || quality || "HD"}</span>
                </button>
                {showQualityMenu && (
                  <div className="vp-menu vp-menu-up">
                    {visibleQualityOptions.map(([value, label]) => (
                      <button
                        key={value}
                        type="button"
                        className={`vp-menu-item${quality === value ? " vp-menu-item-active" : ""}`}
                        onClick={() => { onQualityChange(value, { userInitiated: true }); setShowQualityMenu(false); }}
                      >
                        {label}
                      </button>
                    ))}
                  </div>
                )}
              </div>
            )}

            {/* Captions. Only rendered once a track actually exists:
                the backend generates these in the background and plenty
                of posts (a clip with no speech) legitimately never get
                one, so a permanently dead CC button would be worse than
                none. */}
            {captions && (
              <button
                type="button"
                className={`vp-btn${captionsOn ? " active" : ""}`}
                onClick={() => setCaptionsOn((value) => { setPlayerPref("captions", !value); return !value; })}
                title={captionsOn ? "Turn captions off" : "Turn captions on (auto-generated)"}
                aria-label="Toggle captions"
                aria-pressed={captionsOn}
              >
                {captionsOn ? <Captions size={18} /> : <CaptionsOff size={18} />}
              </button>
            )}

            {/* Autoplay the next post in the same browsing run once this
                one ends. Only offered when the caller actually gave us
                somewhere to go (a feed/collection the viewer arrived
                from), never on a standalone permalink. */}
            {onNext && (
              <button
                type="button"
                className={`vp-btn${autoplayNext ? " active" : ""}`}
                onClick={toggleAutoplayNext}
                title={autoplayNext ? "Autoplay next: on" : "Autoplay next: off"}
                aria-label="Toggle autoplay next"
                aria-pressed={autoplayNext}
              >
                <NextIcon size={18} />
              </button>
            )}

            {/* PiP -- checks the actual flag, not just that the property
                exists: `"pictureInPictureEnabled" in document` is true in
                every supporting browser regardless of its VALUE, so a
                browser/enterprise policy or Permissions-Policy header that
                disables PiP would still show this button, just make
                clicking it silently do nothing (requestPictureInPicture()
                rejects, caught and swallowed by togglePip's .catch).
                `pipSupported` additionally covers Safari, which implements
                PiP only through the element's webkitSetPresentationMode --
                see togglePip. */}
            {pipSupported && (
              <button type="button" className={`vp-btn${pip ? " active" : ""}`} onClick={togglePip} title="Picture in Picture" aria-label="Picture in Picture">
                <PictureInPicture2 size={18} />
              </button>
            )}

            {/* Fullscreen */}
            <button type="button" className="vp-btn" onClick={toggleFullscreen} title={fullscreen ? "Exit fullscreen" : "Fullscreen"} aria-label={fullscreen ? "Exit fullscreen" : "Fullscreen"}>
              {fullscreen ? <Minimize size={18} /> : <Maximize size={18} />}
            </button>
          </div>
        </div>
      </div>

      {/* Close speed/quality menus on outside click */}
      {(showSpeedMenu || showQualityMenu) && (
        <div className="vp-menu-overlay" onClick={() => { setShowSpeedMenu(false); setShowQualityMenu(false); }} />
      )}
    </div>
  );
}
