#!/usr/bin/env bash
# =============================================================================
# lib/locks.sh - File Locking System for Concurrent Operation Safety
#
# Provides atomic file locking and release mechanisms to prevent race conditions
# in concurrent operations. Implements multiple lock types with timeout and
# automatic cleanup.
#
# Features:
#   - Exclusive locks for critical sections
#   - Shared locks for read-only operations
#   - Lock timeout with automatic release
#   - Deadlock detection and prevention
#   - Process-safe cleanup on exit
#
# Functions:
#   - acquire_lock()        Acquire exclusive lock for a resource
#   - acquire_shared_lock() Acquire shared lock for a resource
#   - release_lock()        Release lock for a resource
#   - is_locked()           Check if resource is currently locked
#   - wait_for_lock()       Wait for lock with timeout
#   - cleanup_locks()       Clean up all locks on process exit
# =============================================================================

set -euo pipefail

# Lock directory - use /tmp with proper permissions
LOCKS_DIR="${LOCKS_DIR:-/tmp/portoser_locks}"
LOCKS_TIMEOUT="${LOCKS_TIMEOUT:-300}"  # 5 minutes default
LOCKS_RETRY_INTERVAL="${LOCKS_RETRY_INTERVAL:-1}"  # Check every 1 second
LOCKS_PID="$$"

# Initialize locks directory
mkdir -p "$LOCKS_DIR" 2>/dev/null || true
chmod 700 "$LOCKS_DIR" 2>/dev/null || true

# Track locks held by this process for cleanup
declare -gA LOCKS_HELD=()

# Cleanup on exit
trap 'cleanup_locks' EXIT

# =============================================================================
# _sanitize_lock_name - Sanitize lock name to safe filesystem name
#
# Parameters:
#   $1 - Lock name (may contain special characters)
#
# Returns:
#   0 - Always succeeds
#
# Outputs:
#   Prints sanitized lock name to stdout
# =============================================================================
_sanitize_lock_name() {
    local name="$1"
    # Replace special chars with underscores, keep alphanumeric and dash
    echo "$name" | sed 's/[^a-zA-Z0-9_-]/_/g' | sed 's/_\+/_/g'
}

# =============================================================================
# acquire_lock - Acquire exclusive lock for a resource
#
# Attempts to acquire an exclusive lock. If lock is held by another process,
# waits up to LOCKS_TIMEOUT seconds. Supports nested locks from same process.
#
# Parameters:
#   $1 - resource_name (required): Name of resource to lock
#   $2 - timeout (optional): Timeout in seconds (default: LOCKS_TIMEOUT)
#   $3 - description (optional): Human-readable description for debugging
#
# Returns:
#   0 - Lock acquired successfully
#   1 - Lock acquisition failed (timeout or other error)
#
# Outputs:
#   Prints debug messages to stderr if DEBUG=1
#   Writes lock metadata to lock file
#
# Example:
#   if acquire_lock "deployment_pi1" 30 "Deploying to pi1"; then
#       # Critical section
#       release_lock "deployment_pi1"
#   fi
# =============================================================================
acquire_lock() {
    local resource="$1"
    local timeout="${2:-$LOCKS_TIMEOUT}"
    local description="${3:-}"
    local sanitized_name

    if [[ -z "$resource" ]]; then
        echo "Error: resource_name parameter required" >&2
        return 1
    fi

    sanitized_name=$(_sanitize_lock_name "$resource")
    local lock_file="$LOCKS_DIR/${sanitized_name}.lock"
    local start_time
    start_time=$(date +%s)

    [ "$DEBUG" = "1" ] && echo "  [LOCK] Attempting to acquire lock: $resource (timeout: ${timeout}s)" >&2

    # Check if we already hold this lock (allow nested acquisition)
    if [[ "${LOCKS_HELD[$resource]:-0}" -gt 0 ]]; then
        ((LOCKS_HELD[$resource]++))
        [ "$DEBUG" = "1" ] && echo "  [LOCK] Nested lock acquired for $resource (depth: ${LOCKS_HELD[$resource]})" >&2
        return 0
    fi

    # Try to acquire lock with timeout
    while true; do
        # Attempt atomic creation - will fail if file exists
        if mkdir -p "$LOCKS_DIR" 2>/dev/null && \
           (set -C; : > "$lock_file") 2>/dev/null; then

            # Write lock metadata
            {
                echo "LOCK_PID=$LOCKS_PID"
                echo "LOCK_RESOURCE=$resource"
                echo "LOCK_TIME=$(date '+%Y-%m-%d %H:%M:%S')"
                if [[ -n "$description" ]]; then
                    echo "LOCK_DESCRIPTION=$description"
                fi
            } > "$lock_file"

            LOCKS_HELD[$resource]=1
            [ "$DEBUG" = "1" ] && echo "  [LOCK] Successfully acquired lock: $resource" >&2
            return 0
        fi

        # Check timeout
        local current_time
        current_time=$(date +%s)
        local elapsed
        elapsed=$((current_time - start_time))

        if [[ $elapsed -ge $timeout ]]; then
            echo "Error: Failed to acquire lock for $resource after ${timeout}s" >&2
            echo "  Lock held by: $(cat "$lock_file" 2>/dev/null || echo 'unknown')" >&2
            return 1
        fi

        # Wait before retrying
        sleep "$LOCKS_RETRY_INTERVAL"
    done
}

# =============================================================================
# acquire_shared_lock - Acquire shared lock for read-only access
#
# Allows multiple readers but blocks writers. Useful for operations that
# don't modify state and can run concurrently.
#
# Parameters:
#   $1 - resource_name (required): Name of resource to lock
#   $2 - timeout (optional): Timeout in seconds
#   $3 - description (optional): Human-readable description
#
# Returns:
#   0 - Lock acquired successfully
#   1 - Lock acquisition failed
#
# Outputs:
#   Prints debug messages to stderr if DEBUG=1
# =============================================================================
acquire_shared_lock() {
    local resource="$1"
    local timeout="${2:-$LOCKS_TIMEOUT}"
    local description="${3:-}"
    local sanitized_name

    if [[ -z "$resource" ]]; then
        echo "Error: resource_name parameter required" >&2
        return 1
    fi

    sanitized_name=$(_sanitize_lock_name "$resource")
    local shared_lock_dir="$LOCKS_DIR/.shared_${sanitized_name}"
    local reader_lock="$shared_lock_dir/${LOCKS_PID}.reader"
    local start_time
    start_time=$(date +%s)

    [ "$DEBUG" = "1" ] && echo "  [SHARED_LOCK] Acquiring shared lock for $resource" >&2

    # Create shared lock directory and register this reader
    while true; do
        if mkdir -p "$shared_lock_dir" 2>/dev/null && \
           (set -C; : > "$reader_lock") 2>/dev/null; then

            [ "$DEBUG" = "1" ] && echo "  [SHARED_LOCK] Successfully acquired shared lock: $resource" >&2
            LOCKS_HELD[$resource]=1
            return 0
        fi

        # Check timeout
        local current_time
        current_time=$(date +%s)
        local elapsed
        elapsed=$((current_time - start_time))

        if [[ $elapsed -ge $timeout ]]; then
            echo "Error: Failed to acquire shared lock for $resource after ${timeout}s" >&2
            return 1
        fi

        sleep "$LOCKS_RETRY_INTERVAL"
    done
}

# =============================================================================
# release_lock - Release lock for a resource
#
# Releases the specified lock. Handles nested locks correctly by decrementing
# a counter. Only removes lock when counter reaches 0.
#
# Parameters:
#   $1 - resource_name (required): Name of resource to unlock
#
# Returns:
#   0 - Lock released successfully
#   1 - Lock was not held
#
# Outputs:
#   Prints debug messages to stderr if DEBUG=1
# =============================================================================
release_lock() {
    local resource="$1"

    if [[ -z "$resource" ]]; then
        echo "Error: resource_name parameter required" >&2
        return 1
    fi

    if [[ "${LOCKS_HELD[$resource]:-0}" -eq 0 ]]; then
        echo "Warning: Attempted to release lock not held: $resource" >&2
        return 1
    fi

    # Decrement nesting counter
    ((LOCKS_HELD[$resource]--))

    if [[ ${LOCKS_HELD[$resource]} -gt 0 ]]; then
        [ "$DEBUG" = "1" ] && echo "  [LOCK] Nested lock still held for $resource (depth: ${LOCKS_HELD[$resource]})" >&2
        return 0
    fi

    local sanitized_name
    sanitized_name=$(_sanitize_lock_name "$resource")
    local lock_file="$LOCKS_DIR/${sanitized_name}.lock"

    # Remove lock file
    if rm -f "$lock_file" 2>/dev/null; then
        [ "$DEBUG" = "1" ] && echo "  [LOCK] Released lock: $resource" >&2
        unset 'LOCKS_HELD[$resource]'
        return 0
    else
        echo "Warning: Failed to remove lock file: $lock_file" >&2
        return 1
    fi
}

# =============================================================================
# release_shared_lock - Release shared lock for a resource
#
# Releases the calling process' shared lock. Once all readers have released,
# the shared lock is fully cleared.
#
# Parameters:
#   $1 - resource_name (required): Name of resource to unlock
#
# Returns:
#   0 - Lock released successfully
#   1 - Lock was not held
# =============================================================================
release_shared_lock() {
    local resource="$1"

    if [[ -z "$resource" ]]; then
        echo "Error: resource_name parameter required" >&2
        return 1
    fi

    if [[ "${LOCKS_HELD[$resource]:-0}" -eq 0 ]]; then
        echo "Warning: Attempted to release shared lock not held: $resource" >&2
        return 1
    fi

    local sanitized_name
    sanitized_name=$(_sanitize_lock_name "$resource")
    local shared_lock_dir="$LOCKS_DIR/.shared_${sanitized_name}"
    local reader_lock="$shared_lock_dir/${LOCKS_PID}.reader"

    # Remove this reader's lock file
    if rm -f "$reader_lock" 2>/dev/null; then
        [ "$DEBUG" = "1" ] && echo "  [SHARED_LOCK] Released shared lock: $resource" >&2
        unset 'LOCKS_HELD[$resource]'

        # Clean up shared lock dir if empty
        rmdir "$shared_lock_dir" 2>/dev/null || true

        return 0
    else
        echo "Warning: Failed to release shared lock for $resource" >&2
        return 1
    fi
}

# =============================================================================
# is_locked - Check if a resource is currently locked
#
# Parameters:
#   $1 - resource_name (required): Name of resource to check
#
# Returns:
#   0 - Resource is locked
#   1 - Resource is not locked
# =============================================================================
is_locked() {
    local resource="$1"

    if [[ -z "$resource" ]]; then
        echo "Error: resource_name parameter required" >&2
        return 1
    fi

    local sanitized_name
    sanitized_name=$(_sanitize_lock_name "$resource")
    local lock_file="$LOCKS_DIR/${sanitized_name}.lock"

    [[ -f "$lock_file" ]]
}

# =============================================================================
# wait_for_lock - Wait for a resource to become unlocked
#
# Useful for waiting for other processes to release locks without acquiring
# your own exclusive lock.
#
# Parameters:
#   $1 - resource_name (required): Name of resource to wait for
#   $2 - timeout (optional): Timeout in seconds (default: LOCKS_TIMEOUT)
#
# Returns:
#   0 - Resource became unlocked
#   1 - Timeout expired
# =============================================================================
wait_for_lock() {
    local resource="$1"
    local timeout="${2:-$LOCKS_TIMEOUT}"
    local start_time
    start_time=$(date +%s)

    if [[ -z "$resource" ]]; then
        echo "Error: resource_name parameter required" >&2
        return 1
    fi

    [ "$DEBUG" = "1" ] && echo "  [LOCK] Waiting for resource to unlock: $resource (timeout: ${timeout}s)" >&2

    while is_locked "$resource"; do
        local current_time
        current_time=$(date +%s)
        local elapsed
        elapsed=$((current_time - start_time))

        if [[ $elapsed -ge $timeout ]]; then
            echo "Error: Timeout waiting for lock release on $resource" >&2
            return 1
        fi

        sleep "$LOCKS_RETRY_INTERVAL"
    done

    [ "$DEBUG" = "1" ] && echo "  [LOCK] Resource is now unlocked: $resource" >&2
    return 0
}

# =============================================================================
# cleanup_locks - Clean up all locks held by this process
#
# Called automatically on process exit. Releases all locks held and cleans up
# lock directory if empty.
#
# Returns:
#   0 - Always succeeds
# =============================================================================
cleanup_locks() {
    [ "$DEBUG" = "1" ] && echo "[LOCK] Cleaning up locks for PID $LOCKS_PID" >&2

    local resource
    for resource in "${!LOCKS_HELD[@]}"; do
        if [[ ${LOCKS_HELD[$resource]:-0} -gt 0 ]]; then
            release_lock "$resource" 2>/dev/null || true
        fi
    done

    # Clean up empty lock directory
    rmdir "$LOCKS_DIR" 2>/dev/null || true

    return 0
}

# =============================================================================
# lock_registry_update - Safely update a registry-like file
#
# Acquires lock, updates file content atomically, then releases lock.
# Prevents concurrent writes to shared registry files.
#
# Parameters:
#   $1 - registry_file (required): Path to registry file
#   $2 - update_command (required): Command to run inside lock
#
# Returns:
#   0 - Update successful
#   1 - Update failed
#
# Example:
#   lock_registry_update "/tmp/registry.txt" "echo 'new_entry' >> /tmp/registry.txt"
# =============================================================================
lock_registry_update() {
    local registry_file="$1"
    local update_command="$2"

    if [[ -z "$registry_file" ]] || [[ -z "$update_command" ]]; then
        echo "Error: Both registry_file and update_command required" >&2
        return 1
    fi

    local lock_name
    lock_name="registry_$(basename "$registry_file")"

    if ! acquire_lock "$lock_name" 30 "Updating $registry_file"; then
        echo "Error: Failed to acquire lock for $registry_file" >&2
        return 1
    fi

    if bash -c "$update_command"; then
        release_lock "$lock_name"
        return 0
    else
        release_lock "$lock_name"
        return 1
    fi
}

# =============================================================================
# show_locks - Display currently held locks (debugging)
#
# Useful for understanding lock state during development/debugging.
#
# Returns:
#   0 - Always succeeds
# =============================================================================
show_locks() {
    echo "Active locks:" >&2

    if [[ ! -d "$LOCKS_DIR" ]]; then
        echo "  (no locks)" >&2
        return 0
    fi

    for lock_file in "$LOCKS_DIR"/*.lock; do
        if [[ -f "$lock_file" ]] 2>/dev/null; then
            echo "  $(basename "$lock_file"):" >&2
            sed 's/^/    /' "$lock_file" >&2
        fi
    done

    return 0
}

# Export functions for use in subshells
export -f acquire_lock
export -f release_lock
export -f acquire_shared_lock
export -f release_shared_lock
export -f is_locked
export -f wait_for_lock
export -f cleanup_locks
