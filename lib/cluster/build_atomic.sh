#!/usr/bin/env bash
# =============================================================================
# lib/cluster/build_atomic.sh - Atomic Build Operations for Local Builds
#
# Provides atomic operations and race condition prevention for concurrent
# local builds. Simplified for native builds without registry operations.
#
# Features:
#   - Build atomicity with rollback
#   - Build cache management
#   - Concurrent build safety
#   - Build attempt tracking
#
# Functions:
#   - atomic_build_service()       Build with atomic guarantees
#   - reset_build_cache()          Clear build cache safely
# =============================================================================

set -euo pipefail

# Source required libraries. Resolve via this file's own directory so we
# don't depend on the caller having $SCRIPT_DIR set (broken under set -u).
_CLUSTER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB_DIR="$(cd "$_CLUSTER_LIB_DIR/.." && pwd)"

if [[ -f "$_LIB_DIR/locks.sh" ]]; then
    # shellcheck source=lib/locks.sh
    source "$_LIB_DIR/locks.sh"
fi

if [[ -f "$_CLUSTER_LIB_DIR/build.sh" ]]; then
    # shellcheck source=lib/cluster/build.sh
    source "$_CLUSTER_LIB_DIR/build.sh"
fi
unset _CLUSTER_LIB_DIR _LIB_DIR

# Configuration
BUILD_CACHE_DIR="${BUILD_CACHE_DIR:-/tmp/build_cache}"

# Initialize cache directory
mkdir -p "$BUILD_CACHE_DIR" 2>/dev/null || true

# =============================================================================
# reset_build_cache - Clear Docker build cache safely
#
# Removes build cache to free up space or fix cache corruption.
# Must be called when no builds are in progress.
#
# Returns:
#   0 - Cache cleared successfully
#   1 - Cache clearing failed
# =============================================================================
reset_build_cache() {
    echo "Clearing Docker build cache..." >&2

    local lock_name="build_cache_clear"
    if ! acquire_lock "$lock_name" 30 "Clearing build cache"; then
        echo "Error: Cannot acquire cache clear lock (builds in progress?)" >&2
        return 1
    fi

    # Clear cache using prune
    if docker builder prune --all --force 2>/dev/null; then
        echo "Build cache cleared successfully" >&2
        release_lock "$lock_name"
        return 0
    else
        echo "Error: Failed to clear build cache" >&2
        release_lock "$lock_name"
        return 1
    fi
}

# =============================================================================
# atomic_build_service - Build with atomic guarantees
#
# Performs a local build with lock coordination and retry capability.
# Wraps build_local_service with safety checks.
#
# Parameters:
#   $1 - service_name (required): Service to build
#   $2 - build_dir (required): Build directory
#   $3 - no_cache (optional): Disable cache
#   $4 - max_retries (optional): Max build attempts (default: 3)
#
# Returns:
#   0 - Build successful
#   1 - Build failed after retries
#   2 - Invalid parameters
#
# Outputs:
#   Build logs to stderr and /tmp/build-<service>.log
#
# Example:
#   atomic_build_service "myservice" "/path/to/myservice" "false"
# =============================================================================
atomic_build_service() {
    local service_name="$1"
    local build_dir="$2"
    local no_cache="${3:-false}"
    local max_retries="${4:-3}"

    if [[ -z "$service_name" ]] || [[ -z "$build_dir" ]]; then
        echo "Error: service_name and build_dir required" >&2
        return 2
    fi

    echo "Starting atomic build for $service_name" >&2

    # Phase 1: Acquire build lock
    echo "  [PHASE 1] Acquiring build lock..." >&2
    local lock_name="build_${service_name}"
    if ! acquire_lock "$lock_name" 30 "Building $service_name"; then
        echo "Error: Failed to acquire build lock (another build in progress?)" >&2
        return 1
    fi

    # Phase 2: Perform build with retries
    echo "  [PHASE 2] Executing build..." >&2
    local attempt=1
    local build_success=0

    while [[ $attempt -le $max_retries ]]; do
        if [[ $attempt -gt 1 ]]; then
            echo "  Retry attempt $attempt/$max_retries..." >&2
            sleep 5
        fi

        # Attempt build
        if build_local_service "$service_name" "$build_dir" "$no_cache" 2>&1; then
            build_success=1
            break
        fi

        ((attempt++))
    done

    release_lock "$lock_name"

    if [[ $build_success -eq 1 ]]; then
        echo "Build successful for $service_name" >&2
        return 0
    else
        echo "Error: Build failed after $max_retries attempts" >&2
        return 1
    fi
}

# Export functions for use in subshells
export -f reset_build_cache
export -f atomic_build_service
