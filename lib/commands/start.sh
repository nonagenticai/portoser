#!/usr/bin/env bash
################################################################################
# Start Command Module
#
# Starts services or all services on a machine.
# Registry-aware startup that knows where each service is located.
#
# Usage: portoser start <service|machine> [service...]
################################################################################

set -euo pipefail

# Start command handler (registry-aware)
cmd_start() {
    if [ $# -eq 0 ]; then
        start_help
        exit 1
    fi

    local first_arg="$1"

    # Check if first argument is a machine or service
    if is_machine "$first_arg"; then
        # Machine-based start
        local machine="$first_arg"
        shift
        local services=("$@")

        if [ ${#services[@]} -eq 0 ]; then
            # Start all services on machine
            print_color "$BLUE" "Starting all services on $machine..."
            start_machine_services "$machine"
        else
            # Start specific services on machine
            print_color "$BLUE" "Starting services on $machine: ${services[*]}"
            start_machine_services "$machine" "${services[@]}"
        fi
    elif is_service "$first_arg"; then
        # Service-based start
        local service="$first_arg"
        print_color "$BLUE" "Starting service: $service"
        smart_start_service "$service"
        local exit_code="$?"
        exit "$exit_code"
    else
        print_color "$RED" "Error: '$first_arg' is neither a registered machine nor service"
        exit 1
    fi
}

# Help function for start command
start_help() {
    cat <<EOF
Usage: portoser start <service|machine> [service...]

Start services or all services on a machine.

Examples:
  portoser start requirements          # Start service (registry knows where/how)
  portoser start host-b                 # Start all services on host-b
  portoser start host-b requirements myservice # Start specific services on host-b

The registry automatically tracks where each service is deployed, so you don't
need to specify the machine when starting individual services.

EOF
}

################################################################################
# End of start.sh
################################################################################
