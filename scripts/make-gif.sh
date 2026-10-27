#!/usr/bin/env bash
# Turns a window recording into a looping GIF with a two pass palette.
#   scripts/make-gif.sh <in.mov> <out.gif> <fps> <width> [start-seconds] [duration-seconds]
# PRE=<ffmpeg filters> runs first, at full size (crops, patches).
set -eu
[ $# -ge 4 ] || { echo "usage: make-gif.sh <in.mov> <out.gif> <fps> <width> [start] [duration]" >&2; exit 2; }
in="$1" out="$2" fps="$3" width="$4" start="${5:-0}" dur="${6:-}"
pal="$(mktemp -d)/palette.png"
trim=(-ss "$start"); [ -n "$dur" ] && trim+=(-t "$dur")
filters="${PRE:+$PRE,}fps=$fps,scale=$width:-1:flags=lanczos"
ffmpeg -v error -y "${trim[@]}" -i "$in" -vf "$filters,palettegen=stats_mode=diff" "$pal"
ffmpeg -v error -y "${trim[@]}" -i "$in" -i "$pal" \
  -lavfi "$filters [x]; [x][1:v] paletteuse=dither=sierra2_4a:diff_mode=rectangle" -loop 0 "$out"
rm -rf "$(dirname "$pal")"
if command -v gifsicle >/dev/null 2>&1; then gifsicle -O3 --batch "$out"; fi
ls -lh "$out" | awk '{print $5, $NF}'
