#!/usr/bin/env bash
# Helpers for terminal recording scripts.
# Sourced from each scene; exposes `prompt` (typed-out shell line) and
# `pexec` (run a portoser command inside the api container so the recording
# looks like the operator's own terminal).

set -euo pipefail

CAPTURE_PROMPT='\033[1;32m$\033[0m '

# Type a command character-by-character into the recording. Looks like a
# human at a terminal rather than instant text.
prompt() {
  local cmd="$1"
  printf "%b" "$CAPTURE_PROMPT"
  local i=0
  while [ $i -lt ${#cmd} ]; do
    printf "%s" "${cmd:$i:1}"
    sleep 0.025
    i=$((i + 1))
  done
  printf "\n"
  sleep 0.25
}

# Run a portoser CLI command inside the api container with the demo
# registry. Stdout/stderr stream back to the recording terminal.
#
# A small grep -v filter strips known-noisy lines that come from the
# demo container's missing docker binary and read-only knowledge mount.
# Real output is untouched.
pexec() {
  docker exec portoser-api bash -lc \
    "cd /opt/portoser && export CADDY_REGISTRY_PATH=/app/registry-data/registry.yml && ./portoser $* 2>&1" \
  | grep -v -E \
    -e 'lib/docker\.sh: line [0-9]+: docker: command not found' \
    -e 'Failed to create Docker context' \
    -e 'Read-only file system' \
    -e 'lib/standardize/learning\.sh: line' \
    -e 'lib/history/tracker\.sh: line' \
    -e 'mkdir: cannot create directory.*Read-only' \
    -e 'ln: failed to create symbolic link.*Read-only' \
  || true
}
