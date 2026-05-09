#!/usr/bin/env bash
#=============================================================================
# File: lib/utils/ssh_pool.sh
# Purpose: SSH connection pooling for improved performance
#
# Description:
#   Manages SSH master connections with connection pooling to avoid
#   repeated connection setup overhead. Uses ControlMaster for persistent
#   multiplexed SSH connections.
#
# Key Features:
#   - Connection pooling with ControlMaster
#   - Batch command execution
#   - Connection health checks
#   - Automatic cleanup
#   - Reuse timeout management
#
# Usage Examples:
#   ssh_pool_init "user@host"
#   ssh_pool_exec "user@host" "command"
#   ssh_pool_batch "user@host" "cmd1" "cmd2" "cmd3"
#   ssh_pool_cleanup "user@host"
#   ssh_pool_cleanup_all
#
#=============================================================================

set -euo pipefail

# SSH Pool configuration
SSH_POOL_CONTROL_DIR="${HOME}/.ssh/control"
SSH_POOL_SOCKET_TIMEOUT=30m          # Socket lifetime
SSH_POOL_CONNECT_TIMEOUT=5            # Connection timeout

# Create control directory if needed
mkdir -p "$SSH_POOL_CONTROL_DIR"
chmod 700 "$SSH_POOL_CONTROL_DIR"

#=============================================================================
# Function: ssh_pool_get_socket_path
# Description: Get the socket path for a given SSH host
# Parameters: USER@HOST[:PORT]
# Returns: Path to socket file
#=============================================================================
ssh_pool_get_socket_path() {
    local host_spec="$1"
    local socket_name

    # Create safe socket name from host@port
    socket_name=$(echo "$host_spec" | tr '@' '_' | tr ':' '_')
    echo "${SSH_POOL_CONTROL_DIR}/socket_${socket_name}"
}

#=============================================================================
# Function: ssh_pool_socket_exists
# Description: Check if a socket file exists and is responsive
# Parameters: USER@HOST[:PORT]
# Returns: 0 if socket exists and works, 1 otherwise
#=============================================================================
ssh_pool_socket_exists() {
    local host_spec="$1"
    local socket_path

    socket_path=$(ssh_pool_get_socket_path "$host_spec")

    if [ ! -S "$socket_path" ] 2>/dev/null; then
        return 1
    fi

    # Test socket responsiveness with -O check
    if ssh -O "check" "$host_spec" >/dev/null 2>&1; then
        return 0
    else
        rm -f "$socket_path" 2>/dev/null || true
        return 1
    fi
}

#=============================================================================
# Function: ssh_pool_init
# Description: Initialize a connection pool for a host
# Parameters: USER@HOST[:PORT]
# Returns: 0 on success, 1 on failure
#=============================================================================
ssh_pool_init() {
    local host_spec="$1"
    local socket_path

    socket_path=$(ssh_pool_get_socket_path "$host_spec")

    # If socket already exists and works, return success
    if ssh_pool_socket_exists "$host_spec"; then
        [ "$DEBUG" = "1" ] && echo "Debug: SSH pool already initialized for $host_spec" >&2
        return 0
    fi

    # Parse host_spec to extract components
    local user_host="$host_spec"
    local port_opt=()

    # Extract port if specified
    if [[ "$host_spec" =~ :([0-9]+)$ ]]; then
        port_opt=(-p "${BASH_REMATCH[1]}")
    fi

    # Initialize master connection with connection pooling
    # Using ControlMaster=auto allows first connection to establish master
    if ssh \
        -o "ControlPath=$socket_path" \
        -o "ControlMaster=auto" \
        -o "ControlPersist=${SSH_POOL_SOCKET_TIMEOUT}" \
        -o "ConnectTimeout=${SSH_POOL_CONNECT_TIMEOUT}" \
        -o "ServerAliveInterval=10" \
        -o "ServerAliveCountMax=3" \
        -o "StrictHostKeyChecking=accept-new" \
        -o "BatchMode=yes" \
        "${port_opt[@]}" \
        "$user_host" "echo 2>&1" >/dev/null 2>&1; then
        [ "$DEBUG" = "1" ] && echo "Debug: SSH pool initialized for $host_spec" >&2
        return 0
    else
        [ "$DEBUG" = "1" ] && echo "Debug: Failed to initialize SSH pool for $host_spec" >&2
        return 1
    fi
}

#=============================================================================
# Function: ssh_pool_exec
# Description: Execute a command using connection pool
# Parameters: USER@HOST[:PORT] COMMAND [ARGS...]
# Returns: Command exit code
#=============================================================================
ssh_pool_exec() {
    local host_spec="$1"
    shift
    local command="$*"

    if [ -z "$host_spec" ] || [ -z "$command" ]; then
        echo "Error: host_spec and command required" >&2
        return 1
    fi

    # Initialize pool if needed
    if ! ssh_pool_socket_exists "$host_spec"; then
        if ! ssh_pool_init "$host_spec"; then
            echo "Error: Failed to initialize SSH pool for $host_spec" >&2
            return 1
        fi
    fi

    local socket_path
    local port_opt=()
    socket_path=$(ssh_pool_get_socket_path "$host_spec")

    # Extract port if specified
    if [[ "$host_spec" =~ :([0-9]+)$ ]]; then
        port_opt=(-p "${BASH_REMATCH[1]}")
    fi

    # Execute command using pooled connection
    ssh \
        -o "ControlPath=$socket_path" \
        -o "ControlMaster=no" \
        -o "ConnectTimeout=${SSH_POOL_CONNECT_TIMEOUT}" \
        -o "ServerAliveInterval=10" \
        -o "ServerAliveCountMax=3" \
        -o "BatchMode=yes" \
        "${port_opt[@]}" \
        "$host_spec" -- "$command"
}

#=============================================================================
# Function: ssh_pool_batch
# Description: Execute multiple commands in a single session
# Parameters: USER@HOST[:PORT] COMMAND1 [COMMAND2 ...]
# Returns: 0 if all commands succeed, 1 otherwise
#=============================================================================
ssh_pool_batch() {
    local host_spec="$1"
    shift

    if [ -z "$host_spec" ] || [ $# -eq 0 ]; then
        echo "Error: host_spec and at least one command required" >&2
        return 1
    fi

    # Initialize pool if needed
    if ! ssh_pool_socket_exists "$host_spec"; then
        if ! ssh_pool_init "$host_spec"; then
            echo "Error: Failed to initialize SSH pool for $host_spec" >&2
            return 1
        fi
    fi

    local socket_path
    local port_opt=()
    socket_path=$(ssh_pool_get_socket_path "$host_spec")

    # Extract port if specified
    if [[ "$host_spec" =~ :([0-9]+)$ ]]; then
        port_opt=(-p "${BASH_REMATCH[1]}")
    fi

    # Build heredoc with all commands
    local command_script="set -e;"
    while [ $# -gt 0 ]; do
        command_script+=" $1;"
        shift
    done

    # Execute all commands in single session
    ssh \
        -o "ControlPath=$socket_path" \
        -o "ControlMaster=no" \
        -o "ConnectTimeout=${SSH_POOL_CONNECT_TIMEOUT}" \
        -o "ServerAliveInterval=10" \
        -o "ServerAliveCountMax=3" \
        -o "BatchMode=yes" \
        "${port_opt[@]}" \
        "$host_spec" bash -c "$command_script"
}

#=============================================================================
# Function: ssh_pool_copy_to
# Description: Copy file to remote using connection pool
# Parameters: USER@HOST[:PORT] LOCAL_FILE REMOTE_PATH
# Returns: 0 on success, 1 on failure
#=============================================================================
ssh_pool_copy_to() {
    local host_spec="$1"
    local local_file="$2"
    local remote_path="$3"

    if [ -z "$host_spec" ] || [ -z "$local_file" ] || [ -z "$remote_path" ]; then
        echo "Error: host_spec, local_file, and remote_path required" >&2
        return 1
    fi

    if [ ! -f "$local_file" ]; then
        echo "Error: Local file not found: $local_file" >&2
        return 1
    fi

    # Initialize pool if needed
    if ! ssh_pool_socket_exists "$host_spec"; then
        if ! ssh_pool_init "$host_spec"; then
            echo "Error: Failed to initialize SSH pool for $host_spec" >&2
            return 1
        fi
    fi

    local socket_path
    local port_opt=()
    socket_path=$(ssh_pool_get_socket_path "$host_spec")

    # Extract port if specified
    if [[ "$host_spec" =~ :([0-9]+)$ ]]; then
        port_opt=(-P "${BASH_REMATCH[1]}")
    fi

    # Use scp with ControlPath for connection reuse
    scp \
        -o "ControlPath=$socket_path" \
        -o "ControlMaster=no" \
        -o "ConnectTimeout=${SSH_POOL_CONNECT_TIMEOUT}" \
        "${port_opt[@]}" \
        "$local_file" "${host_spec}:${remote_path}"
}

#=============================================================================
# Function: ssh_pool_copy_from
# Description: Copy file from remote using connection pool
# Parameters: USER@HOST[:PORT] REMOTE_FILE LOCAL_PATH
# Returns: 0 on success, 1 on failure
#=============================================================================
ssh_pool_copy_from() {
    local host_spec="$1"
    local remote_file="$2"
    local local_path="$3"

    if [ -z "$host_spec" ] || [ -z "$remote_file" ] || [ -z "$local_path" ]; then
        echo "Error: host_spec, remote_file, and local_path required" >&2
        return 1
    fi

    # Initialize pool if needed
    if ! ssh_pool_socket_exists "$host_spec"; then
        if ! ssh_pool_init "$host_spec"; then
            echo "Error: Failed to initialize SSH pool for $host_spec" >&2
            return 1
        fi
    fi

    local socket_path
    local port_opt=()
    socket_path=$(ssh_pool_get_socket_path "$host_spec")

    # Extract port if specified
    if [[ "$host_spec" =~ :([0-9]+)$ ]]; then
        port_opt=(-P "${BASH_REMATCH[1]}")
    fi

    # Use scp with ControlPath for connection reuse
    scp \
        -o "ControlPath=$socket_path" \
        -o "ControlMaster=no" \
        -o "ConnectTimeout=${SSH_POOL_CONNECT_TIMEOUT}" \
        "${port_opt[@]}" \
        "${host_spec}:${remote_file}" "$local_path"
}

#=============================================================================
# Function: ssh_pool_cleanup
# Description: Clean up connection pool for a specific host
# Parameters: USER@HOST[:PORT]
# Returns: 0 always
#=============================================================================
ssh_pool_cleanup() {
    local host_spec="$1"
    local socket_path

    if [ -z "$host_spec" ]; then
        return 0
    fi

    socket_path=$(ssh_pool_get_socket_path "$host_spec")

    # Send exit command to close master
    ssh -O "exit" "$host_spec" 2>/dev/null || true

    # Remove socket file
    rm -f "$socket_path" 2>/dev/null || true

    [ "$DEBUG" = "1" ] && echo "Debug: SSH pool cleaned up for $host_spec" >&2
    return 0
}

#=============================================================================
# Function: ssh_pool_cleanup_all
# Description: Clean up all connection pools
# Returns: 0 always
#=============================================================================
ssh_pool_cleanup_all() {
    if [ -d "$SSH_POOL_CONTROL_DIR" ]; then
        for socket in "$SSH_POOL_CONTROL_DIR"/socket_*; do
            if [ -S "$socket" ]; then
                rm -f "$socket" 2>/dev/null || true
            fi
        done
    fi

    [ "$DEBUG" = "1" ] && echo "Debug: All SSH pools cleaned up" >&2
    return 0
}

#=============================================================================
# Function: ssh_pool_status
# Description: Check status of a connection pool
# Parameters: USER@HOST[:PORT]
# Returns: 0 if pool is active, 1 if not
#=============================================================================
ssh_pool_status() {
    local host_spec="$1"

    if [ -z "$host_spec" ]; then
        echo "Error: host_spec required" >&2
        return 1
    fi

    if ssh_pool_socket_exists "$host_spec"; then
        echo "Active: $host_spec"
        return 0
    else
        echo "Inactive: $host_spec"
        return 1
    fi
}

# Export functions for use in other scripts
export -f ssh_pool_get_socket_path
export -f ssh_pool_socket_exists
export -f ssh_pool_init
export -f ssh_pool_exec
export -f ssh_pool_batch
export -f ssh_pool_copy_to
export -f ssh_pool_copy_from
export -f ssh_pool_cleanup
export -f ssh_pool_cleanup_all
export -f ssh_pool_status
