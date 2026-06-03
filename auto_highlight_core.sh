#!/usr/bin/env bash
set -eu -o pipefail
VERSION=debug_1776929525
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Shared implementation for auto_highlight entrypoints.
# Key env knobs:
#   KEEP_DEBUG=1 keep intermediates under debug_<ts>/; 0 uses tmpdir and cleans up
#   TARGET=300.0 target total highlight length in seconds
#   SCENE_THRESH=<auto|0.10-ish> lower = more scene cuts; auto-tuned by density_tune.sh if unset
#   LOW_CONTENT_ENABLE=0 enable near-static/low-variance segment filtering
#   LOW_CONTENT_MIN_DUR=1.0 minimum seconds before low-content filtering rejects a span
# Bitrate: output tries to follow source bitrate, with low-res caps and 400k..2.5M video clamps.

SCENE_THRESH=${SCENE_THRESH:-}
PAD=${PAD:-0.5}
MERGE_GAP=${MERGE_GAP:-1.0}
MIN_CLIP=${MIN_CLIP:-5.0}
END_TRIM=${END_TRIM:-10.0}
TARGET=${TARGET:-300.0}
KEEP_DEBUG=${KEEP_DEBUG:-1}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $(basename "$0") input.mp4 [output.mp4]" >&2
  exit 1
fi

in="$1"
debug_ts_epoch="$(date +%s)"

if [ "$#" -ge 2 ]; then
  out="$2"
else
  in_dir="$(dirname "$in")"
  in_base="$(basename "$in")"
  if [ "$KEEP_DEBUG" = "1" ]; then
    out="$in_dir/hl_${debug_ts_epoch}_${in_base}"
  else
    out="$in_dir/hl_${in_base}"
  fi
fi

if [ "$KEEP_DEBUG" = "1" ]; then
  debug_root="/home/davidchu2000/video-highlight/debug_${debug_ts_epoch}"
  mkdir -p "$debug_root"
  tmpdir="$debug_root/tmp"
else
  tmpdir="$(mktemp -d)"
fi

sc_log="$tmpdir/scenes.log"
clips_dir="$tmpdir/clips"
merged_file="$tmpdir/merged_clips.csv"
list_file="$tmpdir/concat_list.txt"

mkdir -p "$clips_dir"
: > "$sc_log"

if [ -z "$SCENE_THRESH" ]; then
  tuner="$SCRIPT_DIR/density_tune.sh"
  if [ -x "$tuner" ]; then
    if SCENE_THRESH="$($tuner "$in" 2> >(cat >&2))" && [ -n "$SCENE_THRESH" ]; then
      echo "Auto-tuned SCENE_THRESH=$SCENE_THRESH" >&2
    else
      SCENE_THRESH=0.10
      echo "density_tune.sh failed; falling back to SCENE_THRESH=$SCENE_THRESH" >&2
    fi
  else
    SCENE_THRESH=0.10
    echo "density_tune.sh not found; using default SCENE_THRESH=$SCENE_THRESH" >&2
  fi
fi

# Duration
duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$in")
duration=${duration:-0}

# Source bitrate-aware encode targets (avoid inflating low-bitrate sources)
input_width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$in" || true)
input_height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$in" || true)
input_video_bitrate=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$in" || true)
input_audio_bitrate=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$in" || true)
input_format_bitrate=$(ffprobe -v error -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$in" || true)
input_width=${input_width:-0}
input_height=${input_height:-0}
input_video_bitrate=${input_video_bitrate:-0}
input_audio_bitrate=${input_audio_bitrate:-0}
input_format_bitrate=${input_format_bitrate:-0}

if ! [[ "$input_width" =~ ^[0-9]+$ ]]; then input_width=0; fi
if ! [[ "$input_height" =~ ^[0-9]+$ ]]; then input_height=0; fi
if ! [[ "$input_video_bitrate" =~ ^[0-9]+$ ]]; then input_video_bitrate=0; fi
if ! [[ "$input_audio_bitrate" =~ ^[0-9]+$ ]]; then input_audio_bitrate=0; fi
if ! [[ "$input_format_bitrate" =~ ^[0-9]+$ ]]; then input_format_bitrate=0; fi

if [ "$input_video_bitrate" -le 0 ] && [ "$input_format_bitrate" -gt 0 ]; then
  if [ "$input_audio_bitrate" -gt 0 ] && [ "$input_format_bitrate" -gt "$input_audio_bitrate" ]; then
    input_video_bitrate=$((input_format_bitrate - input_audio_bitrate))
  else
    input_video_bitrate=$input_format_bitrate
  fi
fi

if [ "$input_audio_bitrate" -le 0 ]; then
  input_audio_bitrate=128000
fi

# Resolution-based caps for low-res tape sources
resolution_cap=0
if [ "$input_width" -gt 0 ] && [ "$input_height" -gt 0 ]; then
  if [ "$input_width" -le 640 ] && [ "$input_height" -le 480 ]; then
    resolution_cap=500000
  elif [ "$input_width" -le 720 ] && [ "$input_height" -le 480 ]; then
    resolution_cap=700000
  fi
fi

if [ "$input_video_bitrate" -le 0 ]; then
  target_video_bitrate=1200000
else
  target_video_bitrate=$input_video_bitrate
fi

if [ "$resolution_cap" -gt 0 ] && [ "$target_video_bitrate" -gt "$resolution_cap" ]; then
  target_video_bitrate=$resolution_cap
fi

if [ "$target_video_bitrate" -lt 400000 ]; then
  target_video_bitrate=400000
fi
if [ "$target_video_bitrate" -gt 2500000 ]; then
  target_video_bitrate=2500000
fi

if [ "$input_video_bitrate" -gt 0 ]; then
  max_video_bitrate=$((input_video_bitrate * 12 / 10))
else
  max_video_bitrate=$((target_video_bitrate * 12 / 10))
fi
if [ "$resolution_cap" -gt 0 ] && [ "$max_video_bitrate" -gt "$resolution_cap" ]; then
  max_video_bitrate=$resolution_cap
fi
if [ "$max_video_bitrate" -lt "$target_video_bitrate" ]; then
  max_video_bitrate=$target_video_bitrate
fi
bufsize=$((max_video_bitrate * 2))
audio_bitrate=128000
if [ "$input_audio_bitrate" -gt 0 ] && [ "$input_audio_bitrate" -lt 128000 ]; then
  audio_bitrate=$input_audio_bitrate
fi
if [ "$audio_bitrate" -lt 64000 ]; then
  audio_bitrate=64000
fi

echo "Input video: ${input_width}x${input_height}" >&2
echo "Input bitrate: video=${input_video_bitrate} audio=${input_audio_bitrate} format=${input_format_bitrate}" >&2
echo "Encode target: video=${target_video_bitrate} max=${max_video_bitrate} bufsize=${bufsize} audio=${audio_bitrate} resolution_cap=${resolution_cap}" >&2

# Detect codec
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

# Scene detection
if [ -n "$dec" ]; then
  if ffmpeg -hide_banner -nostats -c:v "$dec" -i "$in" -vf "select='gt(scene,${SCENE_THRESH})',metadata=print" -an -f null - > /dev/null 2> "$sc_log"; then
    true
  else
    ffmpeg -hide_banner -nostats -i "$in" -vf "select='gt(scene,${SCENE_THRESH})',metadata=print" -an -f null - > /dev/null 2> "$sc_log"
  fi
else
  ffmpeg -hide_banner -nostats -i "$in" -vf "select='gt(scene,${SCENE_THRESH})',metadata=print" -an -f null - > /dev/null 2> "$sc_log"
fi

# Black detection prepass
BLACK_MIN_DUR=${BLACK_MIN_DUR:-2.0}
BLACK_PIXEL_THRESH=${BLACK_PIXEL_THRESH:-0.98}
BLACK_LUMA_THRESH=${BLACK_LUMA_THRESH:-0.10}
black_log="$tmpdir/blackdetect.log"
black_file="$tmpdir/black_ranges.csv"
ffmpeg -hide_banner -nostats -i "$in" -vf "blackdetect=d=${BLACK_MIN_DUR}:pic_th=${BLACK_PIXEL_THRESH}:pix_th=${BLACK_LUMA_THRESH}" -an -f null - > /dev/null 2> "$black_log" || true
awk '
/black_start:/ {
  bs=""; be=""; bd="";
  for(i=1;i<=NF;i++){
    if($i ~ /black_start:/){ split($i,a,":"); bs=a[2] }
    if($i ~ /black_end:/){ split($i,a,":"); be=a[2] }
    if($i ~ /black_duration:/){ split($i,a,":"); bd=a[2] }
  }
  if(bs!="" && be!="" && bd!="") printf "%.3f,%.3f,%.3f\n", bs, be, bd
}
' "$black_log" > "$black_file"

# Non-dark low-content detection prepass (near-solid / low-variance picture)
LOW_CONTENT_ENABLE=${LOW_CONTENT_ENABLE:-0}
LOW_CONTENT_MIN_DUR=${LOW_CONTENT_MIN_DUR:-1.0}
LOW_CONTENT_YDIF_AVG_MAX=${LOW_CONTENT_YDIF_AVG_MAX:-1.2}
LOW_CONTENT_YDIF_MAX_MAX=${LOW_CONTENT_YDIF_MAX_MAX:-8.0}
low_content_file="$tmpdir/low_content_ranges.csv"
: > "$low_content_file"
if [ "$LOW_CONTENT_ENABLE" = "1" ]; then
  stats_log="$tmpdir/signalstats.log"
  ffmpeg -hide_banner -nostats -i "$in" -vf "signalstats,metadata=print" -an -f null - > /dev/null 2> "$stats_log" || true
  awk -F= -v minDur="$LOW_CONTENT_MIN_DUR" -v yavgMax="$LOW_CONTENT_YDIF_AVG_MAX" -v ymaxDiffMax="$LOW_CONTENT_YDIF_MAX_MAX" '
    function flush_run() {
      if (in_run) {
        dur = prev_t - run_start;
        if (dur >= minDur) printf "%.3f,%.3f,%.3f\n", run_start, prev_t, dur;
      }
      in_run=0;
    }
    /pts_time:/ {
      split($0,a,"pts_time:");
      split(a[2],b," ");
      t=b[1]+0;
    }
    /lavfi.signalstats.YDIF=/ {
      ydif=$2+0;
    }
    /lavfi.signalstats.YMAX=/ {
      ymax=$2+0;
    }
    /lavfi.signalstats.YMIN=/ {
      ymin=$2+0;
      yspan=ymax-ymin;
      is_low = (ydif <= yavgMax && yspan <= ymaxDiffMax) ? 1 : 0;
      if (is_low) {
        if (!in_run) {
          run_start=t;
          in_run=1;
        }
      } else {
        flush_run();
      }
      prev_t=t;
    }
    END { flush_run() }
  ' "$stats_log" > "$low_content_file"
fi

# Parse to time_score.csv
awk '
/pts_time:/ {
  for(i=1;i<=NF;i++){
    if($i ~ /pts_time:/){
      split($i,a,":");
      t=a[2];
      if(t=="") t=$(i+1);
      gsub(/[^0-9.]/,"",t);
      print t
    }
  }
}
/lavfi.scene_score=/ {
  for(i=1;i<=NF;i++){
    if($i ~ /lavfi.scene_score=/){
      split($i,a,"=");
      s=a[2];
      gsub(/[^0-9.]/,"",s);
      print "SCORE:" s
    }
  }
}
' "$sc_log" > "$tmpdir/parsed.lst"

: > "$tmpdir/time_score.csv"
last_score=""
while IFS= read -r line; do
  if [[ "$line" == SCORE:* ]]; then
    last_score="${line#SCORE:}"
  else
    time=$(printf "%.3f" "$line")
    if [[ -z "$last_score" ]]; then last_score=1.0; fi
    printf "%s,%s\n" "$time" "$last_score" >> "$tmpdir/time_score.csv"
    last_score=""
  fi
done < "$tmpdir/parsed.lst" || true

# fallback
if [[ ! -s "$tmpdir/time_score.csv" ]]; then
  step=15
  t=15
  while (( $(echo "$t < $duration" | bc -l) )); do
    printf "%s,1.0\n" "$(printf "%.3f" "$t")" >> "$tmpdir/time_score.csv"
    t=$(echo "$t + $step" | bc)
  done
fi

# Build raw clips
content_end=$(echo "$duration - $END_TRIM" | bc -l)
if (( $(echo "$content_end < 0" | bc -l) )); then content_end=0; fi
MAX_RAW_CLIP=${MAX_RAW_CLIP:-120.0}
prev=0
: > "$tmpdir/raw_clips.csv"
while IFS= read -r line; do
  time=$(echo "$line" | cut -d, -f1)
  score=$(echo "$line" | cut -d, -f2)
  if (( $(echo "$time > $content_end" | bc -l) )); then
    break
  fi
  if (( $(echo "$time > $prev" | bc -l) )); then
    start="$prev"
    end="$time"
    dur=$(echo "$end - $start" | bc -l)
    overlaps_black=0
    if [ -s "$black_file" ]; then
      overlaps_black=$(awk -F, -v s="$start" -v e="$end" '
        BEGIN{ hit=0 }
        {
          bs=$1; be=$2;
          overlap = ((e < be ? e : be) - (s > bs ? s : bs));
          if (overlap > 0.5) { hit=1; exit }
        }
        END{ print hit }
      ' "$black_file")
    fi
    overlaps_low_content=0
    if [ -s "$low_content_file" ]; then
      overlaps_low_content=$(awk -F, -v s="$start" -v e="$end" '
        BEGIN{ hit=0 }
        {
          ls=$1; le=$2;
          overlap = ((e < le ? e : le) - (s > ls ? s : ls));
          if (overlap > 0.5) { hit=1; exit }
        }
        END{ print hit }
      ' "$low_content_file")
    fi
    if (( $(echo "$dur >= 0.05 && $dur <= $MAX_RAW_CLIP" | bc -l) )) && [ "$overlaps_black" = "0" ] && [ "$overlaps_low_content" = "0" ]; then
      printf "%s,%s,%.6f\n" "$start" "$end" "$score" >> "$tmpdir/raw_clips.csv"
    fi
    prev="$time"
  fi
done < "$tmpdir/time_score.csv"

last_start="$prev"
FINAL_TAIL_SCORE=${FINAL_TAIL_SCORE:-0.05}
final_tail_dur=$(echo "$content_end - $last_start" | bc -l)
final_tail_overlaps_black=0
if [ -s "$black_file" ]; then
  final_tail_overlaps_black=$(awk -F, -v s="$last_start" -v e="$content_end" '
    BEGIN{ hit=0 }
    {
      bs=$1; be=$2;
      overlap = ((e < be ? e : be) - (s > bs ? s : bs));
      if (overlap > 0.5) { hit=1; exit }
    }
    END{ print hit }
  ' "$black_file")
fi
final_tail_overlaps_low_content=0
if [ -s "$low_content_file" ]; then
  final_tail_overlaps_low_content=$(awk -F, -v s="$last_start" -v e="$content_end" '
    BEGIN{ hit=0 }
    {
      ls=$1; le=$2;
      overlap = ((e < le ? e : le) - (s > ls ? s : ls));
      if (overlap > 0.5) { hit=1; exit }
    }
    END{ print hit }
  ' "$low_content_file")
fi
if (( $(echo "$content_end > $last_start && $final_tail_dur <= $MAX_RAW_CLIP" | bc -l) )) && [ "$final_tail_overlaps_black" = "0" ] && [ "$final_tail_overlaps_low_content" = "0" ]; then
  printf "%s,%s,%.6f\n" "$last_start" "$content_end" "$FINAL_TAIL_SCORE" >> "$tmpdir/raw_clips.csv"
fi

# Score and select
: > "$tmpdir/scored.csv"
idx=0
while IFS=, read -r s e sc; do
  dur=$(echo "$e - $s" | bc -l)
  if (( $(echo "$dur >= $MIN_CLIP" | bc -l) )); then
    score=$(echo "$dur * $sc" | bc -l)
    idx=$((idx+1))
    printf "%d,%.3f,%.3f,%.3f,%.6f\n" "$idx" "$s" "$e" "$dur" "$score" >> "$tmpdir/scored.csv"
  fi
done < "$tmpdir/raw_clips.csv"

sort -t, -k5 -nr "$tmpdir/scored.csv" > "$tmpdir/sorted.csv" || true
sort -t, -k2 -n "$tmpdir/scored.csv" > "$tmpdir/timeline_scored.csv" || true
: > "$tmpdir/selected.csv"
total=0

# pass 1: best-scoring clips first
while IFS=, read -r idx s e dur sc; do
  if (( $(echo "$total >= $TARGET" | bc -l) )); then break; fi
  printf "%s,%.3f,%.3f,%.3f\n" "$idx" "$s" "$e" "$dur" >> "$tmpdir/selected.csv"
  total=$(echo "$total + $dur" | bc -l)
done < "$tmpdir/sorted.csv"

# pass 2: timeline backfill to reach target more reliably with still-valid clips
BACKFILL_MIN_SCORE=${BACKFILL_MIN_SCORE:-0.03}
if (( $(echo "$total < $TARGET" | bc -l) )); then
  while IFS=, read -r idx s e dur sc; do
    if grep -q "^$idx," "$tmpdir/selected.csv"; then
      continue
    fi
    if (( $(echo "$sc < $BACKFILL_MIN_SCORE" | bc -l) )); then
      continue
    fi
    printf "%s,%.3f,%.3f,%.3f\n" "$idx" "$s" "$e" "$dur" >> "$tmpdir/selected.csv"
    total=$(echo "$total + $dur" | bc -l)
    if (( $(echo "$total >= $TARGET" | bc -l) )); then break; fi
  done < "$tmpdir/timeline_scored.csv"
fi

# pass 3: if still short, take any remaining valid clips chronologically
if (( $(echo "$total < $TARGET" | bc -l) )); then
  while IFS=, read -r idx s e dur sc; do
    if grep -q "^$idx," "$tmpdir/selected.csv"; then
      continue
    fi
    printf "%s,%.3f,%.3f,%.3f\n" "$idx" "$s" "$e" "$dur" >> "$tmpdir/selected.csv"
    total=$(echo "$total + $dur" | bc -l)
    if (( $(echo "$total >= $TARGET" | bc -l) )); then break; fi
  done < "$tmpdir/timeline_scored.csv"
fi

# pad & merge
awk -v pad="$PAD" -v dur="$duration" -F, '{ s=$2-pad; if(s<0) s=0; e=$3+pad; if(e>dur) e=dur; printf "%.6f %.6f\n", s, e }' "$tmpdir/selected.csv" | sort -n -k1,1 > "$tmpdir/padded_sorted.txt"
awk -v gap="$MERGE_GAP" '
BEGIN { prev_s=""; prev_e="" }
{
  s=$1; e=$2;
  if(prev_s=="") { prev_s=s; prev_e=e; next }
  if(s <= prev_e + gap) {
    if(e>prev_e) prev_e=e
  } else {
    printf "%.3f,%.3f\n", prev_s, prev_e
    prev_s=s; prev_e=e
  }
}
END {
  if(prev_s!="") printf "%.3f,%.3f\n", prev_s, prev_e
}' "$tmpdir/padded_sorted.txt" > "$merged_file"

# extract and create list
: > "$list_file"
clip_i=0
while IFS=, read -r s e; do
  clip_i=$((clip_i+1))
  clip="$clips_dir/clip_$(printf "%03d" "$clip_i").mp4"
  s_fixed=$(printf "%.3f" "$s")
  s_fixed=${s_fixed/#./0.}
  segdur=$(echo "$e - $s" | bc -l)
  segdur_fixed=$(printf "%.3f" "$segdur")
  segdur_fixed=${segdur_fixed/#./0.}
  if ffmpeg -nostdin -hide_banner -nostats -y -ss "$s_fixed" -i "$in" -t "$segdur_fixed" -avoid_negative_ts make_zero -c:v h264_nvenc -preset p5 -rc vbr_hq -b:v "$target_video_bitrate" -maxrate "$max_video_bitrate" -bufsize "$bufsize" -c:a aac -b:a "$audio_bitrate" "$clip" 2>/dev/null; then
    :
  else
    ffmpeg -nostdin -hide_banner -nostats -y -ss "$s_fixed" -i "$in" -t "$segdur_fixed" -avoid_negative_ts make_zero -c:v libx264 -preset slow -b:v "$target_video_bitrate" -maxrate "$max_video_bitrate" -bufsize "$bufsize" -c:a aac -b:a "$audio_bitrate" "$clip"
  fi
  if [ -f "$clip" ] && [ "$(stat -c%s "$clip")" -gt 1024 ]; then
    clip_duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$clip" 2>/dev/null || echo 0)
    if (( $(echo "$clip_duration > 0 && $clip_duration <= $segdur_fixed + 1.0" | bc -l) )); then
      printf "file '%s'\n" "$clip" >> "$list_file"
    else
      echo "Skipping suspicious clip duration for $clip: got $clip_duration expected <= $(echo "$segdur_fixed + 1.0" | bc -l)" >&2
      rm -f "$clip"
    fi
  fi
done < "$merged_file"

# encode
if [ -s "$list_file" ]; then
  if ffmpeg -nostdin -hide_banner -nostats -y -f concat -safe 0 -i "$list_file" -c:v h264_nvenc -preset p5 -rc vbr_hq -b:v "$target_video_bitrate" -maxrate "$max_video_bitrate" -bufsize "$bufsize" -c:a aac -b:a "$audio_bitrate" "$out" 2>/dev/null; then
    echo "Created $out with NVENC"
  else
    ffmpeg -nostdin -hide_banner -nostats -y -f concat -safe 0 -i "$list_file" -c:v libx264 -preset slow -b:v "$target_video_bitrate" -maxrate "$max_video_bitrate" -bufsize "$bufsize" -c:a aac -b:a "$audio_bitrate" "$out"
    echo "Created $out with libx264 (NVENC not available)"
  fi
else
  ffmpeg -nostdin -hide_banner -nostats -y -ss 0 -t 30 -i "$in" -c:v libx264 -preset slow -b:v "$target_video_bitrate" -maxrate "$max_video_bitrate" -bufsize "$bufsize" -c:a aac -b:a "$audio_bitrate" "$out"
fi

if [ "$KEEP_DEBUG" = "1" ]; then
  echo "Debug files preserved in: ${debug_root}"
  echo "scenes log: $sc_log"
  echo "selected: $tmpdir/selected.csv"
  echo "padded: $tmpdir/padded_sorted.txt"
  echo "merged: $merged_file"
  echo "concat list: $list_file"
  echo "clips dir: $clips_dir"
else
  rm -rf "$tmpdir"
fi

echo "Highlight video created: $out"
