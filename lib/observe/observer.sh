#!/usr/bin/env bash
# observer.sh - GO TO SEE
# Proactively observe and collect facts about the system state
# Part of Toyota Engagement Equation implementation

set -euo pipefail

# Cleanup background jobs on exit (only when any exist).
_observer_cleanup_jobs() {
    local pids
    pids=$(jobs -p)
    if [ -n "$pids" ]; then
        # shellcheck disable=SC2086 # word-split intentional: pids is space-separated
        kill $pids 2>/dev/null || true
    fi
}
trap _observer_cleanup_jobs EXIT INT TERM

# Initialize global variables
DEBUG="${DEBUG:-0}"
PIDS_DIR="${PIDS_DIR:-$HOME/.portoser/pids}"

# Observation storage
OBSERVATIONS_DIR="${OBSERVATIONS_DIR:-$HOME/.portoser/observations}"
mkdir -p "$OBSERVATIONS_DIR"

# Color codes (only set if not already defined as readonly by utils.sh)
if ! readonly -p | grep -q "^declare -[[:alpha:]]*r[[:alpha:]]* BLUE="; then
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    GRAY='\033[0;90m'
    NC='\033[0m'
else
    # Variables are readonly, add GRAY which utils.sh doesn't define
    GRAY='\033[0;90m'
fi

# Observation result structure
declare -A OBSERVATION_RESULTS

# Print observation message
observe_print() {
    local level="$1"
    shift
    case "$level" in
        INFO)
            echo -e "${BLUE}🔍 $*${NC}" >&2
            ;;
        SUCCESS)
            echo -e "${GREEN}   ✓ $*${NC}" >&2
            ;;
        WARNING)
            echo -e "${YELLOW}   ⚠ $*${NC}" >&2
            ;;
        ERROR)
            echo -e "${RED}   ✗ $*${NC}" >&2
            ;;
        DEBUG)
            if [ "$DEBUG" = "1" ]; then
                echo -e "${GRAY}   → $*${NC}" >&2
            fi
            ;;
    esac
}

# Record observation (fact)
# Usage: record_observation "check_name" "check_status" "value" "message"
record_observation() {
    local check_name="$1"
    local check_status="$2"      # OK, WARNING, ERROR, UNKNOWN
    local value="$3"       # The actual observed value
    local message="$4"     # Human-readable message

    OBSERVATION_RESULTS[$check_name]="$check_status|$value|$message"

    # Also log to file for history
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp|$check_name|$check_status|$value|$message" >> "$OBSERVATIONS_DIR/observations.log"
}

# Get observation result
# Usage: get_observation "check_name"
# Returns: status|value|message
get_observation() {
    local check_name="$1"
    echo "${OBSERVATION_RESULTS[$check_name]}"
}

# Check SSH connectivity to a machine
# Usage: observe_ssh_connectivity MACHINE
observe_ssh_connectivity() {
    local machine="$1"

    observe_print DEBUG "Checking SSH to $machine..."

    # Get machine IP from registry (for display purposes)
    local machine_ip
    machine_ip=$(get_machine_ip "$machine" 2>/dev/null)
    if [ -z "$machine_ip" ]; then
        machine_ip="unknown"
    fi

    # Try SSH connection using SSH config (hostname only, user/key from config)
    # This relies on ~/.ssh/config having the correct configuration
    # BatchMode=yes ensures no interactive prompts (host key verification relies on known_hosts)
    if timeout 3 ssh -o ConnectTimeout=2 -o BatchMode=yes \
        "$machine" "exit 0" >/dev/null 2>&1; then
        record_observation "ssh_$machine" "OK" "connected" "SSH connection successful"
        observe_print SUCCESS "SSH to $machine ($machine_ip): Connected"
        return 0
    else
        local exit_code=$?
        record_observation "ssh_$machine" "ERROR" "failed:$exit_code" "SSH connection failed"
        observe_print ERROR "SSH to $machine ($machine_ip): Failed (exit $exit_code)"
        return 1
    fi
}

# Check if Docker is running on a machine
# Usage: observe_docker_status MACHINE
observe_docker_status() {
    local machine="$1"
    # SSH_USER not needed - use SSH config instead
    local machine_ip
    machine_ip=$(get_machine_ip "$machine" 2>/dev/null)

    observe_print DEBUG "Checking Docker daemon on $machine..."

    if [ -z "$machine_ip" ]; then
        record_observation "docker_$machine" "ERROR" "no_ip" "Machine IP not found"
        return 1
    fi

    # Check if Docker is running. BatchMode prevents hangs on auth prompts;
    # the outer timeout bounds wallclock so a stuck dockerd can't stall diagnose.
    local docker_status
    docker_status=$(timeout 8 ssh -o ConnectTimeout=3 -o BatchMode=yes "$machine" \
        "docker info >/dev/null 2>&1 && echo 'running' || echo 'not_running'" 2>/dev/null)

    # Validate result
    if [ -z "$docker_status" ]; then
        docker_status="unknown"
    fi

    if [ "$docker_status" = "running" ]; then
        record_observation "docker_$machine" "OK" "running" "Docker daemon is running"
        observe_print SUCCESS "Docker on $machine: Running"
        return 0
    else
        record_observation "docker_$machine" "ERROR" "not_running" "Docker daemon not running"
        observe_print ERROR "Docker on $machine: Not running"
        return 1
    fi
}

# Check docker/compose prerequisites and context reachability on target
observe_target_prereqs() {
    local machine="$1"
    local ssh_host
    ssh_host=$(get_ssh_host "$machine" 2>/dev/null)
    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine" 2>/dev/null)
    local context
    context=$(get_machine_context "$machine" 2>/dev/null || echo "ctx-${machine}")
    local expected_arch
    expected_arch=$(get_machine_arch "$machine" 2>/dev/null || echo "")

    if [ -z "$ssh_host" ] || [ -z "$ssh_user" ]; then
        record_observation "prereq_$machine" "ERROR" "missing_ssh" "Cannot resolve SSH info for $machine"
        observe_print ERROR "Prereq: Missing SSH info for $machine"
        return 1
    fi

    if timeout 8 ssh -o ConnectTimeout=3 -o BatchMode=yes "${ssh_user}@${ssh_host}" "command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1"; then
        observe_print SUCCESS "Prereq: Docker + Compose present on $machine"
    else
        record_observation "prereq_$machine" "ERROR" "missing_docker" "Docker/Compose not available"
        observe_print ERROR "Prereq: Docker/Compose missing on $machine"
        return 1
    fi

    # Confirm architecture matches registry expectations
    if [ -n "$expected_arch" ] && [ "$expected_arch" != "null" ]; then
        local actual_arch
        actual_arch=$(timeout 5 ssh -o ConnectTimeout=3 -o BatchMode=yes "${ssh_user}@${ssh_host}" "uname -m" 2>/dev/null || echo "")
        if [ -n "$actual_arch" ]; then
            if [[ "$expected_arch" =~ arm64 ]] && [[ "$actual_arch" != "arm64" && "$actual_arch" != "aarch64" ]]; then
                record_observation "prereq_$machine" "ERROR" "arch_mismatch" "Expected $expected_arch but found $actual_arch"
                observe_print ERROR "Prereq: Arch mismatch (expected $expected_arch, got $actual_arch)"
                return 1
            fi
            if [[ "$expected_arch" =~ amd64 ]] && [[ "$actual_arch" =~ arm64|aarch64 ]]; then
                record_observation "prereq_$machine" "ERROR" "arch_mismatch" "Expected $expected_arch but found $actual_arch"
                observe_print ERROR "Prereq: Arch mismatch (expected $expected_arch, got $actual_arch)"
                return 1
            fi
        fi
    fi

    # If the controller box has no local docker CLI we can't and shouldn't
    # build a context for it - the SSH-driven docker compose path takes
    # over. Skip the check silently so we don't flag a phantom prereq error.
    if ! command -v docker >/dev/null 2>&1; then
        record_observation "prereq_$machine" "OK" "no_local_docker" "Local docker CLI absent; using SSH-driven compose"
        return 0
    fi

    if ensure_docker_context "$context" "$machine" >/dev/null 2>&1 \
        && docker --context "$context" ps >/dev/null 2>&1; then
        record_observation "prereq_$machine" "OK" "$context" "Context reachable"
        observe_print SUCCESS "Prereq: Docker context '$context' reachable"
        return 0
    else
        record_observation "prereq_$machine" "ERROR" "context_failed" "Docker context unreachable"
        observe_print ERROR "Prereq: Docker context '$context' unreachable"
        return 1
    fi
}

# Check if a port is available on a machine
# Usage: observe_port_availability MACHINE PORT
observe_port_availability() {
    local machine="$1"
    local port="$2"
    # SSH_USER not needed - use SSH config instead
    local machine_ip
    machine_ip=$(get_machine_ip "$machine" 2>/dev/null)

    observe_print DEBUG "Checking port $port availability on $machine..."

    if [ -z "$machine_ip" ]; then
        record_observation "port_${machine}_${port}" "ERROR" "no_ip" "Machine IP not found"
        return 1
    fi

    # Check if port is in use. Prefer `ss` (reliable on every distro we
    # target including the busybox-based demo fakehosts where lsof's `-t`
    # short-form output is unreliable). Fall back to lsof, but discard
    # anything that isn't a bare PID so a misbehaving lsof can't leak FD
    # tables into the observation record.
    local port_check
    port_check=$(timeout 8 ssh -o ConnectTimeout=3 -o BatchMode=yes "$machine" "
        if command -v ss >/dev/null 2>&1; then
            pid=\$(ss -tlnpH 2>/dev/null | awk -v p=$port '\$4 ~ \":\"p\"\$\" {print \$0}' \
                | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
            if [ -n \"\$pid\" ]; then echo \"\$pid\"; else echo 'available'; fi
        elif command -v lsof >/dev/null 2>&1; then
            pid=\$(lsof -i :$port -t 2>/dev/null | grep -E '^[0-9]+\$' | head -1)
            if [ -n \"\$pid\" ]; then echo \"\$pid\"; else echo 'available'; fi
        else
            echo 'available'
        fi
    " 2>/dev/null)

    if [ "$port_check" = "available" ] || [ -z "$port_check" ]; then
        record_observation "port_${machine}_${port}" "OK" "available" "Port is available"
        observe_print SUCCESS "Port $port on $machine: Available"
        return 0
    else
        record_observation "port_${machine}_${port}" "ERROR" "in_use:$port_check" "Port in use by PID $port_check"
        observe_print ERROR "Port $port on $machine: In use (PID $port_check)"
        return 1
    fi
}

# Check disk space on a machine
# Usage: observe_disk_space MACHINE [THRESHOLD_PERCENT]
observe_disk_space() {
    local machine="$1"
    local threshold="${2:-90}"  # Default 90% threshold
    # SSH_USER not needed - use SSH config instead
    local machine_ip
    machine_ip=$(get_machine_ip "$machine" 2>/dev/null)

    observe_print DEBUG "Checking disk space on $machine..."

    if [ -z "$machine_ip" ]; then
        record_observation "disk_$machine" "ERROR" "no_ip" "Machine IP not found"
        return 1
    fi

    # Get disk usage percentage for root filesystem
    local disk_usage
    disk_usage=$(timeout 6 ssh -o ConnectTimeout=3 -o BatchMode=yes "$machine" \
        "df -h / | tail -1 | awk '{print \$5}' | sed 's/%//'" 2>/dev/null)

    # Validate numeric value
    if [ -n "$disk_usage" ] && [[ "$disk_usage" =~ ^[0-9]+$ ]]; then
        if [ "$disk_usage" -ge "$threshold" ]; then
            record_observation "disk_$machine" "WARNING" "${disk_usage}%" "Disk usage above threshold ($threshold%)"
            observe_print WARNING "Disk space on $machine: ${disk_usage}% (threshold: $threshold%)"
            return 1
        else
            record_observation "disk_$machine" "OK" "${disk_usage}%" "Disk usage healthy"
            observe_print SUCCESS "Disk space on $machine: ${disk_usage}% (healthy)"
            return 0
        fi
    else
        record_observation "disk_$machine" "ERROR" "unknown" "Could not determine disk usage"
        observe_print ERROR "Disk space on $machine: Unknown"
        return 1
    fi
}

# Check service health (actual running state)
# Usage: observe_service_health SERVICE
observe_service_health() {
    local service="$1"

    observe_print DEBUG "Checking health of $service..."

    # Use existing health check from health.sh. We previously also fetched
    # the health URL here for inclusion in the observation but never threaded
    # it through, so the lookup has been removed.
    if check_service_health "$service" 1 >/dev/null 2>&1; then
        record_observation "health_$service" "OK" "healthy" "Service responding to health checks"
        observe_print SUCCESS "Service $service: Healthy"
        return 0
    else
        record_observation "health_$service" "ERROR" "unhealthy" "Service not responding"
        observe_print ERROR "Service $service: Unhealthy/Not responding"
        return 1
    fi
}

# Check if service process is actually running
# Usage: observe_service_process SERVICE MACHINE
observe_service_process() {
    local service="$1"
    local machine="$2"
    # SSH_USER not needed - use SSH config instead
    local machine_ip
    machine_ip=$(get_machine_ip "$machine" 2>/dev/null)
    local service_type
    service_type=$(get_service_type "$service" 2>/dev/null)

    observe_print DEBUG "Checking if $service process is running on $machine..."

    if [ -z "$machine_ip" ]; then
        record_observation "process_${service}" "ERROR" "no_ip" "Machine IP not found"
        return 1
    fi

    if [ "$service_type" = "docker" ]; then
        # Check Docker container status
        local container_status
        container_status=$(timeout 8 ssh -o ConnectTimeout=3 -o BatchMode=yes "$machine" \
            "docker ps --filter name=$service --format '{{.Status}}' 2>/dev/null" 2>/dev/null)

        if [ -n "$container_status" ]; then
            record_observation "process_${service}" "OK" "running" "Container running: $container_status"
            observe_print SUCCESS "Process $service on $machine: Running ($container_status)"
            return 0
        else
            record_observation "process_${service}" "ERROR" "not_running" "Container not found"
            observe_print ERROR "Process $service on $machine: Not running"
            return 1
        fi
    else
        # Check local process via PID file
        local pid_file="$PIDS_DIR/${service}.pid"
        if [ -f "$pid_file" ]; then
            local pid
            pid=$(cat "$pid_file")
            if timeout 5 ssh -o ConnectTimeout=3 -o BatchMode=yes "$machine" "kill -0 $pid 2>/dev/null"; then
                record_observation "process_${service}" "OK" "running:$pid" "Process running"
                observe_print SUCCESS "Process $service on $machine: Running (PID $pid)"
                return 0
            else
                record_observation "process_${service}" "WARNING" "stale_pid:$pid" "PID file exists but process not running"
                observe_print WARNING "Process $service on $machine: Stale PID file ($pid)"
                return 1
            fi
        else
            record_observation "process_${service}" "ERROR" "no_pid" "No PID file found"
            observe_print ERROR "Process $service on $machine: No PID file"
            return 1
        fi
    fi
}

# Check service dependencies
# Usage: observe_dependencies SERVICE
observe_dependencies() {
    local service="$1"
    local dependencies
    dependencies=$(get_service_dependencies "$service" 2>/dev/null)

    observe_print DEBUG "Checking dependencies for $service..."

    if [ -z "$dependencies" ]; then
        record_observation "deps_$service" "OK" "none" "No dependencies"
        observe_print SUCCESS "Dependencies for $service: None"
        return 0
    fi

    local all_healthy=0
    local unhealthy_deps=""

    while IFS= read -r dep; do
        if [ -n "$dep" ]; then
            if check_service_health "$dep" 1 >/dev/null 2>&1; then
                observe_print SUCCESS "Dependency $dep: Healthy"
            else
                all_healthy=1
                unhealthy_deps="$unhealthy_deps $dep"
                observe_print ERROR "Dependency $dep: Unhealthy"
            fi
        fi
    done <<< "$dependencies"

    if [ $all_healthy -eq 0 ]; then
        record_observation "deps_$service" "OK" "all_healthy" "All dependencies healthy"
        return 0
    else
        record_observation "deps_$service" "ERROR" "unhealthy:$unhealthy_deps" "Some dependencies unhealthy"
        return 1
    fi
}

# Comprehensive observation for deployment readiness
# Usage: observe_deployment_readiness SERVICE TARGET_MACHINE
observe_deployment_readiness() {
    local service="$1"
    local target_machine="$2"
    local port
    port=$(get_service_port "$service" 2>/dev/null)
    local service_type
    service_type=$(get_service_type "$service" 2>/dev/null)

    observe_print INFO "Observing deployment readiness for $service on $target_machine..."
    echo ""

    local checks_passed=0
    local checks_failed=0

    # 1. SSH connectivity
    local ssh_reachable=1
    if observe_ssh_connectivity "$target_machine"; then
        checks_passed=$((checks_passed + 1))
    else
        checks_failed=$((checks_failed + 1))
        ssh_reachable=0
    fi

    # If SSH is dead, every remote probe below will fail the same way and waste
    # ~8s each. Record them as skipped and move on; the SSH failure is the root
    # cause and that's what diagnose should surface.
    if [ "$ssh_reachable" -eq 1 ]; then
        # 2. Docker status (if Docker service)
        if [ "$service_type" = "docker" ]; then
            if observe_docker_status "$target_machine"; then
                checks_passed=$((checks_passed + 1))
            else
                checks_failed=$((checks_failed + 1))
            fi

            if observe_target_prereqs "$target_machine"; then
                checks_passed=$((checks_passed + 1))
            else
                checks_failed=$((checks_failed + 1))
            fi
        fi

        # 3. Port availability
        if [ -n "$port" ]; then
            if observe_port_availability "$target_machine" "$port"; then
                checks_passed=$((checks_passed + 1))
            else
                checks_failed=$((checks_failed + 1))
            fi
        fi

        # 4. Disk space
        if observe_disk_space "$target_machine" 90; then
            checks_passed=$((checks_passed + 1))
        else
            checks_failed=$((checks_failed + 1))
        fi
    else
        observe_print WARNING "Skipping remote probes (Docker, port, disk) because SSH is unreachable"
        if [ "$service_type" = "docker" ]; then
            record_observation "docker_$target_machine" "SKIPPED" "ssh_unreachable" "Skipped: SSH to $target_machine failed"
            record_observation "prereq_$target_machine" "SKIPPED" "ssh_unreachable" "Skipped: SSH to $target_machine failed"
        fi
        if [ -n "$port" ]; then
            record_observation "port_${target_machine}_${port}" "SKIPPED" "ssh_unreachable" "Skipped: SSH to $target_machine failed"
        fi
        record_observation "disk_$target_machine" "SKIPPED" "ssh_unreachable" "Skipped: SSH to $target_machine failed"
    fi

    # 5. Dependencies
    if observe_dependencies "$service"; then
        checks_passed=$((checks_passed + 1))
    else
        checks_failed=$((checks_failed + 1))
    fi

    echo ""

    # Save observation snapshot
    local snapshot_file
    snapshot_file="$OBSERVATIONS_DIR/${service}_${target_machine}_$(date +%s).json"
    save_observation_snapshot "$snapshot_file"

    if [ $checks_failed -eq 0 ]; then
        observe_print INFO "Observation complete: ${GREEN}All checks passed ($checks_passed)${NC}"
        return 0
    else
        observe_print INFO "Observation complete: ${YELLOW}$checks_failed issues detected${NC} ($checks_passed passed)"
        return 1
    fi
}

# Save current observations to JSON snapshot
# Usage: save_observation_snapshot FILENAME
save_observation_snapshot() {
    local filename="$1"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    echo "{" > "$filename"
    echo "  \"timestamp\": \"$timestamp\"," >> "$filename"
    echo "  \"observations\": {" >> "$filename"

    local first=1
    for check_name in "${!OBSERVATION_RESULTS[@]}"; do
        local result="${OBSERVATION_RESULTS[$check_name]}"
        local check_status="${result%%|*}"
        local rest="${result#*|}"
        local value="${rest%%|*}"
        local message="${rest#*|}"

        if [ $first -eq 0 ]; then
            echo "," >> "$filename"
        fi
        first=0

        {
            echo -n "    \"$check_name\": {"
            echo -n "\"status\": \"$check_status\", "
            echo -n "\"value\": \"$value\", "
            echo -n "\"message\": \"$message\"}"
        } >> "$filename"
    done

    {
        echo ""
        echo "  }"
        echo "}"
    } >> "$filename"

    observe_print DEBUG "Observation snapshot saved: $filename"
}

# Export functions for use by other scripts
# (no-op in zsh, just documenting available functions)
