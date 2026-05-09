#!/usr/bin/env bash
# lib/utils/python_helpers.sh - Python cache and environment utilities
#
# This library provides centralized Python cache management functions,
# eliminating duplication of flush_python_cache logic across scripts.
#
# Functions:
#   - flush_python_cache(service, machine) - Clear Python cache for a service
#   - clear_pycache_dirs(path) - Remove __pycache__ directories
#   - clear_pyc_files(path) - Remove .pyc and .pyo files
#   - clear_python_cache_at_path(path) - Clear all Python cache at path
#

set -euo pipefail

################################################################################
# Cache Clearing Functions
################################################################################

# Clear __pycache__ directories at a given path
# Usage: clear_pycache_dirs PATH
# Returns: Number of directories removed
clear_pycache_dirs() {
    local path="$1"

    if [ -z "$path" ]; then
        echo "Error: Path required" >&2
        return 1
    fi

    if [ ! -d "$path" ]; then
        echo "Warning: Path not found: $path" >&2
        return 1
    fi

    local count=0
    count=$(find "$path" -type d -name "__pycache__" 2>/dev/null | wc -l | tr -d ' ')

    if [ "$count" -gt 0 ]; then
        find "$path" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
    fi

    echo "$count"
}

# Clear .pyc and .pyo files at a given path
# Usage: clear_pyc_files PATH
# Returns: Number of files removed
clear_pyc_files() {
    local path="$1"

    if [ -z "$path" ]; then
        echo "Error: Path required" >&2
        return 1
    fi

    if [ ! -d "$path" ]; then
        echo "Warning: Path not found: $path" >&2
        return 1
    fi

    local count=0
    count=$(find "$path" -type f \( -name "*.pyc" -o -name "*.pyo" \) 2>/dev/null | wc -l | tr -d ' ')

    if [ "$count" -gt 0 ]; then
        find "$path" -type f \( -name "*.pyc" -o -name "*.pyo" \) -delete 2>/dev/null || true
    fi

    echo "$count"
}

# Clear all Python cache at a given path
# Usage: clear_python_cache_at_path PATH
# Returns: 0 if successful
clear_python_cache_at_path() {
    local path="$1"

    if [ -z "$path" ]; then
        echo "Error: Path required" >&2
        return 1
    fi

    if [ ! -d "$path" ]; then
        echo "Warning: Path not found: $path" >&2
        return 1
    fi

    local pycache_count
    local pyc_count

    pycache_count=$(clear_pycache_dirs "$path")
    pyc_count=$(clear_pyc_files "$path")

    if [ "$pycache_count" -gt 0 ] || [ "$pyc_count" -gt 0 ]; then
        echo "✓ Python cache cleared ($pycache_count __pycache__ dirs, $pyc_count .pyc/.pyo files)"
        return 0
    else
        echo "  No Python cache files found"
        return 0
    fi
}

################################################################################
# Service-Level Cache Flushing
################################################################################

# Flush Python cache for a service (local or remote)
# Usage: flush_python_cache SERVICE_NAME [MACHINE]
# Returns: 0 if successful, 1 if failed
flush_python_cache() {
    local service="$1"
    local machine="${2:-local}"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    if [ "$machine" = "local" ]; then
        _flush_python_cache_local "$service"
    else
        _flush_python_cache_remote "$service" "$machine"
    fi
}

# Flush Python cache - LOCAL implementation
# Usage: _flush_python_cache_local SERVICE_NAME
_flush_python_cache_local() {
    local service="$1"

    # Try to get working directory from files
    # This requires get_working_dir_from_files to be available
    local service_dir
    if command -v get_working_dir_from_files &>/dev/null; then
        service_dir=$(get_working_dir_from_files "$service" 2>/dev/null || true)
    else
        echo "Warning: Cannot locate service directory for $service" >&2
        return 1
    fi

    if [ -z "$service_dir" ] || [ "$service_dir" = "null" ]; then
        echo "Warning: No working directory found for $service" >&2
        return 1
    fi

    if [ ! -d "$service_dir" ]; then
        echo "Warning: Service directory not found: $service_dir" >&2
        return 1
    fi

    echo "Flushing Python cache for $service..."
    clear_python_cache_at_path "$service_dir"
}

# Flush Python cache - REMOTE implementation via SSH
# Usage: _flush_python_cache_remote SERVICE_NAME MACHINE
_flush_python_cache_remote() {
    local service="$1"
    local machine="$2"

    # Import helpers if available
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$script_dir/ssh_helpers.sh" ]; then
        # shellcheck source=lib/utils/ssh_helpers.sh
        source "$script_dir/ssh_helpers.sh"
    fi

    local ip
    local ssh_user
    local ssh_port

    # Try to get connection info
    if ! command -v get_machine_ip &>/dev/null; then
        echo "Error: Cannot get machine info for $machine" >&2
        return 1
    fi

    ip=$(get_machine_ip "$machine")
    ssh_user=$(get_machine_ssh_user "$machine" 2>/dev/null || echo "root")
    ssh_port=$(get_machine_ssh_port "$machine" 2>/dev/null || echo "22")

    # Try to validate service name if function available
    if command -v validate_service_name &>/dev/null; then
        if ! validate_service_name "$service"; then
            echo "Error: Invalid service name" >&2
            return 1
        fi
    fi

    # Try to validate IP if function available
    if command -v validate_ip &>/dev/null; then
        if ! validate_ip "$ip"; then
            echo "Error: Invalid IP address" >&2
            return 1
        fi
    fi

    # Try to get service registry path
    local service_file=""
    local docker_compose=""

    if [ -n "${CADDY_REGISTRY_PATH:-}" ] && [ -f "$CADDY_REGISTRY_PATH" ]; then
        service_file=$(yq eval ".services.${service}.service_file" "$CADDY_REGISTRY_PATH" 2>/dev/null || echo "")
        docker_compose=$(yq eval ".services.${service}.docker_compose" "$CADDY_REGISTRY_PATH" 2>/dev/null || echo "")
    fi

    echo "Flushing Python cache for $service on $machine..."

    # Execute cache flush on remote machine
    ssh -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" bash -s "$service" "$service_file" "$docker_compose" <<'REMOTE_EOF'
service=$1
service_file=$2
docker_compose=$3

# Get service working directory from registry or docker-compose
service_dir=""

if [ -n "$service_file" ] && [ "$service_file" != "null" ]; then
    # Try to get working_dir from service.yml
    if [ -f "$service_file" ]; then
        service_dir=$(yq eval '.working_dir' "$service_file" 2>/dev/null || echo "")
    fi
elif [ -n "$docker_compose" ] && [ "$docker_compose" != "null" ]; then
    # Try to get working_directory or build context from docker-compose.yml
    if [ -f "$docker_compose" ]; then
        service_dir=$(yq eval ".services.${service}.working_dir" "$docker_compose" 2>/dev/null || echo "")
        if [ -z "$service_dir" ] || [ "$service_dir" = "null" ]; then
            service_dir=$(yq eval ".services.${service}.build.context" "$docker_compose" 2>/dev/null || echo "")
        fi
    fi
fi

# If no service_dir found, try common locations
if [ -z "$service_dir" ] || [ "$service_dir" = "null" ]; then
    for base in /home /opt /usr/local /srv; do
        if [ -d "$base/$service" ]; then
            service_dir="$base/$service"
            break
        fi
    done
fi

if [ -z "$service_dir" ] || [ ! -d "$service_dir" ]; then
    echo "Warning: Could not locate service directory for $service" >&2
    exit 1
fi

# Count and remove Python cache
pycache_dirs=$(find "$service_dir" -type d -name "__pycache__" 2>/dev/null | wc -l | tr -d ' ')
pyc_files=$(find "$service_dir" -type f \( -name "*.pyc" -o -name "*.pyo" \) 2>/dev/null | wc -l | tr -d ' ')

find "$service_dir" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$service_dir" -type f \( -name "*.pyc" -o -name "*.pyo" \) -delete 2>/dev/null || true

if [ "$pycache_dirs" -gt 0 ] || [ "$pyc_files" -gt 0 ]; then
    echo "✓ Python cache cleared for $service ($pycache_dirs __pycache__ dirs, $pyc_files .pyc/.pyo files)"
else
    echo "  No Python cache files found"
fi
exit 0
REMOTE_EOF

    return $?
}

################################################################################
# Python Virtual Environment Utilities
################################################################################

# Detect if a Python virtual environment is present at a path
# Usage: has_python_venv PATH
# Returns: 0 if venv found, 1 otherwise
has_python_venv() {
    local path="$1"

    if [ -z "$path" ] || [ ! -d "$path" ]; then
        return 1
    fi

    # Check for venv markers
    if [ -f "$path/bin/activate" ] || [ -f "$path/Scripts/activate" ]; then
        return 0
    fi

    # Check for venv directory
    if [ -d "$path/venv" ]; then
        return 0
    fi

    if [ -d "$path/.venv" ]; then
        return 0
    fi

    return 1
}

# Activate Python virtual environment
# Usage: activate_python_venv PATH
# Note: This should be sourced, not executed in a subshell
activate_python_venv() {
    local path="$1"

    if [ -z "$path" ] || [ ! -d "$path" ]; then
        echo "Error: Path required and must be a directory" >&2
        return 1
    fi

    # Try standard locations. Each activate is generated by python -m venv at
    # runtime, so shellcheck can't follow the path; suppress with /dev/null.
    if [ -f "$path/bin/activate" ]; then
        # shellcheck source=/dev/null
        source "$path/bin/activate"
        return 0
    fi

    if [ -f "$path/Scripts/activate" ]; then
        # shellcheck source=/dev/null
        source "$path/Scripts/activate"
        return 0
    fi

    if [ -d "$path/venv" ] && [ -f "$path/venv/bin/activate" ]; then
        # shellcheck source=/dev/null
        source "$path/venv/bin/activate"
        return 0
    fi

    if [ -d "$path/.venv" ] && [ -f "$path/.venv/bin/activate" ]; then
        # shellcheck source=/dev/null
        source "$path/.venv/bin/activate"
        return 0
    fi

    echo "Error: No Python virtual environment found at $path" >&2
    return 1
}

# Export functions for use in subshells
export -f clear_pycache_dirs
export -f clear_pyc_files
export -f clear_python_cache_at_path
export -f flush_python_cache
export -f has_python_venv
