#!/usr/bin/env bash
# disk_space_cleanup.sh - Solution pattern for low disk space

set -euo pipefail
# Handles situations where disk space is running low

solve_disk_space_cleanup() {
    local problem_data="$1"

    # Parse problem data: KEY|STATUS|VALUE|MESSAGE. Only key + value are
    # consulted by this pattern.
    local obs_key="${problem_data%%|*}"
    local rest="${problem_data#*|}"
    rest="${rest#*|}"  # Skip status
    local value="${rest%%|*}"

    # Extract machine name: disk_MACHINE
    local machine="${obs_key#disk_}"

    # Extract disk usage percentage
    local disk_usage="${value%\%}"

    solve_print ACTION "Freeing disk space on $machine (current: ${disk_usage}%)"

    local machine_ip
    machine_ip=$(get_machine_ip "$machine" 2>/dev/null)

    if [ -z "$machine_ip" ]; then
        solve_print FAILED "Cannot get IP for machine: $machine"
        return 1
    fi

    # 1. Clean up old logs (older than 7 days)
    solve_print ACTION "Cleaning old logs (>7 days)..."
    local logs_freed
    logs_freed=$(ssh -o ConnectTimeout=3 "$machine" \
        "find /var/log -type f -name '*.log.*' -mtime +7 -exec rm -f {} \; 2>/dev/null; \
         find $LOGS_DIR -type f -name '*.log.*' -mtime +7 -exec rm -f {} \; 2>/dev/null; \
         echo 'done'" 2>/dev/null)

    if [ -n "$logs_freed" ]; then
        solve_print SUCCESS "Old logs cleaned"
    fi

    # 2. Clean Docker if available
    local docker_status
    docker_status=$(ssh -o ConnectTimeout=3 "$machine" \
        "docker info >/dev/null 2>&1 && echo 'running' || echo 'not_running'" 2>/dev/null)

    if [ "$docker_status" = "running" ]; then
        solve_print ACTION "Cleaning Docker resources..."

        # Remove stopped containers
        ssh -o ConnectTimeout=3 "$machine" \
            "docker container prune -f 2>/dev/null" >/dev/null 2>&1

        # Remove dangling images
        ssh -o ConnectTimeout=3 "$machine" \
            "docker image prune -f 2>/dev/null" >/dev/null 2>&1

        # Remove unused volumes (be careful!)
        ssh -o ConnectTimeout=3 "$machine" \
            "docker volume prune -f 2>/dev/null" >/dev/null 2>&1

        solve_print SUCCESS "Docker cleanup complete"
    fi

    # 3. Clean package manager caches
    local os_type
    os_type=$(ssh -o ConnectTimeout=3 "$machine" \
        "uname -s" 2>/dev/null)

    case "$os_type" in
        Darwin)
            solve_print ACTION "Cleaning Homebrew cache..."
            ssh -o ConnectTimeout=3 "$machine" \
                "brew cleanup 2>/dev/null" >/dev/null 2>&1
            ;;
        Linux)
            solve_print ACTION "Cleaning APT cache..."
            ssh -o ConnectTimeout=3 "$machine" \
                "sudo apt-get clean 2>/dev/null || sudo yum clean all 2>/dev/null" >/dev/null 2>&1
            ;;
    esac

    # 4. Clean temporary files
    solve_print ACTION "Cleaning temporary files..."
    ssh -o ConnectTimeout=3 "$machine" \
        "find /tmp -type f -mtime +3 -exec rm -f {} \; 2>/dev/null" >/dev/null 2>&1

    # 5. Truncate large log files (>100MB)
    solve_print ACTION "Truncating large log files..."
    ssh -o ConnectTimeout=3 "$machine" \
        "find $LOGS_DIR -type f -size +100M -exec sh -c 'tail -1000 \"\$1\" > \"\$1.tmp\" && mv \"\$1.tmp\" \"\$1\"' _ {} \; 2>/dev/null" >/dev/null 2>&1

    # Check new disk usage
    sleep 1
    local new_usage
    new_usage=$(ssh -o ConnectTimeout=3 "$machine" \
        "df -h / | tail -1 | awk '{print \$5}' | sed 's/%//'" 2>/dev/null)

    if [ -n "$new_usage" ]; then
        local freed
        freed=$((disk_usage - new_usage))
        solve_print SUCCESS "Disk space reduced from ${disk_usage}% to ${new_usage}% (freed ${freed}%)"

        if [ "$new_usage" -lt 85 ]; then
            solve_print SUCCESS "Disk space now healthy"
            return 0
        else
            solve_print WARNING "Disk space still above 85% - may need manual cleanup"
            return 1
        fi
    else
        solve_print WARNING "Could not verify new disk usage"
        return 1
    fi
}
