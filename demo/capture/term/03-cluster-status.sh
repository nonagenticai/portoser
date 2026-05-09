#!/usr/bin/env bash
# Cluster overview from the CLI.
# Output: output/03-cluster-status.svg

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_lib.sh"

clear
prompt "portoser status"
pexec status || true
sleep 1
