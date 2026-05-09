#!/usr/bin/env bash
# registry.sh - Functions for reading and updating Caddy registry.yml

set -euo pipefail

# Cache for SSH hostnames (avoids repeated connectivity tests)
declare -A SSH_HOST_CACHE

# Get the IP address for a machine
# Usage: get_machine_ip MACHINE_NAME
get_machine_ip() {
    local machine="$1"

    if [ -z "$machine" ]; then
        echo "Error: Machine name required" >&2
        return 1
    fi

    if [ ! -f "$CADDY_REGISTRY_PATH" ]; then
        echo "Error: Registry file not found: $CADDY_REGISTRY_PATH" >&2
        return 1
    fi

    local ip
    ip=$(yq eval ".hosts.$machine.ip" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ "$ip" = "null" ] || [ -z "$ip" ]; then
        echo "Error: Machine '$machine' not found in registry" >&2
        return 1
    fi

    echo "$ip"
}

# Get the SSH host for a machine (tries .local first, falls back to IP)
# Usage: get_ssh_host MACHINE_NAME
#
# Cross-platform SSH host resolution:
# - macOS: .local (mDNS/Bonjour) usually works best
# - Linux: IP address often more reliable
# - Windows: IP address recommended
#
# This function tries both and returns the first one that works.
# Results are cached for the duration of the command execution.
get_ssh_host() {
    local machine="$1"

    if [ -z "$machine" ]; then
        echo "Error: Machine name required" >&2
        return 1
    fi

    # Check cache first
    if [ "${SSH_HOST_CACHE[$machine]+_}" ]; then
        echo "${SSH_HOST_CACHE[$machine]}"
        return 0
    fi

    # Check if registry specifies a preferred SSH method
    local ssh_hostname
    ssh_hostname=$(yq eval ".hosts.$machine.ssh_hostname" "$CADDY_REGISTRY_PATH" 2>/dev/null)
    if [ -n "$ssh_hostname" ] && [ "$ssh_hostname" != "null" ]; then
        SSH_HOST_CACHE[$machine]="$ssh_hostname"
        echo "$ssh_hostname"
        return 0
    fi

    # Get IP address (will need this as fallback)
    local machine_ip
    machine_ip=$(get_machine_ip "$machine")
    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")

    if [ -z "$machine_ip" ] || [ -z "$ssh_user" ]; then
        echo "Error: Could not get machine info for '$machine'" >&2
        return 1
    fi

    # Try .local hostname first (fast timeout)
    # BatchMode=yes ensures non-interactive (host key must be in known_hosts)
    local local_hostname="${machine}.local"
    if ssh -o ConnectTimeout=1 -o ConnectionAttempts=1 -o BatchMode=yes \
        "$ssh_user@$local_hostname" "exit 0" >/dev/null 2>&1; then
        [ "$DEBUG" = "1" ] && echo "Debug: Using .local hostname for $machine" >&2
        SSH_HOST_CACHE[$machine]="$local_hostname"
        echo "$local_hostname"
        return 0
    fi

    # Fall back to IP address
    [ "$DEBUG" = "1" ] && echo "Debug: Using IP address for $machine (.local failed)" >&2
    SSH_HOST_CACHE[$machine]="$machine_ip"
    echo "$machine_ip"
}

# Get the Docker context for a machine
# Usage: get_machine_context MACHINE_NAME
get_machine_context() {
    local machine="$1"

    if [ -z "$machine" ]; then
        echo "Error: Machine name required" >&2
        return 1
    fi

    local context
    context=$(yq eval ".hosts.$machine.context" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    # Default to ctx-${machine} when not explicitly set
    if [ "$context" = "null" ] || [ -z "$context" ]; then
        echo "ctx-${machine}"
    else
        echo "$context"
    fi
}

# Get the architecture for a machine (from registry or inferred)
# Usage: get_machine_arch MACHINE_NAME
get_machine_arch() {
    local machine="$1"

    if [ -z "$machine" ]; then
        echo "Error: Machine name required" >&2
        return 1
    fi

    if [ ! -f "$CADDY_REGISTRY_PATH" ]; then
        echo "Error: Registry file not found: $CADDY_REGISTRY_PATH" >&2
        return 1
    fi

    local arch
    arch=$(yq eval ".hosts.$machine.arch" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    # Normalize and infer architecture if not set in registry
    if [ "$arch" = "null" ] || [ -z "$arch" ]; then
        if [[ "$machine" =~ ^m ]]; then
            arch="darwin/arm64"
        else
            arch="linux/arm64"
        fi
    fi

    # Allow legacy values without OS component
    if [[ "$arch" != *"/"* ]]; then
        if [[ "$arch" =~ apple|darwin ]]; then
            arch="darwin/arm64"
        elif [[ "$arch" =~ arm64 ]]; then
            arch="linux/arm64"
        else
            arch="linux/amd64"
        fi
    fi

    echo "$arch"
}

# Get desired platform for a service on a target machine
# Usage: get_service_platform SERVICE_NAME TARGET_MACHINE
get_service_platform() {
    local service="$1"
    local machine="$2"

    if [ -z "$service" ] || [ -z "$machine" ]; then
        echo "Error: Service name and machine required" >&2
        return 1
    fi

    local platform
    platform=$(yq eval ".services.$service.platform" "$CADDY_REGISTRY_PATH" 2>/dev/null)
    if [ -z "$platform" ] || [ "$platform" = "null" ]; then
        local arch
        arch=$(get_machine_arch "$machine" 2>/dev/null || echo "")
        if [[ "$arch" =~ "/" ]]; then
            platform="$arch"
        elif [[ "$arch" =~ arm64 ]]; then
            platform="linux/arm64"
        else
            platform="linux/amd64"
        fi
    fi

    echo "$platform"
}

# Get target image tag for a service on a machine
# Usage: get_service_target_tag SERVICE_NAME TARGET_MACHINE
get_service_target_tag() {
    local service="$1"
    local machine="$2"

    if [ -z "$service" ] || [ -z "$machine" ]; then
        echo "Error: Service name and machine required" >&2
        return 1
    fi

    local tag
    tag=$(yq eval ".services.$service.target_tag" "$CADDY_REGISTRY_PATH" 2>/dev/null)
    if [ -z "$tag" ] || [ "$tag" = "null" ]; then
        tag=$(yq eval ".services.$service.tag" "$CADDY_REGISTRY_PATH" 2>/dev/null)
    fi
    if [ -z "$tag" ] || [ "$tag" = "null" ]; then
        tag="${machine}-latest"
    fi

    echo "$tag"
}

# Get the current host for a service
# Usage: get_service_host SERVICE_NAME
get_service_host() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    if [ -z "$CADDY_REGISTRY_PATH" ] || [ ! -f "$CADDY_REGISTRY_PATH" ]; then
        echo "Error: Registry file not found at: $CADDY_REGISTRY_PATH" >&2
        return 1
    fi

    local host
    host=$(yq eval ".services.$service.current_host" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ "$host" = "null" ] || [ -z "$host" ]; then
        echo "Error: Service '$service' not found in registry" >&2
        return 1
    fi

    echo "$host"
}

# Get the exposed port for a service
# Usage: get_service_port SERVICE_NAME
get_service_port() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    # First check if port is explicitly defined in registry
    local port
    port=$(yq eval ".services.$service.port" "$CADDY_REGISTRY_PATH" 2>/dev/null)
    if [ -n "$port" ] && [ "$port" != "null" ]; then
        echo "$port"
        return 0
    fi

    # Otherwise read from service.yml or docker-compose.yml
    port=$(get_service_port_from_files "$service")
    if [ -n "$port" ] && [ "$port" != "null" ]; then
        echo "$port"
        return 0
    fi

    return 1
}

# Get the deployment type for a service (docker or native)
# Usage: get_service_type SERVICE_NAME
get_service_type() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    local type
    type=$(yq eval ".services.$service.deployment_type" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ "$type" = "null" ] || [ -z "$type" ]; then
        # Default to docker if not specified
        echo "docker"
    else
        echo "$type"
    fi
}

# Get the docker compose file for a service
# Usage: get_service_compose_file SERVICE_NAME
get_service_compose_file() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    # Read from new minimal registry (uses docker_compose field)
    local compose_file
    compose_file=$(yq eval ".services.$service.docker_compose" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ "$compose_file" = "null" ] || [ -z "$compose_file" ]; then
        # Fallback: return relative path
        echo "docker-compose.yml"
    else
        echo "$compose_file"
    fi
}

# Get the service directory path
# Usage: get_service_directory SERVICE_NAME
get_service_directory() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    # Get the host this service runs on
    local host
    if ! host=$(get_service_host "$service" 2>/dev/null) || [ -z "$host" ]; then
        # Fallback to SERVICES_ROOT if we can't determine host
        echo "$SERVICES_ROOT/$service"
        return 0
    fi

    # Get the base path for this host
    local host_path
    host_path=$(yq eval ".hosts.$host.path" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    # Use host path if available, otherwise fallback to SERVICES_ROOT
    local base_path="${host_path:-$SERVICES_ROOT}"

    # Check for docker_compose or service_file to determine directory
    local docker_compose
    docker_compose=$(yq eval ".services.$service.docker_compose" "$CADDY_REGISTRY_PATH" 2>/dev/null)
    local service_file
    service_file=$(yq eval ".services.$service.service_file" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ "$docker_compose" != "null" ] && [ -n "$docker_compose" ]; then
        # Extract directory from docker_compose path
        echo "$base_path$(dirname "$docker_compose")"
    elif [ "$service_file" != "null" ] && [ -n "$service_file" ]; then
        # Extract directory from service_file path
        echo "$base_path$(dirname "$service_file")"
    else
        # Default to service name
        echo "$base_path/$service"
    fi
}

# Get the health check URL for a service
# Usage: get_service_health_url SERVICE_NAME
get_service_health_url() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    local health_url
    health_url=$(yq eval ".services.$service.healthcheck_url" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ "$health_url" = "null" ] || [ -z "$health_url" ]; then
        # Try to construct from service hostname
        local host
        host=$(get_service_host "$service")
        local port
        port=$(get_service_port "$service")
        local ip
        if ip=$(get_machine_ip "$host"); then
            echo "http://$ip:$port/health"
        else
            return 1
        fi
    else
        echo "$health_url"
    fi
}

# Get the service hostname (for Caddy)
# Usage: get_service_hostname SERVICE_NAME
get_service_hostname() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    local hostname
    hostname=$(yq eval ".services.$service.hostname" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ "$hostname" = "null" ] || [ -z "$hostname" ]; then
        # Default to service_name.internal
        echo "$service.internal"
    else
        echo "$hostname"
    fi
}

# Update service host in registry
# Usage: update_service_host SERVICE_NAME NEW_HOST
update_service_host() {
    local service="$1"
    local new_host="$2"

    if [ -z "$service" ] || [ -z "$new_host" ]; then
        echo "Error: Service name and new host required" >&2
        return 1
    fi

    # Verify new host exists
    if ! get_machine_ip "$new_host" > /dev/null 2>&1; then
        echo "Error: Machine '$new_host' not found in registry" >&2
        return 1
    fi

    # Update the registry
    if yq eval ".services.$service.current_host = \"$new_host\"" -i "$CADDY_REGISTRY_PATH"; then
        echo "✓ Updated service '$service' host to '$new_host' in registry"
        return 0
    fi
    echo "Error: Failed to update registry" >&2
    return 1
}

# Update service health URL in registry
# Usage: update_service_health_url SERVICE_NAME NEW_URL
update_service_health_url() {
    local service="$1"
    local new_url="$2"

    if [ -z "$service" ] || [ -z "$new_url" ]; then
        echo "Error: Service name and new URL required" >&2
        return 1
    fi

    if yq eval ".services.$service.healthcheck_url = \"$new_url\"" -i "$CADDY_REGISTRY_PATH"; then
        echo "✓ Updated service '$service' health URL to '$new_url' in registry"
        return 0
    fi
    echo "Error: Failed to update registry" >&2
    return 1
}

# List all services in registry
# Usage: list_services
list_services() {
    if [ ! -f "$CADDY_REGISTRY_PATH" ]; then
        echo "Error: Registry file not found: $CADDY_REGISTRY_PATH" >&2
        return 1
    fi

    yq eval '.services | keys | .[]' "$CADDY_REGISTRY_PATH"
}

# List all machines in registry
# Usage: list_machines
list_machines() {
    if [ ! -f "$CADDY_REGISTRY_PATH" ]; then
        echo "Error: Registry file not found: $CADDY_REGISTRY_PATH" >&2
        return 1
    fi

    yq eval '.hosts | keys | .[]' "$CADDY_REGISTRY_PATH"
}

# Get service information as JSON
# Usage: get_service_info SERVICE_NAME
get_service_info() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    yq eval ".services.$service" "$CADDY_REGISTRY_PATH" -o=json
}

# Get machine information as JSON
# Usage: get_machine_info MACHINE_NAME
get_machine_info() {
    local machine="$1"

    if [ -z "$machine" ]; then
        echo "Error: Machine name required" >&2
        return 1
    fi

    yq eval ".hosts.$machine" "$CADDY_REGISTRY_PATH" -o=json
}

# Validate registry file exists and is valid YAML
# Usage: validate_registry
validate_registry() {
    if [ ! -f "$CADDY_REGISTRY_PATH" ]; then
        echo "Error: Registry file not found: $CADDY_REGISTRY_PATH" >&2
        return 1
    fi

    if ! yq eval '.' "$CADDY_REGISTRY_PATH" > /dev/null 2>&1; then
        echo "Error: Invalid YAML in registry file" >&2
        return 1
    fi

    # Check for required top-level keys
    if ! yq eval '.hosts' "$CADDY_REGISTRY_PATH" > /dev/null 2>&1; then
        echo "Error: Registry missing 'hosts' section" >&2
        return 1
    fi

    if ! yq eval '.services' "$CADDY_REGISTRY_PATH" > /dev/null 2>&1; then
        echo "Error: Registry missing 'services' section" >&2
        return 1
    fi

    # Check for port conflicts on same host
    local conflicts=0
    local services
    services=$(yq eval '.services | keys | .[]' "$CADDY_REGISTRY_PATH")
    declare -A host_ports

    while IFS= read -r service; do
        if [ -z "$service" ]; then
            continue
        fi

        local host
        host=$(yq eval ".services.$service.current_host" "$CADDY_REGISTRY_PATH" 2>/dev/null)
        local port
        port=$(yq eval ".services.$service.port" "$CADDY_REGISTRY_PATH" 2>/dev/null)

        if [ "$host" != "null" ] && [ "$port" != "null" ] && [ -n "$host" ] && [ -n "$port" ]; then
            local key="${host}:${port}"
            if [ "${host_ports[$key]+_}" ]; then
                echo "⚠️  Port conflict: Services '$service' and '${host_ports[$key]}' both use port $port on host $host" >&2
                conflicts=$((conflicts + 1))
            else
                host_ports[$key]="$service"
            fi
        fi
    done <<< "$services"

    if [ $conflicts -gt 0 ]; then
        echo "Error: Found $conflicts port conflict(s)" >&2
        return 1
    fi

    echo "✓ Registry file is valid"
    return 0
}

# Check if a name is a valid machine
# Usage: is_machine NAME
is_machine() {
    local name="$1"

    if [ -z "$name" ]; then
        return 1
    fi

    if [ ! -f "$CADDY_REGISTRY_PATH" ]; then
        return 1
    fi

    local result
    result=$(yq eval ".hosts.$name" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ "$result" = "null" ] || [ -z "$result" ]; then
        return 1
    else
        return 0
    fi
}

# Check if a name is a valid service
# Usage: is_service NAME
is_service() {
    local name="$1"

    if [ -z "$name" ]; then
        return 1
    fi

    if [ ! -f "$CADDY_REGISTRY_PATH" ]; then
        return 1
    fi

    local result
    result=$(yq eval ".services.$name" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ "$result" = "null" ] || [ -z "$result" ]; then
        return 1
    else
        return 0
    fi
}

# Get SSH user for a machine
# Usage: get_machine_ssh_user MACHINE_NAME
get_machine_ssh_user() {
    local machine="$1"

    if [ -z "$machine" ]; then
        echo "$USER"  # Default to current user
        return 0
    fi

    local ssh_user
    ssh_user=$(yq eval ".hosts.$machine.ssh_user" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ "$ssh_user" = "null" ] || [ -z "$ssh_user" ]; then
        echo "$USER"  # Default to current user
    else
        echo "$ssh_user"
    fi
}

# Get SSH port for a machine
# Usage: get_machine_ssh_port MACHINE_NAME
get_machine_ssh_port() {
    local machine="$1"

    if [ -z "$machine" ]; then
        echo "22"  # Default port
        return 0
    fi

    local ssh_port
    ssh_port=$(yq eval ".hosts.$machine.ssh_port" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ "$ssh_port" = "null" ] || [ -z "$ssh_port" ]; then
        echo "22"  # Default port
    else
        echo "$ssh_port"
    fi
}

# Get start command for a service
# Usage: get_service_start_command SERVICE_NAME
get_service_start_command() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    # Read from service.yml or docker-compose.yml
    local cmd
    cmd=$(get_start_command_from_files "$service")
    if [ -n "$cmd" ] && [ "$cmd" != "null" ]; then
        echo "$cmd"
        return 0
    fi

    return 1  # No command specified
}

# Get stop command for a service
# Usage: get_service_stop_command SERVICE_NAME
get_service_stop_command() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    # Read from service.yml or docker-compose.yml
    local cmd
    cmd=$(get_stop_command_from_files "$service")
    if [ -n "$cmd" ] && [ "$cmd" != "null" ]; then
        echo "$cmd"
        return 0
    fi

    return 1  # No command specified
}

# Get restart command for a service
# Usage: get_service_restart_command SERVICE_NAME
get_service_restart_command() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    # First try registry
    local cmd
    cmd=$(yq eval ".services.$service.restart_command" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ -n "$cmd" ] && [ "$cmd" != "null" ]; then
        echo "$cmd"
        return 0
    fi

    # Fall back to reading from service.yml or docker-compose.yml
    cmd=$(get_restart_command_from_files "$service")
    if [ -n "$cmd" ] && [ "$cmd" != "null" ]; then
        echo "$cmd"
        return 0
    fi

    return 1  # No command specified
}

# Get working directory for a service
# Usage: get_service_working_dir SERVICE_NAME
get_service_working_dir() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    local registry_dir
    registry_dir=$(yq eval ".services.$service.service_directory" "$CADDY_REGISTRY_PATH" 2>/dev/null)
    local registry_working_dir
    registry_working_dir=$(yq eval ".services.$service.working_dir" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ -n "$registry_working_dir" ] && [ "$registry_working_dir" != "null" ]; then
        echo "$registry_working_dir"
        return 0
    fi

    if [ -n "$registry_dir" ] && [ "$registry_dir" != "null" ]; then
        # Preserve absolute paths verbatim
        if [[ "$registry_dir" = /* ]]; then
            echo "$registry_dir"
        else
            echo "$SERVICES_ROOT/$registry_dir"
        fi
        return 0
    fi

    # Read from service.yml or docker-compose.yml
    local dir
    dir=$(get_working_dir_from_files "$service")
    if [ -n "$dir" ] && [ "$dir" != "null" ]; then
        echo "$dir"
        return 0
    fi

    return 1  # No directory specified
}

# Get Python manager for a service
# Usage: get_service_python_manager SERVICE_NAME
get_service_python_manager() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    local mgr
    mgr=$(yq eval ".services.$service.python_manager" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ "$mgr" = "null" ] || [ -z "$mgr" ]; then
        echo "venv"  # Default to venv
    else
        echo "$mgr"
    fi
}

# Get environment file for a service
# Usage: get_service_env_file SERVICE_NAME
get_service_env_file() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    # Read from service.yml or docker-compose.yml
    local env_file
    env_file=$(get_env_file_from_files "$service")
    if [ -n "$env_file" ] && [ "$env_file" != "null" ]; then
        echo "$env_file"
        return 0
    fi

    return 1  # No env file specified
}

# Get dependencies for a service (returns newline-separated list)
# Usage: get_service_dependencies SERVICE_NAME
#
# Returns the deduplicated union of:
#   1. depends_on entries in the service's compose / service.yml file
#      (same-host deps; the docker-compose runtime cares about these too).
#   2. .services.<name>.dependencies in the registry (cross-host or logical
#      deps the compose file can't express because the upstream lives on a
#      different machine).
# Either source can be empty.
get_service_dependencies() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    local file_deps
    file_deps=$(get_dependencies_from_files "$service" 2>/dev/null)

    local registry_deps
    registry_deps=$(yq eval ".services.${service}.dependencies[]" "$CADDY_REGISTRY_PATH" 2>/dev/null)
    if [ "$registry_deps" = "null" ]; then
        registry_deps=""
    fi

    {
        if [ -n "$file_deps" ] && [ "$file_deps" != "null" ]; then echo "$file_deps"; fi
        if [ -n "$registry_deps" ]; then echo "$registry_deps"; fi
    } | awk 'NF && !seen[$0]++'
}

# Get healthcheck command for a service
# Usage: get_service_healthcheck_command SERVICE_NAME
get_service_healthcheck_command() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    # Read from service.yml or docker-compose.yml
    local cmd
    cmd=$(get_healthcheck_from_files "$service")
    if [ -n "$cmd" ] && [ "$cmd" != "null" ]; then
        echo "$cmd"
        return 0
    fi

    return 1  # No healthcheck command
}

# Get healthcheck interval for a service (in seconds)
# Usage: get_service_healthcheck_interval SERVICE_NAME
get_service_healthcheck_interval() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "5"  # Default
        return 0
    fi

    local interval
    interval=$(yq eval ".services.$service.healthcheck_interval" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ "$interval" = "null" ] || [ -z "$interval" ]; then
        echo "5"  # Default
    else
        echo "$interval"
    fi
}

# Get healthcheck retries for a service
# Usage: get_service_healthcheck_retries SERVICE_NAME
get_service_healthcheck_retries() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "3"  # Default
        return 0
    fi

    local retries
    retries=$(yq eval ".services.$service.healthcheck_retries" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ "$retries" = "null" ] || [ -z "$retries" ]; then
        echo "3"  # Default
    else
        echo "$retries"
    fi
}

# Get Caddy config directory path
# Usage: get_caddy_config_dir
get_caddy_config_dir() {
    local dir
    dir=$(yq eval ".caddy.config_dir" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ "$dir" = "null" ] || [ -z "$dir" ]; then
        echo "${CADDY_CONFIG_DIR:-${HOME}/portoser/caddy}"  # Default
    else
        echo "$dir"
    fi
}

# Get Caddy admin endpoint
# Usage: get_caddy_admin_endpoint
get_caddy_admin_endpoint() {
    local endpoint
    endpoint=$(yq eval ".caddy.admin_endpoint" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ "$endpoint" = "null" ] || [ -z "$endpoint" ]; then
        echo "http://localhost:2019"  # Default
    else
        echo "$endpoint"
    fi
}

# Update service metadata (last_updated timestamp)
# Usage: update_service_metadata SERVICE_NAME
update_service_metadata() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    yq eval -i ".services.$service.last_updated = \"$timestamp\"" "$CADDY_REGISTRY_PATH" 2>/dev/null
}

# Get list of services deployed on a specific machine
# Usage: get_services_on_machine MACHINE_NAME
# Returns: Comma-separated list of service names
get_services_on_machine() {
    local machine="$1"

    if [ -z "$machine" ]; then
        echo "Error: Machine name required" >&2
        return 1
    fi

    local services=()
    local all_services
    all_services=$(yq eval '.services | keys | .[]' "$CADDY_REGISTRY_PATH" 2>/dev/null)

    # Iterate through all services and check current_host
    while IFS= read -r service; do
        if [ -z "$service" ]; then
            continue
        fi
        local host
        host=$(yq eval ".services.$service.current_host" "$CADDY_REGISTRY_PATH" 2>/dev/null)
        if [ "$host" = "$machine" ]; then
            services+=("$service")
        fi
    done <<< "$all_services"

    # Return comma-separated list - use bash-compatible method
    if [ ${#services[@]} -gt 0 ]; then
        local IFS=','
        echo "${services[*]}"
    fi
}

# Get list of services that depend on a specific service
# Usage: get_service_dependents SERVICE_NAME
# Returns: Comma-separated list of service names
get_service_dependents() {
    local target_service="$1"

    if [ -z "$target_service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    local dependents=()
    local all_services
    all_services=$(yq eval '.services | keys | .[]' "$CADDY_REGISTRY_PATH" 2>/dev/null)

    # Iterate through all services and check their dependencies
    while IFS= read -r service; do
        if [ -z "$service" ]; then
            continue
        fi
        local deps
        deps=$(yq eval ".services.$service.dependencies[]" "$CADDY_REGISTRY_PATH" 2>/dev/null)

        # Check if target_service is in this service's dependencies
        while IFS= read -r dep; do
            if [ -z "$dep" ]; then
                continue
            fi
            if [ "$dep" = "$target_service" ]; then
                dependents+=("$service")
                break
            fi
        done <<< "$deps"
    done <<< "$all_services"

    # Return comma-separated list - use bash-compatible method
    if [ ${#dependents[@]} -gt 0 ]; then
        local IFS=','
        echo "${dependents[*]}"
    fi
}
