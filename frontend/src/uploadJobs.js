// Tracks background upload jobs (see upload_chunk_finish/upload_job_status
// in routes.lua) across page navigation -- once /api/media/upload/finish
// hands back a job_id instead of blocking until done, the uploader is free
// to leave the page entirely, so "what's still processing" has to survive
// in something other than component state. localStorage, not the API cache
// helpers in api.js: this needs to persist across a full page reload too.
const STORAGE_KEY = "image_gallery_pending_upload_jobs";

export function getPendingUploadJobs() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    const parsed = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed) ? parsed : [];
  } catch (_error) {
    return [];
  }
}

function writePendingUploadJobs(jobs) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(jobs));
  } catch (_error) {
    // Storage can be unavailable in hardened browser contexts.
  }
}

export function addPendingUploadJob({ jobId, filename }) {
  const jobs = getPendingUploadJobs().filter((job) => job.jobId !== jobId);
  jobs.push({ jobId, filename, queuedAt: Date.now() });
  writePendingUploadJobs(jobs);
}

export function removePendingUploadJob(jobId) {
  writePendingUploadJobs(getPendingUploadJobs().filter((job) => job.jobId !== jobId));
}

// Human-readable text for a background upload job's `stage` (see
// upload_job_status in routes.lua).
const STAGE_TEXT = {
  queued: "Waiting for a free processing slot…",
  starting: "Processing…",
  optimizing: "Optimizing video for streaming…",
  analyzing: "Filling in title and tags with AI…",
  fingerprinting: "Checking for duplicates…",
  saving: "Saving…",
  finishing: "Almost done…",
  retrying: "Hit a snag — retrying…",
};

export function describeUploadStage(stage) {
  return STAGE_TEXT[stage] || "Processing…";
}
