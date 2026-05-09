#!/usr/bin/env bash
# lib/docker_registry.sh - Docker Registry Management Library
#
# This library provides functions for managing a Docker registry service
# that runs on a designated registry host and serves images to the cluster.
#
# Registry Configuration (override via env):
#   - REGISTRY_DIR        Location of registry data on the registry host
#   - REGISTRY_PORT       External port (default 5555)
#   - REGISTRY_HOST       Registry hostname (default localhost)
#   - REGISTRY_HOST_IP    Registry host IP (used for /etc/hosts entries)
#   - Auth: Basic auth with htpasswd
#   - TLS: Self-signed certificates via certificates.sh
#
# Functions:
#   - docker_registry_start()
#   - docker_registry_stop()
#   - docker_registry_restart()
#   - docker_registry_health()
#   - docker_registry_status()
#   - docker_registry_images()
#   - docker_registry_auth_list()
#   - docker_registry_auth_update()
#   - docker_registry_certs_check()
#   - docker_registry_storage_status()

set -euo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================

REGISTRY_DIR="${REGISTRY_DIR:-${HOME}/portoser/docker-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5555}"
REGISTRY_INTERNAL_PORT="${REGISTRY_INTERNAL_PORT:-5000}"
REGISTRY_HOST="${REGISTRY_HOST:-localhost}"
REGISTRY_URL="${REGISTRY_URL:-https://${REGISTRY_HOST}:${REGISTRY_INTERNAL_PORT}}"
REGISTRY_CONTAINER="${REGISTRY_CONTAINER:-docker-registry}"
REGISTRY_COMPOSE="${REGISTRY_COMPOSE:-${REGISTRY_DIR}/docker-compose.yml}"
REGISTRY_AUTH_FILE="${REGISTRY_AUTH_FILE:-${REGISTRY_DIR}/auth/htpasswd}"
REGISTRY_CERTS_DIR="${REGISTRY_CERTS_DIR:-${REGISTRY_DIR}/certs}"
REGISTRY_DATA_DIR="${REGISTRY_DATA_DIR:-${REGISTRY_DIR}/data}"
REGISTRY_HOST_IP="${REGISTRY_HOST_IP:-127.0.0.1}"
REGISTRY_USERNAME="${REGISTRY_USERNAME:-admin}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-changeme}"
readonly HEALTH_CHECK_WAIT=3

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Print colored output
_registry_print() {
    local color="$1"
    shift
    local message="$*"

    case "$color" in
        red)    echo -e "\033[0;31m${message}\033[0m" ;;
        green)  echo -e "\033[0;32m${message}\033[0m" ;;
        yellow) echo -e "\033[0;33m${message}\033[0m" ;;
        blue)   echo -e "\033[0;34m${message}\033[0m" ;;
        *)      echo "$message" ;;
    esac
}

# Check if registry directory exists
_registry_check_dir() {
    if [ ! -d "$REGISTRY_DIR" ]; then
        _registry_print red "Error: Registry directory not found: $REGISTRY_DIR"
        return 1
    fi
    return 0
}

# Check if docker-compose.yml exists
_registry_check_compose() {
    if [ ! -f "$REGISTRY_COMPOSE" ]; then
        _registry_print red "Error: docker-compose.yml not found: $REGISTRY_COMPOSE"
        return 1
    fi
    return 0
}

# Check if container is running
_registry_is_running() {
    docker ps --filter "name=${REGISTRY_CONTAINER}" --format "{{.Names}}" 2>/dev/null | grep -q "^${REGISTRY_CONTAINER}$"
}

# Check if container exists (running or stopped)
_registry_exists() {
    docker ps -a --filter "name=${REGISTRY_CONTAINER}" --format "{{.Names}}" 2>/dev/null | grep -q "^${REGISTRY_CONTAINER}$"
}

# Check if Docker daemon is running
_registry_check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        _registry_print red "Error: docker command not found. Please install Docker."
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        _registry_print red "Error: Docker daemon is not running"
        return 1
    fi

    return 0
}

# Check if port is available
_registry_check_port() {
    local port="$1"
    if lsof -Pi ":${port}" -sTCP:LISTEN -t >/dev/null 2>&1; then
        _registry_print red "Error: Port ${port} is already in use"
        lsof -Pi ":${port}" -sTCP:LISTEN 2>/dev/null | tail -n +2
        return 1
    fi
    return 0
}

# ============================================================================
# LIFECYCLE MANAGEMENT
# ============================================================================

# Start the Docker registry container
docker_registry_start() {
    _registry_print blue "Starting Docker registry..."

    # Check Docker is available
    if ! _registry_check_docker; then
        return 1
    fi

    if ! _registry_check_dir || ! _registry_check_compose; then
        return 1
    fi

    if _registry_is_running; then
        _registry_print yellow "Registry is already running"
        return 0
    fi

    # Check if port is available (only if container doesn't exist)
    if ! _registry_exists; then
        if ! _registry_check_port "$REGISTRY_PORT"; then
            return 1
        fi
    fi

    # Start with docker compose
    local original_dir="$PWD"
    cd "$REGISTRY_DIR" || {
        _registry_print red "Failed to change to registry directory"
        return 1
    }

    local compose_output
    if compose_output=$(docker compose up -d 2>&1); then
        cd "$original_dir"
        _registry_print green "Registry started successfully"

        # Wait for it to be healthy
        _registry_print blue "Waiting for registry to be ready..."
        sleep "$HEALTH_CHECK_WAIT"

        if docker_registry_health --quiet; then
            _registry_print green "Registry is healthy and accepting connections"
            return 0
        else
            _registry_print yellow "Registry started but health check failed"
            return 1
        fi
    else
        cd "$original_dir"
        _registry_print red "Failed to start registry"
        echo "$compose_output"
        return 1
    fi
}

# Stop the Docker registry container
docker_registry_stop() {
    _registry_print blue "Stopping Docker registry..."

    # Check Docker is available
    if ! _registry_check_docker; then
        return 1
    fi

    if ! _registry_check_dir || ! _registry_check_compose; then
        return 1
    fi

    if ! _registry_is_running; then
        _registry_print yellow "Registry is not running"
        return 0
    fi

    local original_dir="$PWD"
    cd "$REGISTRY_DIR" || {
        _registry_print red "Failed to change to registry directory"
        return 1
    }

    local compose_output
    if compose_output=$(docker compose down 2>&1); then
        cd "$original_dir"
        _registry_print green "Registry stopped successfully"
        return 0
    else
        cd "$original_dir"
        _registry_print red "Failed to stop registry"
        echo "$compose_output"
        return 1
    fi
}

# Restart the Docker registry container
docker_registry_restart() {
    _registry_print blue "Restarting Docker registry..."

    # Check Docker is available
    if ! _registry_check_docker; then
        return 1
    fi

    if ! _registry_check_dir || ! _registry_check_compose; then
        return 1
    fi

    local original_dir="$PWD"
    cd "$REGISTRY_DIR" || {
        _registry_print red "Failed to change to registry directory"
        return 1
    }

    local compose_output
    if compose_output=$(docker compose restart 2>&1); then
        cd "$original_dir"
        _registry_print green "Registry restarted successfully"

        # Wait and check health
        sleep "$HEALTH_CHECK_WAIT"
        docker_registry_health --quiet
        return $?
    else
        cd "$original_dir"
        _registry_print red "Failed to restart registry"
        echo "$compose_output"
        return 1
    fi
}

# Show registry status
docker_registry_status() {
    _registry_print blue "Docker Registry Status"
    echo "=========================================="
    echo ""

    # Check if running
    if _registry_is_running; then
        _registry_print green "Status: RUNNING"
    elif _registry_exists; then
        _registry_print yellow "Status: STOPPED"
    else
        _registry_print red "Status: NOT FOUND"
    fi

    echo ""
    echo "Configuration:"
    echo "  Directory: $REGISTRY_DIR"
    echo "  URL: $REGISTRY_URL"
    echo "  External Port: $REGISTRY_PORT"
    echo "  Container: $REGISTRY_CONTAINER"
    echo ""

    # Show container details if running
    if _registry_is_running; then
        echo "Container Details:"
        docker ps --filter "name=${REGISTRY_CONTAINER}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo ""

        # Show resource usage
        echo "Resource Usage:"
        docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" "$REGISTRY_CONTAINER" 2>/dev/null || true
        echo ""
    fi

    # Show health
    docker_registry_health

    return 0
}

# ============================================================================
# HEALTH CHECKS
# ============================================================================

# Check registry health
docker_registry_health() {
    local quiet=false
    local verbose=false

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quiet) quiet=true; shift ;;
            --verbose) verbose=true; shift ;;
            *) shift ;;
        esac
    done

    if [ "$quiet" = false ]; then
        echo "Health Check:"
    fi

    # Check if container is running
    if ! _registry_is_running; then
        if [ "$quiet" = false ]; then
            _registry_print red "  Container: NOT RUNNING"
        fi
        return 1
    fi

    if [ "$quiet" = false ]; then
        _registry_print green "  Container: Running"
    fi

    # Check HTTP endpoint
    local start_time
    start_time=$(date +%s%3N)
    if timeout 5 curl -k -s "https://localhost:${REGISTRY_PORT}/v2/" >/dev/null 2>&1; then
        local end_time
        end_time=$(date +%s%3N)
        local response_time
        response_time=$((end_time - start_time))

        if [ "$quiet" = false ]; then
            _registry_print green "  HTTP Endpoint: OK (${response_time}ms)"
        fi
    else
        if [ "$quiet" = false ]; then
            _registry_print red "  HTTP Endpoint: FAILED"
        fi
        return 1
    fi

    # Check storage
    if [ -d "$REGISTRY_DATA_DIR" ]; then
        if [ "$quiet" = false ]; then
            _registry_print green "  Storage: Accessible"
        fi
    else
        if [ "$quiet" = false ]; then
            _registry_print red "  Storage: NOT FOUND"
        fi
        return 1
    fi

    # Verbose checks
    if [ "$verbose" = true ]; then
        echo ""
        echo "Detailed Health:"

        # Check auth file
        if [ -f "$REGISTRY_AUTH_FILE" ]; then
            _registry_print green "  Auth File: Present"
        else
            _registry_print yellow "  Auth File: Missing"
        fi

        # Check certificates
        if [ -f "$REGISTRY_CERTS_DIR/domain.crt" ]; then
            _registry_print green "  Certificates: Present"

            # Check expiry
            local expiry_date expiry_epoch now_epoch days_until_expiry
            expiry_date=$(openssl x509 -in "$REGISTRY_CERTS_DIR/domain.crt" -noout -enddate 2>/dev/null | cut -d= -f2)

            if [ -n "$expiry_date" ]; then
                expiry_epoch=$(date -j -f "%b %d %T %Y %Z" "$expiry_date" +%s 2>/dev/null || echo 0)
                now_epoch=$(date +%s)

                if [ "$expiry_epoch" -gt 0 ]; then
                    days_until_expiry=$(( (expiry_epoch - now_epoch) / 86400 ))

                    if [ $days_until_expiry -gt 30 ]; then
                        _registry_print green "  Certificate Expiry: ${days_until_expiry} days"
                    elif [ $days_until_expiry -gt 0 ]; then
                        _registry_print yellow "  Certificate Expiry: ${days_until_expiry} days (renew soon)"
                    else
                        _registry_print red "  Certificate Expiry: EXPIRED"
                    fi
                else
                    _registry_print yellow "  Certificate Expiry: Cannot parse date"
                fi
            else
                _registry_print yellow "  Certificate Expiry: Cannot read certificate"
            fi
        else
            _registry_print red "  Certificates: Missing"
        fi

        # Check logs for errors
        if docker ps --filter "name=${REGISTRY_CONTAINER}" --format "{{.Names}}" >/dev/null 2>&1; then
            local error_count
            error_count=$(docker logs --tail 100 "$REGISTRY_CONTAINER" 2>&1 | grep -ci error)
            if [ "$error_count" -eq 0 ]; then
                _registry_print green "  Recent Errors: None"
            else
                _registry_print yellow "  Recent Errors: ${error_count} in last 100 log lines"
            fi
        else
            _registry_print yellow "  Recent Errors: Cannot check (container not found)"
        fi
    fi

    return 0
}

# ============================================================================
# IMAGE MANAGEMENT
# ============================================================================

# List images in registry
docker_registry_images() {
    local verbose=false

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verbose) verbose=true; shift ;;
            *) shift ;;
        esac
    done

    _registry_print blue "Registry Images"
    echo "=========================================="
    echo ""

    # Check if running
    if ! _registry_is_running; then
        _registry_print red "Registry is not running"
        return 1
    fi

    # Get catalog from API
    local catalog_response
    if ! catalog_response=$(curl -k -s -u "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" "https://localhost:${REGISTRY_PORT}/v2/_catalog" 2>&1); then
        _registry_print red "Failed to query registry API"
        echo "$catalog_response"
        return 1
    fi

    # Parse repositories
    local repositories
    repositories=$(echo "$catalog_response" | grep -o '"repositories":\[.*\]' | sed 's/"repositories":\[//;s/\]//;s/"//g')

    if [ -z "$repositories" ] || [ "$repositories" = "null" ]; then
        _registry_print yellow "No images found in registry"
        return 0
    fi

    # Process each repository
    echo "$repositories" | tr ',' '\n' | while read -r repo; do
        if [ -n "$repo" ]; then
            echo "Repository: $repo"

            # Get tags for this repository
            local tags_response
            if tags_response=$(curl -k -s -u "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" "https://localhost:${REGISTRY_PORT}/v2/${repo}/tags/list" 2>&1); then
                local tags
                tags=$(echo "$tags_response" | grep -o '"tags":\[.*\]' | sed 's/"tags":\[//;s/\]//;s/"//g')

                if [ -n "$tags" ] && [ "$tags" != "null" ]; then
                    echo "$tags" | tr ',' '\n' | while read -r tag; do
                        if [ -n "$tag" ]; then
                            echo "  - ${repo}:${tag}"

                            if [ "$verbose" = true ]; then
                                # Get manifest for size info (simplified)
                                local manifest
                                if manifest=$(curl -k -s -u "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" \
                                    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
                                    "https://localhost:${REGISTRY_PORT}/v2/${repo}/manifests/${tag}" 2>&1); then

                                    if [ -n "$manifest" ]; then
                                        local config_size
                                        config_size=$(echo "$manifest" | grep -o '"size":[0-9]*' | head -1 | cut -d: -f2)
                                        if [ -n "$config_size" ] && [ "$config_size" -gt 0 ] 2>/dev/null; then
                                            local size_mb
                                            size_mb=$((config_size / 1024 / 1024))
                                            echo "    Size: ~${size_mb}MB"
                                        fi
                                    fi
                                fi
                            fi
                        fi
                    done
                fi
            else
                _registry_print yellow "  Failed to get tags"
            fi
            echo ""
        fi
    done

    return 0
}

# ============================================================================
# AUTHENTICATION MANAGEMENT
# ============================================================================

# List authenticated users
docker_registry_auth_list() {
    _registry_print blue "Registry Authentication Users"
    echo "=========================================="
    echo ""

    if [ ! -f "$REGISTRY_AUTH_FILE" ]; then
        _registry_print yellow "No authentication file found"
        return 1
    fi

    echo "Users in htpasswd file:"
    while IFS=: read -r username _; do
        echo "  - $username"
    done < "$REGISTRY_AUTH_FILE"

    echo ""
    _registry_print blue "Note: Password hashes are stored securely"

    return 0
}

# Update registry credentials
docker_registry_auth_update() {
    local username="$1"
    local password="$2"

    if [ -z "$username" ] || [ -z "$password" ]; then
        _registry_print red "Usage: docker_registry_auth_update USERNAME PASSWORD"
        return 1
    fi

    _registry_print blue "Updating credentials for user: $username"

    # Check if htpasswd is available
    if ! command -v htpasswd >/dev/null 2>&1; then
        _registry_print red "Error: htpasswd command not found"
        _registry_print yellow "Install with: brew install httpd"
        return 1
    fi

    # Create auth directory if it doesn't exist
    if ! mkdir -p "$(dirname "$REGISTRY_AUTH_FILE")"; then
        _registry_print red "ERROR: Failed to create auth directory"
        return 1
    fi

    # Update or create user
    local htpasswd_output
    if htpasswd_output=$(htpasswd -Bb "$REGISTRY_AUTH_FILE" "$username" "$password" 2>&1); then
        _registry_print green "Credentials updated successfully"

        # Restart registry to apply changes
        _registry_print blue "Restarting registry to apply changes..."
        docker_registry_restart

        return $?
    else
        _registry_print red "Failed to update credentials"
        echo "$htpasswd_output"
        return 1
    fi
}

# ============================================================================
# CERTIFICATE MANAGEMENT
# ============================================================================

# Check certificate expiry
docker_registry_certs_check() {
    local days_warning=30

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days) days_warning="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    _registry_print blue "Registry Certificates"
    echo "=========================================="
    echo ""

    if [ ! -d "$REGISTRY_CERTS_DIR" ]; then
        _registry_print red "Certificates directory not found: $REGISTRY_CERTS_DIR"
        return 1
    fi

    local cert_files=("domain.crt" "ca.crt")
    local has_error=false

    for cert_file in "${cert_files[@]}"; do
        local cert_path="$REGISTRY_CERTS_DIR/$cert_file"

        echo "Certificate: $cert_file"

        if [ ! -f "$cert_path" ]; then
            _registry_print red "  Status: NOT FOUND"
            has_error=true
            echo ""
            continue
        fi

        # Get certificate details
        local subject issuer start_date end_date
        subject=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed 's/subject=//')
        issuer=$(openssl x509 -in "$cert_path" -noout -issuer 2>/dev/null | sed 's/issuer=//')
        start_date=$(openssl x509 -in "$cert_path" -noout -startdate 2>/dev/null | cut -d= -f2)
        end_date=$(openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | cut -d= -f2)

        if [ -z "$subject" ] || [ -z "$end_date" ]; then
            _registry_print red "  Status: INVALID CERTIFICATE"
            has_error=true
            echo ""
            continue
        fi

        echo "  Subject: $subject"
        echo "  Issuer: $issuer"
        echo "  Valid From: $start_date"
        echo "  Valid Until: $end_date"

        # Calculate days until expiry
        local expiry_epoch now_epoch days_until_expiry
        expiry_epoch=$(date -j -f "%b %d %T %Y %Z" "$end_date" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)

        if [ "$expiry_epoch" -eq 0 ]; then
            _registry_print yellow "  Status: Cannot parse expiry date"
            has_error=true
        else
            days_until_expiry=$(( (expiry_epoch - now_epoch) / 86400 ))

            if [ $days_until_expiry -lt 0 ]; then
                _registry_print red "  Status: EXPIRED (${days_until_expiry#-} days ago)"
                has_error=true
            elif [ $days_until_expiry -lt "$days_warning" ]; then
                _registry_print yellow "  Status: EXPIRES SOON (${days_until_expiry} days)"
                has_error=true
            else
                _registry_print green "  Status: VALID (${days_until_expiry} days remaining)"
            fi
        fi

        echo ""
    done

    if [ "$has_error" = true ]; then
        _registry_print yellow "Recommendation: Regenerate certificates"
        echo "  Run: source ${PORTOSER_ROOT:-.}/lib/certificates.sh"
        echo "       generate_server_cert \"registry\" \"$REGISTRY_HOST\" \"$REGISTRY_HOST_IP\" \"$REGISTRY_CERTS_DIR\""
        return 1
    fi

    return 0
}

# ============================================================================
# STORAGE MANAGEMENT
# ============================================================================

# Show storage usage
docker_registry_storage_status() {
    _registry_print blue "Registry Storage Status"
    echo "=========================================="
    echo ""

    if [ ! -d "$REGISTRY_DATA_DIR" ]; then
        _registry_print red "Storage directory not found: $REGISTRY_DATA_DIR"
        return 1
    fi

    # Overall storage usage
    echo "Storage Location: $REGISTRY_DATA_DIR"
    echo ""

    local total_size
    total_size=$(du -sh "$REGISTRY_DATA_DIR" 2>/dev/null | awk '{print $1}')
    echo "Total Size: $total_size"
    echo ""

    # Breakdown by repository
    echo "Storage by Repository:"
    local repos_dir="$REGISTRY_DATA_DIR/docker/registry/v2/repositories"

    if [ -d "$repos_dir" ]; then
        local find_output
        if find_output=$(find "$repos_dir" -maxdepth 1 -mindepth 1 -type d 2>&1); then
            if [ -n "$find_output" ]; then
                echo "$find_output" | while read -r repo_dir; do
                    local repo_name
                    repo_name=$(basename "$repo_dir")
                    local repo_size
                    repo_size=$(du -sh "$repo_dir" 2>/dev/null | awk '{print $1}')
                    echo "  $repo_name: $repo_size"
                done
            else
                _registry_print yellow "  No repositories found"
            fi
        else
            _registry_print yellow "  Cannot access repositories directory"
        fi
    else
        _registry_print yellow "  No repositories found"
    fi

    echo ""

    # Check available disk space
    local available_space
    available_space=$(df -h "$REGISTRY_DATA_DIR" | awk 'NR==2 {print $4}')
    local used_percent
    used_percent=$(df -h "$REGISTRY_DATA_DIR" | awk 'NR==2 {print $5}')

    echo "Disk Usage:"
    echo "  Available: $available_space"
    echo "  Used: $used_percent"

    # Warning if disk is getting full
    local used_num="${used_percent//%/}"
    if [ -n "$used_num" ] && [ "$used_num" -eq "$used_num" ] 2>/dev/null; then
        if [ "$used_num" -gt 80 ]; then
            _registry_print yellow "  Warning: Disk usage is high!"
            echo "  Consider running garbage collection:"
            echo "    docker exec $REGISTRY_CONTAINER registry garbage-collect /etc/docker/registry/config.yml"
        fi
    fi

    echo ""

    return 0
}

# ============================================================================
# MAIN EXPORTS
# ============================================================================

# Export all functions for use in other scripts
export -f docker_registry_start
export -f docker_registry_stop
export -f docker_registry_restart
export -f docker_registry_health
export -f docker_registry_status
export -f docker_registry_images
export -f docker_registry_auth_list
export -f docker_registry_auth_update
export -f docker_registry_certs_check
export -f docker_registry_storage_status
