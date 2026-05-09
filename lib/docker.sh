#!/usr/bin/env bash
# docker.sh - Functions for Docker operations on local and remote machines


# Returns 0 (true) if MACHINE refers to the host running this script.
# Recognises both the literal "local" alias and the actual short hostname.
_is_local_machine() {
    local machine="$1"
    local self
    self=$(hostname -s 2>/dev/null || hostname | cut -d. -f1)
    [ "$machine" = "local" ] || [ "$machine" = "$self" ]
}

set -euo pipefail

# Import validation library. Resolve via this file's own directory so we
# don't depend on the caller having $SCRIPT_DIR set (broken under set -u).
_DOCKER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/utils/validation.sh
source "${_DOCKER_LIB_DIR}/utils/validation.sh"
unset _DOCKER_LIB_DIR

# Prepare secrets from Vault for Docker deployment
# Creates a temporary .env file with secrets from Vault
# Usage: prepare_vault_secrets_for_docker SERVICE_NAME MACHINE WORKING_DIR
prepare_vault_secrets_for_docker() {
    local service="$1"
    local machine="$2"
    local working_dir="$3"

    # Check if Vault is enabled and ready
    if ! vault_is_ready 2>/dev/null; then
        # Vault not available, fall back to existing .env file
        return 0
    fi

    # Try to get secrets from Vault
    local secrets
    secrets=$(vault_get_service_secrets "$service" "$machine" 2>/dev/null)

    if [ -z "$secrets" ]; then
        # No secrets in Vault for this service, use existing .env
        return 0
    fi

    # Create temporary .env file with Vault secrets
    local temp_env="$working_dir/.env.vault"

    echo "# Auto-generated from Vault - $(date)" > "$temp_env"
    echo "$secrets" >> "$temp_env"

    # If there's an existing .env, merge non-secret config
    if [ -f "$working_dir/.env" ]; then
        # Extract non-secret config (lines starting with # or non-uppercase vars)
        grep -E '^#|^[a-z_]' "$working_dir/.env" >> "$temp_env" 2>/dev/null || true
    fi

    echo "  ✓ Loaded secrets from Vault for $service"

    # Replace .env with vault version (backup original)
    if [ -f "$working_dir/.env" ]; then
        cp "$working_dir/.env" "$working_dir/.env.backup"
    fi
    mv "$temp_env" "$working_dir/.env"

    return 0
}

# Cleanup vault-generated .env file after deployment
# Usage: cleanup_vault_env_file WORKING_DIR
cleanup_vault_env_file() {
    local working_dir="$1"

    if [ -f "$working_dir/.env.backup" ]; then
        mv "$working_dir/.env.backup" "$working_dir/.env"
    fi
}

# Check if Docker context exists
# Usage: check_docker_context CONTEXT_NAME
check_docker_context() {
    local context="$1"

    if [ -z "$context" ]; then
        echo "Error: Context name required" >&2
        return 1
    fi

    if docker context ls --format '{{.Name}}' | grep -q "^${context}$"; then
        return 0
    else
        return 1
    fi
}

# Ensure Docker context exists, create if missing
# Usage: ensure_docker_context CONTEXT_NAME MACHINE
ensure_docker_context() {
    local context="$1"
    local machine="$2"

    if [ -z "$context" ] || [ -z "$machine" ]; then
        echo "Error: Context name and machine required" >&2
        return 1
    fi

    # Check if context already exists
    if check_docker_context "$context"; then
        return 0
    fi

    # Context doesn't exist, create it
    echo "Docker context '$context' not found, creating..."

    local ip
    ip=$(get_machine_ip "$machine")
    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")
    local ssh_port
    ssh_port=$(get_machine_ssh_port "$machine")

    if [ -z "$ip" ] || [ -z "$ssh_user" ]; then
        echo "Error: Could not get SSH connection info for machine '$machine'" >&2
        return 1
    fi

    # Build Docker host URL
    local docker_host
    if [ "$ssh_port" = "22" ]; then
        docker_host="ssh://${ssh_user}@${ip}"
    else
        docker_host="ssh://${ssh_user}@${ip}:${ssh_port}"
    fi

    echo "  Creating context: $context"
    echo "  Docker host: $docker_host"

    if docker context create "$context" --docker "host=${docker_host}" 2>&1; then
        echo "✓ Docker context '$context' created successfully"
        return 0
    else
        echo "✗ Failed to create Docker context '$context'" >&2
        return 1
    fi
}

# Resolve and ensure a context for a machine (defaults to ctx-${machine})
get_or_create_machine_context() {
    local machine="$1"
    local context="${2:-}"

    if [ -z "$machine" ]; then
        echo "Error: Machine name required" >&2
        return 1
    fi

    if [ -z "$context" ]; then
        context=$(get_machine_context "$machine" 2>/dev/null || echo "ctx-${machine}")
    fi

    if ! ensure_docker_context "$context" "$machine"; then
        return 1
    fi

    echo "$context"
}

# Build Docker image on local machine
# Usage: docker_build_local SERVICE_NAME
docker_build_local() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    local service_dir
    service_dir=$(get_service_directory "$service")
    local compose_file
    compose_file=$(get_service_compose_file "$service")

    if [ ! -d "$service_dir" ]; then
        echo "Error: Service directory not found: $service_dir" >&2
        return 1
    fi

    echo "Building Docker image for $service locally..."
    echo "  Directory: $service_dir"
    echo "  Compose file: $compose_file"

    cd "$service_dir" || {
        echo "Error: Cannot change to directory: $service_dir" >&2
        return 1
    }

    # Run poetry lock if pyproject.toml exists
    if [ -f "pyproject.toml" ]; then
        echo "Running poetry lock..."
        if poetry lock > /dev/null 2>&1; then
            echo "✓ Poetry lock completed"
        else
            echo "⚠ Poetry lock failed (continuing anyway)"
        fi
    fi

    # Build using docker compose
    if [ -f "$compose_file" ]; then
        docker compose -f "$compose_file" build
        local exit_code=$?
        cd - > /dev/null || return 1
        return $exit_code
    else
        echo "Error: Compose file not found: $service_dir/$compose_file" >&2
        cd - > /dev/null || return 1
        return 1
    fi
}

# Build Docker image on remote machine via context
# Usage: docker_build_remote SERVICE_NAME MACHINE
docker_build_remote() {
    local service="$1"
    local machine="$2"

    if [ -z "$service" ] || [ -z "$machine" ]; then
        echo "Error: Service name and machine required" >&2
        return 1
    fi

    local context
    if ! context=$(get_machine_context "$machine"); then
        echo "Error: Could not get Docker context for machine '$machine'" >&2
        return 1
    fi

    # Ensure Docker context exists (create if needed)
    if ! ensure_docker_context "$context" "$machine"; then
        echo "Error: Failed to ensure Docker context '$context'" >&2
        return 1
    fi

    local service_dir
    service_dir=$(get_service_directory "$service")
    local compose_file
    compose_file=$(get_service_compose_file "$service")

    echo "Building Docker image for $service on $machine (context: $context)..."

    cd "$service_dir" || {
        echo "Error: Cannot change to directory: $service_dir" >&2
        return 1
    }

    # Run poetry lock if pyproject.toml exists
    if [ -f "pyproject.toml" ]; then
        echo "Running poetry lock..."
        poetry lock > /dev/null 2>&1
    fi

    # Build using docker compose with context
    if [ -f "$compose_file" ]; then
        docker --context "$context" compose -f "$compose_file" build
        local exit_code=$?
        cd - > /dev/null || return 1
        return $exit_code
    else
        echo "Error: Compose file not found: $service_dir/$compose_file" >&2
        cd - > /dev/null || return 1
        return 1
    fi
}

# Deploy Docker container on remote machine
# Usage: docker_deploy SERVICE_NAME MACHINE
# SC2029: paths are sanitized via sanitize_for_shell; remote interpolation is
# intentional so the remote shell evaluates the resulting command.
# shellcheck disable=SC2029
docker_deploy() {
    local service="$1"
    local machine="$2"

    if [ -z "$service" ] || [ -z "$machine" ]; then
        echo "Error: Service name and machine required" >&2
        return 1
    fi

    # Get service directory and compose file path
    local docker_compose_path
    docker_compose_path=$(yq eval ".services.${service}.docker_compose" "$CADDY_REGISTRY_PATH")
    if [ "$docker_compose_path" = "null" ] || [ -z "$docker_compose_path" ]; then
        echo "Error: No docker_compose path found for $service" >&2
        return 1
    fi

    local service_dir
    service_dir=$(dirname "$docker_compose_path")
    local compose_file
    compose_file=$(basename "$docker_compose_path")

    echo "Deploying $service on $machine..."
    echo "  Service directory: $service_dir"

    # Check if this is local deployment (current host)
    if _is_local_machine "$machine"; then
        # Local deployment - service_dir should exist locally
        if [ ! -d "$service_dir" ]; then
            echo "Error: Service directory not found locally: $service_dir" >&2
            return 1
        fi

        cd "$service_dir" || {
            echo "Error: Cannot change to directory: $service_dir" >&2
            return 1
        }
        prepare_vault_secrets_for_docker "$service" "$machine" "$service_dir"

        local platform
        platform=$(get_service_platform "$service" "$machine" 2>/dev/null || echo "")

        local compose_has_build=0
        grep -q "^[[:space:]]*build:" "$compose_file" >/dev/null 2>&1 && compose_has_build=1
        local platform_env=""
        if [ "$platform" = "linux/arm64" ] && [ $compose_has_build -eq 1 ]; then
            platform_env="DOCKER_DEFAULT_PLATFORM=$platform"
        fi

        # Validate compose file path
        if ! validate_path "$compose_file"; then
            echo "Error: Invalid compose file path" >&2
            cleanup_vault_env_file "$service_dir"
            cd - > /dev/null || return 1
            return 1
        fi

        if [ -f "$compose_file" ]; then
            if [ -n "$platform_env" ]; then
                env "$platform_env" docker compose -f "$compose_file" up -d
            else
                docker compose -f "$compose_file" up -d
            fi
            local exit_code=$?
            cleanup_vault_env_file "$service_dir"
            cd - > /dev/null || return 1

            if [ $exit_code -eq 0 ]; then
                echo "✓ Successfully deployed $service on $machine"
                return 0
            else
                echo "✗ Failed to deploy $service on $machine"
                return 1
            fi
        else
            echo "Error: Compose file not found: $service_dir/$compose_file" >&2
            cleanup_vault_env_file "$service_dir"
            cd - > /dev/null || return 1
            return 1
        fi
    else
        # Remote deployment - run docker compose on remote machine via SSH
        local ssh_host
        ssh_host=$(get_ssh_host "$machine")
        local ssh_user
        ssh_user=$(get_machine_ssh_user "$machine")
        local context
        context=$(get_or_create_machine_context "$machine") || context=""

        if [ -z "$ssh_host" ] || [ -z "$ssh_user" ]; then
            echo "Error: Could not get SSH info for machine '$machine'" >&2
            return 1
        fi

        # Validate inputs
        if ! validate_service_name "$service"; then
            echo "Error: Invalid service name" >&2
            return 1
        fi
        if ! validate_path "$service_dir"; then
            echo "Error: Invalid service directory path" >&2
            return 1
        fi
        if ! validate_path "$compose_file"; then
            echo "Error: Invalid compose file path" >&2
            return 1
        fi

        local platform
        platform=$(get_service_platform "$service" "$machine" 2>/dev/null || echo "")

        # Use sanitized paths for remote commands
        local safe_service_dir
        safe_service_dir=$(sanitize_for_shell "$service_dir")
        local safe_compose_file
        safe_compose_file=$(sanitize_for_shell "$compose_file")

        local compose_has_build=0
        ssh "${ssh_user}@${ssh_host}" "grep -q \"^[[:space:]]*build:\" ${safe_compose_file}" >/dev/null 2>&1 && compose_has_build=1

        local platform_env=""
        if [ "$platform" = "linux/arm64" ] && [ $compose_has_build -eq 1 ]; then
            platform_env="DOCKER_DEFAULT_PLATFORM=$platform"
        fi

        echo "  Running docker compose on $machine..."

        local compose_cmd_success=1

        # Prefer contexts when compose file exists locally
        if [ -f "$service_dir/$compose_file" ] && [ -n "$context" ]; then
            if [ -n "$platform_env" ]; then
                if env "$platform_env" docker --context "$context" compose -f "$service_dir/$compose_file" up -d; then
                    compose_cmd_success=0
                fi
            else
                if docker --context "$context" compose -f "$service_dir/$compose_file" up -d; then
                    compose_cmd_success=0
                fi
            fi
        fi

        # Fallback: run compose directly on host via SSH
        if [ $compose_cmd_success -ne 0 ]; then
            if [ -n "$platform_env" ]; then
                if ssh "${ssh_user}@${ssh_host}" "PATH=/usr/local/bin:/opt/homebrew/bin:\$PATH && cd ${safe_service_dir} && ${platform_env} docker compose -f ${safe_compose_file} up -d"; then
                    compose_cmd_success=0
                fi
            else
                if ssh "${ssh_user}@${ssh_host}" "PATH=/usr/local/bin:/opt/homebrew/bin:\$PATH && cd ${safe_service_dir} && docker compose -f ${safe_compose_file} up -d"; then
                    compose_cmd_success=0
                fi
            fi
        fi

        if [ $compose_cmd_success -eq 0 ]; then
            echo "✓ Successfully deployed $service on $machine"
            return 0
        else
            echo "✗ Failed to deploy $service on $machine"
            return 1
        fi
    fi
}

# Stop Docker container on a machine
# Usage: docker_stop SERVICE_NAME MACHINE
# SC2029: sanitized paths interpolated into remote command; intentional.
# shellcheck disable=SC2029
docker_stop() {
    local service="$1"
    local machine="$2"

    if [ -z "$service" ] || [ -z "$machine" ]; then
        echo "Error: Service name and machine required" >&2
        return 1
    fi

    # Get working directory from registry (correct path for target machine)
    local working_dir
    working_dir=$(get_service_working_dir "$service" 2>/dev/null)
    local compose_file
    compose_file=$(get_service_compose_file "$service")

    if [ "$working_dir" = "null" ] || [ -z "$working_dir" ]; then
        echo "Error: No working directory found for $service" >&2
        return 1
    fi

    echo "Stopping $service on $machine..."

    # Check if this is the local machine
    if _is_local_machine "$machine"; then
        # Local execution
        cd "$working_dir" || {
            echo "Error: Cannot change to directory: $working_dir" >&2
            return 1
        }

        if [ -f "$compose_file" ]; then
            docker compose -f "$compose_file" down --volumes --remove-orphans
            local exit_code=$?
            cd - > /dev/null || return 1

            if [ $exit_code -eq 0 ]; then
                echo "✓ Successfully stopped $service on $machine"
                return 0
            else
                echo "✗ Failed to stop $service on $machine"
                return 1
            fi
        else
            echo "Error: Compose file not found: $working_dir/$compose_file" >&2
            cd - > /dev/null || return 1
            return 1
        fi
    else
        # Remote execution via SSH
        local ssh_host
        ssh_host=$(get_ssh_host "$machine")
        local ssh_user
        ssh_user=$(get_machine_ssh_user "$machine")
        local context
        context=$(get_or_create_machine_context "$machine") || context=""

        if [ -z "$ssh_host" ] || [ -z "$ssh_user" ]; then
            echo "Error: Could not get SSH connection info for machine '$machine'" >&2
            return 1
        fi

        # Validate paths
        if ! validate_path "$working_dir"; then
            echo "Error: Invalid working directory path" >&2
            return 1
        fi
        if ! validate_path "$compose_file"; then
            echo "Error: Invalid compose file path" >&2
            return 1
        fi

        local safe_working_dir
        safe_working_dir=$(sanitize_for_shell "$working_dir")
        local safe_compose_file
        safe_compose_file=$(sanitize_for_shell "$compose_file")

        local exit_code=1

        if [ -f "$working_dir/$compose_file" ] && [ -n "$context" ]; then
            docker --context "$context" compose -f "$working_dir/$compose_file" down --volumes --remove-orphans 2>&1
            exit_code=$?
        fi

        if [ $exit_code -ne 0 ]; then
            # Execute docker compose stop on remote machine
            ssh "${ssh_user}@${ssh_host}" "PATH=/usr/local/bin:/opt/homebrew/bin:\$PATH && cd ${safe_working_dir} && docker compose -f ${safe_compose_file} down --volumes --remove-orphans" 2>&1
            exit_code=$?
        fi

        if [ $exit_code -eq 0 ]; then
            echo "✓ Successfully stopped $service on $machine"
            return 0
        else
            echo "✗ Failed to stop $service on $machine"
            return 1
        fi
    fi
}

# Start Docker container on a machine (starts existing containers)
# Usage: docker_start SERVICE_NAME MACHINE
# SC2029: sanitized paths interpolated into remote command; intentional.
# shellcheck disable=SC2029
docker_start() {
    local service="$1"
    local machine="$2"

    if [ -z "$service" ] || [ -z "$machine" ]; then
        echo "Error: Service name and machine required" >&2
        return 1
    fi

    # Get working directory from registry (correct path for target machine)
    local working_dir
    working_dir=$(get_service_working_dir "$service" 2>/dev/null)
    local compose_file
    compose_file=$(get_service_compose_file "$service")

    if [ "$working_dir" = "null" ] || [ -z "$working_dir" ]; then
        echo "Error: No working directory found for $service" >&2
        return 1
    fi

    echo "Starting $service on $machine..."
    [ "$DEBUG" = "1" ] && echo "DEBUG: working_dir=$working_dir, machine=$machine" >&2

    # Check if this is the local machine
    if _is_local_machine "$machine"; then
        [ "$DEBUG" = "1" ] && echo "DEBUG: Using LOCAL execution path" >&2
        # Local execution
        cd "$working_dir" || {
            echo "Error: Cannot change to directory: $working_dir" >&2
            return 1
        }

        # Prepare secrets from Vault
        prepare_vault_secrets_for_docker "$service" "$machine" "$working_dir"

        if [ -f "$compose_file" ]; then
            local platform
            platform=$(get_service_platform "$service" "$machine" 2>/dev/null || echo "")

            local compose_has_build=0
            grep -q "^[[:space:]]*build:" "$compose_file" >/dev/null 2>&1 && compose_has_build=1
            local platform_env=""
            if [ "$platform" = "linux/arm64" ] && [ $compose_has_build -eq 1 ]; then
                platform_env="DOCKER_DEFAULT_PLATFORM=$platform"
            fi

            if [ -n "$platform_env" ]; then
                env "$platform_env" docker compose -f "$compose_file" up -d
            else
                docker compose -f "$compose_file" up -d
            fi
            local exit_code=$?

            # Cleanup vault-generated .env
            cleanup_vault_env_file "$working_dir"

            cd - > /dev/null || return 1

            if [ $exit_code -eq 0 ]; then
                echo "✓ Successfully started $service on $machine"
                return 0
            else
                echo "✗ Failed to start $service on $machine"
                return 1
            fi
        else
            echo "Error: Compose file not found: $working_dir/$compose_file" >&2
            cleanup_vault_env_file "$working_dir"
            cd - > /dev/null || return 1
            return 1
        fi
    else
        [ "$DEBUG" = "1" ] && echo "DEBUG: Using REMOTE execution path via SSH" >&2
        # Remote execution via SSH
        local ssh_host
        ssh_host=$(get_ssh_host "$machine")
        local ssh_user
        ssh_user=$(get_machine_ssh_user "$machine")
        local context
        context=$(get_or_create_machine_context "$machine") || context=""

        if [ -z "$ssh_host" ] || [ -z "$ssh_user" ]; then
            echo "Error: Could not get SSH connection info for machine '$machine'" >&2
            return 1
        fi

        [ "$DEBUG" = "1" ] && echo "DEBUG: SSH to ${ssh_user}@${ssh_host}, dir=$working_dir" >&2

        # Validate paths
        if ! validate_path "$working_dir"; then
            echo "Error: Invalid working directory path" >&2
            return 1
        fi
        if ! validate_path "$compose_file"; then
            echo "Error: Invalid compose file path" >&2
            return 1
        fi

        local safe_working_dir
        safe_working_dir=$(sanitize_for_shell "$working_dir")
        local safe_compose_file
        safe_compose_file=$(sanitize_for_shell "$compose_file")

        local platform
        platform=$(get_service_platform "$service" "$machine" 2>/dev/null || echo "")
        local compose_has_build=0
        ssh "${ssh_user}@${ssh_host}" "grep -q \"^[[:space:]]*build:\" ${safe_compose_file}" >/dev/null 2>&1 && compose_has_build=1
        local platform_env=""
        if [ "$platform" = "linux/arm64" ] && [ $compose_has_build -eq 1 ]; then
            platform_env="DOCKER_DEFAULT_PLATFORM=$platform"
        fi

        local exit_code=1
        if [ -f "$working_dir/$compose_file" ] && [ -n "$context" ]; then
            if [ -n "$platform_env" ]; then
                env "$platform_env" docker --context "$context" compose -f "$working_dir/$compose_file" up -d 2>&1
            else
                docker --context "$context" compose -f "$working_dir/$compose_file" up -d 2>&1
            fi
            exit_code=$?
        fi

        if [ $exit_code -ne 0 ]; then
            # Execute docker compose up on remote machine (creates and starts containers)
            if [ -n "$platform_env" ]; then
                ssh "${ssh_user}@${ssh_host}" "PATH=/usr/local/bin:/opt/homebrew/bin:\$PATH && cd ${safe_working_dir} && ${platform_env} docker compose -f ${safe_compose_file} up -d" 2>&1
            else
                ssh "${ssh_user}@${ssh_host}" "PATH=/usr/local/bin:/opt/homebrew/bin:\$PATH && cd ${safe_working_dir} && docker compose -f ${safe_compose_file} up -d" 2>&1
            fi
            exit_code=$?
        fi

        if [ $exit_code -eq 0 ]; then
            echo "✓ Successfully started $service on $machine"
            return 0
        else
            echo "✗ Failed to start $service on $machine"
            return 1
        fi
    fi
}

# Restart Docker container on a machine
# Usage: docker_restart SERVICE_NAME MACHINE
docker_restart() {
    local service="$1"
    local machine="$2"

    if [ -z "$service" ] || [ -z "$machine" ]; then
        echo "Error: Service name and machine required" >&2
        return 1
    fi

    echo "Restarting $service on $machine..."

    # Stop first
    if docker_stop "$service" "$machine"; then
        sleep 2
        # Then deploy
        docker_deploy "$service" "$machine"
        return $?
    else
        echo "Error: Failed to stop service, aborting restart" >&2
        return 1
    fi
}

# View Docker container logs
# Usage: docker_logs SERVICE_NAME MACHINE [LINES]
# SC2029: sanitized service name interpolated into remote command; intentional.
# shellcheck disable=SC2029
docker_logs() {
    local service="$1"
    local machine="$2"
    local lines="${3:-100}"

    if [ -z "$service" ] || [ -z "$machine" ]; then
        echo "Error: Service name and machine required" >&2
        return 1
    fi

    # Get working directory from registry (correct path for target machine)
    local working_dir
    working_dir=$(get_service_working_dir "$service" 2>/dev/null)
    local compose_file
    compose_file=$(get_service_compose_file "$service")

    if [ "$working_dir" = "null" ] || [ -z "$working_dir" ]; then
        echo "Error: No working directory found for $service" >&2
        return 1
    fi

    echo "Fetching logs for $service on $machine (last $lines lines)..."
    echo ""

    # Check if this is the local machine
    if _is_local_machine "$machine"; then
        # Local execution
        cd "$working_dir" || {
            echo "Error: Cannot change to directory: $working_dir" >&2
            return 1
        }

        if [ -f "$compose_file" ]; then
            docker compose -f "$compose_file" logs --tail="$lines"
            local exit_code=$?
            cd - > /dev/null || return 1
            return $exit_code
        else
            echo "Error: Compose file not found: $working_dir/$compose_file" >&2
            cd - > /dev/null || return 1
            return 1
        fi
    else
        # Remote execution via SSH
        local ssh_host
        ssh_host=$(get_ssh_host "$machine")
        local ssh_user
        ssh_user=$(get_machine_ssh_user "$machine")
        local context
        context=$(get_or_create_machine_context "$machine") || context=""

        if [ -z "$ssh_host" ] || [ -z "$ssh_user" ]; then
            echo "Error: Could not get SSH connection info for machine '$machine'" >&2
            return 1
        fi

        # Validate paths and lines parameter
        if ! validate_path "$working_dir"; then
            echo "Error: Invalid working directory path" >&2
            return 1
        fi
        if ! validate_path "$compose_file"; then
            echo "Error: Invalid compose file path" >&2
            return 1
        fi
        # Validate lines is a number
        if ! [[ "$lines" =~ ^[0-9]+$ ]]; then
            echo "Error: Invalid lines parameter, must be a number" >&2
            return 1
        fi

        local safe_working_dir
        safe_working_dir=$(sanitize_for_shell "$working_dir")
        local safe_compose_file
        safe_compose_file=$(sanitize_for_shell "$compose_file")

        local exit_code=1

        if [ -f "$working_dir/$compose_file" ] && [ -n "$context" ]; then
            docker --context "$context" compose -f "$working_dir/$compose_file" logs --tail="$lines" 2>&1
            exit_code=$?
        fi

        if [ $exit_code -ne 0 ]; then
            # Execute docker compose logs on remote machine
            ssh "${ssh_user}@${ssh_host}" "PATH=/usr/local/bin:/opt/homebrew/bin:\$PATH && cd ${safe_working_dir} && docker compose -f ${safe_compose_file} logs --tail=${lines}" 2>&1
            exit_code=$?
        fi

        return $exit_code
    fi
}

# Build locally and deploy to remote machine
# Usage: docker_build_local_deploy_remote SERVICE_NAME TARGET_MACHINE
# SC2029: service name validated via validate_service_name; remote
# interpolation of /tmp/${service}_image.tar is intentional.
# shellcheck disable=SC2029
docker_build_local_deploy_remote() {
    local service="$1"
    local target_machine="$2"

    if [ -z "$service" ] || [ -z "$target_machine" ]; then
        echo "Error: Service name and target machine required" >&2
        return 1
    fi

    echo ""
    echo "==========================================="
    echo "BUILD LOCAL → DEPLOY REMOTE"
    echo "==========================================="
    echo "Service: $service"
    echo "Target: $target_machine"
    echo ""

    # Step 1: Build locally
    echo "Step 1: Building Docker image locally..."
    if ! docker_build_local "$service"; then
        echo "✗ Local build failed" >&2
        return 1
    fi
    echo "✓ Local build successful"
    echo ""

    # Step 2: Export image
    echo "Step 2: Exporting Docker image..."
    local image_name
    image_name=$(get_service_image_name "$service")

    # Validate service name for temp file
    if ! validate_service_name "$service"; then
        echo "✗ Invalid service name" >&2
        return 1
    fi

    local temp_image="/tmp/${service}_image.tar"

    if ! docker save -o "$temp_image" "$image_name"; then
        echo "✗ Image export failed" >&2
        return 1
    fi
    echo "✓ Image exported to $temp_image"
    echo ""

    # Step 3: Transfer to remote machine
    echo "Step 3: Transferring image to $target_machine..."
    local target_ip
    target_ip=$(get_machine_ip "$target_machine")
    local ssh_user
    ssh_user=$(get_machine_ssh_user "$target_machine")

    # Validate IP address
    if ! validate_ip "$target_ip"; then
        echo "✗ Invalid target IP address" >&2
        rm -f "$temp_image"
        return 1
    fi

    if ! scp -o ConnectTimeout=10 "$temp_image" "${ssh_user}@${target_ip}:/tmp/"; then
        echo "✗ Image transfer failed" >&2
        rm -f "$temp_image"
        return 1
    fi
    echo "✓ Image transferred"
    echo ""

    # Step 4: Load image on remote machine
    echo "Step 4: Loading image on $target_machine..."
    if ! ssh "${ssh_user}@${target_ip}" "docker load -i /tmp/${service}_image.tar && rm -f /tmp/${service}_image.tar"; then
        echo "✗ Image load failed on remote machine" >&2
        rm -f "$temp_image"
        return 1
    fi
    echo "✓ Image loaded on remote machine"
    echo ""

    # Clean up local temp file
    rm -f "$temp_image"

    # Step 5: Deploy on remote machine
    echo "Step 5: Deploying on $target_machine..."
    if docker_deploy "$service" "$target_machine"; then
        echo ""
        echo "✓ Build and deploy completed successfully!"
        return 0
    else
        echo "✗ Deployment failed" >&2
        return 1
    fi
}

# Get Docker image name for a service
# Usage: get_service_image_name SERVICE_NAME
get_service_image_name() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    # Try to read from compose file
    local service_dir
    service_dir=$(get_service_directory "$service")
    local compose_file
    compose_file=$(get_service_compose_file "$service")

    if [ -f "$service_dir/$compose_file" ]; then
        # Extract image name from compose file (simplified)
        local image
        image=$(grep -E "^\s*image:" "$service_dir/$compose_file" | head -n1 | awk '{print $2}')

        if [ -n "$image" ]; then
            echo "$image"
        else
            # Default to service name if not found
            echo "$service:latest"
        fi
    else
        echo "$service:latest"
    fi
}

# Check Docker network exists
# Usage: check_docker_network NETWORK_NAME [MACHINE]
check_docker_network() {
    local network="$1"
    local machine="${2:-local}"

    if [ -z "$network" ]; then
        echo "Error: Network name required" >&2
        return 1
    fi

    if [ "$machine" = "local" ]; then
        if docker network ls --format '{{.Name}}' | grep -q "^${network}$"; then
            return 0
        else
            return 1
        fi
    else
        local context
        context=$(get_machine_context "$machine")
        if docker --context "$context" network ls --format '{{.Name}}' | grep -q "^${network}$"; then
            return 0
        else
            return 1
        fi
    fi
}

# Create Docker network on a machine
# Usage: create_docker_network NETWORK_NAME [MACHINE]
create_docker_network() {
    local network="$1"
    local machine="${2:-local}"

    if [ -z "$network" ]; then
        echo "Error: Network name required" >&2
        return 1
    fi

    if check_docker_network "$network" "$machine"; then
        echo "✓ Network '$network' already exists on $machine"
        return 0
    fi

    echo "Creating Docker network '$network' on $machine..."

    local rc=0
    if [ "$machine" = "local" ]; then
        docker network create --driver bridge "$network" || rc=$?
    else
        local context
        context=$(get_machine_context "$machine")
        docker --context "$context" network create --driver bridge "$network" || rc=$?
    fi

    if [ "$rc" -eq 0 ]; then
        echo "✓ Network '$network' created on $machine"
        return 0
    fi
    echo "✗ Failed to create network '$network' on $machine" >&2
    return 1
}
