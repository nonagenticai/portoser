#!/usr/bin/env bash
################################################################################
# Validation & Type Safety Module
#
# Purpose: Comprehensive validation and type safety to prevent runtime errors
#
# Features:
# - Validates all input parameters
# - Checks required commands exist (docker, yq, ssh, etc.)
# - Validates registry.yml format and content
# - Sanitizes inputs to prevent command injection
# - Bash strict mode (set -euo pipefail)
# - File/directory existence checks
# - Environment variable validation
# - Type checking for associative arrays
#
# Usage:
#   source /tmp/agent4_validation.sh
#   validate_environment
#   validate_registry_file "$CADDY_REGISTRY_PATH"
#   sanitize_input "$user_input"
################################################################################

set -euo pipefail

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_INVALID_ARGS=1
readonly EXIT_MISSING_COMMAND=2
readonly EXIT_INVALID_REGISTRY=3
readonly EXIT_INVALID_SERVICE=4
readonly EXIT_INVALID_HOST=5
readonly EXIT_FILE_NOT_FOUND=6
readonly EXIT_INVALID_ENV=7
readonly EXIT_SECURITY_VIOLATION=8

# Color codes for output
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_RESET='\033[0m'

################################################################################
# BASH VERSION VALIDATION
################################################################################

# Function: validate_bash_version
# Description: Validates that bash version is 4.0 or higher (required for associative arrays)
# Arguments: None
# Returns: 0 if valid, EXIT_INVALID_ENV if invalid
# Output: Error message if validation fails
validate_bash_version() {
    local bash_version="${BASH_VERSION%%.*}"

    if [ -z "$bash_version" ]; then
        echo -e "${COLOR_RED}Error: Cannot determine bash version${COLOR_RESET}" >&2
        return $EXIT_INVALID_ENV
    fi

    if [ "$bash_version" -lt 4 ]; then
        echo -e "${COLOR_RED}Error: Bash version 4.0 or higher required (found ${BASH_VERSION})${COLOR_RESET}" >&2
        echo -e "${COLOR_YELLOW}Tip: On macOS, install bash via Homebrew: brew install bash${COLOR_RESET}" >&2
        return $EXIT_INVALID_ENV
    fi

    return $EXIT_SUCCESS
}

################################################################################
# COMMAND EXISTENCE VALIDATION
################################################################################

# Function: validate_command_exists
# Description: Checks if a command exists in PATH
# Arguments:
#   $1 - command name (e.g., "docker", "yq", "ssh")
# Returns: 0 if exists, EXIT_MISSING_COMMAND if not found
# Output: Error message if command not found
validate_command_exists() {
    local cmd="$1"

    if [ -z "$cmd" ]; then
        echo -e "${COLOR_RED}Error: Command name required${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${COLOR_RED}Error: Required command '$cmd' not found in PATH${COLOR_RESET}" >&2
        echo -e "${COLOR_YELLOW}Tip: Install '$cmd' before proceeding${COLOR_RESET}" >&2
        return $EXIT_MISSING_COMMAND
    fi

    return $EXIT_SUCCESS
}

# Function: validate_required_commands
# Description: Validates that all required commands are available
# Arguments: None (checks standard portoser requirements)
# Returns: 0 if all commands exist, EXIT_MISSING_COMMAND if any missing
# Output: Error messages for missing commands
validate_required_commands() {
    local required_commands=(
        "bash"
        "docker"
        "docker-compose"
        "yq"
        "ssh"
        "scp"
        "curl"
        "nc"
        "grep"
        "awk"
        "sed"
        "jq"
        "git"
        "date"
        "mktemp"
        "dirname"
        "basename"
        "timeout"
    )

    local missing_commands=()

    echo -e "${COLOR_BLUE}Checking required commands...${COLOR_RESET}"

    for cmd in "${required_commands[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${COLOR_GREEN}  ✓ $cmd${COLOR_RESET}"
        else
            echo -e "${COLOR_RED}  ✗ $cmd (MISSING)${COLOR_RESET}"
            missing_commands+=("$cmd")
        fi
    done

    if [ ${#missing_commands[@]} -gt 0 ]; then
        echo ""
        echo -e "${COLOR_RED}Error: Missing required commands:${COLOR_RESET}" >&2
        for cmd in "${missing_commands[@]}"; do
            echo -e "${COLOR_YELLOW}  - $cmd${COLOR_RESET}" >&2
            case "$cmd" in
                docker)
                    echo -e "${COLOR_YELLOW}    Install: https://www.docker.com/products/docker-desktop${COLOR_RESET}" >&2
                    ;;
                docker-compose)
                    echo -e "${COLOR_YELLOW}    Install: https://docs.docker.com/compose/install/${COLOR_RESET}" >&2
                    echo -e "${COLOR_YELLOW}    Or: brew install docker-compose${COLOR_RESET}" >&2
                    ;;
                ssh|scp)
                    echo -e "${COLOR_YELLOW}    Ensure SSH is installed (usually pre-installed)${COLOR_RESET}" >&2
                    ;;
                yq)
                    echo -e "${COLOR_YELLOW}    Install: brew install yq (macOS)${COLOR_RESET}" >&2
                    echo -e "${COLOR_YELLOW}    Or: sudo apt-get install yq (Linux)${COLOR_RESET}" >&2
                    ;;
                timeout)
                    echo -e "${COLOR_YELLOW}    Usually pre-installed. For macOS GNU timeout: brew install coreutils${COLOR_RESET}" >&2
                    ;;
                *)
                    echo -e "${COLOR_YELLOW}    Please install $cmd before proceeding${COLOR_RESET}" >&2
                    ;;
            esac
        done
        echo ""
        return $EXIT_MISSING_COMMAND
    fi

    echo -e "${COLOR_GREEN}✓ All required commands available${COLOR_RESET}"
    return $EXIT_SUCCESS
}

# Function: validate_docker_running
# Description: Checks if Docker daemon is running
# Arguments: None
# Returns: 0 if running, EXIT_MISSING_COMMAND if not
# Output: Error message if Docker not running
validate_docker_running() {
    if ! docker info >/dev/null 2>&1; then
        echo -e "${COLOR_RED}Error: Docker daemon is not running${COLOR_RESET}" >&2
        echo -e "${COLOR_YELLOW}Tip: Start Docker Desktop or dockerd service${COLOR_RESET}" >&2
        return $EXIT_MISSING_COMMAND
    fi

    return $EXIT_SUCCESS
}

################################################################################
# INPUT SANITIZATION
################################################################################

# Function: sanitize_input
# Description: Sanitizes user input to prevent command injection
# Arguments:
#   $1 - input string to sanitize
# Returns: 0 always
# Output: Sanitized string to stdout
sanitize_input() {
    local input="$1"

    # Remove or escape dangerous characters
    # Allow: alphanumeric, dash, underscore, dot, slash, colon
    # Escape: semicolon, pipe, ampersand, backtick, dollar, parentheses
    local sanitized="${input//;/\\;}"
    sanitized="${sanitized//|/\\|}"
    sanitized="${sanitized//&/\\&}"
    sanitized="${sanitized//\`/\\\`}"
    sanitized="${sanitized//$/\\$}"
    sanitized="${sanitized//(/\\(}"
    sanitized="${sanitized//)/\\)}"
    sanitized="${sanitized//</\\<}"
    sanitized="${sanitized//>/\\>}"

    echo "$sanitized"
}

# Function: validate_service_name
# Description: Validates service name format (alphanumeric, dash, underscore only)
# Arguments:
#   $1 - service name
# Returns: 0 if valid, EXIT_INVALID_SERVICE if invalid
# Output: Error message if validation fails
validate_service_name() {
    local service="$1"

    if [ -z "$service" ]; then
        echo -e "${COLOR_RED}Error: Service name cannot be empty${COLOR_RESET}" >&2
        return $EXIT_INVALID_SERVICE
    fi

    # Check for valid characters (alphanumeric, dash, underscore, dot)
    if ! [[ "$service" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo -e "${COLOR_RED}Error: Invalid service name '$service'${COLOR_RESET}" >&2
        echo -e "${COLOR_YELLOW}Service names must contain only: a-z A-Z 0-9 . _ -${COLOR_RESET}" >&2
        return $EXIT_INVALID_SERVICE
    fi

    # Check length (1-100 characters)
    local len=${#service}
    if [ "$len" -lt 1 ] || [ "$len" -gt 100 ]; then
        echo -e "${COLOR_RED}Error: Service name length must be 1-100 characters${COLOR_RESET}" >&2
        return $EXIT_INVALID_SERVICE
    fi

    return $EXIT_SUCCESS
}

# Function: validate_host_name
# Description: Validates host/machine name format
# Arguments:
#   $1 - host name
# Returns: 0 if valid, EXIT_INVALID_HOST if invalid
# Output: Error message if validation fails
validate_host_name() {
    local host="$1"

    if [ -z "$host" ]; then
        echo -e "${COLOR_RED}Error: Host name cannot be empty${COLOR_RESET}" >&2
        return $EXIT_INVALID_HOST
    fi

    # Check for valid characters (alphanumeric, dash, underscore, dot)
    if ! [[ "$host" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo -e "${COLOR_RED}Error: Invalid host name '$host'${COLOR_RESET}" >&2
        echo -e "${COLOR_YELLOW}Host names must contain only: a-z A-Z 0-9 . _ -${COLOR_RESET}" >&2
        return $EXIT_INVALID_HOST
    fi

    # Check length (1-63 characters, per DNS standards)
    local len=${#host}
    if [ "$len" -lt 1 ] || [ "$len" -gt 63 ]; then
        echo -e "${COLOR_RED}Error: Host name length must be 1-63 characters${COLOR_RESET}" >&2
        return $EXIT_INVALID_HOST
    fi

    return $EXIT_SUCCESS
}

# Function: validate_ip_address
# Description: Validates IPv4 address format
# Arguments:
#   $1 - IP address
# Returns: 0 if valid, EXIT_INVALID_ARGS if invalid
# Output: Error message if validation fails
validate_ip_address() {
    local ip="$1"

    if [ -z "$ip" ]; then
        echo -e "${COLOR_RED}Error: IP address cannot be empty${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    # Basic IPv4 format check
    if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo -e "${COLOR_RED}Error: Invalid IP address format '$ip'${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    # Validate each octet (0-255)
    IFS='.' read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
            echo -e "${COLOR_RED}Error: Invalid IP address '$ip' (octet out of range)${COLOR_RESET}" >&2
            return $EXIT_INVALID_ARGS
        fi
    done

    return $EXIT_SUCCESS
}

# Function: validate_port_number
# Description: Validates port number (1-65535)
# Arguments:
#   $1 - port number
# Returns: 0 if valid, EXIT_INVALID_ARGS if invalid
# Output: Error message if validation fails
validate_port_number() {
    local port="$1"

    if [ -z "$port" ]; then
        echo -e "${COLOR_RED}Error: Port number cannot be empty${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    # Check if numeric
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        echo -e "${COLOR_RED}Error: Port must be numeric (got '$port')${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    # Check range (1-65535)
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${COLOR_RED}Error: Port must be between 1 and 65535 (got $port)${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    # Check for port 8000 (per user instructions)
    if [ "$port" -eq 8000 ]; then
        echo -e "${COLOR_RED}Error: Port 8000 is reserved and cannot be used${COLOR_RESET}" >&2
        echo -e "${COLOR_YELLOW}Tip: Choose a different port (8000 is forbidden per user configuration)${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    return $EXIT_SUCCESS
}

################################################################################
# FILE AND DIRECTORY VALIDATION
################################################################################

# Function: check_file_exists
# Description: Checks if a file exists and is readable
# Arguments:
#   $1 - file path
# Returns: 0 if exists and readable, EXIT_FILE_NOT_FOUND if not
# Output: Error message if file not found or not readable
check_file_exists() {
    local file_path="$1"

    if [ -z "$file_path" ]; then
        echo -e "${COLOR_RED}Error: File path cannot be empty${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    if [ ! -f "$file_path" ]; then
        echo -e "${COLOR_RED}Error: File not found: $file_path${COLOR_RESET}" >&2
        return $EXIT_FILE_NOT_FOUND
    fi

    if [ ! -r "$file_path" ]; then
        echo -e "${COLOR_RED}Error: File not readable: $file_path${COLOR_RESET}" >&2
        return $EXIT_FILE_NOT_FOUND
    fi

    return $EXIT_SUCCESS
}

# Function: check_directory_exists
# Description: Checks if a directory exists and is accessible
# Arguments:
#   $1 - directory path
# Returns: 0 if exists and accessible, EXIT_FILE_NOT_FOUND if not
# Output: Error message if directory not found or not accessible
check_directory_exists() {
    local dir_path="$1"

    if [ -z "$dir_path" ]; then
        echo -e "${COLOR_RED}Error: Directory path cannot be empty${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    if [ ! -d "$dir_path" ]; then
        echo -e "${COLOR_RED}Error: Directory not found: $dir_path${COLOR_RESET}" >&2
        return $EXIT_FILE_NOT_FOUND
    fi

    if [ ! -x "$dir_path" ]; then
        echo -e "${COLOR_RED}Error: Directory not accessible: $dir_path${COLOR_RESET}" >&2
        return $EXIT_FILE_NOT_FOUND
    fi

    return $EXIT_SUCCESS
}

# Function: check_file_writable
# Description: Checks if a file path is writable (file or parent directory)
# Arguments:
#   $1 - file path
# Returns: 0 if writable, EXIT_FILE_NOT_FOUND if not
# Output: Error message if not writable
check_file_writable() {
    local file_path="$1"

    if [ -z "$file_path" ]; then
        echo -e "${COLOR_RED}Error: File path cannot be empty${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    if [ -f "$file_path" ]; then
        # File exists, check if writable
        if [ ! -w "$file_path" ]; then
            echo -e "${COLOR_RED}Error: File not writable: $file_path${COLOR_RESET}" >&2
            return $EXIT_FILE_NOT_FOUND
        fi
    else
        # File doesn't exist, check if parent directory is writable
        local parent_dir
        parent_dir=$(dirname "$file_path")
        if [ ! -d "$parent_dir" ]; then
            echo -e "${COLOR_RED}Error: Parent directory does not exist: $parent_dir${COLOR_RESET}" >&2
            return $EXIT_FILE_NOT_FOUND
        fi
        if [ ! -w "$parent_dir" ]; then
            echo -e "${COLOR_RED}Error: Cannot write to directory: $parent_dir${COLOR_RESET}" >&2
            return $EXIT_FILE_NOT_FOUND
        fi
    fi

    return $EXIT_SUCCESS
}

################################################################################
# YAML FILE VALIDATION
################################################################################

# Function: validate_yaml_file
# Description: Validates that a file is valid YAML
# Arguments:
#   $1 - file path
# Returns: 0 if valid, EXIT_INVALID_REGISTRY if invalid
# Output: Error message if YAML is invalid
validate_yaml_file() {
    local file_path="$1"

    if ! check_file_exists "$file_path"; then
        return $EXIT_FILE_NOT_FOUND
    fi

    # Check if yq is available
    if ! command -v yq >/dev/null 2>&1; then
        echo -e "${COLOR_RED}Error: yq command not found (required for YAML validation)${COLOR_RESET}" >&2
        return $EXIT_MISSING_COMMAND
    fi

    # Validate YAML syntax
    if ! yq eval '.' "$file_path" >/dev/null 2>&1; then
        echo -e "${COLOR_RED}Error: Invalid YAML in file: $file_path${COLOR_RESET}" >&2
        return $EXIT_INVALID_REGISTRY
    fi

    return $EXIT_SUCCESS
}

################################################################################
# REGISTRY FILE VALIDATION
################################################################################

# Function: validate_registry_file
# Description: Validates registry.yml format and content
# Arguments:
#   $1 - registry file path
# Returns: 0 if valid, EXIT_INVALID_REGISTRY if invalid
# Output: Detailed error messages for validation failures
validate_registry_file() {
    local registry_path="$1"

    if [ -z "$registry_path" ]; then
        echo -e "${COLOR_RED}Error: Registry file path required${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    # Check file exists
    if ! check_file_exists "$registry_path"; then
        return $EXIT_FILE_NOT_FOUND
    fi

    # Validate YAML syntax
    if ! validate_yaml_file "$registry_path"; then
        return $EXIT_INVALID_REGISTRY
    fi

    local errors=0

    # Check required top-level fields
    local required_fields=("domain" "hosts" "services")
    for field in "${required_fields[@]}"; do
        local value
        value=$(yq eval ".$field" "$registry_path" 2>/dev/null)
        if [ "$value" = "null" ] || [ -z "$value" ]; then
            echo -e "${COLOR_RED}Error: Missing required field '$field' in registry${COLOR_RESET}" >&2
            errors=$((errors + 1))
        fi
    done

    if [ $errors -gt 0 ]; then
        return $EXIT_INVALID_REGISTRY
    fi

    # Validate hosts section
    local hosts
    hosts=$(yq eval '.hosts | keys | .[]' "$registry_path" 2>/dev/null)
    if [ -z "$hosts" ]; then
        echo -e "${COLOR_RED}Error: No hosts defined in registry${COLOR_RESET}" >&2
        return $EXIT_INVALID_REGISTRY
    fi

    while IFS= read -r host; do
        if [ -z "$host" ]; then
            continue
        fi

        # Validate host name
        if ! validate_host_name "$host"; then
            errors=$((errors + 1))
            continue
        fi

        # Check required host fields
        local ip
        ip=$(yq eval ".hosts.$host.ip" "$registry_path" 2>/dev/null)
        if [ "$ip" = "null" ] || [ -z "$ip" ]; then
            echo -e "${COLOR_RED}Error: Host '$host' missing IP address${COLOR_RESET}" >&2
            errors=$((errors + 1))
        else
            if ! validate_ip_address "$ip"; then
                errors=$((errors + 1))
            fi
        fi

        local ssh_user
        ssh_user=$(yq eval ".hosts.$host.ssh_user" "$registry_path" 2>/dev/null)
        if [ "$ssh_user" = "null" ] || [ -z "$ssh_user" ]; then
            echo -e "${COLOR_YELLOW}Warning: Host '$host' missing ssh_user (will default to current user)${COLOR_RESET}" >&2
        fi

        local path
        path=$(yq eval ".hosts.$host.path" "$registry_path" 2>/dev/null)
        if [ "$path" = "null" ] || [ -z "$path" ]; then
            echo -e "${COLOR_YELLOW}Warning: Host '$host' missing path${COLOR_RESET}" >&2
        fi
    done <<< "$hosts"

    # Validate services section
    local services
    services=$(yq eval '.services | keys | .[]' "$registry_path" 2>/dev/null)
    if [ -z "$services" ]; then
        echo -e "${COLOR_YELLOW}Warning: No services defined in registry${COLOR_RESET}" >&2
    else
        while IFS= read -r service; do
            if [ -z "$service" ]; then
                continue
            fi

            # Validate service name
            if ! validate_service_name "$service"; then
                errors=$((errors + 1))
                continue
            fi

            # Check required service fields
            local current_host
            current_host=$(yq eval ".services.$service.current_host" "$registry_path" 2>/dev/null)
            if [ "$current_host" = "null" ] || [ -z "$current_host" ]; then
                echo -e "${COLOR_YELLOW}Warning: Service '$service' missing current_host${COLOR_RESET}" >&2
            else
                # Verify host exists
                local host_ip
                host_ip=$(yq eval ".hosts.$current_host.ip" "$registry_path" 2>/dev/null)
                if [ "$host_ip" = "null" ] || [ -z "$host_ip" ]; then
                    echo -e "${COLOR_RED}Error: Service '$service' references non-existent host '$current_host'${COLOR_RESET}" >&2
                    errors=$((errors + 1))
                fi
            fi

            local port
            port=$(yq eval ".services.$service.port" "$registry_path" 2>/dev/null)
            if [ "$port" != "null" ] && [ -n "$port" ]; then
                if ! validate_port_number "$port"; then
                    errors=$((errors + 1))
                fi
            fi
        done <<< "$services"
    fi

    # Check for port conflicts
    declare -A host_ports
    while IFS= read -r service; do
        if [ -z "$service" ]; then
            continue
        fi

        local host
        host=$(yq eval ".services.$service.current_host" "$registry_path" 2>/dev/null)
        local port
        port=$(yq eval ".services.$service.port" "$registry_path" 2>/dev/null)

        if [ "$host" != "null" ] && [ "$port" != "null" ] && [ -n "$host" ] && [ -n "$port" ]; then
            local key="${host}:${port}"
            if [ "${host_ports[$key]+_}" ]; then
                echo -e "${COLOR_RED}Error: Port conflict - Services '$service' and '${host_ports[$key]}' both use port $port on host $host${COLOR_RESET}" >&2
                errors=$((errors + 1))
            else
                host_ports[$key]="$service"
            fi
        fi
    done <<< "$services"

    if [ $errors -gt 0 ]; then
        echo -e "${COLOR_RED}Registry validation failed with $errors error(s)${COLOR_RESET}" >&2
        return $EXIT_INVALID_REGISTRY
    fi

    echo -e "${COLOR_GREEN}✓ Registry file validation passed${COLOR_RESET}"
    return $EXIT_SUCCESS
}

################################################################################
# DOCKER COMPOSE FILE VALIDATION
################################################################################

# Function: validate_docker_compose_file
# Description: Validates docker-compose.yml format and required fields
# Arguments:
#   $1 - docker-compose file path
# Returns: 0 if valid, EXIT_INVALID_REGISTRY if invalid
# Output: Error messages for validation failures
validate_docker_compose_file() {
    local compose_file="$1"

    if [ -z "$compose_file" ]; then
        echo -e "${COLOR_RED}Error: Docker compose file path required${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    # Check file exists
    if ! check_file_exists "$compose_file"; then
        return $EXIT_FILE_NOT_FOUND
    fi

    # Validate YAML syntax
    if ! validate_yaml_file "$compose_file"; then
        return $EXIT_INVALID_REGISTRY
    fi

    # Check for services section
    local services
    services=$(yq eval '.services' "$compose_file" 2>/dev/null)
    if [ "$services" = "null" ] || [ -z "$services" ]; then
        echo -e "${COLOR_RED}Error: Docker compose file missing 'services' section${COLOR_RESET}" >&2
        return $EXIT_INVALID_REGISTRY
    fi

    # Check version (optional but recommended)
    local version
    version=$(yq eval '.version' "$compose_file" 2>/dev/null)
    if [ "$version" = "null" ] || [ -z "$version" ]; then
        echo -e "${COLOR_YELLOW}Warning: Docker compose file missing 'version' field${COLOR_RESET}" >&2
    fi

    return $EXIT_SUCCESS
}

# Function: validate_registry_v3_service_paths
# Description: Validates service paths in registry v3 format (supports both docker_compose and service_file)
# Arguments:
#   $1 - registry file path
#   $2 - host name to validate (optional, validates all if not provided)
# Returns: 0 if valid, EXIT_INVALID_REGISTRY if invalid
# Output: Error messages for validation failures
validate_registry_v3_service_paths() {
    local registry_path="$1"
    local target_host="${2:-}"

    if [ -z "$registry_path" ]; then
        echo -e "${COLOR_RED}Error: Registry file path required${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    local errors=0
    local checked=0

    # Get all services
    local services
    services=$(yq eval '.services | keys | .[]' "$registry_path" 2>/dev/null)

    if [ -z "$services" ]; then
        echo -e "${COLOR_YELLOW}Warning: No services found in registry${COLOR_RESET}" >&2
        return $EXIT_SUCCESS
    fi

    while IFS= read -r service; do
        [ -z "$service" ] && continue

        local host
        host=$(yq eval ".services.$service.current_host" "$registry_path" 2>/dev/null)

        # Skip if filtering by host and this isn't the target host
        if [ -n "$target_host" ] && [ "$host" != "$target_host" ]; then
            continue
        fi

        # Check for docker_compose field
        local docker_compose
        docker_compose=$(yq eval ".services.$service.docker_compose" "$registry_path" 2>/dev/null)

        # Check for service_file field
        local service_file
        service_file=$(yq eval ".services.$service.service_file" "$registry_path" 2>/dev/null)

        # Validate that service has either docker_compose or service_file
        if [ "$docker_compose" != "null" ] && [ -n "$docker_compose" ]; then
            checked=$((checked + 1))
            echo -e "${COLOR_BLUE}Checking docker_compose for service '$service' on host '$host'${COLOR_RESET}"

            local host_path
            host_path=$(yq eval ".hosts.$host.path" "$registry_path" 2>/dev/null)
            local full_path="${host_path}${docker_compose}"

            # Only validate if on current host
            local current_hostname
            current_hostname=$(hostname -s 2>/dev/null || hostname)
            if [ "$host" = "$current_hostname" ] || [ "$host" = "$(whoami)" ]; then
                if ! check_file_exists "$full_path"; then
                    errors=$((errors + 1))
                fi
            else
                echo -e "${COLOR_YELLOW}  Skipping (remote host)${COLOR_RESET}"
            fi
        elif [ "$service_file" != "null" ] && [ -n "$service_file" ]; then
            checked=$((checked + 1))
            echo -e "${COLOR_BLUE}Checking service_file for service '$service' on host '$host'${COLOR_RESET}"

            local host_path
            host_path=$(yq eval ".hosts.$host.path" "$registry_path" 2>/dev/null)
            local full_path="${host_path}${service_file}"

            # Only validate if on current host
            local current_hostname
            current_hostname=$(hostname -s 2>/dev/null || hostname)
            if [ "$host" = "$current_hostname" ] || [ "$host" = "$(whoami)" ]; then
                if ! check_file_exists "$full_path"; then
                    errors=$((errors + 1))
                fi
            else
                echo -e "${COLOR_YELLOW}  Skipping (remote host)${COLOR_RESET}"
            fi
        else
            echo -e "${COLOR_YELLOW}Warning: Service '$service' has neither docker_compose nor service_file field${COLOR_RESET}" >&2
        fi
    done <<< "$services"

    if [ $checked -eq 0 ]; then
        echo -e "${COLOR_YELLOW}No services checked (possibly all on remote hosts)${COLOR_RESET}"
    fi

    if [ $errors -gt 0 ]; then
        echo -e "${COLOR_RED}Service path validation failed with $errors error(s)${COLOR_RESET}" >&2
        return $EXIT_INVALID_REGISTRY
    fi

    echo -e "${COLOR_GREEN}✓ Service path validation passed (checked $checked services)${COLOR_RESET}"
    return $EXIT_SUCCESS
}

# Function: validate_service_yml
# Description: Validates service.yml format for native services
# Arguments:
#   $1 - service.yml file path
# Returns: 0 if valid, EXIT_INVALID_REGISTRY if invalid
# Output: Error messages for validation failures
validate_service_yml() {
    local service_file="$1"

    if [ -z "$service_file" ]; then
        echo -e "${COLOR_RED}Error: Service file path required${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    # Check file exists
    if ! check_file_exists "$service_file"; then
        return $EXIT_FILE_NOT_FOUND
    fi

    # Validate YAML syntax
    if ! validate_yaml_file "$service_file"; then
        return $EXIT_INVALID_REGISTRY
    fi

    return $EXIT_SUCCESS
}

################################################################################
# ENVIRONMENT VALIDATION
################################################################################

# Function: validate_environment_variable
# Description: Validates that an environment variable is set and non-empty
# Arguments:
#   $1 - variable name
#   $2 - (optional) default value if not set
# Returns: 0 if valid, EXIT_INVALID_ENV if not set
# Output: Error message if variable not set
validate_environment_variable() {
    local var_name="$1"
    local default_value="${2:-}"

    if [ -z "$var_name" ]; then
        echo -e "${COLOR_RED}Error: Variable name required${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    # Check if variable is set
    if [ -z "${!var_name:-}" ]; then
        if [ -n "$default_value" ]; then
            echo -e "${COLOR_YELLOW}Warning: $var_name not set, using default: $default_value${COLOR_RESET}" >&2
            # Note: Cannot set the variable from here, caller must handle
            return $EXIT_SUCCESS
        else
            echo -e "${COLOR_RED}Error: Required environment variable '$var_name' is not set${COLOR_RESET}" >&2
            return $EXIT_INVALID_ENV
        fi
    fi

    return $EXIT_SUCCESS
}

# Function: validate_environment
# Description: Validates complete portoser environment setup
# Arguments: None
# Returns: 0 if valid, appropriate exit code if not
# Output: Detailed validation results
validate_environment() {
    local errors=0

    echo -e "${COLOR_BLUE}Validating portoser environment...${COLOR_RESET}"
    echo ""

    # Check bash version
    if ! validate_bash_version; then
        errors=$((errors + 1))
    fi

    # Check required commands
    if ! validate_required_commands; then
        errors=$((errors + 1))
    fi

    # Check Docker
    echo -n "Checking Docker... "
    if validate_docker_running; then
        echo -e "${COLOR_GREEN}✓${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}⚠ (may not be required for all operations)${COLOR_RESET}"
    fi

    # Check environment variables
    echo ""
    echo -e "${COLOR_BLUE}Checking environment variables...${COLOR_RESET}"

    local env_vars=(
        "CADDY_REGISTRY_PATH"
        "SERVICES_ROOT"
    )

    for var in "${env_vars[@]}"; do
        echo -n "  $var: "
        if [ -n "${!var:-}" ]; then
            echo -e "${COLOR_GREEN}✓ ${!var}${COLOR_RESET}"
        else
            echo -e "${COLOR_YELLOW}⚠ not set${COLOR_RESET}"
        fi
    done

    # Check registry file if path is set
    if [ -n "${CADDY_REGISTRY_PATH:-}" ]; then
        echo ""
        echo -e "${COLOR_BLUE}Validating registry file...${COLOR_RESET}"
        if validate_registry_file "$CADDY_REGISTRY_PATH"; then
            # Success message already printed by validate_registry_file
            :
        else
            errors=$((errors + 1))
        fi
    fi

    echo ""
    if [ $errors -eq 0 ]; then
        echo -e "${COLOR_GREEN}✓ Environment validation passed${COLOR_RESET}"
        return $EXIT_SUCCESS
    else
        echo -e "${COLOR_RED}✗ Environment validation failed with $errors error(s)${COLOR_RESET}" >&2
        return $EXIT_INVALID_ENV
    fi
}

################################################################################
# SSH VALIDATION
################################################################################

# Function: validate_ssh_connection
# Description: Validates SSH connectivity to a host
# Arguments:
#   $1 - ssh user
#   $2 - ssh host (IP or hostname)
#   $3 - (optional) ssh port (default: 22)
# Returns: 0 if connection successful, EXIT_INVALID_HOST if failed
# Output: Error message if connection fails
validate_ssh_connection() {
    local ssh_user="$1"
    local ssh_host="$2"
    local ssh_port="${3:-22}"

    if [ -z "$ssh_user" ] || [ -z "$ssh_host" ]; then
        echo -e "${COLOR_RED}Error: SSH user and host required${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    # Validate port
    if ! validate_port_number "$ssh_port"; then
        return $EXIT_INVALID_ARGS
    fi

    # Test SSH connection with 5 second timeout
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$ssh_port" \
        "$ssh_user@$ssh_host" "exit 0" >/dev/null 2>&1; then
        echo -e "${COLOR_RED}Error: Cannot connect to $ssh_user@$ssh_host:$ssh_port${COLOR_RESET}" >&2
        echo -e "${COLOR_YELLOW}Tip: Ensure SSH keys are configured and host is reachable${COLOR_RESET}" >&2
        return $EXIT_INVALID_HOST
    fi

    return $EXIT_SUCCESS
}

################################################################################
# ARRAY VALIDATION
################################################################################

# Function: validate_associative_array
# Description: Validates that a variable is a valid associative array
# Arguments:
#   $1 - array name (not the array itself)
# Returns: 0 if valid associative array, EXIT_INVALID_ARGS if not
# Output: Error message if validation fails
validate_associative_array() {
    local array_name="$1"

    if [ -z "$array_name" ]; then
        echo -e "${COLOR_RED}Error: Array name required${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    # Check if variable exists and is an array
    if ! declare -p "$array_name" >/dev/null 2>&1; then
        echo -e "${COLOR_RED}Error: Variable '$array_name' does not exist${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    # Check if it's an associative array
    local array_type
    array_type=$(declare -p "$array_name" 2>/dev/null | grep -o "declare -[aA]")
    if [[ "$array_type" != *"A"* ]]; then
        echo -e "${COLOR_RED}Error: Variable '$array_name' is not an associative array${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    return $EXIT_SUCCESS
}

################################################################################
# URL VALIDATION
################################################################################

# Function: validate_url
# Description: Validates URL format
# Arguments:
#   $1 - URL
# Returns: 0 if valid, EXIT_INVALID_ARGS if invalid
# Output: Error message if validation fails
validate_url() {
    local url="$1"

    if [ -z "$url" ]; then
        echo -e "${COLOR_RED}Error: URL cannot be empty${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    # Basic URL format check (http/https)
    if ! [[ "$url" =~ ^https?:// ]]; then
        echo -e "${COLOR_RED}Error: Invalid URL format (must start with http:// or https://)${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    return $EXIT_SUCCESS
}

################################################################################
# PATH VALIDATION
################################################################################

# Function: validate_absolute_path
# Description: Validates that a path is absolute (not relative)
# Arguments:
#   $1 - file path
# Returns: 0 if absolute, EXIT_INVALID_ARGS if relative
# Output: Error message if validation fails
validate_absolute_path() {
    local path="$1"

    if [ -z "$path" ]; then
        echo -e "${COLOR_RED}Error: Path cannot be empty${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    # Check if path starts with /
    if [[ "$path" != /* ]]; then
        echo -e "${COLOR_RED}Error: Path must be absolute (got '$path')${COLOR_RESET}" >&2
        echo -e "${COLOR_YELLOW}Tip: Absolute paths start with '/'${COLOR_RESET}" >&2
        return $EXIT_INVALID_ARGS
    fi

    return $EXIT_SUCCESS
}

################################################################################
# SECURITY CHECKS
################################################################################

# Function: check_command_injection
# Description: Checks input for potential command injection patterns
# Arguments:
#   $1 - input string
# Returns: 0 if safe, EXIT_SECURITY_VIOLATION if dangerous
# Output: Warning message if dangerous patterns detected
check_command_injection() {
    local input="$1"

    # Dangerous patterns
    local dangerous_patterns=(
        ";"
        "|"
        "&"
        "\$("
        "\`"
        ">"
        "<"
        "\n"
        "\r"
    )

    for pattern in "${dangerous_patterns[@]}"; do
        if [[ "$input" == *"$pattern"* ]]; then
            echo -e "${COLOR_RED}Security Error: Input contains dangerous pattern '$pattern'${COLOR_RESET}" >&2
            echo -e "${COLOR_YELLOW}Input: $input${COLOR_RESET}" >&2
            return $EXIT_SECURITY_VIOLATION
        fi
    done

    return $EXIT_SUCCESS
}

################################################################################
# UTILITY FUNCTIONS
################################################################################

# Function: print_command_install_help
# Description: Prints installation instructions for missing commands
# Arguments: None
# Returns: 0
# Output: Installation help text
print_command_install_help() {
    cat <<EOF
${COLOR_BLUE}Command Installation Help${COLOR_RESET}
${COLOR_BLUE}==========================${COLOR_RESET}

${COLOR_YELLOW}Docker${COLOR_RESET}:
  macOS: https://www.docker.com/products/docker-desktop
  Linux: sudo apt-get install docker.io
  Or via snap: sudo snap install docker

${COLOR_YELLOW}Docker Compose${COLOR_RESET}:
  macOS: brew install docker-compose
  Linux: sudo apt-get install docker-compose
  Or via pip: pip install docker-compose
  URL: https://docs.docker.com/compose/install/

${COLOR_YELLOW}SSH / SCP${COLOR_RESET}:
  Usually pre-installed on macOS and Linux
  macOS: brew install openssh
  Linux: sudo apt-get install openssh-client

${COLOR_YELLOW}yq${COLOR_RESET}:
  macOS: brew install yq
  Linux: sudo apt-get install yq
  URL: https://github.com/mikefarah/yq

${COLOR_YELLOW}timeout${COLOR_RESET}:
  Usually pre-installed (part of coreutils)
  macOS (GNU timeout): brew install coreutils
  Linux: sudo apt-get install coreutils

${COLOR_YELLOW}Other required commands${COLOR_RESET}:
  Most others (awk, sed, grep, jq, git, curl, nc) are typically pre-installed
  If missing, install via your system package manager

EOF
}

# Function: print_validation_help
# Description: Prints usage information for validation functions
# Arguments: None
# Returns: 0
# Output: Help text
print_validation_help() {
    cat <<EOF
${COLOR_BLUE}Portoser Validation Module${COLOR_RESET}
${COLOR_BLUE}==========================${COLOR_RESET}

Usage: source /tmp/agent4_validation.sh

Available Functions:
  validate_bash_version              - Check bash >= 4.0
  validate_required_commands         - Check all required commands
  validate_command_exists CMD        - Check specific command
  validate_docker_running            - Check Docker daemon

  validate_service_name NAME         - Validate service name format
  validate_host_name NAME            - Validate host name format
  validate_ip_address IP             - Validate IPv4 address
  validate_port_number PORT          - Validate port (1-65535, not 8000)

  check_file_exists PATH             - Check file exists and readable
  check_directory_exists PATH        - Check directory exists
  check_file_writable PATH           - Check file/directory writable

  validate_registry_file PATH        - Comprehensive registry validation
  validate_docker_compose_file PATH  - Validate docker-compose.yml
  validate_service_yml PATH          - Validate service.yml

  validate_environment               - Validate complete environment
  validate_environment_variable NAME - Check env var set

  sanitize_input INPUT               - Sanitize user input
  check_command_injection INPUT      - Check for injection attacks

  validate_ssh_connection USER HOST  - Test SSH connectivity
  validate_url URL                   - Validate URL format
  validate_absolute_path PATH        - Check path is absolute

  print_command_install_help         - Show command installation instructions

Exit Codes:
  0 - Success
  1 - Invalid arguments
  2 - Missing command
  3 - Invalid registry
  4 - Invalid service
  5 - Invalid host
  6 - File not found
  7 - Invalid environment
  8 - Security violation

EOF
}

# Export functions for use in other scripts
export -f validate_bash_version
export -f validate_command_exists
export -f validate_required_commands
export -f validate_docker_running
export -f sanitize_input
export -f validate_service_name
export -f validate_host_name
export -f validate_ip_address
export -f validate_port_number
export -f check_file_exists
export -f check_directory_exists
export -f check_file_writable
export -f validate_yaml_file
export -f validate_registry_file
export -f validate_docker_compose_file
export -f validate_registry_v3_service_paths
export -f validate_service_yml
export -f validate_environment_variable
export -f validate_environment
export -f validate_ssh_connection
export -f validate_associative_array
export -f validate_url
export -f validate_absolute_path
export -f check_command_injection
export -f print_command_install_help
export -f print_validation_help

# Export exit codes
export EXIT_SUCCESS EXIT_INVALID_ARGS EXIT_MISSING_COMMAND EXIT_INVALID_REGISTRY
export EXIT_INVALID_SERVICE EXIT_INVALID_HOST EXIT_FILE_NOT_FOUND EXIT_INVALID_ENV
export EXIT_SECURITY_VIOLATION

echo -e "${COLOR_GREEN}✓ Validation module loaded${COLOR_RESET}"
echo -e "${COLOR_BLUE}Run 'print_validation_help' for usage information${COLOR_RESET}"
