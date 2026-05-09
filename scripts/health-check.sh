#!/usr/bin/env bash
# =============================================================================
# health-check.sh - Cluster Docker container health summary
# =============================================================================
#
# Iterates over every host in cluster.conf and prints a one-line summary of
# healthy vs total Docker containers per host. Driven entirely by the
# CLUSTER_HOSTS map from cluster.conf - no hardcoded hostnames.
#
# Requires SSH key access to all hosts in cluster.conf. Run
# scripts/setup-ssh-keys.sh first if key auth is not yet configured. This
# script intentionally does NOT use sshpass.
#
# Usage:
#   ./health-check.sh [--no-delay] [--verbose]
#
# Options:
#   --no-delay    Skip the initial delay (default: 0 seconds; kept for
#                 backwards compatibility with older callers)
#   --verbose     Show per-container detail (Names + Status) per host
#   -h, --help    Show this help message
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Load cluster topology
# -----------------------------------------------------------------------------
CLUSTER_CONF="${CLUSTER_CONF:-${PORTOSER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/cluster.conf}"
if [[ ! -f "$CLUSTER_CONF" ]]; then
    echo "ERROR: cluster.conf not found at $CLUSTER_CONF" >&2
    echo "       Copy cluster.conf.example to cluster.conf and edit for your environment." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CLUSTER_CONF"

if ! declare -p CLUSTER_HOSTS &>/dev/null || [[ ${#CLUSTER_HOSTS[@]} -eq 0 ]]; then
    echo "ERROR: CLUSTER_HOSTS is empty or unset in $CLUSTER_CONF" >&2
    echo "       See cluster.conf.example for the expected layout." >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
GRAY='\033[0;90m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# Defaults / arg parsing
# -----------------------------------------------------------------------------
INITIAL_DELAY=0
VERBOSE=false
SSH_TIMEOUT=5

while [ $# -gt 0 ]; do
    case "$1" in
        --no-delay)
            INITIAL_DELAY=0
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Count healthy and total Docker containers across every host in cluster.conf.

Options:
  --no-delay    Skip the initial delay (default: 0 seconds)
  --verbose     Show per-container detail (Names + Status) per host
  -h, --help    Show this help message

Requires SSH key access to all hosts in cluster.conf. Run
scripts/setup-ssh-keys.sh first if not yet configured.
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
    esac
done

if [ "$INITIAL_DELAY" -gt 0 ]; then
    echo -e "${BLUE}Waiting ${INITIAL_DELAY}s for services to stabilize...${NC}"
    sleep "$INITIAL_DELAY"
fi

# -----------------------------------------------------------------------------
# Banner
# -----------------------------------------------------------------------------
echo -e "\n${BLUE}================================================================================${NC}"
echo -e "${BLUE}Cluster Docker Health Check${NC}"
echo -e "${BLUE}================================================================================${NC}\n"

echo -e "${YELLOW}Note: Docker 'healthy' status only confirms the container's healthcheck${NC}"
echo -e "${YELLOW}      passed. It does NOT guarantee dependencies (DB, Redis, etc.) work.${NC}\n"

# -----------------------------------------------------------------------------
# Per-host probing
# -----------------------------------------------------------------------------
TOTAL_HEALTHY=0
TOTAL_CONTAINERS=0

# Stable iteration order
mapfile -t SORTED_HOSTS < <(printf '%s\n' "${!CLUSTER_HOSTS[@]}" | sort)

declare -A HOST_HEALTHY=()
declare -A HOST_TOTAL=()
declare -A HOST_REACHABLE=()

ssh_opts=(-o "StrictHostKeyChecking=accept-new" -o "BatchMode=yes" -o "ConnectTimeout=${SSH_TIMEOUT}")

for host_key in "${SORTED_HOSTS[@]}"; do
    ssh_target="${CLUSTER_HOSTS[$host_key]}"

    echo -e "${BLUE}Checking ${host_key} (${ssh_target})...${NC}"

    # Healthy count: lines in `docker ps` whose status contains 'healthy'.
    # We pipe through wc -l on the remote side. If ssh fails, healthy=0 and
    # we mark the host unreachable.
    if healthy=$(ssh "${ssh_opts[@]}" "$ssh_target" \
            "docker ps 2>/dev/null | grep -c healthy || true" 2>/dev/null); then
        HOST_REACHABLE[$host_key]=1
    else
        HOST_REACHABLE[$host_key]=0
        healthy=0
    fi
    healthy="$(echo "$healthy" | tr -d ' \n\r')"
    [ -z "$healthy" ] && healthy=0

    # Total containers (including non-running). Subtract 1 for the header.
    if [ "${HOST_REACHABLE[$host_key]}" = "1" ]; then
        total_raw=$(ssh "${ssh_opts[@]}" "$ssh_target" \
            "docker ps -a 2>/dev/null | wc -l" 2>/dev/null || echo "1")
        total_raw="$(echo "$total_raw" | tr -d ' \n\r')"
        [ -z "$total_raw" ] && total_raw=1
        total=$((total_raw - 1))
        [ "$total" -lt 0 ] && total=0
    else
        total=0
    fi

    HOST_HEALTHY[$host_key]="$healthy"
    HOST_TOTAL[$host_key]="$total"

    if [ "${HOST_REACHABLE[$host_key]}" = "0" ]; then
        echo -e "  ${YELLOW}!${NC} ${host_key}: unreachable via SSH"
    elif [ "$total" -eq 0 ]; then
        echo -e "  ${GRAY}-${NC} ${host_key}: no containers"
    else
        echo -e "  ${GREEN}+${NC} ${host_key}: ${GREEN}${healthy}${NC}/${total} healthy containers"
    fi

    if [ "$VERBOSE" = true ] && [ "${HOST_REACHABLE[$host_key]}" = "1" ] && [ "$total" -gt 0 ]; then
        echo -e "${GRAY}"
        ssh "${ssh_opts[@]}" "$ssh_target" \
            "docker ps --format 'table {{.Names}}\t{{.Status}}'" 2>/dev/null \
            | sed 's/^/    /' || true
        echo -e "${NC}"
    fi

    TOTAL_HEALTHY=$((TOTAL_HEALTHY + healthy))
    TOTAL_CONTAINERS=$((TOTAL_CONTAINERS + total))
    echo ""
done

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo -e "${BLUE}================================================================================${NC}"
echo -e "${BLUE}Summary${NC}"
echo -e "${BLUE}================================================================================${NC}\n"

for host_key in "${SORTED_HOSTS[@]}"; do
    label=$(printf '%-12s' "$host_key")
    if [ "${HOST_REACHABLE[$host_key]}" = "0" ]; then
        echo -e "  ${label} ${YELLOW}unreachable${NC}"
    else
        echo -e "  ${label} ${GREEN}${HOST_HEALTHY[$host_key]}${NC}/${HOST_TOTAL[$host_key]} healthy"
    fi
done

echo -e ""
echo -e "  ${BLUE}TOTAL:${NC} ${GREEN}${TOTAL_HEALTHY}${NC}/${TOTAL_CONTAINERS} healthy containers across ${#SORTED_HOSTS[@]} host(s)"
echo -e ""

# Exit non-zero only if something is reachable but unhealthy, OR if any host
# was unreachable. Empty clusters (zero containers) exit 0.
exit_code=0
for host_key in "${SORTED_HOSTS[@]}"; do
    if [ "${HOST_REACHABLE[$host_key]}" = "0" ]; then
        exit_code=2
    fi
done

if [ "$TOTAL_CONTAINERS" -gt 0 ] && [ "$TOTAL_HEALTHY" -lt "$TOTAL_CONTAINERS" ] && [ "$exit_code" -eq 0 ]; then
    exit_code=1
fi

exit "$exit_code"
