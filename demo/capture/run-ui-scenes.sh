#!/usr/bin/env bash
# run-ui-scenes.sh — capture each UI scene and convert it to embed assets.
# Playwright wipes test-results/ between specs by default, so we run one
# spec at a time and immediately invoke convert.sh while the webm is still
# on disk.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# scene_name|TRIM_START|TRIM_DURATION|POSTER_TS — empty fields skip the trim.
declare -a scenes=(
  "01-hero-drag-deploy|||5"
  "02-self-healing|13||20"
  "03-dependency-graph|14||2"
  "04-live-metrics|14||20"
  "05-knowledge-base|8||15"
)

for entry in "${scenes[@]}"; do
  IFS='|' read -r scene trim_start trim_duration poster_ts <<< "$entry"
  spec="specs/${scene}.spec.ts"

  echo
  echo "===== capturing ${scene} ====="
  npx playwright test "$spec"

  echo "===== converting ${scene} ====="
  env_args=()
  [ -n "$trim_start" ] && env_args+=("TRIM_START=$trim_start")
  [ -n "$trim_duration" ] && env_args+=("TRIM_DURATION=$trim_duration")
  [ -n "$poster_ts" ] && env_args+=("POSTER_TS=$poster_ts")
  env "${env_args[@]}" ./convert.sh "$scene"
done

echo
echo "===== done. assets in output/ ====="
ls -la output/*.{mp4,webp} 2>/dev/null
