#!/usr/bin/env bash
# =============================================================================
# check-cluster-docker-health.sh - Cluster Docker Health Check
#
# Iterates over the hosts declared in your cluster config (default
# `cluster.conf` at the repo root) and reports how many Docker containers on
# each host are reporting "healthy". The local host is included as well.
#
# Usage:
#   ./check-cluster-docker-health.sh [--no-delay] [--verbose] [--endpoints]
#
# Options:
#   --no-delay    Skip the initial delay (default: 25 seconds)
#   --verbose     Show detailed container information per host
#   --endpoints   Probe a few HTTP/HTTPS health endpoints (configurable
#                 via HEALTH_ENDPOINTS, comma-separated URL list)
#
# Configuration (env vars):
#   CLUSTER_CONF        Path to cluster.conf (default: <repo>/cluster.conf)
#   TOTAL_EXPECTED      Expected total healthy container count (default: 0,
#                       which disables the threshold check)
#   HEALTH_ENDPOINTS    Comma-separated list of URLs to probe with --endpoints
#
# Requirements:
#   - bash 4+ (for associative arrays); on macOS install via `brew install bash`
#   - docker (locally) and key-based ssh to each remote host
# =============================================================================

set -euo pipefail

# Resolve repo root from this script's location
PORTOSER_ROOT="${PORTOSER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CLUSTER_CONF="${CLUSTER_CONF:-$PORTOSER_ROOT/cluster.conf}"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
GRAY='\033[0;90m'
NC='\033[0m'

# Defaults
INITIAL_DELAY=25
VERBOSE=false
CHECK_ENDPOINTS=false
TOTAL_EXPECTED="${TOTAL_EXPECTED:-0}"

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --no-delay)   INITIAL_DELAY=0; shift ;;
        --verbose)    VERBOSE=true; shift ;;
        --endpoints)  CHECK_ENDPOINTS=true; shift ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Load cluster configuration
if [ ! -f "$CLUSTER_CONF" ]; then
    echo -e "${RED}Error:${NC} cluster config not found at $CLUSTER_CONF"
    echo "Copy cluster.conf.example to cluster.conf and edit it for your hosts."
    exit 1
fi

# shellcheck disable=SC1090
source "$CLUSTER_CONF"

if [ -z "${CLUSTER_HOSTS+x}" ]; then
    echo -e "${RED}Error:${NC} CLUSTER_HOSTS not defined in $CLUSTER_CONF"
    exit 1
fi

# Initial delay (useful after deployments)
if [ "$INITIAL_DELAY" -gt 0 ]; then
    echo -e "${BLUE}Waiting ${INITIAL_DELAY}s for services to stabilize...${NC}"
    sleep "$INITIAL_DELAY"
fi

echo -e "\n${BLUE}================================================================================${NC}"
echo -e "${BLUE}Cluster Docker Health Check${NC}"
echo -e "${BLUE}================================================================================${NC}"
echo
echo -e "${YELLOW}Note: Docker 'healthy' is a coarse signal — a container can be 'healthy'${NC}"
echo -e "${YELLOW}      while its dependencies (DB, Redis, etc.) are unreachable.${NC}"
echo

# Generic helpers --------------------------------------------------------------

# Run a command on a logical cluster host. The first argument is the logical
# host key from $CLUSTER_HOSTS; "local" / "localhost" runs locally.
run_on_host() {
    local host_key="$1"
    shift
    local cmd="$*"

    if [ "$host_key" = "local" ] || [ "$host_key" = "localhost" ]; then
        bash -c "$cmd"
        return $?
    fi

    local target="${CLUSTER_HOSTS[$host_key]:-}"
    if [ -z "$target" ]; then
        echo -e "${RED}Error:${NC} no SSH target for host '$host_key'" >&2
        return 1
    fi
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
        "$target" "$cmd"
}

healthy_count_for_host() {
    local host_key="$1"
    local n
    n=$(run_on_host "$host_key" "docker ps 2>/dev/null | grep -c healthy" 2>/dev/null || echo 0)
    n=${n//[^0-9]/}
    [ -z "$n" ] && n=0
    echo "$n"
}

show_healthy_for_host() {
    local host_key="$1"
    run_on_host "$host_key" \
        "docker ps --format 'table {{.Names}}\t{{.Status}}' | grep healthy" 2>/dev/null \
        | sed 's/^/  /' || true
}

# Per-host check ---------------------------------------------------------------

declare -A HOST_HEALTHY
TOTAL=0

# Always include localhost first (where this script runs)
echo -e "${BLUE}Checking local host...${NC}"
LOCAL_HEALTHY=$(docker ps 2>/dev/null | grep -c healthy || echo 0)
LOCAL_HEALTHY=${LOCAL_HEALTHY//[^0-9]/}
[ -z "$LOCAL_HEALTHY" ] && LOCAL_HEALTHY=0
echo -e "${GREEN}OK${NC} local: ${GREEN}${LOCAL_HEALTHY}${NC} healthy containers"
HOST_HEALTHY["local"]=$LOCAL_HEALTHY
TOTAL=$((TOTAL + LOCAL_HEALTHY))
if [ "$VERBOSE" = true ] && [ "$LOCAL_HEALTHY" -gt 0 ]; then
    echo -e "${GRAY}"
    docker ps --format "table {{.Names}}\t{{.Status}}" | grep healthy | sed 's/^/  /' || true
    echo -e "${NC}"
fi

# Then each remote logical host from cluster.conf
for host_key in "${!CLUSTER_HOSTS[@]}"; do
    target="${CLUSTER_HOSTS[$host_key]}"
    echo -e "\n${BLUE}Checking ${host_key} (${target})...${NC}"

    h=$(healthy_count_for_host "$host_key")
    HOST_HEALTHY[$host_key]=$h
    TOTAL=$((TOTAL + h))
    echo -e "${GREEN}OK${NC} ${host_key}: ${GREEN}${h}${NC} healthy containers"

    if [ "$VERBOSE" = true ] && [ "$h" -gt 0 ]; then
        echo -e "${GRAY}"
        show_healthy_for_host "$host_key"
        echo -e "${NC}"
    fi
done

# Summary ----------------------------------------------------------------------

echo -e "\n${BLUE}================================================================================${NC}"
echo -e "${BLUE}Summary${NC}"
echo -e "${BLUE}================================================================================${NC}\n"

printf "  %-12s ${GREEN}%s${NC} healthy\n" "local:" "${HOST_HEALTHY[local]}"
for host_key in "${!CLUSTER_HOSTS[@]}"; do
    printf "  %-12s ${GREEN}%s${NC} healthy\n" "${host_key}:" "${HOST_HEALTHY[$host_key]}"
done

if [ "$TOTAL_EXPECTED" -gt 0 ]; then
    echo -e "\n  ${BLUE}TOTAL: ${GREEN}${TOTAL}${NC}/${TOTAL_EXPECTED} healthy${NC}"
else
    echo -e "\n  ${BLUE}TOTAL: ${GREEN}${TOTAL}${NC} healthy${NC}"
fi
echo

# Optional endpoint checks -----------------------------------------------------
if [ "$CHECK_ENDPOINTS" = true ]; then
    echo -e "${BLUE}Endpoint checks:${NC}"
    if [ -z "${HEALTH_ENDPOINTS:-}" ]; then
        echo -e "  ${YELLOW}HEALTH_ENDPOINTS is unset; nothing to probe.${NC}"
        echo -e "  Example: HEALTH_ENDPOINTS='http://localhost:8080/health,https://api.example.local/healthz'"
    else
        IFS=',' read -ra ENDPOINTS <<< "$HEALTH_ENDPOINTS"
        for url in "${ENDPOINTS[@]}"; do
            url="${url// /}"
            [ -z "$url" ] && continue
            printf "  %s " "$url"
            if curl -k -s --max-time 3 -o /dev/null -w "%{http_code}" "$url" | grep -qE '^(2|3)'; then
                echo -e "${GREEN}OK${NC}"
            else
                echo -e "${YELLOW}FAIL${NC}"
            fi
        done
    fi
    echo
fi

# Exit code based on TOTAL_EXPECTED if provided
if [ "$TOTAL_EXPECTED" -gt 0 ]; then
    if [ "$TOTAL" -eq "$TOTAL_EXPECTED" ]; then
        exit 0
    elif [ "$TOTAL" -ge $((TOTAL_EXPECTED * 80 / 100)) ]; then
        exit 1
    else
        exit 2
    fi
fi
exit 0
