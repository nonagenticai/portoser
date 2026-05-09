#!/usr/bin/env bash
################################################################################
# Status Command Module
#
# Displays overview of all services, their types, locations, and health status.
#
# Usage: portoser status
################################################################################

set -euo pipefail

# Status command handler
cmd_status() {
    echo "Portoser - Service Status Overview"
    echo "======================================"
    echo ""

    local services
    services=$(list_services)

    printf "%-25s %-10s %-15s %-10s %s\n" "SERVICE" "TYPE" "MACHINE" "STATUS" "HEALTH"
    echo "--------------------------------------------------------------------------------"

    # Use file descriptor 3 for reading services to free stdin for SSH commands
    while IFS= read -r -u 3 service; do
        if [ -z "$service" ]; then
            continue
        fi

        local service_type
        service_type=$(get_service_type "$service")
        local current_host
        current_host=$(get_service_host "$service")
        local service_status
        service_status=$(get_service_status "$service" 2>/dev/null || echo "unknown")
        local health="N/A"

        if [ "$service_status" = "running" ]; then
            if check_service_health "$service" 1 2>/dev/null; then
                health="✓"
            else
                health="✗"
            fi
        fi

        printf "%-25s %-10s %-15s %-10s %s\n" "$service" "$service_type" "$current_host" "$service_status" "$health"
    done 3<<< "$services"

    echo ""
}

# Help function for status command
status_help() {
    cat <<EOF
Usage: portoser status

Display a table showing all services, their types, current machine, and health.

This command shows:
  - SERVICE: Name of the service
  - TYPE: Service type (docker, native, etc.)
  - MACHINE: Machine where the service is currently deployed
  - STATUS: Service status (running, stopped, etc.)
  - HEALTH: Health check result (✓ = healthy, ✗ = unhealthy, N/A = not running)

Example:
  portoser status

EOF
}

################################################################################
# End of status.sh
################################################################################
