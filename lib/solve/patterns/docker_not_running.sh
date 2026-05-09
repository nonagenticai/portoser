#!/usr/bin/env bash
# docker_not_running.sh - Solution pattern for Docker daemon not running

set -euo pipefail
# Handles situations where Docker is required but not running

solve_docker_not_running() {
    local problem_data="$1"

    # Parse problem data: KEY|STATUS|VALUE|MESSAGE. Only the key is needed
    # by this pattern (to extract the machine name); the rest is informational.
    local obs_key="${problem_data%%|*}"

    # Extract machine name: docker_MACHINE
    local machine="${obs_key#docker_}"

    solve_print ACTION "Attempting to start Docker daemon on $machine"

    local machine_ip
    machine_ip=$(get_machine_ip "$machine" 2>/dev/null)

    if [ -z "$machine_ip" ]; then
        solve_print FAILED "Cannot get IP for machine: $machine"
        return 1
    fi

    # Check OS type to determine how to start Docker
    local os_type
    os_type=$(ssh -o ConnectTimeout=3 "$machine" \
        "uname -s" 2>/dev/null)

    case "$os_type" in
        Darwin)
            # macOS - use open or osascript
            solve_print ACTION "Starting Docker Desktop on macOS..."

            # Try to start Docker Desktop
            if ssh -o ConnectTimeout=3 "$machine" \
                "open -a Docker 2>/dev/null" >/dev/null 2>&1; then
                solve_print ACTION "Docker Desktop starting... waiting for daemon"

                # Wait for Docker daemon to be ready (up to 30 seconds)
                local wait_count=0
                while [ $wait_count -lt 30 ]; do
                    sleep 1
                    ((wait_count++))

                    local docker_status
                    docker_status=$(ssh -o ConnectTimeout=3 "$machine" \
                        "docker info >/dev/null 2>&1 && echo 'running' || echo 'not_running'" 2>/dev/null)

                    if [ "$docker_status" = "running" ]; then
                        solve_print SUCCESS "Docker daemon is now running (${wait_count}s)"
                        return 0
                    fi
                done

                solve_print WARNING "Docker Desktop launched but daemon not ready after 30s"
                return 1
            else
                solve_print FAILED "Could not launch Docker Desktop"
                return 1
            fi
            ;;

        Linux)
            # Linux - use systemctl or service
            solve_print ACTION "Starting Docker daemon on Linux..."

            # Try systemctl first
            if ssh -o ConnectTimeout=3 "$machine" \
                "sudo systemctl start docker 2>/dev/null" >/dev/null 2>&1; then
                sleep 2

                local docker_status
                docker_status=$(ssh -o ConnectTimeout=3 "$machine" \
                    "docker info >/dev/null 2>&1 && echo 'running' || echo 'not_running'" 2>/dev/null)

                if [ "$docker_status" = "running" ]; then
                    solve_print SUCCESS "Docker daemon started via systemctl"
                    return 0
                fi
            fi

            # Try service command
            if ssh -o ConnectTimeout=3 "$machine" \
                "sudo service docker start 2>/dev/null" >/dev/null 2>&1; then
                sleep 2

                local docker_status
                docker_status=$(ssh -o ConnectTimeout=3 "$machine" \
                    "docker info >/dev/null 2>&1 && echo 'running' || echo 'not_running'" 2>/dev/null)

                if [ "$docker_status" = "running" ]; then
                    solve_print SUCCESS "Docker daemon started via service command"
                    return 0
                fi
            fi

            solve_print FAILED "Could not start Docker daemon on Linux"
            return 1
            ;;

        *)
            solve_print FAILED "Unknown OS type: $os_type"
            solve_print WARNING "Manual intervention required to start Docker"
            solve_print ACTION "Suggestion: ssh $machine and start Docker manually"
            return 1
            ;;
    esac
}
