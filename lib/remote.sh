#!/usr/bin/env bash
# remote.sh - Functions for SSH remote operations

set -euo pipefail

# Source security validation library from the directory of this file, not via
# the caller's $SCRIPT_DIR (which under set -u is fatal when unset, and silently
# wrong when set to anything other than the repo root).
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$LIB_DIR/utils/security_validation.sh" ]; then
    # shellcheck source=lib/utils/security_validation.sh
    source "$LIB_DIR/utils/security_validation.sh"
fi

# Check SSH connectivity to a machine
# Usage: check_ssh_connection MACHINE
check_ssh_connection() {
    local machine="$1"

    if [ -z "$machine" ]; then
        echo "Error: Machine name required" >&2
        return 1
    fi

    local ip
    if ! ip=$(get_machine_ip "$machine"); then
        return 1
    fi

    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")
    local ssh_port
    ssh_port=$(get_machine_ssh_port "$machine")

    # Try to connect with timeout
    if ssh -p "$ssh_port" -o ConnectTimeout=5 -o BatchMode=yes "$ssh_user@$ip" "echo 2>&1" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Execute command on remote machine
# Usage: remote_exec MACHINE COMMAND
remote_exec() {
    local machine="$1"
    shift
    local command="$*"

    if [ -z "$machine" ] || [ -z "$command" ]; then
        echo "Error: Machine and command required" >&2
        return 1
    fi

    local ip
    if ! ip=$(get_machine_ip "$machine"); then
        return 1
    fi

    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")
    local ssh_port
    ssh_port=$(get_machine_ssh_port "$machine")

    [ "$DEBUG" = "1" ] && echo "Debug: Executing on $machine: $command" >&2

    # Security: Pass command as separate SSH argument, properly quoted
    ssh -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" -- "$command"
}

# Copy file to remote machine
# Usage: remote_copy_to LOCAL_FILE MACHINE REMOTE_PATH
remote_copy_to() {
    local local_file="$1"
    local machine="$2"
    local remote_path="$3"

    if [ -z "$local_file" ] || [ -z "$machine" ] || [ -z "$remote_path" ]; then
        echo "Error: Local file, machine, and remote path required" >&2
        return 1
    fi

    if [ ! -f "$local_file" ]; then
        echo "Error: Local file not found: $local_file" >&2
        return 1
    fi

    local ip
    if ! ip=$(get_machine_ip "$machine"); then
        return 1
    fi

    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")
    local ssh_port
    ssh_port=$(get_machine_ssh_port "$machine")

    echo "Copying $local_file to $machine:$remote_path..."

    if scp -P "$ssh_port" -o ConnectTimeout=10 "$local_file" "$ssh_user@$ip:$remote_path"; then
        echo "✓ File copied successfully"
        return 0
    else
        echo "✗ Failed to copy file" >&2
        return 1
    fi
}

# Copy file from remote machine
# Usage: remote_copy_from MACHINE REMOTE_FILE LOCAL_PATH
remote_copy_from() {
    local machine="$1"
    local remote_file="$2"
    local local_path="$3"

    if [ -z "$machine" ] || [ -z "$remote_file" ] || [ -z "$local_path" ]; then
        echo "Error: Machine, remote file, and local path required" >&2
        return 1
    fi

    local ip
    if ! ip=$(get_machine_ip "$machine"); then
        return 1
    fi

    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")
    local ssh_port
    ssh_port=$(get_machine_ssh_port "$machine")

    echo "Copying $machine:$remote_file to $local_path..."

    if scp -P "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip:$remote_file" "$local_path"; then
        echo "✓ File copied successfully"
        return 0
    else
        echo "✗ Failed to copy file" >&2
        return 1
    fi
}

# Check if directory exists on remote machine
# Usage: remote_dir_exists MACHINE DIRECTORY
remote_dir_exists() {
    local machine="$1"
    local directory="$2"

    if [ -z "$machine" ] || [ -z "$directory" ]; then
        echo "Error: Machine and directory required" >&2
        return 1
    fi

    local ip
    if ! ip=$(get_machine_ip "$machine"); then
        return 1
    fi

    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")
    local ssh_port
    ssh_port=$(get_machine_ssh_port "$machine")

    # Security: Validate path to prevent command injection
    if ! validate_path "$directory" "directory"; then
        return 1
    fi

    # Security: Use printf %q in single quotes to prevent local expansion,
    # then execute remotely where the quoting takes effect
    if ssh -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" -- bash -c '[ -d "$1" ]' _ "$directory" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Check if file exists on remote machine
# Usage: remote_file_exists MACHINE FILE
remote_file_exists() {
    local machine="$1"
    local file="$2"

    if [ -z "$machine" ] || [ -z "$file" ]; then
        echo "Error: Machine and file required" >&2
        return 1
    fi

    local ip
    if ! ip=$(get_machine_ip "$machine"); then
        return 1
    fi

    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")
    local ssh_port
    ssh_port=$(get_machine_ssh_port "$machine")

    # Security: Validate path to prevent command injection
    if ! validate_path "$file" "file"; then
        return 1
    fi

    # Security: Use bash -c with positional parameters to safely pass file path
    if ssh -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" -- bash -c '[ -f "$1" ]' _ "$file" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Create directory on remote machine
# Usage: remote_mkdir MACHINE DIRECTORY
remote_mkdir() {
    local machine="$1"
    local directory="$2"

    if [ -z "$machine" ] || [ -z "$directory" ]; then
        echo "Error: Machine and directory required" >&2
        return 1
    fi

    local ip
    if ! ip=$(get_machine_ip "$machine"); then
        return 1
    fi

    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")
    local ssh_port
    ssh_port=$(get_machine_ssh_port "$machine")

    # Security: Validate path to prevent command injection
    if ! validate_path "$directory" "directory"; then
        return 1
    fi

    echo "Creating directory on $machine: $directory"

    # Security: Use bash -c with positional parameters to safely pass directory path
    if ssh -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" -- bash -c 'mkdir -p "$1"' _ "$directory" 2>/dev/null; then
        echo "✓ Directory created"
        return 0
    else
        echo "✗ Failed to create directory" >&2
        return 1
    fi
}

# Get remote machine hostname
# Usage: remote_hostname MACHINE
remote_hostname() {
    local machine="$1"

    if [ -z "$machine" ]; then
        echo "Error: Machine name required" >&2
        return 1
    fi

    remote_exec "$machine" "hostname"
}

# Get remote machine uptime
# Usage: remote_uptime MACHINE
remote_uptime() {
    local machine="$1"

    if [ -z "$machine" ]; then
        echo "Error: Machine name required" >&2
        return 1
    fi

    remote_exec "$machine" "uptime"
}

# Get remote machine disk usage
# Usage: remote_disk_usage MACHINE [PATH]
remote_disk_usage() {
    local machine="$1"
    local path="${2:-/}"

    if [ -z "$machine" ]; then
        echo "Error: Machine name required" >&2
        return 1
    fi

    # Security: Validate path to prevent command injection
    if ! validate_path "$path" "path"; then
        return 1
    fi

    # Security: Use remote_exec with properly quoted path
    local ip
    ip=$(get_machine_ip "$machine")
    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")
    local ssh_port
    ssh_port=$(get_machine_ssh_port "$machine")

    # Use bash -c with positional parameters for safe path handling
    ssh -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" -- bash -c 'df -h "$1"' _ "$path"
}

# Get remote machine memory usage
# Usage: remote_memory_usage MACHINE
remote_memory_usage() {
    local machine="$1"

    if [ -z "$machine" ]; then
        echo "Error: Machine name required" >&2
        return 1
    fi

    remote_exec "$machine" "free -h"
}

# Sync directory to remote machine
# Usage: remote_sync_to LOCAL_DIR MACHINE REMOTE_DIR
remote_sync_to() {
    local local_dir="$1"
    local machine="$2"
    local remote_dir="$3"

    if [ -z "$local_dir" ] || [ -z "$machine" ] || [ -z "$remote_dir" ]; then
        echo "Error: Local dir, machine, and remote dir required" >&2
        return 1
    fi

    if [ ! -d "$local_dir" ]; then
        echo "Error: Local directory not found: $local_dir" >&2
        return 1
    fi

    local ip
    if ! ip=$(get_machine_ip "$machine"); then
        return 1
    fi

    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")
    local ssh_port
    ssh_port=$(get_machine_ssh_port "$machine")

    echo "Syncing $local_dir to $machine:$remote_dir..."

    # Use rsync for efficient sync; capture rc so set -e at the call site
    # doesn't short-circuit before we get to print the failure message.
    local rc=0
    if command -v rsync >/dev/null 2>&1; then
        rsync -avz --delete -e "ssh -p $ssh_port -o ConnectTimeout=10" "$local_dir/" "$ssh_user@$ip:$remote_dir/" || rc=$?
    else
        scp -P "$ssh_port" -r -o ConnectTimeout=10 "$local_dir"/* "$ssh_user@$ip:$remote_dir/" || rc=$?
    fi

    if [ "$rc" -eq 0 ]; then
        echo "✓ Directory synced successfully"
        return 0
    fi
    echo "✗ Failed to sync directory" >&2
    return 1
}

# Sync directory from remote machine
# Usage: remote_sync_from MACHINE REMOTE_DIR LOCAL_DIR
remote_sync_from() {
    local machine="$1"
    local remote_dir="$2"
    local local_dir="$3"

    if [ -z "$machine" ] || [ -z "$remote_dir" ] || [ -z "$local_dir" ]; then
        echo "Error: Machine, remote dir, and local dir required" >&2
        return 1
    fi

    local ip
    if ! ip=$(get_machine_ip "$machine"); then
        return 1
    fi

    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")
    local ssh_port
    ssh_port=$(get_machine_ssh_port "$machine")

    # Create local directory if it doesn't exist
    mkdir -p "$local_dir"

    echo "Syncing $machine:$remote_dir to $local_dir..."

    local rc=0
    if command -v rsync >/dev/null 2>&1; then
        rsync -avz --delete -e "ssh -p $ssh_port -o ConnectTimeout=10" "$ssh_user@$ip:$remote_dir/" "$local_dir/" || rc=$?
    else
        scp -P "$ssh_port" -r -o ConnectTimeout=10 "$ssh_user@$ip:$remote_dir"/* "$local_dir/" || rc=$?
    fi

    if [ "$rc" -eq 0 ]; then
        echo "✓ Directory synced successfully"
        return 0
    fi
    echo "✗ Failed to sync directory" >&2
    return 1
}

# Sync library files/directories to remote machine using tar
# Usage: remote_sync_libs MACHINE LIB_PATHS... [--dry-run]
#
# Arguments:
#   MACHINE      - Target machine name
#   LIB_PATHS... - Space-separated list of lib subdirectories or files to sync
#                  (relative to $SCRIPT_DIR/lib)
#
# Options:
#   --dry-run    - Show what would be synced without actually transferring
#
# Example:
#   remote_sync_libs host-a metrics platform solve
#   remote_sync_libs host-b "metrics platform" --dry-run
#
# Returns:
#   0 on success, 1 on failure
remote_sync_libs() {
    local machine=""
    local lib_paths=()
    local dry_run=false

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)
                dry_run=true
                shift
                ;;
            *)
                if [ -z "$machine" ]; then
                    machine="$1"
                else
                    lib_paths+=("$1")
                fi
                shift
                ;;
        esac
    done

    # Validate arguments
    if [ -z "$machine" ]; then
        echo "Error: Machine name required" >&2
        echo "Usage: remote_sync_libs MACHINE LIB_PATHS... [--dry-run]" >&2
        return 1
    fi

    if [ ${#lib_paths[@]} -eq 0 ]; then
        echo "Error: At least one lib path required" >&2
        echo "Usage: remote_sync_libs MACHINE LIB_PATHS... [--dry-run]" >&2
        return 1
    fi

    # Get machine connection details
    local ip
    if ! ip=$(get_machine_ip "$machine"); then
        echo "Error: Failed to get IP for machine: $machine" >&2
        return 1
    fi

    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")
    local ssh_port
    ssh_port=$(get_machine_ssh_port "$machine")

    # Determine source directory
    local lib_dir
    if [ -n "${SCRIPT_DIR:-}" ]; then
        lib_dir="$SCRIPT_DIR/lib"
    elif [ -n "${LIB_DIR:-}" ]; then
        # We're already in the lib directory
        lib_dir="$LIB_DIR"
    else
        # Fallback: determine from this script's location
        lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi

    if [ ! -d "$lib_dir" ]; then
        echo "Error: Library directory not found: $lib_dir" >&2
        return 1
    fi

    # Validate that all paths exist and are safe
    local missing_paths=()
    for path in "${lib_paths[@]}"; do
        # Security: Validate each path
        if ! validate_path "$path" "lib_path"; then
            echo "Error: Invalid lib path: $path" >&2
            return 1
        fi

        if [ ! -e "$lib_dir/$path" ]; then
            missing_paths+=("$path")
        fi
    done

    if [ ${#missing_paths[@]} -gt 0 ]; then
        echo "Error: The following lib paths do not exist:" >&2
        for path in "${missing_paths[@]}"; do
            echo "  - $path" >&2
        done
        return 1
    fi

    # Remote destination. The tilde is intentionally left literal — SSH passes
    # the value as a bare token to the remote shell, which performs tilde
    # expansion before any quoting takes effect on the remote side.
    # shellcheck disable=SC2088
    local remote_lib_dir="~/.portoser_lib"

    # Verbose/debug output
    if [ "${VERBOSE:-false}" = "true" ] || [ "${DEBUG:-0}" = "1" ]; then
        echo "Debug: Syncing libraries to $machine" >&2
        echo "Debug: Source: $lib_dir" >&2
        echo "Debug: Target: $ssh_user@$ip:$remote_lib_dir" >&2
        echo "Debug: Paths: ${lib_paths[*]}" >&2
    fi

    # Dry run mode
    if [ "$dry_run" = true ]; then
        echo "DRY RUN: Would sync the following to $machine:$remote_lib_dir:"
        for path in "${lib_paths[@]}"; do
            echo "  - $path"
        done
        echo "Command: tar -C $lib_dir -cf - ${lib_paths[*]} | ssh -p $ssh_port $ssh_user@$ip 'mkdir -p $remote_lib_dir && tar -xf - -C $remote_lib_dir'"
        return 0
    fi

    # Info message
    echo "Syncing ${#lib_paths[@]} lib path(s) to $machine:$remote_lib_dir..."

    # Create remote directory first
    # Security: Use bash -c with properly quoted remote directory
    if ! ssh -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" -- bash -c 'mkdir -p "$1"' _ "$remote_lib_dir" 2>/dev/null; then
        echo "Error: Failed to create remote directory on $machine" >&2
        return 1
    fi

    # Perform tar-based sync
    # Security: Quote array expansion and use bash -c for remote tar
    # Use tar | ssh | tar pattern for efficient bulk transfer
    if tar -C "$lib_dir" -cf - "${lib_paths[@]}" 2>/dev/null | \
       ssh -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" -- bash -c 'tar -xf - -C "$1"' _ "$remote_lib_dir" 2>&1; then

        if [ "${VERBOSE:-false}" = "true" ] || [ "${DEBUG:-0}" = "1" ]; then
            echo "Debug: Successfully synced ${#lib_paths[@]} path(s)" >&2
        fi

        echo "✓ Libraries synced successfully to $machine"
        return 0
    else
        local exit_code=$?
        echo "✗ Failed to sync libraries to $machine (exit code: $exit_code)" >&2

        # Provide more detailed error information
        if [ "${VERBOSE:-false}" = "true" ] || [ "${DEBUG:-0}" = "1" ]; then
            echo "Debug: tar command failed" >&2
            echo "Debug: Check SSH connectivity and tar availability on remote host" >&2
        fi

        return 1
    fi
}

# Test all machine connections
# Usage: test_all_connections
test_all_connections() {
    echo "Testing SSH connections to all machines..."
    echo ""

    local machines
    machines=$(list_machines)
    local all_ok=0

    while IFS= read -r machine; do
        if [ -z "$machine" ]; then
            continue
        fi

        printf "%-20s ... " "$machine"

        if check_ssh_connection "$machine"; then
            echo "✓ Connected"
        else
            echo "✗ Failed"
            all_ok=1
        fi
    done <<< "$machines"

    echo ""
    if [ $all_ok -eq 0 ]; then
        echo "✓ All machines are accessible"
        return 0
    else
        echo "✗ Some machines are not accessible"
        return 1
    fi
}

# Get system info from remote machine
# Usage: remote_system_info MACHINE
remote_system_info() {
    local machine="$1"

    if [ -z "$machine" ]; then
        echo "Error: Machine name required" >&2
        return 1
    fi

    echo "System Information for $machine:"
    echo ""

    local ip
    ip=$(get_machine_ip "$machine")
    echo "IP Address: $ip"
    echo ""

    echo "Hostname:"
    remote_hostname "$machine"
    echo ""

    echo "Uptime:"
    remote_uptime "$machine"
    echo ""

    echo "Disk Usage:"
    remote_disk_usage "$machine"
    echo ""

    echo "Memory Usage:"
    remote_memory_usage "$machine"
    echo ""

    echo "Docker Info:"
    remote_exec "$machine" "docker info 2>/dev/null | grep -E 'Server Version|Containers|Images' || echo 'Docker not available'"
}
