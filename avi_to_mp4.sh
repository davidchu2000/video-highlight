#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 input.avi"
  exit 1
fi

in="$1"
if [ ! -f "$in" ]; then
  echo "Input not found: $in"
  exit 1
fi

src_dir="$(dirname "$in")"
base_name="$(basename "$in")"
base_stem="${base_name%.*}"
out="$src_dir/${base_stem}.mp4"
linux_stage_dir="/home/davidchu2000/video-highlight/out"
log_dir="/home/davidchu2000/video-highlight/logs"
tmp_out="$linux_stage_dir/${base_stem}.partial.mp4"
final_stage="$linux_stage_dir/${base_stem}.mp4"
log_file="$log_dir/avi_to_mp4_${base_stem}.log"

mkdir -p "$linux_stage_dir" "$log_dir"
rm -f "$tmp_out"

cleanup() {
  rm -f "$tmp_out"
}
trap cleanup INT TERM

exec > >(tee "$log_file") 2>&1

echo "Input: $in"
echo "Staging output: $final_stage"
echo "Final output: $out"
echo "Log: $log_file"

COMMON_INPUT=(
  -hide_banner -y
  -err_detect ignore_err
  -fflags +genpts+discardcorrupt
  -i "$in"
  -map 0:v:0 -map 0:a?
  -vsync cfr
)

COMMON_OUTPUT=(
  -movflags +faststart
  -c:a aac -b:a 160k -ar 48000 -ac 2
  "$tmp_out"
)

encoder_used=""

encode_nvenc() {
  echo "Trying NVIDIA NVENC..."
  ffmpeg "${COMMON_INPUT[@]}" \
    -c:v h264_nvenc -preset p5 -cq 23 \
    -profile:v main -level 3.1 \
    -pix_fmt yuv420p \
    "${COMMON_OUTPUT[@]}"
  encoder_used="gpu:nvenc"
}

encode_cpu() {
  echo "Falling back to CPU libx264..."
  ffmpeg "${COMMON_INPUT[@]}" \
    -c:v libx264 -preset medium -crf 20 \
    -profile:v main -level 3.1 \
    -x264-params ref=1:bframes=0:weightp=0:cabac=1 \
    -pix_fmt yuv420p \
    "${COMMON_OUTPUT[@]}"
  encoder_used="cpu:libx264"
}

if ! encode_nvenc; then
  echo "NVENC failed. Cleaning up partial output and retrying on CPU."
  rm -f "$tmp_out"
  encode_cpu
fi

mv -f "$tmp_out" "$final_stage"
cp -f "$final_stage" "$out"

echo "Encoder used: $encoder_used"
echo "Done: $out"
trap - INT TERM
