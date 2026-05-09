#!/usr/bin/env bash
# lib/utils/service_detection.sh - Service detection and lifecycle management
#
# This library provides centralized service detection and management functions,
# eliminating duplication across intelligent_deploy.sh, service_control.sh, etc.
#
# Functions:
#   - detect_service_type(service) - Determine if docker/local/remote
#   - is_service_running(service, machine) - Check if service is running
#   - is_docker_service(service) - Check if service uses Docker
#   - is_local_service(service) - Check if service is local Python
#   - is_remote_service(service) - Check if service is remote
#   - get_service_port(service) - Get service's primary port
#   - get_service_pid_file(service) - Get PID file path
#   - get_service_working_dir(service) - Get working directory
#

set -euo pipefail

################################################################################
# Service Detection
################################################################################

# Detect service type (docker, local, or remote)
# Usage: detect_service_type SERVICE_NAME
# Returns: "docker", "local", "remote", or "unknown"
detect_service_type() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    # Check if service is defined in registry
    if [ -n "${CADDY_REGISTRY_PATH:-}" ] && [ -f "$CADDY_REGISTRY_PATH" ]; then
        local service_type
        service_type=$(yq eval ".services.${service}.type" "$CADDY_REGISTRY_PATH" 2>/dev/null || echo "")

        if [ -n "$service_type" ] && [ "$service_type" != "null" ]; then
            echo "$service_type"
            return 0
        fi

        # Check for docker_compose key (indicates Docker service)
        local docker_compose
        docker_compose=$(yq eval ".services.${service}.docker_compose" "$CADDY_REGISTRY_PATH" 2>/dev/null || echo "")
        if [ -n "$docker_compose" ] && [ "$docker_compose" != "null" ]; then
            echo "docker"
            return 0
        fi

        # Check for service_file key (indicates local/remote service)
        local service_file
        service_file=$(yq eval ".services.${service}.service_file" "$CADDY_REGISTRY_PATH" 2>/dev/null || echo "")
        if [ -n "$service_file" ] && [ "$service_file" != "null" ]; then
            echo "local"
            return 0
        fi
    fi

    echo "unknown"
}

# Check if service is Docker-based
# Usage: is_docker_service SERVICE_NAME
# Returns: 0 if Docker service, 1 otherwise
is_docker_service() {
    local service="$1"

    if [ -z "$service" ]; then
        return 1
    fi

    local service_type
    service_type=$(detect_service_type "$service")

    if [ "$service_type" = "docker" ]; then
        return 0
    fi

    return 1
}

# Check if service is local (Python-based)
# Usage: is_local_service SERVICE_NAME
# Returns: 0 if local service, 1 otherwise
is_local_service() {
    local service="$1"

    if [ -z "$service" ]; then
        return 1
    fi

    local service_type
    service_type=$(detect_service_type "$service")

    if [ "$service_type" = "local" ]; then
        return 0
    fi

    return 1
}

# Check if service is remote
# Usage: is_remote_service SERVICE_NAME MACHINE
# Returns: 0 if remote service, 1 otherwise
is_remote_service() {
    local service="$1"
    local machine="$2"

    if [ -z "$service" ] || [ -z "$machine" ]; then
        return 1
    fi

    # For now, just check if machine is not "local"
    if [ "$machine" != "local" ]; then
        return 0
    fi

    return 1
}

################################################################################
# Service Status Check
################################################################################

# Check if service is running (local)
# Usage: is_service_running_local SERVICE_NAME
# Returns: 0 if running, 1 if not
is_service_running_local() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    # Try to get PID file
    local pid_file
    if command -v get_pid_file &>/dev/null; then
        pid_file=$(get_pid_file "$service" 2>/dev/null || echo "")
    else
        pid_file="/tmp/pids/${service}.pid"
    fi

    # Check if PID file exists and process is running
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || echo "")
        if [ -n "$pid" ] && ps -p "$pid" > /dev/null 2>&1; then
            return 0
        fi
    fi

    # Check if service port is in use (if we can determine port)
    if command -v get_service_port &>/dev/null; then
        local port
        port=$(get_service_port "$service" 2>/dev/null || echo "")
        if [ -n "$port" ] && lsof -ti ":$port" > /dev/null 2>&1; then
            return 0
        fi
    fi

    return 1
}

# Check if service is running (remote via SSH)
# Usage: is_service_running_remote SERVICE_NAME MACHINE
# Returns: 0 if running, 1 if not
is_service_running_remote() {
    local service="$1"
    local machine="$2"

    if [ -z "$service" ] || [ -z "$machine" ]; then
        echo "Error: Service and machine required" >&2
        return 1
    fi

    # Import SSH helpers if available
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$script_dir/ssh_helpers.sh" ]; then
        # shellcheck source=lib/utils/ssh_helpers.sh
        source "$script_dir/ssh_helpers.sh" 2>/dev/null || true
    fi

    # Try remote SSH check
    if command -v remote_exec &>/dev/null; then
        if remote_exec "$machine" "systemctl is-active --quiet $service" 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# Check if service is running (works for local and remote)
# Usage: is_service_running SERVICE_NAME [MACHINE]
# Returns: 0 if running, 1 if not
is_service_running() {
    local service="$1"
    local machine="${2:-local}"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    if [ "$machine" = "local" ]; then
        is_service_running_local "$service"
    else
        is_service_running_remote "$service" "$machine"
    fi
}

################################################################################
# Service Information Retrieval
################################################################################

# Get service's primary port
# Usage: get_service_port SERVICE_NAME
# Returns: Port number on stdout, or empty if not found
get_service_port() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    # Try to get from registry
    if [ -n "${CADDY_REGISTRY_PATH:-}" ] && [ -f "$CADDY_REGISTRY_PATH" ]; then
        local port
        port=$(yq eval ".services.${service}.port" "$CADDY_REGISTRY_PATH" 2>/dev/null || echo "")
        if [ -n "$port" ] && [ "$port" != "null" ]; then
            echo "$port"
            return 0
        fi

        # Try alternative key names
        port=$(yq eval ".services.${service}.internal_port" "$CADDY_REGISTRY_PATH" 2>/dev/null || echo "")
        if [ -n "$port" ] && [ "$port" != "null" ]; then
            echo "$port"
            return 0
        fi
    fi

    return 1
}

# Get service PID file path
# Usage: get_service_pid_file SERVICE_NAME
# Returns: Path on stdout
get_service_pid_file() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    # Default location
    if [ -d "/tmp/pids" ]; then
        echo "/tmp/pids/${service}.pid"
    else
        echo "/var/run/${service}.pid"
    fi
}

# Get service working directory
# Usage: get_service_working_dir SERVICE_NAME [MACHINE]
# Returns: Directory path on stdout
get_service_working_dir() {
    local service="$1"
    local machine="${2:-local}"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    # Try to use existing function if available
    if command -v get_working_dir_from_files &>/dev/null; then
        get_working_dir_from_files "$service" 2>/dev/null || return 1
        return 0
    fi

    # Try registry-based lookup
    if [ -n "${CADDY_REGISTRY_PATH:-}" ] && [ -f "$CADDY_REGISTRY_PATH" ]; then
        local service_file
        local docker_compose
        local service_dir

        service_file=$(yq eval ".services.${service}.service_file" "$CADDY_REGISTRY_PATH" 2>/dev/null || echo "")
        docker_compose=$(yq eval ".services.${service}.docker_compose" "$CADDY_REGISTRY_PATH" 2>/dev/null || echo "")

        if [ -n "$service_file" ] && [ "$service_file" != "null" ] && [ -f "$service_file" ]; then
            service_dir=$(yq eval '.working_dir' "$service_file" 2>/dev/null || echo "")
            if [ -n "$service_dir" ] && [ "$service_dir" != "null" ]; then
                echo "$service_dir"
                return 0
            fi
        fi

        if [ -n "$docker_compose" ] && [ "$docker_compose" != "null" ] && [ -f "$docker_compose" ]; then
            service_dir=$(yq eval ".services.${service}.working_dir" "$docker_compose" 2>/dev/null || echo "")
            if [ -z "$service_dir" ] || [ "$service_dir" = "null" ]; then
                service_dir=$(yq eval ".services.${service}.build.context" "$docker_compose" 2>/dev/null || echo "")
            fi
            if [ -n "$service_dir" ] && [ "$service_dir" != "null" ]; then
                echo "$service_dir"
                return 0
            fi
        fi
    fi

    return 1
}

################################################################################
# Service Lifecycle Management
################################################################################

# Start a service
# Usage: start_service SERVICE_NAME [MACHINE]
# Returns: 0 if successful, 1 if failed
start_service() {
    local service="$1"
    local machine="${2:-local}"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    # Detect service type
    local service_type
    service_type=$(detect_service_type "$service")

    echo "Starting $service service ($service_type)..."

    if [ "$service_type" = "docker" ]; then
        _start_docker_service "$service"
    elif [ "$service_type" = "local" ]; then
        _start_local_service "$service"
    else
        echo "Error: Unknown service type for $service" >&2
        return 1
    fi
}

# Stop a service
# Usage: stop_service SERVICE_NAME [MACHINE]
# Returns: 0 if successful, 1 if failed
stop_service() {
    local service="$1"
    local machine="${2:-local}"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    # Detect service type
    local service_type
    service_type=$(detect_service_type "$service")

    echo "Stopping $service service ($service_type)..."

    if [ "$service_type" = "docker" ]; then
        _stop_docker_service "$service"
    elif [ "$service_type" = "local" ]; then
        _stop_local_service "$service"
    else
        echo "Error: Unknown service type for $service" >&2
        return 1
    fi
}

# Restart a service
# Usage: restart_service SERVICE_NAME [MACHINE]
# Returns: 0 if successful, 1 if failed
restart_service() {
    local service="$1"
    local machine="${2:-local}"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    stop_service "$service" "$machine" || true
    sleep 2
    start_service "$service" "$machine"
}

################################################################################
# Internal Service Start/Stop Implementation
################################################################################

# Start Docker service
# Usage: _start_docker_service SERVICE_NAME
_start_docker_service() {
    local service="$1"

    # Import docker helpers if available
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$script_dir/docker_compose.sh" ]; then
        # shellcheck source=lib/utils/docker_compose.sh
        source "$script_dir/docker_compose.sh" 2>/dev/null || true
    fi

    # Get compose file from registry
    if [ -n "${CADDY_REGISTRY_PATH:-}" ] && [ -f "$CADDY_REGISTRY_PATH" ]; then
        local docker_compose
        docker_compose=$(yq eval ".services.${service}.docker_compose" "$CADDY_REGISTRY_PATH" 2>/dev/null || echo "")

        if [ -n "$docker_compose" ] && [ "$docker_compose" != "null" ] && [ -f "$docker_compose" ]; then
            if command -v compose_up &>/dev/null; then
                compose_up "$docker_compose" "$service"
                return $?
            fi
        fi
    fi

    echo "Warning: Could not determine docker-compose file for $service" >&2
    return 1
}

# Stop Docker service
# Usage: _stop_docker_service SERVICE_NAME
_stop_docker_service() {
    local service="$1"

    # Import docker helpers if available
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$script_dir/docker_compose.sh" ]; then
        # shellcheck source=lib/utils/docker_compose.sh
        source "$script_dir/docker_compose.sh" 2>/dev/null || true
    fi

    # Get compose file from registry
    if [ -n "${CADDY_REGISTRY_PATH:-}" ] && [ -f "$CADDY_REGISTRY_PATH" ]; then
        local docker_compose
        docker_compose=$(yq eval ".services.${service}.docker_compose" "$CADDY_REGISTRY_PATH" 2>/dev/null || echo "")

        if [ -n "$docker_compose" ] && [ "$docker_compose" != "null" ] && [ -f "$docker_compose" ]; then
            if command -v compose_down &>/dev/null; then
                compose_down "$docker_compose" "$service"
                return $?
            fi
        fi
    fi

    echo "Warning: Could not determine docker-compose file for $service" >&2
    return 1
}

# Start local service
# Usage: _start_local_service SERVICE_NAME
_start_local_service() {
    local service="$1"

    # Get service working directory
    local service_dir
    service_dir=$(get_service_working_dir "$service" 2>/dev/null || echo "")

    if [ -z "$service_dir" ] || [ ! -d "$service_dir" ]; then
        echo "Error: Could not determine working directory for $service" >&2
        return 1
    fi

    echo "Starting local service $service from $service_dir..."

    # This is a placeholder - actual implementation depends on service.yml format.
    # Stub left in place for the eventual local-process start path; until that
    # exists, it just signals "not implemented".
    echo "Note: Local service start requires service.yml configuration"
    return 1
}

# Stop local service
# Usage: _stop_local_service SERVICE_NAME
_stop_local_service() {
    local service="$1"

    # Get PID file
    local pid_file
    if command -v get_pid_file &>/dev/null; then
        pid_file=$(get_pid_file "$service")
    else
        pid_file="/tmp/pids/${service}.pid"
    fi

    if [ ! -f "$pid_file" ]; then
        echo "Warning: No PID file found for $service" >&2
        return 1
    fi

    local pid
    pid=$(cat "$pid_file" 2>/dev/null || echo "")

    if [ -z "$pid" ]; then
        echo "Warning: No PID found in $pid_file" >&2
        return 1
    fi

    # Import process helpers if available
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$script_dir/process.sh" ]; then
        # shellcheck source=lib/utils/process.sh
        source "$script_dir/process.sh" 2>/dev/null || true
    fi

    echo "Stopping local service $service (PID: $pid)..."

    if command -v kill_process_tree &>/dev/null; then
        kill_process_tree "$pid"
        rm -f "$pid_file"
        return $?
    else
        kill -TERM "$pid" 2>/dev/null || true
        sleep 1
        kill -9 "$pid" 2>/dev/null || true
        rm -f "$pid_file"
        return 0
    fi
}

# Export functions for use in subshells
export -f detect_service_type
export -f is_docker_service
export -f is_local_service
export -f is_remote_service
export -f is_service_running_local
export -f is_service_running_remote
export -f is_service_running
export -f get_service_port
export -f get_service_pid_file
export -f get_service_working_dir
export -f start_service
export -f stop_service
export -f restart_service
