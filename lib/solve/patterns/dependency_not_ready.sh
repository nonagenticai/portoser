#!/usr/bin/env bash
# dependency_not_ready.sh - Solution pattern for unhealthy dependencies

set -euo pipefail
# Handles situations where service dependencies are not responding

solve_dependency_not_ready() {
    local problem_data="$1"

    # Parse problem data: KEY|STATUS|VALUE|MESSAGE. Only the key (for the
    # service name) and the value (for the unhealthy-deps list) are needed.
    local obs_key="${problem_data%%|*}"
    local rest="${problem_data#*|}"
    rest="${rest#*|}"  # Skip status
    local value="${rest%%|*}"

    # Extract service name: deps_SERVICE
    local service="${obs_key#deps_}"

    # Extract unhealthy dependencies from value: unhealthy: dep1 dep2
    local unhealthy_deps="${value#unhealthy:}"

    solve_print ACTION "Attempting to start dependencies for $service"
    solve_print ACTION "Unhealthy dependencies:$unhealthy_deps"

    local deps_started=0
    local deps_failed=0

    for dep in $unhealthy_deps; do
        dep=$(echo "$dep" | xargs)  # Trim whitespace
        if [ -z "$dep" ]; then
            continue
        fi

        solve_print ACTION "Starting dependency: $dep"

        # Get dependency info
        local dep_host
        dep_host=$(get_service_host "$dep" 2>/dev/null)
        local dep_type
        dep_type=$(get_service_type "$dep" 2>/dev/null)

        if [ -z "$dep_host" ] || [ "$dep_host" = "null" ]; then
            solve_print WARNING "Dependency $dep not deployed yet"
            ((deps_failed++))
            continue
        fi

        # Try to start the dependency
        local start_success=0
        if [ "$dep_type" = "docker" ]; then
            if docker_start "$dep" "$dep_host" >/dev/null 2>&1; then
                solve_print SUCCESS "Started Docker service: $dep"
                start_success=1
            else
                # Try restart if start failed
                if docker_restart "$dep" "$dep_host" >/dev/null 2>&1; then
                    solve_print SUCCESS "Restarted Docker service: $dep"
                    start_success=1
                fi
            fi
        else
            if remote_start_service "$dep" "$dep_host" >/dev/null 2>&1; then
                solve_print SUCCESS "Started service: $dep"
                start_success=1
            else
                # Try restart if start failed
                if remote_restart_service "$dep" "$dep_host" >/dev/null 2>&1; then
                    solve_print SUCCESS "Restarted service: $dep"
                    start_success=1
                fi
            fi
        fi

        if [ $start_success -eq 1 ]; then
            # Wait a moment for service to be ready
            solve_print ACTION "Waiting for $dep to be healthy..."
            sleep 2

            # Check health
            if wait_for_service_health "$dep" 15 >/dev/null 2>&1; then
                solve_print SUCCESS "Dependency $dep is now healthy"
                ((deps_started++))
            else
                solve_print WARNING "Dependency $dep started but not yet healthy"
                ((deps_started++))
            fi
        else
            solve_print FAILED "Could not start dependency: $dep"
            ((deps_failed++))
        fi
    done

    if [ $deps_failed -eq 0 ]; then
        solve_print SUCCESS "All dependencies started successfully ($deps_started)"
        return 0
    else
        solve_print WARNING "Some dependencies could not be started ($deps_failed failed)"
        return 1
    fi
}
