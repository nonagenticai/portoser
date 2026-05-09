#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Cluster-Wide Service Management Script
# Uses registry.yml as source of truth to manage services across all hosts
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_FILE="${REGISTRY_FILE:-$SCRIPT_DIR/registry.yml}"
# Fall back to the bundled example registry if the user has not yet copied it.
[[ -f "$REGISTRY_FILE" ]] || REGISTRY_FILE="$SCRIPT_DIR/registry.example.yml"
LOCAL_HOSTNAME=$(hostname -s)

# Source verification module
source "$SCRIPT_DIR/lib/cluster/verification.sh"

# Source SSH key authentication module
source "$SCRIPT_DIR/lib/cluster/ssh_keys.sh"

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

# Source Caddy integration module
if [ -f "$SCRIPT_DIR/lib/caddy_integration.sh" ]; then
    source "$SCRIPT_DIR/lib/caddy_integration.sh"
fi

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

is_pi_host() {
    local host="$1"
    [[ "$host" =~ ^pi[1-4]$ ]]
}

# Registry functions removed - using local-only operations

# =============================================================================
# REMOTE EXECUTION FUNCTIONS
# =============================================================================

# Wrapper for run_on_host() to handle local execution
# The ssh_keys.sh module provides the remote SSH execution
# This wrapper adds local execution support
_run_on_host_ssh() {
    # Call the ssh_keys.sh version
    command run_on_host "$@"
}

run_on_host() {
    local host="$1"
    local command="$2"

    # Check if this is the local host
    if [ "$host" = "$LOCAL_HOSTNAME" ]; then
        # Run locally using bash -c for consistency
        bash -c "$command"
    else
        # Run remotely via SSH keys module
        _run_on_host_ssh "$host" "$command"
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
    local all_running=true
    while IFS=: read -r container status; do
        if [[ "$status" =~ Up|running ]]; then
            echo "    ✓ $container: $status"
        else
            echo "    ✗ $container: $status"
            all_running=false
        fi
    done <<< "$container_status"

    if [ "$all_running" = true ]; then
        return 0
    else
        return 1
    fi
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
# PI BUILD FUNCTIONS (Cross-platform ARM64 builds)
# =============================================================================

# Find source directory for Pi service
find_pi_service_source() {
    local service_name="$1"
    local service_path="$2"  # Added service_path parameter

    # Extract directory name from service path (e.g., /code_graph_helper/docker-compose.yml -> code_graph_helper)
    local path_dirname
    path_dirname=$(dirname "$service_path")
    path_dirname="${path_dirname#/}"  # Remove leading slash

    # Convert service name: replace hyphens with underscores
    local normalized_name="${service_name//-/_}"

    # Source code location for service repos. Override with SOURCE_REPO_BASE
    # in the environment (defaults to ~/Documents to preserve legacy layout).
    local source_base="${SOURCE_REPO_BASE:-${HOME}/Documents}"

    # Try different naming patterns (path dirname first, then fallbacks)
    local patterns=(
        "${source_base}/${path_dirname}"  # Try the path from registry first
        "${source_base}/${normalized_name}_api"
        "${source_base}/${normalized_name}_service"
        "${source_base}/${normalized_name}"
        "${source_base}/${service_name}_api"
        "${source_base}/${service_name}_service"
        "${source_base}/${service_name}"
    )

    for dir in "${patterns[@]}"; do
        if [ -d "$dir" ]; then
            echo "$dir"
            return 0
        fi
    done

    return 1
}

build_pi_image() {
    local service_name="$1"
    local service_path="$2"
    local host="$3"

    # Local-only image tag (no registry)
    local image_tag="${service_name}:latest"

    # Find source directory
    local build_dir
    build_dir=$(find_pi_service_source "$service_name" "$service_path")

    if [ -z "$build_dir" ]; then
        echo "  ✗ Could not find source directory for $service_name"
        echo "  Looked in ${SOURCE_REPO_BASE:-${HOME}/Documents} for patterns: ${service_name}*, ${service_name//-/_}*, $(dirname "$service_path" | sed 's|^/||')"
        return 1
    fi

    echo "  [buildx] Building ARM64 image locally for $service_name"
    echo "  Image tag: $image_tag"
    echo "  Build directory: $build_dir"

    # Change to build directory
    cd "$build_dir" || {
        echo "  ✗ Failed to cd to $build_dir"
        return 1
    }

    # Build locally using buildx for ARM64 (load to local Docker)
    if docker buildx build \
        --platform linux/arm64 \
        --tag "$image_tag" \
        --load \
        --no-cache \
        . 2>&1 | sed 's/^/    /'; then
        echo "  ✓ Successfully built $service_name locally"
        cd "$SCRIPT_DIR"
        return 0
    else
        echo "  ✗ Failed to build $service_name"
        cd "$SCRIPT_DIR"
        return 1
    fi
}

# =============================================================================
# SERVICE MANAGEMENT FUNCTIONS
# =============================================================================

manage_docker_service() {
    local host="$1"
    local service_path="$2"
    local service_name="$3"
    local action="$4"

    local base_path="${BASE_PATHS[$host]}"
    local full_path
    full_path="${base_path}$(dirname "$service_path")"

    echo "  [$host] Managing docker service: $service_name"

    # Special handling for Pi hosts on rebuild - build locally with buildx
    if is_pi_host "$host" && [ "$REBUILD_NOCACHE" = true ]; then
        # Check if source code exists for this service
        local build_dir
        build_dir=$(find_pi_service_source "$service_name" "$service_path")

        if [ -z "$build_dir" ]; then
            echo "  No source code found - using pre-built image from Docker Hub"
            # For services without source (like grafana), just pull and restart
            local restart_cmd="mkdir -p '$full_path' && cd '$full_path' && docker compose pull && docker compose down --volumes --remove-orphans && docker compose up -d"

            if ! run_on_host_checked "$host" "$restart_cmd" "$service_name"; then
                echo "  ✗ Failed to restart $service_name on $host"
                track_service_failure "$service_name" "Docker compose restart failed (no source)" "docker" "$host"
                return 1
            fi

            # Verify containers are running
            if verify_containers_running "$host" "$service_name" "$full_path"; then
                echo "  ✓ Completed restart for $service_name on $host"
                return 0
            else
                echo "  ✗ Containers not running properly for $service_name on $host"
                track_service_failure "$service_name" "Containers not running after restart" "docker" "$host"
                return 1
            fi
        fi

        echo "  Detected Pi host - building ARM64 image locally with buildx"

        # Build image locally using buildx
        if ! build_pi_image "$service_name" "$service_path" "$host"; then
            echo "  ✗ Failed to build image for $service_name"
            track_service_failure "$service_name" "Failed to build ARM64 image with buildx" "docker" "$host"
            return 1
        fi

        # Copy docker-compose.yml to the Pi
        echo "  Copying docker-compose.yml to $host..."
        local ssh_host="${CLUSTER_HOSTS[$host]}"

        # Create directory and copy compose file
        if ! run_on_host "$host" "mkdir -p '$full_path'"; then
            echo "  ✗ Failed to create directory on $host"
            track_service_failure "$service_name" "Failed to create directory on host" "docker" "$host"
            return 1
        fi

        # Use SSH key authentication for scp
        if ! scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$build_dir/docker-compose.yml" "$ssh_host:$full_path/"; then
            echo "  ✗ Failed to copy docker-compose.yml to $host"
            track_service_failure "$service_name" "Failed to copy docker-compose.yml to host" "docker" "$host"
            return 1
        fi

        # Copy .env if it exists
        if [ -f "$build_dir/.env" ]; then
            echo "  Copying .env to $host..."
            scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$build_dir/.env" "$ssh_host:$full_path/" || true
        fi

        # Save and transfer the local image to Pi
        local image_tag="${service_name}:latest"

        echo "  Transferring local image to $host..."

        # Export image, transfer, and deploy with forced cleanup if containers are stuck
        local deploy_cmd="mkdir -p '$full_path' && cd '$full_path' && \
            (docker compose down --volumes --remove-orphans --timeout 10 || docker compose kill || true) && \
            docker compose up -d"

        # First, save and transfer the image
        echo "  Saving image locally..."
        # Use SSH key authentication for docker image transfer
        if docker save "$image_tag" | ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$ssh_host" "docker load"; then
            echo "  ✓ Image transferred to $host"
        else
            echo "  ✗ Failed to transfer image to $host"
            track_service_failure "$service_name" "Failed to transfer Docker image to host" "docker" "$host"
            return 1
        fi

        # Deploy on the Pi
        if ! run_on_host_checked "$host" "$deploy_cmd" "$service_name"; then
            echo "  ✗ Failed to deploy $service_name on $host"
            echo "  Possible causes:"
            echo "    - Container still stuck (may need to restart Docker on $host)"
            echo "    - docker-compose.yml has errors"
            track_service_failure "$service_name" "Docker compose deployment failed" "docker" "$host"
            return 1
        fi

        # Verify containers are running
        if verify_containers_running "$host" "$service_name" "$full_path"; then
            echo "  ✓ Completed rebuild and deploy for $service_name on $host"
            return 0
        else
            echo "  ✗ Deployment completed but containers not running properly for $service_name on $host"
            echo "  Check logs with: ssh $host 'cd $full_path && docker compose logs'"
            track_service_failure "$service_name" "Containers not running after deployment" "docker" "$host"
            return 1
        fi
    fi

    # Normal flow for Mac hosts or non-rebuild operations
    local compose_cmd=""
    case $action in
        start)
            if [ "$REBUILD_NOCACHE" = true ]; then
                compose_cmd="mkdir -p '$full_path' && cd '$full_path' && docker compose build --no-cache && docker compose up -d"
            else
                compose_cmd="mkdir -p '$full_path' && cd '$full_path' && docker compose up -d"
            fi
            ;;
        restart)
            if [ "$REBUILD_NOCACHE" = true ]; then
                compose_cmd="mkdir -p '$full_path' && cd '$full_path' && docker compose down --volumes --remove-orphans && docker compose build --no-cache && docker compose up -d"
            else
                compose_cmd="mkdir -p '$full_path' && cd '$full_path' && docker compose down --volumes --remove-orphans && docker compose up -d"
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
            return 0
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
        # Note: sudo commands now require passwordless sudo or SSH key-based authentication
        # If sudo requires a password, configure passwordless sudo for the service user
        # Example: echo "username ALL=(ALL) NOPASSWD: /path/to/command" >> /etc/sudoers.d/service

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

    if [ -n "$actual_cmd" ]; then
        # Run start/stop/restart as provided (expected to background itself if long-lived)
        # For backgrounded commands (ending with &), run asynchronously to avoid pipe hang
        if [[ "$actual_cmd" =~ \&[[:space:]]*$ ]]; then
            if ! run_on_host "$host" "$actual_cmd" >/dev/null 2>&1; then
                echo "  ✗ Failed to $action $service_name on $host"
                track_service_failure "$service_name" "Command execution failed: $actual_cmd" "local" "$host"
                return 1
            fi
        else
            if ! run_on_host "$host" "$actual_cmd" 2>&1 | sed 's/^/    /'; then
                echo "  ✗ Failed to $action $service_name on $host"
                track_service_failure "$service_name" "Command execution failed: $actual_cmd" "local" "$host"
                return 1
            fi
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
        local health_timeout=10  # seconds per health attempt
        if [ -n "$health_actual" ]; then
            echo "    Waiting for healthcheck..."
            local attempts=30   # 30 * 3s = 90s max
            local i=0
            while [ $i -lt $attempts ]; do
                # Run health command with a per-attempt timeout and capture its exit status
                # Use timeout command for cleaner timeout handling
                local timed_health="timeout ${health_timeout} bash -c '$health_actual'"
                if run_on_host "$host" "$timed_health" > /dev/null 2>&1; then
                    ok=1; break
                fi
                if (( i % 5 == 0 )); then echo "    ...health attempt $((i+1))/$attempts"; fi
                sleep 3
                i=$((i+1))
            done
        else
            # Fallback to status command if present
            local status_cmd="grep '^status:' '$service_file' | sed 's/^status:[[:space:]]*//' | head -1"
            local status_actual
            status_actual=$(run_on_host "$host" "$status_cmd" 2>/dev/null || echo "")
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
            return 0
        else
            echo "  ✗ $service_name failed health/status check"
            echo "    Logs: ${service_file%/service.yml}/logs or /tmp/portoser-${service_name}.log"
            track_service_failure "$service_name" "Health/status check failed after $action" "local" "$host"
            return 1
        fi
    else
        echo "  ⚠ No $cmd_type command found in service.yml"
        track_service_failure "$service_name" "No $cmd_type command in service.yml" "local" "$host"
        return 1
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
            # It's a service name
            SERVICE_TARGETS+=("$target")
            EXPANDED_SERVICES+=("$target")
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
    echo "❌ No services specified. Use 'all' or specify service/host names"
    show_help
    exit 1
fi

echo ""

# Regenerate Caddyfile if doing restart/rebuild all
if [[ "$ACTION" == "restart" && "$ALL_SERVICES" == true ]]; then
    echo "==========================================" 
    echo "REGENERATING CADDYFILE FROM REGISTRY"
    echo "=========================================="
    echo ""
    
    if [ -f "$SCRIPT_DIR/portoser" ]; then
        cd "$SCRIPT_DIR"
        ./portoser caddy regenerate || true  # Ignore exit code if validation succeeds
         echo "✓ Caddyfile regenerated"
    fi
fi

# Ensure Docker network exists on all hosts
echo "=========================================="
echo "ENSURING DOCKER NETWORKS"
echo "=========================================="
echo ""

# Get unique list of hosts that have Docker services
DOCKER_HOSTS=$(awk '
/^services:/ { in_services=1; next }
in_services && /^[a-z]+:/ { in_services=0 }
in_services && /^  [a-z][a-z0-9_-]+:$/ {
    service = $1
    gsub(/:/, "", service)
    in_service = 1
    next
}
in_service && /current_host:/ {
    gsub(/^[ \t]+current_host:[ \t]+/, "")
    host = $0
}
in_service && /deployment_type:/ {
    gsub(/^[ \t]+deployment_type:[ \t]+/, "")
    if ($0 == "docker") {
        print host
    }
    in_service = 0
}
' "$REGISTRY_FILE" | sort -u)

for host in $DOCKER_HOSTS; do
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

    # Dispatch to appropriate handler
    case $type in
        docker)
            if ! manage_docker_service "$host" "$path" "$service" "$ACTION"; then
                FAILED_SERVICES+=("$service")
            fi
            ;;
        native)
            if ! manage_native_service "$host" "$path" "$service" "$ACTION"; then
                FAILED_SERVICES+=("$service")
            fi
            ;;
        local)
            if ! manage_local_service "$host" "$path" "$service" "$ACTION"; then
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

# Report any failed services before final summary
if ! report_failed_services; then
    exit 1
fi

# Reload Caddy if we regenerated Caddyfile
if [[ "$ACTION" == "restart" && "$ALL_SERVICES" == true ]]; then
    echo "==========================================" 
    echo "RELOADING CADDY"
    echo "=========================================="
    echo ""
    
    caddy_host=$(awk '/^  caddy:/,/^  [a-z]/ {
        if (/current_host:/) {
            gsub(/^[ \t]+current_host:[ \t]+/, "")
            print
            exit
        }
    }' "$REGISTRY_FILE")
    
    if [ -n "$caddy_host" ]; then
        echo "Reloading Caddy on $caddy_host..."
        caddy_config="${BASE_PATHS[$caddy_host]}/caddy/Caddyfile"
        run_on_host "$caddy_host" "caddy reload --config $caddy_config"
        echo "✓ Caddy reloaded"
    fi
    echo ""
fi

# Cleanup build cache
cleanup_build_cache

echo "=============================="
echo "✅ $ACTION completed successfully"
echo "=============================="
