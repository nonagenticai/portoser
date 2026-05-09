#!/usr/bin/env bash
# Health-watch scene: three cluster-status passes with timestamps,
# emulating `portoser cluster status --watch`. Each pass clears the
# screen and reprints the summary.
# Output: output/05-health-watch.svg

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_lib.sh"

clear

prompt "watch -n 5 portoser cluster status"

for _ in 1 2 3; do
  printf '\033[H\033[2J'
  printf 'Every 5.0s: portoser cluster status                       %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  pexec cluster status || true
  sleep 2
done

sleep 1
