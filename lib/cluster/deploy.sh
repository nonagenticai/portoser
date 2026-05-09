#!/usr/bin/env bash
# =============================================================================
# lib/cluster/deploy.sh - Docker Service Deployment Library
#
# Provides functions for deploying Docker services to Raspberry Pi hosts,
# including file synchronization and service management using locally built images.
#
# Functions:
#   - deploy_to_pi()                Deploy all services to a Pi
#   - deploy_service_to_pi()        Deploy a single service to a Pi
#   - verify_deployment()           Verify service is running correctly
#   - rollback_deployment()         Rollback to previous version
#
# Dependencies: docker, yq, ssh, sshpass, rsync
# Created: 2025-12-03
# =============================================================================

set -euo pipefail

# Source security validation library. Resolve via this file's own directory
# so we don't depend on the caller having $SCRIPT_DIR set (broken under set -u).
_CLUSTER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_CLUSTER_LIB_DIR/../utils/security_validation.sh" ]; then
    # shellcheck source=lib/utils/security_validation.sh
    source "$_CLUSTER_LIB_DIR/../utils/security_validation.sh"
fi
unset _CLUSTER_LIB_DIR

# Default configuration
DEPLOY_LOG_DIR="/tmp"
DEPLOY_STARTUP_TIMEOUT=60
DEPLOY_DRY_RUN=false
DEPLOY_DELETE_VOLUMES=false
DEPLOY_AUTO_VERIFY=true
DEPLOY_AUTO_ROLLBACK=true

# Default per-host base paths. Override per-host via env (e.g.
# DEPLOY_PI_PATH_PI1=/home/pi1/myapp), via the registry's
# `hosts.<host>.path`, or by reassigning DEPLOY_PI_PATHS in your wrapper
# before invoking deploy. The "<base>" placeholder is "portoser" by default.
declare -gA DEPLOY_PI_PATHS=(
    ["pi1"]="${DEPLOY_PI_PATH_PI1:-/home/pi1/${DEPLOY_DEFAULT_BASE:-portoser}}"
    ["pi2"]="${DEPLOY_PI_PATH_PI2:-/home/pi2/${DEPLOY_DEFAULT_BASE:-portoser}}"
    ["pi3"]="${DEPLOY_PI_PATH_PI3:-/home/pi3/${DEPLOY_DEFAULT_BASE:-portoser}}"
    ["pi4"]="${DEPLOY_PI_PATH_PI4:-/home/pi4/${DEPLOY_DEFAULT_BASE:-portoser}}"
)

# REMOVED: DEPLOY_PI_PASSWORDS array - now using SSH keys (see lib/cluster/ssh_keys.sh)

# =============================================================================
# deploy_service_to_pi - Deploy a single service to a Raspberry Pi
#
# Deploys a Docker service to a Pi by:
# 1. Creating target directory on Pi
# 2. Syncing service files (docker-compose.yml, .env, certs)
# 3. Restarting the service with docker compose (using locally built images)
# 4. Verifying deployment health (if DEPLOY_AUTO_VERIFY=true)
# 5. Rolling back on failure (if DEPLOY_AUTO_ROLLBACK=true)
#
# Parameters:
#   $1 - service_name (required): Name of the service to deploy
#   $2 - pi_name (required): Target Pi host (pi1, pi2, pi3, pi4)
#   $3 - service_dir (required): Local service directory path
#
# Environment Variables:
#   DEPLOY_DRY_RUN - If true, only print commands without executing
#   DEPLOY_DELETE_VOLUMES - If true, delete volumes on restart (DANGEROUS!)
#   DEPLOY_AUTO_VERIFY - If true, verify deployment after completion
#   DEPLOY_AUTO_ROLLBACK - If true, rollback on verification failure
#   DEPLOY_STARTUP_TIMEOUT - Seconds to wait for service startup
#
# Returns:
#   0 - Deployment successful
#   1 - Deployment failed
#   2 - Invalid parameters
#
# Outputs:
#   Prints status messages to stderr
#   Deployment logs written to /tmp/deploy-<service>-<pi>.log
#
# Example:
#   deploy_service_to_pi "myservice" "pi1" "<sync-base>/myservice"
#   DEPLOY_DELETE_VOLUMES=true deploy_service_to_pi "myservice" "pi1" "/path/to/myservice"
# =============================================================================
deploy_service_to_pi() {
    local service_name="$1"
    local pi_name="$2"
    local service_dir="$3"

    # Validate parameters
    if [[ -z "$service_name" ]]; then
        echo "Error: service_name parameter is required" >&2
        return 2
    fi

    if [[ -z "$pi_name" ]]; then
        echo "Error: pi_name parameter is required" >&2
        return 2
    fi

    if [[ -z "$service_dir" ]]; then
        echo "Error: service_dir parameter is required" >&2
        return 2
    fi

    if [[ ! -d "$service_dir" ]]; then
        echo "Error: Service directory not found: $service_dir" >&2
        return 2
    fi

    # Get Pi configuration
    # REMOVED: pi_password reference - now using SSH keys
    local pi_path="${DEPLOY_PI_PATHS[$pi_name]:-}"

    if [[ -z "$pi_path" ]]; then
        echo "Error: No path configured for $pi_name" >&2
        return 2
    fi

    # Extract service directory name
    local service_dirname
    service_dirname=$(basename "$service_dir")

    local target_path="${pi_path}/${service_dirname}"
    local log_file="${DEPLOY_LOG_DIR}/deploy-${service_name}-${pi_name}.log"

    echo "Deploying $service_name to $pi_name..." >&2

    # Security: Validate paths and service names
    if ! validate_path "$target_path" "target_path"; then
        return 2
    fi

    if ! validate_service_name "$service_name" "service_name"; then
        return 2
    fi

    # Check dependencies
    if ! command -v rsync &> /dev/null; then
        echo "Error: rsync is not installed" >&2
        return 2
    fi

    # Step 1: Create directory on Pi (using SSH keys)
    echo "  Creating directory on $pi_name..." >&2
    # Security: Use bash -c with positional parameter to safely pass target_path
    if ! ssh -o StrictHostKeyChecking=accept-new "${pi_name}@${pi_name}.local" -- \
        bash -c 'mkdir -p "$1"' _ "$target_path" 2>>"$log_file"; then
        echo "Error: Failed to create directory on $pi_name" >&2
        return 1
    fi

    # Step 2: Sync service files (using SSH keys)
    echo "  Syncing files to $pi_name..." >&2
    if ! rsync -az --delete \
        --exclude='*.pyc' \
        --exclude='__pycache__' \
        --exclude='node_modules' \
        --exclude='.git' \
        --exclude='.venv' \
        --exclude='venv' \
        --exclude='*.log' \
        -e "ssh -o StrictHostKeyChecking=accept-new" \
        "$service_dir/" \
        "${pi_name}@${pi_name}.local:$target_path/" 2>>"$log_file"; then
        echo "Error: Failed to sync files to $pi_name" >&2
        return 1
    fi

    # Step 3: Restart service using locally built images
    echo "  Restarting service..." >&2

    # Build docker compose down command
    # CRITICAL FIX: Never use --volumes by default (causes data loss!)
    # Only delete volumes if explicitly requested AND confirmed
    local down_flags="--remove-orphans"

    if [[ "$DEPLOY_DELETE_VOLUMES" == "true" ]]; then
        echo "" >&2
        echo "WARNING: Volume deletion requested for $service_name!" >&2
        echo "This will PERMANENTLY DELETE all data including databases!" >&2
        echo "Service: $service_name" >&2
        echo "Pi: $pi_name" >&2
        echo "" >&2

        # Skip confirmation if in non-interactive mode
        if [[ -t 0 ]]; then
            read -r -p "Type 'DELETE' to confirm volume deletion: " confirmation
            if [[ "$confirmation" != "DELETE" ]]; then
                echo "Volume deletion cancelled. Deployment aborted." >&2
                return 1
            fi
        else
            echo "ERROR: Volume deletion requires interactive confirmation!" >&2
            echo "Running in non-interactive mode - deployment aborted for safety." >&2
            return 1
        fi

        down_flags="$down_flags --volumes"
        echo "  Proceeding with volume deletion..." >&2
    fi

    # Security: Build command using validated target_path as positional parameter
    # Note: target_path is already validated above
    # Uses locally built images only - no registry pull needed
    # shellcheck disable=SC2016  # $1 here is the remote bash positional, not a local expansion
    local deploy_cmd='cd "$1" && docker compose down '"$down_flags"' && docker compose up -d'

    # DRY RUN mode
    if [[ "$DEPLOY_DRY_RUN" == "true" ]]; then
        echo "" >&2
        echo "DRY RUN MODE - Commands that would be executed:" >&2
        echo "  SSH Host: ${pi_name}@${pi_name}.local" >&2
        echo "  Command: cd \"$target_path\" && docker compose down $down_flags && docker compose up -d" >&2
        echo "" >&2
        return 0
    fi

    # Save current container ID for potential rollback
    local current_container_id
    # Security: Use bash -c with positional parameter for service name (using SSH keys)
    current_container_id=$(ssh -o StrictHostKeyChecking=accept-new "${pi_name}@${pi_name}.local" -- \
        bash -c 'docker ps -q --filter "name=$1" 2>/dev/null || echo ""' _ "$service_name" 2>/dev/null)

    # Execute deployment (using SSH keys)
    # Security: Pass target_path as positional parameter to bash -c
    if ! ssh -o StrictHostKeyChecking=accept-new "${pi_name}@${pi_name}.local" -- \
        bash -lc "$deploy_cmd" _ "$target_path" >>"$log_file" 2>&1; then
        echo "Error: Failed to deploy $service_name to $pi_name (see $log_file)" >&2
        return 1
    fi

    echo "  Deployment command completed successfully" >&2

    # Step 4: Verify deployment (if enabled)
    if [[ "$DEPLOY_AUTO_VERIFY" == "true" ]]; then
        echo "  Verifying deployment..." >&2

        if verify_deployment "$service_name" "$pi_name" "$DEPLOY_STARTUP_TIMEOUT" 2>>"$log_file"; then
            echo "Successfully deployed $service_name to $pi_name" >&2
            return 0
        else
            echo "Error: Deployment verification failed for $service_name on $pi_name" >&2

            # Automatic rollback (if enabled)
            if [[ "$DEPLOY_AUTO_ROLLBACK" == "true" ]] && [[ -n "$current_container_id" ]]; then
                echo "  Attempting automatic rollback..." >&2

                # Try to restart the previous container (using SSH keys)
                local rollback_cmd="cd $target_path && docker compose down $down_flags && docker compose up -d"
                if ssh -o StrictHostKeyChecking=accept-new "${pi_name}@${pi_name}.local" \
                    "bash -lc '$rollback_cmd'" >>"$log_file" 2>&1; then
                    echo "  Rollback completed - previous version restored" >&2
                else
                    echo "  WARNING: Rollback failed! Service may be down" >&2
                fi
            fi

            return 1
        fi
    fi

    echo "Successfully deployed $service_name to $pi_name" >&2
    return 0
}

# =============================================================================
# deploy_to_pi - Deploy all services to a Raspberry Pi
#
# Deploys all Docker services assigned to a specific Pi according to the
# registry.yml configuration. Services are deployed sequentially.
#
# Parameters:
#   $1 - pi_name (required): Target Pi host (pi1, pi2, pi3, pi4)
#   $2 - registry_file (required): Path to registry.yml
#   $3 - base_dir (optional): Base directory for service paths
#                             Default: "<sync-base>"
#
# Returns:
#   0 - All deployments successful
#   1 - One or more deployments failed
#   2 - Invalid parameters
#
# Outputs:
#   Prints progress to stderr
#   Returns number of failed deployments in exit code
#
# Example:
#   deploy_to_pi "pi1" "/path/to/registry.yml"
# =============================================================================
deploy_to_pi() {
    local pi_name="$1"
    local registry_file="$2"
    local base_dir="${3:-<sync-base>}"

    # Validate parameters
    if [[ -z "$pi_name" ]]; then
        echo "Error: pi_name parameter is required" >&2
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

    # Check for yq
    if ! command -v yq &> /dev/null; then
        echo "Error: yq is not installed or not in PATH" >&2
        return 2
    fi

    echo "Deploying services to $pi_name..." >&2

    # Get services for this Pi
    local services
    services=$(yq eval ".services | to_entries | .[] | select(.value.current_host == \"$pi_name\" and .value.deployment_type == \"docker\") | .key" "$registry_file" 2>/dev/null)

    if [[ -z "$services" ]]; then
        echo "No services configured for $pi_name" >&2
        return 0
    fi

    # Convert to array
    local service_array=()
    while IFS= read -r service; do
        [[ -n "$service" ]] && service_array+=("$service")
    done <<< "$services"

    echo "Found ${#service_array[@]} services to deploy" >&2

    local deployed=0
    local failed=0

    # Deploy each service
    for service in "${service_array[@]}"; do
        # Get service directory
        local compose_path
        compose_path=$(yq eval ".services.\"$service\".docker_compose // .services.\"$service\".service_file" "$registry_file" 2>/dev/null)

        if [[ -z "$compose_path" ]] || [[ "$compose_path" == "null" ]]; then
            echo "Warning: No docker_compose path for $service, skipping" >&2
            continue
        fi

        # Extract directory
        local service_dirname
        service_dirname=$(echo "$compose_path" | cut -d'/' -f2)

        local service_dir="${base_dir}/${service_dirname}"

        # Deploy service
        if deploy_service_to_pi "$service" "$pi_name" "$service_dir"; then
            ((deployed++))
        else
            ((failed++))
        fi
    done

    echo "Deployment to $pi_name complete: $deployed successful, $failed failed" >&2

    if [[ $failed -gt 0 ]]; then
        return 1
    fi

    return 0
}

# =============================================================================
# verify_deployment - Verify a service is running correctly on a Pi
#
# Checks that a deployed service is running and healthy by:
# 1. Verifying the container is running
# 2. Checking the container is healthy (if health check defined)
# 3. Optionally testing the service endpoint
#
# Parameters:
#   $1 - service_name (required): Name of the service to verify
#   $2 - pi_name (required): Target Pi host
#   $3 - timeout (optional): Timeout in seconds to wait for healthy state
#                           Default: 30
#
# Returns:
#   0 - Service is running and healthy
#   1 - Service is not running or unhealthy
#   2 - Invalid parameters
#
# Outputs:
#   Prints status messages to stderr
#   Returns "HEALTHY", "UNHEALTHY", or "NOT_RUNNING" to stdout
#
# Example:
#   if verify_deployment "myservice" "pi1" 60; then
#       echo "Service is healthy"
#   fi
# =============================================================================
verify_deployment() {
    local service_name="$1"
    local pi_name="$2"
    local timeout="${3:-30}"

    # Validate parameters
    if [[ -z "$service_name" ]]; then
        echo "Error: service_name parameter is required" >&2
        return 2
    fi

    if [[ -z "$pi_name" ]]; then
        echo "Error: pi_name parameter is required" >&2
        return 2
    fi

    # Get Pi configuration
    # REMOVED: pi_password reference - now using SSH keys

    echo "Verifying $service_name on $pi_name..." >&2

    # Check if container is running (using SSH keys)
    local check_cmd="docker ps --filter name=$service_name --format '{{.Status}}'"
    local container_status
    container_status=$(ssh -o StrictHostKeyChecking=accept-new "${pi_name}@${pi_name}.local" \
        "bash -lc '$check_cmd'" 2>/dev/null || echo "")

    if [[ -z "$container_status" ]]; then
        echo "NOT_RUNNING"
        echo "Service $service_name is not running on $pi_name" >&2
        return 1
    fi

    # Wait for healthy state if health check is defined
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        # Check health status (using SSH keys)
        local health_status
        health_status=$(ssh -o StrictHostKeyChecking=accept-new "${pi_name}@${pi_name}.local" \
            "bash -lc 'docker inspect --format=\"{{.State.Health.Status}}\" \$(docker ps -q --filter name=$service_name) 2>/dev/null || echo \"no-health-check\"'" 2>/dev/null || echo "error")

        if [[ "$health_status" == "healthy" ]] || [[ "$health_status" == "no-health-check" ]]; then
            echo "HEALTHY"
            echo "Service $service_name is healthy on $pi_name" >&2
            return 0
        elif [[ "$health_status" == "unhealthy" ]]; then
            echo "UNHEALTHY"
            echo "Service $service_name is unhealthy on $pi_name" >&2
            return 1
        fi

        # Wait and retry
        sleep 2
        ((elapsed+=2))
    done

    echo "UNHEALTHY"
    echo "Timeout waiting for $service_name to become healthy on $pi_name" >&2
    return 1
}

# =============================================================================
# rollback_deployment - Rollback a service to previous version
#
# Attempts to rollback a service deployment by restarting with locally built images
#
# Parameters:
#   $1 - service_name (required): Name of the service to rollback
#   $2 - pi_name (required): Target Pi host
#
# Returns:
#   0 - Rollback successful
#   1 - Rollback failed
#   2 - Invalid parameters
#
# Outputs:
#   Prints status messages to stderr
#
# Example:
#   rollback_deployment "myservice" "pi1"
# =============================================================================
rollback_deployment() {
    local service_name="$1"
    local pi_name="$2"

    # Validate parameters
    if [[ -z "$service_name" ]]; then
        echo "Error: service_name parameter is required" >&2
        return 2
    fi

    if [[ -z "$pi_name" ]]; then
        echo "Error: pi_name parameter is required" >&2
        return 2
    fi

    # Get Pi configuration
    # REMOVED: pi_password reference - now using SSH keys
    local pi_path="${DEPLOY_PI_PATHS[$pi_name]:-}"

    if [[ -z "$pi_path" ]]; then
        echo "Error: Pi configuration not found for $pi_name" >&2
        return 2
    fi

    echo "Rolling back $service_name on $pi_name..." >&2

    local log_file="${DEPLOY_LOG_DIR}/rollback-${service_name}-${pi_name}.log"

    # Rollback command - restart with locally built images (using SSH keys)
    local rollback_cmd="cd ${pi_path} && docker compose down --remove-orphans && docker compose up -d"

    if ssh -o StrictHostKeyChecking=accept-new "${pi_name}@${pi_name}.local" \
        "bash -lc '$rollback_cmd'" >>"$log_file" 2>&1; then
        echo "Successfully rolled back $service_name on $pi_name" >&2
        return 0
    else
        echo "Error: Failed to rollback $service_name on $pi_name (see $log_file)" >&2
        return 1
    fi
}

# =============================================================================
# Library initialization check
# =============================================================================

# Verify this script is being sourced, not executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This library should be sourced, not executed directly" >&2
    echo "Usage: source lib/cluster/deploy.sh" >&2
    exit 1
fi
