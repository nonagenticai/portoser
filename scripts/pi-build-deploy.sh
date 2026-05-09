#!/opt/homebrew/bin/bash
set -euo pipefail

# =============================================================================
# Pi Build & Deploy Script
#
# DEPRECATED: Consider using: portoser cluster deploy
#
# Single unified script to build and deploy all Docker services to pi1-pi4
# Reads registry.yml as source of truth, builds locally on each device
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib/cluster"

# Source cluster libraries
if [[ -f "${LIB_DIR}/build.sh" ]]; then
    # shellcheck source=lib/cluster/build.sh
    source "${LIB_DIR}/build.sh"
fi
if [[ -f "${LIB_DIR}/deploy.sh" ]]; then
    # shellcheck source=lib/cluster/deploy.sh
    source "${LIB_DIR}/deploy.sh"
fi

PORTOSER_ROOT="${PORTOSER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CLUSTER_CONF="${CLUSTER_CONF:-$PORTOSER_ROOT/cluster.conf}"
REGISTRY_FILE="${REGISTRY_FILE:-$PORTOSER_ROOT/registry.yml}"
DOCUMENTS_DIR="${DOCUMENTS_DIR:-$(dirname "$PORTOSER_ROOT")}"
BATCH_SIZE="${BATCH_SIZE:-4}"

# Per-host working paths come from cluster.conf (CLUSTER_PATHS) so this script
# is not tied to any particular hostname or layout. CLUSTER_HOSTS provides the
# SSH targets. SSH must use key-based auth (see lib/cluster/ssh_keys.sh).
if [[ -f "$CLUSTER_CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CLUSTER_CONF"
fi
# =============================================================================
# HELP & ARGUMENT PARSING
# =============================================================================

show_help() {
    cat << HELP
Pi Build & Deploy Script
Unified script to build and deploy all Docker services to Raspberry Pis.

Usage: $0 [MODE]

Modes:
  all              Build (with cache) and deploy all Pi services (default)
  rebuild          Build with --no-cache and deploy all Pi services
  build-only       Only sync files to each Pi (no build/deploy)
  deploy-only      Only build and deploy on each Pi (assumes files synced)

Services Managed:
  Discovered from registry.yml: every service whose \`current_host\` is
  pi1, pi2, pi3, or pi4 and whose \`deployment_type\` is \`docker\`.

Build Details:
  - Syncs source files to each Pi device
  - Builds locally on each Pi for native platform
  - Loads images locally for deployment
  - Sources from \$DOCUMENTS_DIR (override with DOCUMENTS_DIR env var)

Deploy Details:
  - SSHs to each Pi
  - Runs docker compose build && docker compose down && up -d

Examples:
  $0                    # Build and deploy everything
  $0 rebuild            # Rebuild from scratch (no cache)
  $0 build-only         # Just sync files to each Pi
  $0 deploy-only        # Just build and deploy on each Pi

HELP
}

# Parse mode
MODE="all"
if [ $# -gt 0 ]; then
    case "$1" in
        all|rebuild|build-only|deploy-only)
            MODE="$1"
            ;;
        -h|--help|help)
            show_help
            exit 0
            ;;
        *)
            echo "❌ Unknown mode: $1"
            show_help
            exit 1
            ;;
    esac
fi

# Set build flags based on mode
BUILD=true
DEPLOY=true
NO_CACHE=false

case "$MODE" in
    rebuild)
        NO_CACHE=true
        ;;
    build-only)
        DEPLOY=false
        ;;
    deploy-only)
        BUILD=false
        ;;
esac

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

get_pi_services() {
    local pi="$1"
    yq eval ".services | to_entries | .[] | select(.value.current_host == \"$pi\" and .value.deployment_type == \"docker\") | .key" "$REGISTRY_FILE"
}

get_all_pi_services() {
    yq eval '.services | to_entries | .[] | select(.value.current_host == "pi1" or .value.current_host == "pi2" or .value.current_host == "pi3" or .value.current_host == "pi4") | select(.value.deployment_type == "docker") | .key' "$REGISTRY_FILE"
}

get_service_dir() {
    local service="$1"
    local docker_compose_path

    # Try docker_compose first, then service_file
    docker_compose_path=$(yq eval ".services.\"$service\".docker_compose // .services.\"$service\".service_file" "$REGISTRY_FILE")

    # Handle null/empty
    if [ "$docker_compose_path" = "null" ] || [ -z "$docker_compose_path" ]; then
        echo ""
        return 1
    fi

    # Extract directory from path like /myservice/docker-compose.yml -> myservice
    echo "$docker_compose_path" | cut -d'/' -f2
}

# =============================================================================
# BUILD FUNCTIONS
# =============================================================================

build_service() {
    local service="$1"
    local no_cache_flag="$2"

    local service_dir
    service_dir=$(get_service_dir "$service")

    if [ -z "$service_dir" ]; then
        echo "  ⚠️  $service: Could not determine service directory"
        return 1
    fi

    local service_path="$DOCUMENTS_DIR/$service_dir"

    if [ ! -d "$service_path" ]; then
        echo "  ⚠️  $service: Directory not found: $service_path"
        return 1
    fi

    if [ ! -f "$service_path/Dockerfile" ]; then
        echo "  ⏭️  $service: No Dockerfile (3rd party image)"
        return 2  # Return 2 for "skip" vs 1 for "error"
    fi

    local image_tag="$service:latest"
    local build_args=(
        --tag "$image_tag"
        --load
    )

    if [ "$no_cache_flag" = "true" ]; then
        build_args+=(--no-cache)
    fi

    echo "  🔨 Building $service..."
    if docker build "${build_args[@]}" "$service_path" > "/tmp/build-$service.log" 2>&1; then
        echo "  ✅ $service built and loaded"
        return 0
    else
        echo "  ❌ $service build failed (see /tmp/build-$service.log)"
        return 1
    fi
}

build_all_services() {
    echo "════════════════════════════════════════════════════════"
    echo "BUILDING ALL PI SERVICES"
    if [ "$NO_CACHE" = "true" ]; then
        echo "Mode: REBUILD (--no-cache)"
    else
        echo "Mode: BUILD (with cache)"
    fi
    echo "════════════════════════════════════════════════════════"
    echo ""

    # Get all Pi services
    local services
    mapfile -t services < <(get_all_pi_services)

    local total=${#services[@]}
    echo "Total services to build: $total"
    echo "Mode: Local builds (no registry)"
    echo ""

    local built=0 failed=0
    local service
    for service in "${services[@]}"; do
        if build_service "$service" "$NO_CACHE"; then
            ((built++))
        else
            local rc=$?
            # build_service returns 2 for "skipped" (e.g. 3rd-party image,
            # no Dockerfile) — don't count those as failures.
            [ "$rc" -eq 2 ] || ((failed++))
        fi
    done

    echo ""
    echo "Build summary: $built built, $failed failed (of $total)"
    return "$failed"
}

deploy_to_pi() {
    local pi="$1"

    echo ""
    echo "─────────────────────────────────────────────────────────"
    echo "DEPLOYING TO: $pi"
    echo "─────────────────────────────────────────────────────────"

    local services
    mapfile -t services < <(get_pi_services "$pi")

    if [ ${#services[@]} -eq 0 ]; then
        echo "  No services for $pi"
        return 0
    fi

    echo "  Services: ${#services[@]}"
    echo ""

    local deployed=0
    local failed=0

    for service in "${services[@]}"; do
        if deploy_service_to_pi "$service" "$pi"; then
            ((deployed++))
        else
            ((failed++))
        fi
    done

    echo ""
    echo "  $pi: $deployed deployed, $failed failed"

    return $failed
}

deploy_all_services() {
    echo "════════════════════════════════════════════════════════"
    echo "DEPLOYING TO ALL PIS"
    echo "════════════════════════════════════════════════════════"
    echo ""

    local pis=("pi1" "pi2" "pi3" "pi4")
    local total_failed=0

    # Deploy to each Pi sequentially (Pis can't handle parallel load well)
    for pi in "${pis[@]}"; do
        if deploy_to_pi "$pi"; then
            :  # Success
        else
            ((total_failed += $?))
        fi
    done

    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "DEPLOY PHASE COMPLETE"
    echo "════════════════════════════════════════════════════════"

    if [ $total_failed -gt 0 ]; then
        echo "⚠️  Some deployments failed"
        return 1
    else
        echo "✅ All services deployed successfully"
        return 0
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

echo "════════════════════════════════════════════════════════"
echo "PI BUILD & DEPLOY"
echo "════════════════════════════════════════════════════════"
echo "Mode: $MODE"
echo "Registry: $REGISTRY_FILE"
echo ""

# Verify registry.yml exists
if [ ! -f "$REGISTRY_FILE" ]; then
    echo "❌ Registry file not found: $REGISTRY_FILE"
    exit 1
fi

# Execute based on mode
EXIT_CODE=0

if [ "$BUILD" = "true" ]; then
    if ! build_all_services; then
        echo ""
        echo "❌ Build phase failed"
        EXIT_CODE=1

        if [ "$DEPLOY" = "true" ]; then
            echo "⚠️  Skipping deploy phase due to build failures"
            exit $EXIT_CODE
        fi
    fi
fi

if [ "$DEPLOY" = "true" ]; then
    if ! deploy_all_services; then
        echo ""
        echo "❌ Deploy phase failed"
        EXIT_CODE=1
    fi
fi

echo ""
echo "════════════════════════════════════════════════════════"
if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ SUCCESS"
else
    echo "❌ COMPLETED WITH ERRORS"
fi
echo "════════════════════════════════════════════════════════"
echo ""

exit $EXIT_CODE
