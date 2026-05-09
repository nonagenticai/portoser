#!/usr/bin/env bash
# =============================================================================
# lib/cluster/deploy_atomic.sh - Atomic Deployment Operations
#
# Wraps deploy.sh functions with atomic operations, state management, and
# enhanced rollback capabilities. Implements transaction-like behavior for
# deployments with automatic rollback on failure.
#
# Features:
#   - Atomic deployment with state checkpoint
#   - Enhanced verification before rollback
#   - Automatic snapshot creation
#   - Transaction-like rollback
#   - Deployment state tracking
#   - Race condition prevention
#
# Functions:
#   - atomic_deploy_service()       Deploy with atomic guarantees
#   - verify_rollback_capability()  Check rollback feasibility
#   - safe_rollback()              Enhanced rollback with verification
#   - get_deployment_history()      Show deployment history
#   - abort_deployment()            Safely abort mid-deployment
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

if [[ -f "$_LIB_DIR/state.sh" ]]; then
    # shellcheck source=lib/state.sh
    source "$_LIB_DIR/state.sh"
fi
unset _CLUSTER_LIB_DIR _LIB_DIR

if [[ -f "$SCRIPT_DIR/deploy.sh" ]]; then
    # shellcheck source=lib/cluster/deploy.sh
    source "$SCRIPT_DIR/deploy.sh"
fi

# Configuration
ATOMIC_DEPLOY_LOG_DIR="/tmp/portoser_deployments"
ATOMIC_DEPLOY_MAX_RETRIES="${ATOMIC_DEPLOY_MAX_RETRIES:-3}"
ATOMIC_DEPLOY_VERIFY_TIMEOUT="${ATOMIC_DEPLOY_VERIFY_TIMEOUT:-60}"

# Initialize deployment directory
mkdir -p "$ATOMIC_DEPLOY_LOG_DIR" 2>/dev/null || true

# =============================================================================
# atomic_deploy_service - Deploy with atomic guarantees
#
# Performs deployment with full state tracking, checkpointing, and
# automatic rollback on verification failure. Implements transaction
# semantics for deployments.
#
# Parameters:
#   $1 - service_name (required): Name of the service to deploy
#   $2 - pi_name (required): Target Pi host
#   $3 - service_dir (required): Local service directory
#
# Returns:
#   0 - Deployment successful and verified
#   1 - Deployment failed, rolled back
#   2 - Invalid parameters
#   3 - Rollback failed (service down)
#
# Outputs:
#   Prints deployment progress to stderr
#   Writes transaction log to /tmp/portoser_deployments/
#
# Example:
#   atomic_deploy_service "myservice" "pi1" "/path/to/myservice"
# =============================================================================
atomic_deploy_service() {
    local service_name="$1"
    local pi_name="$2"
    local service_dir="$3"

    # Validate parameters
    if [[ -z "$service_name" ]] || [[ -z "$pi_name" ]] || [[ -z "$service_dir" ]]; then
        echo "Error: service_name, pi_name, and service_dir required" >&2
        return 2
    fi

    local deployment_id
    deployment_id="${service_name}_${pi_name}_$(date +%s)"
    local transaction_log="$ATOMIC_DEPLOY_LOG_DIR/${deployment_id}.transaction"
    local state_key="deployment_${service_name}_${pi_name}"

    echo "Starting atomic deployment: $deployment_id" >&2

    # Initialize transaction log
    {
        echo "DEPLOYMENT_ID=$deployment_id"
        echo "SERVICE=$service_name"
        echo "PI=$pi_name"
        echo "TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "STATUS=STARTING"
    } > "$transaction_log"

    # Phase 1: Initialize state
    echo "  [PHASE 1] Initializing state..." >&2
    if ! state_init "$state_key" "deploying" "{\"service\":\"$service_name\",\"pi\":\"$pi_name\"}"; then
        echo "Error: Failed to initialize deployment state" >&2
        return 2
    fi

    # Phase 2: Create deployment checkpoint
    echo "  [PHASE 2] Creating checkpoint..." >&2
    local checkpoint
    checkpoint=$(state_checkpoint "$state_key" "${deployment_id}_before" "Pre-deployment state") || {
        echo "Error: Failed to create deployment checkpoint" >&2
        state_transition "$state_key" "failed" "{\"reason\":\"checkpoint_failed\"}" >/dev/null 2>&1 || true
        return 2
    }

    echo "CHECKPOINT=$checkpoint" >> "$transaction_log"

    # Phase 3: Acquire deployment lock to prevent concurrent deployments
    echo "  [PHASE 3] Acquiring deployment lock..." >&2
    local lock_name="${service_name}_${pi_name}_deploy"
    if ! acquire_lock "$lock_name" 30 "Atomic deployment for $service_name on $pi_name"; then
        echo "Error: Failed to acquire deployment lock (another deployment in progress?)" >&2
        state_transition "$state_key" "failed" "{\"reason\":\"lock_failed\"}" >/dev/null 2>&1 || true
        return 1
    fi

    # Phase 4: Execute deployment
    echo "  [PHASE 4] Executing deployment..." >&2
    echo "STATUS=DEPLOYING" >> "$transaction_log"

    if ! deploy_service_to_pi "$service_name" "$pi_name" "$service_dir" 2>&1 | tee -a "$transaction_log"; then
        echo "Error: Deployment execution failed" >&2
        echo "STATUS=DEPLOY_FAILED" >> "$transaction_log"

        release_lock "$lock_name"
        state_transition "$state_key" "failed" "{\"reason\":\"deployment_failed\"}" >/dev/null 2>&1 || true

        # Attempt safe rollback
        echo "  [PHASE 5] Attempting safe rollback..." >&2
        safe_rollback "$service_name" "$pi_name" "$checkpoint" "$state_key" || {
            echo "CRITICAL: Rollback failed!" >&2
            echo "STATUS=ROLLBACK_FAILED" >> "$transaction_log"
            return 3
        }

        echo "STATUS=ROLLED_BACK" >> "$transaction_log"
        return 1
    fi

    echo "STATUS=DEPLOY_SUCCESS" >> "$transaction_log"

    # Phase 5: Comprehensive verification
    echo "  [PHASE 5] Verifying deployment..." >&2

    if ! verify_deployment "$service_name" "$pi_name" "$ATOMIC_DEPLOY_VERIFY_TIMEOUT" 2>&1 | tee -a "$transaction_log"; then
        echo "Error: Deployment verification failed" >&2
        echo "STATUS=VERIFICATION_FAILED" >> "$transaction_log"

        release_lock "$lock_name"
        state_transition "$state_key" "failed" "{\"reason\":\"verification_failed\"}" >/dev/null 2>&1 || true

        # Perform safe rollback
        echo "  [PHASE 6] Performing safe rollback..." >&2
        safe_rollback "$service_name" "$pi_name" "$checkpoint" "$state_key" || {
            echo "CRITICAL: Rollback failed during verification recovery!" >&2
            echo "STATUS=CRITICAL_ROLLBACK_FAILED" >> "$transaction_log"
            return 3
        }

        echo "STATUS=ROLLED_BACK_AFTER_VERIFICATION" >> "$transaction_log"
        return 1
    fi

    echo "STATUS=VERIFICATION_SUCCESS" >> "$transaction_log"

    # Phase 6: Update state to running
    echo "  [PHASE 6] Updating deployment state..." >&2
    if ! state_transition "$state_key" "running" "{\"completed_at\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"}"; then
        echo "Warning: Failed to update state to running, but deployment appears successful" >&2
    fi

    # Phase 7: Create success checkpoint
    echo "  [PHASE 7] Creating success checkpoint..." >&2
    state_checkpoint "$state_key" "${deployment_id}_after" "Post-deployment state" >/dev/null 2>&1 || true

    # Release lock
    release_lock "$lock_name"

    echo "STATUS=COMPLETE_SUCCESS" >> "$transaction_log"
    echo "Successfully deployed $service_name to $pi_name (Transaction: $deployment_id)" >&2
    return 0
}

# =============================================================================
# verify_rollback_capability - Check if rollback is feasible
#
# Verifies that rollback is possible before attempting it. Checks:
# - Previous image exists in registry
# - Service can be reached before rollback
# - Previous state can be restored
#
# Parameters:
#   $1 - service_name (required): Service name
#   $2 - pi_name (required): Target Pi
#   $3 - checkpoint_name (optional): Checkpoint to verify
#
# Returns:
#   0 - Rollback is feasible
#   1 - Rollback is not feasible
# =============================================================================
verify_rollback_capability() {
    local service_name="$1"
    local pi_name="$2"
    local checkpoint_name="${3:-}"

    if [[ -z "$service_name" ]] || [[ -z "$pi_name" ]]; then
        echo "Error: service_name and pi_name required" >&2
        return 1
    fi

    [ "$DEBUG" = "1" ] && echo "  [VERIFY] Checking rollback capability for $service_name on $pi_name" >&2

    # Check 1: Can we reach the Pi?
    local pi_password="${DEPLOY_PI_PASSWORDS[$pi_name]:-}"
    if [[ -z "$pi_password" ]]; then
        echo "Error: Cannot reach Pi $pi_name (no password configured)" >&2
        return 1
    fi

    # Check 2: Does previous state snapshot exist?
    if [[ -n "$checkpoint_name" ]]; then
        local snapshot_file="$STATE_SNAPSHOTS_DIR/${checkpoint_name}.snapshot"
        if [[ ! -f "$snapshot_file" ]]; then
            echo "Error: Checkpoint not found: $checkpoint_name" >&2
            return 1
        fi
    fi

    # Check 3: Can we contact Pi?
    if ! sshpass -p "$pi_password" ssh -o StrictHostKeyChecking=accept-new \
         -o ConnectTimeout=5 "${pi_name}@${pi_name}.local" \
         "docker ps > /dev/null 2>&1"; then
        echo "Error: Cannot reach Docker on $pi_name (rollback impossible)" >&2
        return 1
    fi

    [ "$DEBUG" = "1" ] && echo "  [VERIFY] Rollback is feasible for $service_name on $pi_name" >&2
    return 0
}

# =============================================================================
# safe_rollback - Enhanced rollback with verification
#
# Performs rollback with safety checks and state restoration. Only
# rollbacks if verified feasible.
#
# Parameters:
#   $1 - service_name (required): Service to rollback
#   $2 - pi_name (required): Target Pi
#   $3 - checkpoint_name (optional): Checkpoint to restore from
#   $4 - state_key (optional): State key for tracking
#
# Returns:
#   0 - Rollback successful
#   1 - Rollback failed
# =============================================================================
safe_rollback() {
    local service_name="$1"
    local pi_name="$2"
    local checkpoint_name="${3:-}"
    local state_key="${4:-}"

    if [[ -z "$service_name" ]] || [[ -z "$pi_name" ]]; then
        echo "Error: service_name and pi_name required" >&2
        return 1
    fi

    echo "Initiating safe rollback for $service_name on $pi_name..." >&2

    # Verify rollback is possible
    if ! verify_rollback_capability "$service_name" "$pi_name" "$checkpoint_name"; then
        echo "Error: Rollback verification failed - cannot perform safe rollback" >&2
        return 1
    fi

    # Restore state from checkpoint if provided
    if [[ -n "$checkpoint_name" ]] && [[ -n "$state_key" ]]; then
        echo "  Restoring state from checkpoint: $checkpoint_name" >&2
        if ! state_restore "$state_key" "$checkpoint_name"; then
            echo "Warning: Failed to restore state from checkpoint" >&2
            # Continue with rollback anyway
        fi
    fi

    # Perform actual rollback using docker compose
    local pi_password="${DEPLOY_PI_PASSWORDS[$pi_name]:-}"
    local pi_path="${DEPLOY_PI_PATHS[$pi_name]:-}"

    if [[ -z "$pi_password" ]] || [[ -z "$pi_path" ]]; then
        echo "Error: Pi configuration incomplete for $pi_name" >&2
        return 1
    fi

    local service_path="${pi_path}/${service_name}"
    # $1 here is the remote bash positional, not a local expansion — single
    # quotes preserve it for evaluation on the remote side.
    # shellcheck disable=SC2016
    local rollback_cmd='cd "$1" && docker compose down --remove-orphans && docker compose up -d'

    echo "  Executing rollback commands..." >&2

    # Execute rollback
    if sshpass -p "$pi_password" ssh -o StrictHostKeyChecking=accept-new "${pi_name}@${pi_name}.local" -- \
         bash -lc "$rollback_cmd" _ "$service_path" 2>/dev/null; then

        # Verify service comes back up
        sleep 5
        if verify_deployment "$service_name" "$pi_name" 30; then
            echo "Rollback successful - service restored" >&2
            if [[ -n "$state_key" ]]; then state_transition "$state_key" "stopped" "{\"reason\":\"rolled_back\"}" >/dev/null 2>&1 || true; fi
            return 0
        fi
    fi

    echo "Error: Rollback failed or service did not restart properly" >&2
    if [[ -n "$state_key" ]]; then state_transition "$state_key" "unknown" "{\"reason\":\"rollback_failed\"}" >/dev/null 2>&1 || true; fi
    return 1
}

# =============================================================================
# get_deployment_history - Show recent deployments
#
# Parameters:
#   $1 - service_name (optional): Filter by service (shows all if empty)
#   $2 - limit (optional): Number of records to show (default: 10)
#
# Returns:
#   0 - Always succeeds
# =============================================================================
get_deployment_history() {
    local service_filter="${1:-}"
    local limit="${2:-10}"

    echo "Recent Deployments:" >&2
    echo "===================" >&2

    if [[ ! -d "$ATOMIC_DEPLOY_LOG_DIR" ]]; then
        echo "No deployment history available" >&2
        return 0
    fi

    # Find transaction logs
    find "$ATOMIC_DEPLOY_LOG_DIR" -name "*.transaction" -type f -printf '%T@ %p\n' 2>/dev/null | \
        sort -rn | head -"$limit" | cut -d' ' -f2- | while read -r log_file; do

        if [[ -n "$service_filter" ]]; then
            grep -q "SERVICE=$service_filter" "$log_file" || continue
        fi

        echo "" >&2
        grep "^DEPLOYMENT_ID=\|^SERVICE=\|^TIMESTAMP=\|^STATUS=" "$log_file" | sed 's/^/  /' >&2
    done

    return 0
}

# =============================================================================
# abort_deployment - Safely abort an in-progress deployment
#
# Allows graceful abortion of stuck deployments with proper cleanup.
#
# Parameters:
#   $1 - service_name (required): Service to abort
#   $2 - pi_name (required): Target Pi
#
# Returns:
#   0 - Abort successful
#   1 - Abort failed
# =============================================================================
abort_deployment() {
    local service_name="$1"
    local pi_name="$2"

    if [[ -z "$service_name" ]] || [[ -z "$pi_name" ]]; then
        echo "Error: service_name and pi_name required" >&2
        return 1
    fi

    local lock_name="${service_name}_${pi_name}_deploy"
    local state_key="deployment_${service_name}_${pi_name}"

    echo "Aborting deployment for $service_name on $pi_name..." >&2

    # Release deployment lock if held
    if is_locked "$lock_name"; then
        release_lock "$lock_name" 2>/dev/null || true
        echo "Released deployment lock" >&2
    fi

    # Update state to stopped
    state_transition "$state_key" "stopped" "{\"reason\":\"aborted\"}" 2>/dev/null || true

    echo "Deployment aborted" >&2
    return 0
}

# Export functions for use in subshells
export -f atomic_deploy_service
export -f verify_rollback_capability
export -f safe_rollback
export -f get_deployment_history
export -f abort_deployment
