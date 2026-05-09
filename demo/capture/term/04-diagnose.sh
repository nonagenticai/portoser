#!/usr/bin/env bash
# Diagnose scene: portoser diagnose surfacing the analyzer fingerprint.
# Caller is expected to have stopped the dependency container on the
# fakehost (e.g. python-sensors on raspi-4) so the dependency check fails
# and the analyzer reports PROBLEM_DEPENDENCY_UNHEALTHY.
# Output: output/04-diagnose.svg

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_lib.sh"

clear

prompt "portoser diagnose homeassistant raspi-4"
pexec diagnose homeassistant raspi-4 || true

sleep 1
