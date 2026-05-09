#!/usr/bin/env bash
# Knowledge-base CLI flow: summary → playbooks → per-service insights.
# Output: output/02-learn-flow.svg

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_lib.sh"

clear

prompt "portoser learn summary"
pexec learn summary || true
sleep 0.6

prompt "portoser learn playbooks"
pexec learn playbooks || true
sleep 0.6

prompt "portoser learn insights gitea"
pexec learn insights gitea || true

sleep 1
