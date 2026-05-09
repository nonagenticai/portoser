#!/usr/bin/env bash
# =============================================================================
# lib/cluster/discovery.sh - Service Discovery Library
#
# Provides functions for discovering services across machines by scanning
# directories for docker-compose.yml and service.yml files.
#
# Functions:
#   - scan_machine_services()    Scan a machine for services
#   - discover_all_services()    Discover services on all machines
#   - parse_service_config()     Parse service configuration files
#
# Dependencies: ssh, yq, grep
# Created: 2025-12-03
# =============================================================================

set -euo pipefail

# Default configuration. Public — sourcing scripts may consume
# DISCOVERY_DEFAULT_PATHS to enumerate where services live (DISCOVERY_PATHS env
# overrides). Listed here so the discovery API surface is visible at the top
# of the file.
# shellcheck disable=SC2034 # public API surface, consumed by discovery callers
if [[ -n "${DISCOVERY_PATHS:-}" ]]; then
    IFS=',' read -ra DISCOVERY_DEFAULT_PATHS <<< "${DISCOVERY_PATHS}"
else
    DISCOVERY_DEFAULT_PATHS=(
        "${SERVICES_ROOT:-${HOME}/portoser}"
    )
fi

# =============================================================================
# parse_service_config - Parse service configuration from docker-compose.yml
#
# Extracts port and other configuration from a docker-compose.yml file.
# Looks for the first port mapping in the ports section.
#
# Parameters:
#   $1 - config_file (required): Path to docker-compose.yml or service.yml
#   $2 - config_type (required): "docker" or "native"
#
# Returns:
#   0 - Successfully parsed configuration
#   1 - Failed to parse or file not found
#
# Outputs:
#   Prints JSON object to stdout:
#   {
#     "type": "docker|native",
#     "port": "8080",
#     "name": "service-name"
#   }
#
# Example:
#   config=$(parse_service_config "/path/to/docker-compose.yml" "docker")
# =============================================================================
parse_service_config() {
    local config_file="$1"
    local config_type="$2"

    # Validate parameters
    if [[ -z "$config_file" ]]; then
        echo "Error: config_file parameter is required" >&2
        return 1
    fi

    if [[ -z "$config_type" ]]; then
        echo "Error: config_type parameter is required" >&2
        return 1
    fi

    if [[ ! -f "$config_file" ]]; then
        echo "Error: Config file not found: $config_file" >&2
        return 1
    fi

    local service_name
    service_name=$(basename "$(dirname "$config_file")")

    local port=""

    if [[ "$config_type" == "docker" ]]; then
        # Parse docker-compose.yml for port
        # Look for patterns like: - "8080:8080" or - 8080:8080
        port=$(grep -E '^\s+- ["\"]?[0-9]+:' "$config_file" 2>/dev/null | head -1 | \
               sed 's/.*"\([0-9]*\):.*/\1/' | sed 's/.*- \([0-9]*\):.*/\1/' || echo "")
    elif [[ "$config_type" == "native" ]]; then
        # Parse service.yml for port
        if command -v yq &> /dev/null; then
            port=$(yq eval '.port' "$config_file" 2>/dev/null || echo "")
        else
            # Fallback to grep if yq not available
            port=$(grep -E '^port:' "$config_file" 2>/dev/null | awk '{print $2}' || echo "")
        fi
    fi

    # Remove any quotes or whitespace
    port=$(echo "$port" | tr -d '"' | tr -d "'" | xargs)

    # Validate port is numeric
    if [[ -n "$port" ]] && [[ ! "$port" =~ ^[0-9]+$ ]]; then
        port=""
    fi

    # Output JSON
    if [[ -n "$port" ]]; then
        echo "{\"type\":\"$config_type\",\"port\":\"$port\",\"name\":\"$service_name\"}"
        return 0
    else
        echo "Error: Could not extract port from $config_file" >&2
        return 1
    fi
}

# =============================================================================
# scan_machine_services - Scan a machine for services
#
# Scans a directory on a machine (local or remote) for services by looking
# for docker-compose.yml and service.yml files. Returns a list of discovered
# services with their configurations.
#
# Parameters:
#   $1 - machine_name (required): Name of machine (any host key from registry.yml)
#   $2 - scan_path (required): Path to scan for services
#   $3 - is_remote (optional): Set to "true" for SSH scan
#                              Default: "false"
#   $4 - ssh_host (optional): SSH connection string (e.g., "user@host.example.local")
#                             Required if is_remote is true
#
# Returns:
#   0 - Successfully scanned (even if no services found)
#   1 - Scan failed
#   2 - Invalid parameters
#
# Outputs:
#   Prints newline-separated list of service info to stdout:
#   "service_name: docker, port=8080"
#   "service_name: native, port=8081"
#
# Example:
#   scan_machine_services "host-a" "<services-root>"
#   scan_machine_services "host-b" "<services-root>" "true" "user@host.example.local"
# =============================================================================
scan_machine_services() {
    local machine_name="$1"
    local scan_path="$2"
    local is_remote="${3:-false}"
    local ssh_host="${4:-}"

    # Validate parameters
    if [[ -z "$machine_name" ]]; then
        echo "Error: machine_name parameter is required" >&2
        return 2
    fi

    if [[ -z "$scan_path" ]]; then
        echo "Error: scan_path parameter is required" >&2
        return 2
    fi

    if [[ "$is_remote" == "true" ]] && [[ -z "$ssh_host" ]]; then
        echo "Error: ssh_host required when is_remote is true" >&2
        return 2
    fi

    # Build scan command
    local scan_cmd
    scan_cmd=$(cat <<'EOFCMD'
for dir in SCAN_PATH/*/; do
    name=$(basename "$dir")

    # Skip common non-service directories
    [[ "$name" == "TV" ]] && continue
    [[ "$name" == "node_modules" ]] && continue
    [[ "$name" == "logs" ]] && continue
    [[ "$name" == "scripts" ]] && continue
    [[ "$name" == "certs" ]] && continue
    [[ "$name" == "presentations_markdown" ]] && continue
    [[ "$name" == "actions-runner" ]] && continue
    [[ "$name" == "frontend" ]] && continue
    [[ "$name" == "planka-cleanup" ]] && continue

    # Check for docker-compose.yml
    if [[ -f "$dir/docker-compose.yml" ]]; then
        ports=$(grep -E "^\s+- [\"']?[0-9]+:" "$dir/docker-compose.yml" 2>/dev/null | head -1 | sed "s/.*\"\([0-9]*\):.*/\1/" | sed "s/.*- \([0-9]*\):.*/\1/")
        [[ -n "$ports" ]] && echo "$name: docker, port=$ports"
    fi

    # Check for service.yml
    if [[ -f "$dir/service.yml" ]]; then
        port=$(grep -E "^port:" "$dir/service.yml" 2>/dev/null | awk '{print $2}')
        [[ -n "$port" ]] && echo "$name: native, port=$port"
    fi
done
EOFCMD
    )

    # Replace SCAN_PATH placeholder
    scan_cmd="${scan_cmd//SCAN_PATH/$scan_path}"

    # Execute scan
    if [[ "$is_remote" == "true" ]]; then
        # Remote scan via SSH
        if ! command -v ssh &> /dev/null; then
            echo "Error: ssh is not installed" >&2
            return 2
        fi

        if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$ssh_host" "$scan_cmd" 2>/dev/null; then
            echo "Error: Failed to scan remote machine $machine_name" >&2
            return 1
        fi
    else
        # Local scan
        if [[ ! -d "$scan_path" ]]; then
            echo "Error: Scan path does not exist: $scan_path" >&2
            return 2
        fi

        eval "$scan_cmd"
    fi

    return 0
}

# =============================================================================
# discover_all_services - Discover services on all machines
#
# Scans all configured machines (both local and remote) for services.
# Returns aggregated results grouped by machine.
#
# Parameters:
#   $1 - registry_file (optional): Path to registry.yml for machine config
#                                  If not provided, uses default paths
#   $2 - output_format (optional): "text" or "json"
#                                  Default: "text"
#
# Returns:
#   0 - Successfully completed discovery
#   1 - Discovery completed with some errors
#
# Outputs:
#   If output_format is "text":
#     === MACHINE1 SERVICES ===
#     service1: docker, port=8080
#     service2: native, port=8081
#
#     === MACHINE2 SERVICES ===
#     ...
#
#   If output_format is "json":
#     {
#       "machines": [
#         {
#           "name": "host-a",
#           "services": [...]
#         }
#       ]
#     }
#
# Example:
#   discover_all_services "/path/to/registry.yml" "text"
#   discover_all_services "" "json"
# =============================================================================
discover_all_services() {
    local registry_file="${1:-}"
    local output_format="${2:-text}"

    local has_errors=false

    if [[ "$output_format" == "json" ]]; then
        echo "{"
        echo "  \"machines\": ["
    fi

    # Define machines to scan
    declare -A machines

    if [[ -n "$registry_file" ]] && [[ -f "$registry_file" ]]; then
        # Use registry.yml for machine configuration
        if command -v yq &> /dev/null; then
            local hosts
            hosts=$(yq eval '.hosts | keys | .[]' "$registry_file" 2>/dev/null)

            while IFS= read -r host; do
                [[ -z "$host" ]] && continue

                local host_ip
                local host_user
                local host_path

                host_ip=$(yq eval ".hosts.${host}.ip" "$registry_file" 2>/dev/null)
                host_user=$(yq eval ".hosts.${host}.ssh_user" "$registry_file" 2>/dev/null)
                host_path=$(yq eval ".hosts.${host}.path" "$registry_file" 2>/dev/null)

                # Fall back to "$HOME/portoser" on the remote when the
                # registry doesn't pin a path for this host. The platform
                # determines the home prefix (Linux vs macOS).
                if [[ -z "$host_path" || "$host_path" == "null" ]]; then
                    if [[ "$host" =~ ^pi[0-9]+$ ]]; then
                        host_path="/home/${host}/portoser"
                    else
                        host_path="/Users/${host}/portoser"
                    fi
                fi

                machines["$host"]="${host_user}@${host_ip}:${host_path}"
            done <<< "$hosts"
        fi
    else
        # Fall back to cluster.conf if the registry file does not list hosts.
        local cluster_conf="${CLUSTER_CONF:-${PORTOSER_ROOT:-$(pwd)}/cluster.conf}"
        if [[ -f "${cluster_conf}" ]]; then
            # shellcheck disable=SC1090
            source "${cluster_conf}"
            local _h
            for _h in "${!CLUSTER_HOSTS[@]}"; do
                local _path="${CLUSTER_PATHS[$_h]:-${SERVICES_ROOT:-${HOME}/portoser}}"
                machines["$_h"]="${CLUSTER_HOSTS[$_h]}:${_path}"
            done
        else
            # Single-host fallback: scan the local services root only.
            machines["local"]="localhost:${SERVICES_ROOT:-${HOME}/portoser}"
        fi
    fi

    local first_machine=true

    # Scan each machine
    for machine_name in "${!machines[@]}"; do
        local machine_config="${machines[$machine_name]}"
        local ssh_host="${machine_config%%:*}"
        local scan_path="${machine_config##*:}"

        if [[ "$output_format" == "text" ]]; then
            echo ""
            echo "=== ${machine_name^^} SERVICES ==="
        else
            if [[ "$first_machine" == true ]]; then
                first_machine=false
            else
                echo ","
            fi
            echo "    {"
            echo "      \"name\": \"$machine_name\","
            echo "      \"services\": ["
        fi

        # Determine if local or remote
        local is_remote="true"
        if [[ -d "$scan_path" ]]; then
            is_remote="false"
            ssh_host=""
        fi

        # Scan machine
        local scan_result
        if scan_result=$(scan_machine_services "$machine_name" "$scan_path" "$is_remote" "$ssh_host" 2>/dev/null); then
            if [[ "$output_format" == "text" ]]; then
                if [[ -n "$scan_result" ]]; then
                    echo "$scan_result"
                else
                    echo "(no services found)"
                fi
            else
                # JSON output
                local first_service=true
                while IFS= read -r line; do
                    [[ -z "$line" ]] && continue

                    if [[ "$first_service" == true ]]; then
                        first_service=false
                    else
                        echo ","
                    fi

                    # Parse service line
                    local svc_name="${line%%:*}"
                    local svc_rest="${line#*: }"
                    local svc_type="${svc_rest%%,*}"
                    local svc_port="${svc_rest##*=}"

                    echo -n "        {\"name\":\"$svc_name\",\"type\":\"$svc_type\",\"port\":\"$svc_port\"}"
                done <<< "$scan_result"

                [[ "$first_service" == false ]] && echo ""
            fi
        else
            has_errors=true
            if [[ "$output_format" == "text" ]]; then
                echo "(scan failed)"
            fi
        fi

        if [[ "$output_format" == "json" ]]; then
            echo "      ]"
            echo -n "    }"
        fi
    done

    if [[ "$output_format" == "json" ]]; then
        echo ""
        echo "  ]"
        echo "}"
    fi

    if [[ "$has_errors" == true ]]; then
        return 1
    fi

    return 0
}

# =============================================================================
# Library initialization check
# =============================================================================

# Verify this script is being sourced, not executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This library should be sourced, not executed directly" >&2
    echo "Usage: source lib/cluster/discovery.sh" >&2
    exit 1
fi
