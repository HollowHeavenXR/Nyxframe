#!/bin/sh
# Runs GALLERY_WORKERS backend workers plus proxy.lua in one container
# (2026-10-26). Each worker is single-threaded, so one slow request (ffmpeg,
# a big file read) used to freeze the whole site; the proxy sends each new
# connection to the least-busy worker instead.
#
#   public port  GALLERY_HTTP_PORT (default 8788)  -> proxy.lua
#   workers      127.0.0.1:GALLERY_WORKER_BASE_PORT.. (default 8790..)
#   background jobs run only on the first worker (GALLERY_PRIMARY_WORKER_PORT)
#
# GALLERY_WORKERS=1 falls back to the old single-process mode.
set -u
cd "$(dirname "$0")"

N=${GALLERY_WORKERS:-4}
PUBLIC_PORT=${GALLERY_HTTP_PORT:-8788}
PUBLIC_HOST=${GALLERY_HTTP_HOST:-0.0.0.0}
BASE=${GALLERY_WORKER_BASE_PORT:-8790}

if [ "$N" -le 1 ]; then
  exec luajit main.lua
fi

# A container (re)start kills every ffmpeg, so transcode claims and
# "render in progress" markers left on disk are all stale. Left alone they
# blocked video playback ("server is busy transcoding") for up to 30 min
# after every deploy. Cleared here, before any worker can make new ones.
UP=${GALLERY_UPLOADS_DIR:-../uploads}
rm -f "$UP"/_transcode_slots/* "$UP"/_hls_cache/*.pending "$UP"/_video_cache/*.pending 2>/dev/null
find "$UP/_thumb_cache" "$UP/_preview_cache" -maxdepth 2 -name '*.pending' -delete 2>/dev/null

backends=""
i=0
while [ "$i" -lt "$N" ]; do
  port=$((BASE + i))
  backends="${backends:+$backends,}127.0.0.1:$port"
  (
    # Restart a crashed worker instead of losing its share of capacity.
    while true; do
      GALLERY_HTTP_HOST=127.0.0.1 GALLERY_HTTP_PORT=$port GALLERY_PRIMARY_WORKER_PORT=$BASE \
        GALLERY_WORKER_ID=$i luajit main.lua
      echo "[nyxframe-workers] worker $i (port $port) exited with $?; restarting in 2s"
      sleep 2
    done
  ) &
  i=$((i + 1))
done

echo "[nyxframe-workers] started $N workers: $backends"
GALLERY_PROXY_HOST=$PUBLIC_HOST GALLERY_PROXY_PORT=$PUBLIC_PORT GALLERY_PROXY_BACKENDS=$backends \
  exec luajit proxy.lua
