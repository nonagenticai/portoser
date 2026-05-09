#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Cluster-Wide Service Management Script (LOCAL BUILDS ONLY)
# Uses registry.yml as source of truth to manage services across all hosts
# ALL BUILDS HAPPEN LOCALLY ON EACH HOST - NO CROSS-COMPILATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_FILE="${REGISTRY_FILE:-$SCRIPT_DIR/registry.yml}"
# Fall back to the bundled example registry if the user has not yet copied it.
[[ -f "$REGISTRY_FILE" ]] || REGISTRY_FILE="$SCRIPT_DIR/registry.example.yml"
LOCAL_HOSTNAME=$(hostname -s)
# Health check tuning (override via env)
HEALTH_MAX_ATTEMPTS=${HEALTH_MAX_ATTEMPTS:-6}       # shorter default to avoid long waits
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-5}
HEALTH_RETRY_DELAY=${HEALTH_RETRY_DELAY:-2}
HEALTH_FAST_FAIL_ON_STATUS=${HEALTH_FAST_FAIL_ON_STATUS:-1}

# =============================================================================
# STARTUP VALIDATION CHECKS
# =============================================================================

# Load validation module for command existence checks
if [ -f "$SCRIPT_DIR/lib/cluster/validation.sh" ]; then
    source "$SCRIPT_DIR/lib/cluster/validation.sh"

    # Run startup validation checks
    echo ""
    validate_bash_version || exit 1
    validate_required_commands || exit 1
    echo ""
fi

# =============================================================================
# SOURCE VERIFICATION MODULE
# =============================================================================
# Load enhanced verification and error propagation functions
if [ -f "$SCRIPT_DIR/lib/cluster/verification.sh" ]; then
    source "$SCRIPT_DIR/lib/cluster/verification.sh"
fi

# Load Caddy integration module
if [ -f "$SCRIPT_DIR/lib/caddy_integration.sh" ]; then
    source "$SCRIPT_DIR/lib/caddy_integration.sh"
fi

# Load SSH key authentication module
if [ -f "$SCRIPT_DIR/lib/cluster/ssh_keys.sh" ]; then
    source "$SCRIPT_DIR/lib/cluster/ssh_keys.sh"
else
    echo "❌ SSH keys module not found at $SCRIPT_DIR/lib/cluster/ssh_keys.sh"
    exit 1
fi

# =============================================================================
# CLUSTER TOPOLOGY
# =============================================================================
# CLUSTER_HOSTS / CLUSTER_PATHS / CLUSTER_ARCH are loaded from cluster.conf.
# See cluster.conf.example for the expected layout.
CLUSTER_CONF="${CLUSTER_CONF:-$SCRIPT_DIR/cluster.conf}"
if [[ ! -f "$CLUSTER_CONF" ]]; then
    echo "ERROR: cluster.conf not found at $CLUSTER_CONF" >&2
    echo "       Copy cluster.conf.example to cluster.conf and edit for your environment." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CLUSTER_CONF"

# =============================================================================
# CLEANUP AND ERROR HANDLING
# =============================================================================

cleanup_build_cache() {
    echo ""
    echo "🧹 Cleaning up Docker build cache..."
    docker builder prune -f --filter "until=24h" > /dev/null 2>&1 || true
    docker buildx prune -f --filter "until=24h" > /dev/null 2>&1 || true
    echo "✓ Build cache cleaned"
}

# Backwards-compatible aliases: older code paths in this script reference
# HOSTS / BASE_PATHS. Point them at the cluster.conf maps so existing logic
# keeps working without re-introducing hardcoded topology.
declare -n HOSTS=CLUSTER_HOSTS
declare -n BASE_PATHS=CLUSTER_PATHS

# =============================================================================
# PARSE ARGUMENTS
# =============================================================================

ACTION=""
TARGETS=()
REBUILD_NOCACHE=false
ALL_SERVICES=false
FAILED_SERVICES=()

show_help() {
    cat << HELP
Cluster-Wide Service Management Script
Uses registry.yml to manage services across all hosts

Usage: $0 [ACTION] [OPTIONS] [TARGETS...]

Actions:
  start              Start services (default if no action specified)
  restart            Restart services
  shutdown           Stop services
  rebuild            Rebuild and restart services (with --no-cache for Docker)

Options:
  all                Apply action to ALL services across ALL hosts
  [host names]       Apply to all services on specific hosts (any keys from
                     registry.yml's \`hosts:\` map, e.g. host-a host-b)
  [service names]    Specific services to target (any keys from
                     registry.yml's \`services:\` map, e.g. nginx postgres)

Examples:
  $0 restart all                    # Restart all services across cluster
  $0 restart host-a                 # Restart all services on a single host
  $0 rebuild host-b host-c          # Rebuild all services on two hosts
  $0 shutdown host-d host-e         # Shutdown all services on those hosts
  $0 restart nginx                  # Restart nginx on whichever host owns it
  $0 rebuild api worker             # Rebuild specific services
  $0 start postgres redis           # Start specific services

Host / service names come from your registry.yml.

Notes:
  - Uses registry.yml as source of truth for service locations
  - Automatically SSHs to remote hosts as needed
  - Handles native, local, and docker deployment types
  - Regenerates Caddyfile on restart/rebuild all
  - Can target entire hosts or individual services
HELP
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        start|restart|shutdown|rebuild)
            ACTION="$1"
            shift
            ;;
        all)
            ALL_SERVICES=true
            shift
            ;;
        -h|--help|help)
            show_help
            exit 0
            ;;
        *)
            TARGETS+=("$1")
            shift
            ;;
    esac
done

# Default action is start
if [ -z "$ACTION" ]; then
    ACTION="start"
fi

# Set rebuild flag
if [ "$ACTION" = "rebuild" ]; then
    REBUILD_NOCACHE=true
    ACTION="restart"  # Rebuild is restart with no-cache
fi

# =============================================================================
# STARTUP VALIDATION CHECKS
# =============================================================================

# Source validation module
if [ -f "$SCRIPT_DIR/lib/cluster/validation.sh" ]; then
    source "$SCRIPT_DIR/lib/cluster/validation.sh"
else
    echo "❌ Validation module not found at $SCRIPT_DIR/lib/cluster/validation.sh"
    exit 1
fi

# Run startup validation checks
validate_bash_version || exit 1
validate_required_commands || exit 1
validate_registry_file "$REGISTRY_FILE" || exit 1
validate_environment || exit 1

# =============================================================================
# REGISTRY PARSING FUNCTIONS
# =============================================================================

get_service_info() {
    local service_name="$1"
    
    awk -v service="$service_name" '
        $0 ~ "^  " service ":" { found=1; next }
        found && /^  [a-z]/ { found=0 }
        found && /current_host:/ { gsub(/^[ \t]+current_host:[ \t]+/, ""); print "host=" $0 }
        found && /deployment_type:/ { gsub(/^[ \t]+deployment_type:[ \t]+/, ""); print "type=" $0 }
        found && /docker_compose:/ { gsub(/^[ \t]+docker_compose:[ \t]+/, ""); print "path=" $0 }
        found && /service_file:/ { gsub(/^[ \t]+service_file:[ \t]+/, ""); print "path=" $0 }
    ' "$REGISTRY_FILE"
}

get_all_services() {
    awk '
    /^services:/ { in_services=1; next }
    in_services && /^[a-z]+:/ { in_services=0 }
    in_services && /^  [a-z][a-z0-9_-]+:$/ {
        gsub(/:/, "", $1)
        gsub(/^[ \t]+/, "", $1)
        print $1
    }' "$REGISTRY_FILE"
}

get_services_by_host() {
    local target_host="$1"
    awk -v host="$target_host" '
    /^services:/ { in_services=1; next }
    in_services && /^[a-z]+:/ { in_services=0 }
    in_services && /^  [a-z][a-z0-9_-]+:$/ {
        service = $1
        gsub(/:/, "", service)
        gsub(/^[ \t]+/, "", service)
        in_service = 1
        next
    }
    in_service && /current_host:/ {
        gsub(/^[ \t]+current_host:[ \t]+/, "")
        if ($0 == host) {
            print service
        }
        in_service = 0
    }
    in_service && /^  [a-z]/ {
        in_service = 0
    }
    ' "$REGISTRY_FILE"
}

is_valid_host() {
    local host="$1"
    # Check if host exists in HOSTS array
    [[ -v HOSTS[$host] ]]
}

get_registry_url() {
    # Get registry URL from registry.yml
    awk '/^registry:/,/^[a-z]+:/ {
        if (/url:/) {
            gsub(/^[ \t]+url:[ \t]+/, "")
            print
            exit
        }
    }' "$REGISTRY_FILE"
}

# Resolve service name (handles both service keys and directory names)
# Returns the actual service key from registry
resolve_service_name() {
    local input_name="$1"

    # First, check if it's an exact service key match
    if get_service_info "$input_name" | grep -q "host="; then
        echo "$input_name"
        return 0
    fi

    # If not found, try to find by directory name
    # Extract directory from docker_compose or service_file paths
    local found_service
    found_service=$(awk -v dir="$input_name" '
    /^services:/ { in_services=1; next }
    in_services && /^[a-z]+:/ { in_services=0 }
    in_services && /^  [a-z][a-z0-9_-]+:$/ {
        service = $1
        gsub(/:/, "", service)
        gsub(/^[ \t]+/, "", service)
        in_service = 1
        next
    }
    in_service && (/docker_compose:/ || /service_file:/) {
        gsub(/^[ \t]+(docker_compose|service_file):[ \t]+/, "")
        # Extract directory name from path (e.g., /ingestion_service/docker-compose.yml -> ingestion_service)
        path = $0
        gsub(/\/[^\/]+$/, "", path)  # Remove filename
        gsub(/^\//, "", path)        # Remove leading slash
        if (path == dir) {
            print service
            exit
        }
        in_service = 0
    }
    in_service && /^  [a-z]/ {
        in_service = 0
    }
    ' "$REGISTRY_FILE")

    if [ -n "$found_service" ]; then
        echo "$found_service"
        return 0
    fi

    # Not found - return original name
    echo "$input_name"
    return 1
}

# =============================================================================
# REMOTE EXECUTION FUNCTIONS
# =============================================================================

run_on_host() {
    local host="$1"
    local command="$2"

    if [ "$host" = "$LOCAL_HOSTNAME" ]; then
        # Run locally
        eval "$command"
    else
        # Run remotely via SSH with login shell to load PATH
        # Now using SSH key authentication from lib/cluster/ssh_keys.sh
        local ssh_host="${HOSTS[$host]}"

        # Detect SSH key for this host
        local ssh_key
        ssh_key=$(detect_ssh_key "$host" 2>/dev/null || echo "")

        # Build SSH command with key authentication
        local ssh_cmd="ssh"
        local ssh_args=("-o" "BatchMode=yes" "-o" "ConnectTimeout=${SSH_CONNECT_TIMEOUT}" "-o" "StrictHostKeyChecking=accept-new")

        # Add identity file if we have a key
        if [[ -n "$ssh_key" ]]; then
            ssh_args+=("-i" "$ssh_key")
        fi

        # Execute command with login shell to load PATH
        "${ssh_cmd}" "${ssh_args[@]}" "$ssh_host" "bash -lc '$command'"
    fi
}

# Execute command on host and capture exit code properly
# Returns: 0 on success, 1 on failure
# Outputs command output with proper indentation
run_on_host_checked() {
    local host="$1"
    local command="$2"
    local service_name="$3"  # For better error messages

    # Create temp file for output
    local output_file
    output_file=$(mktemp)

    # Run command and capture output
    if run_on_host "$host" "$command" > "$output_file" 2>&1; then
        # Success - show output with indentation
        sed 's/^/    /' "$output_file"
        rm -f "$output_file"
        return 0
    else
        local exit_code=$?
        # Failure - show output and error message
        echo "    ❌ Command failed with exit code $exit_code:"
        sed 's/^/    /' "$output_file"
        rm -f "$output_file"
        return 1
    fi
}

# Verify that containers are actually running after deployment
verify_containers_running() {
    local host="$1"
    local service_name="$2"
    local compose_path="$3"

    echo "  Verifying containers are running..."

    # Get list of containers from docker compose ps
    local check_cmd="cd '$compose_path' && docker compose ps --format '{{.Name}}:{{.Status}}'"
    local container_status
    container_status=$(run_on_host "$host" "$check_cmd" 2>/dev/null)

    if [ -z "$container_status" ]; then
        echo "  ⚠️  Warning: No containers found for $service_name"
        return 1
    fi

    # Check each container status
    # local all_running=true
    # while IFS=: read -r container status; do
    #     if [[ "$status" =~ Up|running ]]; then
    #         echo "    ✓ $container: $status"
    #     else
    #         echo "    ✗ $container: $status"
    #         all_running=false
    #     fi
    # done <<< "$container_status"

    # if [ "$all_running" = true ]; then
    #     return 0
    # else
    #     return 1
    # fi
}

# Ensure docker network exists on a host
ensure_docker_network() {
    local host="$1"
    local network_name="workflow-system-network"

    echo "  Checking Docker network on $host..."

    local check_cmd="docker network ls --format '{{.Name}}' | grep -q '^${network_name}\$' || docker network create --driver bridge ${network_name}"

    if run_on_host "$host" "$check_cmd" > /dev/null 2>&1; then
        echo "  ✓ Network '$network_name' ready on $host"
    else
        echo "  ⚠ Failed to ensure network on $host"
    fi
}

# =============================================================================
# SERVICE MANAGEMENT FUNCTIONS
# =============================================================================
# All Docker builds happen locally on each host - no cross-compilation

manage_docker_service() {
    local host="$1"
    local service_path="$2"
    local service_name="$3"
    local action="$4"

    local base_path="${BASE_PATHS[$host]}"
    local full_path
    full_path="${base_path}$(dirname "$service_path")"

    echo "  [$host] Managing docker service: $service_name"

    # Build and run locally on the target host
    local compose_cmd=""
    case $action in
        start)
            if [ "$REBUILD_NOCACHE" = true ]; then
                echo "  → Building image from scratch (--no-cache)..."
                compose_cmd="mkdir -p '$full_path' && cd '$full_path' && docker compose build --no-cache --progress=plain && docker compose up -d"
            else
                compose_cmd="mkdir -p '$full_path' && cd '$full_path' && docker compose up -d"
            fi
            ;;
        restart)
            if [ "$REBUILD_NOCACHE" = true ]; then
                echo "  → Stopping containers..."
                run_on_host "$host" "cd '$full_path' && docker compose down --volumes --remove-orphans" 2>&1 | sed 's/^/    /'
                echo "  → Building image from scratch (--no-cache, this may take several minutes)..."
                compose_cmd="cd '$full_path' && docker compose build --no-cache --progress=plain && docker compose up -d"
            else
                echo "  → Stopping containers..."
                run_on_host "$host" "cd '$full_path' && docker compose down --volumes --remove-orphans" 2>&1 | sed 's/^/    /'
                echo "  → Starting containers..."
                compose_cmd="cd '$full_path' && docker compose up -d"
            fi
            ;;
        shutdown)
            compose_cmd="mkdir -p '$full_path' && cd '$full_path' && docker compose down --volumes --remove-orphans"
            ;;
    esac

    if ! run_on_host_checked "$host" "$compose_cmd" "$service_name"; then
        echo "  ✗ Failed to $action $service_name on $host"
        track_service_failure "$service_name" "Docker compose $action failed" "docker" "$host"
        return 1
    fi

    # Verify containers are running (skip verification for shutdown action)
    if [ "$action" != "shutdown" ]; then
        if verify_containers_running "$host" "$service_name" "$full_path"; then
            echo "  ✓ Completed $action for $service_name on $host"
        else
            echo "  ✗ Action completed but containers not running properly for $service_name on $host"
            track_service_failure "$service_name" "Containers not running after $action" "docker" "$host"
            return 1
        fi
    else
        echo "  ✓ Completed $action for $service_name on $host"
    fi
}

manage_native_service() {
    local host="$1"
    local service_path="$2"
    local service_name="$3"
    local action="$4"
    
    local base_path="${BASE_PATHS[$host]}"
    local service_file
    service_file="${base_path}$(dirname "$service_path")/service.yml"

    echo "  [$host] Managing native service: $service_name"
    
    # For native services, read commands from service.yml
    local cmd_type=""
    case $action in
        start) cmd_type="start" ;;
        restart)
            # Even during rebuilds, native services should use their restart command
            cmd_type="restart"
            ;;
        shutdown) cmd_type="stop" ;;
    esac
    
    # Extract command from service.yml and execute
    local service_cmd="grep '^${cmd_type}:' '$service_file' | sed 's/^${cmd_type}:[[:space:]]*//' | head -1"
    local actual_cmd
    actual_cmd=$(run_on_host "$host" "$service_cmd" 2>/dev/null || echo "")
    
    if [ -n "$actual_cmd" ]; then
        # Note: sudo commands should be configured with NOPASSWD in sudoers for passwordless execution
        # Or SSH keys should be set up with appropriate permissions
        # No longer using password-based sudo authentication for security

        # For backgrounded commands (ending with &), run asynchronously to avoid pipe hang
        if [[ "$actual_cmd" =~ \&[[:space:]]*$ ]]; then
            if ! run_on_host "$host" "$actual_cmd" >/dev/null 2>&1; then
                echo "  ✗ Failed to $action $service_name on $host"
                track_service_failure "$service_name" "Native service command failed (backgrounded)" "native" "$host"
                return 1
            fi
        else
            if ! run_on_host "$host" "$actual_cmd" 2>&1 | sed 's/^/    /'; then
                echo "  ✗ Failed to $action $service_name on $host"
                track_service_failure "$service_name" "Native service command failed" "native" "$host"
                return 1
            fi
        fi
        echo "  ✓ Completed $action for $service_name on $host"
        return 0
    else
        echo "  ⚠ No $cmd_type command found in service.yml"
        track_service_failure "$service_name" "No $cmd_type command in service.yml" "native" "$host"
        return 1
    fi
}

manage_local_service() {
    local host="$1"
    local service_path="$2"
    local service_name="$3"
    local action="$4"

    local base_path="${BASE_PATHS[$host]}"
    local service_file
    service_file="${base_path}$(dirname "$service_path")/service.yml"
    
    echo "  [$host] Managing local service: $service_name"
    
    # Similar to native but for local Python/Node services
    local cmd_type=""
    case $action in
        start) cmd_type="start" ;;
        restart) cmd_type="restart" ;;
        shutdown) cmd_type="stop" ;;
    esac
    
    local service_cmd="grep '^${cmd_type}:' '$service_file' | sed 's/^${cmd_type}:[[:space:]]*//' | head -1"
    local actual_cmd
    actual_cmd=$(run_on_host "$host" "$service_cmd" 2>/dev/null || echo "")

    # Status command is useful both as fallback and for fast‑fail during health loops
    local status_cmd="grep '^status:' '$service_file' | sed 's/^status:[[:space:]]*//' | head -1"
    local status_actual
    status_actual=$(run_on_host "$host" "$status_cmd" 2>/dev/null || echo "")

    if [ -n "$actual_cmd" ]; then
        # Run start/stop/restart as provided (expected to background itself if long-lived)
        # For backgrounded commands (ending with &), run asynchronously to avoid pipe hang
        if [[ "$actual_cmd" =~ \&[[:space:]]*$ ]]; then
            run_on_host "$host" "$actual_cmd" >/dev/null 2>&1
        else
            run_on_host "$host" "$actual_cmd" 2>&1 | sed 's/^/    /'
        fi

        # Skip health checks for shutdown - it's expected that service will be stopped
        if [ "$action" = "shutdown" ]; then
            echo "  ✓ Completed $action for $service_name on $host"
            return 0
        fi

        # Prefer explicit healthcheck if provided
        local health_cmd="grep '^healthcheck:' '$service_file' | sed 's/^healthcheck:[[:space:]]*//' | head -1"
        local health_actual
        health_actual=$(run_on_host "$host" "$health_cmd" 2>/dev/null || echo "")

        local ok=0
        local health_timeout="$HEALTH_TIMEOUT"  # seconds per health attempt
        if [ -n "$health_actual" ]; then
            echo "    Waiting for healthcheck..."
            local attempts="$HEALTH_MAX_ATTEMPTS"
            local i=0
            while [ "$i" -lt "$attempts" ]; do
                # Run health command with a per-attempt timeout and capture its exit status
                # Use timeout command for cleaner timeout handling
                local timed_health="timeout ${health_timeout} bash -c '$health_actual'"
                if run_on_host "$host" "$timed_health" > /dev/null 2>&1; then
                    ok=1; break
                fi
                # Optional fast-fail if status says service stopped
                if [ "$HEALTH_FAST_FAIL_ON_STATUS" = "1" ] && [ -n "$status_actual" ]; then
                    local status_out
                    status_out=$(run_on_host "$host" "$status_actual" 2>/dev/null || echo "")
                    if [[ "$status_out" != running* ]]; then
                        echo "    Service not running (status: ${status_out:-unknown}); aborting health checks early."
                        break
                    fi
                fi
                if (( i % 3 == 0 )); then echo "    ...health attempt $((i+1))/$attempts"; fi
                sleep "$HEALTH_RETRY_DELAY"
                i=$((i+1))
            done
        else
            # Fallback to status command if present
            if [ -n "$status_actual" ]; then
                sleep 5
                local status
                status=$(run_on_host "$host" "$status_actual" 2>/dev/null || echo "")
                [[ "$status" == "running"* ]] && ok=1
            else
                ok=1  # No health/status defined; assume success
            fi
        fi

        if [ $ok -eq 1 ]; then
            echo "  ✓ Completed $action for $service_name on $host"
        else
            echo "  ✗ $service_name failed health/status check"
            echo "    Logs: ${service_file%/service.yml}/logs or /tmp/portoser-${service_name}.log"
            track_service_failure "$service_name" "Health/status check failed after $action" "local" "$host"
        fi
    else
        echo "  ⚠ No $cmd_type command found in service.yml"
        track_service_failure "$service_name" "No $cmd_type command in service.yml" "local" "$host"
    fi
}

# =============================================================================
# MAIN LOGIC
# =============================================================================

echo "🚀 Cluster Service Management"
echo "=============================="
echo "Action: $ACTION"
echo "Registry: $REGISTRY_FILE"
echo ""

# Verify registry exists
if [ ! -f "$REGISTRY_FILE" ]; then
    echo "❌ Registry file not found: $REGISTRY_FILE"
    exit 1
fi

# Get list of services to process
if [ "$ALL_SERVICES" = true ]; then
    SERVICE_LIST=$(get_all_services)
    echo "📋 Processing ALL services across cluster"
elif [ ${#TARGETS[@]} -gt 0 ]; then
    # Check if targets are hosts or services
    EXPANDED_SERVICES=()
    HOST_TARGETS=()
    SERVICE_TARGETS=()

    for target in "${TARGETS[@]}"; do
        if is_valid_host "$target"; then
            # It's a host identifier - get all services on that host
            HOST_TARGETS+=("$target")
            while IFS= read -r service; do
                if [ -n "$service" ]; then
                    EXPANDED_SERVICES+=("$service")
                fi
            done < <(get_services_by_host "$target")
        else
            # It's a service name - resolve it (handles both service keys and directory names)
            resolved_service=$(resolve_service_name "$target")
            SERVICE_TARGETS+=("$target")
            EXPANDED_SERVICES+=("$resolved_service")
        fi
    done

    SERVICE_LIST="${EXPANDED_SERVICES[*]}"

    # Print what we're processing
    if [ ${#HOST_TARGETS[@]} -gt 0 ]; then
        echo "📋 Processing all services on hosts: ${HOST_TARGETS[*]}"
        if [ ${#SERVICE_TARGETS[@]} -gt 0 ]; then
            echo "   Plus specific services: ${SERVICE_TARGETS[*]}"
        fi
    else
        echo "📋 Processing services: ${SERVICE_TARGETS[*]}"
    fi
else
    # No targets specified - default to local host services
    echo "📋 No target specified, defaulting to services on local host: $LOCAL_HOSTNAME"
    EXPANDED_SERVICES=()
    while IFS= read -r service; do
        if [ -n "$service" ]; then
            EXPANDED_SERVICES+=("$service")
        fi
    done < <(get_services_by_host "$LOCAL_HOSTNAME")

    if [ ${#EXPANDED_SERVICES[@]} -eq 0 ]; then
        echo "❌ No services found on local host: $LOCAL_HOSTNAME"
        exit 1
    fi

    SERVICE_LIST="${EXPANDED_SERVICES[*]}"
fi

echo ""

# Regenerate Caddyfile if doing restart/rebuild/start
if [[ "$ACTION" == "restart" || "$ACTION" == "start" ]]; then
    if ! update_caddy_from_registry "$SCRIPT_DIR" "$REGISTRY_FILE"; then
        echo "WARNING: Caddy update failed - check /tmp/cluster-compose.log"
    fi
fi


# Ensure Docker network exists only on hosts we're actually using
echo "=========================================="
echo "ENSURING DOCKER NETWORKS"
echo "=========================================="
echo ""

# Collect unique hosts from our service list
TARGETED_HOSTS=()
for service in $SERVICE_LIST; do
    host=""
    type=""
    eval "$(get_service_info "$service")"

    if [ -n "$host" ] && [ "$type" = "docker" ]; then
        # Add to array if not already present
        already_present=0
        for existing in "${TARGETED_HOSTS[@]}"; do
            if [ "$existing" = "$host" ]; then
                already_present=1
                break
            fi
        done
        if [ "$already_present" -eq 0 ]; then
            TARGETED_HOSTS+=("$host")
        fi
    fi
done

# Only ensure networks on hosts we're actually managing
for host in "${TARGETED_HOSTS[@]}"; do
    ensure_docker_network "$host"
done

echo ""

# Process each service sequentially for now (parallel builds cause issues)
for service in $SERVICE_LIST; do
    echo "🔍 Processing: $service"

    # Get service info from registry
    host=""
    type=""
    path=""
    eval "$(get_service_info "$service")"

    if [ -z "$host" ] || [ -z "$type" ] || [ -z "$path" ]; then
        echo "  ⚠️  Missing configuration in registry - skipping"
        echo ""
        continue
    fi

    echo "  Host: $host"
    echo "  Type: $type"
    echo "  Path: $path"

    # Dispatch to appropriate handler and check return codes
    case $type in
        docker)
            if ! manage_docker_service "$host" "$path" "$service" "$ACTION"; then
                echo "  ⚠️  Failed to manage docker service: $service"
                FAILED_SERVICES+=("$service")
            fi
            ;;
        native)
            if ! manage_native_service "$host" "$path" "$service" "$ACTION"; then
                echo "  ⚠️  Failed to manage native service: $service"
                FAILED_SERVICES+=("$service")
            fi
            ;;
        local)
            if ! manage_local_service "$host" "$path" "$service" "$ACTION"; then
                echo "  ⚠️  Failed to manage local service: $service"
                FAILED_SERVICES+=("$service")
            fi
            ;;
        *)
            echo "  ✗ Unknown deployment type: $type"
            FAILED_SERVICES+=("$service")
            ;;
    esac

    echo ""
done

# Post-action health check (skip for shutdown)
if [[ "$ACTION" != "shutdown" ]]; then
    echo "=========================================="
    echo "POST-ACTION HEALTH CHECK"
    echo "=========================================="
    echo ""
    if ! "$SCRIPT_DIR/portoser" health --all; then
        echo "⚠  Health check reported issues (see output above)"
    fi
    echo ""
fi

# Summarize any start/restart failures for local services
# Use enhanced reporting if verification module was loaded
if [ ${#FAILED_SERVICES[@]} -gt 0 ]; then
    if type report_failed_services &>/dev/null; then
        # Use enhanced reporting from verification module
        if ! report_failed_services; then
            exit 1
        fi
    else
        # Fallback to simple reporting
        echo "⚠  Some services reported failures: ${FAILED_SERVICES[*]}"
        exit 1
    fi
fi

# Caddy reload is now handled by update_caddy_from_registry above

# Cleanup build cache
cleanup_build_cache

echo "=============================="
echo "✅ $ACTION completed successfully"
echo "=============================="
