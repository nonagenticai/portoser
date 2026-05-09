#!/usr/bin/env bash
# =============================================================================
# lib/cluster/buildx.sh - Docker Buildx Management Library
#
# Provides functions for managing Docker buildx builders and contexts for
# multi-platform (arm64/amd64) container builds across the cluster.
#
# Functions:
#   - setup_cluster_buildx()        Configure buildx builder for the cluster
#   - verify_buildx_ready()         Verify buildx builder is ready
#   - create_docker_contexts()      Create Docker contexts for all Pis
#   - get_buildx_builder_name()     Get the cluster builder name
#
# Dependencies: docker, yq
# Created: 2025-12-03
# =============================================================================

set -euo pipefail

# Default builder name
BUILDX_DEFAULT_BUILDER="portoser-builder"

# =============================================================================
# setup_cluster_buildx - Configure Docker buildx builder for multi-platform builds
#
# Creates or recreates a Docker buildx builder with support for linux/arm64
# and linux/amd64 platforms. The builder uses the docker-container driver
# for optimal cross-platform build support.
#
# Parameters:
#   $1 - builder_name (optional): Name for the buildx builder
#                                  Default: "portoser-builder"
#   $2 - recreate (optional): Set to "true" to force recreation
#                             Default: "false"
#
# Returns:
#   0 - Builder configured successfully
#   1 - Failed to configure builder
#
# Environment:
#   BUILDX_DEFAULT_BUILDER - Default builder name if not specified
#
# Example:
#   setup_cluster_buildx "my-builder" "true"
#   setup_cluster_buildx  # Uses default name
# =============================================================================
setup_cluster_buildx() {
    local builder_name="${1:-$BUILDX_DEFAULT_BUILDER}"
    local recreate="${2:-false}"

    # Validate builder name
    if [[ -z "$builder_name" ]]; then
        echo "Error: Builder name cannot be empty" >&2
        return 1
    fi

    # Check if docker is available
    if ! command -v docker &> /dev/null; then
        echo "Error: docker is not installed or not in PATH" >&2
        return 1
    fi

    # Check if builder exists
    if docker buildx inspect "$builder_name" &> /dev/null; then
        if [[ "$recreate" == "true" ]]; then
            echo "Removing existing builder: $builder_name" >&2
            docker buildx rm "$builder_name" || {
                echo "Error: Failed to remove existing builder" >&2
                return 1
            }
        else
            echo "Builder '$builder_name' already exists (use recreate=true to replace)" >&2
            return 0
        fi
    fi

    # Create new builder
    echo "Creating buildx builder: $builder_name" >&2
    if ! docker buildx create \
        --name "$builder_name" \
        --driver docker-container \
        --bootstrap \
        --use; then
        echo "Error: Failed to create buildx builder" >&2
        return 1
    fi

    # Verify the builder
    if ! docker buildx inspect "$builder_name" &> /dev/null; then
        echo "Error: Builder created but not accessible" >&2
        return 1
    fi

    echo "Successfully configured buildx builder: $builder_name" >&2
    return 0
}

# =============================================================================
# verify_buildx_ready - Verify that buildx builder is ready for use
#
# Checks that the specified builder exists, is running, and supports the
# required platforms (linux/arm64, linux/amd64).
#
# Parameters:
#   $1 - builder_name (optional): Name of the buildx builder to verify
#                                  Default: "portoser-builder"
#
# Returns:
#   0 - Builder is ready
#   1 - Builder is not ready or missing
#
# Outputs:
#   Prints status messages to stderr
#   On success, prints "READY" to stdout
#
# Example:
#   if verify_buildx_ready "my-builder"; then
#       echo "Builder is ready"
#   fi
# =============================================================================
verify_buildx_ready() {
    local builder_name="${1:-$BUILDX_DEFAULT_BUILDER}"

    # Validate builder name
    if [[ -z "$builder_name" ]]; then
        echo "Error: Builder name cannot be empty" >&2
        return 1
    fi

    # Check if docker is available
    if ! command -v docker &> /dev/null; then
        echo "Error: docker is not installed or not in PATH" >&2
        return 1
    fi

    # Check if builder exists
    if ! docker buildx inspect "$builder_name" &> /dev/null; then
        echo "Error: Builder '$builder_name' does not exist" >&2
        return 1
    fi

    # Verify platforms
    local platforms
    platforms=$(docker buildx inspect "$builder_name" 2>/dev/null | grep -i "Platforms:" | head -1)

    if [[ -z "$platforms" ]]; then
        echo "Error: Could not determine builder platforms" >&2
        return 1
    fi

    # Check for required platforms
    if ! echo "$platforms" | grep -q "linux/arm64"; then
        echo "Error: Builder does not support linux/arm64" >&2
        return 1
    fi

    echo "READY"
    return 0
}

# =============================================================================
# create_docker_contexts - Create Docker contexts for all Pi hosts
#
# Reads the registry.yml file to discover all Pi hosts and creates SSH-based
# Docker contexts for each one. Existing contexts are removed and recreated.
# Tests SSH connectivity before creating each context.
#
# Parameters:
#   $1 - registry_file (required): Path to registry.yml file
#
# Returns:
#   0 - All contexts created successfully
#   1 - One or more contexts failed to create
#   2 - Invalid parameters or missing dependencies
#
# Environment:
#   None
#
# Example:
#   create_docker_contexts "/path/to/registry.yml"
# =============================================================================
create_docker_contexts() {
    local registry_file="$1"

    # Validate parameters
    if [[ -z "$registry_file" ]]; then
        echo "Error: registry_file parameter is required" >&2
        return 2
    fi

    if [[ ! -f "$registry_file" ]]; then
        echo "Error: Registry file not found: $registry_file" >&2
        return 2
    fi

    # Check dependencies
    if ! command -v docker &> /dev/null; then
        echo "Error: docker is not installed or not in PATH" >&2
        return 2
    fi

    if ! command -v yq &> /dev/null; then
        echo "Error: yq is not installed or not in PATH" >&2
        return 2
    fi

    # Get Pi hosts from registry
    local pi_hosts
    pi_hosts=$(yq eval '.hosts | to_entries | .[] | select(.key | test("^pi[0-9]+$")) | .key' "$registry_file" 2>/dev/null)

    if [[ -z "$pi_hosts" ]]; then
        echo "Warning: No Pi hosts found in registry" >&2
        return 0
    fi

    local failed_count=0
    local success_count=0

    # Create context for each Pi
    while IFS= read -r pi_name; do
        [[ -z "$pi_name" ]] && continue

        echo "Setting up Docker context for $pi_name..." >&2

        # Get Pi details
        local pi_ip
        local pi_user
        pi_ip=$(yq eval ".hosts.${pi_name}.ip" "$registry_file" 2>/dev/null)
        pi_user=$(yq eval ".hosts.${pi_name}.ssh_user" "$registry_file" 2>/dev/null)

        if [[ -z "$pi_ip" ]] || [[ "$pi_ip" == "null" ]]; then
            echo "  Error: Could not determine IP for $pi_name" >&2
            ((failed_count++))
            continue
        fi

        if [[ -z "$pi_user" ]] || [[ "$pi_user" == "null" ]]; then
            echo "  Error: Could not determine SSH user for $pi_name" >&2
            ((failed_count++))
            continue
        fi

        # Test SSH connectivity
        if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${pi_user}@${pi_ip}" "echo 'SSH OK'" &> /dev/null; then
            echo "  Warning: Cannot connect to ${pi_name} via SSH (${pi_user}@${pi_ip})" >&2
            echo "  Skipping context creation" >&2
            ((failed_count++))
            continue
        fi

        # Remove existing context if present
        if docker context inspect "$pi_name" &> /dev/null; then
            docker context rm "$pi_name" -f &> /dev/null || true
        fi

        # Create SSH-based context
        if docker context create "$pi_name" \
            --description "Docker on $pi_name ($pi_ip)" \
            --docker "host=ssh://${pi_user}@${pi_ip}" &> /dev/null; then
            echo "  Created context: $pi_name -> ssh://${pi_user}@${pi_ip}" >&2
            ((success_count++))
        else
            echo "  Error: Failed to create context for $pi_name" >&2
            ((failed_count++))
        fi
    done <<< "$pi_hosts"

    echo "Docker contexts created: $success_count successful, $failed_count failed" >&2

    if [[ $failed_count -gt 0 ]]; then
        return 1
    fi

    return 0
}

# =============================================================================
# get_buildx_builder_name - Get the name of the cluster buildx builder
#
# Returns the builder name that should be used for cluster builds. Can be
# overridden with the BUILDX_BUILDER environment variable.
#
# Parameters:
#   None
#
# Returns:
#   0 - Always successful
#
# Outputs:
#   Prints the builder name to stdout
#
# Environment:
#   BUILDX_BUILDER - Override the default builder name
#
# Example:
#   builder=$(get_buildx_builder_name)
#   docker buildx build --builder "$builder" ...
# =============================================================================
get_buildx_builder_name() {
    echo "${BUILDX_BUILDER:-$BUILDX_DEFAULT_BUILDER}"
    return 0
}

# =============================================================================
# Library initialization check
# =============================================================================

# Verify this script is being sourced, not executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This library should be sourced, not executed directly" >&2
    echo "Usage: source lib/cluster/buildx.sh" >&2
    exit 1
fi
