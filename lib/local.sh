#!/usr/bin/env bash
# local.sh - Functions for managing local Python services (adapted from compose.sh)

set -euo pipefail

# Import validation library. Resolve via this file's own directory so we
# don't depend on the caller having $SCRIPT_DIR set (broken under set -u).
_LOCAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/utils/validation.sh
source "${_LOCAL_LIB_DIR}/utils/validation.sh"
unset _LOCAL_LIB_DIR

# Export Vault secrets as environment variables for local services
# Usage: export_vault_secrets_for_local SERVICE_NAME MACHINE
export_vault_secrets_for_local() {
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

    # No secrets in Vault, fall back to .env file
    return 0
}

# Get PID file path for a service
# Usage: get_pid_file SERVICE_NAME
get_pid_file() {
    local service="$1"
    echo "$PIDS_DIR/${service}.pid"
}

# Get log file path for a service
# Usage: get_log_file SERVICE_NAME
get_log_file() {
    local service="$1"
    echo "$LOGS_DIR/${service}.log"
}

# Flush Python cache files for a service
# Usage: flush_python_cache SERVICE_NAME [MACHINE]
flush_python_cache() {
    local service="$1"
    local machine="${2:-local}"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    # Get service_dir differently for local vs remote
    local service_dir
    if [ "$machine" = "local" ]; then
        service_dir=$(get_working_dir_from_files "$service" 2>/dev/null)

        if [ -z "$service_dir" ] || [ "$service_dir" = "null" ]; then
            echo "Warning: No working directory found for $service" >&2
            return 1
        fi

        if [ -d "$service_dir" ]; then
            echo "Flushing Python cache for $service..."

            # Count files before deletion for reporting
            local pycache_dirs
            pycache_dirs=$(find "$service_dir" -type d -name "__pycache__" 2>/dev/null | wc -l | tr -d ' ')
            local pyc_files
            pyc_files=$(find "$service_dir" -type f \( -name "*.pyc" -o -name "*.pyo" \) 2>/dev/null | wc -l | tr -d ' ')

            # Remove cache directories and files
            find "$service_dir" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null
            find "$service_dir" -type f \( -name "*.pyc" -o -name "*.pyo" \) -delete 2>/dev/null

            if [ "$pycache_dirs" -gt 0 ] || [ "$pyc_files" -gt 0 ]; then
                echo "✓ Python cache cleared for $service ($pycache_dirs __pycache__ dirs, $pyc_files .pyc/.pyo files)"
            else
                echo "  No Python cache files found"
            fi
        else
            echo "Warning: Service directory not found: $service_dir" >&2
            return 1
        fi
    else
        # Remote machine via SSH - get working_dir from REMOTE service.yml
        local ip
        ip=$(get_machine_ip "$machine")
        local ssh_user
        ssh_user=$(get_machine_ssh_user "$machine")
        local ssh_port
        ssh_port=$(get_machine_ssh_port "$machine")

        # Validate service name, IP, and port
        if ! validate_service_name "$service"; then
            echo "Error: Invalid service name" >&2
            return 1
        fi
        if ! validate_ip "$ip"; then
            echo "Error: Invalid IP address" >&2
            return 1
        fi
        if ! validate_port "$ssh_port"; then
            echo "Error: Invalid SSH port" >&2
            return 1
        fi

        # Get service file path from registry
        local service_file
        service_file=$(yq eval ".services.${service}.service_file" "$CADDY_REGISTRY_PATH" 2>/dev/null)
        local docker_compose
        docker_compose=$(yq eval ".services.${service}.docker_compose" "$CADDY_REGISTRY_PATH" 2>/dev/null)

        echo "Flushing Python cache for $service on $machine..."

        # Read working_dir from remote service.yml or docker-compose.yml
        if [ -n "$service_file" ] && [ "$service_file" != "null" ]; then
            # Validate and sanitize service_file path
            if ! validate_path "$service_file"; then
                echo "Error: Invalid service file path" >&2
                return 1
            fi
            local safe_service_file
            safe_service_file=$(sanitize_for_shell "$service_file")
            # Parse service.yml on remote machine
            service_dir=$(ssh -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" "yq eval '.working_dir' ${safe_service_file} 2>/dev/null")
        elif [ -n "$docker_compose" ] && [ "$docker_compose" != "null" ]; then
            # Parse docker-compose.yml on remote machine (get working_directory or build context)
            local compose_dir
            compose_dir=$(dirname "$docker_compose")
            service_dir="$compose_dir"
        fi

        if [ -z "$service_dir" ] || [ "$service_dir" = "null" ]; then
            echo "Warning: Could not determine working directory for $service on $machine" >&2
            return 1
        fi

        # Validate service directory
        if ! validate_path "$service_dir"; then
            echo "Error: Invalid service directory path" >&2
            return 1
        fi

        # Pass the values as positional parameters into a quoted heredoc.
        # No client-side expansion = no shell-injection surface; sanitize_for_shell
        # is no longer needed because the values never reach a shell parser.
        ssh -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" \
            bash -s -- "$service_dir" "$service" <<'REMOTE'
service_dir="$1"
service="$2"

if [ -d "$service_dir" ]; then
    pycache_dirs=$(find "$service_dir" -type d -name "__pycache__" 2>/dev/null | wc -l | tr -d ' ')
    pyc_files=$(find "$service_dir" -type f \( -name "*.pyc" -o -name "*.pyo" \) 2>/dev/null | wc -l | tr -d ' ')

    find "$service_dir" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null
    find "$service_dir" -type f \( -name "*.pyc" -o -name "*.pyo" \) -delete 2>/dev/null

    if [ "$pycache_dirs" -gt 0 ] || [ "$pyc_files" -gt 0 ]; then
        echo "✓ Python cache cleared for ${service} (${pycache_dirs} __pycache__ dirs, ${pyc_files} .pyc/.pyo files)"
    else
        echo "  No Python cache files found"
    fi
else
    echo "Warning: Service directory not found: $service_dir" >&2
    exit 1
fi
REMOTE
    fi
}

# Check if a local Python service is running
# Usage: check_local_service_running_local SERVICE_NAME
check_local_service_running_local() {
    local service="$1"
    local pid_file
    pid_file=$(get_pid_file "$service")

    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file")
        if ps -p "$pid" > /dev/null 2>&1; then
            return 0  # Running
        else
            # PID file exists but process is dead, clean it up
            rm -f "$pid_file"
            return 1  # Not running
        fi
    fi
    return 1  # Not running
}

# Stop a local Python service
# Usage: local_stop_service SERVICE_NAME
local_stop_service() {
    local service="$1"
    local pid_file
    pid_file=$(get_pid_file "$service")

    if [ ! -f "$pid_file" ]; then
        echo "Service '$service' is not running (no PID file)"
        return 0
    fi

    local pid
    pid=$(cat "$pid_file")

    if ! ps -p "$pid" > /dev/null 2>&1; then
        echo "Service '$service' is not running (stale PID file)"
        rm -f "$pid_file"
        return 0
    fi

    echo "Stopping $service (PID: $pid)..."
    kill -TERM "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null

    # Wait for process to stop (max 10 seconds)
    local count=0
    while ps -p "$pid" > /dev/null 2>&1 && [ $count -lt 10 ]; do
        sleep 1
        count=$((count + 1))
    done

    if ps -p "$pid" > /dev/null 2>&1; then
        echo "⚠ Warning: Process $pid did not stop gracefully, forcing..."
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$pid_file"
    echo "✓ Stopped $service"

    # Flush Python cache after stopping
    flush_python_cache "$service" "local"

    return 0
}

# Start a local Python service
# Usage: local_start_service SERVICE_NAME [MACHINE]
local_start_service() {
    local service="$1"
    local machine="${2:-$(hostname)}"

    # Get service configuration from registry
    local service_dir
    service_dir=$(get_service_working_dir "$service" 2>/dev/null || get_service_directory "$service")
    local port
    port=$(get_service_port "$service")
    local pid_file
    pid_file=$(get_pid_file "$service")
    local log_file
    log_file=$(get_log_file "$service")

    # Check if service directory exists
    if [ ! -d "$service_dir" ]; then
        echo "Error: Service directory not found: $service_dir" >&2
        return 1
    fi

    # Check if already running
    if check_local_service_running_local "$service"; then
        echo "✓ $service is already running (PID: $(cat "$pid_file"))"
        return 0
    fi

    # Flush Python cache before starting
    flush_python_cache "$service" "local"

    echo "Starting $service on port $port..."

    # Create directories if they don't exist
    mkdir -p "$PIDS_DIR"
    mkdir -p "$LOGS_DIR"

    cd "$service_dir" || {
        echo "Error: Cannot change to directory: $service_dir" >&2
        return 1
    }

    # Try to get explicit start command from registry first
    local start_command
    start_command=$(get_service_start_command "$service" 2>/dev/null)

    if [ -z "$start_command" ]; then
        # Fall back to auto-detection if no explicit command
        local python_mgr
        python_mgr=$(get_service_python_manager "$service" 2>/dev/null || echo "venv")

        case "$python_mgr" in
            venv)
                if [ -d ".venv" ]; then
                    if [ -f "run_server.py" ]; then
                        start_command=".venv/bin/python run_server.py"
                    elif [ -f "main.py" ]; then
                        start_command=".venv/bin/python -m uvicorn main:app --host 0.0.0.0 --port $port"
                    fi
                fi
                ;;
            poetry)
                if [ -f "poetry.lock" ] && command -v poetry >/dev/null 2>&1; then
                    start_command="poetry run uvicorn main:app --host 0.0.0.0 --port $port"
                fi
                ;;
            uv)
                if command -v uv >/dev/null 2>&1; then
                    if [ -f "run_server.py" ]; then
                        start_command="uv run python run_server.py"
                    else
                        start_command="uv run python -m uvicorn main:app --host 0.0.0.0 --port $port"
                    fi
                fi
                ;;
        esac

        if [ -z "$start_command" ]; then
            echo "Error: Could not determine start command for $service" >&2
            cd - > /dev/null
            return 1
        fi
    fi

    # Export Vault secrets if available (use the local hostname so Vault
    # AppRole lookups match the right approle path).
    export_vault_secrets_for_local "$service" "$(hostname -s 2>/dev/null || hostname | cut -d. -f1)"

    # Load env file if specified (Vault secrets take precedence)
    local env_file
    env_file=$(get_service_env_file "$service" 2>/dev/null)
    if [ -n "$env_file" ] && [ -f "$env_file" ]; then
        set -a
        # shellcheck source=/dev/null
        source "$env_file"
        set +a
    fi

    # Start the service in background
    # Security: Use array for command to prevent injection
    local cmd_array
    IFS=' ' read -ra cmd_array <<< "$start_command"
    nohup "${cmd_array[@]}" > "$log_file" 2>&1 &
    local pid=$!

    # Save PID
    echo "$pid" > "$pid_file"

    # Wait a moment and verify it started
    sleep 2
    if ps -p "$pid" > /dev/null 2>&1; then
        echo "✓ Started $service (PID: $pid, Port: $port)"
        echo "  Log: $log_file"
        cd - > /dev/null
        return 0
    else
        echo "✗ Failed to start $service"
        echo "  Check log: $log_file"
        rm -f "$pid_file"
        cd - > /dev/null
        return 1
    fi
}

# Restart a local Python service
# Usage: local_restart_service SERVICE_NAME
local_restart_service() {
    local service="$1"

    echo "Restarting local service $service..."

    # Stop first
    local_stop_service "$service"
    sleep 1

    # Then start
    local_start_service "$service"
}

# Stop a local service on a remote machine via SSH
# Usage: remote_stop_service SERVICE_NAME MACHINE
remote_stop_service() {
    local service="$1"
    local machine="$2"

    if [ -z "$service" ] || [ -z "$machine" ]; then
        echo "Error: Service name and machine required" >&2
        return 1
    fi

    local ip
    ip=$(get_machine_ip "$machine")
    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")
    local ssh_port
    ssh_port=$(get_machine_ssh_port "$machine")
    local pid_file
    pid_file=$(get_pid_file "$service")

    # Validate inputs
    if ! validate_service_name "$service"; then
        echo "Error: Invalid service name" >&2
        return 1
    fi
    if ! validate_ip "$ip"; then
        echo "Error: Invalid IP address" >&2
        return 1
    fi
    if ! validate_port "$ssh_port"; then
        echo "Error: Invalid SSH port" >&2
        return 1
    fi

    # Try to use explicit stop command from registry
    local stop_command
    stop_command=$(get_service_stop_command "$service" 2>/dev/null)

    echo "Stopping $service on $machine via SSH..."

    if [ -n "$stop_command" ]; then
        # Use explicit stop command
        local service_dir
        service_dir=$(get_service_working_dir "$service" 2>/dev/null || get_service_directory "$service")

        # Validate paths
        if ! validate_path "$service_dir"; then
            echo "Error: Invalid service directory" >&2
            return 1
        fi

        # Security: Properly sanitize both directory and command
        local safe_service_dir
        safe_service_dir=$(sanitize_for_shell "$service_dir")
        local safe_stop_command
        safe_stop_command=$(sanitize_for_shell "$stop_command")

        ssh -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" "cd ${safe_service_dir} && ${safe_stop_command}"
        return $?
    fi

    # Validate pid_file path
    if ! validate_path "$pid_file"; then
        echo "Error: Invalid PID file path" >&2
        return 1
    fi

    # Pass values as positional parameters into a quoted heredoc — no
    # client-side expansion, no shell-injection surface.
    if ssh -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" \
        bash -s -- "$pid_file" "$service" <<'REMOTE'
pid_file="$1"
service="$2"

if [ -f "$pid_file" ]; then
    pid=$(cat "$pid_file")
    if ps -p "$pid" > /dev/null 2>&1; then
        echo "Stopping service (PID: $pid)..."
        kill -TERM "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null

        count=0
        while ps -p "$pid" > /dev/null 2>&1 && [ $count -lt 10 ]; do
            sleep 1
            count=$((count + 1))
        done

        if ps -p "$pid" > /dev/null 2>&1; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi
    rm -f "$pid_file"
    echo "✓ Stopped ${service}"
else
    echo "Service ${service} is not running (no PID file)"
fi
REMOTE
    then
        echo "✓ Successfully stopped $service on $machine"

        # Flush Python cache after stopping
        flush_python_cache "$service" "$machine"

        return 0
    fi
    echo "✗ Failed to stop $service on $machine" >&2
    return 1
}

# Start a local service on a remote machine via SSH
# Usage: remote_start_service SERVICE_NAME MACHINE
remote_start_service() {
    local service="$1"
    local machine="$2"

    if [ -z "$service" ] || [ -z "$machine" ]; then
        echo "Error: Service name and machine required" >&2
        return 1
    fi

    local ip
    ip=$(get_machine_ip "$machine")
    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")
    local ssh_port
    ssh_port=$(get_machine_ssh_port "$machine")
    local service_dir
    service_dir=$(get_service_working_dir "$service" 2>/dev/null || get_service_directory "$service")
    local port
    port=$(get_service_port "$service")

    # Validate all inputs
    if ! validate_service_name "$service"; then
        echo "Error: Invalid service name" >&2
        return 1
    fi
    if ! validate_ip "$ip"; then
        echo "Error: Invalid IP address" >&2
        return 1
    fi
    if ! validate_port "$ssh_port"; then
        echo "Error: Invalid SSH port" >&2
        return 1
    fi
    if ! validate_port "$port"; then
        echo "Error: Invalid service port" >&2
        return 1
    fi
    if ! validate_path "$service_dir"; then
        echo "Error: Invalid service directory" >&2
        return 1
    fi

    # Determine the remote base directory for pids/logs. Prefer the host's
    # registry-declared base path (hosts.<machine>.path); fall back to the
    # user's home if the registry doesn't specify one.
    local remote_base
    remote_base=$(yq eval ".hosts.${machine}.path // \"\"" "${CADDY_REGISTRY_PATH:-${REGISTRY_FILE:-registry.yml}}" 2>/dev/null || true)
    if [ -z "$remote_base" ] || [ "$remote_base" = "null" ]; then
        remote_base="/home/$ssh_user"
    fi
    local remote_pids_dir="$remote_base/.pids"
    local remote_logs_dir="$remote_base/.logs"
    local pid_file="$remote_pids_dir/${service}.pid"
    local log_file="$remote_logs_dir/${service}.log"

    # Try to get explicit start command
    local start_command
    start_command=$(get_service_start_command "$service" 2>/dev/null)
    local has_explicit_command=0
    if [ -n "$start_command" ]; then
        has_explicit_command=1
    fi

    # Get Python manager for fallback
    local python_mgr
    python_mgr=$(get_service_python_manager "$service" 2>/dev/null || echo "venv")

    # Get env file if specified
    local env_file
    env_file=$(get_service_env_file "$service" 2>/dev/null)

    # Flush Python cache before starting
    flush_python_cache "$service" "$machine"

    echo "Starting $service on $machine via SSH..."

    # All values pass into the remote shell as positional parameters via a
    # quoted heredoc — no client-side expansion, no shell-injection surface,
    # no need for sanitize_for_shell.
    local has_explicit_command=0
    [ -n "$start_command" ] && has_explicit_command=1

    if ! ssh -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" \
        bash -s -- \
            "$port" \
            "$has_explicit_command" \
            "$remote_pids_dir" \
            "$remote_logs_dir" \
            "$pid_file" \
            "$log_file" \
            "$service_dir" \
            "$service" \
            "$start_command" \
            "$python_mgr" \
            "$env_file" \
        <<'REMOTE'
port="$1"
has_explicit_command="$2"
remote_pids_dir="$3"
remote_logs_dir="$4"
pid_file="$5"
log_file="$6"
service_dir="$7"
service="$8"
start_command="$9"
python_mgr="${10}"
env_file="${11}"

mkdir -p "$remote_pids_dir"
mkdir -p "$remote_logs_dir"

if [ -f "$pid_file" ]; then
    pid=$(cat "$pid_file")
    if ps -p "$pid" > /dev/null 2>&1; then
        echo "✓ ${service} is already running (PID: $pid)"
        exit 0
    else
        rm -f "$pid_file"
    fi
fi

cd "$service_dir" || exit 1

if [ "$has_explicit_command" -eq 1 ]; then
    start_cmd="$start_command"
else
    case "$python_mgr" in
        venv)
            if [ -d ".venv" ]; then
                if [ -f "run_server.py" ]; then
                    start_cmd=".venv/bin/python run_server.py"
                else
                    start_cmd=".venv/bin/python -m uvicorn main:app --host 0.0.0.0 --port ${port}"
                fi
            fi
            ;;
        poetry)
            if [ -f "poetry.lock" ] && command -v poetry >/dev/null 2>&1; then
                start_cmd="poetry run uvicorn main:app --host 0.0.0.0 --port ${port}"
            fi
            ;;
        uv)
            if command -v uv >/dev/null 2>&1; then
                if [ -f "run_server.py" ]; then
                    start_cmd="uv run python run_server.py"
                else
                    start_cmd="uv run python -m uvicorn main:app --host 0.0.0.0 --port ${port}"
                fi
            fi
            ;;
    esac

    if [ -z "$start_cmd" ]; then
        echo "Error: Could not determine start command"
        exit 1
    fi
fi

if [ -n "$env_file" ] && [ -f "$env_file" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
fi

nohup sh -c "$start_cmd" > "$log_file" 2>&1 &
pid=$!
echo "$pid" > "$pid_file"

sleep 2
if ps -p "$pid" > /dev/null 2>&1; then
    echo "✓ Started ${service} (PID: $pid, Port: ${port})"
    echo "  Log: $log_file"
else
    echo "✗ Failed to start ${service}"
    echo "  Check log: $log_file"
    rm -f "$pid_file"
    exit 1
fi
REMOTE
    then
        echo "✗ Failed to start $service on $machine" >&2
        return 1
    fi
    echo "✓ Successfully started $service on $machine"
    return 0
}

# Restart a local service on a remote machine via SSH
# Usage: remote_restart_service SERVICE_NAME MACHINE
remote_restart_service() {
    local service="$1"
    local machine="$2"

    if [ -z "$service" ] || [ -z "$machine" ]; then
        echo "Error: Service name and machine required" >&2
        return 1
    fi

    echo "Restarting $service on $machine..."

    if remote_stop_service "$service" "$machine"; then
        sleep 2
        remote_start_service "$service" "$machine"
        return $?
    else
        echo "Error: Failed to stop service, aborting restart" >&2
        return 1
    fi
}

# Kill any process using a specific port (improved with aggressive cleanup)
# Usage: kill_process_on_port PORT [MACHINE]
kill_process_on_port() {
    local port="$1"
    local machine="${2:-local}"

    if [ -z "$port" ]; then
        echo "Error: Port required" >&2
        return 1
    fi

    if [ "$machine" = "local" ]; then
        echo "Checking for existing processes on port $port..."

        # Find all PIDs using the port
        local pids
        pids=$(lsof -ti ":$port" 2>/dev/null)

        if [ -n "$pids" ]; then
            # Get process details for reporting
            local process_info
            process_info=$(lsof -i ":$port" 2>/dev/null | grep LISTEN | awk '{print $1 " (PID: " $2 ")"}' | sort -u)
            echo "Found processes on port $port:"
            # shellcheck disable=SC2001  # per-line prefix; bash parameter expansion can't anchor with ^
            echo "$process_info" | sed 's/^/  /'

            # Kill each PID and its children
            for pid in $pids; do
                if ps -p "$pid" > /dev/null 2>&1; then
                    echo "Killing process tree for PID $pid..."

                    # Find all child processes
                    local child_pids
                    child_pids=$(pgrep -P "$pid" 2>/dev/null)

                    # Try graceful termination first (SIGTERM)
                    kill -TERM "$pid" 2>/dev/null
                    if [ -n "$child_pids" ]; then
                        echo "$child_pids" | xargs kill -TERM 2>/dev/null
                    fi

                    # Wait up to 3 seconds for graceful shutdown
                    local count=0
                    while ps -p "$pid" > /dev/null 2>&1 && [ $count -lt 3 ]; do
                        sleep 1
                        count=$((count + 1))
                    done

                    # Force kill if still running
                    if ps -p "$pid" > /dev/null 2>&1; then
                        echo "  ⚠ Process $pid did not stop gracefully, forcing with SIGKILL..."
                        kill -9 "$pid" 2>/dev/null || true
                        if [ -n "$child_pids" ]; then
                            echo "$child_pids" | xargs kill -9 2>/dev/null || true
                        fi

                        # Final verification
                        sleep 1
                        if ps -p "$pid" > /dev/null 2>&1; then
                            echo "  ✗ Warning: Process $pid may still be running"
                        else
                            echo "  ✓ Process $pid forcefully killed"
                        fi
                    else
                        echo "  ✓ Process $pid terminated gracefully"
                    fi
                fi
            done

            # Verify port is actually clear
            local verify_count=0
            while lsof -ti ":$port" >/dev/null 2>&1 && [ $verify_count -lt 3 ]; do
                echo "  Port still in use, retrying cleanup..."
                local remaining_pids
                remaining_pids=$(lsof -ti ":$port" 2>/dev/null)
                echo "$remaining_pids" | xargs kill -9 2>/dev/null || true
                sleep 2
                verify_count=$((verify_count + 1))
            done

            if lsof -ti ":$port" >/dev/null 2>&1; then
                echo "✗ Warning: Port $port may still be in use by remaining processes"
                lsof -i ":$port" 2>/dev/null | grep LISTEN
                return 1
            else
                echo "✓ Port $port fully cleared"
            fi
        else
            echo "  No processes found on port $port"
        fi
    else
        # Remote machine cleanup via SSH
        local ip
        ip=$(get_machine_ip "$machine")
        local ssh_user
        ssh_user=$(get_machine_ssh_user "$machine")
        local ssh_port
        ssh_port=$(get_machine_ssh_port "$machine")

        echo "Checking for existing processes on port $port on $machine..."

        ssh -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" bash -s "$port" <<'EOF'
port=$1

# Find all PIDs using the port
pids=$(lsof -ti ":$port" 2>/dev/null)

if [ -n "$pids" ]; then
    # Get process details for reporting
    process_info=$(lsof -i :$port 2>/dev/null | grep LISTEN | awk '{print $1 " (PID: " $2 ")"}' | sort -u)
    echo "Found processes on port $port:"
    echo "$process_info" | sed 's/^/  /'

    # Kill each PID and its children
    for pid in $pids; do
        if ps -p "$pid" > /dev/null 2>&1; then
            echo "Killing process tree for PID $pid..."

            # Find all child processes
            child_pids=$(pgrep -P "$pid" 2>/dev/null)

            # Try graceful termination first (SIGTERM)
            kill -TERM "$pid" 2>/dev/null
            if [ -n "$child_pids" ]; then
                echo "$child_pids" | xargs kill -TERM 2>/dev/null
            fi

            # Wait up to 3 seconds for graceful shutdown
            count=0
            while ps -p "$pid" > /dev/null 2>&1 && [ $count -lt 3 ]; do
                sleep 1
                count=$((count + 1))
            done

            # Force kill if still running
            if ps -p "$pid" > /dev/null 2>&1; then
                echo "  ⚠ Process $pid did not stop gracefully, forcing with SIGKILL..."
                kill -9 "$pid" 2>/dev/null || true
                if [ -n "$child_pids" ]; then
                    echo "$child_pids" | xargs kill -9 2>/dev/null || true
                fi

                # Final verification
                sleep 1
                if ps -p "$pid" > /dev/null 2>&1; then
                    echo "  ✗ Warning: Process $pid may still be running"
                else
                    echo "  ✓ Process $pid forcefully killed"
                fi
            else
                echo "  ✓ Process $pid terminated gracefully"
            fi
        fi
    done

    # Verify port is actually clear
    verify_count=0
    while lsof -ti ":$port" >/dev/null 2>&1 && [ $verify_count -lt 3 ]; do
        echo "  Port still in use, retrying cleanup..."
        remaining_pids=$(lsof -ti ":$port" 2>/dev/null)
        echo "$remaining_pids" | xargs kill -9 2>/dev/null || true
        sleep 2
        verify_count=$((verify_count + 1))
    done

    if lsof -ti ":$port" >/dev/null 2>&1; then
        echo "✗ Warning: Port $port may still be in use by remaining processes"
        lsof -i :$port 2>/dev/null | grep LISTEN
        exit 1
    else
        echo "✓ Port $port fully cleared"
    fi
else
    echo "  No processes found on port $port"
fi
EOF
    fi
}

# Get service logs
# Usage: get_service_logs SERVICE_NAME [LINES] [MACHINE]
get_service_logs() {
    local service="$1"
    local lines="${2:-50}"
    local machine="${3:-local}"

    local log_file
    log_file=$(get_log_file "$service")

    if [ "$machine" = "local" ]; then
        if [ ! -f "$log_file" ]; then
            echo "Warning: Log file not found for service '$service'" >&2
            return 1
        fi

        tail -n "$lines" "$log_file"
    else
        local ip
        ip=$(get_machine_ip "$machine")
        local ssh_user
        ssh_user=$(get_machine_ssh_user "$machine")
        local ssh_port
        ssh_port=$(get_machine_ssh_port "$machine")

        ssh -p "$ssh_port" -o ConnectTimeout=10 "$ssh_user@$ip" "tail -n $lines $log_file" 2>/dev/null
    fi
}
