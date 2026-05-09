#!/usr/bin/env bash
# convert.sh — turn a Playwright video.webm into the embed assets.
# Usage: ./convert.sh <scene-name>
#   reads:  test-results/<scene-name>-<scene-name>-chromium/video.webm
#   writes: output/<scene-name>.mp4
#           output/<scene-name>.webp
#           output/<scene-name>-poster.webp
#
# WebP is sized for being a graceful fallback, not the primary asset:
# 12fps, q:v 35, single loop. The MP4 is what the site actually plays.

set -euo pipefail

scene="${1:?usage: $0 <scene-name>}"
src="test-results/${scene}-${scene}-chromium/video.webm"
out_dir="output"

if [ ! -f "$src" ]; then
  # Fall back to a glob in case Playwright renamed the dir.
  src="$(ls test-results/*${scene}*-chromium/video.webm 2>/dev/null | head -1)"
fi

if [ -z "$src" ] || [ ! -f "$src" ]; then
  echo "No video.webm for scene '$scene' under test-results/" >&2
  exit 1
fi

mkdir -p "$out_dir"

# Optional trim: TRIM_START + TRIM_DURATION skip the recording's
# auth/navigation prefix so the embedded clip starts at something useful.
trim_args=()
if [ -n "${TRIM_START:-}" ]; then
  trim_args+=(-ss "$TRIM_START")
fi
if [ -n "${TRIM_DURATION:-}" ]; then
  trim_args+=(-t "$TRIM_DURATION")
fi

# 1) MP4 (primary): h264, faststart, no audio, decent quality.
ffmpeg -y -loglevel error "${trim_args[@]}" -i "$src" \
  -c:v libx264 -pix_fmt yuv420p -movflags +faststart -crf 23 -an \
  "$out_dir/${scene}.mp4"

# 2) Animated WebP (fallback): lower fps, lower quality, lossy.
ffmpeg -y -loglevel error "${trim_args[@]}" -i "$src" \
  -vf 'fps=12,scale=960:-2:flags=lanczos' \
  -vcodec libwebp -lossless 0 -q:v 35 -loop 0 -preset default -an -vsync 0 \
  "$out_dir/${scene}.webp"

# 3) Poster (still): a single frame from a useful timestamp.
poster_ts="${POSTER_TS:-3}"
ffmpeg -y -loglevel error -ss "$poster_ts" -i "$src" \
  -frames:v 1 -c:v libwebp -q:v 80 \
  "$out_dir/${scene}-poster.webp"

ls -la "$out_dir/${scene}".{mp4,webp} "$out_dir/${scene}-poster.webp"
