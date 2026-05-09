#!/usr/bin/env bash
# =============================================================================
# Service Verification & Error Propagation Module
# =============================================================================
#
# Container verification + error propagation for cluster-compose scripts.
#
# What this provides:
# 1. verify_containers_running() - parses `docker ps` output into a status map
# 2. manage_* functions return proper exit codes
# 3. Main loop checks return codes and tracks failures
# 4. FAILED_SERVICES array tracks all types of failures
# 5. Error messages identify which services failed
#
# Usage:
#   Source this file from cluster-compose.sh to use these implementations.
#
# =============================================================================

# Global array to track all service failures across all types
declare -g -a FAILED_SERVICES=()

# =============================================================================
# CONTAINER VERIFICATION - FIXED IMPLEMENTATION
# =============================================================================

# Verify that containers are actually running after deployment
# Returns: 0 if all containers running/healthy, 1 if any issues
#
# Parameters:
#   $1 - host: The hostname where containers are running
#   $2 - service_name: Name of the service for error messages
#   $3 - compose_path: Full path to docker-compose.yml directory
#
# Container status patterns matched:
#   - "Up" (standard running state)
#   - "running" (compose v2 format)
#   - "healthy" (if healthcheck defined)
#
verify_containers_running() {
    local host="$1"
    local service_name="$2"
    local compose_path="$3"

    echo "  Verifying containers are running..."

    # Get list of containers from docker compose ps with name and status
    # Format: "container_name:Status description"
    local check_cmd="cd '$compose_path' && docker compose ps --format '{{.Name}}:{{.Status}}'"
    local container_status
    container_status=$(run_on_host "$host" "$check_cmd" 2>/dev/null)

    # Check if we got any output
    if [ -z "$container_status" ]; then
        echo "  ✗ Warning: No containers found for $service_name"
        echo "    This could mean:"
        echo "      - docker compose up failed silently"
        echo "      - No services defined in docker-compose.yml"
        echo "      - Containers exited immediately after start"
        return 1
    fi

    # Parse and validate each container's status
    local all_running=true
    local container_count=0
    local running_count=0

    while IFS=: read -r container status; do
        # Skip empty lines
        [ -z "$container" ] && continue

        container_count=$((container_count + 1))

        # Check if status indicates container is running
        # Match patterns: "Up", "running", "Up X seconds", "Up (healthy)", etc.
        if [[ "$status" =~ Up|running|healthy ]]; then
            echo "    ✓ $container: $status"
            running_count=$((running_count + 1))
        else
            echo "    ✗ $container: $status"
            all_running=false
        fi
    done <<< "$container_status"

    # Summary of verification
    echo "    Containers: $running_count/$container_count running"

    if [ "$all_running" = true ] && [ $container_count -gt 0 ]; then
        return 0
    else
        if [ $container_count -eq 0 ]; then
            echo "  ✗ No containers to verify"
        else
            echo "  ✗ Not all containers are running"
            echo "    Check logs: ssh $host 'cd $compose_path && docker compose logs'"
        fi
        return 1
    fi
}

# =============================================================================
# GENERIC SERVICE HEALTH CHECKER
# =============================================================================

# Generic health verification for any service type
# Returns: 0 if healthy, 1 if unhealthy
#
# Parameters:
#   $1 - service_name: Name of service being checked
#   $2 - service_type: Type (docker, native, local)
#   $3 - host: Hostname where service runs
#   $4 - health_check_cmd: Optional custom health check command
#
verify_service_health() {
    local service_name="$1"
    local service_type="$2"
    local host="$3"
    local health_check_cmd="${4:-}"

    echo "  Running health verification for $service_name ($service_type)..."

    # If custom health check provided, use it
    if [ -n "$health_check_cmd" ]; then
        local timed_health="timeout 10 bash -c '$health_check_cmd'"
        if run_on_host "$host" "$timed_health" > /dev/null 2>&1; then
            echo "    ✓ Health check passed"
            return 0
        else
            echo "    ✗ Health check failed"
            return 1
        fi
    fi

    # Default health checks based on service type
    case "$service_type" in
        docker)
            # For docker services, container status is the health check
            echo "    ℹ Using container status as health indicator"
            return 0
            ;;
        native|local)
            # For native/local services, assume healthy if we got here
            # (actual health checks happen in manage_local_service)
            echo "    ℹ Service started successfully"
            return 0
            ;;
        *)
            echo "    ⚠ Unknown service type, cannot verify health"
            return 1
            ;;
    esac
}

# =============================================================================
# SERVICE FAILURE TRACKING
# =============================================================================

# Track a service failure in the global FAILED_SERVICES array
# Prevents duplicates and provides detailed error context
#
# Parameters:
#   $1 - service_name: Name of the failed service
#   $2 - reason: Reason for failure
#   $3 - service_type: Type of service (docker, native, local)
#   $4 - host: Host where failure occurred
#
track_service_failure() {
    local service_name="$1"
    local reason="$2"
    local service_type="${3:-unknown}"
    local host="${4:-unknown}"

    # Create failure entry with metadata
    local failure_entry="${service_name}|${service_type}|${host}|${reason}"

    # Check if this exact failure already tracked (avoid duplicates)
    local already_tracked=false
    for existing_failure in "${FAILED_SERVICES[@]}"; do
        if [ "$existing_failure" = "$failure_entry" ]; then
            already_tracked=true
            break
        fi
    done

    if [ "$already_tracked" = false ]; then
        FAILED_SERVICES+=("$failure_entry")
        echo "  ⚠️  Tracked failure: $service_name on $host - $reason"
    fi
}

# Report all failed services at the end of execution
# Displays a formatted summary of all failures
#
# Returns: 1 if any failures exist, 0 if none
#
report_failed_services() {
    if [ ${#FAILED_SERVICES[@]} -eq 0 ]; then
        return 0
    fi

    echo ""
    echo "=========================================="
    echo "⚠️  FAILED SERVICES SUMMARY"
    echo "=========================================="
    echo ""
    echo "The following services encountered errors:"
    echo ""

    local failure_num=1
    for failure in "${FAILED_SERVICES[@]}"; do
        # Parse failure entry: service|type|host|reason
        IFS='|' read -r svc_name svc_type svc_host svc_reason <<< "$failure"

        echo "  $failure_num. $svc_name"
        echo "     Type: $svc_type"
        echo "     Host: $svc_host"
        echo "     Reason: $svc_reason"
        echo ""

        failure_num=$((failure_num + 1))
    done

    echo "Total failures: ${#FAILED_SERVICES[@]}"
    echo ""

    return 1
}

# =============================================================================
# DOCKER SERVICE MANAGEMENT - WITH PROPER RETURN CODES
# =============================================================================

# Manage Docker-based services with complete error handling
# Returns: 0 on success, 1 on failure
#
# This function properly:
# - Checks all command return codes
# - Verifies containers are actually running
# - Tracks failures in FAILED_SERVICES array
# - Provides detailed error messages
#
manage_docker_service() {
    local host="$1"
    local service_path="$2"
    local service_name="$3"
    local action="$4"

    local base_path="${BASE_PATHS[$host]}"
    local full_path
    full_path="${base_path}$(dirname "$service_path")"

    echo "  [$host] Managing docker service: $service_name"

    # Build appropriate docker compose command
    local compose_cmd=""
    case $action in
        start)
            if [ "${REBUILD_NOCACHE:-false}" = true ]; then
                compose_cmd="mkdir -p '$full_path' && cd '$full_path' && docker compose build --no-cache && docker compose up -d"
            else
                compose_cmd="mkdir -p '$full_path' && cd '$full_path' && docker compose up -d"
            fi
            ;;
        restart)
            if [ "${REBUILD_NOCACHE:-false}" = true ]; then
                compose_cmd="mkdir -p '$full_path' && cd '$full_path' && docker compose down --volumes --remove-orphans && docker compose build --no-cache && docker compose up -d"
            else
                compose_cmd="mkdir -p '$full_path' && cd '$full_path' && docker compose down --volumes --remove-orphans && docker compose up -d"
            fi
            ;;
        shutdown)
            compose_cmd="mkdir -p '$full_path' && cd '$full_path' && docker compose down --volumes --remove-orphans"
            ;;
        *)
            echo "  ✗ Unknown action: $action"
            track_service_failure "$service_name" "Unknown action: $action" "docker" "$host"
            return 1
            ;;
    esac

    # Execute docker compose command and check return code
    if ! run_on_host_checked "$host" "$compose_cmd" "$service_name"; then
        echo "  ✗ Failed to $action $service_name on $host"
        track_service_failure "$service_name" "Docker compose $action failed" "docker" "$host"
        return 1
    fi

    # Verify containers are running (skip for shutdown)
    if [ "$action" != "shutdown" ]; then
        if ! verify_containers_running "$host" "$service_name" "$full_path"; then
            echo "  ✗ Docker compose succeeded but containers not running for $service_name"
            track_service_failure "$service_name" "Containers not running after $action" "docker" "$host"
            return 1
        fi
        echo "  ✓ Completed $action for $service_name on $host"
    else
        echo "  ✓ Completed $action for $service_name on $host"
    fi

    return 0
}

# =============================================================================
# NATIVE SERVICE MANAGEMENT - WITH PROPER RETURN CODES
# =============================================================================

# Manage native services (systemd, launchd, etc.) with error handling
# Returns: 0 on success, 1 on failure
#
# Native services are managed by system service managers.
# Commands are read from service.yml
#
manage_native_service() {
    local host="$1"
    local service_path="$2"
    local service_name="$3"
    local action="$4"

    local base_path="${BASE_PATHS[$host]}"
    local service_file
    service_file="${base_path}$(dirname "$service_path")/service.yml"

    echo "  [$host] Managing native service: $service_name"

    # Map action to command type in service.yml
    local cmd_type=""
    case $action in
        start) cmd_type="start" ;;
        restart) cmd_type="restart" ;;
        shutdown) cmd_type="stop" ;;
        *)
            echo "  ✗ Unknown action: $action"
            track_service_failure "$service_name" "Unknown action: $action" "native" "$host"
            return 1
            ;;
    esac

    # Extract command from service.yml
    local service_cmd="grep '^${cmd_type}:' '$service_file' | sed 's/^${cmd_type}:[[:space:]]*//' | head -1"
    local actual_cmd
    actual_cmd=$(run_on_host "$host" "$service_cmd" 2>/dev/null || echo "")

    if [ -z "$actual_cmd" ]; then
        echo "  ⚠ No $cmd_type command found in service.yml"
        track_service_failure "$service_name" "No $cmd_type command in service.yml" "native" "$host"
        return 1
    fi

    # Handle sudo commands - add password
    if [[ "$actual_cmd" == *"sudo"* ]]; then
        local password="${PASSWORDS[$host]}"
        actual_cmd="echo '$password' | ${actual_cmd//sudo/sudo -S}"
    fi

    # Execute the command
    local cmd_output
    local cmd_exit_code=0

    # For backgrounded commands (ending with &), run asynchronously
    if [[ "$actual_cmd" =~ \&[[:space:]]*$ ]]; then
        run_on_host "$host" "$actual_cmd" >/dev/null 2>&1 || cmd_exit_code=$?
    else
        cmd_output=$(run_on_host "$host" "$actual_cmd" 2>&1) || cmd_exit_code=$?
        # shellcheck disable=SC2001  # per-line prefix; bash parameter expansion can't anchor with ^
        [ -n "$cmd_output" ] && echo "$cmd_output" | sed 's/^/    /'
    fi

    # Check if command succeeded
    if [ $cmd_exit_code -ne 0 ]; then
        echo "  ✗ Failed to $action $service_name (exit code: $cmd_exit_code)"
        track_service_failure "$service_name" "Command failed with exit code $cmd_exit_code" "native" "$host"
        return 1
    fi

    echo "  ✓ Completed $action for $service_name on $host"
    return 0
}

# =============================================================================
# LOCAL SERVICE MANAGEMENT - WITH PROPER RETURN CODES
# =============================================================================

# Manage local services (Python, Node, etc.) with health checks
# Returns: 0 on success, 1 on failure
#
# Local services run as background processes.
# Includes health check verification after start/restart.
#
manage_local_service() {
    local host="$1"
    local service_path="$2"
    local service_name="$3"
    local action="$4"

    local base_path="${BASE_PATHS[$host]}"
    local service_file
    service_file="${base_path}$(dirname "$service_path")/service.yml"

    echo "  [$host] Managing local service: $service_name"

    # Map action to command type
    local cmd_type=""
    case $action in
        start) cmd_type="start" ;;
        restart) cmd_type="restart" ;;
        shutdown) cmd_type="stop" ;;
        *)
            echo "  ✗ Unknown action: $action"
            track_service_failure "$service_name" "Unknown action: $action" "local" "$host"
            return 1
            ;;
    esac

    # Extract command from service.yml
    local service_cmd="grep '^${cmd_type}:' '$service_file' | sed 's/^${cmd_type}:[[:space:]]*//' | head -1"
    local actual_cmd
    actual_cmd=$(run_on_host "$host" "$service_cmd" 2>/dev/null || echo "")

    if [ -z "$actual_cmd" ]; then
        echo "  ⚠ No $cmd_type command found in service.yml"
        track_service_failure "$service_name" "No $cmd_type command in service.yml" "local" "$host"
        return 1
    fi

    # Execute the command
    local cmd_output
    local cmd_exit_code=0

    # For backgrounded commands (ending with &), run asynchronously
    if [[ "$actual_cmd" =~ \&[[:space:]]*$ ]]; then
        run_on_host "$host" "$actual_cmd" >/dev/null 2>&1 || cmd_exit_code=$?
    else
        cmd_output=$(run_on_host "$host" "$actual_cmd" 2>&1) || cmd_exit_code=$?
        # shellcheck disable=SC2001  # per-line prefix; bash parameter expansion can't anchor with ^
        [ -n "$cmd_output" ] && echo "$cmd_output" | sed 's/^/    /'
    fi

    # Check if command succeeded
    if [ $cmd_exit_code -ne 0 ]; then
        echo "  ✗ Failed to $action $service_name (exit code: $cmd_exit_code)"
        track_service_failure "$service_name" "Command failed with exit code $cmd_exit_code" "local" "$host"
        return 1
    fi

    # Skip health checks for shutdown
    if [ "$action" = "shutdown" ]; then
        echo "  ✓ Completed $action for $service_name on $host"
        return 0
    fi

    # Health check configuration
    local health_timeout="${HEALTH_TIMEOUT:-10}"
    local health_max_attempts="${HEALTH_MAX_ATTEMPTS:-30}"
    local health_retry_delay="${HEALTH_RETRY_DELAY:-3}"

    # Extract healthcheck command
    local health_cmd="grep '^healthcheck:' '$service_file' | sed 's/^healthcheck:[[:space:]]*//' | head -1"
    local health_actual
    health_actual=$(run_on_host "$host" "$health_cmd" 2>/dev/null || echo "")

    # Extract status command (for fast-fail)
    local status_cmd="grep '^status:' '$service_file' | sed 's/^status:[[:space:]]*//' | head -1"
    local status_actual
    status_actual=$(run_on_host "$host" "$status_cmd" 2>/dev/null || echo "")

    local health_ok=0

    if [ -n "$health_actual" ]; then
        echo "    Waiting for healthcheck..."
        local attempt=0

        while [ $attempt -lt "$health_max_attempts" ]; do
            # Run health command with timeout
            local timed_health="timeout ${health_timeout} bash -c '$health_actual'"
            if run_on_host "$host" "$timed_health" > /dev/null 2>&1; then
                health_ok=1
                break
            fi

            # Optional: fast-fail if status indicates service stopped
            if [ -n "$status_actual" ]; then
                local status_out
                status_out=$(run_on_host "$host" "$status_actual" 2>/dev/null || echo "")
                if [[ "$status_out" != running* ]]; then
                    echo "    Service not running (status: ${status_out:-unknown})"
                    break
                fi
            fi

            # Progress indicator every few attempts
            if (( attempt % 5 == 0 )); then
                echo "    ...health attempt $((attempt+1))/$health_max_attempts"
            fi

            sleep "$health_retry_delay"
            attempt=$((attempt+1))
        done
    else
        # Fallback to status command
        if [ -n "$status_actual" ]; then
            sleep 5
            local status
            status=$(run_on_host "$host" "$status_actual" 2>/dev/null || echo "")
            [[ "$status" == "running"* ]] && health_ok=1
        else
            # No health/status defined; assume success
            health_ok=1
        fi
    fi

    # Evaluate health check result
    if [ $health_ok -eq 1 ]; then
        echo "  ✓ Completed $action for $service_name on $host"
        return 0
    else
        echo "  ✗ $service_name failed health/status check"
        echo "    Logs: ${service_file%/service.yml}/logs or /tmp/portoser-${service_name}.log"
        track_service_failure "$service_name" "Health check failed after $action" "local" "$host"
        return 1
    fi
}

# =============================================================================
# USAGE EXAMPLES
# =============================================================================

# Example 1: Standalone usage
#
# source /tmp/agent3_verification.sh
# manage_docker_service "host-a" "/keycloak/docker-compose.yml" "keycloak" "restart"
# if [ $? -ne 0 ]; then
#     echo "Service management failed"
#     report_failed_services
# fi

# Example 2: In main service loop
#
# for service in $SERVICE_LIST; do
#     case $type in
#         docker)
#             if ! manage_docker_service "$host" "$path" "$service" "$ACTION"; then
#                 echo "Failed to manage docker service: $service"
#             fi
#             ;;
#         native)
#             if ! manage_native_service "$host" "$path" "$service" "$ACTION"; then
#                 echo "Failed to manage native service: $service"
#             fi
#             ;;
#         local)
#             if ! manage_local_service "$host" "$path" "$service" "$ACTION"; then
#                 echo "Failed to manage local service: $service"
#             fi
#             ;;
#     esac
# done
#
# # At the end of script
# if ! report_failed_services; then
#     exit 1
# fi

# =============================================================================
# INTEGRATION NOTES
# =============================================================================
#
# TO INTEGRATE INTO EXISTING SCRIPTS:
#
# 1. Source this file at the beginning of the cluster-compose script.
#
# 2. Update the main service processing loop to check return codes:
#
#    case $type in
#        docker)
#            if ! manage_docker_service "$host" "$path" "$service" "$ACTION"; then
#                echo "⚠️  Service $service failed"
#            fi
#            ;;
#        # ... similar for native and local ...
#    esac
#
# 4. At end of script, report failures:
#
#    if ! report_failed_services; then
#        echo "Some services failed during $ACTION"
#        exit 1
#    fi
#
# 5. Remove or update the old FAILED_SERVICES summary code since
#    report_failed_services() now handles this with more detail
#
# =============================================================================

echo "✓ Service Verification & Error Propagation Module loaded"
echo "  - verify_containers_running() - Fixed implementation"
echo "  - verify_service_health() - Generic health checker"
echo "  - manage_docker_service() - Returns proper exit codes"
echo "  - manage_native_service() - Returns proper exit codes"
echo "  - manage_local_service() - Returns proper exit codes"
echo "  - track_service_failure() - Track all failures with metadata"
echo "  - report_failed_services() - Comprehensive failure reporting"
echo ""
echo "Ready to fix container verification and error propagation!"
