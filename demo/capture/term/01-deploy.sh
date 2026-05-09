#!/usr/bin/env bash
# Hero terminal scene: a fresh deploy of `pihole` to `raspi-4` (arm64-linux).
# Auto-heal enabled. Caller is expected to have already removed the running
# container on host-raspi-4 so the deploy is a real first-time install.
# Output: output/01-deploy.svg

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_lib.sh"

clear

prompt "portoser deploy raspi-4 pihole"
pexec deploy raspi-4 pihole || true

sleep 1
