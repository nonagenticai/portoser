#!/usr/bin/env bash
# port_conflict.sh - Solution pattern for port conflicts

set -euo pipefail
# Handles situations where a port is already in use

solve_port_conflict() {
    local problem_data="$1"

    # Parse problem data: KEY|STATUS|VALUE|MESSAGE. Only key + value drive
    # this pattern's logic.
    local obs_key="${problem_data%%|*}"
    local rest="${problem_data#*|}"
    rest="${rest#*|}"  # Skip status
    local value="${rest%%|*}"

    # Extract details from observation key: port_MACHINE_PORT
    local machine="${obs_key#port_}"
    machine="${machine%_*}"
    local port="${obs_key##*_}"

    # Extract PID from value: in_use:PID
    local pid="${value#in_use:}"

    solve_print ACTION "Checking process on port $port (PID $pid) on $machine"

    local machine_ip
    machine_ip=$(get_machine_ip "$machine" 2>/dev/null)

    if [ -z "$machine_ip" ]; then
        solve_print FAILED "Cannot get IP for machine: $machine"
        return 1
    fi

    # Get process information
    local process_info
    process_info=$(ssh -o ConnectTimeout=3 "$machine" \
        "ps -p $pid -o comm= 2>/dev/null" 2>/dev/null)

    if [ -z "$process_info" ]; then
        solve_print WARNING "Process $pid no longer exists (may have been cleaned up)"
        return 0
    fi

    solve_print ACTION "Process: $process_info (PID $pid)"

    # Check if this is a known service process
    local is_our_service=0
    for service in $(list_services 2>/dev/null); do
        local service_port
        service_port=$(get_service_port "$service" 2>/dev/null)
        local service_host
        service_host=$(get_service_host "$service" 2>/dev/null)

        if [ "$service_port" = "$port" ] && [ "$service_host" = "$machine" ]; then
            solve_print ACTION "Identified as stale instance of service: $service"
            is_our_service=1

            # Stop the stale process
            solve_print ACTION "Stopping stale process..."

            local service_type
            service_type=$(get_service_type "$service" 2>/dev/null)
            if [ "$service_type" = "docker" ]; then
                # Docker container
                if ssh -o ConnectTimeout=3 "$machine" \
                    "docker stop $service 2>/dev/null" >/dev/null 2>&1; then
                    solve_print SUCCESS "Stopped Docker container: $service"
                    return 0
                else
                    # Try force kill
                    solve_print ACTION "Force stopping container..."
                    if ssh -o ConnectTimeout=3 "$machine" \
                        "docker kill $service 2>/dev/null" >/dev/null 2>&1; then
                        solve_print SUCCESS "Force stopped Docker container: $service"
                        return 0
                    fi
                fi
            else
                # Local process - try graceful stop first
                if ssh -o ConnectTimeout=3 "$machine" \
                    "kill $pid 2>/dev/null" >/dev/null 2>&1; then
                    sleep 2

                    # Check if process is gone
                    local still_running
                    still_running=$(ssh -o ConnectTimeout=3 "$machine" \
                        "kill -0 $pid 2>/dev/null && echo 'yes' || echo 'no'" 2>/dev/null)

                    if [ "$still_running" = "no" ]; then
                        solve_print SUCCESS "Gracefully stopped process: $pid"

                        # Clean up PID file
                        local pid_file="$PIDS_DIR/${service}.pid"
                        if [ -f "$pid_file" ]; then
                            rm -f "$pid_file"
                        fi

                        return 0
                    else
                        # Force kill
                        solve_print ACTION "Process still running, force killing..."
                        if ssh -o ConnectTimeout=3 "$machine" \
                            "kill -9 $pid 2>/dev/null" >/dev/null 2>&1; then
                            solve_print SUCCESS "Force killed process: $pid"

                            # Clean up PID file
                            if [ -f "$pid_file" ]; then
                                rm -f "$pid_file"
                            fi

                            return 0
                        fi
                    fi
                fi
            fi

            solve_print FAILED "Could not stop process $pid"
            return 1
        fi
    done

    # If we get here, it's not one of our services
    if [ $is_our_service -eq 0 ]; then
        solve_print WARNING "Port is used by unknown process: $process_info"
        solve_print WARNING "Manual intervention may be required"
        solve_print ACTION "Suggestion: ssh $machine 'kill $pid'"
        return 1
    fi

    return 1
}
