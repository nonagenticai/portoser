#!/usr/bin/env bash
# sync-pi-directories.sh - Pull each cluster host's working directory back
# into a local mirror so you can grep / build / inspect everything from one
# machine. Driven by `cluster.conf`.
#
# Usage:
#   ./sync-pi-directories.sh                # sync every host in cluster.conf
#   ./sync-pi-directories.sh host1          # sync only "host1"
#   ./sync-pi-directories.sh host1 host3    # sync host1 and host3
#
# Configuration (env vars):
#   CLUSTER_CONF   Path to cluster.conf (default: <repo>/cluster.conf)
#   DEST_BASE      Local directory under which mirrors are written
#                  (default: $PORTOSER_ROOT/.cluster-mirror)
#
# SSH must already use key-based auth (see scripts/setup-ssh-keys.sh).

set -euo pipefail

PORTOSER_ROOT="${PORTOSER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CLUSTER_CONF="${CLUSTER_CONF:-$PORTOSER_ROOT/cluster.conf}"
DEST_BASE="${DEST_BASE:-$PORTOSER_ROOT/.cluster-mirror}"

if [[ ! -f "$CLUSTER_CONF" ]]; then
    echo "Error: cluster config not found at $CLUSTER_CONF" >&2
    echo "Copy cluster.conf.example to cluster.conf and edit it for your hosts." >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CLUSTER_CONF"

if ! declare -p CLUSTER_HOSTS >/dev/null 2>&1; then
    echo "Error: CLUSTER_HOSTS not defined in $CLUSTER_CONF" >&2
    exit 1
fi
if ! declare -p CLUSTER_PATHS >/dev/null 2>&1; then
    echo "Error: CLUSTER_PATHS not defined in $CLUSTER_CONF" >&2
    exit 1
fi

# Decide which hosts to sync
if [ $# -eq 0 ]; then
    TARGETS=("${!CLUSTER_HOSTS[@]}")
else
    TARGETS=("$@")
    for key in "${TARGETS[@]}"; do
        if [[ -z "${CLUSTER_HOSTS[$key]:-}" ]]; then
            echo "Error: unknown host key '$key' (not in CLUSTER_HOSTS)" >&2
            exit 1
        fi
    done
fi

echo "========================================"
echo "Syncing host directories into $DEST_BASE"
echo "========================================"
echo "Target hosts: ${TARGETS[*]}"
echo

mkdir -p "$DEST_BASE"

for key in "${TARGETS[@]}"; do
    target="${CLUSTER_HOSTS[$key]}"
    src_path="${CLUSTER_PATHS[$key]:-}"

    if [[ -z "$src_path" ]]; then
        echo "Warning: no CLUSTER_PATHS entry for $key; skipping"
        continue
    fi

    dest_path="$DEST_BASE/$key"
    echo "----------------------------------------"
    echo "Syncing $key"
    echo "----------------------------------------"
    echo "Source: ${target}:${src_path}"
    echo "Dest:   ${dest_path}"

    echo -n "Testing connection... "
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
            "$target" "echo OK" >/dev/null 2>&1; then
        echo "OK"
    else
        echo "FAIL - skipping $key"
        continue
    fi

    mkdir -p "$dest_path"

    rsync -avz --delete \
        --exclude='*.pyc' \
        --exclude='__pycache__' \
        --exclude='node_modules' \
        --exclude='.git' \
        --exclude='.venv' \
        --exclude='venv' \
        --exclude='*.log' \
        -e "ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes" \
        "${target}:${src_path}/" \
        "${dest_path}/"

    echo "$key synced."
    echo
done

echo "========================================"
echo "Sync complete"
echo "========================================"
for key in "${TARGETS[@]}"; do
    if [ -d "$DEST_BASE/$key" ]; then
        size=$(du -sh "$DEST_BASE/$key" 2>/dev/null | cut -f1)
        echo "  $key: $size"
    fi
done
