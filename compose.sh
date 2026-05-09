#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Portoser Docker Compose Manager
# ============================================================================
# Manages local Docker Compose stacks for portoser-managed services.
#
# Configuration:
#   PORTOSER_SERVICES_ROOT  Directory under which each service lives in its own
#                           subdirectory containing a docker-compose.yml. Defaults
#                           to "$HOME/portoser".
#   PORTOSER_SERVICES_FILE  Optional path to a newline-separated list of service
#                           names to manage. Lines starting with "#" are ignored.
#                           If unset, every immediate subdirectory of
#                           $PORTOSER_SERVICES_ROOT that contains a
#                           docker-compose.yml is treated as a service.
# ============================================================================

ROOTDIR="${PORTOSER_SERVICES_ROOT:-${HOME}/portoser}"

# =============================================================================
# STARTUP VALIDATION CHECKS
# =============================================================================

# Source validation module if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/lib/cluster/validation.sh" ]; then
    source "$SCRIPT_DIR/lib/cluster/validation.sh"

    # Run startup validation checks
    echo ""
    validate_bash_version || exit 1
    validate_required_commands || exit 1
    echo ""
fi

# Trap to cleanup background processes on exit
trap 'kill $(jobs -p) 2>/dev/null' EXIT INT TERM

# Parse command line arguments
ACTION="start"
REBUILD_NOCACHE=false
REBUILD_TARGETS=()
TARGETS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --restart|-r)
            ACTION="restart"
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                TARGETS+=("$1")
                shift
            done
            ;;
        --shutdown|-s)
            ACTION="shutdown"
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                TARGETS+=("$1")
                shift
            done
            ;;
        --cleanup|-c)
            ACTION="cleanup"
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                TARGETS+=("$1")
                shift
            done
            ;;
        --rebuild|-b)
            REBUILD_NOCACHE=true
            ACTION="restart"
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                REBUILD_TARGETS+=("$1")
                shift
            done
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  -r, --restart [SERVICES...]"
            echo "                      Restart containers (down + up with build)"
            echo "                      If no services specified, restarts all"
            echo "  -s, --shutdown [SERVICES...]"
            echo "                      Shutdown containers (down with volumes)"
            echo "                      If no services specified, shuts down all"
            echo "  -c, --cleanup [SERVICES...]"
            echo "                      Full cleanup: stop, delete volumes and images"
            echo "                      If no services specified, cleans up all"
            echo "  -b, --rebuild [SERVICES...]"
            echo "                      Force rebuild with --no-cache"
            echo "                      If no services specified or 'all', rebuilds all"
            echo "  -h, --help          Show this help message"
            echo ""
            echo "Configuration:"
            echo "  PORTOSER_SERVICES_ROOT   Root directory containing service subdirs"
            echo "                           (default: \$HOME/portoser)"
            echo "  PORTOSER_SERVICES_FILE   Optional file listing services to manage"
            echo ""
            echo "Examples:"
            echo "  $0                           # Start all services"
            echo "  $0 --restart                 # Restart all services"
            echo "  $0 --restart keycloak        # Restart keycloak only"
            echo "  $0 --rebuild all             # Rebuild all services"
            echo "  $0 --rebuild keycloak        # Rebuild keycloak only"
            echo "  $0 --cleanup                 # Full cleanup of all"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Discover services either from PORTOSER_SERVICES_FILE or by scanning ROOTDIR.
declare -A SERVICES=()
if [[ -n "${PORTOSER_SERVICES_FILE:-}" && -f "$PORTOSER_SERVICES_FILE" ]]; then
    while IFS= read -r line; do
        # Strip comments and whitespace.
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [[ -z "$line" ]] && continue
        SERVICES["$line"]="$ROOTDIR/$line"
    done < "$PORTOSER_SERVICES_FILE"
else
    if [[ -d "$ROOTDIR" ]]; then
        for dir in "$ROOTDIR"/*/; do
            [[ -d "$dir" ]] || continue
            if [[ -f "$dir/docker-compose.yml" ]]; then
                name="$(basename "$dir")"
                SERVICES["$name"]="${dir%/}"
            fi
        done
    fi
fi

if [[ ${#SERVICES[@]} -eq 0 ]]; then
    echo "ERROR: No services discovered." >&2
    echo "       Set PORTOSER_SERVICES_ROOT to a directory containing service subdirs," >&2
    echo "       or set PORTOSER_SERVICES_FILE to a file listing service names." >&2
    echo "       Current PORTOSER_SERVICES_ROOT=$ROOTDIR" >&2
    exit 1
fi

# Determine which services to operate on
if [[ ${#TARGETS[@]} -eq 0 && ${#REBUILD_TARGETS[@]} -eq 0 ]]; then
    # No targets specified, use all services
    SERVICE_LIST=("${!SERVICES[@]}")
elif [[ ${#REBUILD_TARGETS[@]} -gt 0 ]]; then
    # Check if "all" was specified
    if [[ " ${REBUILD_TARGETS[*]} " =~ " all " ]]; then
        SERVICE_LIST=("${!SERVICES[@]}")
    else
        SERVICE_LIST=("${REBUILD_TARGETS[@]}")
    fi
else
    SERVICE_LIST=("${TARGETS[@]}")
fi

# Sort services for consistent ordering
mapfile -t SERVICE_LIST < <(printf '%s\n' "${SERVICE_LIST[@]}" | sort)

echo "============================================="
echo "Portoser Docker Compose Manager"
echo "============================================="
echo "Action: $ACTION"
echo "Root:   $ROOTDIR"
echo "Services: ${SERVICE_LIST[*]}"
if [[ "$REBUILD_NOCACHE" == "true" ]]; then
    echo "Rebuild: --no-cache enabled"
fi
echo ""

# Function to run docker-compose command
run_compose() {
    local service=$1
    local cmd=$2
    local dir=${SERVICES[$service]}

    if [[ ! -d "$dir" ]]; then
        echo "WARN: $service: Directory not found: $dir"
        return 1
    fi

    if [[ ! -f "$dir/docker-compose.yml" ]]; then
        echo "WARN: $service: docker-compose.yml not found"
        return 1
    fi

    echo "-> $service: $cmd"
    cd "$dir"
    eval "$cmd"
}

# Execute action on each service
for service in "${SERVICE_LIST[@]}"; do
    if [[ ! -v SERVICES[$service] ]]; then
        echo "ERROR: Unknown service: $service"
        continue
    fi

    case $ACTION in
        start)
            run_compose "$service" "docker-compose up -d --build"
            ;;
        restart)
            if [[ "$REBUILD_NOCACHE" == "true" ]] && [[ " ${REBUILD_TARGETS[*]} " == *" $service "* || " ${REBUILD_TARGETS[*]} " == *" all "* ]]; then
                echo "Rebuilding $service with --no-cache"
                run_compose "$service" "docker-compose down"
                run_compose "$service" "docker-compose build --no-cache"
                run_compose "$service" "docker-compose up -d"
            else
                run_compose "$service" "docker-compose down"
                run_compose "$service" "docker-compose up -d --build"
            fi
            ;;
        shutdown)
            run_compose "$service" "docker-compose down -v"
            ;;
        cleanup)
            echo "Full cleanup for $service"
            run_compose "$service" "docker-compose down -v --rmi all"
            ;;
    esac

    echo ""
done

echo "============================================="
echo "Complete!"
echo "============================================="
