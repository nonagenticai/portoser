#!/usr/bin/env bash
# =============================================================================
# lib/cluster/build.sh - Docker Image Build Library
#
# Provides functions for building Docker images locally on each device.
# Builds are performed natively without registry push/pull operations.
#
# Functions:
#   - build_local_service()         Build a single service locally
#   - build_services_parallel()     Build multiple services in parallel
#   - get_service_build_dir()       Get the build directory for a service
#
# Dependencies: docker, yq
# Created: 2025-12-03
# Updated: 2025-12-09 - Removed registry references for local builds
# =============================================================================

set -euo pipefail

# Default configuration
BUILD_LOG_DIR="/tmp"

# =============================================================================
# get_service_build_dir - Get the build directory for a service
#
# Reads the registry.yml file to determine the build directory for a service
# by parsing the docker_compose or service_file path.
#
# Parameters:
#   $1 - service_name (required): Name of the service
#   $2 - registry_file (required): Path to registry.yml
#   $3 - base_dir (optional): Base directory for service paths
#                             Default: "<sync-base>"
#
# Returns:
#   0 - Successfully found build directory
#   1 - Service not found or no build directory
#
# Outputs:
#   Prints the absolute build directory path to stdout
#   Prints error messages to stderr
#
# Example:
#   build_dir=$(get_service_build_dir "myservice" "/path/to/registry.yml")
# =============================================================================
get_service_build_dir() {
    local service_name="$1"
    local registry_file="$2"
    local base_dir="${3:-<sync-base>}"

    # Validate parameters
    if [[ -z "$service_name" ]]; then
        echo "Error: service_name parameter is required" >&2
        return 1
    fi

    if [[ -z "$registry_file" ]]; then
        echo "Error: registry_file parameter is required" >&2
        return 1
    fi

    if [[ ! -f "$registry_file" ]]; then
        echo "Error: Registry file not found: $registry_file" >&2
        return 1
    fi

    # Check for yq
    if ! command -v yq &> /dev/null; then
        echo "Error: yq is not installed or not in PATH" >&2
        return 1
    fi

    # Get the docker_compose or service_file path
    local compose_path
    compose_path=$(yq eval ".services.\"$service_name\".docker_compose // .services.\"$service_name\".service_file" "$registry_file" 2>/dev/null)

    # Handle null/empty
    if [[ -z "$compose_path" ]] || [[ "$compose_path" == "null" ]]; then
        echo "Error: Could not find docker_compose or service_file for service: $service_name" >&2
        return 1
    fi

    # Extract directory from path like /myservice/docker-compose.yml -> myservice
    local service_dir
    service_dir=$(echo "$compose_path" | cut -d'/' -f2)

    if [[ -z "$service_dir" ]]; then
        echo "Error: Could not parse service directory from: $compose_path" >&2
        return 1
    fi

    # Construct full path
    local full_path="${base_dir}/${service_dir}"

    # Verify directory exists
    if [[ ! -d "$full_path" ]]; then
        echo "Error: Build directory does not exist: $full_path" >&2
        return 1
    fi

    echo "$full_path"
    return 0
}

# =============================================================================
# build_local_service - Build a Docker image locally
#
# Builds a Docker image natively on the local device. Images are built
# for the native architecture and stored locally without registry operations.
# Build logs are written to /tmp/build-<service>.log
#
# Parameters:
#   $1 - service_name (required): Name of the service to build
#   $2 - build_dir (required): Directory containing Dockerfile
#   $3 - no_cache (optional): Set to "true" to disable cache
#                             Default: "false"
#
# Returns:
#   0 - Build successful
#   1 - Build failed
#   2 - Invalid parameters or missing Dockerfile
#
# Outputs:
#   Prints status messages to stderr
#   Build logs written to /tmp/build-<service>.log
#
# Example:
#   build_local_service "myservice" "/path/to/myservice" "false"
# =============================================================================
build_local_service() {
    local service_name="$1"
    local build_dir="$2"
    local no_cache="${3:-false}"

    # Validate parameters
    if [[ -z "$service_name" ]]; then
        echo "Error: service_name parameter is required" >&2
        return 2
    fi

    if [[ -z "$build_dir" ]]; then
        echo "Error: build_dir parameter is required" >&2
        return 2
    fi

    # Validate build directory
    if [[ ! -d "$build_dir" ]]; then
        echo "Error: Build directory not found: $build_dir" >&2
        return 2
    fi

    if [[ ! -f "$build_dir/Dockerfile" ]]; then
        echo "Error: Dockerfile not found in $build_dir" >&2
        return 2
    fi

    # Check docker is available
    if ! command -v docker &> /dev/null; then
        echo "Error: docker is not installed or not in PATH" >&2
        return 2
    fi

    # Construct image tag (local only)
    local image_tag="${service_name}:latest"
    local log_file="${BUILD_LOG_DIR}/build-${service_name}.log"

    # Build arguments
    local build_args=(
        --tag "$image_tag"
    )

    # Add cache control
    if [[ "$no_cache" == "true" ]]; then
        build_args+=(--no-cache)
    fi

    # Execute build
    echo "Building $service_name locally..." >&2

    if docker build "${build_args[@]}" "$build_dir" > "$log_file" 2>&1; then
        echo "Successfully built $service_name" >&2
        return 0
    else
        echo "Failed to build $service_name (see $log_file)" >&2
        return 1
    fi
}

# =============================================================================
# build_services_parallel - Build multiple services in parallel batches
#
# Builds multiple services in parallel with configurable batch size. Tracks
# success/failure counts and provides progress callbacks.
#
# Parameters:
#   $1 - services (required): Newline-separated list of service names
#   $2 - registry_file (required): Path to registry.yml
#   $3 - batch_size (optional): Number of parallel builds
#                               Default: 4
#   $4 - no_cache (optional): Set to "true" to disable cache
#                             Default: "false"
#   $5 - progress_callback (optional): Function to call with progress updates
#                                      Signature: callback(current, total, service, status)
#
# Returns:
#   0 - All builds successful
#   1 - One or more builds failed
#   2 - Invalid parameters
#
# Outputs:
#   Prints progress to stderr
#   Calls progress_callback if provided
#
# Example:
#   services="myservice\nworkers\ntools"
#   build_services_parallel "$services" "/path/to/registry.yml" 4
# =============================================================================
build_services_parallel() {
    local services="$1"
    local registry_file="$2"
    local batch_size="${3:-4}"
    local no_cache="${4:-false}"
    local progress_callback="${5:-}"

    # Validate parameters
    if [[ -z "$services" ]]; then
        echo "Error: services parameter is required" >&2
        return 2
    fi

    if [[ -z "$registry_file" ]]; then
        echo "Error: registry_file parameter is required" >&2
        return 2
    fi

    if [[ ! -f "$registry_file" ]]; then
        echo "Error: Registry file not found: $registry_file" >&2
        return 2
    fi

    # Convert services to array
    local service_array=()
    while IFS= read -r service; do
        [[ -n "$service" ]] && service_array+=("$service")
    done <<< "$services"

    local total=${#service_array[@]}
    if [[ $total -eq 0 ]]; then
        echo "Warning: No services to build" >&2
        return 0
    fi

    echo "Building $total services (batch size: $batch_size)..." >&2

    local built=0
    local failed=0
    local skipped=0
    local failed_services=()

    # Process in batches
    for ((i=0; i<total; i+=batch_size)); do
        local batch=("${service_array[@]:i:batch_size}")
        local batch_num
        batch_num=$(((i / batch_size) + 1))
        local total_batches
        total_batches=$(((total + batch_size - 1) / batch_size))

        echo "Batch $batch_num/$total_batches (${#batch[@]} services)..." >&2

        local pids=()
        local build_dirs=()

        # Start parallel builds
        for service in "${batch[@]}"; do
            # Get build directory
            local build_dir
            if ! build_dir=$(get_service_build_dir "$service" "$registry_file"); then
                echo "Skipping $service (no build directory)" >&2
                ((skipped++))
                if [[ -n "$progress_callback" ]]; then $progress_callback $((built + failed + skipped)) "$total" "$service" "skipped" || true; fi
                continue
            fi

            # Check for Dockerfile
            if [[ ! -f "$build_dir/Dockerfile" ]]; then
                echo "Skipping $service (no Dockerfile - 3rd party image)" >&2
                ((skipped++))
                if [[ -n "$progress_callback" ]]; then $progress_callback $((built + failed + skipped)) "$total" "$service" "skipped" || true; fi
                continue
            fi

            # Start build in background
            (
                build_local_service "$service" "$build_dir" "$no_cache"
                exit $?
            ) &
            pids+=($!)
            build_dirs+=("$service")
        done

        # Wait for batch to complete
        for idx in "${!pids[@]}"; do
            local pid=${pids[$idx]}
            local svc=${build_dirs[$idx]}

            wait "$pid"
            local exit_code=$?

            if [[ $exit_code -eq 0 ]]; then
                ((built++))
                if [[ -n "$progress_callback" ]]; then $progress_callback $((built + failed + skipped)) "$total" "$svc" "success" || true; fi
            else
                ((failed++))
                failed_services+=("$svc")
                if [[ -n "$progress_callback" ]]; then $progress_callback $((built + failed + skipped)) "$total" "$svc" "failed" || true; fi
            fi
        done

        echo "Batch complete: $built built, $skipped skipped, $failed failed" >&2
    done

    echo "Build complete: $built successful, $skipped skipped, $failed failed" >&2

    if [[ $failed -gt 0 ]]; then
        echo "Failed services:" >&2
        for svc in "${failed_services[@]}"; do
            echo "  - $svc (log: ${BUILD_LOG_DIR}/build-${svc}.log)" >&2
        done
        return 1
    fi

    return 0
}


# =============================================================================
# Library initialization check
# =============================================================================

# Verify this script is being sourced, not executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This library should be sourced, not executed directly" >&2
    echo "Usage: source lib/cluster/build.sh" >&2
    exit 1
fi
