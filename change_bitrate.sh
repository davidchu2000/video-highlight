#!/usr/bin/env bash
set -eu -o pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $(basename "$0") <input-video> <bitrate>" >&2
  echo "Example: $(basename "$0") /path/video.mp4 1200k" >&2
  exit 1
fi

in="$1"
video_bitrate="$2"

if [ ! -f "$in" ]; then
  echo "Input file not found: $in" >&2
  exit 1
fi

case "$video_bitrate" in
  *[kKmM]) ;;
  *[0-9]) ;;
  *)
    echo "Invalid bitrate: $video_bitrate" >&2
    echo "Use values like 800k, 1200k, 2M, or 1500000" >&2
    exit 1
    ;;
esac

input_dir="$(dirname "$in")"
input_name="$(basename "$in")"
base_name="${input_name%.*}"
ext="${input_name##*.}"
if [ "$base_name" = "$input_name" ]; then
  ext="mp4"
fi

safe_bitrate="$(printf '%s' "$video_bitrate" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')"
out="$input_dir/${base_name}_${safe_bitrate}.${ext}"
staging_dir="/home/davidchu2000/video-highlight/out"
mkdir -p "$staging_dir"
staged_out="$staging_dir/${base_name}_${safe_bitrate}.${ext}"

input_audio_bitrate=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$in" || true)
input_audio_bitrate=${input_audio_bitrate:-0}
if ! [[ "$input_audio_bitrate" =~ ^[0-9]+$ ]]; then
  input_audio_bitrate=0
fi

audio_bitrate=128k
if [ "$input_audio_bitrate" -gt 0 ] && [ "$input_audio_bitrate" -lt 128000 ]; then
  audio_bitrate="$input_audio_bitrate"
fi
if [[ "$audio_bitrate" =~ ^[0-9]+$ ]] && [ "$audio_bitrate" -lt 64000 ]; then
  audio_bitrate=64000
fi

if ffmpeg -y -i "$in" \
  -c:v h264_nvenc -preset p5 -rc vbr_hq -b:v "$video_bitrate" -maxrate "$video_bitrate" -bufsize "$video_bitrate" \
  -c:a aac -b:a "$audio_bitrate" \
  "$staged_out"; then
  echo "Encoded with NVENC"
else
  echo "NVENC failed, falling back to libx264" >&2
  ffmpeg -y -i "$in" \
    -c:v libx264 -preset slow -b:v "$video_bitrate" -maxrate "$video_bitrate" -bufsize "$video_bitrate" \
    -c:a aac -b:a "$audio_bitrate" \
    "$staged_out"
  echo "Encoded with libx264"
fi

cp -f "$staged_out" "$out"

echo "Created: $out"
echo "Staged copy kept at: $staged_out"
