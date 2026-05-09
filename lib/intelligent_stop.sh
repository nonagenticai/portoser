#!/usr/bin/env bash
# intelligent_stop.sh - Intelligent service stopping with observation

set -euo pipefail

# Cleanup background jobs on exit (only when any exist).
_intelligent_stop_cleanup_jobs() {
    local pids
    pids=$(jobs -p)
    if [ -n "$pids" ]; then
        # shellcheck disable=SC2086 # word-split intentional: pids is space-separated
        kill $pids 2>/dev/null || true
    fi
}
trap _intelligent_stop_cleanup_jobs EXIT INT TERM

# Stops services regardless of how they were started

# Source uptime tracking
SCRIPT_DIR_ISTOP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR_ISTOP/../metrics/uptime.sh" ]; then
    # shellcheck source=lib/metrics/uptime.sh
    source "$SCRIPT_DIR_ISTOP/../metrics/uptime.sh"
fi

# Returns 0 (true) if MACHINE refers to the host running this script.
# Recognises both the literal "local" alias and the actual short hostname.
_is_local_machine() {
    local machine="$1"
    local self
    self=$(hostname -s 2>/dev/null || hostname | cut -d. -f1)
    [ "$machine" = "local" ] || [ "$machine" = "$self" ]
}


# Intelligent stop for Docker service
# Usage: intelligent_docker_stop SERVICE MACHINE
intelligent_docker_stop() {
    local service="$1"
    local machine="$2"

    [ "$DEBUG" = "1" ] && echo "  Debug: Getting machine info..."
    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")
    local machine_ip
    machine_ip=$(get_machine_ip "$machine")
    [ "$DEBUG" = "1" ] && echo "  Debug: $ssh_user@$machine_ip"

    # Get service info from service files
    local working_dir
    working_dir=$(get_service_working_dir "$service" 2>/dev/null)
    local compose_file
    compose_file=$(get_service_compose_file "$service" 2>/dev/null)

    if [ "$working_dir" = "null" ] || [ -z "$working_dir" ]; then
        # Fallback: try to get from compose file directory
        if [ -n "$compose_file" ] && [ "$compose_file" != "null" ]; then
            working_dir=$(dirname "$compose_file")
        else
            [ "$DEBUG" = "1" ] && echo "  Debug: No working_directory found for $service"
            # Last-resort fallback: use the host's registry-declared base path
            # (hosts.<machine>.path) so we don't bake a hostname-specific layout
            # like "/Users/<user>/<base>" into this script.
            local _host_base
            _host_base=$(yq eval ".hosts.${machine}.path // \"\"" "${CADDY_REGISTRY_PATH:-${REGISTRY_FILE:-registry.yml}}" 2>/dev/null || true)
            if [ -n "$_host_base" ] && [ "$_host_base" != "null" ]; then
                working_dir="${_host_base}/${service}"
            else
                working_dir="${service}"
            fi
        fi
    fi

    # Get project name from working directory
    local project_name
    project_name=$(basename "$working_dir")
    [ "$DEBUG" = "1" ] && echo "  Debug: project_name=$project_name, working_dir=$working_dir"

    # PHASE 1: GO TO SEE - Find all containers for this service
    echo -n "  🔍 Finding containers... "

    local containers=""

    # METHOD 1: Try docker-compose if compose file exists
    if [ "$compose_file" != "null" ] && [ -n "$compose_file" ]; then
        [ "$DEBUG" = "1" ] && printf '\n  Debug: Trying docker-compose ps with %s\n' "$compose_file"

        if _is_local_machine "$machine"; then
            # Local execution
            if [ -f "$compose_file" ]; then
                local compose_dir
                compose_dir=$(dirname "$compose_file")
                containers=$(cd "$compose_dir" && docker compose ps --format '{{.Names}}' 2>/dev/null)
            fi
        else
            # Remote execution
            containers=$(ssh -o ConnectTimeout=5 "$ssh_user@$machine_ip" \
                "cd '$(dirname "$compose_file")' 2>/dev/null && docker compose ps --format '{{.Names}}' 2>/dev/null")
        fi

        [ "$DEBUG" = "1" ] && echo "  Debug: docker-compose ps found: $(echo "$containers" | wc -l | tr -d ' ') containers"
    fi

    # METHOD 2: Try docker compose labels if Method 1 failed
    if [ -z "$containers" ]; then
        [ "$DEBUG" = "1" ] && printf '\n  Debug: Trying docker labels for project=%s\n' "$project_name"

        if _is_local_machine "$machine"; then
            containers=$(docker ps --filter "label=com.docker.compose.project=$project_name" \
                --format "{{.Names}}" 2>/dev/null)
        else
            containers=$(ssh -o ConnectTimeout=5 "$ssh_user@$machine_ip" \
                "/usr/local/bin/docker ps --filter 'label=com.docker.compose.project=$project_name' --format '{{.Names}}' 2>/dev/null || docker ps --filter 'label=com.docker.compose.project=$project_name' --format '{{.Names}}'")
        fi

        [ "$DEBUG" = "1" ] && echo "  Debug: docker labels found: $(echo "$containers" | wc -l | tr -d ' ') containers"
    fi

    # METHOD 3: Precise prefix matching (fallback)
    if [ -z "$containers" ]; then
        [ "$DEBUG" = "1" ] && printf '\n  Debug: Trying prefix matching\n'

        # Match containers that START with project name or service name
        # Pattern: ^project_name- OR ^service_name-
        local service_dash="${service//_/-}"
        local pattern="^${project_name}[-_]|^${service}[-_]|^${service_dash}[-_]"

        if _is_local_machine "$machine"; then
            containers=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -E "$pattern" || true)
        else
            local all_containers
            if ! all_containers=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$ssh_user@$machine_ip" \
                '/usr/local/bin/docker ps --format "{{.Names}}" 2>/dev/null || docker ps --format "{{.Names}}"' 2>&1); then
                print_color "$RED" "  ✗ Failed to connect to $machine"
                return 1
            fi

            containers=$(echo "$all_containers" | grep -E "$pattern" || true)
        fi

        [ "$DEBUG" = "1" ] && echo "  Debug: prefix matching found: $(echo "$containers" | wc -l | tr -d ' ') containers"
    fi

    if [ -z "$containers" ]; then
        echo "none running"
        return 0
    fi

    # PHASE 2: GRASP THE SITUATION - List what will be stopped
    local container_count
    container_count=$(echo "$containers" | wc -l | tr -d ' ')
    echo "found $container_count"

    if [ "$DEBUG" = "1" ]; then
        echo "  Debug: Container list:"
        while IFS= read -r container; do
            echo "     - [$container]"
        done <<< "$containers"
    fi

    # PHASE 3: GET TO SOLUTION - Stop each container
    echo -n "  🔧 Stopping... "

    local stopped=0
    local failed=0

    while IFS= read -r container; do
        if [ -n "$container" ]; then
            [ "$DEBUG" = "1" ] && printf '\n     Stopping %s...\n' "$container"

            if _is_local_machine "$machine"; then
                # Local
                if docker stop "$container" >/dev/null 2>&1; then
                    stopped=$((stopped + 1))
                    echo -n "."
                    [ "$DEBUG" = "1" ] && echo " (stopped)"
                else
                    # Try force stop
                    if docker kill "$container" >/dev/null 2>&1; then
                        stopped=$((stopped + 1))
                        echo -n "!"
                        [ "$DEBUG" = "1" ] && echo " (killed)"
                    else
                        failed=$((failed + 1))
                        echo -n "✗"
                        [ "$DEBUG" = "1" ] && echo " (failed)"
                    fi
                fi
            else
                # Remote - use full docker path for non-interactive SSH
                # Quote the container name properly for remote execution
                # CRITICAL: Use -n flag to prevent SSH from consuming stdin (would break the while loop)
                # Security: Properly escape container name
                if ssh -n -o ConnectTimeout=3 "$ssh_user@$machine_ip" \
                    "/usr/local/bin/docker stop $(printf '%q' "$container") 2>/dev/null || docker stop $(printf '%q' "$container")" >/dev/null 2>&1; then
                    stopped=$((stopped + 1))
                    echo -n "."
                    [ "$DEBUG" = "1" ] && echo " (stopped)"
                else
                    # Try force stop
                    # Security: Properly escape container name
                    if ssh -n -o ConnectTimeout=3 "$ssh_user@$machine_ip" \
                        "/usr/local/bin/docker kill $(printf '%q' "$container") 2>/dev/null || docker kill $(printf '%q' "$container")" >/dev/null 2>&1; then
                        stopped=$((stopped + 1))
                        echo -n "!"
                        [ "$DEBUG" = "1" ] && echo " (killed)"
                    else
                        failed=$((failed + 1))
                        echo -n "✗"
                        [ "$DEBUG" = "1" ] && echo " (failed)"
                    fi
                fi
            fi
        else
            [ "$DEBUG" = "1" ] && printf '\n     Skipping empty line\n'
        fi
    done <<< "$containers"
    echo ""  # New line after progress dots

    # PHASE 4: VERIFY - Check they're actually stopped
    if [ $failed -eq 0 ]; then
        print_color "$GREEN" "  ✓ Stopped $stopped container(s)"
        return 0
    else
        print_color "$YELLOW" "  ⚠ Stopped $stopped, failed $failed"
        return 1
    fi
}

# Intelligent stop for local (non-Docker) service
# Usage: intelligent_local_stop SERVICE MACHINE
intelligent_local_stop() {
    local service="$1"
    local machine="$2"
    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")
    local machine_ip
    machine_ip=$(get_machine_ip "$machine")

    # PHASE 1: GO TO SEE - Check if PID file exists
    # Construct PID file path for the target machine
    local pid_file
    if _is_local_machine "$machine"; then
        pid_file="$PIDS_DIR/${service}.pid"
    else
        # Remote machine - locate the PID file under the host's
        # registry-declared base path (hosts.<machine>.path/.pids).
        local _remote_base
        _remote_base=$(yq eval ".hosts.${machine}.path // \"\"" "${CADDY_REGISTRY_PATH:-${REGISTRY_FILE:-registry.yml}}" 2>/dev/null || true)
        if [ -z "$_remote_base" ] || [ "$_remote_base" = "null" ]; then
            _remote_base="/home/${ssh_user}"
        fi
        pid_file="${_remote_base}/.pids/${service}.pid"
    fi

    echo -n "  🔍 Checking PID file... "

    local pid=""
    if _is_local_machine "$machine"; then
        if [ -f "$pid_file" ]; then
            pid=$(cat "$pid_file")
        fi
    else
        # Security: Properly quote PID file path
        pid=$(ssh -o ConnectTimeout=3 -o BatchMode=yes "$ssh_user@$machine_ip" \
            "cat $(printf '%q' "$pid_file") 2>/dev/null" 2>/dev/null || true)
    fi

    if [ -z "$pid" ]; then
        echo "not found (not running)"
        return 0
    fi

    echo "found PID $pid"

    # PHASE 2: GRASP THE SITUATION - Check if process is actually running
    echo -n "  📊 Checking process... "

    local is_running=0
    if _is_local_machine "$machine"; then
        if kill -0 "$pid" 2>/dev/null; then
            is_running=1
        fi
    else
        # Security: Validate PID is numeric before use
        if [[ "$pid" =~ ^[0-9]+$ ]] && ssh -o ConnectTimeout=3 -o BatchMode=yes "$ssh_user@$machine_ip" \
            "kill -0 '$pid' 2>/dev/null"; then
            is_running=1
        fi
    fi

    if [ $is_running -eq 0 ]; then
        echo "stale (cleaning up)"
        # Clean up stale PID file
        if _is_local_machine "$machine"; then
            rm -f "$pid_file"
        else
            # Security: Properly quote PID file path
            ssh -o ConnectTimeout=3 -o BatchMode=yes "$ssh_user@$machine_ip" \
                "rm -f $(printf '%q' "$pid_file")" 2>/dev/null
        fi
        print_color "$GREEN" "  ✓ Cleaned up stale PID file"
        return 0
    fi

    echo "running"

    # PHASE 3: GET TO SOLUTION - Stop the process
    echo -n "  🔧 Stopping... "

    if _is_local_machine "$machine"; then
        # Graceful stop - verify PID exists first
        if ps -p "$pid" >/dev/null 2>&1; then
            if kill -TERM "$pid" 2>/dev/null; then
                # Wait for graceful shutdown
                local count=0
                while ps -p "$pid" >/dev/null 2>&1 && [ $count -lt 5 ]; do
                    sleep 1
                    count=$((count + 1))
                done

                # Check if stopped
                if ! ps -p "$pid" >/dev/null 2>&1; then
                    rm -f "$pid_file"
                    echo "done"
                    print_color "$GREEN" "  ✓ Stopped gracefully"
                    return 0
                else
                    # Force kill - verify still exists
                    if ps -p "$pid" >/dev/null 2>&1; then
                        kill -9 "$pid" 2>/dev/null
                    fi
                    rm -f "$pid_file"
                    echo "force stopped"
                    print_color "$GREEN" "  ✓ Force stopped"
                    return 0
                fi
            else
                echo "failed"
                print_color "$RED" "  ✗ Failed to stop"
                return 1
            fi
        else
            echo "process disappeared"
            rm -f "$pid_file"
            return 0
        fi
    else
        # Remote - verify PID exists first
        # Security: Validate PID is numeric before use
        if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
            echo "invalid PID"
            print_color "$RED" "  ✗ Invalid PID format"
            return 1
        fi

        if ssh -o ConnectTimeout=3 -o BatchMode=yes "$ssh_user@$machine_ip" \
            "ps -p '$pid' >/dev/null 2>&1"; then
            if ssh -o ConnectTimeout=3 -o BatchMode=yes "$ssh_user@$machine_ip" \
                "kill -TERM '$pid' 2>/dev/null"; then
                # Wait for graceful shutdown
                local count=0
                while [ $count -lt 5 ]; do
                    if ! ssh -o ConnectTimeout=3 -o BatchMode=yes "$ssh_user@$machine_ip" \
                        "ps -p '$pid' >/dev/null 2>&1"; then
                        break
                    fi
                    sleep 1
                    count=$((count + 1))
                done

                # Check if stopped
                if ! ssh -o ConnectTimeout=3 -o BatchMode=yes "$ssh_user@$machine_ip" \
                    "ps -p '$pid' >/dev/null 2>&1"; then
                    # Security: Properly quote PID file path
                    ssh -o ConnectTimeout=3 -o BatchMode=yes "$ssh_user@$machine_ip" \
                        "rm -f $(printf '%q' "$pid_file")" 2>/dev/null
                    echo "done"
                    print_color "$GREEN" "  ✓ Stopped gracefully"
                    return 0
                else
                    # Force kill - verify still exists
                    if ssh -o ConnectTimeout=3 -o BatchMode=yes "$ssh_user@$machine_ip" \
                        "ps -p '$pid' >/dev/null 2>&1"; then
                        ssh -o ConnectTimeout=3 -o BatchMode=yes "$ssh_user@$machine_ip" \
                            "kill -9 '$pid' 2>/dev/null"
                    fi
                    # Security: Properly quote PID file path
                    ssh -o ConnectTimeout=3 -o BatchMode=yes "$ssh_user@$machine_ip" \
                        "rm -f $(printf '%q' "$pid_file")" 2>/dev/null
                    echo "force stopped"
                    print_color "$GREEN" "  ✓ Force stopped"
                    return 0
                fi
            else
                echo "failed"
                print_color "$RED" "  ✗ Failed to stop"
                return 1
            fi
        else
            echo "process disappeared"
            # Security: Properly quote PID file path
            ssh -o ConnectTimeout=3 -o BatchMode=yes "$ssh_user@$machine_ip" \
                "rm -f $(printf '%q' "$pid_file")" 2>/dev/null
            return 0
        fi
    fi
}

# Main intelligent stop dispatcher
# Usage: intelligent_stop_service SERVICE MACHINE
intelligent_stop_service() {
    local service="$1"
    local machine="$2"
    local service_type
    service_type=$(get_service_type "$service" 2>/dev/null)

    if [ -z "$service_type" ]; then
        print_color "$RED" "Error: Service '$service' not found in registry"
        return 1
    fi

    local stop_result=0
    if [ "$service_type" = "docker" ]; then
        intelligent_docker_stop "$service" "$machine"
        stop_result=$?
    else
        intelligent_local_stop "$service" "$machine"
        stop_result=$?
    fi

    # Record uptime tracking event
    if command -v record_service_stop >/dev/null 2>&1; then
        record_service_stop "$service" "$machine" "$stop_result" "manual_stop"
    fi

    return $stop_result
}
