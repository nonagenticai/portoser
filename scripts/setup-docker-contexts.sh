#!/usr/bin/env bash
# =============================================================================
# setup-docker-contexts.sh - Create Docker contexts for each cluster host
#
# For every host declared in your cluster.conf, this script creates a local
# Docker context that points at that host over SSH. After running, you can
# operate on a remote engine with:
#
#     docker --context <host_key> ps
#     docker --context <host_key> compose up -d
#
# Configuration:
#   CLUSTER_CONF   Path to cluster.conf (default: <repo>/cluster.conf)
#
# Requirements:
#   - bash 4+ (for associative arrays); on macOS install via `brew install bash`
#   - docker CLI locally
#   - key-based SSH already working to each remote host (run setup-ssh-keys.sh
#     first if needed)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PORTOSER_ROOT="${PORTOSER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CLUSTER_CONF="${CLUSTER_CONF:-$PORTOSER_ROOT/cluster.conf}"

if [[ ! -f "$CLUSTER_CONF" ]]; then
    echo -e "${RED}Error:${NC} cluster config not found at $CLUSTER_CONF" >&2
    echo "Copy cluster.conf.example to cluster.conf and edit it for your hosts." >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CLUSTER_CONF"

if ! declare -p CLUSTER_HOSTS >/dev/null 2>&1; then
    echo -e "${RED}Error:${NC} CLUSTER_HOSTS not defined in $CLUSTER_CONF" >&2
    exit 1
fi

error_exit() { echo -e "${RED}ERROR: $1${NC}" >&2; exit 1; }
success_msg() { echo -e "${GREEN}OK${NC} $1"; }
warning_msg() { echo -e "${YELLOW}WARN${NC} $1"; }

# Parse "user@host[:port]" into a docker context host string.
# Defaults to port 22 if not specified.
ssh_target_to_docker_host() {
    local target="$1"
    local user_host port
    if [[ "$target" == *:* ]]; then
        user_host="${target%:*}"
        port="${target##*:}"
    else
        user_host="$target"
        port=22
    fi
    echo "ssh://${user_host}:${port}"
}

test_ssh_connectivity() {
    local key="$1" target="$2"
    echo "Testing SSH connectivity to $key ($target)..."
    if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            "$target" "echo SSH-OK" >/dev/null 2>&1; then
        success_msg "SSH to $key works"
        return 0
    fi
    warning_msg "SSH to $key failed"
    return 1
}

test_docker_remote() {
    local key="$1" target="$2"
    echo "Testing remote Docker on $key..."
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "$target" "docker version" >/dev/null 2>&1; then
        success_msg "Docker reachable on $key"
        return 0
    fi
    warning_msg "Docker not reachable on $key (is the daemon running and the user in the docker group?)"
    return 1
}

create_context() {
    local key="$1" target="$2"
    local docker_host
    docker_host=$(ssh_target_to_docker_host "$target")

    if docker context inspect "$key" >/dev/null 2>&1; then
        echo "Removing existing context: $key"
        docker context rm "$key" -f >/dev/null || warning_msg "Could not remove existing context $key"
    fi

    if docker context create "$key" --docker "host=${docker_host}" >/dev/null; then
        success_msg "Created context: $key ($docker_host)"
        return 0
    fi
    error_exit "Failed to create docker context for $key"
}

verify_context() {
    local key="$1"
    if docker --context "$key" info >/dev/null 2>&1; then
        success_msg "Context $key verified"
        return 0
    fi
    warning_msg "Context $key verification failed"
    return 1
}

list_contexts() {
    echo
    echo "=== Docker contexts ==="
    docker context ls
    echo
}

cleanup_contexts() {
    echo "Cleaning up cluster Docker contexts..."
    for key in "${!CLUSTER_HOSTS[@]}"; do
        if docker context inspect "$key" >/dev/null 2>&1; then
            echo "Removing context: $key"
            docker context rm "$key" -f >/dev/null || warning_msg "Could not remove $key"
        fi
    done
    success_msg "Cleanup complete"
}

setup_all() {
    local ssh_passed=0 ssh_failed=0 created=0 verified=0
    local total=${#CLUSTER_HOSTS[@]}

    echo "=== Docker context setup ($total host(s)) ==="

    echo "--- SSH connectivity ---"
    for key in "${!CLUSTER_HOSTS[@]}"; do
        if test_ssh_connectivity "$key" "${CLUSTER_HOSTS[$key]}"; then
            ((ssh_passed++))
        else
            ((ssh_failed++))
        fi
    done

    echo "--- Remote Docker ---"
    for key in "${!CLUSTER_HOSTS[@]}"; do
        test_docker_remote "$key" "${CLUSTER_HOSTS[$key]}" || true
    done

    echo "--- Creating contexts ---"
    for key in "${!CLUSTER_HOSTS[@]}"; do
        if create_context "$key" "${CLUSTER_HOSTS[$key]}"; then
            ((created++))
        fi
    done

    echo "--- Verifying contexts ---"
    for key in "${!CLUSTER_HOSTS[@]}"; do
        if verify_context "$key"; then
            ((verified++))
        fi
    done

    list_contexts

    echo "=== Summary ==="
    echo "SSH:       $ssh_passed passed, $ssh_failed failed"
    echo "Created:   $created/$total"
    echo "Verified:  $verified/$total"
}

usage() {
    cat <<EOF
Usage: $0 [COMMAND]

Commands:
    setup       Create Docker contexts for all hosts in cluster.conf (default)
    list        List all Docker contexts on this machine
    cleanup     Remove the contexts that match cluster.conf host keys
    test        Only test SSH connectivity (do not create contexts)
    help        Show this help

Cluster config: $CLUSTER_CONF
EOF
}

main() {
    local cmd="${1:-setup}"
    case "$cmd" in
        setup)   setup_all ;;
        list)    list_contexts ;;
        cleanup) cleanup_contexts ;;
        test)
            echo "=== Testing SSH connectivity ==="
            for key in "${!CLUSTER_HOSTS[@]}"; do
                test_ssh_connectivity "$key" "${CLUSTER_HOSTS[$key]}" || true
            done
            ;;
        help|-h|--help) usage ;;
        *) echo "Unknown command: $cmd"; usage; exit 1 ;;
    esac
}

main "$@"
