#!/usr/bin/env bash
# health.sh - Functions for checking service health

set -euo pipefail

# Source security validation library
_HEALTH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_HEALTH_LIB_DIR/utils/security_validation.sh" ]; then
    # shellcheck source=lib/utils/security_validation.sh
    source "$_HEALTH_LIB_DIR/utils/security_validation.sh"
fi

# Check if a port is open on a host
# Usage: check_port_open HOST PORT
check_port_open() {
    local host="$1"
    local port="$2"

    if [ -z "$host" ] || [ -z "$port" ]; then
        echo "Error: Host and port required" >&2
        return 1
    fi

    # Security: Validate host and port
    if ! validate_ip_address "$host" "host" 2>/dev/null; then
        if ! validate_hostname "$host" "host"; then
            return 1
        fi
    fi

    if ! validate_port "$port" "port"; then
        return 1
    fi

    # Use nc (netcat) for port checking - works for both HTTP and HTTPS
    if nc -z -w 5 "$host" "$port" 2>/dev/null; then
        return 0
    else
        # Fallback: try bash /dev/tcp method with validated host/port
        # Security: Pass as positional parameters to avoid injection
        if bash -c 'echo > /dev/tcp/$1/$2' _ "$host" "$port" 2>/dev/null; then
            return 0
        else
            return 1
        fi
    fi
}

# Check HTTP health endpoint
# Usage: check_http_health URL [TIMEOUT]
check_http_health() {
    local url="$1"
    local timeout="${2:-$HEALTH_CHECK_TIMEOUT}"

    if [ -z "$url" ]; then
        echo "Error: URL required" >&2
        return 1
    fi

    # Try the health endpoint (use -k for self-signed certs).
    # Only the curl exit code matters here.
    if curl -k -f -s -m "$timeout" "$url" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Check service health via Caddy hostname
# Usage: check_service_health_via_caddy SERVICE_NAME
check_service_health_via_caddy() {
    local service="$1"

    if [ -z "$service" ]; then
        return 1
    fi

    local hostname
    hostname=$(get_service_hostname "$service")
    local health_url
    health_url=$(get_service_health_url "$service" 2>/dev/null)

    # If no health URL, try to construct from hostname
    if [ -z "$health_url" ] || [ "$health_url" = "null" ]; then
        # Determine protocol - check if TLS cert exists in registry
        local protocol="http"
        local tls_cert
        tls_cert=$(yq eval ".services.${service}.tls_cert" "$CADDY_REGISTRY_PATH" 2>/dev/null)
        if [ -n "$tls_cert" ] && [ "$tls_cert" != "null" ]; then
            protocol="https"
        fi
        health_url="${protocol}://${hostname}/health"
    fi

    # Replace direct IP with hostname for Caddy test
    health_url=$(echo "$health_url" | sed -E "s|https?://[0-9.]+:[0-9]+|http://${hostname}|")

    [ "$DEBUG" = "1" ] && echo "Debug: Testing Caddy routing for $service at $health_url" >&2

    # Test via Caddy (may need -k for self-signed certs)
    if curl -k -f -s -m 5 "$health_url" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Check service health with retry
# Usage: check_service_health SERVICE_NAME [MAX_ATTEMPTS]
check_service_health() {
    local service="$1"
    local max_attempts="${2:-1}"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    local current_host
    current_host=$(get_service_host "$service")
    local port
    port=$(get_service_port "$service")
    local ip
    ip=$(get_machine_ip "$current_host")

    # Check if there's a custom healthcheck command
    local healthcheck_cmd
    healthcheck_cmd=$(get_service_healthcheck_command "$service" 2>/dev/null)

    if [ -n "$healthcheck_cmd" ] && [ "$healthcheck_cmd" != "null" ]; then
        # SECURITY WARNING: Custom healthcheck commands from registry should be validated
        # They come from registry.yml which is controlled, but we still sanitize
        [ "$DEBUG" = "1" ] && echo "Debug: Using healthcheck command for $service: $healthcheck_cmd" >&2

        # Security: Check for dangerous characters in healthcheck command
        if contains_dangerous_chars "$healthcheck_cmd"; then
            echo "Error: Healthcheck command for $service contains dangerous characters" >&2
            echo "Command: $healthcheck_cmd" >&2
            echo "This may indicate a security issue in registry.yml" >&2
            return 1
        fi

        local attempt=1
        while [ "$attempt" -le "$max_attempts" ]; do
            if [ "$attempt" -gt 1 ]; then
                echo "  Retry attempt $attempt/$max_attempts..." >&2
                sleep "$HEALTH_CHECK_INTERVAL"
            fi

            # Execute healthcheck command (locally or remotely)
            # Use bash -c instead of eval for safety
            # Check if current_host is local by comparing with actual hostname
            local actual_hostname
            actual_hostname=$(hostname)
            local is_local=0
            if [ "$current_host" = "$actual_hostname" ] || [ "$current_host" = "localhost" ] || [ "$current_host" = "127.0.0.1" ]; then
                is_local=1
            fi

            if [ "$is_local" -eq 1 ]; then
                # Local execution
                if bash -c "$healthcheck_cmd" >/dev/null 2>&1; then
                    [ "$DEBUG" = "1" ] && echo "✓ Service '$service' is healthy (via command)" >&2
                    return 0
                fi
            else
                # Remote execution via SSH
                # Security: Pass command properly quoted to SSH
                local ssh_user
                ssh_user=$(get_machine_ssh_user "$current_host")
                local ssh_port
                ssh_port=$(get_machine_ssh_port "$current_host")
                if ssh -n -p "$ssh_port" -o ConnectTimeout=5 -o BatchMode=yes "$ssh_user@$ip" -- bash -c "$healthcheck_cmd" >/dev/null 2>&1; then
                    [ "$DEBUG" = "1" ] && echo "✓ Service '$service' is healthy (via command)" >&2
                    return 0
                fi
            fi

            attempt=$((attempt + 1))
        done

        [ "$DEBUG" = "1" ] && echo "✗ Service '$service' healthcheck command failed" >&2
        return 1
    fi

    # Fall back to HTTP health check
    local health_url
    if ! health_url=$(get_service_health_url "$service"); then
        echo "Error: Could not determine health URL for service '$service'" >&2
        return 1
    fi

    [ "$DEBUG" = "1" ] && echo "Debug: Checking health for $service at $health_url" >&2

    # Retry logic
    local attempt=1
    while [ "$attempt" -le "$max_attempts" ]; do
        if [ "$attempt" -gt 1 ]; then
            echo "  Retry attempt $attempt/$max_attempts..." >&2
            sleep "$HEALTH_CHECK_INTERVAL"
        fi

        # First check if port is open
        if check_port_open "$ip" "$port"; then
            # Port is open, try HTTP health check (direct access)
            if check_http_health "$health_url"; then
                # Direct access works, now verify Caddy routing
                if check_service_health_via_caddy "$service" 2>/dev/null; then
                    echo "✓ Service '$service' is healthy (direct + Caddy routing)"
                    return 0
                else
                    [ "$DEBUG" = "1" ] && echo "Debug: Caddy routing failed for $service" >&2
                    echo "⚠ Service '$service' is healthy but Caddy routing may have issues"
                    return 0  # Still return success if direct access works
                fi
            else
                [ "$DEBUG" = "1" ] && echo "Debug: HTTP health check failed for $service" >&2
            fi
        else
            [ "$DEBUG" = "1" ] && echo "Debug: Port $port not open on $ip for $service" >&2
        fi

        attempt=$((attempt + 1))
    done

    echo "✗ Service '$service' is unhealthy or unreachable"
    return 1
}

# Wait for service to become healthy
# Usage: wait_for_service_health SERVICE_NAME [TIMEOUT_SECONDS]
wait_for_service_health() {
    local service="$1"
    local timeout="${2:-$HEALTH_CHECK_TIMEOUT}"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    echo "Waiting for service '$service' to become healthy (timeout: ${timeout}s)..."

    local health_url
    if ! health_url=$(get_service_health_url "$service"); then
        echo "Error: Could not determine health URL for service '$service'" >&2
        return 1
    fi

    local current_host
    current_host=$(get_service_host "$service")
    local port
    port=$(get_service_port "$service")
    local ip
    ip=$(get_machine_ip "$current_host")

    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if check_port_open "$ip" "$port"; then
            if check_http_health "$health_url" 5; then
                echo "✓ Service '$service' is healthy after ${elapsed}s"
                return 0
            fi
        fi

        sleep "$HEALTH_CHECK_INTERVAL"
        elapsed=$((elapsed + HEALTH_CHECK_INTERVAL))

        # Progress indicator
        if [ $((elapsed % 10)) -eq 0 ]; then
            echo "  Still waiting... (${elapsed}s elapsed)"
        fi
    done

    echo "✗ Service '$service' did not become healthy within ${timeout}s"
    return 1
}

# Check all services health
# Usage: check_all_services_health
check_all_services_health() {
    echo "Checking health of all services..."
    echo ""

    local services
    services=$(list_services)
    local all_healthy=0

    while IFS= read -r service; do
        if [ -z "$service" ]; then
            continue
        fi

        printf "%-30s ... " "$service"

        if check_service_health "$service" 2>/dev/null; then
            echo "✓ HEALTHY"
        else
            echo "✗ UNHEALTHY"
            all_healthy=1
        fi
    done <<< "$services"

    echo ""
    if [ $all_healthy -eq 0 ]; then
        echo "✓ All services are healthy"
        return 0
    else
        echo "✗ Some services are unhealthy"
        return 1
    fi
}

# Check if Docker container is running on a machine
# Usage: check_docker_container_running MACHINE SERVICE
check_docker_container_running() {
    local machine="$1"
    local service="$2"

    if [ -z "$machine" ] || [ -z "$service" ]; then
        echo "Error: Machine and service name required" >&2
        return 1
    fi

    local context
    if ! context=$(get_machine_context "$machine" 2>/dev/null) || [ -z "$context" ] || [ "$context" = "null" ]; then
        # Try SSH instead - use machine-specific SSH user
        local ip
        ip=$(get_machine_ip "$machine")
        local ssh_user
        ssh_user=$(get_machine_ssh_user "$machine")
        local ssh_port
        ssh_port=$(get_machine_ssh_port "$machine")
        local running
        running=$(ssh -n -p "$ssh_port" -o ConnectTimeout=5 "$ssh_user@$ip" "docker ps --format '{{.Names}}' | grep -i '$service'" 2>/dev/null)
    else
        local running
        running=$(docker --context "$context" ps --format '{{.Names}}' | grep -i "$service" 2>/dev/null)
    fi

    if [ -n "$running" ]; then
        return 0
    else
        return 1
    fi
}

# Check if local Python service is running on a machine
# Usage: check_local_service_running MACHINE SERVICE
check_local_service_running() {
    local machine="$1"
    local service="$2"

    if [ -z "$machine" ] || [ -z "$service" ]; then
        echo "Error: Machine and service name required" >&2
        return 1
    fi

    local ip
    ip=$(get_machine_ip "$machine")
    local pid_file="$PIDS_DIR/${service}.pid"

    # Determine if we should check locally or remotely
    local current_machine
    current_machine=$(hostname -s 2>/dev/null || hostname | cut -d. -f1)
    local is_local=0
    if [ "$machine" = "$current_machine" ]; then
        is_local=1
    fi

    # First, try PID file check
    if [ $is_local -eq 1 ]; then
        # Local check
        if [ -f "$pid_file" ]; then
            local pid
            pid=$(cat "$pid_file")
            if ps -p "$pid" > /dev/null 2>&1; then
                return 0
            fi
        fi
    else
        # Remote check via SSH
        # Security: Validate path before using in SSH command
        if ! validate_path "$pid_file" "pid_file"; then
            return 1
        fi

        local ssh_port
        ssh_port=$(get_machine_ssh_port "$machine")
        local ssh_user
        ssh_user=$(get_machine_ssh_user "$machine")
        # Security: Use bash -c with positional parameter to safely pass pid_file
        local running
        running=$(ssh -n -p "$ssh_port" -o ConnectTimeout=5 "$ssh_user@$ip" -- \
            bash -c '[ -f "$1" ] && ps -p $(cat "$1") > /dev/null 2>&1 && echo "running"' _ "$pid_file" 2>/dev/null)
        if [ "$running" = "running" ]; then
            return 0
        fi
    fi

    # If PID file check failed, try checking brew services
    # Extract brew service name from start command if it uses brew services
    local brew_service_name=""
    local start_cmd
    start_cmd=$(get_service_start_command "$service" 2>/dev/null)
    if [ -n "$start_cmd" ] && [[ "$start_cmd" == *"brew services start"* ]]; then
        # Extract service name after "brew services start"
        brew_service_name=$(echo "$start_cmd" | sed -n 's|.*brew services start \([^ ]*\).*|\1|p')
    fi

    if [ -n "$brew_service_name" ]; then
        if [ $is_local -eq 1 ]; then
            # Local brew services check
            if command -v brew >/dev/null 2>&1; then
                local brew_status
                brew_status=$(brew services list | grep "^${brew_service_name}" | awk '{print $2}')
                if [ "$brew_status" = "started" ]; then
                    return 0
                fi
            fi
        else
            # Remote brew services check via SSH
            local ssh_port
            ssh_port=$(get_machine_ssh_port "$machine")
            local ssh_user
            ssh_user=$(get_machine_ssh_user "$machine")
            local brew_status
            brew_status=$(ssh -n -p "$ssh_port" -o ConnectTimeout=5 "$ssh_user@$ip" \
                "command -v brew >/dev/null 2>&1 && brew services list | grep '^${brew_service_name}' | awk '{print \$2}'" 2>/dev/null)
            if [ "$brew_status" = "started" ]; then
                return 0
            fi
        fi
    fi

    # Service not found running
    return 1
}

# Get service status (running/stopped/unknown)
# Usage: get_service_status SERVICE_NAME
get_service_status() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    local current_host
    current_host=$(get_service_host "$service")
    local service_type
    service_type=$(get_service_type "$service")

    case $service_type in
        docker)
            if check_docker_container_running "$current_host" "$service"; then
                echo "running"
            else
                echo "stopped"
            fi
            ;;
        native|local)
            # Both native and local services use PID file checking
            if check_local_service_running "$current_host" "$service"; then
                echo "running"
            else
                echo "stopped"
            fi
            ;;
        *)
            echo "unknown"
            ;;
    esac

    # Always return 0 since we've provided a status
    return 0
}

# Print service status report
# Usage: service_status_report SERVICE_NAME
service_status_report() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    local current_host
    current_host=$(get_service_host "$service")
    local port
    port=$(get_service_port "$service")
    local service_type
    service_type=$(get_service_type "$service")
    local hostname
    hostname=$(get_service_hostname "$service")
    local service_status
    service_status=$(get_service_status "$service")

    echo "Service: $service"
    echo "  Type: $service_type"
    echo "  Host: $current_host"
    echo "  Port: $port"
    echo "  Hostname: $hostname"
    echo "  Status: $service_status"

    if [ "$service_status" = "running" ]; then
        echo "  Health: "
        if check_service_health "$service" 1; then
            echo "    ✓ Healthy"
        else
            echo "    ✗ Unhealthy"
        fi
    fi
}

# =============================================================================
# Enhanced Health Check Functions
# =============================================================================

# Configuration for enhanced health checks
HEALTH_ENHANCED_RETRY_ATTEMPTS="${HEALTH_ENHANCED_RETRY_ATTEMPTS:-5}"
HEALTH_ENHANCED_RETRY_INTERVAL="${HEALTH_ENHANCED_RETRY_INTERVAL:-2}"
HEALTH_ENHANCED_MAX_BACKOFF="${HEALTH_ENHANCED_MAX_BACKOFF:-30}"

# =============================================================================
# check_service_dependencies_health - Verify all service dependencies
#
# Recursively checks that all dependencies of a service are healthy before
# considering the service itself. Prevents false positives when dependencies
# are down.
#
# Parameters:
#   $1 - service_name (required): Service to check dependencies for
#   $2 - max_depth (optional): Max recursion depth to prevent cycles
#                             Default: 10
#   $3 - visited (optional): Array of already checked services (internal)
#
# Returns:
#   0 - All dependencies are healthy
#   1 - One or more dependencies are unhealthy
#   2 - Invalid parameters
# =============================================================================
check_service_dependencies_health() {
    local service_name="$1"
    local max_depth="${2:-10}"
    local -n visited_ref="${3:-__VISITED__}"

    if [[ -z "$service_name" ]]; then
        echo "Error: service_name parameter required" >&2
        return 2
    fi

    # Prevent infinite recursion
    if [[ ! -v visited_ref ]]; then
        declare -gA visited_ref
    fi

    if [[ ${visited_ref[$service_name]:-0} -gt 0 ]]; then
        return 0  # Already checked
    fi

    if [[ $max_depth -le 0 ]]; then
        echo "Warning: Max dependency depth reached for $service_name" >&2
        return 1
    fi

    visited_ref[$service_name]=1

    [ "$DEBUG" = "1" ] && echo "  [HEALTH] Checking dependencies for $service_name" >&2

    # Get dependencies from registry
    local dependencies
    dependencies=$(get_service_dependencies "$service_name" 2>/dev/null || echo "")

    if [[ -z "$dependencies" ]]; then
        [ "$DEBUG" = "1" ] && echo "  [HEALTH] No dependencies for $service_name" >&2
        return 0
    fi

    # Check each dependency
    local dep
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue

        echo "  Checking dependency: $dep" >&2

        # Recursively check the dependency's dependencies
        if ! check_service_dependencies_health "$dep" "$((max_depth - 1))" visited_ref; then
            echo "Error: Dependency $dep is unhealthy" >&2
            return 1
        fi

        # Check dependency health status
        if ! check_service_health "$dep" 3 >/dev/null 2>&1; then
            echo "Error: Dependency $dep is not responding" >&2
            return 1
        fi
    done <<< "$dependencies"

    [ "$DEBUG" = "1" ] && echo "  [HEALTH] All dependencies healthy for $service_name" >&2
    return 0
}

# =============================================================================
# check_dependency_chain - Verify complete dependency chain
# =============================================================================
check_dependency_chain() {
    local service="$1"

    if [[ -z "$service" ]]; then
        echo "Error: service_name required" >&2
        return 1
    fi

    echo "Dependency Chain for $service:" >&2
    echo "===============================" >&2

    local dependencies
    dependencies=$(get_service_dependencies "$service" 2>/dev/null || echo "")

    if [[ -z "$dependencies" ]]; then
        echo "  (no dependencies)" >&2
        return 0
    fi

    local errors=0
    local dep
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue

        echo -n "  $dep: " >&2

        if check_service_health "$dep" 1 >/dev/null 2>&1; then
            echo "HEALTHY" >&2
        else
            echo "UNHEALTHY" >&2
            ((errors++))
        fi
    done <<< "$dependencies"

    if [[ $errors -gt 0 ]]; then
        return 1
    fi

    return 0
}

# =============================================================================
# run_functional_test - Execute functional test for a service
#
# Parameters:
#   $1 - service_name (required): Service to test
#   $2 - test_script (required): Path to test script
#   $3 - timeout (optional): Test timeout in seconds (default: 30)
# =============================================================================
run_functional_test() {
    local service_name="$1"
    local test_script="$2"
    local timeout="${3:-30}"

    if [[ -z "$service_name" ]] || [[ -z "$test_script" ]]; then
        echo "Error: service_name and test_script required" >&2
        return 2
    fi

    if [[ ! -f "$test_script" ]]; then
        echo "Warning: Test script not found: $test_script" >&2
        return 2
    fi

    if [[ ! -x "$test_script" ]]; then
        echo "Warning: Test script not executable: $test_script" >&2
        return 2
    fi

    echo "Running functional test for $service_name..." >&2

    local test_output
    local test_exit_code

    # Run test with timeout
    if test_output=$(timeout "$timeout" bash "$test_script" 2>&1); then
        test_exit_code=$?
    else
        test_exit_code=$?
        if [[ $test_exit_code -eq 124 ]]; then
            echo "Error: Functional test timed out after ${timeout}s" >&2
            return 1
        fi
    fi

    if [[ $test_exit_code -eq 0 ]]; then
        echo "Functional test passed for $service_name" >&2
        return 0
    else
        echo "Functional test failed for $service_name" >&2
        [[ "$DEBUG" = "1" ]] && echo "Test output:" >&2 && echo "$test_output" >&2
        return 1
    fi
}

# =============================================================================
# is_service_ready - Complete service readiness check
#
# Comprehensive check combining:
# - Dependency health
# - Service health
# - Optional functional test
#
# Parameters:
#   $1 - service_name (required): Service to check
#   $2 - test_script (optional): Path to functional test
#   $3 - timeout (optional): Overall timeout in seconds
# =============================================================================
is_service_ready() {
    local service_name="$1"
    local test_script="${2:-}"
    local timeout="${3:-60}"

    if [[ -z "$service_name" ]]; then
        echo "Error: service_name required" >&2
        return 2
    fi

    echo "Checking readiness for $service_name..." >&2

    # Step 1: Check dependencies
    if ! check_service_dependencies_health "$service_name"; then
        echo "Error: Dependencies not ready" >&2
        return 1
    fi

    # Step 2: Check service health
    if ! check_service_health "$service_name" 3 >/dev/null 2>&1; then
        echo "Error: Service health check failed" >&2
        return 1
    fi

    # Step 3: Run functional test if provided
    if [[ -n "$test_script" ]] && [[ -f "$test_script" ]]; then
        if ! run_functional_test "$service_name" "$test_script" "$((timeout / 2))"; then
            echo "Error: Functional test failed" >&2
            return 1
        fi
    fi

    echo "Service is ready: $service_name" >&2
    return 0
}

# =============================================================================
# wait_for_service_ready - Wait for service to be ready with exponential backoff
#
# Parameters:
#   $1 - service_name (required): Service to wait for
#   $2 - max_wait (optional): Maximum wait time in seconds (default: 300)
#   $3 - test_script (optional): Functional test script
# =============================================================================
wait_for_service_ready() {
    local service_name="$1"
    local max_wait="${2:-300}"
    local test_script="${3:-}"

    if [[ -z "$service_name" ]]; then
        echo "Error: service_name required" >&2
        return 2
    fi

    echo "Waiting for service to be ready: $service_name (max ${max_wait}s)..." >&2

    local start_time
    start_time=$(date +%s)
    local attempt=1
    local wait_interval=1

    while true; do
        if is_service_ready "$service_name" "$test_script" "$max_wait" 2>/dev/null; then
            echo "Service ready after $attempt attempts" >&2
            return 0
        fi

        local current_time
        current_time=$(date +%s)
        local elapsed
        elapsed=$((current_time - start_time))

        if [[ $elapsed -ge $max_wait ]]; then
            echo "Timeout: Service not ready after ${max_wait}s" >&2
            return 1
        fi

        # Exponential backoff (capped at HEALTH_ENHANCED_MAX_BACKOFF)
        wait_interval=$((wait_interval * 2))
        if [[ $wait_interval -gt $HEALTH_ENHANCED_MAX_BACKOFF ]]; then
            wait_interval=$HEALTH_ENHANCED_MAX_BACKOFF
        fi

        [ "$DEBUG" = "1" ] && echo "  [HEALTH] Retry in ${wait_interval}s (attempt $attempt)..." >&2
        sleep "$wait_interval"
        ((attempt++))
    done
}

# =============================================================================
# get_health_metrics - Collect detailed health metrics
#
# Parameters:
#   $1 - service_name (required): Service to check
#
# Outputs:
#   Prints JSON-formatted metrics to stdout
# =============================================================================
get_health_metrics() {
    local service_name="$1"

    if [[ -z "$service_name" ]]; then
        echo "Error: service_name required" >&2
        return 1
    fi

    local service_status="unknown"
    local dependency_status="healthy"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # Check service status
    if check_service_health "$service_name" 1 >/dev/null 2>&1; then
        service_status="healthy"
    else
        service_status="unhealthy"
    fi

    # Check dependencies
    if ! check_service_dependencies_health "$service_name" >/dev/null 2>&1; then
        dependency_status="unhealthy"
    fi

    # Get dependency list
    local dependencies
    dependencies=$(get_service_dependencies "$service_name" 2>/dev/null || echo "")

    # Output JSON metrics
    cat <<EOF
{
  "service": "$service_name",
  "timestamp": "$timestamp",
  "health_status": "$service_status",
  "dependency_status": "$dependency_status",
  "dependencies": [
EOF

    local first=1
    if [[ -n "$dependencies" ]]; then
        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue

            if [[ $first -eq 1 ]]; then
                first=0
            else
                echo ","
            fi

            local dep_status="unknown"
            if check_service_health "$dep" 1 >/dev/null 2>&1; then
                dep_status="healthy"
            else
                dep_status="unhealthy"
            fi

            echo -n "    {\"name\": \"$dep\", \"status\": \"$dep_status\"}"
        done <<< "$dependencies"
    fi

    cat <<EOF
  ]
}
EOF

    return 0
}

# =============================================================================
# health_check_all_services - Run health checks on all services
#
# Parameters:
#   $1 - registry_file (required): Path to registry.yml
# =============================================================================
health_check_all_services() {
    local registry_file="$1"

    if [[ -z "$registry_file" ]] || [[ ! -f "$registry_file" ]]; then
        echo "Error: registry_file not found" >&2
        return 1
    fi

    echo "Running health checks on all services..." >&2

    # Get all services
    local services
    services=$(yq eval '.services | keys | .[]' "$registry_file" 2>/dev/null || echo "")

    if [[ -z "$services" ]]; then
        echo "No services configured" >&2
        return 0
    fi

    local healthy=0
    local unhealthy=0

    while IFS= read -r service; do
        [[ -z "$service" ]] && continue

        echo -n "  $service: " >&2
        if check_service_health "$service" 1 >/dev/null 2>&1; then
            echo "HEALTHY" >&2
            ((healthy++))
        else
            echo "UNHEALTHY" >&2
            ((unhealthy++))
        fi
    done <<< "$services"

    echo "Health check summary: $healthy healthy, $unhealthy unhealthy" >&2

    if [[ $unhealthy -gt 0 ]]; then
        return 1
    fi

    return 0
}
