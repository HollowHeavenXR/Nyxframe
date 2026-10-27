import { useEffect, useRef, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { Clipboard, FileImage, FileVideo, RefreshCw, Trash2, Upload, WandSparkles, X } from "lucide-react";
import { apiFetch, clearApiCache, postClientDiagnostic, readToken, resolveApiUrl } from "../api.js";
import { MAX_UPLOAD_BYTES } from "../config.js";
import { addPendingUploadJob, describeUploadStage } from "../uploadJobs.js";
import { ChipRow, Page, RequireLogin, Segmented } from "../components/ui.jsx";
import { ReuseTagsField, mergeTags } from "../components/PostPicker.jsx";
import { ThumbnailChooser, stageThumbnail } from "../components/ThumbnailPicker.jsx";
import { formatBytes } from "../utils/format.js";

const SUBCATEGORY_SLOT_COUNT = 20;
const EDGE_SAFE_UPLOAD_BYTES = 80 * 1024 * 1024;
// At or under this, a file goes up as one request (with defer=true, so the
// server hands it to a background job instead of processing while we
// wait). Above it, it goes up in pieces, several at once, each retried on
// its own -- a dropped connection near the end of a big video then costs
// one piece, not the whole file.
const SINGLE_REQUEST_MAX_BYTES = 16 * 1024 * 1024;
const PARALLEL_CHUNK_BYTES = 8 * 1024 * 1024;
const PARALLEL_CHUNK_STREAMS = 4;
const MAX_REQUEST_ATTEMPTS = 5;
// How long the upload page itself follows processing before handing the
// job to Shell's background poller and moving on.
const FOLLOW_PROCESSING_MS = 45_000;
// Uniform ceiling for every upload-related request (init/chunk/finish/direct
// <=80MB/analyze) -- finalize_upload does real synchronous work server-side
// (fast-start remux, full-file sha256, up to a 30s AI vision call, disk
// save), and xhrJson previously had NO timeout at all, so a truly stalled
// connection would hang forever with no error surfaced to the user.
const UPLOAD_TIMEOUT_MS = 120_000;

// What each subcategory slot usually holds -- the labels and placeholders
// the old six-field grid used, kept as the one-row version's guidance.
const SUBCATEGORY_SLOTS = [
  { label: "Series or group", placeholder: "e.g. Final Fantasy" },
  { label: "Character or subject", placeholder: "e.g. Cloud Strife" },
  { label: "Variant or context", placeholder: "e.g. Advent Children" },
];

// The first three keep their original guidance; the rest are plain extras.
// Twenty always-visible inputs would bury the rest of the form, so the list
// grows as it is filled -- see visibleSubcategoryCount below.
function subcategorySlotMeta(index) {
  return SUBCATEGORY_SLOTS[index] || {
    label: `Subcategory ${index + 1}`,
    placeholder: "Another subcategory (optional)",
  };
}

// Always show at least the three labelled fields, plus one empty field after
// the last one filled, capped at SUBCATEGORY_SLOT_COUNT.
function visibleSubcategoryCount(values) {
  const filled = (Array.isArray(values) ? values : [])
    .map((v) => String(v || "").trim());
  let last = -1;
  filled.forEach((v, i) => { if (v) last = i; });
  return Math.min(SUBCATEGORY_SLOT_COUNT, Math.max(SUBCATEGORY_SLOTS.length, last + 2));
}

const VISIBILITY_OPTIONS = [
  ["public", "Public"],
  ["unlisted", "Unlisted"],
  ["private", "Private"],
];

const VISIBILITY_HINTS = {
  public: "Anyone can find it in Discover, search and your profile.",
  unlisted: "Only people with the link can see it. Hidden from Discover and search.",
  private: "Only you can see it.",
};

const OPTION_TOGGLES = [
  { key: "auto_ai", label: "AI metadata", hint: "After upload, fill in any title, category or tags you left blank." },
  { key: "is_adult", label: "18+", hint: "Only shown to viewers who have verified their age." },
  { key: "comments_enabled", label: "Comments", hint: "Let people comment on this post." },
  { key: "downloads_enabled", label: "Downloads", hint: "Show the download button on this post." },
  { key: "check_site_duplicates", label: "Check the whole site for duplicates", hint: "Warn if a similar post exists anywhere on Nyxframe, not just in your uploads." },
];

function blankSubcategorySlots() {
  return Array.from({ length: SUBCATEGORY_SLOT_COUNT }, () => "");
}

function sameName(a, b) {
  return String(a || "").trim().toLowerCase() === String(b || "").trim().toLowerCase();
}

function findCategory(categories, text) {
  if (!String(text || "").trim()) return null;
  return (categories || []).find((category) => sameName(category.name, text)) || null;
}

function subcategoriesOf(category) {
  return category?.subcategories || category?.children || [];
}

// Category and subcategories are single type-or-pick fields now: a name that
// matches an existing entry is sent as its id, anything else as a new name to
// create -- the same two request shapes the old select + "New ..." input
// pairs produced, without making the uploader choose between two fields.
function resolvePlacement(categories, categoryText, subcategoryTexts) {
  const category = findCategory(categories, categoryText);
  const existingSubs = subcategoriesOf(category);
  const subcategoryIds = [];
  const subcategoryNames = [];
  normalizeSlots(subcategoryTexts).forEach((text) => {
    const trimmed = text.trim();
    if (!trimmed) return;
    const match = existingSubs.find((sub) => sameName(sub.name, trimmed));
    if (match) subcategoryIds.push(String(match.id));
    else subcategoryNames.push(trimmed);
  });
  return {
    categoryId: category ? String(category.id) : "",
    categoryName: category ? "" : String(categoryText || "").trim(),
    subcategoryIds,
    subcategoryNames,
  };
}

function isAcceptedFile(file) {
  return Boolean(file && (file.type.startsWith("image/") || file.type.startsWith("video/")));
}

function formatDuration(seconds) {
  const total = Math.round(Number(seconds) || 0);
  const minutes = Math.floor(total / 60);
  return `${minutes}:${String(total % 60).padStart(2, "0")}`;
}

function parseTags(text) {
  return String(text || "").split(",").map((tag) => tag.trim()).filter(Boolean);
}

function normalizeSlots(values) {
  const slots = Array.isArray(values) ? values.slice(0, SUBCATEGORY_SLOT_COUNT) : [];
  while (slots.length < SUBCATEGORY_SLOT_COUNT) slots.push("");
  return slots.map((value) => String(value || ""));
}

function uploadError(message, { status = 0, retryable = false, payload = null } = {}) {
  const error = new Error(message);
  error.status = status;
  error.retryable = retryable;
  error.payload = payload;
  return error;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Network errors, timeouts, rate limits and 5xx (including Cloudflare's
// 520-524 when the origin restarts or is briefly busy) are worth another
// try; any other 4xx is a real rejection.
function isRetryableStatus(status) {
  return status === 0 || status === 408 || status === 425 || status === 429 || status >= 500;
}

// `track` registers the in-flight request so Cancel can abort it.
function xhrJson(url, { method = "POST", body, contentType, onProgress, timeoutMs = UPLOAD_TIMEOUT_MS, track } = {}) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    track?.(xhr);
    const token = readToken();
    xhr.open(method, url, true);
    if (token) xhr.setRequestHeader("Authorization", `Bearer ${token}`);
    xhr.setRequestHeader("Accept", "application/json");
    if (contentType) xhr.setRequestHeader("Content-Type", contentType);
    xhr.withCredentials = true;
    xhr.timeout = timeoutMs;
    if (onProgress) xhr.upload.addEventListener("progress", onProgress);
    xhr.addEventListener("load", () => {
      let payload = null;
      try { payload = xhr.responseText ? JSON.parse(xhr.responseText) : null; } catch { /* handled below */ }
      if (xhr.status >= 200 && xhr.status < 300) return resolve(payload);
      const detail = payload?.detail;
      reject(uploadError(
        detail ? (Array.isArray(detail) ? detail.map((item) => item?.msg || item).join("; ") : String(detail)) : `Upload failed (${xhr.status})`,
        { status: xhr.status, retryable: isRetryableStatus(xhr.status), payload },
      ));
    });
    xhr.addEventListener("error", () => reject(uploadError("Network error during upload.", { retryable: true })));
    xhr.addEventListener("abort", () => reject(uploadError("Upload cancelled.", { status: -1 })));
    xhr.addEventListener("timeout", () => reject(uploadError("Request timed out. Please try again.", { retryable: true })));
    xhr.send(body);
  });
}

// Retries a request with backoff (1s, 2s, 4s, 8s) while it fails in a
// retryable way. `onRetry` counts attempts for diagnostics.
async function withRetries(run, { isCancelled, onRetry } = {}) {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await run(attempt);
    } catch (error) {
      if (isCancelled?.() || !error.retryable || attempt >= MAX_REQUEST_ATTEMPTS) throw error;
      onRetry?.();
      await sleep(Math.min(8000, 1000 * 2 ** (attempt - 1)));
      if (isCancelled?.()) throw uploadError("Upload cancelled.", { status: -1 });
    }
  }
}

export function UploadPage({ ctx }) {
  const navigate = useNavigate();
  const [form, setForm] = useState({
    file: null,
    title: "",
    description: "",
    source_url: "",
    category: "",
    subcategories: blankSubcategorySlots(),
    tags: "",
    is_adult: false,
    visibility: "public",
    comments_enabled: true,
    downloads_enabled: true,
    pinned: false,
    auto_ai: true,
    publish_at: "",
    expires_in_hours: "",
    check_site_duplicates: true,
  });
  const [preview, setPreview] = useState("");
  const [mediaInfo, setMediaInfo] = useState(null); // { width, height, duration }
  const [busy, setBusy] = useState(false);
  const [analyzing, setAnalyzing] = useState(false);
  const [uploadProgress, setUploadProgress] = useState(0); // 0–100
  const [dragActive, setDragActive] = useState(false);
  const [analysis, setAnalysis] = useState(null);
  const [duplicates, setDuplicates] = useState([]);
  const dragDepth = useRef(0);
  // Batch upload: form.file stays the one file with full manual editing
  // (title/description/AI-analyze preview/duplicate-check) exactly as
  // before -- these are the REST of a multi-file pick/drop, each one
  // sharing this same form's category/subcategories/tags/visibility/
  // toggles/publish_at but with NO shared title/description (auto_ai, if
  // on, fills those in per-file instead -- a batch of distinct images
  // all getting the one typed-in title would be wrong, not a convenience).
  const [extraFiles, setExtraFiles] = useState([]); // [{ id, file, status: pending|uploading|done|error, error }]
  const extraFileIdRef = useRef(0);
  // Custom thumbnail for the primary file when it's a video (a Blob, or
  // null for the automatic frame grab), plus the preview <video> so "Use
  // current frame" can capture whatever frame it's paused on.
  const [thumbnail, setThumbnail] = useState(null);
  const previewVideoRef = useRef(null);
  // idle -> uploading (bytes going up) -> processing (server working on a
  // single upload this page is following) -> idle/navigated away.
  const [phase, setPhase] = useState("idle");
  const [stage, setStage] = useState("");
  const [rate, setRate] = useState(null); // { bps, etaSeconds } while uploading
  const activeXhrs = useRef(new Set());
  const cancelledRef = useRef(false);
  const followJobRef = useRef(null); // { jobId, filename } being followed here

  // Warn before closing the tab while bytes are still going up (once
  // they're sent, processing carries on server-side regardless).
  useEffect(() => {
    if (phase !== "uploading") return undefined;
    const onBeforeUnload = (event) => {
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", onBeforeUnload);
    return () => window.removeEventListener("beforeunload", onBeforeUnload);
  }, [phase]);

  // Leaving the page while following a job: hand it to Shell's poller so
  // its completion toast still shows up wherever the user goes.
  useEffect(() => () => {
    const job = followJobRef.current;
    if (job) {
      followJobRef.current = null;
      addPendingUploadJob(job);
    }
  }, []);

  useEffect(() => {
    setMediaInfo(null);
    if (!form.file) {
      setPreview("");
      return undefined;
    }
    const url = URL.createObjectURL(form.file);
    setPreview(url);
    return () => URL.revokeObjectURL(url);
  }, [form.file]);

  useEffect(() => {
    setDuplicates([]);
    setAnalysis(null);
    setThumbnail(null);
  }, [form.file]);

  // Paste an image straight from the clipboard (a screenshot, a copied
  // image) -- but never hijack a paste into a text field.
  useEffect(() => {
    function onPaste(event) {
      const target = event.target;
      if (target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.isContentEditable)) return;
      const file = [...(event.clipboardData?.files || [])].find(isAcceptedFile);
      if (!file) return;
      event.preventDefault();
      pickFile(file);
    }
    window.addEventListener("paste", onPaste);
    return () => window.removeEventListener("paste", onPaste);
  });

  if (!ctx.user) return <RequireLogin />;

  function trackXhr(xhr) {
    activeXhrs.current.add(xhr);
    xhr.addEventListener("loadend", () => activeXhrs.current.delete(xhr));
  }

  function cancelUpload() {
    cancelledRef.current = true;
    for (const xhr of activeXhrs.current) xhr.abort();
    activeXhrs.current.clear();
  }

  function pickFile(file) {
    if (!file) return;
    if (!isAcceptedFile(file)) {
      ctx.showToast("Only image and video files can be uploaded.", "error");
      return;
    }
    update("file", file);
  }

  // Shared by the file input (now `multiple`) and multi-file drag/drop:
  // the first accepted file becomes the primary file (unchanged manual-
  // editing flow); anything beyond that joins the batch queue below it.
  function pickFiles(fileList) {
    const files = [...(fileList || [])].filter(isAcceptedFile);
    if (!files.length) {
      if (fileList?.length) ctx.showToast("Only image and video files can be uploaded.", "error");
      return;
    }
    const [first, ...rest] = files;
    if (!form.file) {
      update("file", first);
    } else {
      rest.unshift(first);
    }
    if (rest.length) {
      setExtraFiles((current) => [
        ...current,
        ...rest.map((file) => ({ id: ++extraFileIdRef.current, file, status: "pending", error: "" })),
      ]);
    }
  }

  function removeExtraFile(id) {
    setExtraFiles((current) => current.filter((row) => row.id !== id));
  }

  // The whole page is a drop target. dragenter/dragleave fire for every
  // child element crossed, so count depth instead of trusting relatedTarget.
  function handleDragEnter(event) {
    if (![...(event.dataTransfer?.types || [])].includes("Files")) return;
    event.preventDefault();
    dragDepth.current += 1;
    setDragActive(true);
  }

  function handleDragOver(event) {
    if (![...(event.dataTransfer?.types || [])].includes("Files")) return;
    event.preventDefault();
  }

  function handleDragLeave(event) {
    if (![...(event.dataTransfer?.types || [])].includes("Files")) return;
    dragDepth.current = Math.max(0, dragDepth.current - 1);
    if (!dragDepth.current) setDragActive(false);
  }

  function handleDrop(event) {
    event.preventDefault();
    dragDepth.current = 0;
    setDragActive(false);
    pickFiles(event.dataTransfer?.files);
  }

  function update(key, value) {
    setForm((current) => ({ ...current, [key]: value }));
  }

  // Tags picked from one of the uploader's own posts (PostPicker).
  function applyPickedTags(tags, post, mode) {
    const { tags: next, added } = mergeTags(parseTags(form.tags), tags, mode);
    update("tags", next.join(", "));
    const from = `"${post.title || `Post #${post.id}`}"`;
    if (mode === "replace") ctx.showToast(`Tags replaced with ${next.length} from ${from}.`, "success");
    else ctx.showToast(added ? `Added ${added} tag${added === 1 ? "" : "s"} from ${from}.` : `You already have every tag from ${from}.`, added ? "success" : "info");
  }

  function updateSubcategory(index, value) {
    setForm((current) => {
      const next = normalizeSlots(current.subcategories);
      next[index] = value;
      return { ...current, subcategories: next };
    });
  }

  function removeFile() {
    update("file", null);
    setUploadProgress(0);
  }

  async function analyze() {
    if (!form.file) return;
    // Analyze always sends the file as one plain multipart request (unlike
    // the real upload below, which switches to the chunked path above this
    // same threshold) -- a large enough picked file makes that single
    // request itself exceed this deployment's Cloudflare edge body-size cap
    // and 413s with a raw Cloudflare HTML error page, not a real API error
    // (reported live from a large wallpaper image). Analyze is a pure
    // convenience preview -- auto_ai already runs the same analysis
    // server-side during the real upload regardless -- so it's fine to just
    // decline up front here rather than build a second chunking path for a
    // pre-submit preview feature.
    if (form.file.size > EDGE_SAFE_UPLOAD_BYTES) {
      ctx.showToast("This file is too large to analyze here — go ahead and upload it directly; AI metadata still runs automatically.", "info");
      return;
    }
    setBusy(true);
    setAnalyzing(true);
    try {
      const body = new FormData();
      body.set("file", form.file);
      body.set("title", form.title);
      body.set("description", form.description);
      if (form.source_url.trim()) body.set("source_url", form.source_url.trim());
      body.set("tags", form.tags);
      // AI vision analysis can legitimately take up to ai_timeout_seconds+10 on the
      // backend (default 55s) before falling back to local heuristics, well past the
      // default 12s apiFetch timeout — use a longer timeout so real analyses don't abort.
      const data = await apiFetch("/api/media/analyze", { method: "POST", body, timeoutMs: UPLOAD_TIMEOUT_MS });
      setAnalysis(data.analysis);
      setDuplicates(data.possible_duplicates || []);
      // Only fills gaps -- anything the uploader already typed wins.
      setForm((current) => ({
        ...current,
        title: current.title || data.analysis?.title || "",
        category: current.category || data.analysis?.category_name || "",
        subcategories: normalizeSlots(current.subcategories).map((value, index) => {
          if (value) return value;
          return String(data.analysis?.subcategory_names?.[index] || "");
        }),
        tags: current.tags || (data.analysis?.tags || []).join(", "),
        is_adult: current.is_adult || Boolean(data.analysis?.is_adult),
      }));
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setBusy(false);
      setAnalyzing(false);
    }
  }

  // Form fields shared by every file of this submit (title/description
  // are per file: the batch rows leave them blank for AI auto-fill).
  function uploadFields({ title, description, thumbnailToken }) {
    const placement = resolvePlacement(ctx.lookups.categories, form.category, form.subcategories);
    const fields = [
      ["title", title],
      ["description", description],
      ["category_id", placement.categoryId],
      ["category_name", placement.categoryName],
      ["subcategory_id", placement.subcategoryIds[0] || ""],
      ["subcategory_name", placement.subcategoryNames[0] || ""],
      ["subcategory_ids_json", JSON.stringify(placement.subcategoryIds)],
      ["subcategory_names_json", JSON.stringify(placement.subcategoryNames)],
      ["tags", form.tags],
      ["is_adult", String(form.is_adult)],
      ["visibility", form.visibility],
      ["comments_enabled", String(form.comments_enabled)],
      ["downloads_enabled", String(form.downloads_enabled)],
      ["pinned", String(form.pinned)],
      ["auto_ai", String(form.auto_ai)],
      ["check_site_duplicates", String(form.check_site_duplicates)],
    ];
    if (form.source_url.trim()) fields.push(["source_url", form.source_url.trim()]);
    if (form.publish_at) fields.push(["publish_at", new Date(form.publish_at).toISOString()]);
    if (form.expires_in_hours) fields.push(["expires_in_hours", form.expires_in_hours]);
    if (thumbnailToken) fields.push(["thumbnail_token", thumbnailToken]);
    return fields;
  }

  // Sends one file's bytes and hands it to the server. Resolves with the
  // server's reply: normally { status: "processing", job_id } (processing
  // continues server-side), or a finished { media } from an older server.
  // `onBytes(sent)` reports progress in bytes. Throws on failure; an error
  // with status -1 means the user cancelled.
  async function uploadOneFile(file, { title, description, thumbnailToken }, onBytes) {
    const uploadT0 = performance.now();
    let uploadMethod = "direct";
    let chunkCount = 0;
    let retryCount = 0;
    const isCancelled = () => cancelledRef.current;
    const onRetry = () => { retryCount += 1; };
    const reportUploadDiagnostic = (outcome, errorMessage) => postClientDiagnostic("/api/media/upload/diagnostics", {
      outcome,
      method: uploadMethod,
      duration_ms: Math.round(performance.now() - uploadT0),
      bytes: file.size,
      chunk_count: chunkCount || undefined,
      retry_count: retryCount,
      error_message: errorMessage,
    });
    try {
      const fields = uploadFields({ title, description, thumbnailToken });
      let data;
      if (file.size <= SINGLE_REQUEST_MAX_BYTES) {
        const url = await resolveApiUrl("/api/media");
        data = await withRetries(() => {
          const body = new FormData();
          body.set("file", file);
          for (const [key, value] of fields) body.set(key, value);
          body.set("defer", "true");
          return xhrJson(url, {
            body,
            track: trackXhr,
            onProgress: (progressEvent) => {
              if (progressEvent.lengthComputable) onBytes?.(Math.round((progressEvent.loaded / progressEvent.total) * file.size));
            },
          });
        }, { isCancelled, onRetry });
      } else {
        uploadMethod = "chunked";
        const jsonRequest = async (path, payload) => xhrJson(await resolveApiUrl(path), {
          body: JSON.stringify(payload),
          contentType: "application/json",
          track: trackXhr,
        });
        const init = await withRetries(
          () => jsonRequest("/api/media/upload/init", { total_size: file.size, filename: file.name }),
          { isCancelled, onRetry },
        );
        // Servers that accept `offset` take pieces in any order, several at
        // a time; older ones need them one by one, in order.
        const parallel = Boolean(init.parallel);
        const chunkSize = parallel
          ? Math.min(PARALLEL_CHUNK_BYTES, Number(init.max_chunk_size) || PARALLEL_CHUNK_BYTES)
          : (Number(init.chunk_size) > 0 ? Number(init.chunk_size) : 4 * 1024 * 1024);
        const totalChunks = Math.ceil(file.size / chunkSize);
        const chunkUrl = await resolveApiUrl("/api/media/upload/chunk");
        const sessionParam = encodeURIComponent(init.session_id);
        const inFlight = new Map(); // chunk index -> bytes sent so far
        let doneBytes = 0;
        const reportBytes = () => {
          let sending = 0;
          for (const value of inFlight.values()) sending += value;
          onBytes?.(Math.min(file.size, doneBytes + sending));
        };
        const sendChunk = async (index) => {
          const start = index * chunkSize;
          const piece = file.slice(start, Math.min(start + chunkSize, file.size));
          await withRetries(() => {
            inFlight.set(index, 0);
            return xhrJson(`${chunkUrl}?session_id=${sessionParam}&index=${index}${parallel ? `&offset=${start}` : ""}`, {
              body: piece,
              contentType: "application/octet-stream",
              track: trackXhr,
              onProgress: (progressEvent) => {
                inFlight.set(index, progressEvent.loaded || 0);
                reportBytes();
              },
            });
          }, { isCancelled, onRetry });
          inFlight.delete(index);
          doneBytes += piece.size;
          chunkCount += 1;
          reportBytes();
        };
        const sendRange = async (fromIndex) => {
          let next = fromIndex;
          let failure = null;
          const streams = parallel ? PARALLEL_CHUNK_STREAMS : 1;
          await Promise.all(Array.from({ length: Math.min(streams, totalChunks - fromIndex) }, async () => {
            while (!failure && next < totalChunks) {
              const index = next;
              next += 1;
              try {
                await sendChunk(index);
              } catch (error) {
                failure = failure || error;
              }
            }
          }));
          if (failure) throw failure;
        };
        await sendRange(0);

        const finishPayload = {
          ...Object.fromEntries(fields),
          session_id: init.session_id,
          total_size: file.size,
        };
        let resentGap = false;
        data = await withRetries(async () => {
          try {
            return await jsonRequest("/api/media/upload/finish", finishPayload);
          } catch (error) {
            // The server is missing some bytes (a piece that was lost on the
            // way): send everything from that point again, then finish.
            const missingFrom = Number(error.payload?.missing_from);
            if (error.status === 400 && parallel && Number.isFinite(missingFrom) && !resentGap) {
              resentGap = true;
              doneBytes = missingFrom;
              await sendRange(Math.floor(missingFrom / chunkSize));
              return jsonRequest("/api/media/upload/finish", finishPayload);
            }
            throw error;
          }
        }, { isCancelled, onRetry });
      }
      reportUploadDiagnostic("success");
      return data;
    } catch (error) {
      reportUploadDiagnostic(error.status === -1 ? "cancelled" : "error", String(error.message || "").slice(0, 300));
      throw error;
    }
  }

  function announceUploaded(data) {
    clearApiCache();
    ctx.refreshLookups();
    if (!duplicates.length && data.possible_duplicates?.length) {
      ctx.showToast(
        `Uploaded — heads up, ${data.possible_duplicates.length} similar post${data.possible_duplicates.length === 1 ? "" : "s"} already exist in your library.`,
        "info",
      );
    } else if (data.possible_site_duplicates?.length) {
      ctx.showToast(
        `Uploaded — heads up, ${data.possible_site_duplicates.length} similar post${data.possible_site_duplicates.length === 1 ? "" : "s"} already exist elsewhere on the site.`,
        "info",
      );
    } else {
      ctx.showToast("Upload saved.", "success");
    }
  }

  // Follows a single upload's processing on this page (showing its stage)
  // for up to FOLLOW_PROCESSING_MS, then opens the new post. If it takes
  // longer -- or the user leaves, or picks "Continue in background" -- the
  // job moves to Shell's background poller, which toasts when it's done.
  async function followJob(jobId, filename) {
    followJobRef.current = { jobId, filename };
    setPhase("processing");
    setStage("queued");
    const deadline = Date.now() + FOLLOW_PROCESSING_MS;
    while (followJobRef.current?.jobId === jobId && Date.now() < deadline) {
      let data = null;
      try {
        data = await apiFetch(`/api/media/upload/job/${encodeURIComponent(jobId)}`);
      } catch (_error) {
        await sleep(1500);
        continue;
      }
      if (followJobRef.current?.jobId !== jobId) return;
      if (data.status === "done" && data.media?.id) {
        followJobRef.current = null;
        announceUploaded(data);
        navigate(`/media/${data.media.id}`);
        return;
      }
      if (data.status === "error" && !data.retrying) {
        followJobRef.current = null;
        ctx.showToast(`Upload failed: ${data.detail || "unknown error"}`, "error");
        return;
      }
      setStage(data.status === "error" ? "retrying" : (data.stage || "queued"));
      await sleep(700);
    }
    handOffFollowedJob(true);
  }

  function handOffFollowedJob(navigateAway) {
    const job = followJobRef.current;
    if (!job) return;
    followJobRef.current = null;
    addPendingUploadJob(job);
    if (navigateAway) {
      ctx.showToast("Still processing in the background — we'll let you know when it's ready.", "info");
      navigate("/profile");
    }
  }

  async function submit(event) {
    event.preventDefault();
    if (!form.file) return ctx.showToast("Choose a file first.", "error");
    if (form.file.size > MAX_UPLOAD_BYTES) return ctx.showToast(`This file is over the ${formatBytes(MAX_UPLOAD_BYTES)} upload limit.`, "error");
    for (const row of extraFiles) {
      if (row.file.size > MAX_UPLOAD_BYTES) {
        return ctx.showToast(`"${row.file.name}" is over the ${formatBytes(MAX_UPLOAD_BYTES)} upload limit.`, "error");
      }
    }
    if (duplicates.length) {
      const proceed = window.confirm(
        `This looks similar to ${duplicates.length} post${duplicates.length === 1 ? "" : "s"} already in your library. Upload anyway?`,
      );
      if (!proceed) return;
    }

    const entries = [
      { id: "primary", file: form.file, title: form.title, description: form.description },
      ...extraFiles
        .filter((row) => row.status !== "done")
        .map((row) => ({ id: row.id, file: row.file, title: "", description: "" })),
    ];
    const totalBytes = entries.reduce((sum, entry) => sum + entry.file.size, 0) || 1;
    const sentByFile = new Map();
    const speed = { lastT: performance.now(), lastBytes: 0, bps: 0 };
    const onFileBytes = (id, bytes) => {
      sentByFile.set(id, bytes);
      let sent = 0;
      for (const value of sentByFile.values()) sent += value;
      setUploadProgress(Math.min(100, Math.floor((sent / totalBytes) * 100)));
      const now = performance.now();
      if (now - speed.lastT >= 600) {
        const instant = ((sent - speed.lastBytes) * 1000) / (now - speed.lastT);
        speed.bps = speed.bps ? speed.bps * 0.6 + instant * 0.4 : instant;
        speed.lastT = now;
        speed.lastBytes = sent;
        setRate({ bps: speed.bps, etaSeconds: speed.bps > 0 ? (totalBytes - sent) / speed.bps : null });
      }
    };

    cancelledRef.current = false;
    setBusy(true);
    setPhase("uploading");
    setUploadProgress(0);
    setRate(null);
    setStage("");
    try {
      // A chosen thumbnail goes up first (it's small); the upload carries
      // its token and the server attaches it once the post exists.
      if (thumbnail && form.file.type.startsWith("video/")) {
        entries[0].thumbnailToken = await stageThumbnail(thumbnail);
      }
      if (entries.length === 1) {
        const data = await uploadOneFile(form.file, entries[0], (bytes) => onFileBytes("primary", bytes));
        setRate(null);
        if (data.job_id) {
          await followJob(data.job_id, form.file.name);
        } else if (data.media?.id) {
          announceUploaded(data);
          navigate(`/media/${data.media.id}`);
        }
        return;
      }

      // Batch: two files at a time. Each one's processing continues
      // server-side and is tracked by Shell's poller, so the page only
      // waits for the bytes. One failure doesn't stop the rest.
      const setRow = (id, patch) => setExtraFiles((current) => current.map((row) => (row.id === id ? { ...row, ...patch } : row)));
      let succeeded = 0;
      const failures = [];
      let next = 0;
      await Promise.all(Array.from({ length: Math.min(2, entries.length) }, async () => {
        while (next < entries.length && !cancelledRef.current) {
          const entry = entries[next];
          next += 1;
          if (entry.id !== "primary") setRow(entry.id, { status: "uploading", error: "" });
          try {
            const data = await uploadOneFile(entry.file, entry, (bytes) => onFileBytes(entry.id, bytes));
            if (data.job_id) addPendingUploadJob({ jobId: data.job_id, filename: entry.file.name });
            sentByFile.set(entry.id, entry.file.size);
            succeeded += 1;
            if (entry.id !== "primary") setRow(entry.id, { status: "done" });
          } catch (error) {
            if (error.status === -1) return;
            failures.push(`${entry.file.name}: ${error.message}`);
            if (entry.id !== "primary") setRow(entry.id, { status: "error", error: error.message });
          }
        }
      }));
      if (cancelledRef.current) {
        ctx.showToast(succeeded ? `Cancelled — ${succeeded} file${succeeded === 1 ? " was" : "s were"} already sent and will still be posted.` : "Upload cancelled.", "info");
        return;
      }
      clearApiCache();
      ctx.refreshLookups();
      if (failures.length) {
        ctx.showToast(`Sent ${succeeded} of ${entries.length} files — ${failures.length} failed (${failures[0]}).`, "error");
        if (!succeeded) return;
      } else {
        ctx.showToast(`All ${succeeded} files sent — they're processing now. We'll let you know as each one is ready.`, "success");
      }
      navigate("/profile");
    } catch (error) {
      if (error.status === -1) ctx.showToast("Upload cancelled.", "info");
      else ctx.showToast(error.message, "error");
      setUploadProgress(0);
    } finally {
      setBusy(false);
      setPhase("idle");
      setRate(null);
    }
  }

  const categories = ctx.lookups.categories || [];
  const matchedCategory = findCategory(categories, form.category);
  const existingSubcategories = subcategoriesOf(matchedCategory);
  const isVideo = form.file?.type?.startsWith("video/");
  const tooBig = Boolean(form.file && form.file.size > MAX_UPLOAD_BYTES);
  const tooBigToAnalyze = Boolean(form.file && form.file.size > EDGE_SAFE_UPLOAD_BYTES);
  const tagList = parseTags(form.tags);
  const analysisChips = analysis
    ? [analysis.media_kind, analysis.source, analysis.category_name, ...(analysis.subcategory_names || []), ...((analysis.tags || []).slice(0, 4))].filter(Boolean)
    : [];
  const uploading = busy && !analyzing;
  const processing = phase === "processing";
  const fileFacts = form.file
    ? [
      isVideo ? "Video" : "Image",
      formatBytes(form.file.size),
      mediaInfo?.width ? `${mediaInfo.width}×${mediaInfo.height}` : "",
      mediaInfo?.duration ? formatDuration(mediaInfo.duration) : "",
    ].filter(Boolean)
    : [];
  let status = "Choose a file to get started.";
  if (processing) status = describeUploadStage(stage);
  else if (uploading) {
    status = uploadProgress >= 100
      ? "Handing off to the server…"
      : [
        `Uploading… ${uploadProgress}%`,
        rate?.bps > 0 ? `${formatBytes(rate.bps)}/s` : "",
        rate?.etaSeconds != null && rate.etaSeconds >= 1 ? `${formatDuration(rate.etaSeconds)} left` : "",
      ].filter(Boolean).join(" · ");
  }
  else if (analyzing) status = "Analyzing with AI…";
  else if (tooBig) status = `Over the ${formatBytes(MAX_UPLOAD_BYTES)} limit — choose a smaller file.`;
  else if (form.file && !form.title.trim() && !form.auto_ai) status = "Add a title, or turn on AI metadata to fill it in.";
  else if (form.file) status = `Ready · ${form.file.name}`;

  return (
    <Page
      title="Upload"
      eyebrow="Create"
      lede="Add an image or video to the gallery. Drop a file anywhere on this page, or paste one from your clipboard."
    >
      <form
        className={`upload-page${dragActive ? " is-dragging" : ""}`}
        onSubmit={submit}
        onDragEnter={handleDragEnter}
        onDragOver={handleDragOver}
        onDragLeave={handleDragLeave}
        onDrop={handleDrop}
      >
        {dragActive ? (
          <div className="upload-drop-overlay" aria-hidden="true">
            <Upload size={36} />
            <strong>Drop to add this file</strong>
          </div>
        ) : null}

        <aside className="upload-media">
          {!form.file ? (
            <label className="upload-dropzone">
              <input type="file" accept="image/*,video/*" multiple onChange={(event) => { pickFiles(event.target.files); event.target.value = ""; }} />
              <span className="upload-dropzone-icon"><Upload size={28} /></span>
              <strong>Drop an image or video</strong>
              <span className="upload-dropzone-cta">Choose files</span>
              <small>Images, GIFs and videos · up to {formatBytes(MAX_UPLOAD_BYTES)} each · pick or drop more than one to batch-upload</small>
              <small className="upload-dropzone-paste"><Clipboard size={13} />You can also paste an image</small>
            </label>
          ) : (
            <div className="upload-file-card">
              <div className="upload-preview">
                {!preview ? null : isVideo ? (
                  <video
                    ref={previewVideoRef}
                    src={preview}
                    controls
                    muted
                    playsInline
                    onLoadedMetadata={(event) => setMediaInfo({ width: event.currentTarget.videoWidth, height: event.currentTarget.videoHeight, duration: event.currentTarget.duration })}
                  />
                ) : (
                  <img
                    src={preview}
                    alt="Preview of the file you picked"
                    onLoad={(event) => setMediaInfo({ width: event.currentTarget.naturalWidth, height: event.currentTarget.naturalHeight })}
                  />
                )}
              </div>
              <div className="upload-file-meta">
                {isVideo ? <FileVideo size={18} /> : <FileImage size={18} />}
                <div>
                  <strong title={form.file.name}>{form.file.name}</strong>
                  <span>{fileFacts.join(" · ")}</span>
                </div>
              </div>
              {tooBig ? (
                <p className="upload-file-error" role="alert">
                  This file is {formatBytes(form.file.size)}, over the {formatBytes(MAX_UPLOAD_BYTES)} upload limit.
                </p>
              ) : null}
              <div className="upload-file-actions">
                <label className={`button-link${uploading ? " is-disabled" : ""}`}>
                  <RefreshCw size={15} />Replace
                  <input type="file" accept="image/*,video/*" disabled={uploading} onChange={(event) => { pickFile(event.target.files?.[0]); event.target.value = ""; }} />
                </label>
                <button type="button" onClick={removeFile} disabled={uploading}><Trash2 size={15} />Remove</button>
              </div>
            </div>
          )}

          {form.file && isVideo ? (
            <ThumbnailChooser
              value={thumbnail}
              onChange={setThumbnail}
              videoRef={previewVideoRef}
              disabled={uploading}
              onError={(message) => ctx.showToast(message, "error")}
            />
          ) : null}

          {form.file ? (
            <div className="upload-batch-queue">
              <div className="upload-batch-head">
                <span>Also uploading {extraFiles.length ? `(${extraFiles.length})` : ""}</span>
                <label className={`button-link${uploading ? " is-disabled" : ""}`}>
                  + Add more files
                  <input type="file" accept="image/*,video/*" multiple disabled={uploading} onChange={(event) => { pickFiles(event.target.files); event.target.value = ""; }} />
                </label>
              </div>
              {extraFiles.length ? (
                <p className="field-hint">
                  These share this form's category, tags, visibility and other settings below — not the title/description above,
                  which only applies to the file shown. Leave "AI metadata" on to have each one titled and tagged individually.
                </p>
              ) : null}
              {extraFiles.length ? (
                <ul className="upload-batch-list">
                  {extraFiles.map((row) => (
                    <li key={row.id} className={`upload-batch-item status-${row.status}`}>
                      {row.file.type.startsWith("video") ? <FileVideo size={15} /> : <FileImage size={15} />}
                      <span className="upload-batch-name" title={row.file.name}>{row.file.name}</span>
                      <span className="upload-batch-size">{formatBytes(row.file.size)}</span>
                      <span className="upload-batch-status">
                        {row.status === "pending" ? "Queued" : null}
                        {row.status === "uploading" ? "Uploading…" : null}
                        {row.status === "done" ? "Done" : null}
                        {row.status === "error" ? (row.error || "Failed") : null}
                      </span>
                      {row.status === "pending" || row.status === "error" ? (
                        <button type="button" className="icon-button" onClick={() => removeExtraFile(row.id)} disabled={uploading} title="Remove">
                          <Trash2 size={14} />
                        </button>
                      ) : null}
                    </li>
                  ))}
                </ul>
              ) : null}
            </div>
          ) : null}

          <section className="upload-ai" aria-label="AI auto-fill">
            <div className="upload-ai-copy">
              <h3><WandSparkles size={16} />AI auto-fill</h3>
              <p>Suggests a title, category, subcategories and tags from the file. Anything you&rsquo;ve already typed is kept.</p>
            </div>
            <button
              type="button"
              onClick={analyze}
              disabled={busy || !form.file || tooBigToAnalyze}
              title={tooBigToAnalyze ? "Too large to analyze here — upload directly instead; AI metadata still runs automatically." : undefined}
            ><WandSparkles size={16} />{analyzing ? "Analyzing…" : "Analyze with AI"}</button>
            {tooBigToAnalyze ? <p className="muted small">This file is too large to analyze before uploading. AI metadata still runs after upload if it&rsquo;s turned on.</p> : null}
            {analysis ? <ChipRow values={analysisChips} /> : null}
            {analysis?.reason ? <p className="muted small">{analysis.reason}</p> : null}
          </section>

          {duplicates.length ? (
            <div className="upload-duplicate-warning" role="alert">
              <p className="small">
                Looks similar to {duplicates.length} post{duplicates.length === 1 ? "" : "s"} already in your library:
              </p>
              <div className="upload-duplicate-thumbs">
                {duplicates.map((dup) => (
                  <Link key={dup.id} to={`/media/${dup.id}`} target="_blank" title={dup.title || `Post #${dup.id}`}>
                    <img src={dup.thumb_url} alt={dup.title || `Post #${dup.id}`} />
                  </Link>
                ))}
              </div>
            </div>
          ) : null}
        </aside>

        <div className="upload-form">
          <section className="upload-section">
            <h2>Details</h2>
            <label className="field">
              <span className="field-head">Title<small aria-hidden="true">{form.title.length}/160</small></span>
              <input value={form.title} onChange={(event) => update("title", event.target.value)} required={!form.auto_ai} maxLength={160} placeholder={form.auto_ai ? "Leave blank to let AI name it" : "Give it a name"} />
            </label>
            <label className="field">
              <span className="field-head">Description<small aria-hidden="true">{form.description.length}/2000</small></span>
              <textarea value={form.description} onChange={(event) => update("description", event.target.value)} rows={4} maxLength={2000} placeholder="Optional" />
            </label>
            <label className="field">
              <span className="field-head">Original source</span>
              <input value={form.source_url} onChange={(event) => update("source_url", event.target.value)} type="url" inputMode="url" maxLength={500} placeholder="https://… where you got this (optional)" />
            </label>
            <label className="field">
              <span>Tags</span>
              <input value={form.tags} onChange={(event) => update("tags", event.target.value)} placeholder="cloud, aria, wallpaper" />
              <small className="field-hint">Separate tags with commas.</small>
            </label>
            {tagList.length ? <ChipRow values={tagList.map((tag) => `#${tag}`)} /> : null}
            <ReuseTagsField currentTags={tagList} onApply={applyPickedTags} />
          </section>

          <section className="upload-section">
            <h2>Where it goes</h2>
            <label className="field">
              <span className="field-head">
                Category
                {form.category.trim() ? <small className={`placement-badge ${matchedCategory ? "is-existing" : "is-new"}`}>{matchedCategory ? "Existing" : "New — created on upload"}</small> : null}
              </span>
              <input
                list="upload-category-options"
                value={form.category}
                onChange={(event) => update("category", event.target.value)}
                placeholder={categories.length ? `e.g. ${categories[0].name}` : "Type a category"}
                autoComplete="off"
              />
              <datalist id="upload-category-options">
                {categories.map((category) => <option key={category.id} value={category.name} />)}
              </datalist>
              <small className="field-hint">Pick an existing category or type a new one.</small>
            </label>
            <div className="upload-subcategories">
              {Array.from({ length: visibleSubcategoryCount(form.subcategories) }, (_, index) => {
                const slot = subcategorySlotMeta(index);
                const text = normalizeSlots(form.subcategories)[index];
                const isExisting = existingSubcategories.some((sub) => sameName(sub.name, text));
                return (
                  <label className="field" key={`subcat-slot-${index}`}>
                    <span className="field-head">
                      {slot.label}
                      {text.trim() ? <small className={`placement-badge ${isExisting ? "is-existing" : "is-new"}`}>{isExisting ? "Existing" : "New"}</small> : null}
                    </span>
                    <input
                      list="upload-subcategory-options"
                      value={text}
                      onChange={(event) => updateSubcategory(index, event.target.value)}
                      placeholder={slot.placeholder}
                      autoComplete="off"
                    />
                  </label>
                );
              })}
              <datalist id="upload-subcategory-options">
                {existingSubcategories.map((sub) => <option key={sub.id} value={sub.name} />)}
              </datalist>
            </div>
            <small className="field-hint">Subcategories are optional. Up to three, from broad to specific.</small>
          </section>

          <section className="upload-section">
            <h2>Visibility &amp; options</h2>
            <div className="field">
              <span>Who can see it</span>
              <Segmented value={form.visibility} onChange={(value) => update("visibility", value)} options={VISIBILITY_OPTIONS} />
              <small className="field-hint">{VISIBILITY_HINTS[form.visibility]}</small>
            </div>
            <label className="field">
              <span>Schedule for later <small>(optional)</small></span>
              <input type="datetime-local" value={form.publish_at} onChange={(event) => update("publish_at", event.target.value)} />
              <small className="field-hint">{form.publish_at ? "It stays hidden until then." : "Leave empty to publish right away."}</small>
            </label>
            <label className="field">
              <span>Self-destruct <small>(optional)</small></span>
              <select value={form.expires_in_hours} onChange={(event) => update("expires_in_hours", event.target.value)}>
                <option value="">Never expires</option>
                <option value="1">1 hour</option>
                <option value="6">6 hours</option>
                <option value="24">24 hours</option>
                <option value="72">3 days</option>
                <option value="168">7 days</option>
              </select>
              <small className="field-hint">{form.expires_in_hours ? "Automatically disappears after this -- works like a story." : "Leave as-is for a permanent post."}</small>
            </label>
            <div className="upload-toggles">
              {OPTION_TOGGLES.map((option) => (
                <label className="upload-toggle" key={option.key}>
                  <span>
                    <strong>{option.label}</strong>
                    <small id={`upload-hint-${option.key}`}>{option.hint}</small>
                  </span>
                  <input
                    type="checkbox"
                    role="switch"
                    aria-label={option.label}
                    aria-describedby={`upload-hint-${option.key}`}
                    checked={form[option.key]}
                    onChange={(event) => update(option.key, event.target.checked)}
                  />
                </label>
              ))}
            </div>
          </section>

          <div className="upload-actionbar">
            <div className="upload-status">
              <span className={tooBig ? "is-error" : ""}>{status}</span>
              {processing ? (
                <div className="upload-progress-track is-indeterminate" role="progressbar" aria-label="Processing">
                  <div className="upload-progress-fill" />
                </div>
              ) : uploading && uploadProgress > 0 ? (
                <div className="upload-progress-track" role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={uploadProgress} aria-label="Upload progress">
                  <div className="upload-progress-fill" style={{ width: `${uploadProgress}%` }} />
                </div>
              ) : null}
            </div>
            {processing ? (
              <button type="button" onClick={() => handOffFollowedJob(true)}>Continue in background</button>
            ) : uploading ? (
              <button type="button" onClick={cancelUpload}><X size={16} />Cancel</button>
            ) : null}
            <button className="primary" type="submit" disabled={busy || !form.file || tooBig}>
              <Upload size={16} />{processing ? "Processing" : uploading ? "Uploading" : "Upload"}
            </button>
          </div>
        </div>
      </form>
    </Page>
  );
}
