#!/usr/bin/env bash
# service_file_parser.sh - Parse service.yml files for local/native services

set -euo pipefail

# Get service.yml path for a service from registry
# Usage: get_service_yml_path SERVICE_NAME
get_service_yml_path() {
    local service="$1"
    yq eval ".services.${service}.service_file" "$CADDY_REGISTRY_PATH" 2>/dev/null
}

# Get docker-compose.yml path for a service from registry
# Usage: get_docker_compose_path SERVICE_NAME
get_docker_compose_path() {
    local service="$1"
    yq eval ".services.${service}.docker_compose" "$CADDY_REGISTRY_PATH" 2>/dev/null
}

# Get docker-compose service name (for multi-service compose files)
# Usage: get_docker_service_name SERVICE_NAME
get_docker_service_name() {
    local service="$1"
    local svc_name
    svc_name=$(yq eval ".services.${service}.service_name" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ "$svc_name" = "null" ] || [ -z "$svc_name" ]; then
        # Default to using the service name itself
        echo "$service"
    else
        echo "$svc_name"
    fi
}

# Read value from service.yml (local or remote)
# Usage: read_service_yml SERVICE_NAME FIELD [MACHINE]
read_service_yml() {
    local service="$1"
    local field="$2"
    local machine="${3:-$(get_service_host "$service")}"

    local service_file
    service_file=$(get_service_yml_path "$service")

    if [ "$service_file" = "null" ] || [ -z "$service_file" ]; then
        return 1
    fi

    # Check if local or remote
    local current_machine
    current_machine=$(hostname -s)
    if [ "$machine" = "$current_machine" ] || [ "$machine" = "local" ]; then
        # Local read
        if [ -f "$service_file" ]; then
            yq eval ".${field}" "$service_file" 2>/dev/null
        fi
    else
        # Remote read via SSH - fetch file content and parse locally
        local ssh_user
        ssh_user=$(get_machine_ssh_user "$machine")
        local ssh_host
        ssh_host=$(get_ssh_host "$machine")

        # Fetch remote file and parse locally with yq.
        # -n keeps ssh from consuming the surrounding heredoc/while-read stdin
        # (callers like dependencies/analyzer.sh feed services via `<<<`).
        ssh -n -o ConnectTimeout=5 "$ssh_user@$ssh_host" "cat '$service_file' 2>/dev/null" | \
            yq eval ".${field}" - 2>/dev/null
    fi
}

# Read value from docker-compose.yml
# Usage: read_docker_compose SERVICE_NAME FIELD [SERVICE_NAME_IN_COMPOSE]
read_docker_compose() {
    local service="$1"
    local field="$2"
    local compose_service="${3:-$(get_docker_service_name "$service")}"
    local machine
    machine=$(get_service_host "$service")

    local compose_file
    compose_file=$(get_docker_compose_path "$service")

    if [ "$compose_file" = "null" ] || [ -z "$compose_file" ]; then
        return 1
    fi

    # Check if local or remote
    local current_machine
    current_machine=$(hostname -s)
    if [ "$machine" = "$current_machine" ] || [ "$machine" = "local" ]; then
        # Local read
        if [ -f "$compose_file" ]; then
            yq eval ".services.${compose_service}.${field}" "$compose_file" 2>/dev/null
        fi
    else
        # Remote read via SSH - fetch file content and parse locally
        local ssh_user
        ssh_user=$(get_machine_ssh_user "$machine")
        local ssh_host
        ssh_host=$(get_ssh_host "$machine")

        # Fetch remote file and parse locally with yq. `-n` prevents ssh from
        # eating the parent loop's stdin (see read_service_yml above).
        ssh -n -o ConnectTimeout=5 "$ssh_user@$ssh_host" "cat '$compose_file' 2>/dev/null" | \
            yq eval ".services.${compose_service}.${field}" - 2>/dev/null
    fi
}

# Get service port (works for both service.yml and docker-compose.yml)
# Usage: get_service_port_from_files SERVICE_NAME
get_service_port_from_files() {
    local service="$1"
    local deployment_type
    deployment_type=$(get_service_type "$service")

    case "$deployment_type" in
        docker)
            # Try to get from docker-compose ports
            local ports
            ports=$(read_docker_compose "$service" "ports")
            if [ -n "$ports" ] && [ "$ports" != "null" ]; then
                # Extract first port mapping (e.g., "8080:8080" -> 8080)
                # Remove quotes, extract port after colon, remove comments and spaces
                echo "$ports" | head -1 | sed 's/.*://g' | sed 's/#.*//g' | tr -d ' "'"'"
            fi
            ;;
        local|native)
            # Read from service.yml - try multiple port fields
            local port
            port=$(read_service_yml "$service" "port")
            if [ -z "$port" ] || [ "$port" = "null" ]; then
                # Try ports array (for services like caddy with multiple ports)
                local ports
                ports=$(read_service_yml "$service" "ports")
                if [ -n "$ports" ] && [ "$ports" != "null" ]; then
                    # Extract first port from array: [80, 443, 2019] -> 80
                    port=$(echo "$ports" | sed 's/\[//; s/\]//; s/,.*//; s/ //g')
                fi
            fi
            if [ -z "$port" ] || [ "$port" = "null" ]; then
                # Try http_port
                port=$(read_service_yml "$service" "http_port")
            fi
            if [ -z "$port" ] || [ "$port" = "null" ]; then
                # Try bolt_port (for Neo4j)
                port=$(read_service_yml "$service" "bolt_port")
            fi
            if [ -n "$port" ] && [ "$port" != "null" ]; then
                echo "$port"
            fi
            ;;
    esac
}

# Get start command (works for both service.yml and docker-compose.yml)
# Usage: get_start_command_from_files SERVICE_NAME
get_start_command_from_files() {
    local service="$1"
    local deployment_type
    deployment_type=$(get_service_type "$service")

    case "$deployment_type" in
        docker)
            # Docker uses docker-compose up
            local compose_file
            compose_file=$(get_docker_compose_path "$service")
            local compose_service
            compose_service=$(get_docker_service_name "$service")
            echo "docker compose -f $compose_file up -d $compose_service"
            ;;
        local|native)
            # Read from service.yml
            read_service_yml "$service" "start"
            ;;
    esac
}

# Get stop command
# Usage: get_stop_command_from_files SERVICE_NAME
get_stop_command_from_files() {
    local service="$1"
    local deployment_type
    deployment_type=$(get_service_type "$service")

    case "$deployment_type" in
        docker)
            # Docker uses docker-compose down
            local compose_file
            compose_file=$(get_docker_compose_path "$service")
            local compose_service
            compose_service=$(get_docker_service_name "$service")
            echo "docker compose -f $compose_file stop $compose_service"
            ;;
        local|native)
            # Read from service.yml
            read_service_yml "$service" "stop"
            ;;
    esac
}

# Get restart command
# Usage: get_restart_command_from_files SERVICE_NAME
get_restart_command_from_files() {
    local service="$1"
    local deployment_type
    deployment_type=$(get_service_type "$service")

    case "$deployment_type" in
        docker)
            # Docker uses docker-compose restart
            local compose_file
            compose_file=$(get_docker_compose_path "$service")
            local compose_service
            compose_service=$(get_docker_service_name "$service")
            echo "docker compose -f $compose_file restart $compose_service"
            ;;
        local|native)
            # Read from service.yml
            read_service_yml "$service" "restart"
            ;;
    esac
}

# Get working directory
# Usage: get_working_dir_from_files SERVICE_NAME
get_working_dir_from_files() {
    local service="$1"
    local deployment_type
    deployment_type=$(get_service_type "$service")

    case "$deployment_type" in
        docker)
            # Get directory from docker-compose file path
            local compose_file
            compose_file=$(get_docker_compose_path "$service")
            if [ -n "$compose_file" ] && [ "$compose_file" != "null" ]; then
                dirname "$compose_file"
            fi
            ;;
        local|native)
            read_service_yml "$service" "working_dir"
            ;;
    esac
}

# Get env file
# Usage: get_env_file_from_files SERVICE_NAME
get_env_file_from_files() {
    local service="$1"
    local deployment_type
    deployment_type=$(get_service_type "$service")

    case "$deployment_type" in
        docker)
            # Try to read env_file from docker-compose
            read_docker_compose "$service" "env_file"
            ;;
        local|native)
            read_service_yml "$service" "env_file"
            ;;
    esac
}

# Get dependencies from service.yml
# Usage: get_dependencies_from_files SERVICE_NAME
get_dependencies_from_files() {
    local service="$1"
    local deployment_type
    deployment_type=$(get_service_type "$service")

    case "$deployment_type" in
        docker)
            # Read depends_on from docker-compose
            local compose_service
            compose_service=$(get_docker_service_name "$service")
            # depends_on can be array format (- redis) or object format (redis: {condition: ...})
            # Handle both by checking if it's an array first
            local deps_data
            deps_data=$(read_docker_compose "$service" "depends_on" "$compose_service")
            if [ -n "$deps_data" ] && [ "$deps_data" != "null" ]; then
                # Try array format first (most common)
                echo "$deps_data" | yq eval '.[]' - 2>/dev/null || \
                # If that fails, try object format
                echo "$deps_data" | yq eval 'keys | .[]' - 2>/dev/null
            fi
            ;;
        local|native)
            # Read dependencies from service.yml
            read_service_yml "$service" "dependencies | keys | .[]"
            ;;
    esac
}

# Get healthcheck command from service.yml or docker-compose.yml
# Usage: get_healthcheck_from_files SERVICE_NAME
get_healthcheck_from_files() {
    local service="$1"
    local deployment_type
    deployment_type=$(get_service_type "$service")

    case "$deployment_type" in
        docker)
            # Try to read healthcheck from docker-compose
            local healthcheck
            healthcheck=$(read_docker_compose "$service" "healthcheck.test")
            if [ -n "$healthcheck" ] && [ "$healthcheck" != "null" ]; then
                # Convert Docker healthcheck format to executable command
                # Docker format: ["CMD", "arg1", "arg2", ...] or ["CMD-SHELL", "command"]
                # Remove brackets and quotes, extract command
                healthcheck=$(echo "$healthcheck" | sed 's/^\[//; s/\]$//; s/"//g')

                # Check if it starts with CMD-SHELL or CMD
                if echo "$healthcheck" | grep -q "^CMD-SHELL,"; then
                    # CMD-SHELL: Just take everything after "CMD-SHELL, "
                    local trimmed="${healthcheck#CMD-SHELL,}"
                    # Strip leading whitespace (sed had `*` to handle 0+ spaces)
                    trimmed="${trimmed#"${trimmed%%[! ]*}"}"
                    echo "$trimmed"
                elif echo "$healthcheck" | grep -q "^CMD,"; then
                    # CMD: Join all arguments after CMD with spaces
                    echo "$healthcheck" | sed 's/^CMD, *//' | sed 's/, */ /g'
                else
                    # Unknown format, return as-is
                    echo "$healthcheck"
                fi
            fi
            ;;
        local|native)
            # Read from service.yml
            read_service_yml "$service" "healthcheck"
            ;;
    esac
}
