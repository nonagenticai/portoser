#!/usr/bin/env bash
# lib/utils/ssh_helpers.sh - SSH connection and file transfer utilities
#
# This library provides centralized SSH operations, eliminating duplication
# across remote.sh, databases.sh, certificates.sh, and other files.
#
# Functions:
#   - check_ssh_connection(machine) - Test SSH connectivity
#   - remote_exec(machine, command) - Execute command on remote machine
#   - remote_copy_to(local_file, machine, remote_path) - Copy file to remote
#   - remote_copy_from(machine, remote_file, local_path) - Copy file from remote
#   - ssh_exec_with_key(machine, key_file, command) - Execute with specific key
#   - ssh_copy_with_key(machine, key_file, local_file, remote_path) - Copy with key
#

set -euo pipefail

################################################################################
# SSH Connection Verification
################################################################################

# Check SSH connectivity to a machine
# Usage: check_ssh_connection MACHINE [TIMEOUT]
# Returns: 0 if connected, 1 if not
check_ssh_connection() {
    local machine="$1"
    local timeout="${2:-5}"

    if [ -z "$machine" ]; then
        echo "Error: Machine name required" >&2
        return 1
    fi

    # Get connection parameters
    local ip
    local ssh_user
    local ssh_port

    if ! command -v get_machine_ip &>/dev/null; then
        echo "Error: Machine configuration functions not available" >&2
        return 1
    fi

    ip=$(get_machine_ip "$machine") || return 1
    ssh_user=$(get_machine_ssh_user "$machine" 2>/dev/null || echo "root")
    ssh_port=$(get_machine_ssh_port "$machine" 2>/dev/null || echo "22")

    # Try to connect with timeout
    if ssh -p "$ssh_port" -o ConnectTimeout="$timeout" -o BatchMode=yes \
        -o StrictHostKeyChecking=no "$ssh_user@$ip" "echo 'SSH OK'" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Wait for SSH to become available on a machine
# Usage: wait_for_ssh MACHINE [MAX_ATTEMPTS] [DELAY_SECONDS]
# Returns: 0 if SSH becomes available, 1 if timeout
wait_for_ssh() {
    local machine="$1"
    local max_attempts="${2:-30}"
    local delay="${3:-2}"

    local attempt=0
    while [ $attempt -lt "$max_attempts" ]; do
        if check_ssh_connection "$machine" 5; then
            return 0
        fi
        attempt=$((attempt + 1))
        if [ $attempt -lt "$max_attempts" ]; then
            echo "  Waiting for SSH on $machine... (attempt $attempt/$max_attempts)"
            sleep "$delay"
        fi
    done

    echo "Error: SSH connection failed after $max_attempts attempts" >&2
    return 1
}

################################################################################
# Remote Command Execution
################################################################################

# Execute command on remote machine
# Usage: remote_exec MACHINE COMMAND [ARGS...]
# Returns: Command exit code
remote_exec() {
    local machine="$1"
    shift
    local command="$*"

    if [ -z "$machine" ] || [ -z "$command" ]; then
        echo "Error: Machine and command required" >&2
        return 1
    fi

    # Get connection parameters
    local ip
    local ssh_user
    local ssh_port

    if ! command -v get_machine_ip &>/dev/null; then
        echo "Error: Machine configuration functions not available" >&2
        return 1
    fi

    ip=$(get_machine_ip "$machine") || return 1
    ssh_user=$(get_machine_ssh_user "$machine" 2>/dev/null || echo "root")
    ssh_port=$(get_machine_ssh_port "$machine" 2>/dev/null || echo "22")

    [ "${DEBUG:-0}" = "1" ] && echo "Debug: Executing on $machine: $command" >&2

    # Security: Pass command as separate SSH argument, properly quoted
    ssh -p "$ssh_port" -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "$ssh_user@$ip" -- "$command"
}

# Execute command with script input on remote machine
# Usage: remote_exec_script MACHINE [STDIN_SCRIPT]
# Returns: Command exit code
# Note: If STDIN_SCRIPT is provided, it will be piped to the remote bash
remote_exec_script() {
    local machine="$1"
    local script="${2:-}"

    if [ -z "$machine" ]; then
        echo "Error: Machine name required" >&2
        return 1
    fi

    # Get connection parameters
    local ip
    local ssh_user
    local ssh_port

    if ! command -v get_machine_ip &>/dev/null; then
        echo "Error: Machine configuration functions not available" >&2
        return 1
    fi

    ip=$(get_machine_ip "$machine") || return 1
    ssh_user=$(get_machine_ssh_user "$machine" 2>/dev/null || echo "root")
    ssh_port=$(get_machine_ssh_port "$machine" 2>/dev/null || echo "22")

    if [ -n "$script" ]; then
        echo "$script" | ssh -p "$ssh_port" -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=no "$ssh_user@$ip" bash
    else
        ssh -p "$ssh_port" -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
            "$ssh_user@$ip" bash
    fi
}

################################################################################
# Remote File Transfer
################################################################################

# Copy file to remote machine
# Usage: remote_copy_to LOCAL_FILE MACHINE REMOTE_PATH
# Returns: 0 if successful, 1 if failed
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

    # Get connection parameters
    local ip
    local ssh_user
    local ssh_port

    if ! command -v get_machine_ip &>/dev/null; then
        echo "Error: Machine configuration functions not available" >&2
        return 1
    fi

    ip=$(get_machine_ip "$machine") || return 1
    ssh_user=$(get_machine_ssh_user "$machine" 2>/dev/null || echo "root")
    ssh_port=$(get_machine_ssh_port "$machine" 2>/dev/null || echo "22")

    echo "Copying $local_file to $machine:$remote_path..."

    if scp -P "$ssh_port" -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "$local_file" "$ssh_user@$ip:$remote_path" > /dev/null 2>&1; then
        echo "✓ File copied successfully"
        return 0
    else
        echo "✗ Failed to copy file" >&2
        return 1
    fi
}

# Copy file from remote machine
# Usage: remote_copy_from MACHINE REMOTE_FILE LOCAL_PATH
# Returns: 0 if successful, 1 if failed
remote_copy_from() {
    local machine="$1"
    local remote_file="$2"
    local local_path="$3"

    if [ -z "$machine" ] || [ -z "$remote_file" ] || [ -z "$local_path" ]; then
        echo "Error: Machine, remote file, and local path required" >&2
        return 1
    fi

    # Get connection parameters
    local ip
    local ssh_user
    local ssh_port

    if ! command -v get_machine_ip &>/dev/null; then
        echo "Error: Machine configuration functions not available" >&2
        return 1
    fi

    ip=$(get_machine_ip "$machine") || return 1
    ssh_user=$(get_machine_ssh_user "$machine" 2>/dev/null || echo "root")
    ssh_port=$(get_machine_ssh_port "$machine" 2>/dev/null || echo "22")

    echo "Copying from $machine:$remote_file to $local_path..."

    if scp -P "$ssh_port" -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "$ssh_user@$ip:$remote_file" "$local_path" > /dev/null 2>&1; then
        echo "✓ File copied successfully"
        return 0
    else
        echo "✗ Failed to copy file" >&2
        return 1
    fi
}

# Recursive copy to remote machine
# Usage: remote_copy_to_recursive LOCAL_DIR MACHINE REMOTE_PATH
# Returns: 0 if successful, 1 if failed
remote_copy_to_recursive() {
    local local_dir="$1"
    local machine="$2"
    local remote_path="$3"

    if [ -z "$local_dir" ] || [ -z "$machine" ] || [ -z "$remote_path" ]; then
        echo "Error: Local directory, machine, and remote path required" >&2
        return 1
    fi

    if [ ! -d "$local_dir" ]; then
        echo "Error: Local directory not found: $local_dir" >&2
        return 1
    fi

    # Get connection parameters
    local ip
    local ssh_user
    local ssh_port

    if ! command -v get_machine_ip &>/dev/null; then
        echo "Error: Machine configuration functions not available" >&2
        return 1
    fi

    ip=$(get_machine_ip "$machine") || return 1
    ssh_user=$(get_machine_ssh_user "$machine" 2>/dev/null || echo "root")
    ssh_port=$(get_machine_ssh_port "$machine" 2>/dev/null || echo "22")

    echo "Copying directory $local_dir to $machine:$remote_path..."

    if scp -r -P "$ssh_port" -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "$local_dir" "$ssh_user@$ip:$remote_path" > /dev/null 2>&1; then
        echo "✓ Directory copied successfully"
        return 0
    else
        echo "✗ Failed to copy directory" >&2
        return 1
    fi
}

################################################################################
# SSH with Specific Key
################################################################################

# Execute command with specific SSH key
# Usage: ssh_exec_with_key MACHINE KEY_FILE COMMAND [ARGS...]
# Returns: Command exit code
ssh_exec_with_key() {
    local machine="$1"
    local key_file="$2"
    shift 2
    local command="$*"

    if [ -z "$machine" ] || [ -z "$key_file" ] || [ -z "$command" ]; then
        echo "Error: Machine, key file, and command required" >&2
        return 1
    fi

    if [ ! -f "$key_file" ]; then
        echo "Error: Key file not found: $key_file" >&2
        return 1
    fi

    # Get connection parameters
    local ip
    local ssh_user

    if ! command -v get_machine_ip &>/dev/null; then
        echo "Error: Machine configuration functions not available" >&2
        return 1
    fi

    ip=$(get_machine_ip "$machine") || return 1
    ssh_user=$(get_machine_ssh_user "$machine" 2>/dev/null || echo "root")

    # Set restrictive permissions on key if needed
    chmod 600 "$key_file" 2>/dev/null || true

    # Execute with specific key
    ssh -i "$key_file" -o StrictHostKeyChecking=no "$ssh_user@$ip" -- "$command"
}

# Copy file with specific SSH key
# Usage: ssh_copy_with_key MACHINE KEY_FILE LOCAL_FILE REMOTE_PATH
# Returns: 0 if successful, 1 if failed
ssh_copy_with_key() {
    local machine="$1"
    local key_file="$2"
    local local_file="$3"
    local remote_path="$4"

    if [ -z "$machine" ] || [ -z "$key_file" ] || [ -z "$local_file" ] || [ -z "$remote_path" ]; then
        echo "Error: Machine, key file, local file, and remote path required" >&2
        return 1
    fi

    if [ ! -f "$key_file" ]; then
        echo "Error: Key file not found: $key_file" >&2
        return 1
    fi

    if [ ! -f "$local_file" ]; then
        echo "Error: Local file not found: $local_file" >&2
        return 1
    fi

    # Get connection parameters
    local ip
    local ssh_user
    local ssh_port

    if ! command -v get_machine_ip &>/dev/null; then
        echo "Error: Machine configuration functions not available" >&2
        return 1
    fi

    ip=$(get_machine_ip "$machine") || return 1
    ssh_user=$(get_machine_ssh_user "$machine" 2>/dev/null || echo "root")
    ssh_port=$(get_machine_ssh_port "$machine" 2>/dev/null || echo "22")

    # Set restrictive permissions on key if needed
    chmod 600 "$key_file" 2>/dev/null || true

    echo "Copying $local_file to $machine:$remote_path with SSH key..."

    if scp -i "$key_file" -P "$ssh_port" -o StrictHostKeyChecking=no \
        "$local_file" "$ssh_user@$ip:$remote_path" > /dev/null 2>&1; then
        echo "✓ File copied successfully"
        return 0
    else
        echo "✗ Failed to copy file" >&2
        return 1
    fi
}

# Export functions for use in subshells
export -f check_ssh_connection
export -f wait_for_ssh
export -f remote_exec
export -f remote_exec_script
export -f remote_copy_to
export -f remote_copy_from
export -f remote_copy_to_recursive
export -f ssh_exec_with_key
export -f ssh_copy_with_key
