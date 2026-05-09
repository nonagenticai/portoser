#!/usr/bin/env bash
# lib/utils/process.sh - Process management utilities
#
# This library provides centralized process management functions,
# eliminating duplication across local.sh, dns.sh, and docker_registry.sh
#
# Functions:
#   - get_process_on_port(port) - Get PID using a specific port
#   - kill_process_on_port(port, machine) - Kill process on port (local or remote)
#   - graceful_kill(pid, timeout) - Gracefully terminate a process
#   - force_kill(pid) - Force kill a process with SIGKILL
#   - kill_process_tree(pid) - Kill process and all children
#

set -euo pipefail

################################################################################
# Get Process Information
################################################################################

# Get the PID(s) using a specific port (local only)
# Usage: get_process_on_port PORT
# Returns: PID(s) on stdout, empty if none found
get_process_on_port() {
    local port="$1"

    if [ -z "$port" ]; then
        echo "Error: Port required" >&2
        return 1
    fi

    # Find all PIDs using the port
    lsof -ti ":$port" 2>/dev/null || true
}

# Get process info string for display
# Usage: get_process_info PORT
# Returns: Human-readable process information
get_process_info() {
    local port="$1"

    if [ -z "$port" ]; then
        echo "Error: Port required" >&2
        return 1
    fi

    lsof -i ":$port" 2>/dev/null | grep LISTEN | awk '{print $1 " (PID: " $2 ")"}' | sort -u
}

################################################################################
# Process Termination Functions
################################################################################

# Gracefully terminate a process with timeout
# Usage: graceful_kill PID [TIMEOUT_SECONDS]
# Returns: 0 if killed, 1 if timeout
graceful_kill() {
    local pid="$1"
    local timeout="${2:-3}"

    if [ -z "$pid" ]; then
        echo "Error: PID required" >&2
        return 1
    fi

    if ! ps -p "$pid" > /dev/null 2>&1; then
        return 0  # Process already dead
    fi

    # Send SIGTERM (graceful)
    kill -TERM "$pid" 2>/dev/null || return 0

    # Wait for process to exit
    local count=0
    while ps -p "$pid" > /dev/null 2>&1 && [ $count -lt "$timeout" ]; do
        sleep 1
        count=$((count + 1))
    done

    # Check if process exited
    if ps -p "$pid" > /dev/null 2>&1; then
        return 1  # Still running
    fi

    return 0  # Successfully killed
}

# Force kill a process with SIGKILL
# Usage: force_kill PID
# Returns: 0 if killed, 1 if failed
force_kill() {
    local pid="$1"

    if [ -z "$pid" ]; then
        echo "Error: PID required" >&2
        return 1
    fi

    if ! ps -p "$pid" > /dev/null 2>&1; then
        return 0  # Process already dead
    fi

    kill -9 "$pid" 2>/dev/null || true

    # Wait a moment for OS to clean up
    sleep 1

    # Verify it's really gone
    if ps -p "$pid" > /dev/null 2>&1; then
        return 1  # Still running (shouldn't happen with SIGKILL)
    fi

    return 0
}

# Kill a process and all its children
# Usage: kill_process_tree PID [TIMEOUT_SECONDS]
# Returns: 0 if successful, 1 if process still running
kill_process_tree() {
    local pid="$1"
    local timeout="${2:-3}"

    if [ -z "$pid" ]; then
        echo "Error: PID required" >&2
        return 1
    fi

    if ! ps -p "$pid" > /dev/null 2>&1; then
        return 0  # Process already dead
    fi

    # Find all child processes
    local child_pids
    child_pids=$(pgrep -P "$pid" 2>/dev/null || true)

    # Try graceful termination first
    if graceful_kill "$pid" "$timeout"; then
        # Kill any remaining children
        if [ -n "$child_pids" ]; then
            echo "$child_pids" | xargs kill -TERM 2>/dev/null || true
            sleep 1
            echo "$child_pids" | xargs kill -9 2>/dev/null || true
        fi
        return 0
    fi

    # If graceful failed, force kill parent and children
    force_kill "$pid"
    if [ -n "$child_pids" ]; then
        echo "$child_pids" | xargs kill -9 2>/dev/null || true
    fi

    sleep 1

    # Final verification
    if ps -p "$pid" > /dev/null 2>&1; then
        return 1  # Still running
    fi

    return 0
}

################################################################################
# Kill Process on Port (Local and Remote)
################################################################################

# Kill process(es) on a specific port
# Usage: kill_process_on_port PORT [MACHINE]
# Returns: 0 if successful, 1 if failed
kill_process_on_port() {
    local port="$1"
    local machine="${2:-local}"

    if [ -z "$port" ]; then
        echo "Error: Port required" >&2
        return 1
    fi

    # Validate port is numeric
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid port number: $port" >&2
        return 1
    fi

    # Check if port 8000 - RESERVED for mother's server
    if [ "$port" = "8000" ]; then
        echo "Error: Port 8000 is RESERVED (mother's server)" >&2
        return 1
    fi

    if [ "$machine" = "local" ]; then
        _kill_process_on_port_local "$port"
    else
        _kill_process_on_port_remote "$port" "$machine"
    fi
}

# Kill process on port - LOCAL implementation
# Usage: _kill_process_on_port_local PORT
_kill_process_on_port_local() {
    local port="$1"

    echo "Checking for existing processes on port $port..."

    # Find all PIDs using the port
    local pids
    pids=$(lsof -ti ":$port" 2>/dev/null || true)

    if [ -z "$pids" ]; then
        echo "  No processes found on port $port"
        return 0
    fi

    # Display processes found
    local process_info
    process_info=$(get_process_info "$port")
    echo "Found processes on port $port:"
    # shellcheck disable=SC2001  # per-line prefix; bash parameter expansion can't anchor with ^
    echo "$process_info" | sed 's/^/  /'

    # Kill each PID and its children
    for pid in $pids; do
        if ps -p "$pid" > /dev/null 2>&1; then
            echo "Killing process tree for PID $pid..."

            if kill_process_tree "$pid" 3; then
                echo "  ✓ Process $pid terminated gracefully"
            else
                echo "  ⚠ Process $pid did not stop gracefully, forcing with SIGKILL..."
                if force_kill "$pid"; then
                    echo "  ✓ Process $pid forcefully killed"
                else
                    echo "  ✗ Warning: Process $pid may still be running"
                fi
            fi
        fi
    done

    # Verify port is actually clear
    local verify_count=0
    while lsof -ti ":$port" >/dev/null 2>&1 && [ $verify_count -lt 3 ]; do
        echo "  Port still in use, retrying cleanup..."
        local remaining_pids
        remaining_pids=$(lsof -ti ":$port" 2>/dev/null || true)
        if [ -n "$remaining_pids" ]; then
            echo "$remaining_pids" | xargs kill -9 2>/dev/null || true
        fi
        sleep 2
        verify_count=$((verify_count + 1))
    done

    if lsof -ti ":$port" >/dev/null 2>&1; then
        echo "✗ Warning: Port $port may still be in use by remaining processes"
        lsof -i ":$port" 2>/dev/null | grep LISTEN || true
        return 1
    else
        echo "✓ Port $port fully cleared"
        return 0
    fi
}

# Kill process on port - REMOTE implementation via SSH
# Usage: _kill_process_on_port_remote PORT MACHINE
_kill_process_on_port_remote() {
    local port="$1"
    local machine="$2"

    # Import SSH helpers if available
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$script_dir/ssh_helpers.sh" ]; then
        # shellcheck source=lib/utils/ssh_helpers.sh
        source "$script_dir/ssh_helpers.sh"
    fi

    local ip
    local ssh_user
    local ssh_port

    # Try to get connection info (these functions may or may not exist)
    if command -v get_machine_ip &>/dev/null; then
        ip=$(get_machine_ip "$machine")
    else
        echo "Error: Cannot get machine IP for $machine" >&2
        return 1
    fi

    if command -v get_machine_ssh_user &>/dev/null; then
        ssh_user=$(get_machine_ssh_user "$machine")
    else
        ssh_user="root"
    fi

    if command -v get_machine_ssh_port &>/dev/null; then
        ssh_port=$(get_machine_ssh_port "$machine")
    else
        ssh_port="22"
    fi

    echo "Checking for existing processes on port $port on $machine..."

    # Execute cleanup script on remote machine
    ssh -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" bash -s "$port" <<'REMOTE_EOF'
port=$1

# Find all PIDs using the port
pids=$(lsof -ti :$port 2>/dev/null || true)

if [ -z "$pids" ]; then
    echo "  No processes found on port $port"
    exit 0
fi

# Get process details for reporting
process_info=$(lsof -i :$port 2>/dev/null | grep LISTEN | awk '{print $1 " (PID: " $2 ")"}' | sort -u)
echo "Found processes on port $port:"
echo "$process_info" | sed 's/^/  /'

# Kill each PID and its children
for pid in $pids; do
    if ps -p "$pid" > /dev/null 2>&1; then
        echo "Killing process tree for PID $pid..."

        # Find all child processes
        child_pids=$(pgrep -P "$pid" 2>/dev/null || true)

        # Try graceful termination first (SIGTERM)
        kill -TERM "$pid" 2>/dev/null || true
        if [ -n "$child_pids" ]; then
            echo "$child_pids" | xargs kill -TERM 2>/dev/null || true
        fi

        # Wait up to 3 seconds for graceful shutdown
        count=0
        while ps -p "$pid" > /dev/null 2>&1 && [ $count -lt 3 ]; do
            sleep 1
            count=$((count + 1))
        done

        # Force kill if still running
        if ps -p "$pid" > /dev/null 2>&1; then
            echo "  ⚠ Process $pid did not stop gracefully, forcing with SIGKILL..."
            kill -9 "$pid" 2>/dev/null || true
            if [ -n "$child_pids" ]; then
                echo "$child_pids" | xargs kill -9 2>/dev/null || true
            fi

            # Final verification
            sleep 1
            if ps -p "$pid" > /dev/null 2>&1; then
                echo "  ✗ Warning: Process $pid may still be running"
            else
                echo "  ✓ Process $pid forcefully killed"
            fi
        else
            echo "  ✓ Process $pid terminated gracefully"
        fi
    fi
done

# Verify port is actually clear
verify_count=0
while lsof -ti :$port >/dev/null 2>&1 && [ $verify_count -lt 3 ]; do
    echo "  Port still in use, retrying cleanup..."
    remaining_pids=$(lsof -ti :$port 2>/dev/null || true)
    if [ -n "$remaining_pids" ]; then
        echo "$remaining_pids" | xargs kill -9 2>/dev/null || true
    fi
    sleep 2
    verify_count=$((verify_count + 1))
done

if lsof -ti :$port >/dev/null 2>&1; then
    echo "✗ Warning: Port $port may still be in use by remaining processes"
    lsof -i :$port 2>/dev/null | grep LISTEN || true
    exit 1
else
    echo "✓ Port $port fully cleared"
    exit 0
fi
REMOTE_EOF

    return $?
}

# Export functions for use in subshells
export -f get_process_on_port
export -f get_process_info
export -f graceful_kill
export -f force_kill
export -f kill_process_tree
export -f kill_process_on_port
