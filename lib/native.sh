#!/usr/bin/env bash
# Native service operations (brew services, systemctl, etc.)

set -euo pipefail

# Note: registry.sh and remote.sh are sourced by the main portoser script
# No need to source them again here

# Export Vault secrets for native services
# Usage: export_vault_secrets_for_native SERVICE_NAME MACHINE
export_vault_secrets_for_native() {
    local service="$1"
    local machine="${2:-$(hostname -s 2>/dev/null || hostname | cut -d. -f1)}"

    # Check if Vault is enabled and ready
    if ! vault_is_ready 2>/dev/null; then
        return 0
    fi

    # Try to get secrets from Vault
    if vault_export_service_secrets "$service" "$machine" 2>/dev/null; then
        echo "  ✓ Loaded secrets from Vault for $service"
        return 0
    fi

    # No secrets in Vault, proceed without them
    return 0
}

# Start a native service
# Args:
#   $1: SERVICE - Service name
#   $2: MACHINE - Machine name (optional, uses current_host from registry)
native_start_service() {
    local service=$1
    local machine=${2:-$(get_service_host "$service")}

    if [[ -z "$machine" ]]; then
        echo "Error: Could not determine machine for service '$service'" >&2
        return 1
    fi

    local current_machine
    current_machine=$(hostname -s)

    # Check if service is on current machine
    if [[ "$machine" == "$current_machine" ]]; then
        native_start_local "$service"
    else
        native_start_remote "$service" "$machine"
    fi
}

# Stop a native service
# Args:
#   $1: SERVICE - Service name
#   $2: MACHINE - Machine name (optional, uses current_host from registry)
native_stop_service() {
    local service=$1
    local machine=${2:-$(get_service_host "$service")}

    if [[ -z "$machine" ]]; then
        echo "Error: Could not determine machine for service '$service'" >&2
        return 1
    fi

    local current_machine
    current_machine=$(hostname -s)

    # Check if service is on current machine
    if [[ "$machine" == "$current_machine" ]]; then
        native_stop_local "$service"
    else
        native_stop_remote "$service" "$machine"
    fi
}

# Restart a native service
# Args:
#   $1: SERVICE - Service name
#   $2: MACHINE - Machine name (optional, uses current_host from registry)
native_restart_service() {
    local service=$1
    local machine=${2:-$(get_service_host "$service")}

    echo "Restarting native service '$service' on $machine..."
    native_stop_service "$service" "$machine"
    sleep 2
    native_start_service "$service" "$machine"
}

# Get status of a native service
# Args:
#   $1: SERVICE - Service name
#   $2: MACHINE - Machine name (optional, uses current_host from registry)
# Returns: "running", "stopped", or "unknown"
native_status_service() {
    local service=$1
    local machine=${2:-$(get_service_host "$service")}

    if [[ -z "$machine" ]]; then
        echo "unknown"
        return 1
    fi

    local current_machine
    current_machine=$(hostname -s)

    # Check if service is on current machine
    if [[ "$machine" == "$current_machine" ]]; then
        native_status_local "$service"
    else
        native_status_remote "$service" "$machine"
    fi
}

# Start native service locally (brew services)
# Args:
#   $1: SERVICE - Service name
native_start_local() {
    local service=$1

    # Check if service is already registered with launchd (any status: started, stopped, error, etc.)
    local is_registered=false
    if command -v brew &> /dev/null; then
        if brew services list | grep -q "^$service"; then
            is_registered=true
        fi
    fi

    if [[ "$is_registered" == true ]]; then
        echo "Service '$service' is already registered with launchd, restarting..."

        # Use restart command if available
        local restart_cmd
        restart_cmd=$(get_service_restart_command "$service")
        if [[ -n "$restart_cmd" ]]; then
            if bash -c "$restart_cmd"; then
                echo "✓ Restarted $service via custom command"
                return 0
            fi
        fi

        # Fallback: stop then start
        local stop_cmd
        stop_cmd=$(get_service_stop_command "$service")
        if [[ -n "$stop_cmd" ]]; then
            bash -c "$stop_cmd" 2>/dev/null || true
            sleep 1
        fi
    else
        echo "Starting native service '$service' locally..."
    fi

    # Export Vault secrets if available
    export_vault_secrets_for_native "$service" "$(hostname -s)"

    # Get start command from service.yml
    local start_cmd
    start_cmd=$(get_service_start_command "$service")
    if [[ -n "$start_cmd" ]]; then
        if bash -c "$start_cmd"; then
            if [[ "$is_registered" == true ]]; then
                echo "✓ Restarted $service via custom command"
            else
                echo "✓ Started $service via custom command"
            fi
            return 0
        fi
    fi

    echo "Error: Could not start native service '$service'" >&2
    return 1
}

# Stop native service locally
# Args:
#   $1: SERVICE - Service name
native_stop_local() {
    local service=$1

    echo "Stopping native service '$service' locally..."

    # Get stop command from service.yml
    local stop_cmd
    stop_cmd=$(get_service_stop_command "$service")
    if [[ -n "$stop_cmd" ]]; then
        if bash -c "$stop_cmd"; then
            echo "✓ Stopped $service via custom command"
            return 0
        fi
    fi

    echo "Error: Could not stop native service '$service'" >&2
    return 1
}

# Get status of native service locally
# Args:
#   $1: SERVICE - Service name
# Returns: "running", "stopped", or "unknown"
native_status_local() {
    local service=$1

    # Check brew services
    if command -v brew &> /dev/null; then
        local brew_status
        brew_status=$(brew services list | grep "^$service" | awk '{print $2}')
        if [[ "$brew_status" == "started" ]]; then
            echo "running"
            return 0
        elif [[ "$brew_status" == "stopped" ]] || [[ "$brew_status" == "none" ]] || [[ "$brew_status" == "error" ]]; then
            echo "stopped"
            return 0
        fi
    fi

    # Check systemctl
    if command -v systemctl &> /dev/null; then
        if systemctl is-active --quiet "$service"; then
            echo "running"
            return 0
        else
            echo "stopped"
            return 0
        fi
    fi

    # Check for custom healthcheck command
    local health_cmd
    health_cmd=$(yq eval ".services.${service}.healthcheck_command // \"\"" "$CADDY_REGISTRY_PATH")
    if [[ -n "$health_cmd" ]]; then
        if bash -c "$health_cmd" &> /dev/null; then
            echo "running"
            return 0
        else
            echo "stopped"
            return 0
        fi
    fi

    echo "unknown"
    return 1
}

# Start native service on remote machine
# Args:
#   $1: SERVICE - Service name
#   $2: MACHINE - Machine name
native_start_remote() {
    local service=$1
    local machine=$2

    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")
    local ssh_port
    ssh_port=$(get_machine_ssh_port "$machine")
    local ip
    ip=$(get_machine_ip "$machine")

    if [[ -z "$ip" ]]; then
        echo "Error: Could not determine IP for machine '$machine'" >&2
        return 1
    fi

    # Check if service is already registered with launchd on remote machine.
    # Pass $service as a positional parameter into a quoted heredoc so it
    # cannot be reinterpreted by the local shell.
    local is_registered
    is_registered=$(ssh -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" \
        bash -s -- "$service" <<'EOFCHECK'
service="$1"
if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -f /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

if command -v brew &> /dev/null; then
    if brew services list | grep -q "^${service}"; then
        echo "true"
    else
        echo "false"
    fi
else
    echo "false"
fi
EOFCHECK
)

    if [[ "$is_registered" == "true" ]]; then
        echo "Service '$service' is already registered with launchd on $machine, restarting..."

        # Use restart command if available
        local restart_cmd
        restart_cmd=$(get_service_restart_command "$service")
        if [[ -n "$restart_cmd" ]]; then
            if ssh -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" "$restart_cmd"; then
                echo "✓ Restarted $service on $machine"
                return 0
            fi
        fi

        # Fallback: stop then start
        local stop_cmd
        stop_cmd=$(get_service_stop_command "$service")
        if [[ -n "$stop_cmd" ]]; then
            ssh -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" "$stop_cmd" 2>/dev/null || true
            sleep 1
        fi
    else
        echo "Starting native service '$service' on $machine..."
    fi

    # Get start command from service.yml (reads from remote machine)
    local start_cmd
    start_cmd=$(get_service_start_command "$service")

    if [[ -z "$start_cmd" ]]; then
        echo "Error: No start command found in service.yml for '$service'" >&2
        return 1
    fi

    # Execute start command on remote machine
    if ssh -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" "$start_cmd"; then
        if [[ "$is_registered" == "true" ]]; then
            echo "✓ Restarted $service on $machine"
        else
            echo "✓ Started $service on $machine"
        fi
        return 0
    fi
    echo "Error: Failed to start $service on $machine" >&2
    return 1
}

# Stop native service on remote machine
# Args:
#   $1: SERVICE - Service name
#   $2: MACHINE - Machine name
native_stop_remote() {
    local service=$1
    local machine=$2

    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")
    local ssh_port
    ssh_port=$(get_machine_ssh_port "$machine")
    local ip
    ip=$(get_machine_ip "$machine")

    if [[ -z "$ip" ]]; then
        echo "Error: Could not determine IP for machine '$machine'" >&2
        return 1
    fi

    echo "Stopping native service '$service' on $machine..."

    # Get stop command from service.yml (reads from remote machine)
    local stop_cmd
    stop_cmd=$(get_service_stop_command "$service")

    if [[ -z "$stop_cmd" ]]; then
        echo "Error: No stop command found in service.yml for '$service'" >&2
        return 1
    fi

    # Execute stop command on remote machine
    if ssh -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" "$stop_cmd"; then
        echo "✓ Stopped $service on $machine"
        return 0
    fi
    echo "Error: Failed to stop $service on $machine" >&2
    return 1
}

# Get status of native service on remote machine
# Args:
#   $1: SERVICE - Service name
#   $2: MACHINE - Machine name
# Returns: "running", "stopped", or "unknown"
native_status_remote() {
    local service=$1
    local machine=$2

    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")
    local ssh_port
    ssh_port=$(get_machine_ssh_port "$machine")
    local ip
    ip=$(get_machine_ip "$machine")

    if [[ -z "$ip" ]]; then
        echo "unknown"
        return 1
    fi

    # Execute remote status check. Pass $service positionally into a quoted
    # heredoc so it cannot be reinterpreted by the local shell.
    # -n prevents SSH from reading stdin (which would consume the parent loop's input).
    local result
    result=$(ssh -n -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" \
        bash -s -- "$service" <<'EOFSTATUS'
service="$1"
if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -f /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

if command -v brew &> /dev/null; then
    brew_status=$(brew services list | grep "^${service}" | awk '{print $2}')
    if [[ "$brew_status" == "started" ]]; then
        echo "running"
        exit 0
    elif [[ "$brew_status" == "stopped" ]] || [[ "$brew_status" == "none" ]]; then
        echo "stopped"
        exit 0
    fi
fi

if command -v systemctl &> /dev/null; then
    if systemctl is-active --quiet "$service"; then
        echo "running"
        exit 0
    else
        echo "stopped"
        exit 0
    fi
fi

echo "unknown"
EOFSTATUS
)

    echo "$result"
}
