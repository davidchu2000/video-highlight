#!/usr/bin/env bash
set -eu -o pipefail

# detect_scenes.sh (NVDEC auto-detect)
# Usage: ./detect_scenes.sh input.mp4 [outdir]
# Attempt CUVID decode based on the input codec, fallback to CPU decode.

in="$1"
outdir="${2:-.}"
mkdir -p "$outdir"
sc_log="$outdir/scenes.log"
: > "$sc_log"

# get codec name
codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$in" || true)
codec=${codec:-}

dec=""
case "$codec" in
  h264) dec=h264_cuvid ;;
  hevc|h265) dec=hevc_cuvid ;;
  mpeg2video) dec=mpeg2_cuvid ;;
  mpeg4) dec=mpeg4_cuvid ;;
  mjpeg) dec=mjpeg_cuvid ;;
  vp9) dec=vp9_cuvid ;;
  av1) dec=av1_cuvid ;;
  *) dec="" ;;
esac

if [ -n "$dec" ] && command -v nvidia-smi >/dev/null 2>&1; then
  echo "Trying CUVID decoder: $dec" >&2
  if ffmpeg -hide_banner -nostats -c:v "$dec" -i "$in" -vf "select='gt(scene,0.0)',metadata=print" -an -f null - 2> "$sc_log"; then
    echo "Detection complete (CUVID decode used)." >&2
  else
    echo "CUVID decode failed; falling back to CPU decode." >&2
    ffmpeg -hide_banner -nostats -i "$in" -vf "select='gt(scene,0.0)',metadata=print" -an -f null - 2> "$sc_log"
  fi
else
  echo "CUVID not used (no matching decoder or no NVIDIA). Using CPU decode." >&2
  ffmpeg -hide_banner -nostats -i "$in" -vf "select='gt(scene,0.0)',metadata=print" -an -f null - 2> "$sc_log"
fi

# Print first 200 relevant lines for inspection
grep -E "pts_time|lavfi.scene_score" "$sc_log" | sed -n '1,200p'

echo "scenes log written to: $sc_log"