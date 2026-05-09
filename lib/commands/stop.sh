#!/usr/bin/env bash
################################################################################
# Stop Command Module
#
# Stops services or all services on a machine.
# Respects dependency chains by default, unless --force is used.
#
# Usage: portoser stop <service|machine> [options] [service...]
################################################################################

set -euo pipefail

# Stop command handler (registry-aware)
cmd_stop() {
    if [ $# -eq 0 ]; then
        stop_help
        exit 1
    fi

    local first_arg="$1"
    local force=""

    # Check if first argument is a machine or service
    if is_machine "$first_arg"; then
        # Machine-based stop
        local machine="$first_arg"
        shift
        local args=("$@")

        # Extract --force flag and services
        local services=()
        for arg in "${args[@]}"; do
            if [ "$arg" = "--force" ]; then
                force="--force"
            else
                services+=("$arg")
            fi
        done

        if [ ${#services[@]} -eq 0 ]; then
            # Stop all services on machine
            print_color "$BLUE" "Stopping all services on $machine..."
            stop_machine_services "$machine" "$force"
        else
            # Stop specific services on machine
            print_color "$BLUE" "Stopping services on $machine: ${services[*]}"
            stop_machine_services "$machine" "$force" "${services[@]}"
        fi
    elif is_service "$first_arg"; then
        # Service-based stop
        local service="$first_arg"
        shift

        # Check for --force flag
        if [ "$1" = "--force" ]; then
            force="--force"
        fi

        print_color "$BLUE" "Stopping service: $service"
        smart_stop_service "$service" "$force"
    else
        print_color "$RED" "Error: '$first_arg' is neither a registered machine nor service"
        exit 1
    fi
}

# Help function for stop command
stop_help() {
    cat <<EOF
Usage: portoser stop <service|machine> [options] [service...]

Stop services or all services on a machine.

Options:
  --force    Skip dependency checking and stop immediately

Examples:
  portoser stop requirements            # Stop service (registry knows where/how)
  portoser stop requirements --force    # Stop immediately, ignore dependents
  portoser stop host-b                   # Stop all services on host-b
  portoser stop host-b requirements myservice  # Stop specific services on host-b
  portoser stop host-b --force           # Stop all on host-b, ignore dependencies

By default, dependency chains are respected. Use --force to skip dependency
checking and stop immediately.

EOF
}

################################################################################
# End of stop.sh
################################################################################
