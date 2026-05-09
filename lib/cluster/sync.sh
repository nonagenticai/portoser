#!/usr/bin/env bash
# =============================================================================
# lib/cluster/sync.sh - Pi Directory Synchronization Library
#
# Provides functions for synchronizing directories between local machine
# and Raspberry Pi hosts using rsync over SSH.
#
# Functions:
#   - sync_pi_directory()        Sync a directory from/to a Pi
#   - sync_all_pis()             Sync directories for all Pis
#   - test_ssh_connectivity()    Test SSH connection to a Pi
#   - get_sync_excludes()        Get default rsync exclude patterns
#
# Dependencies: ssh, sshpass, rsync
# Created: 2025-12-03
# =============================================================================

set -euo pipefail

# Default configuration. SSH password may be left empty when key-based auth
# is in use (the default for any production deployment); leave SYNC_DEFAULT_PASSWORD
# unset and the sync_* functions will fall back to ssh's normal key auth.
SYNC_DEFAULT_PASSWORD="${SYNC_DEFAULT_PASSWORD:-}"
SYNC_DEFAULT_BASE="${SYNC_DEFAULT_BASE:-<sync-base>}"

# Per-host base directory for syncs. Override per-host with
# SYNC_PI_PATH_<HOST> env vars (e.g. SYNC_PI_PATH_PI1=/home/pi1/portoser),
# or assign directly to SYNC_PI_PATHS in your wrapper before calling sync.
declare -gA SYNC_PI_PATHS=(
    ["pi1"]="${SYNC_PI_PATH_PI1:-/home/pi1/${SYNC_DEFAULT_BASE}}"
    ["pi2"]="${SYNC_PI_PATH_PI2:-/home/pi2/${SYNC_DEFAULT_BASE}}"
    ["pi3"]="${SYNC_PI_PATH_PI3:-/home/pi3/${SYNC_DEFAULT_BASE}}"
    ["pi4"]="${SYNC_PI_PATH_PI4:-/home/pi4/${SYNC_DEFAULT_BASE}}"
)

# =============================================================================
# get_sync_excludes - Get default rsync exclude patterns
#
# Returns a list of patterns that should be excluded from sync operations
# to avoid transferring unnecessary files (logs, cache, build artifacts, etc.)
#
# Parameters:
#   None
#
# Returns:
#   0 - Always successful
#
# Outputs:
#   Prints exclude patterns to stdout, one per line
#   Each line is in format: --exclude='pattern'
#
# Example:
#   rsync $(get_sync_excludes) source/ dest/
# =============================================================================
get_sync_excludes() {
    cat << 'EOF'
--exclude='*.pyc'
--exclude='__pycache__'
--exclude='node_modules'
--exclude='.git'
--exclude='.venv'
--exclude='venv'
--exclude='*.log'
--exclude='.DS_Store'
--exclude='*.swp'
--exclude='*.tmp'
--exclude='.pytest_cache'
--exclude='.mypy_cache'
--exclude='dist'
--exclude='build'
EOF
    return 0
}

# =============================================================================
# test_ssh_connectivity - Test SSH connection to a Raspberry Pi
#
# Tests whether SSH connection to a Pi is working by attempting to execute
# a simple echo command. Uses password authentication.
#
# Parameters:
#   $1 - pi_name (required): Pi host name (pi1, pi2, pi3, pi4)
#   $2 - password (optional): SSH password
#                             Default: "pi"
#   $3 - timeout (optional): Connection timeout in seconds
#                           Default: 5
#
# Returns:
#   0 - SSH connection successful
#   1 - SSH connection failed
#   2 - Invalid parameters
#
# Outputs:
#   Prints status messages to stderr
#   Prints "OK" to stdout on success
#
# Example:
#   if test_ssh_connectivity "pi1"; then
#       echo "Pi1 is reachable"
#   fi
# =============================================================================
test_ssh_connectivity() {
    local pi_name="$1"
    local password="${2:-$SYNC_DEFAULT_PASSWORD}"
    local timeout="${3:-5}"

    # Validate parameters
    if [[ -z "$pi_name" ]]; then
        echo "Error: pi_name parameter is required" >&2
        return 2
    fi

    # Check dependencies
    if ! command -v sshpass &> /dev/null; then
        echo "Error: sshpass is not installed" >&2
        return 2
    fi

    # Test connection
    local ssh_host="${pi_name}@${pi_name}.local"

    if sshpass -p "$password" ssh \
        -o ConnectTimeout="$timeout" \
        -o StrictHostKeyChecking=accept-new \
        -o BatchMode=no \
        "$ssh_host" "echo 'SSH OK'" &> /dev/null; then
        echo "OK"
        return 0
    else
        echo "Error: Cannot connect to $pi_name via SSH" >&2
        return 1
    fi
}

# =============================================================================
# sync_pi_directory - Synchronize a directory with a Raspberry Pi
#
# Synchronizes a directory between the local machine and a Pi using rsync.
# Supports both push (local->Pi) and pull (Pi->local) operations.
#
# Parameters:
#   $1 - pi_name (required): Pi host name (pi1, pi2, pi3, pi4)
#   $2 - direction (required): "push" or "pull"
#   $3 - local_path (optional): Local directory path
#                               Default: "<sync-base>/<pi_name>"
#   $4 - remote_path (optional): Remote directory path
#                                Default: SYNC_PI_PATHS[$pi_name]
#   $5 - password (optional): SSH password
#                             Default: $SYNC_DEFAULT_PASSWORD (empty by
#                             default — use key-based auth)
#   $6 - delete (optional): Set to "true" to use --delete flag
#                          Default: "false"
#
# Returns:
#   0 - Sync successful
#   1 - Sync failed
#   2 - Invalid parameters
#
# Outputs:
#   Prints rsync progress to stderr
#
# Example:
#   sync_pi_directory "pi1" "pull"
#   sync_pi_directory "pi2" "push" "/path/to/local" "/path/to/remote" "password" "true"
# =============================================================================
sync_pi_directory() {
    local pi_name="$1"
    local direction="$2"
    local local_path="${3:-${SYNC_DEFAULT_BASE}/${pi_name}}"
    local remote_path="${4:-${SYNC_PI_PATHS[$pi_name]:-}}"
    local password="${5:-$SYNC_DEFAULT_PASSWORD}"
    local delete="${6:-false}"

    # Validate parameters
    if [[ -z "$pi_name" ]]; then
        echo "Error: pi_name parameter is required" >&2
        return 2
    fi

    if [[ -z "$direction" ]]; then
        echo "Error: direction parameter is required" >&2
        return 2
    fi

    if [[ "$direction" != "push" ]] && [[ "$direction" != "pull" ]]; then
        echo "Error: direction must be 'push' or 'pull'" >&2
        return 2
    fi

    if [[ -z "$remote_path" ]]; then
        echo "Error: No remote path configured for $pi_name" >&2
        return 2
    fi

    # Check dependencies
    if ! command -v sshpass &> /dev/null; then
        echo "Error: sshpass is not installed" >&2
        return 2
    fi

    if ! command -v rsync &> /dev/null; then
        echo "Error: rsync is not installed" >&2
        return 2
    fi

    echo "Syncing $pi_name ($direction)..." >&2

    # Test SSH connectivity first
    if ! test_ssh_connectivity "$pi_name" "$password" 5 &> /dev/null; then
        echo "Error: Cannot connect to $pi_name" >&2
        return 1
    fi

    local ssh_host="${pi_name}@${pi_name}.local"

    # Build rsync command
    local rsync_args=(-avz)

    # Add delete flag if requested
    if [[ "$delete" == "true" ]]; then
        rsync_args+=(--delete)
    fi

    # Add exclude patterns
    while IFS= read -r exclude_pattern; do
        rsync_args+=("$exclude_pattern")
    done < <(get_sync_excludes)

    # Add SSH options
    rsync_args+=(-e "ssh -o StrictHostKeyChecking=accept-new")

    # Determine source and destination based on direction
    local source
    local dest

    if [[ "$direction" == "pull" ]]; then
        # Create local directory if it doesn't exist
        mkdir -p "$local_path"
        source="${ssh_host}:${remote_path}/"
        dest="${local_path}/"
        echo "  Source: ${ssh_host}:${remote_path}" >&2
        echo "  Dest:   ${local_path}" >&2
    else
        # Push
        if [[ ! -d "$local_path" ]]; then
            echo "Error: Local path does not exist: $local_path" >&2
            return 2
        fi
        source="${local_path}/"
        dest="${ssh_host}:${remote_path}/"
        echo "  Source: ${local_path}" >&2
        echo "  Dest:   ${ssh_host}:${remote_path}" >&2
    fi

    # Execute rsync
    if sshpass -p "$password" rsync "${rsync_args[@]}" "$source" "$dest" 2>&1; then
        echo "Successfully synced $pi_name" >&2
        return 0
    else
        echo "Error: Failed to sync $pi_name" >&2
        return 1
    fi
}

# =============================================================================
# sync_all_pis - Synchronize directories for all Pis
#
# Synchronizes directories for multiple Pi hosts. Can sync specific Pis or
# all Pis (pi1-pi4). Tests connectivity before attempting sync.
#
# Parameters:
#   $1 - direction (required): "push" or "pull"
#   $2 - pi_list (optional): Space-separated list of Pi names
#                           Default: "pi1 pi2 pi3 pi4"
#   $3 - base_dir (optional): Base directory for local paths
#                            Default: "<sync-base>"
#   $4 - delete (optional): Set to "true" to use --delete flag
#                          Default: "false"
#
# Returns:
#   0 - All syncs successful
#   1 - One or more syncs failed
#   2 - Invalid parameters
#
# Outputs:
#   Prints progress for each Pi to stderr
#   Returns summary of successes and failures
#
# Example:
#   sync_all_pis "pull"
#   sync_all_pis "push" "pi1 pi3"
#   sync_all_pis "pull" "pi1 pi2" "/custom/base" "true"
# =============================================================================
sync_all_pis() {
    local direction="$1"
    local pi_list="${2:-pi1 pi2 pi3 pi4}"
    local base_dir="${3:-$SYNC_DEFAULT_BASE}"
    local delete="${4:-false}"

    # Validate parameters
    if [[ -z "$direction" ]]; then
        echo "Error: direction parameter is required" >&2
        return 2
    fi

    if [[ "$direction" != "push" ]] && [[ "$direction" != "pull" ]]; then
        echo "Error: direction must be 'push' or 'pull'" >&2
        return 2
    fi

    echo "Syncing Pis: $pi_list (direction: $direction)" >&2
    echo "" >&2

    local success_count=0
    local failed_count=0
    local failed_pis=()

    # Sync each Pi
    for pi_name in $pi_list; do
        echo "----------------------------------------" >&2
        echo "Syncing $pi_name" >&2
        echo "----------------------------------------" >&2

        # Validate pi_name format
        if [[ ! "$pi_name" =~ ^pi[1-4]$ ]]; then
            echo "Error: Invalid Pi name: $pi_name (must be pi1, pi2, pi3, or pi4)" >&2
            ((failed_count++))
            failed_pis+=("$pi_name")
            continue
        fi

        local local_path="${base_dir}/${pi_name}"
        local remote_path="${SYNC_PI_PATHS[$pi_name]}"

        if sync_pi_directory "$pi_name" "$direction" "$local_path" "$remote_path" "$SYNC_DEFAULT_PASSWORD" "$delete"; then
            ((success_count++))

            # Show size if pull and directory exists
            if [[ "$direction" == "pull" ]] && [[ -d "$local_path" ]]; then
                local size
                size=$(du -sh "$local_path" 2>/dev/null | cut -f1 || echo "unknown")
                echo "  Size: $size" >&2
            fi
        else
            ((failed_count++))
            failed_pis+=("$pi_name")
        fi

        echo "" >&2
    done

    echo "========================================" >&2
    echo "Sync Complete" >&2
    echo "========================================" >&2
    echo "Successful: $success_count" >&2
    echo "Failed: $failed_count" >&2

    if [[ $failed_count -gt 0 ]]; then
        echo "" >&2
        echo "Failed Pis:" >&2
        for pi in "${failed_pis[@]}"; do
            echo "  - $pi" >&2
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
    echo "Usage: source lib/cluster/sync.sh" >&2
    exit 1
fi
