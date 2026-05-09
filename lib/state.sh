#!/usr/bin/env bash
# =============================================================================
# lib/state.sh - Consistent State Management System
#
# Provides atomic state tracking and management for deployments, ensuring
# all state changes are recorded and recoverable. Implements:
#
# - State snapshots for rollback capability
# - Transaction-like state changes
# - State validation and verification
# - Historical state tracking
# - Deadlock-free concurrent state access
#
# Features:
#   - Atomic state reads/writes
#   - Snapshot creation and restoration
#   - State transition validation
#   - Automatic cleanup of old snapshots
#   - Process-safe state directory
#
# Functions:
#   - state_init()           Initialize state tracking for a service
#   - state_checkpoint()     Create state snapshot
#   - state_restore()        Restore from snapshot
#   - state_get()            Get current state value
#   - state_set()            Set state value atomically
#   - state_validate()       Validate state consistency
#   - state_transition()     Perform validated state transition
# =============================================================================

set -euo pipefail

# Source locking system for atomic operations.
# Resolve siblings via this file's own directory so we don't depend on the
# caller having $SCRIPT_DIR set (broken under set -u).
_STATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_STATE_LIB_DIR/locks.sh" ]]; then
    # shellcheck source=lib/locks.sh
    source "$_STATE_LIB_DIR/locks.sh"
fi
unset _STATE_LIB_DIR

# State directory configuration
STATE_DIR="${STATE_DIR:-/tmp/portoser_state}"
STATE_SNAPSHOTS_DIR="${STATE_DIR}/snapshots"
STATE_HISTORY_DIR="${STATE_DIR}/history"
STATE_LOCKS_DIR="${STATE_DIR}/locks"
STATE_RETENTION_DAYS="${STATE_RETENTION_DAYS:-7}"

# Initialize state directories
mkdir -p "$STATE_DIR" "$STATE_SNAPSHOTS_DIR" "$STATE_HISTORY_DIR" "$STATE_LOCKS_DIR" 2>/dev/null || true

# State transition rules - define valid transitions
declare -gA STATE_TRANSITIONS=(
    ["pending->deploying"]="1"
    ["deploying->running"]="1"
    ["deploying->failed"]="1"
    ["running->stopping"]="1"
    ["stopping->stopped"]="1"
    ["stopped->deploying"]="1"
    ["failed->deploying"]="1"
    ["running->unknown"]="1"
    ["*->unknown"]="1"
)

# =============================================================================
# state_init - Initialize state tracking for a service
#
# Creates initial state file and snapshot for a service/resource.
# Must be called before any state operations on a new resource.
#
# Parameters:
#   $1 - service_name (required): Service to track
#   $2 - initial_state (optional): Initial state (default: "unknown")
#   $3 - metadata (optional): JSON metadata to store with state
#
# Returns:
#   0 - State initialized successfully
#   1 - Initialization failed
#
# Example:
#   state_init "deployment_pi1" "pending" '{"host":"pi1","time":"2025-12-08"}'
# =============================================================================
state_init() {
    local service="$1"
    local initial_state="${2:-unknown}"
    local metadata="${3:-}"

    if [[ -z "$service" ]]; then
        echo "Error: service_name parameter required" >&2
        return 1
    fi

    local state_file="$STATE_DIR/${service}.state"
    local lock_name="state_${service}"

    if ! acquire_lock "$lock_name" 10 "Initializing state for $service"; then
        echo "Error: Failed to acquire lock for state initialization" >&2
        return 1
    fi

    # Check if already initialized
    if [[ -f "$state_file" ]]; then
        [ "$DEBUG" = "1" ] && echo "  [STATE] State already initialized for $service" >&2
        release_lock "$lock_name"
        return 0
    fi

    # Create initial state file
    {
        echo "STATE=$initial_state"
        echo "TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "TRANSITION_COUNT=0"
        if [[ -n "$metadata" ]]; then
            echo "METADATA=$metadata"
        fi
    } > "$state_file"

    # Create initial snapshot
    cp "$state_file" "$STATE_SNAPSHOTS_DIR/${service}_init.snapshot"

    # Record in history
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')|init|$initial_state|$service" >> "$STATE_HISTORY_DIR/${service}.history"

    release_lock "$lock_name"

    [ "$DEBUG" = "1" ] && echo "  [STATE] Initialized state for $service: $initial_state" >&2
    return 0
}

# =============================================================================
# state_get - Get current state value for a service
#
# Atomically reads the current state without modifying it. Safe for concurrent
# read access from multiple processes.
#
# Parameters:
#   $1 - service_name (required): Service to query
#   $2 - field (optional): Specific field to get (default: STATE)
#
# Returns:
#   0 - Successfully read state
#   1 - State file not found or read failed
#
# Outputs:
#   Prints state value to stdout
#
# Example:
#   current_state=$(state_get "deployment_pi1")
#   echo "Service state: $current_state"
# =============================================================================
state_get() {
    local service="$1"
    local field="${2:-STATE}"

    if [[ -z "$service" ]]; then
        echo "Error: service_name parameter required" >&2
        return 1
    fi

    local state_file="$STATE_DIR/${service}.state"

    if [[ ! -f "$state_file" ]]; then
        echo "Error: State file not found for $service" >&2
        return 1
    fi

    # Use shared lock for read
    local lock_name="state_${service}"
    if ! acquire_shared_lock "$lock_name" 5 "Reading state for $service"; then
        return 1
    fi

    # Read specific field
    local value
    value=$(grep "^${field}=" "$state_file" 2>/dev/null | cut -d'=' -f2- || echo "")

    release_shared_lock "$lock_name"

    if [[ -z "$value" ]]; then
        return 1
    fi

    echo "$value"
    return 0
}

# =============================================================================
# state_set - Set state value atomically
#
# Updates a state field atomically with proper locking. Creates automatic
# backup before modification and records transition in history.
#
# Parameters:
#   $1 - service_name (required): Service to update
#   $2 - state_value (required): New state value
#   $3 - metadata (optional): Additional metadata JSON
#
# Returns:
#   0 - State updated successfully
#   1 - Update failed
#
# Example:
#   state_set "deployment_pi1" "running" '{"started_at":"2025-12-08T22:30:00Z"}'
# =============================================================================
state_set() {
    local service="$1"
    local state_value="$2"
    local metadata="${3:-}"

    if [[ -z "$service" ]] || [[ -z "$state_value" ]]; then
        echo "Error: service_name and state_value required" >&2
        return 1
    fi

    local state_file="$STATE_DIR/${service}.state"
    local lock_name="state_${service}"

    # Ensure state is initialized
    if [[ ! -f "$state_file" ]]; then
        state_init "$service" "unknown" >/dev/null 2>&1 || true
    fi

    if ! acquire_lock "$lock_name" 10 "Updating state for $service"; then
        echo "Error: Failed to acquire lock for state update" >&2
        return 1
    fi

    # Read current state
    local current_state
    current_state=$(grep "^STATE=" "$state_file" 2>/dev/null | cut -d'=' -f2)

    # Create backup
    cp "$state_file" "${state_file}.backup"

    # Update state file atomically (write to temp, then move)
    local temp_file="${state_file}.tmp.$$"

    {
        echo "STATE=$state_value"
        echo "PREVIOUS_STATE=$current_state"
        echo "TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        local transition_count
        transition_count=$(grep "^TRANSITION_COUNT=" "$state_file" 2>/dev/null | cut -d'=' -f2 || echo "0")
        echo "TRANSITION_COUNT=$((transition_count + 1))"
        if [[ -n "$metadata" ]]; then
            echo "METADATA=$metadata"
        fi
        # Preserve other fields
        grep -v "^STATE=\|^PREVIOUS_STATE=\|^TIMESTAMP=\|^TRANSITION_COUNT=\|^METADATA=" "$state_file" 2>/dev/null || true
    } > "$temp_file"

    # Atomic move
    if mv "$temp_file" "$state_file" 2>/dev/null; then
        # Record in history
        echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')|transition|${current_state}→${state_value}|$service" >> "$STATE_HISTORY_DIR/${service}.history"

        release_lock "$lock_name"
        [ "$DEBUG" = "1" ] && echo "  [STATE] Updated state for $service: $current_state → $state_value" >&2
        return 0
    else
        # Restore from backup on failure
        mv "${state_file}.backup" "$state_file" 2>/dev/null || true
        rm -f "$temp_file" 2>/dev/null || true
        release_lock "$lock_name"
        echo "Error: Failed to update state file for $service" >&2
        return 1
    fi
}

# =============================================================================
# state_checkpoint - Create a state snapshot for rollback
#
# Creates named snapshots of current state that can be restored later.
# Snapshots include all service state and metadata.
#
# Parameters:
#   $1 - service_name (required): Service to snapshot
#   $2 - snapshot_name (optional): Name for snapshot (auto-generated if omitted)
#   $3 - description (optional): Human-readable description
#
# Returns:
#   0 - Snapshot created successfully
#   1 - Snapshot creation failed
#
# Outputs:
#   Prints snapshot name to stdout
#
# Example:
#   checkpoint=$(state_checkpoint "deployment_pi1" "before_update")
#   echo "Created checkpoint: $checkpoint"
# =============================================================================
state_checkpoint() {
    local service="$1"
    local snapshot_name="${2:-}"
    local description="${3:-}"

    if [[ -z "$service" ]]; then
        echo "Error: service_name required" >&2
        return 1
    fi

    local state_file="$STATE_DIR/${service}.state"

    if [[ ! -f "$state_file" ]]; then
        echo "Error: State file not found for $service" >&2
        return 1
    fi

    # Generate snapshot name if not provided
    if [[ -z "$snapshot_name" ]]; then
        snapshot_name="${service}_$(date +%s)"
    fi

    local snapshot_file="$STATE_SNAPSHOTS_DIR/${snapshot_name}.snapshot"

    # Acquire lock for consistent snapshot
    local lock_name="state_${service}"
    if ! acquire_shared_lock "$lock_name" 5; then
        echo "Error: Failed to acquire lock for snapshot" >&2
        return 1
    fi

    # Create snapshot with metadata
    {
        echo "# Snapshot for $service"
        echo "# Created: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        if [[ -n "$description" ]]; then
            echo "# Description: $description"
        fi
        echo ""
        cat "$state_file"
    } > "$snapshot_file"

    release_shared_lock "$lock_name"

    # Record in history
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')|snapshot|$snapshot_name|$service" >> "$STATE_HISTORY_DIR/${service}.history"

    echo "$snapshot_name"
    return 0
}

# =============================================================================
# state_restore - Restore service state from snapshot
#
# Restores a previously created snapshot. All services with snapshots can be
# restored to exact point-in-time state.
#
# Parameters:
#   $1 - service_name (required): Service to restore
#   $2 - snapshot_name (required): Name of snapshot to restore
#
# Returns:
#   0 - Restore successful
#   1 - Restore failed
#
# Example:
#   state_restore "deployment_pi1" "before_update"
# =============================================================================
state_restore() {
    local service="$1"
    local snapshot_name="$2"

    if [[ -z "$service" ]] || [[ -z "$snapshot_name" ]]; then
        echo "Error: service_name and snapshot_name required" >&2
        return 1
    fi

    local snapshot_file="$STATE_SNAPSHOTS_DIR/${snapshot_name}.snapshot"
    local state_file="$STATE_DIR/${service}.state"

    if [[ ! -f "$snapshot_file" ]]; then
        echo "Error: Snapshot not found: $snapshot_name" >&2
        return 1
    fi

    local lock_name="state_${service}"
    if ! acquire_lock "$lock_name" 10 "Restoring state for $service"; then
        echo "Error: Failed to acquire lock for restore" >&2
        return 1
    fi

    # Create backup of current state
    if [[ -f "$state_file" ]]; then
        cp "$state_file" "${state_file}.pre_restore_backup"
    fi

    # Extract state from snapshot (skip comments)
    if grep -v "^#" "$snapshot_file" > "$state_file" 2>/dev/null; then
        # Record in history
        echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')|restore|$snapshot_name|$service" >> "$STATE_HISTORY_DIR/${service}.history"

        release_lock "$lock_name"
        [ "$DEBUG" = "1" ] && echo "  [STATE] Restored state for $service from snapshot $snapshot_name" >&2
        return 0
    else
        # Restore previous state on failure
        [[ -f "${state_file}.pre_restore_backup" ]] && mv "${state_file}.pre_restore_backup" "$state_file"
        release_lock "$lock_name"
        echo "Error: Failed to restore state from snapshot" >&2
        return 1
    fi
}

# =============================================================================
# state_transition - Perform validated state transition
#
# Ensures state transitions follow defined rules. Prevents invalid transitions
# that could cause system inconsistency.
#
# Parameters:
#   $1 - service_name (required): Service to transition
#   $2 - new_state (required): Target state
#   $3 - metadata (optional): Transition metadata
#
# Returns:
#   0 - Transition successful
#   1 - Invalid transition or other error
#
# Example:
#   state_transition "deployment_pi1" "running" '{"reason":"deployment_complete"}'
# =============================================================================
state_transition() {
    local service="$1"
    local new_state="$2"
    local metadata="${3:-}"

    if [[ -z "$service" ]] || [[ -z "$new_state" ]]; then
        echo "Error: service_name and new_state required" >&2
        return 1
    fi

    # Initialize if needed
    state_init "$service" "unknown" >/dev/null 2>&1 || true

    # Get current state
    local current_state
    current_state=$(state_get "$service" 2>/dev/null)
    if [[ -z "$current_state" ]]; then
        current_state="unknown"
    fi

    # Validate transition
    local transition_key="${current_state}->${new_state}"
    local wildcard_key="*->${new_state}"

    if [[ "${STATE_TRANSITIONS[$transition_key]:-0}" != "1" ]] && \
       [[ "${STATE_TRANSITIONS[$wildcard_key]:-0}" != "1" ]]; then
        echo "Error: Invalid state transition: $transition_key" >&2
        return 1
    fi

    # Perform transition
    if state_set "$service" "$new_state" "$metadata"; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# state_validate - Validate state consistency
#
# Checks that service state is valid and consistent. Useful for detecting
# corrupted or inconsistent state.
#
# Parameters:
#   $1 - service_name (required): Service to validate
#
# Returns:
#   0 - State is valid
#   1 - State is invalid or inconsistent
#
# Outputs:
#   Prints validation errors to stderr
# =============================================================================
state_validate() {
    local service="$1"

    if [[ -z "$service" ]]; then
        echo "Error: service_name required" >&2
        return 1
    fi

    local state_file="$STATE_DIR/${service}.state"

    if [[ ! -f "$state_file" ]]; then
        echo "Error: State file not found for $service" >&2
        return 1
    fi

    local errors=0

    # Check for required fields
    if ! grep -q "^STATE=" "$state_file"; then
        echo "Error: Missing STATE field in $service state" >&2
        ((errors++))
    fi

    if ! grep -q "^TIMESTAMP=" "$state_file"; then
        echo "Error: Missing TIMESTAMP field in $service state" >&2
        ((errors++))
    fi

    # Validate state value
    local state
    state=$(grep "^STATE=" "$state_file" | cut -d'=' -f2)
    case "$state" in
        pending|deploying|running|stopping|stopped|failed|unknown)
            : # Valid states
            ;;
        *)
            echo "Error: Invalid state value: $state" >&2
            ((errors++))
            ;;
    esac

    # Validate timestamp format
    local timestamp
    timestamp=$(grep "^TIMESTAMP=" "$state_file" | cut -d'=' -f2)
    if ! [[ "$timestamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        echo "Error: Invalid timestamp format: $timestamp" >&2
        ((errors++))
    fi

    if [[ $errors -gt 0 ]]; then
        return 1
    fi

    return 0
}

# =============================================================================
# cleanup_old_snapshots - Automatically clean up old snapshots
#
# Removes snapshots older than STATE_RETENTION_DAYS to prevent disk bloat.
# Called periodically during maintenance.
#
# Returns:
#   0 - Always succeeds
# =============================================================================
cleanup_old_snapshots() {
    if [[ ! -d "$STATE_SNAPSHOTS_DIR" ]]; then
        return 0
    fi

    [ "$DEBUG" = "1" ] && echo "  [STATE] Cleaning up snapshots older than $STATE_RETENTION_DAYS days" >&2

    find "$STATE_SNAPSHOTS_DIR" -type f -name "*.snapshot" -mtime +"$STATE_RETENTION_DAYS" -delete 2>/dev/null || true

    return 0
}

# Export functions for use in subshells
export -f state_init
export -f state_get
export -f state_set
export -f state_checkpoint
export -f state_restore
export -f state_transition
export -f state_validate
export -f cleanup_old_snapshots
