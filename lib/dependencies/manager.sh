#!/usr/bin/env bash
# manager.sh - Dependency management (add/remove dependencies)

set -euo pipefail

# Add a dependency to a service
# Usage: add_service_dependency SERVICE DEPENDENCY [--json-output]
add_service_dependency() {
    local service="${1:-}"
    local dependency="$2"
    local json_output=0

    if [ "$3" = "--json-output" ]; then
        json_output=1
    fi

    if [ -z "$service" ] || [ -z "$dependency" ]; then
        if [ "$json_output" -eq 1 ]; then
            json_error "Service and dependency names required"
        else
            echo "Error: Service and dependency names required" >&2
            echo "Usage: portoser dependencies add <service> <dependency>" >&2
        fi
        return 1
    fi

    # Validate service exists
    if ! is_service "$service"; then
        if [ "$json_output" -eq 1 ]; then
            json_error "Service '$service' not found in registry"
        else
            echo "Error: Service '$service' not found in registry" >&2
        fi
        return 1
    fi

    # Validate dependency exists
    if ! is_service "$dependency"; then
        if [ "$json_output" -eq 1 ]; then
            json_error "Dependency service '$dependency' not found in registry"
        else
            echo "Error: Dependency service '$dependency' not found in registry" >&2
        fi
        return 1
    fi

    # Check if adding would create a circular dependency. visited memoizes
    # the DFS through the dependency graph; check_circular fetches each
    # node's deps on demand.
    local -A visited

    check_circular() {
        local node="$1"

        if [ "$node" = "$service" ]; then
            return 1  # Circular dependency detected
        fi

        if [ "${visited[$node]}" = "1" ]; then
            return 0
        fi

        visited[$node]=1

        local deps
        deps=$(get_service_dependencies "$node" 2>/dev/null)
        if [ -n "$deps" ]; then
            while IFS= read -r dep; do
                [ -z "$dep" ] && continue
                if ! check_circular "$dep"; then
                    return 1
                fi
            done <<< "$deps"
        fi

        return 0
    }

    if ! check_circular "$dependency"; then
        if [ "$json_output" -eq 1 ]; then
            json_error "Adding dependency would create circular dependency"
        else
            echo "Error: Adding dependency '$dependency' to '$service' would create a circular dependency" >&2
        fi
        return 1
    fi

    # Get service file path
    local service_file=""
    local deployment_type
    deployment_type=$(get_service_type "$service")

    if [ "$deployment_type" = "docker" ]; then
        service_file=$(get_docker_compose_path "$service")
    else
        service_file=$(get_service_yml_path "$service")
    fi

    if [ "$service_file" = "null" ] || [ -z "$service_file" ]; then
        if [ "$json_output" -eq 1 ]; then
            json_error "Service file not found for '$service'"
        else
            echo "Error: Service file not found for '$service'" >&2
        fi
        return 1
    fi

    # Check if dependency already exists
    local current_deps
    current_deps=$(get_service_dependencies "$service" 2>/dev/null)
    if [ -n "$current_deps" ]; then
        while IFS= read -r dep; do
            [ -z "$dep" ] && continue
            if [ "$dep" = "$dependency" ]; then
                if [ "$json_output" -eq 1 ]; then
                    json_error "Dependency already exists"
                else
                    echo "Error: Service '$service' already depends on '$dependency'" >&2
                fi
                return 1
            fi
        done <<< "$current_deps"
    fi

    # Add dependency to service file
    local rc=0
    if [ "$deployment_type" = "docker" ]; then
        # For docker-compose.yml, add to depends_on section
        local compose_service
        compose_service=$(get_docker_service_name "$service")

        # Check if depends_on exists
        local has_depends_on
        has_depends_on=$(yq eval ".services.${compose_service}.depends_on" "$service_file" 2>/dev/null)

        if [ "$has_depends_on" = "null" ] || [ -z "$has_depends_on" ]; then
            # Create depends_on array
            yq eval -i ".services.${compose_service}.depends_on = [\"$dependency\"]" "$service_file" || rc=$?
        else
            # Append to existing depends_on
            yq eval -i ".services.${compose_service}.depends_on += [\"$dependency\"]" "$service_file" || rc=$?
        fi
    else
        # For service.yml, add to dependencies section. Both branches do the
        # same two yq writes, so the structural distinction was vestigial.
        yq eval -i ".dependencies.${dependency}.type = \"required\"" "$service_file" || rc=$?
        if [ "$rc" -eq 0 ]; then
            yq eval -i ".dependencies.${dependency}.reason = \"Added via portoser CLI\"" "$service_file" || rc=$?
        fi
    fi

    if [ "$rc" -eq 0 ]; then
        if [ "$json_output" -eq 1 ]; then
            echo "{"
            echo "  \"success\": true,"
            echo "  \"service\": \"$service\","
            echo "  \"dependency\": \"$dependency\","
            echo "  \"message\": \"Dependency added successfully\""
            echo "}"
        else
            echo "✓ Added dependency '$dependency' to service '$service'"
            echo "  Updated: $service_file"
        fi
        return 0
    else
        if [ "$json_output" -eq 1 ]; then
            json_error "Failed to update service file"
        else
            echo "Error: Failed to update service file" >&2
        fi
        return 1
    fi
}

# Remove a dependency from a service
# Usage: remove_service_dependency SERVICE DEPENDENCY [--json-output]
remove_service_dependency() {
    local service="${1:-}"
    local dependency="$2"
    local json_output=0

    if [ "$3" = "--json-output" ]; then
        json_output=1
    fi

    if [ -z "$service" ] || [ -z "$dependency" ]; then
        if [ "$json_output" -eq 1 ]; then
            json_error "Service and dependency names required"
        else
            echo "Error: Service and dependency names required" >&2
            echo "Usage: portoser dependencies remove <service> <dependency>" >&2
        fi
        return 1
    fi

    # Validate service exists
    if ! is_service "$service"; then
        if [ "$json_output" -eq 1 ]; then
            json_error "Service '$service' not found in registry"
        else
            echo "Error: Service '$service' not found in registry" >&2
        fi
        return 1
    fi

    # Check if dependency exists in service
    local current_deps
    current_deps=$(get_service_dependencies "$service" 2>/dev/null)
    local dependency_found=0

    if [ -n "$current_deps" ]; then
        while IFS= read -r dep; do
            [ -z "$dep" ] && continue
            if [ "$dep" = "$dependency" ]; then
                dependency_found=1
                break
            fi
        done <<< "$current_deps"
    fi

    if [ "$dependency_found" -eq 0 ]; then
        if [ "$json_output" -eq 1 ]; then
            json_error "Dependency not found"
        else
            echo "Error: Service '$service' does not depend on '$dependency'" >&2
        fi
        return 1
    fi

    # Get service file path
    local service_file=""
    local deployment_type
    deployment_type=$(get_service_type "$service")

    if [ "$deployment_type" = "docker" ]; then
        service_file=$(get_docker_compose_path "$service")
    else
        service_file=$(get_service_yml_path "$service")
    fi

    if [ "$service_file" = "null" ] || [ -z "$service_file" ]; then
        if [ "$json_output" -eq 1 ]; then
            json_error "Service file not found for '$service'"
        else
            echo "Error: Service file not found for '$service'" >&2
        fi
        return 1
    fi

    # Remove dependency from service file
    local rc=0
    if [ "$deployment_type" = "docker" ]; then
        # For docker-compose.yml, remove from depends_on array
        local compose_service
        compose_service=$(get_docker_service_name "$service")

        # Get current depends_on as array
        local depends_on
        depends_on=$(yq eval ".services.${compose_service}.depends_on" "$service_file" 2>/dev/null)

        if [ "$depends_on" != "null" ] && [ -n "$depends_on" ]; then
            # Remove the dependency from the array
            yq eval -i "del(.services.${compose_service}.depends_on[] | select(. == \"$dependency\"))" "$service_file" || rc=$?

            # Check if depends_on is now empty, and remove it if so
            local new_depends_on
            new_depends_on=$(yq eval ".services.${compose_service}.depends_on | length" "$service_file" 2>/dev/null)
            if [ "$rc" -eq 0 ] && [ "$new_depends_on" = "0" ]; then
                yq eval -i "del(.services.${compose_service}.depends_on)" "$service_file" || rc=$?
            fi
        fi
    else
        # For service.yml, remove from dependencies object
        yq eval -i "del(.dependencies.${dependency})" "$service_file" || rc=$?
    fi

    if [ "$rc" -eq 0 ]; then
        if [ "$json_output" -eq 1 ]; then
            echo "{"
            echo "  \"success\": true,"
            echo "  \"service\": \"$service\","
            echo "  \"dependency\": \"$dependency\","
            echo "  \"message\": \"Dependency removed successfully\""
            echo "}"
        else
            echo "✓ Removed dependency '$dependency' from service '$service'"
            echo "  Updated: $service_file"
        fi
        return 0
    else
        if [ "$json_output" -eq 1 ]; then
            json_error "Failed to update service file"
        else
            echo "Error: Failed to update service file" >&2
        fi
        return 1
    fi
}

# List all dependencies for a service with details
# Usage: list_service_dependencies SERVICE [--json-output]
list_service_dependencies() {
    local service="${1:-}"
    local json_output=0

    if [ "${2:-}" = "--json-output" ]; then
        json_output=1
    fi

    if [ -z "$service" ]; then
        if [ "$json_output" -eq 1 ]; then
            json_error "Service name required"
        else
            echo "Error: Service name required" >&2
        fi
        return 1
    fi

    if ! is_service "$service"; then
        if [ "$json_output" -eq 1 ]; then
            json_error "Service '$service' not found in registry"
        else
            echo "Error: Service '$service' not found in registry" >&2
        fi
        return 1
    fi

    local deps
    deps=$(get_service_dependencies "$service" 2>/dev/null)
    local dependents
    dependents=$(get_service_dependents "$service" 2>/dev/null)

    if [ "$json_output" -eq 1 ]; then
        echo "{"
        echo "  \"service\": \"$service\","
        echo "  \"dependencies\": ["

        local first=1
        if [ -n "$deps" ]; then
            while IFS= read -r dep; do
                [ -z "$dep" ] && continue
                [ $first -eq 0 ] && echo ","
                first=0

                local dep_host
                dep_host=$(get_service_host "$dep" 2>/dev/null || echo "unknown")
                local dep_type
                dep_type=$(get_service_type "$dep" 2>/dev/null || echo "unknown")

                echo -n "    {"
                echo -n "\"name\": \"$dep\", "
                echo -n "\"host\": \"$dep_host\", "
                echo -n "\"type\": \"$dep_type\""
                echo -n "}"
            done <<< "$deps"
        fi

        echo ""
        echo "  ],"
        echo "  \"dependents\": ["

        first=1
        if [ -n "$dependents" ]; then
            # Convert comma-separated to array
            IFS=',' read -ra dep_array <<< "$dependents"
            for dependent in "${dep_array[@]}"; do
                [ -z "$dependent" ] && continue
                [ $first -eq 0 ] && echo ","
                first=0

                local dep_host
                dep_host=$(get_service_host "$dependent" 2>/dev/null || echo "unknown")
                local dep_type
                dep_type=$(get_service_type "$dependent" 2>/dev/null || echo "unknown")

                echo -n "    {"
                echo -n "\"name\": \"$dependent\", "
                echo -n "\"host\": \"$dep_host\", "
                echo -n "\"type\": \"$dep_type\""
                echo -n "}"
            done
        fi

        echo ""
        echo "  ]"
        echo "}"
    else
        echo "Service: $service"
        echo ""
        echo "Dependencies:"
        if [ -n "$deps" ]; then
            while IFS= read -r dep; do
                [ -z "$dep" ] && continue
                echo "  - $dep"
            done <<< "$deps"
        else
            echo "  (none)"
        fi
        echo ""
        echo "Dependents (services that depend on this):"
        if [ -n "$dependents" ]; then
            IFS=',' read -ra dep_array <<< "$dependents"
            for dependent in "${dep_array[@]}"; do
                [ -z "$dependent" ] && continue
                echo "  - $dependent"
            done
        else
            echo "  (none)"
        fi
    fi
}
