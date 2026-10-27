import { useEffect, useRef, useState } from "react";
import { Camera, ImagePlus, RotateCcw, Trash2 } from "lucide-react";
import { apiFetch, clearApiCache } from "../api.js";
import { thumbUrl } from "../utils/media.js";

const SERVER_TYPES = ["image/jpeg", "image/png", "image/webp", "image/gif"];
const MAX_BYTES = 15 * 1024 * 1024;
const MAX_EDGE = 3840;

function canvasToJpeg(canvas) {
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error("Could not encode the image."))), "image/jpeg", 0.9);
  });
}

function drawScaled(source, width, height) {
  const scale = Math.min(1, MAX_EDGE / Math.max(width, height));
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.round(width * scale));
  canvas.height = Math.max(1, Math.round(height * scale));
  canvas.getContext("2d").drawImage(source, 0, 0, canvas.width, canvas.height);
  return canvas;
}

// Phones hand over whatever the gallery holds -- often HEIC from an iPhone,
// sometimes a 40MB panorama. The server takes JPEG/PNG/WEBP/GIF up to
// 15MB, so anything else is decoded by the browser and re-encoded as JPEG
// (largest side capped at 3840px) before it is sent.
export async function normalizeThumbnailFile(file) {
  if (SERVER_TYPES.includes(file.type) && file.size <= MAX_BYTES) return file;
  let bitmap;
  try {
    bitmap = await createImageBitmap(file);
  } catch (_error) {
    throw new Error("That image format isn't supported here. Try a JPEG or PNG.");
  }
  const canvas = drawScaled(bitmap, bitmap.width, bitmap.height);
  bitmap.close?.();
  return canvasToJpeg(canvas);
}

// The frame the uploader paused the preview on, as a JPEG.
export async function captureVideoFrame(video) {
  if (!video || !video.videoWidth) throw new Error("Play or scrub the video preview to a frame first.");
  return canvasToJpeg(drawScaled(video, video.videoWidth, video.videoHeight));
}

function useObjectUrl(blob) {
  const [url, setUrl] = useState("");
  useEffect(() => {
    if (!blob) { setUrl(""); return undefined; }
    const next = URL.createObjectURL(blob);
    setUrl(next);
    return () => URL.revokeObjectURL(next);
  }, [blob]);
  return url;
}

function ImageInputButton({ label, disabled, onFile }) {
  const inputRef = useRef(null);
  return (
    <label className={`button-link${disabled ? " is-disabled" : ""}`}>
      <ImagePlus size={15} />{label}
      {/* image/* lets phones offer the photo library and the camera. */}
      <input
        ref={inputRef}
        type="file"
        accept="image/*"
        disabled={disabled}
        onChange={(event) => {
          const file = event.target.files?.[0];
          event.target.value = "";
          if (file) onFile(file);
        }}
      />
    </label>
  );
}

// Upload form: choose the thumbnail for the video being uploaded. `value`
// is a Blob (or null for automatic); the form sends it with the upload.
export function ThumbnailChooser({ value, onChange, videoRef, disabled = false, onError }) {
  const previewUrl = useObjectUrl(value);
  const [working, setWorking] = useState(false);

  async function take(promise) {
    setWorking(true);
    try {
      onChange(await promise);
    } catch (error) {
      onError?.(error.message || "Could not use that image.");
    } finally {
      setWorking(false);
    }
  }

  return (
    <section className="thumb-chooser" aria-label="Video thumbnail">
      <div className="thumb-chooser-preview">
        {previewUrl ? <img src={previewUrl} alt="Chosen thumbnail" /> : <span>Automatic<br /><small>a frame from the video</small></span>}
      </div>
      <div className="thumb-chooser-body">
        <h3>Thumbnail</h3>
        <p className="muted small">
          {value ? "This image is shown on the video's card and player." : "Pick an image from your device, or pause the preview on a frame you like."}
        </p>
        <div className="thumb-chooser-actions">
          <ImageInputButton label={value ? "Change image" : "Choose image"} disabled={disabled || working} onFile={(file) => take(normalizeThumbnailFile(file))} />
          {videoRef ? (
            <button type="button" disabled={disabled || working} onClick={() => take(captureVideoFrame(videoRef.current))}>
              <Camera size={15} />Use current frame
            </button>
          ) : null}
          {value ? (
            <button type="button" disabled={disabled || working} onClick={() => onChange(null)}><Trash2 size={15} />Use automatic</button>
          ) : null}
        </div>
      </div>
    </section>
  );
}

// Sends a chosen thumbnail ahead of the upload; resolves to the token the
// upload passes along (see stage_upload_thumbnail in routes.lua).
export async function stageThumbnail(blob) {
  const body = new FormData();
  body.set("file", blob, "thumbnail.jpg");
  const data = await apiFetch("/api/media/upload/thumbnail", { method: "POST", body, timeoutMs: 60_000 });
  return data.thumbnail_token;
}

// Post editor: change or reset an existing video's thumbnail right away.
export function EditThumbnailPanel({ ctx, media, onChanged }) {
  const [busy, setBusy] = useState(false);
  if (media?.media_kind !== "video") return null;

  async function run(request, done) {
    setBusy(true);
    try {
      const data = await request();
      clearApiCache();
      onChanged?.(data.media);
      ctx.showToast(done, "success");
    } catch (error) {
      ctx.showToast(error.message || "Could not update the thumbnail.", "error");
    } finally {
      setBusy(false);
    }
  }

  async function upload(file) {
    let blob;
    try {
      blob = await normalizeThumbnailFile(file);
    } catch (error) {
      ctx.showToast(error.message, "error");
      return;
    }
    const body = new FormData();
    body.set("file", blob, "thumbnail.jpg");
    run(() => apiFetch(`/api/media/${media.id}/thumbnail`, { method: "POST", body, timeoutMs: 60_000 }), "Thumbnail updated.");
  }

  return (
    <div className="field thumb-edit">
      <span className="field-head">Thumbnail{media.has_custom_thumbnail ? <small className="placement-badge is-existing">Custom</small> : <small className="placement-badge">Automatic</small>}</span>
      <div className="thumb-edit-row">
        <img className="thumb-edit-preview" src={thumbUrl(media, 640)} alt="Current thumbnail" />
        <div className="thumb-chooser-actions">
          <ImageInputButton label={busy ? "Uploading…" : "Upload image"} disabled={busy} onFile={upload} />
          {media.has_custom_thumbnail ? (
            <button
              type="button"
              disabled={busy}
              onClick={() => run(() => apiFetch(`/api/media/${media.id}/thumbnail`, { method: "DELETE" }), "Thumbnail reset to automatic.")}
            ><RotateCcw size={15} />Use automatic</button>
          ) : null}
        </div>
      </div>
    </div>
  );
}
