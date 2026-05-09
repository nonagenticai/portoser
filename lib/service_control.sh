#!/usr/bin/env bash
# Smart service control - registry-aware start/stop operations

set -euo pipefail

# Source security validation library. Resolve via this file's own directory
# so we don't depend on the caller having $SCRIPT_DIR set (broken under set -u).
_SERVICE_CONTROL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_SERVICE_CONTROL_LIB_DIR/utils/security_validation.sh" ]; then
    # shellcheck source=lib/utils/security_validation.sh
    source "$_SERVICE_CONTROL_LIB_DIR/utils/security_validation.sh"
fi
unset _SERVICE_CONTROL_LIB_DIR

# Note: All required libraries are sourced by the main portoser script
# (registry.sh, docker.sh, local.sh, native.sh, health.sh)

# Ensure docker network exists on a machine
# Args:
#   $1: MACHINE - Machine name
ensure_docker_network() {
    local machine=$1
    local network_name="workflow-system-network"

    # Check if this is local or remote machine. The literal "local" is a
    # registry-level alias for "this host"; otherwise we compare against
    # the actual short hostname.
    local _self
    _self=$(hostname -s 2>/dev/null || hostname | cut -d. -f1)
    if [[ "$machine" == "local" ]] || [[ "$machine" == "$_self" ]]; then
        # Local machine — only the exit code matters.
        if docker network inspect "$network_name" >/dev/null 2>&1; then
            echo "✓ Docker network '$network_name' already exists locally"
        else
            echo "Creating docker network '$network_name' on $machine..."
            local create_output
            if create_output=$(docker network create "$network_name" 2>&1); then
                echo "✓ Created docker network '$network_name'"
            else
                echo "Error: Failed to create docker network '$network_name'" >&2
                echo "Docker output: $create_output" >&2
                return 1
            fi
        fi
    else
        # Remote machine
        local ssh_user
        ssh_user=$(get_machine_ssh_user "$machine")
        local ssh_host
        ssh_host=$(get_ssh_host "$machine")

        if [[ -z "$ssh_host" ]]; then
            echo "Error: Could not determine SSH host for machine '$machine'" >&2
            return 1
        fi

        # Security: Validate network name and SSH host
        if ! validate_safe_string "$network_name" "network_name"; then
            return 1
        fi

        if ! validate_ssh_host "$ssh_user@$ssh_host" "ssh_host"; then
            return 1
        fi

        # Check if network exists on remote machine.
        # Security: Use bash -c with positional parameters to safely pass network name.
        echo "Checking docker network on $machine ($ssh_host)..."
        if ssh -o ConnectTimeout=5 -o BatchMode=yes "$ssh_user@$ssh_host" -- \
            bash -c 'docker network inspect "$1"' _ "$network_name" >/dev/null 2>&1; then
            echo "✓ Docker network '$network_name' already exists on $machine"
        else
            echo "Creating docker network '$network_name' on $machine..."
            local create_output
            local create_exit
            # Security: Use bash -c with positional parameters to safely pass network name
            create_output=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$ssh_user@$ssh_host" -- \
                bash -c 'docker network create "$1"' _ "$network_name" 2>&1)
            create_exit=$?

            if [[ $create_exit -eq 0 ]]; then
                echo "✓ Created docker network '$network_name' on $machine"
            else
                echo "Error: Failed to create docker network '$network_name' on $machine" >&2
                echo "SSH output: $create_output" >&2
                return 1
            fi
        fi
    fi
}

# Smart start service - automatically determines method from registry
# Args:
#   $1: SERVICE - Service name
smart_start_service() {
    local service=$1

    # Validate service exists
    if ! is_service "$service"; then
        echo "Error: Service '$service' not found in registry" >&2
        return 1
    fi

    # Get service metadata from registry
    local deployment_type
    deployment_type=$(get_service_type "$service")
    local machine
    machine=$(get_service_host "$service")

    if [[ -z "$deployment_type" ]]; then
        echo "Error: Service '$service' has no deployment_type in registry" >&2
        return 1
    fi

    if [[ -z "$machine" ]]; then
        echo "Error: Service '$service' has no current_host in registry" >&2
        return 1
    fi

    # Ensure docker network exists if this is a docker service
    if [[ "$deployment_type" == "docker" ]]; then
        ensure_docker_network "$machine"
    fi

    echo "Starting $service (type: $deployment_type, host: $machine)..."

    # Start dependencies first
    local dependencies
    dependencies=$(get_service_dependencies "$service")
    if [[ -n "$dependencies" ]]; then
        echo "Checking dependencies: $(echo "$dependencies" | tr '\n' ' ')"
        while IFS= read -r dep; do
            dep=$(echo "$dep" | xargs)  # trim whitespace
            if [[ -z "$dep" ]]; then
                continue
            fi
            local dep_status
            dep_status=$(get_service_status "$dep")
            if [[ "$dep_status" != "running" ]]; then
                echo "  Starting dependency: $dep"
                smart_start_service "$dep"
            else
                echo "  Dependency $dep is already running"
            fi
        done <<< "$dependencies"
    fi

    # Start service based on deployment type
    case "$deployment_type" in
        docker)
            docker_start "$service" "$machine"
            ;;
        local)
            local current_machine
            current_machine=$(hostname -s)
            if [[ "$machine" == "$current_machine" ]]; then
                local_start_service "$service"
            else
                remote_start_service "$service" "$machine"
            fi
            ;;
        native)
            native_start_service "$service" "$machine"
            ;;
        *)
            echo "Error: Unknown deployment_type '$deployment_type' for service '$service'" >&2
            return 1
            ;;
    esac

    local result=$?

    if [[ $result -eq 0 ]]; then
        echo "✓ Service '$service' started successfully"

        # Wait a moment and check health
        sleep 2
        local health_url
        health_url=$(get_service_health_url "$service")
        if [[ -n "$health_url" ]]; then
            echo "Checking health..."
            check_service_health "$service" 3 || true
            echo "Health check complete"
        fi
    else
        echo "Error: Failed to start service '$service'" >&2
    fi

    return $result
}

# Smart stop service - automatically determines method from registry
# Args:
#   $1: SERVICE - Service name
#   $2: --force (optional) - Skip dependency checking
smart_stop_service() {
    local service=$1
    local force=false

    # Check for --force flag
    if [[ "$2" == "--force" ]]; then
        force=true
    fi

    # Validate service exists
    if ! is_service "$service"; then
        echo "Error: Service '$service' not found in registry" >&2
        return 1
    fi

    # Get service metadata from registry
    local deployment_type
    deployment_type=$(get_service_type "$service")
    local machine
    machine=$(get_service_host "$service")

    if [[ -z "$deployment_type" ]]; then
        echo "Error: Service '$service' has no deployment_type in registry" >&2
        return 1
    fi

    if [[ -z "$machine" ]]; then
        echo "Error: Service '$service' has no current_host in registry" >&2
        return 1
    fi

    # Check for dependent services unless --force
    # FIXED: Re-enabled after fixing the hanging issue in get_service_dependents
    if [[ "$force" == false ]]; then
        local dependents
        dependents=$(get_service_dependents "$service" 2>/dev/null)
        if [[ -n "$dependents" ]]; then
            echo "Service '$service' has dependent services: $dependents"
            echo "Stopping dependents first..."
            # Convert comma-separated to array
            IFS=',' read -ra dep_array <<< "$dependents"
            for dep in "${dep_array[@]}"; do
                dep=$(echo "$dep" | xargs)  # trim whitespace
                if [[ -z "$dep" ]]; then
                    continue
                fi
                local dep_status
                dep_status=$(get_service_status "$dep")
                if [[ "$dep_status" == "running" ]]; then
                    echo "  Stopping dependent: $dep"
                    smart_stop_service "$dep"
                fi
            done
        fi
    fi

    echo "Stopping $service (type: $deployment_type, host: $machine)..."

    # Use intelligent stop (Toyota method: Go to See → Stop what's actually running)
    case "$deployment_type" in
        docker)
            intelligent_docker_stop "$service" "$machine"
            ;;
        local)
            intelligent_local_stop "$service" "$machine"
            ;;
        native)
            native_stop_service "$service" "$machine"
            ;;
        *)
            echo "Error: Unknown deployment_type '$deployment_type' for service '$service'" >&2
            return 1
            ;;
    esac

    local result=$?

    if [[ $result -eq 0 ]]; then
        echo "✓ Service '$service' stopped successfully"
    else
        echo "Error: Failed to stop service '$service'" >&2
    fi

    return $result
}

# Start all services on a machine, or specific services
# Args:
#   $1: MACHINE - Machine name
#   $@: SERVICES - Optional list of specific services (if empty, starts all)
start_machine_services() {
    local machine=$1
    shift
    local specific_services=("$@")

    # Validate machine exists
    if ! is_machine "$machine"; then
        echo "Error: Machine '$machine' not found in registry" >&2
        return 1
    fi

    # Ensure docker network exists on this machine
    ensure_docker_network "$machine"

    # Get all services on this machine
    local all_services
    all_services=$(get_services_on_machine "$machine")

    if [[ -z "$all_services" ]]; then
        echo "No services found on machine '$machine'"
        return 0
    fi

    # Determine which services to start
    local services_to_start
    if [[ ${#specific_services[@]} -gt 0 ]]; then
        # Start specific services
        services_to_start=("${specific_services[@]}")
        echo "Starting specific services on $machine: ${services_to_start[*]}"
    else
        # Start all services - convert comma-separated to array
        IFS=',' read -ra services_to_start <<< "$all_services"
        echo "Starting all services on $machine: ${services_to_start[*]}"
    fi

    # Start each service
    local failed=0
    for service in "${services_to_start[@]}"; do
        service=$(echo "$service" | xargs)  # trim whitespace

        # Skip if service is not on this machine (when specific services provided)
        if [[ ${#specific_services[@]} -gt 0 ]]; then
            local service_machine
            service_machine=$(get_service_host "$service")
            if [[ "$service_machine" != "$machine" ]]; then
                echo "Warning: Service '$service' is not deployed on '$machine' (deployed on '$service_machine')" >&2
                continue
            fi
        fi

        echo ""
        if ! smart_start_service "$service"; then
            failed=$((failed + 1))
        fi
    done

    echo ""
    echo "================================="
    if [[ $failed -eq 0 ]]; then
        echo "✓ All services started successfully on $machine"
        return 0
    else
        echo "✗ $failed service(s) failed to start on $machine" >&2
        return 1
    fi
}

# Stop all services on a machine, or specific services
# Args:
#   $1: MACHINE - Machine name
#   $2: --force (optional) - Skip dependency checking
#   $@: SERVICES - Optional list of specific services (if empty, stops all)
stop_machine_services() {
    local machine=$1
    shift
    local force=false
    local specific_services=()

    # Check for --force flag
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--force" ]]; then
            force=true
            shift
        else
            specific_services+=("$1")
            shift
        fi
    done

    # Validate machine exists
    if ! is_machine "$machine"; then
        echo "Error: Machine '$machine' not found in registry" >&2
        return 1
    fi

    # Get all services on this machine
    local all_services
    all_services=$(get_services_on_machine "$machine")

    if [[ -z "$all_services" ]]; then
        echo "No services found on machine '$machine'"
        return 0
    fi

    # Determine which services to stop
    local services_to_stop
    if [[ ${#specific_services[@]} -gt 0 ]]; then
        # Stop specific services
        services_to_stop=("${specific_services[@]}")
        echo "Stopping specific services on $machine: ${services_to_stop[*]}"
    else
        # Stop all services - convert comma-separated to array
        IFS=',' read -ra services_to_stop <<< "$all_services"
        echo "Stopping all services on $machine: ${services_to_stop[*]}"
    fi

    # Stop each service (in reverse order for dependencies)
    local failed=0
    # Reverse array using bash-compatible method
    local reversed_services=()
    for ((i=${#services_to_stop[@]}-1; i>=0; i--)); do
        reversed_services+=("${services_to_stop[i]}")
    done
    local total=${#reversed_services[@]}
    local current=0

    for service in "${reversed_services[@]}"; do
        service=$(echo "$service" | xargs)  # trim whitespace

        current=$((current + 1))

        # Progress indicator
        echo ""
        print_color "$BLUE" "[$current/$total] Stopping $service..."

        local stop_rc=0
        if [[ "$force" == true ]]; then
            smart_stop_service "$service" --force || stop_rc=$?
        else
            smart_stop_service "$service" || stop_rc=$?
        fi

        if [[ $stop_rc -ne 0 ]]; then
            failed=$((failed + 1))
        fi
    done

    echo ""
    echo "================================="
    if [[ $failed -eq 0 ]]; then
        echo "✓ All services stopped successfully on $machine"
        return 0
    else
        echo "✗ $failed service(s) failed to stop on $machine" >&2
        return 1
    fi
}

# Get service status (wrapper for health.sh)
# Args:
#   $1: SERVICE - Service name
# Returns: "running", "stopped", or "unknown"
get_service_status() {
    local service=$1

    # Use existing health check function
    if declare -f check_service_running &> /dev/null; then
        if check_service_running "$service" &> /dev/null; then
            echo "running"
        else
            echo "stopped"
        fi
    else
        # Fallback - check by deployment type
        local deployment_type
        deployment_type=$(get_service_type "$service")
        local machine
        machine=$(get_service_host "$service")

        case "$deployment_type" in
            docker)
                if check_docker_container_running "$machine" "$service" &> /dev/null; then
                    echo "running"
                else
                    echo "stopped"
                fi
                ;;
            local)
                if check_local_service_running "$machine" "$service" &> /dev/null; then
                    echo "running"
                else
                    echo "stopped"
                fi
                ;;
            native)
                native_status_service "$service" "$machine"
                ;;
            *)
                echo "unknown"
                ;;
        esac
    fi

    # Always return 0 (success) since we've provided a status
    return 0
}

# Get list of services that depend on this service
# Args:
#   $1: SERVICE - Service name
# Returns: Comma-separated list of services
get_service_dependents() {
    local service=$1
    local dependents=()

    # FIXED: Use optimized approach - check service.yml files directly
    # instead of looping with get_service_dependencies (which was causing hangs)

    # Find all service directories
    local service_dir="${PORTOSER_ROOT}/services"
    if [ ! -d "$service_dir" ]; then
        return 0
    fi

    # Check each service's service.yml for dependencies
    for svc_path in "$service_dir"/*; do
        if [ ! -d "$svc_path" ]; then
            continue
        fi

        local svc_name
        svc_name=$(basename "$svc_path")
        local svc_file="$svc_path/service.yml"

        if [ ! -f "$svc_file" ]; then
            continue
        fi

        # Use single yq query to check if this service depends on our target
        local has_dependency
        has_dependency=$(yq eval ".dependencies[]? | select(. == \"$service\")" "$svc_file" 2>/dev/null)

        if [ -n "$has_dependency" ]; then
            dependents+=("$svc_name")
        fi
    done

    # Return comma-separated list - use bash-compatible method
    if [[ ${#dependents[@]} -gt 0 ]]; then
        local IFS=','
        echo "${dependents[*]}"
    fi
}

# Get list of services on a machine
# Args:
#   $1: MACHINE - Machine name
# Returns: Comma-separated list of services
get_services_on_machine() {
    local machine=$1

    # Security: Validate machine name
    if ! validate_safe_string "$machine" "machine"; then
        return 1
    fi

    # FIXED: Use SINGLE yq query - no loops! (matches working compose.sh pattern)
    # The old version called get_service_host in a loop which caused hangs
    if [ -z "$CADDY_REGISTRY_PATH" ] || [ ! -f "$CADDY_REGISTRY_PATH" ]; then
        return 1
    fi

    # One yq call to get all services on this machine
    # Security: Machine name is validated above, safe to use in yq query
    local services
    services=$(yq eval ".services | to_entries | .[] | select(.value.current_host == \"$machine\") | .key" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    # Convert newline-separated to comma-separated
    if [ -n "$services" ]; then
        echo "$services" | tr '\n' ',' | sed 's/,$//'
    fi
}
