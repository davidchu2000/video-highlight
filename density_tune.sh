#!/usr/bin/env bash
set -euo pipefail

# density_tune.sh
# Suggest a SCENE_THRESH value by sampling short portions of a video.
#
# Usage:
#   ./density_tune.sh input.mp4
#   ./density_tune.sh input.mp4 0.10
#
# Output:
#   Minimal stats to stderr, suggested SCENE_THRESH to stdout.

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $(basename "$0") input.mp4 [initial_scene_thresh]" >&2
  exit 1
fi

in="$1"
initial_thresh="${2:-0.10}"
MIN_CLIP="${MIN_CLIP:-5.0}"
END_TRIM="${END_TRIM:-10.0}"
MAX_PASSES="${MAX_PASSES:-3}"
SAMPLE_LEN="${SAMPLE_LEN:-120}"
MAX_SAMPLES="${MAX_SAMPLES:-4}"

if ! command -v ffprobe >/dev/null 2>&1 || ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg and ffprobe are required" >&2
  exit 1
fi

workdir="$(mktemp -d)"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$in")
duration=${duration:-0}
content_end=$(echo "$duration - $END_TRIM" | bc -l)
if (( $(echo "$content_end < 0" | bc -l) )); then
  content_end=0
fi

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

sample_points() {
  python3 - "$content_end" "$SAMPLE_LEN" "$MAX_SAMPLES" <<'PY'
import sys
content_end=float(sys.argv[1])
sample_len=float(sys.argv[2])
max_samples=int(sys.argv[3])
if content_end <= 0:
    print("0 0")
    raise SystemExit
usable=max(0.0, content_end - sample_len)
if max_samples <= 1 or usable <= 0:
    print(f"0 {min(sample_len, content_end):.3f}")
    raise SystemExit
points=[]
for i in range(max_samples):
    frac=(i+1)/(max_samples+1)
    start=usable*frac
    points.append((start, min(sample_len, content_end-start)))
for start,seglen in points:
    print(f"{start:.3f} {seglen:.3f}")
PY
}

run_pass() {
  local thresh="$1"
  local stats_file="$2"

  python3 - "$MIN_CLIP" > "$stats_file" <<'PY'
import sys
print('raw=0')
print('short=0')
print('kept=0')
print('short_ratio=0.000000')
print('raw_per_min=0.000000')
print('usable_ratio=0.000000')
print('sample_minutes=0.000000')
PY

  local idx=0
  while read -r sample_start sample_len _rest; do
    [ -z "${sample_start:-}" ] && continue
    [ -z "${sample_len:-}" ] && continue
    idx=$((idx+1))
    local sc_log="$workdir/scenes_p${idx}.log"
    local parsed="$workdir/parsed_p${idx}.lst"
    local time_score="$workdir/time_score_p${idx}.csv"

    : > "$sc_log"
    if [ -n "$dec" ]; then
      if ffmpeg -hide_banner -nostats -ss "$sample_start" -t "$sample_len" -c:v "$dec" -i "$in" -vf "select='gt(scene,${thresh})',metadata=print" -an -f null - > /dev/null 2> "$sc_log"; then
        true
      else
        ffmpeg -hide_banner -nostats -ss "$sample_start" -t "$sample_len" -i "$in" -vf "select='gt(scene,${thresh})',metadata=print" -an -f null - > /dev/null 2> "$sc_log"
      fi
    else
      ffmpeg -hide_banner -nostats -ss "$sample_start" -t "$sample_len" -i "$in" -vf "select='gt(scene,${thresh})',metadata=print" -an -f null - > /dev/null 2> "$sc_log"
    fi

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
    ' "$sc_log" > "$parsed"

    : > "$time_score"
    local last_score=""
    while IFS= read -r line; do
      if [[ "$line" == SCORE:* ]]; then
        last_score="${line#SCORE:}"
      else
        time=$(printf "%.3f" "$line")
        if [[ -z "$last_score" ]]; then last_score=1.0; fi
        printf "%s,%s\n" "$time" "$last_score" >> "$time_score"
        last_score=""
      fi
    done < "$parsed" || true

    python3 - "$stats_file" "$time_score" "$MIN_CLIP" "$sample_len" <<'PY'
import sys
from pathlib import Path
stats_path=Path(sys.argv[1])
time_score_path=Path(sys.argv[2])
min_clip=float(sys.argv[3])
sample_len=float(sys.argv[4])
stats={}
for line in stats_path.read_text().splitlines():
    if '=' in line:
        k,v=line.split('=',1)
        stats[k]=float(v)
rows=[]
for line in time_score_path.read_text().splitlines():
    if line.strip():
        rows.append(float(line.split(',')[0]))
prev=0.0
raw=short=kept=0
short_dur=kept_dur=0.0
for t in rows:
    if t > prev:
        d=t-prev
        raw += 1
        if d < min_clip:
            short += 1
            short_dur += d
        else:
            kept += 1
            kept_dur += d
        prev=t
if sample_len > prev:
    d=sample_len-prev
    raw += 1
    if d < min_clip:
        short += 1
        short_dur += d
    else:
        kept += 1
        kept_dur += d
stats['raw'] += raw
stats['short'] += short
stats['kept'] += kept
stats['sample_minutes'] += sample_len/60.0
stats.setdefault('short_dur', 0.0)
stats.setdefault('kept_dur', 0.0)
stats['short_dur'] += short_dur
stats['kept_dur'] += kept_dur
stats['short_ratio'] = (stats['short']/stats['raw']) if stats['raw'] else 0.0
stats['raw_per_min'] = (stats['raw']/stats['sample_minutes']) if stats['sample_minutes'] else 0.0
stats['usable_ratio'] = (stats['kept_dur']/(stats['short_dur']+stats['kept_dur'])) if (stats['short_dur']+stats['kept_dur']) else 0.0
order=['raw','short','kept','short_ratio','raw_per_min','usable_ratio','sample_minutes','short_dur','kept_dur']
stats_path.write_text('\n'.join(f"{k}={stats.get(k,0.0):.6f}" if k not in ('raw','short','kept') else f"{k}={int(round(stats.get(k,0.0)))}" for k in order)+"\n")
PY
  done < <(sample_points)
}

get_stat() {
  local key="$1"
  local file="$2"
  awk -F= -v k="$key" '$1==k {print $2}' "$file"
}

thresh="$initial_thresh"
pass=1
best_thresh="$thresh"
while [ "$pass" -le "$MAX_PASSES" ]; do
  stats_file="$workdir/pass_${pass}.txt"
  run_pass "$thresh" "$stats_file"

  raw=$(get_stat raw "$stats_file")
  short_ratio=$(get_stat short_ratio "$stats_file")
  raw_per_min=$(get_stat raw_per_min "$stats_file")
  usable_ratio=$(get_stat usable_ratio "$stats_file")
  sample_minutes=$(get_stat sample_minutes "$stats_file")

  echo "pass=${pass} thresh=${thresh} samples_min=${sample_minutes} raw=${raw} short_ratio=${short_ratio} raw_per_min=${raw_per_min} usable_ratio=${usable_ratio}" >&2

  best_thresh="$thresh"

  overfire=$(python3 - <<PY
rpm=float("${raw_per_min:-0}")
sr=float("${short_ratio:-0}")
print(1 if (rpm > 20.0 or sr > 0.90) else 0)
PY
)
  underfire=$(python3 - <<PY
rpm=float("${raw_per_min:-0}")
ur=float("${usable_ratio:-0}")
print(1 if (rpm < 2.0 and ur > 0.85) else 0)
PY
)

  if [ "$overfire" = "1" ]; then
    thresh=$(python3 - <<PY
x=float("$thresh")
print(f"{min(x + 0.02, 0.25):.2f}")
PY
)
    pass=$((pass+1))
    continue
  fi

  if [ "$underfire" = "1" ]; then
    thresh=$(python3 - <<PY
x=float("$thresh")
print(f"{max(x - 0.02, 0.01):.2f}")
PY
)
    pass=$((pass+1))
    continue
  fi

  break
done

printf "%s\n" "$best_thresh"
