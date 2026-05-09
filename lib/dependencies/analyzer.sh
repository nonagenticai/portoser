#!/usr/bin/env bash
# analyzer.sh - Dependency analysis and graph building

set -euo pipefail

# Parse dependencies from all services
# Returns JSON with service -> dependencies mapping
# Usage: parse_all_dependencies [--json-output]
parse_all_dependencies() {
    local json_output=0

    if [[ "${1:-}" = "--json-output" ]]; then
        json_output=1
    fi

    if [ ! -f "$CADDY_REGISTRY_PATH" ]; then
        if [ "$json_output" -eq 1 ]; then
            json_error "Registry file not found"
        else
            echo "Error: Registry file not found: $CADDY_REGISTRY_PATH" >&2
        fi
        return 1
    fi

    local all_services
    all_services=$(yq eval '.services | keys | .[]' "$CADDY_REGISTRY_PATH" 2>/dev/null)
    local -A dep_map

    # Build dependency map
    while IFS= read -r service; do
        local deps
        deps=$(get_service_dependencies "$service" 2>/dev/null)
        if [ -n "$deps" ]; then
            dep_map[$service]="$deps"
        else
            dep_map[$service]=""
        fi
    done <<< "$all_services"

    if [ "$json_output" -eq 1 ]; then
        # Build JSON output
        echo "{"
        echo "  \"dependencies\": {"
        local first=1
        for service in "${!dep_map[@]}"; do
            [ "$first" -eq 0 ] && echo ","
            first=0

            echo -n "    \"$service\": ["
            if [ -n "${dep_map[$service]}" ]; then
                local dep_first=1
                while IFS= read -r dep; do
                    [ -n "$dep" ] || continue
                    [ "$dep_first" -eq 0 ] && echo -n ", "
                    dep_first=0
                    echo -n "\"$dep\""
                done <<< "${dep_map[$service]}"
            fi
            echo -n "]"
        done
        echo ""
        echo "  },"
        echo "  \"total_services\": ${#dep_map[@]}"
        echo "}"
    else
        # Human-readable output
        for service in "${!dep_map[@]}"; do
            if [ -n "${dep_map[$service]}" ]; then
                echo "$service: ${dep_map[$service]}"
            else
                echo "$service: (no dependencies)"
            fi
        done
    fi
}

# Build complete dependency graph (nodes + edges)
# Returns JSON with nodes and edges arrays
# Usage: build_dependency_graph [--json-output]
build_dependency_graph() {
    local json_output=0

    if [[ "${1:-}" = "--json-output" ]]; then
        json_output=1
    fi

    if [ ! -f "$CADDY_REGISTRY_PATH" ]; then
        if [ "$json_output" -eq 1 ]; then
            json_error "Registry file not found"
        else
            echo "Error: Registry file not found" >&2
        fi
        return 1
    fi

    local all_services
    all_services=$(yq eval '.services | keys | .[]' "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ "$json_output" -eq 1 ]; then
        echo "{"
        echo "  \"nodes\": ["

        # Build nodes array
        local first=1
        while IFS= read -r service; do
            [ -z "$service" ] && continue
            [ "$first" -eq 0 ] && echo ","
            first=0

            local host
            host=$(get_service_host "$service" 2>/dev/null || echo "unknown")
            local type
            type=$(get_service_type "$service" 2>/dev/null || echo "docker")
            local hostname
            hostname=$(get_service_hostname "$service" 2>/dev/null || echo "$service.internal")

            # Get health status (simplified - could call actual health check)
            local health="unknown"

            echo -n "    {"
            echo -n "\"id\": \"$service\", "
            echo -n "\"label\": \"$service\", "
            echo -n "\"type\": \"$type\", "
            echo -n "\"host\": \"$host\", "
            echo -n "\"hostname\": \"$hostname\", "
            echo -n "\"health\": \"$health\""
            echo -n "}"
        done <<< "$all_services"

        echo ""
        echo "  ],"
        echo "  \"edges\": ["

        # Build edges array
        first=1
        while IFS= read -r service; do
            [ -z "$service" ] && continue
            local deps
            deps=$(get_service_dependencies "$service" 2>/dev/null)
            if [ -n "$deps" ]; then
                while IFS= read -r dep; do
                    [ -z "$dep" ] && continue
                    [ "$first" -eq 0 ] && echo ","
                    first=0

                    echo -n "    {"
                    echo -n "\"from\": \"$service\", "
                    echo -n "\"to\": \"$dep\", "
                    echo -n "\"type\": \"required\""
                    echo -n "}"
                done <<< "$deps"
            fi
        done <<< "$all_services"

        echo ""
        echo "  ]"
        echo "}"
    else
        echo "Dependency Graph:"
        echo "Nodes: $(echo "$all_services" | wc -l | tr -d ' ')"

        local edge_count=0
        while IFS= read -r service; do
            [ -z "$service" ] && continue
            local deps
            deps=$(get_service_dependencies "$service" 2>/dev/null)
            if [ -n "$deps" ]; then
                local dep_count
                dep_count=$(echo "$deps" | wc -l | tr -d ' ')
                edge_count=$((edge_count + dep_count))
            fi
        done <<< "$all_services"
        echo "Edges: $edge_count"
    fi
}

# Detect circular dependencies
# Returns 0 if no circular deps, 1 if found
# Usage: detect_circular_dependencies [--json-output]
detect_circular_dependencies() {
    local json_output=0

    if [ "${1:-}" = "--json-output" ]; then
        json_output=1
    fi

    local all_services
    all_services=$(yq eval '.services | keys | .[]' "$CADDY_REGISTRY_PATH" 2>/dev/null)
    local -A visited
    local -A rec_stack
    local circular_found=0
    local circular_path=""

    # DFS helper function to detect cycle
    detect_cycle_dfs() {
        local node="$1"
        local path="$2"

        visited[$node]=1
        rec_stack[$node]=1

        local deps
        deps=$(get_service_dependencies "$node" 2>/dev/null)
        if [ -n "$deps" ]; then
            while IFS= read -r dep; do
                [ -z "$dep" ] && continue
                if [ -z "${visited[$dep]:-}" ]; then
                    detect_cycle_dfs "$dep" "$path -> $dep"
                elif [ "${rec_stack[$dep]:-0}" = "1" ]; then
                    circular_found=1
                    circular_path="$path -> $dep (cycle detected)"
                    return 1
                fi
            done <<< "$deps"
        fi

        rec_stack[$node]=0
        return 0
    }

    # Check each service as starting point
    while IFS= read -r service; do
        [ -z "$service" ] && continue
        if [ -z "${visited[$service]:-}" ]; then
            detect_cycle_dfs "$service" "$service"
            if [ "$circular_found" -eq 1 ]; then
                break
            fi
        fi
    done <<< "$all_services"

    if [ "$json_output" -eq 1 ]; then
        echo "{"
        echo "  \"has_circular_dependencies\": $([ $circular_found -eq 1 ] && echo "true" || echo "false"),"
        echo "  \"circular_path\": \"$circular_path\""
        echo "}"
    else
        if [ "$circular_found" -eq 1 ]; then
            echo "✗ Circular dependency detected: $circular_path"
            return 1
        else
            echo "✓ No circular dependencies found"
            return 0
        fi
    fi
}

# Calculate deployment order using topological sort
# Usage: calculate_deployment_order SERVICE [--json-output]
calculate_deployment_order() {
    local target_service="${1:-}"
    local json_output=0

    if [ "${2:-}" = "--json-output" ]; then
        json_output=1
    fi

    if [ -z "$target_service" ]; then
        if [ "$json_output" -eq 1 ]; then
            json_error "Service name required"
        else
            echo "Error: Service name required" >&2
        fi
        return 1
    fi

    local -a order
    local -A visited

    # DFS-based topological sort
    topo_sort_dfs() {
        local node="$1"

        if [ "${visited[$node]:-0}" = "1" ]; then
            return 0
        fi

        visited[$node]=1

        local deps
        deps=$(get_service_dependencies "$node" 2>/dev/null)
        if [ -n "$deps" ]; then
            while IFS= read -r dep; do
                [ -z "$dep" ] && continue
                topo_sort_dfs "$dep"
            done <<< "$deps"
        fi

        order+=("$node")
    }

    # Build order starting from target service
    topo_sort_dfs "$target_service"

    if [ "$json_output" -eq 1 ]; then
        echo "{"
        echo "  \"service\": \"$target_service\","
        echo "  \"deployment_order\": ["

        local first=1
        for svc in "${order[@]}"; do
            [ "$first" -eq 0 ] && echo ","
            first=0
            echo -n "    \"$svc\""
        done

        echo ""
        echo "  ],"
        echo "  \"total_services\": ${#order[@]}"
        echo "}"
    else
        echo "Deployment order for $target_service:"
        local i=1
        for svc in "${order[@]}"; do
            echo "$i. $svc"
            i=$((i + 1))
        done
    fi
}

# Get all services that depend on a target service (reverse lookup)
# Usage: get_impact_analysis SERVICE [--json-output]
get_impact_analysis() {
    local target_service="${1:-}"
    local json_output=0

    if [ "${2:-}" = "--json-output" ]; then
        json_output=1
    fi

    if [ -z "$target_service" ]; then
        if [ "$json_output" -eq 1 ]; then
            json_error "Service name required"
        else
            echo "Error: Service name required" >&2
        fi
        return 1
    fi

    local all_services
    all_services=$(yq eval '.services | keys | .[]' "$CADDY_REGISTRY_PATH" 2>/dev/null)
    # Explicitly initialize as empty arrays. With `set -u` and bash <4.4,
    # `local -a foo` followed by `${#foo[@]}` raises "unbound variable" if
    # the array was never assigned to — which happens when a service has
    # no dependents (the find_all_dependents loop never runs).
    local -a direct_dependents=()
    local -a all_dependents=()
    local -A checked=()

    # Find all services that directly depend on target
    while IFS= read -r service; do
        [ -z "$service" ] && continue
        local deps
        deps=$(get_service_dependencies "$service" 2>/dev/null)
        if [ -n "$deps" ]; then
            while IFS= read -r dep; do
                [ -z "$dep" ] && continue
                if [ "$dep" = "$target_service" ]; then
                    direct_dependents+=("$service")
                    break
                fi
            done <<< "$deps"
        fi
    done <<< "$all_services"

    # Recursively find all dependents
    find_all_dependents() {
        local svc="$1"

        # `${assoc[missing_key]}` raises under `set -u`; the `:-` default
        # gives "" for unseen entries instead.
        if [ "${checked[$svc]:-}" = "1" ]; then
            return 0
        fi

        checked[$svc]=1
        all_dependents+=("$svc")

        while IFS= read -r service; do
            [ -z "$service" ] && continue
            local deps
            deps=$(get_service_dependencies "$service" 2>/dev/null)
            if [ -n "$deps" ]; then
                while IFS= read -r dep; do
                    [ -z "$dep" ] && continue
                    if [ "$dep" = "$svc" ]; then
                        find_all_dependents "$service"
                    fi
                done <<< "$deps"
            fi
        done <<< "$all_services"
    }

    for dep in "${direct_dependents[@]}"; do
        find_all_dependents "$dep"
    done

    # Calculate impact level
    local impact_level="low"
    local count=${#all_dependents[@]}
    if [ "$count" -ge 5 ]; then
        impact_level="high"
    elif [ "$count" -ge 2 ]; then
        impact_level="medium"
    fi

    if [ "$json_output" -eq 1 ]; then
        echo "{"
        echo "  \"service\": \"$target_service\","
        echo "  \"direct_dependents\": ["

        local first=1
        for svc in "${direct_dependents[@]}"; do
            [ "$first" -eq 0 ] && echo ","
            first=0
            echo -n "    \"$svc\""
        done

        echo ""
        echo "  ],"
        echo "  \"all_dependents\": ["

        first=1
        for svc in "${all_dependents[@]}"; do
            [ "$first" -eq 0 ] && echo ","
            first=0
            echo -n "    \"$svc\""
        done

        echo ""
        echo "  ],"
        echo "  \"impact_level\": \"$impact_level\","
        echo "  \"total_affected\": ${#all_dependents[@]}"
        echo "}"
    else
        echo "Impact Analysis for: $target_service"
        echo "Impact Level: $impact_level"
        echo ""
        echo "Direct Dependents (${#direct_dependents[@]}):"
        for svc in "${direct_dependents[@]}"; do
            echo "  - $svc"
        done
        echo ""
        echo "Total Affected Services: ${#all_dependents[@]}"
    fi
}

# Validate dependencies check
# Usage: validate_dependencies [--json-output]
validate_dependencies() {
    local json_output=0

    if [ "${1:-}" = "--json-output" ]; then
        json_output=1
    fi

    local all_services
    all_services=$(yq eval '.services | keys | .[]' "$CADDY_REGISTRY_PATH" 2>/dev/null)
    local -a errors
    local valid=1

    # Check for missing services
    while IFS= read -r service; do
        [ -z "$service" ] && continue
        local deps
        deps=$(get_service_dependencies "$service" 2>/dev/null)
        if [ -n "$deps" ]; then
            while IFS= read -r dep; do
                [ -z "$dep" ] && continue
                if ! is_service "$dep"; then
                    errors+=("Service '$service' depends on non-existent service '$dep'")
                    valid=0
                fi
            done <<< "$deps"
        fi
    done <<< "$all_services"

    # Check for circular dependencies
    local circular_check
    circular_check=$(detect_circular_dependencies --json-output)
    local has_circular
    has_circular=$(echo "$circular_check" | jq -r '.has_circular_dependencies' 2>/dev/null)

    if [ "$has_circular" = "true" ]; then
        local circular_path
        circular_path=$(echo "$circular_check" | jq -r '.circular_path' 2>/dev/null)
        errors+=("Circular dependency: $circular_path")
        valid=0
    fi

    if [ "$json_output" -eq 1 ]; then
        echo "{"
        echo "  \"valid\": $([ $valid -eq 1 ] && echo "true" || echo "false"),"
        echo "  \"errors\": ["

        local first=1
        for err in "${errors[@]}"; do
            [ "$first" -eq 0 ] && echo ","
            first=0
            echo -n "    \"$err\""
        done

        echo ""
        echo "  ],"
        echo "  \"total_errors\": ${#errors[@]}"
        echo "}"
    else
        if [ "$valid" -eq 1 ]; then
            echo "✓ All dependencies are valid"
            return 0
        else
            echo "✗ Dependency validation failed:"
            for err in "${errors[@]}"; do
                echo "  - $err"
            done
            return 1
        fi
    fi
}

# Get dependency chain (all dependencies recursively)
# Usage: get_dependency_chain SERVICE [--json-output]
get_dependency_chain() {
    local target_service="${1:-}"
    local json_output=0

    if [ "${2:-}" = "--json-output" ]; then
        json_output=1
    fi

    if [ -z "$target_service" ]; then
        if [ "$json_output" -eq 1 ]; then
            json_error "Service name required"
        else
            echo "Error: Service name required" >&2
        fi
        return 1
    fi

    local -a chain
    local -A visited

    build_chain() {
        local svc="$1"
        local depth="$2"

        if [ "${visited[$svc]:-0}" = "1" ]; then
            return 0
        fi

        visited[$svc]=1
        chain+=("$depth:$svc")

        local deps
        deps=$(get_service_dependencies "$svc" 2>/dev/null)
        if [ -n "$deps" ]; then
            while IFS= read -r dep; do
                [ -z "$dep" ] && continue
                build_chain "$dep" "$((depth + 1))"
            done <<< "$deps"
        fi
    }

    build_chain "$target_service" 0

    if [ "$json_output" -eq 1 ]; then
        echo "{"
        echo "  \"service\": \"$target_service\","
        echo "  \"chain\": ["

        local first=1
        for item in "${chain[@]}"; do
            [ "$first" -eq 0 ] && echo ","
            first=0

            local depth="${item%%:*}"
            local svc="${item#*:}"
            echo -n "    {\"service\": \"$svc\", \"depth\": $depth}"
        done

        echo ""
        echo "  ],"
        echo "  \"total_dependencies\": $((${#chain[@]} - 1))"
        echo "}"
    else
        echo "Dependency chain for $target_service:"
        for item in "${chain[@]}"; do
            local depth="${item%%:*}"
            local svc="${item#*:}"
            local indent
            indent=$(printf '%*s' $((depth * 2)) '')
            echo "$indent- $svc"
        done
    fi
}
