#!/usr/bin/env bash
# lib/utils/docker_compose.sh - Docker compose wrapper utilities
#
# This library provides centralized Docker compose operations, eliminating
# duplication of common docker-compose patterns across scripts.
#
# Functions:
#   - compose_command(compose_file, args...) - Execute docker-compose command
#   - compose_up(compose_file, service) - Start service(s)
#   - compose_down(compose_file, service) - Stop service(s)
#   - compose_logs(compose_file, service, lines) - Get service logs
#   - compose_ps(compose_file) - List running services
#   - compose_exec(compose_file, service, command) - Execute command in container
#   - compose_build(compose_file, service) - Build service image
#   - is_compose_file_valid(compose_file) - Validate compose file
#

set -euo pipefail

################################################################################
# Helper Functions
################################################################################

# Get the docker compose command to use (docker compose or docker-compose)
# Usage: get_compose_command
# Returns: "docker compose" or "docker-compose"
get_compose_command() {
    # Try new format first (Docker 20.10+)
    if docker compose version > /dev/null 2>&1; then
        echo "docker compose"
        return 0
    fi

    # Fall back to old format
    if docker-compose version > /dev/null 2>&1; then
        echo "docker-compose"
        return 0
    fi

    echo "Error: docker-compose or docker not found" >&2
    return 1
}

# Validate a compose file exists and is readable
# Usage: is_compose_file_valid COMPOSE_FILE
# Returns: 0 if valid, 1 if not
is_compose_file_valid() {
    local compose_file="$1"

    if [ -z "$compose_file" ]; then
        echo "Error: Compose file path required" >&2
        return 1
    fi

    if [ ! -f "$compose_file" ]; then
        echo "Error: Compose file not found: $compose_file" >&2
        return 1
    fi

    if [ ! -r "$compose_file" ]; then
        echo "Error: Compose file not readable: $compose_file" >&2
        return 1
    fi

    return 0
}

# Resolve compose file to absolute path
# Usage: resolve_compose_path COMPOSE_FILE
# Returns: Absolute path on stdout
resolve_compose_path() {
    local compose_file="$1"

    if [ -z "$compose_file" ]; then
        echo "Error: Compose file path required" >&2
        return 1
    fi

    # If relative path, make absolute
    if [[ "$compose_file" != /* ]]; then
        compose_file="$(pwd)/$compose_file"
    fi

    echo "$compose_file"
}

################################################################################
# Core Compose Operations
################################################################################

# Execute a docker-compose command
# Usage: compose_command COMPOSE_FILE [ARGS...]
# Returns: Command exit code
compose_command() {
    local compose_file="$1"
    shift
    local args=("$@")

    if ! is_compose_file_valid "$compose_file"; then
        return 1
    fi

    compose_file=$(resolve_compose_path "$compose_file")

    local compose_cmd
    compose_cmd=$(get_compose_command) || return 1

    [ "${DEBUG:-0}" = "1" ] && echo "Debug: Running: $compose_cmd -f \"$compose_file\" ${args[*]}" >&2

    $compose_cmd -f "$compose_file" "${args[@]}"
}

################################################################################
# Service Management
################################################################################

# Start service(s) with docker-compose
# Usage: compose_up COMPOSE_FILE [SERVICE_NAME] [OPTIONS]
# Returns: 0 if successful, 1 if failed
compose_up() {
    local compose_file="$1"
    local service="${2:-}"
    shift 2 || shift 1
    local options=("$@")

    if ! is_compose_file_valid "$compose_file"; then
        return 1
    fi

    echo "Starting services from $compose_file..."

    if [ -n "$service" ]; then
        compose_command "$compose_file" up -d "${options[@]}" "$service"
    else
        compose_command "$compose_file" up -d "${options[@]}"
    fi
}

# Stop service(s) with docker-compose
# Usage: compose_down COMPOSE_FILE [SERVICE_NAME] [OPTIONS]
# Returns: 0 if successful, 1 if failed
compose_down() {
    local compose_file="$1"
    local service="${2:-}"
    shift 2 || shift 1
    local options=("$@")

    if ! is_compose_file_valid "$compose_file"; then
        return 1
    fi

    echo "Stopping services from $compose_file..."

    if [ -n "$service" ]; then
        compose_command "$compose_file" down "${options[@]}" "$service"
    else
        compose_command "$compose_file" down "${options[@]}"
    fi
}

# Restart service(s) with docker-compose
# Usage: compose_restart COMPOSE_FILE [SERVICE_NAME]
# Returns: 0 if successful, 1 if failed
compose_restart() {
    local compose_file="$1"
    local service="${2:-}"

    if ! is_compose_file_valid "$compose_file"; then
        return 1
    fi

    echo "Restarting services from $compose_file..."

    if [ -n "$service" ]; then
        compose_command "$compose_file" restart "$service"
    else
        compose_command "$compose_file" restart
    fi
}

# Pause service(s) with docker-compose
# Usage: compose_pause COMPOSE_FILE [SERVICE_NAME]
# Returns: 0 if successful, 1 if failed
compose_pause() {
    local compose_file="$1"
    local service="${2:-}"

    if ! is_compose_file_valid "$compose_file"; then
        return 1
    fi

    echo "Pausing services from $compose_file..."

    if [ -n "$service" ]; then
        compose_command "$compose_file" pause "$service"
    else
        compose_command "$compose_file" pause
    fi
}

# Unpause service(s) with docker-compose
# Usage: compose_unpause COMPOSE_FILE [SERVICE_NAME]
# Returns: 0 if successful, 1 if failed
compose_unpause() {
    local compose_file="$1"
    local service="${2:-}"

    if ! is_compose_file_valid "$compose_file"; then
        return 1
    fi

    echo "Unpausing services from $compose_file..."

    if [ -n "$service" ]; then
        compose_command "$compose_file" unpause "$service"
    else
        compose_command "$compose_file" unpause
    fi
}

################################################################################
# Container Information
################################################################################

# Get service status
# Usage: compose_ps COMPOSE_FILE [SERVICE_NAME]
# Returns: 0 if successful, 1 if failed
compose_ps() {
    local compose_file="$1"
    local service="${2:-}"

    if ! is_compose_file_valid "$compose_file"; then
        return 1
    fi

    if [ -n "$service" ]; then
        compose_command "$compose_file" ps "$service"
    else
        compose_command "$compose_file" ps
    fi
}

# Get service logs
# Usage: compose_logs COMPOSE_FILE [SERVICE_NAME] [NUM_LINES]
# Returns: 0 if successful, 1 if failed
compose_logs() {
    local compose_file="$1"
    local service="${2:-}"
    local lines="${3:-50}"

    if ! is_compose_file_valid "$compose_file"; then
        return 1
    fi

    if [ -n "$service" ]; then
        compose_command "$compose_file" logs --tail "$lines" "$service"
    else
        compose_command "$compose_file" logs --tail "$lines"
    fi
}

# Stream service logs (follow mode)
# Usage: compose_logs_follow COMPOSE_FILE [SERVICE_NAME]
# Returns: 0 if successful, 1 if failed
compose_logs_follow() {
    local compose_file="$1"
    local service="${2:-}"

    if ! is_compose_file_valid "$compose_file"; then
        return 1
    fi

    if [ -n "$service" ]; then
        compose_command "$compose_file" logs -f "$service"
    else
        compose_command "$compose_file" logs -f
    fi
}

# Check if service is running
# Usage: is_service_running COMPOSE_FILE SERVICE_NAME
# Returns: 0 if running, 1 if not
is_service_running() {
    local compose_file="$1"
    local service="$2"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    if ! is_compose_file_valid "$compose_file"; then
        return 1
    fi

    # Check if container is running
    if compose_command "$compose_file" ps "$service" 2>/dev/null | grep -q "Up"; then
        return 0
    fi

    return 1
}

################################################################################
# Build and Configuration
################################################################################

# Build service image
# Usage: compose_build COMPOSE_FILE [SERVICE_NAME] [OPTIONS]
# Returns: 0 if successful, 1 if failed
compose_build() {
    local compose_file="$1"
    local service="${2:-}"
    shift 2 || shift 1
    local options=("$@")

    if ! is_compose_file_valid "$compose_file"; then
        return 1
    fi

    echo "Building services from $compose_file..."

    if [ -n "$service" ]; then
        compose_command "$compose_file" build "${options[@]}" "$service"
    else
        compose_command "$compose_file" build "${options[@]}"
    fi
}

# Validate compose file syntax
# Usage: compose_validate COMPOSE_FILE
# Returns: 0 if valid, 1 if invalid
compose_validate() {
    local compose_file="$1"

    if ! is_compose_file_valid "$compose_file"; then
        return 1
    fi

    if compose_command "$compose_file" config > /dev/null 2>&1; then
        echo "✓ Compose file is valid: $compose_file"
        return 0
    else
        echo "✗ Compose file is invalid: $compose_file" >&2
        return 1
    fi
}

# Get compose file configuration (resolved)
# Usage: compose_config COMPOSE_FILE
# Returns: Resolved configuration on stdout
compose_config() {
    local compose_file="$1"

    if ! is_compose_file_valid "$compose_file"; then
        return 1
    fi

    compose_command "$compose_file" config
}

################################################################################
# Container Execution
################################################################################

# Execute command in running container
# Usage: compose_exec COMPOSE_FILE SERVICE COMMAND [ARGS...]
# Returns: Command exit code
compose_exec() {
    local compose_file="$1"
    local service="$2"
    shift 2
    local command=("$@")

    if [ -z "$service" ] || [ ${#command[@]} -eq 0 ]; then
        echo "Error: Service and command required" >&2
        return 1
    fi

    if ! is_compose_file_valid "$compose_file"; then
        return 1
    fi

    compose_command "$compose_file" exec -T "$service" "${command[@]}"
}

# Run command in container (for stopped containers)
# Usage: compose_run COMPOSE_FILE SERVICE COMMAND [ARGS...]
# Returns: Command exit code
compose_run() {
    local compose_file="$1"
    local service="$2"
    shift 2
    local command=("$@")

    if [ -z "$service" ] || [ ${#command[@]} -eq 0 ]; then
        echo "Error: Service and command required" >&2
        return 1
    fi

    if ! is_compose_file_valid "$compose_file"; then
        return 1
    fi

    compose_command "$compose_file" run --rm "$service" "${command[@]}"
}

################################################################################
# Cleanup
################################################################################

# Remove stopped containers and networks
# Usage: compose_cleanup COMPOSE_FILE
# Returns: 0 if successful, 1 if failed
compose_cleanup() {
    local compose_file="$1"

    if ! is_compose_file_valid "$compose_file"; then
        return 1
    fi

    echo "Cleaning up resources from $compose_file..."
    compose_command "$compose_file" down -v
}

# Remove all data (containers, volumes, networks)
# Usage: compose_cleanup_all COMPOSE_FILE
# Returns: 0 if successful, 1 if failed
compose_cleanup_all() {
    local compose_file="$1"

    if ! is_compose_file_valid "$compose_file"; then
        return 1
    fi

    echo "WARNING: Removing all resources from $compose_file (including volumes)..."
    compose_command "$compose_file" down -v
}

# Export functions for use in subshells
export -f get_compose_command
export -f is_compose_file_valid
export -f resolve_compose_path
export -f compose_command
export -f compose_up
export -f compose_down
export -f compose_restart
export -f compose_pause
export -f compose_unpause
export -f compose_ps
export -f compose_logs
export -f compose_logs_follow
export -f is_service_running
export -f compose_build
export -f compose_validate
export -f compose_config
export -f compose_exec
export -f compose_run
export -f compose_cleanup
export -f compose_cleanup_all
