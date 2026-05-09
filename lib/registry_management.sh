#!/usr/bin/env bash
# registry_management.sh - Registry manipulation and management

set -euo pipefail

# Validate registry structure
# Usage: validate_registry
validate_registry() {
    echo "Validating registry.yml..."
    echo ""

    local errors=0

    # Check file exists
    if [ ! -f "$CADDY_REGISTRY_PATH" ]; then
        echo "✗ Registry file not found: $CADDY_REGISTRY_PATH"
        return 1
    fi

    # Check YAML is valid
    if ! yq eval '.' "$CADDY_REGISTRY_PATH" >/dev/null 2>&1; then
        echo "✗ Invalid YAML syntax"
        errors=$((errors + 1))
    else
        echo "✓ Valid YAML syntax"
    fi

    # Check required top-level keys
    local required_keys=("domain" "hosts" "services")
    for key in "${required_keys[@]}"; do
        if [ "$(yq eval "has(\"$key\")" "$CADDY_REGISTRY_PATH")" = "false" ]; then
            echo "✗ Missing required key: $key"
            errors=$((errors + 1))
        else
            echo "✓ Required key present: $key"
        fi
    done

    # Validate each service (minimal schema: only checks current_host and deployment_type)
    echo ""
    echo "Checking services..."
    local services
    services=$(yq eval '.services | keys | .[]' "$CADDY_REGISTRY_PATH")

    while IFS= read -r service; do
        if [ -z "$service" ]; then continue; fi

        local has_host
        has_host=$(yq eval ".services.${service} | has(\"current_host\")" "$CADDY_REGISTRY_PATH")
        local has_deployment_type
        has_deployment_type=$(yq eval ".services.${service} | has(\"deployment_type\")" "$CADDY_REGISTRY_PATH")
        local current_host
        current_host=$(yq eval ".services.${service}.current_host" "$CADDY_REGISTRY_PATH")

        if [ "$has_host" = "false" ]; then
            echo "  ✗ $service: missing 'current_host' field"
            errors=$((errors + 1))
        elif [ "$has_deployment_type" = "false" ]; then
            echo "  ✗ $service: missing 'deployment_type' field"
            errors=$((errors + 1))
        else
            # Check if host exists in hosts
            local host_exists
            host_exists=$(yq eval ".hosts | has(\"$current_host\")" "$CADDY_REGISTRY_PATH")
            if [ "$host_exists" = "false" ]; then
                echo "  ✗ $service: references non-existent host '$current_host'"
                errors=$((errors + 1))
            else
                echo "  ✓ $service"
            fi
        fi
    done <<< "$services"

    echo ""
    if [ $errors -eq 0 ]; then
        echo "✓ Registry validation passed"
        return 0
    else
        echo "✗ Registry validation failed with $errors error(s)"
        return 1
    fi
}

# Validate that service healthcheck URLs match their machine IPs
# Usage: validate_service_ips
# OBSOLETE: Minimal registry schema does not store healthcheck URLs
validate_service_ips() {
    echo "⚠️  OBSOLETE: This command is no longer supported" >&2
    echo "" >&2
    echo "The minimal registry schema does not store healthcheck URLs or ports." >&2
    echo "Health check information is now stored in:" >&2
    echo "  - docker-compose.yml (for Docker services)" >&2
    echo "  - service.yml (for native/local services)" >&2
    echo "" >&2
    echo "Portoser reads health check configuration from service files automatically." >&2
    return 1
}

# Sync all service healthcheck IPs for a machine
# Usage: sync_machine_ips MACHINE_NAME [--dry-run]
# OBSOLETE: Minimal registry schema does not store healthcheck URLs
sync_machine_ips() {
    echo "⚠️  OBSOLETE: This command is no longer supported" >&2
    echo "" >&2
    echo "The minimal registry schema does not store healthcheck URLs or ports." >&2
    echo "Health check information is now stored in:" >&2
    echo "  - docker-compose.yml (for Docker services)" >&2
    echo "  - service.yml (for native/local services)" >&2
    echo "" >&2
    echo "To move a service to a different machine, use:" >&2
    echo "  portoser registry update-service SERVICE_NAME --machine MACHINE" >&2
    return 1
}

# Add a new service to registry
# Usage: add_service SERVICE_NAME --machine MACHINE --type TYPE --compose PATH [OPTIONS]
add_service() {
    if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        cat <<EOF
Usage: portoser registry add-service SERVICE_NAME --machine MACHINE --type TYPE [OPTIONS]

Add a new service to the registry.

Required:
  SERVICE_NAME             Service name (e.g., my_api)
  --machine MACHINE        Target machine (any host key from registry.yml,
                           e.g. host-a, or "local" for the current host)
  --type TYPE              Deployment type (docker, native, local)
  --compose PATH           Path to docker-compose.yml (for docker type)
  --service-file PATH      Path to service.yml (for native/local type)

Optional:
  --service-name NAME      Container name (if compose has multiple services)
  --description DESC       Human-readable description
  --dependencies DEPS      Comma-separated list of dependencies
  --notes TEXT             Additional notes

Examples:
  # Add Docker service
  portoser registry add-service my_api \\
    --machine host-a \\
    --type docker \\
    --compose <services-root>/my_api/docker-compose.yml \\
    --description "My API service"

  # Add native service
  portoser registry add-service neo4j \\
    --machine host-b \\
    --type native \\
    --service-file <services-root>/neo4j/service.yml
EOF
        return 0
    fi

    local service_name="$1"
    shift

    if [ -z "$service_name" ]; then
        echo "Error: Service name required" >&2
        add_service --help
        return 1
    fi

    # Check if service already exists
    local exists
    exists=$(yq eval ".services | has(\"$service_name\")" "$CADDY_REGISTRY_PATH")
    if [ "$exists" = "true" ]; then
        echo "Error: Service '$service_name' already exists in registry" >&2
        echo "Use 'portoser registry update-service $service_name' to modify it" >&2
        return 1
    fi

    # Parse arguments
    local machine=""
    local type=""
    local compose_path=""
    local service_file_path=""
    local container_name=""
    local description=""
    local dependencies=""
    local notes=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --machine)
                machine="$2"
                shift 2
                ;;
            --type)
                type="$2"
                shift 2
                ;;
            --compose|--docker-compose)
                compose_path="$2"
                shift 2
                ;;
            --service-file)
                service_file_path="$2"
                shift 2
                ;;
            --service-name|--container-name)
                container_name="$2"
                shift 2
                ;;
            --description)
                description="$2"
                shift 2
                ;;
            --dependencies)
                dependencies="$2"
                shift 2
                ;;
            --notes)
                notes="$2"
                shift 2
                ;;
            *)
                echo "Error: Unknown option $1" >&2
                return 1
                ;;
        esac
    done

    # Validate required fields
    if [ -z "$machine" ]; then
        echo "Error: --machine is required" >&2
        return 1
    fi

    if [ -z "$type" ]; then
        echo "Error: --type is required (docker, native, or local)" >&2
        return 1
    fi

    # Validate type-specific requirements
    if [ "$type" = "docker" ]; then
        if [ -z "$compose_path" ]; then
            echo "Error: --compose is required for docker deployment type" >&2
            return 1
        fi
    elif [ "$type" = "native" ] || [ "$type" = "local" ]; then
        if [ -z "$service_file_path" ]; then
            echo "Error: --service-file is required for native/local deployment type" >&2
            return 1
        fi
    else
        echo "Error: Invalid type '$type'. Must be docker, native, or local" >&2
        return 1
    fi

    # Validate machine exists
    local machine_exists
    machine_exists=$(yq eval ".hosts | has(\"$machine\")" "$CADDY_REGISTRY_PATH")
    if [ "$machine_exists" = "false" ]; then
        echo "Error: Machine '$machine' not found in registry" >&2
        echo "Available machines:" >&2
        yq eval '.hosts | keys | .[]' "$CADDY_REGISTRY_PATH" | sed 's/^/  /' >&2
        return 1
    fi

    # Get domain for hostname
    local domain
    domain=$(yq eval ".domain" "$CADDY_REGISTRY_PATH")

    echo "Adding service '$service_name' to registry..."

    # Create timestamped backup to avoid race conditions
    local backup_file
    backup_file="${CADDY_REGISTRY_PATH}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$CADDY_REGISTRY_PATH" "$backup_file"

    # Build the minimal service entry
    yq eval ".services.${service_name}.hostname = \"${service_name}.${domain}\"" -i "$CADDY_REGISTRY_PATH"
    yq eval ".services.${service_name}.current_host = \"$machine\"" -i "$CADDY_REGISTRY_PATH"
    yq eval ".services.${service_name}.deployment_type = \"$type\"" -i "$CADDY_REGISTRY_PATH"

    # Add type-specific path
    if [ "$type" = "docker" ] && [ -n "$compose_path" ]; then
        yq eval ".services.${service_name}.docker_compose = \"$compose_path\"" -i "$CADDY_REGISTRY_PATH"
    fi

    if [ "$type" = "native" ] || [ "$type" = "local" ]; then
        if [ -n "$service_file_path" ]; then
            yq eval ".services.${service_name}.service_file = \"$service_file_path\"" -i "$CADDY_REGISTRY_PATH"
        fi
    fi

    # Add optional container name for multi-service compose files
    if [ -n "$container_name" ]; then
        yq eval ".services.${service_name}.service_name = \"$container_name\"" -i "$CADDY_REGISTRY_PATH"
    fi

    # Add optional description
    if [ -n "$description" ]; then
        yq eval ".services.${service_name}.description = \"$description\"" -i "$CADDY_REGISTRY_PATH"
    fi

    # Add optional notes
    if [ -n "$notes" ]; then
        yq eval ".services.${service_name}.notes = \"$notes\"" -i "$CADDY_REGISTRY_PATH"
    fi

    # Handle dependencies as array
    if [ -n "$dependencies" ]; then
        yq eval ".services.${service_name}.dependencies = []" -i "$CADDY_REGISTRY_PATH"
        # Split dependencies by comma (zsh-compatible)
        local dep_list
        dep_list=$(echo "$dependencies" | tr ',' '\n')
        while IFS= read -r dep; do
            dep=$(echo "$dep" | xargs) # trim whitespace
            if [ -n "$dep" ]; then
                yq eval ".services.${service_name}.dependencies += [\"$dep\"]" -i "$CADDY_REGISTRY_PATH"
            fi
        done <<< "$dep_list"
    fi

    # Validate after adding
    if ! validate_registry >/dev/null 2>&1; then
        echo "✗ Validation failed, restoring backup" >&2
        mv "$backup_file" "$CADDY_REGISTRY_PATH"
        return 1
    fi

    rm "$backup_file"

    echo "✓ Service added successfully"
    echo ""
    echo "Service details:"
    show_service "$service_name"

    echo ""
    echo "Next steps:"
    echo "  1. Regenerate Caddyfile: portoser caddy regenerate"
    echo "  2. Deploy service: portoser deploy $machine $service_name"
    echo "  3. Verify routing: curl http://${service_name}.${domain}/health"

    return 0
}

# Update an existing service in registry
# Usage: update_service SERVICE_NAME [OPTIONS]
update_service() {
    if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        cat <<EOF
Usage: portoser registry update-service SERVICE [OPTIONS]

Update properties of an existing service in the registry.

Options:
  --machine MACHINE        Move service to a different machine
  --type TYPE              Change deployment type (docker/native/local)
  --compose PATH           Update docker-compose.yml path
  --service-file PATH      Update service.yml path
  --service-name NAME      Update container/service name
  --description DESC       Update description
  --notes TEXT             Update notes
  --add-dependency SVC     Add a service dependency
  --remove-dependency SVC  Remove a service dependency

Examples:
  portoser registry update-service my_api --machine host-b
  portoser registry update-service my_api --add-dependency postgres
  portoser registry update-service my_api --compose <services-root>/my_api/docker-compose.yml
EOF
        return 0
    fi

    local service_name="$1"
    shift

    # Check if service exists
    local exists
    exists=$(yq eval ".services | has(\"$service_name\")" "$CADDY_REGISTRY_PATH")
    if [ "$exists" = "false" ]; then
        echo "Error: Service '$service_name' not found in registry" >&2
        return 1
    fi

    # Parse arguments
    local updates=0

    # Create timestamped backup to avoid race conditions
    local backup_file
    backup_file="${CADDY_REGISTRY_PATH}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$CADDY_REGISTRY_PATH" "$backup_file"

    echo "Updating service '$service_name'..."

    while [[ $# -gt 0 ]]; do
        case $1 in
            --machine)
                local machine="$2"
                local machine_exists
                machine_exists=$(yq eval ".hosts | has(\"$machine\")" "$CADDY_REGISTRY_PATH")
                if [ "$machine_exists" = "false" ]; then
                    echo "Error: Machine '$machine' not found" >&2
                    mv "$backup_file" "$CADDY_REGISTRY_PATH"
                    return 1
                fi
                yq eval ".services.${service_name}.current_host = \"$machine\"" -i "$CADDY_REGISTRY_PATH"
                echo "  Updated machine: $machine"
                updates=$((updates + 1))
                shift 2
                ;;
            --type)
                yq eval ".services.${service_name}.deployment_type = \"$2\"" -i "$CADDY_REGISTRY_PATH"
                echo "  Updated type: $2"
                updates=$((updates + 1))
                shift 2
                ;;
            --compose|--docker-compose)
                yq eval ".services.${service_name}.docker_compose = \"$2\"" -i "$CADDY_REGISTRY_PATH"
                echo "  Updated docker_compose path: $2"
                updates=$((updates + 1))
                shift 2
                ;;
            --service-file)
                yq eval ".services.${service_name}.service_file = \"$2\"" -i "$CADDY_REGISTRY_PATH"
                echo "  Updated service_file path: $2"
                updates=$((updates + 1))
                shift 2
                ;;
            --service-name|--container-name)
                yq eval ".services.${service_name}.service_name = \"$2\"" -i "$CADDY_REGISTRY_PATH"
                echo "  Updated service_name: $2"
                updates=$((updates + 1))
                shift 2
                ;;
            --description)
                yq eval ".services.${service_name}.description = \"$2\"" -i "$CADDY_REGISTRY_PATH"
                echo "  Updated description"
                updates=$((updates + 1))
                shift 2
                ;;
            --notes)
                yq eval ".services.${service_name}.notes = \"$2\"" -i "$CADDY_REGISTRY_PATH"
                echo "  Updated notes"
                updates=$((updates + 1))
                shift 2
                ;;
            --add-dependency)
                yq eval ".services.${service_name}.dependencies += [\"$2\"]" -i "$CADDY_REGISTRY_PATH"
                echo "  Added dependency: $2"
                updates=$((updates + 1))
                shift 2
                ;;
            --remove-dependency)
                yq eval ".services.${service_name}.dependencies -= [\"$2\"]" -i "$CADDY_REGISTRY_PATH"
                echo "  Removed dependency: $2"
                updates=$((updates + 1))
                shift 2
                ;;
            *)
                echo "Error: Unknown option $1" >&2
                mv "$backup_file" "$CADDY_REGISTRY_PATH"
                return 1
                ;;
        esac
    done

    if [ $updates -eq 0 ]; then
        echo "No updates specified"
        rm "$backup_file"
        return 0
    fi

    # Validate after updating
    if ! validate_registry >/dev/null 2>&1; then
        echo "✗ Validation failed, restoring backup" >&2
        mv "$backup_file" "$CADDY_REGISTRY_PATH"
        return 1
    fi

    rm "$backup_file"

    echo ""
    echo "✓ Service updated successfully ($updates change(s))"
    echo ""
    echo "Updated service details:"
    show_service "$service_name"

    return 0
}

# Move service to different machine
# Usage: move_service SERVICE_NAME --to MACHINE
move_service() {
    local service_name="$1"
    local target_machine=""

    shift

    if [ -z "$service_name" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --to)
                target_machine="$2"
                shift 2
                ;;
            *)
                echo "Error: Unknown option $1" >&2
                return 1
                ;;
        esac
    done

    if [ -z "$target_machine" ]; then
        echo "Error: Target machine required (--to MACHINE)" >&2
        return 1
    fi

    # Check if service exists
    local exists
    exists=$(yq eval ".services | has(\"$service_name\")" "$CADDY_REGISTRY_PATH")
    if [ "$exists" = "false" ]; then
        echo "Error: Service '$service_name' not found in registry" >&2
        return 1
    fi

    # Get current machine
    local current_machine
    current_machine=$(yq eval ".services.${service_name}.current_host" "$CADDY_REGISTRY_PATH")

    if [ "$current_machine" = "$target_machine" ]; then
        echo "Service '$service_name' is already on machine '$target_machine'"
        return 0
    fi

    # Validate target machine exists
    local machine_exists
    machine_exists=$(yq eval ".hosts | has(\"$target_machine\")" "$CADDY_REGISTRY_PATH")
    if [ "$machine_exists" = "false" ]; then
        echo "Error: Machine '$target_machine' not found in registry" >&2
        echo "Available machines:" >&2
        yq eval '.hosts | keys | .[]' "$CADDY_REGISTRY_PATH" | sed 's/^/  /' >&2
        return 1
    fi

    echo "Moving service '$service_name': $current_machine → $target_machine"

    # Update machine
    if ! update_service "$service_name" --machine "$target_machine"; then
        return 1
    fi
    echo ""
    echo "✓ Service moved successfully"
    echo ""
    echo "Next steps:"
    echo "  1. Stop service on old machine: ssh $current_machine 'cd <working_dir> && docker compose down'"
    echo "  2. Regenerate Caddyfile: portoser caddy regenerate"
    echo "  3. Deploy to new machine: portoser deploy $target_machine $service_name"
}

# Remove service from registry
# Usage: remove_service SERVICE_NAME [--force]
remove_service() {
    local service_name="$1"
    local force=false
    shift

    if [ -z "$service_name" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                force=true
                shift
                ;;
            *)
                echo "Error: Unknown option $1" >&2
                return 1
                ;;
        esac
    done

    # Check if service exists
    local exists
    exists=$(yq eval ".services | has(\"$service_name\")" "$CADDY_REGISTRY_PATH")
    if [ "$exists" = "false" ]; then
        echo "Error: Service '$service_name' not found in registry" >&2
        return 1
    fi

    # Check if other services depend on this one
    local dependents
    dependents=$(yq eval ".services | to_entries | .[] | select(.value.dependencies // [] | contains([\"$service_name\"])) | .key" "$CADDY_REGISTRY_PATH")

    if [ -n "$dependents" ] && [ "$force" = false ]; then
        echo "Error: Cannot remove service '$service_name' - other services depend on it:" >&2
        # shellcheck disable=SC2001  # per-line prefix; bash parameter expansion can't anchor with ^
        echo "$dependents" | sed 's/^/  - /' >&2
        echo "" >&2
        echo "Use --force to remove anyway" >&2
        return 1
    fi

    echo "Removing service '$service_name' from registry..."

    # Create backup
    cp "$CADDY_REGISTRY_PATH" "${CADDY_REGISTRY_PATH}.backup"

    # Remove service
    yq eval "del(.services.${service_name})" -i "$CADDY_REGISTRY_PATH"

    # Validate after removal
    if ! validate_registry >/dev/null 2>&1; then
        echo "✗ Validation failed, restoring backup" >&2
        mv "$backup_file" "$CADDY_REGISTRY_PATH"
        return 1
    fi

    rm "${CADDY_REGISTRY_PATH}.backup"

    echo "✓ Service removed successfully"
    echo ""
    echo "Next steps:"
    echo "  1. Regenerate Caddyfile: portoser caddy regenerate"
    echo "  2. Stop service on machine: ssh <machine> 'cd <working_dir> && docker compose down'"

    return 0
}

# Show detailed information about a service
# Usage: show_service SERVICE_NAME
show_service() {
    local service_name="$1"

    if [ -z "$service_name" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    # Check if service exists
    local exists
    exists=$(yq eval ".services | has(\"$service_name\")" "$CADDY_REGISTRY_PATH")
    if [ "$exists" = "false" ]; then
        echo "Error: Service '$service_name' not found in registry" >&2
        return 1
    fi

    # Get service details
    local hostname
    hostname=$(yq eval ".services.${service_name}.hostname" "$CADDY_REGISTRY_PATH")
    local current_host
    current_host=$(yq eval ".services.${service_name}.current_host" "$CADDY_REGISTRY_PATH")
    # Read port from service.yml or docker-compose.yml
    local exposed_port
    exposed_port=$(get_service_port "$service_name" 2>/dev/null)
    local deployment_type
    deployment_type=$(yq eval ".services.${service_name}.deployment_type" "$CADDY_REGISTRY_PATH")
    local description
    description=$(yq eval ".services.${service_name}.description" "$CADDY_REGISTRY_PATH")
    local healthcheck_url
    healthcheck_url=$(yq eval ".services.${service_name}.healthcheck_url" "$CADDY_REGISTRY_PATH")
    # Read working directory from service files
    local working_directory
    working_directory=$(get_service_working_dir "$service_name" 2>/dev/null)
    local dependencies
    dependencies=$(yq eval ".services.${service_name}.dependencies // [] | .[]" "$CADDY_REGISTRY_PATH")
    local notes
    notes=$(yq eval ".services.${service_name}.notes" "$CADDY_REGISTRY_PATH")
    local last_updated
    last_updated=$(yq eval ".services.${service_name}.last_updated" "$CADDY_REGISTRY_PATH")

    # Get machine IP
    local machine_ip
    machine_ip=$(yq eval ".hosts.${current_host}.ip" "$CADDY_REGISTRY_PATH")

    echo "Service: $service_name"
    echo "  Hostname: $hostname"
    echo "  Current Host: $current_host (${machine_ip}:${exposed_port})"
    echo "  Deployment Type: $deployment_type"

    if [ "$description" != "null" ] && [ -n "$description" ]; then
        echo "  Description: $description"
    fi

    if [ "$healthcheck_url" != "null" ] && [ -n "$healthcheck_url" ]; then
        echo "  Health Check: $healthcheck_url"
    fi

    if [ "$working_directory" != "null" ] && [ -n "$working_directory" ]; then
        echo "  Working Dir: $working_directory"
    fi

    if [ -n "$dependencies" ]; then
        echo "  Dependencies:"
        # shellcheck disable=SC2001  # per-line prefix; bash parameter expansion can't anchor with ^
        echo "$dependencies" | sed 's/^/    - /'
    fi

    if [ "$notes" != "null" ] && [ -n "$notes" ]; then
        echo "  Notes:"
        # shellcheck disable=SC2001  # per-line prefix; bash parameter expansion can't anchor with ^
        echo "$notes" | sed 's/^/    /'
    fi

    if [ "$last_updated" != "null" ] && [ -n "$last_updated" ]; then
        echo "  Last Updated: $last_updated"
    fi

    return 0
}

# Add a new machine to registry
# Usage: add_machine MACHINE_NAME --ip IP --ssh-user USER [OPTIONS]
add_machine() {
    local machine_name="$1"
    shift

    if [ -z "$machine_name" ]; then
        echo "Error: Machine name required" >&2
        return 1
    fi

    # Check if machine already exists
    local exists
    exists=$(yq eval ".hosts | has(\"$machine_name\")" "$CADDY_REGISTRY_PATH")
    if [ "$exists" = "true" ]; then
        echo "Error: Machine '$machine_name' already exists in registry" >&2
        return 1
    fi

    # Parse arguments
    local ip=""
    local ssh_user=""
    local ssh_port="22"
    local path=""
    local description=""
    local context="$machine_name"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --ip)
                ip="$2"
                shift 2
                ;;
            --ssh-user)
                ssh_user="$2"
                shift 2
                ;;
            --ssh-port)
                ssh_port="$2"
                shift 2
                ;;
            --path)
                path="$2"
                shift 2
                ;;
            --description)
                description="$2"
                shift 2
                ;;
            --context)
                context="$2"
                shift 2
                ;;
            *)
                echo "Error: Unknown option $1" >&2
                return 1
                ;;
        esac
    done

    # Validate required fields
    if [ -z "$ip" ] || [ -z "$ssh_user" ] || [ -z "$path" ]; then
        echo "Error: --ip, --ssh-user, and --path are required" >&2
        return 1
    fi

    echo "Adding machine '$machine_name' to registry..."

    # Create backup
    cp "$CADDY_REGISTRY_PATH" "${CADDY_REGISTRY_PATH}.backup"

    # Add machine
    yq eval ".hosts.${machine_name}.ip = \"$ip\"" -i "$CADDY_REGISTRY_PATH"
    yq eval ".hosts.${machine_name}.ssh_user = \"$ssh_user\"" -i "$CADDY_REGISTRY_PATH"
    yq eval ".hosts.${machine_name}.ssh_port = $ssh_port" -i "$CADDY_REGISTRY_PATH"
    yq eval ".hosts.${machine_name}.path = \"$path\"" -i "$CADDY_REGISTRY_PATH"
    yq eval ".hosts.${machine_name}.context = \"$context\"" -i "$CADDY_REGISTRY_PATH"
    yq eval ".hosts.${machine_name}.roles = []" -i "$CADDY_REGISTRY_PATH"

    if [ -n "$description" ]; then
        yq eval ".hosts.${machine_name}.description = \"$description\"" -i "$CADDY_REGISTRY_PATH"
    fi

    # Validate after adding
    if ! validate_registry >/dev/null 2>&1; then
        echo "✗ Validation failed, restoring backup" >&2
        mv "$backup_file" "$CADDY_REGISTRY_PATH"
        return 1
    fi

    rm "${CADDY_REGISTRY_PATH}.backup"

    echo "✓ Machine added successfully"
    echo ""
    echo "Machine: $machine_name"
    echo "  IP: $ip"
    echo "  SSH: ${ssh_user}@${ip}:${ssh_port}"
    echo "  Path: $path"
    echo "  Context: $context"

    return 0
}
