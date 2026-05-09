#!/usr/bin/env bash
# security_validation.sh - Security validation functions for command injection prevention
#
# This library provides comprehensive input validation and sanitization functions
# to prevent command injection vulnerabilities across the portoser codebase.
#
# Functions:
#   - validate_safe_string() - Validate alphanumeric + safe chars
#   - validate_ip_address() - Validate IPv4/IPv6 addresses
#   - validate_hostname() - Validate hostname format
#   - validate_port() - Validate port numbers
#   - validate_path() - Validate file/directory paths
#   - validate_service_name() - Validate service names
#   - validate_url() - Validate URLs
#   - sanitize_for_shell() - Sanitize strings for shell usage
#   - validate_docker_tag() - Validate Docker image tags
#   - validate_environment_name() - Validate environment names
#
# Security Level: HIGH
# Created by: Alpha-4 (Command Injection Remediation Specialist)
# Date: 2025-12-08

# Guard against multiple sourcing
[[ -n "${_SECURITY_VALIDATION_SH_LOADED:-}" ]] && return 0
readonly _SECURITY_VALIDATION_SH_LOADED=1

set -euo pipefail

################################################################################
# Security Validation Constants
################################################################################

# Allowed characters for different contexts
readonly SAFE_CHARS_PATTERN='^[a-zA-Z0-9._-]+$'
readonly HOSTNAME_PATTERN='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'
readonly SERVICE_NAME_PATTERN='^[a-zA-Z0-9][a-zA-Z0-9_-]*$'
readonly DOCKER_TAG_PATTERN='^[a-zA-Z0-9][a-zA-Z0-9._-]*$'
readonly ENV_NAME_PATTERN='^[a-zA-Z0-9][a-zA-Z0-9_-]*$'

# Dangerous characters that can enable command injection.
# Public — referenced by sourcing scripts that compose ad-hoc validators.
# shellcheck disable=SC2034 # public allowlist consumed by sourcing scripts
readonly DANGEROUS_CHARS=';&|$`<>(){}[]!*?~^#'

################################################################################
# Core Validation Functions
################################################################################

# Validate safe string (alphanumeric + dots, dashes, underscores)
# Args: $1 - string to validate
#       $2 - parameter name (for error messages)
# Returns: 0 if valid, 1 if invalid
# Usage: validate_safe_string "$input" "service_name" || return 1
validate_safe_string() {
    local value="$1"
    local name="${2:-input}"

    if [ -z "$value" ]; then
        echo "Error: $name cannot be empty" >&2
        return 1
    fi

    if ! [[ "$value" =~ $SAFE_CHARS_PATTERN ]]; then
        echo "Error: $name contains invalid characters. Only alphanumeric, dots, dashes, and underscores allowed: $value" >&2
        return 1
    fi

    return 0
}

# Validate IPv4 address
# Args: $1 - IP address to validate
#       $2 - parameter name (optional)
# Returns: 0 if valid, 1 if invalid
# Usage: validate_ip_address "$ip" "host_ip" || return 1
validate_ip_address() {
    local ip="$1"
    local name="${2:-IP address}"

    if [ -z "$ip" ]; then
        echo "Error: $name cannot be empty" >&2
        return 1
    fi

    # IPv4 validation
    local ipv4_pattern='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    if [[ "$ip" =~ $ipv4_pattern ]]; then
        # Validate each octet is 0-255. Splitting on '.' is the whole point;
        # IPv4 addresses cannot contain glob characters, so $ip is safe to split.
        local IFS='.'
        # shellcheck disable=SC2206
        local -a octets=($ip)
        for octet in "${octets[@]}"; do
            if [ "$octet" -gt 255 ]; then
                echo "Error: Invalid $name - octet out of range: $ip" >&2
                return 1
            fi
        done
        return 0
    fi

    # IPv6 validation (basic)
    local ipv6_pattern='^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$'
    if [[ "$ip" =~ $ipv6_pattern ]]; then
        return 0
    fi

    echo "Error: Invalid $name format: $ip" >&2
    return 1
}

# Validate hostname
# Args: $1 - hostname to validate
#       $2 - parameter name (optional)
# Returns: 0 if valid, 1 if invalid
# Usage: validate_hostname "$host" "hostname" || return 1
validate_hostname() {
    local hostname="$1"
    local name="${2:-hostname}"

    if [ -z "$hostname" ]; then
        echo "Error: $name cannot be empty" >&2
        return 1
    fi

    # Check length (max 253 characters)
    if [ ${#hostname} -gt 253 ]; then
        echo "Error: $name too long (max 253 characters): $hostname" >&2
        return 1
    fi

    # Check format
    if ! [[ "$hostname" =~ $HOSTNAME_PATTERN ]]; then
        echo "Error: Invalid $name format: $hostname" >&2
        return 1
    fi

    return 0
}

# Validate port number
# Args: $1 - port number to validate
#       $2 - parameter name (optional)
# Returns: 0 if valid, 1 if invalid
# Usage: validate_port "$port" "service_port" || return 1
validate_port() {
    local port="$1"
    local name="${2:-port}"

    if [ -z "$port" ]; then
        echo "Error: $name cannot be empty" >&2
        return 1
    fi

    # Check if numeric
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "Error: $name must be numeric: $port" >&2
        return 1
    fi

    # Check range (1-65535)
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "Error: $name out of range (1-65535): $port" >&2
        return 1
    fi

    return 0
}

# Validate file/directory path
# Args: $1 - path to validate
#       $2 - parameter name (optional)
# Returns: 0 if valid, 1 if invalid
# Usage: validate_path "$path" "config_path" || return 1
validate_path() {
    local path="$1"
    local name="${2:-path}"

    if [ -z "$path" ]; then
        echo "Error: $name cannot be empty" >&2
        return 1
    fi

    # Check for command injection characters
    if [[ "$path" =~ [\;\&\|\$\`\<\>\(\)\{\}\[\]\!\*\?] ]]; then
        echo "Error: $name contains dangerous characters: $path" >&2
        return 1
    fi

    # Check for null bytes
    if [[ "$path" == *$'\0'* ]]; then
        echo "Error: $name contains null bytes" >&2
        return 1
    fi

    return 0
}

# Validate service name
# Args: $1 - service name to validate
#       $2 - parameter name (optional)
# Returns: 0 if valid, 1 if invalid
# Usage: validate_service_name "$service" "service_name" || return 1
validate_service_name() {
    local service="$1"
    local name="${2:-service name}"

    if [ -z "$service" ]; then
        echo "Error: $name cannot be empty" >&2
        return 1
    fi

    # Check format (alphanumeric, dash, underscore; must start with alphanumeric)
    if ! [[ "$service" =~ $SERVICE_NAME_PATTERN ]]; then
        echo "Error: Invalid $name format (must start with alphanumeric, can contain a-z, A-Z, 0-9, -, _): $service" >&2
        return 1
    fi

    # Check length (reasonable limit)
    if [ ${#service} -gt 100 ]; then
        echo "Error: $name too long (max 100 characters): $service" >&2
        return 1
    fi

    return 0
}

# Validate URL
# Args: $1 - URL to validate
#       $2 - parameter name (optional)
# Returns: 0 if valid, 1 if invalid
# Usage: validate_url "$url" "registry_url" || return 1
validate_url() {
    local url="$1"
    local name="${2:-URL}"

    if [ -z "$url" ]; then
        echo "Error: $name cannot be empty" >&2
        return 1
    fi

    # Basic URL pattern (http/https)
    local url_pattern='^https?://[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*(:[0-9]{1,5})?(/[a-zA-Z0-9._~:/?#\[\]@!$&'\''()*+,;=-]*)?$'

    if ! [[ "$url" =~ $url_pattern ]]; then
        echo "Error: Invalid $name format: $url" >&2
        return 1
    fi

    return 0
}

# Validate Docker image tag
# Args: $1 - tag to validate
#       $2 - parameter name (optional)
# Returns: 0 if valid, 1 if invalid
# Usage: validate_docker_tag "$tag" "image_tag" || return 1
validate_docker_tag() {
    local tag="$1"
    local name="${2:-Docker tag}"

    if [ -z "$tag" ]; then
        echo "Error: $name cannot be empty" >&2
        return 1
    fi

    # Check format (alphanumeric, dots, dashes, underscores; must start with alphanumeric)
    if ! [[ "$tag" =~ $DOCKER_TAG_PATTERN ]]; then
        echo "Error: Invalid $name format: $tag" >&2
        return 1
    fi

    # Check length (max 128 characters per Docker spec)
    if [ ${#tag} -gt 128 ]; then
        echo "Error: $name too long (max 128 characters): $tag" >&2
        return 1
    fi

    return 0
}

# Validate environment name
# Args: $1 - environment name to validate
#       $2 - parameter name (optional)
# Returns: 0 if valid, 1 if invalid
# Usage: validate_environment_name "$env" "environment" || return 1
validate_environment_name() {
    local env="$1"
    local name="${2:-environment name}"

    if [ -z "$env" ]; then
        echo "Error: $name cannot be empty" >&2
        return 1
    fi

    # Check format
    if ! [[ "$env" =~ $ENV_NAME_PATTERN ]]; then
        echo "Error: Invalid $name format: $env" >&2
        return 1
    fi

    # Check against common environment names
    local valid_envs="development|dev|staging|stage|production|prod|test|testing|qa|local"
    if ! [[ "$env" =~ ^($valid_envs)$ ]]; then
        echo "Warning: Unusual $name (expected: development, staging, production, etc.): $env" >&2
    fi

    return 0
}

################################################################################
# Sanitization Functions
################################################################################

# Sanitize string for safe shell usage
# Args: $1 - string to sanitize
# Returns: sanitized string (stdout)
# Usage: safe_value=$(sanitize_for_shell "$unsafe_value")
sanitize_for_shell() {
    local value="$1"

    # Remove all dangerous characters
    local sanitized="${value//[;|&\$\`<>(){}[\]!*?~^#]/}"

    # Also remove leading/trailing whitespace
    sanitized="${sanitized#"${sanitized%%[![:space:]]*}"}"
    sanitized="${sanitized%"${sanitized##*[![:space:]]}"}"

    echo "$sanitized"
}

################################################################################
# Compound Validation Functions
################################################################################

# Validate SSH host string (user@ip)
# Args: $1 - host string to validate
#       $2 - parameter name (optional)
# Returns: 0 if valid, 1 if invalid
# Usage: validate_ssh_host "$host" "remote_host" || return 1
validate_ssh_host() {
    local host="$1"
    local name="${2:-SSH host}"

    if [ -z "$host" ]; then
        echo "Error: $name cannot be empty" >&2
        return 1
    fi

    # Must contain @
    if [[ ! "$host" =~ @ ]]; then
        echo "Error: Invalid $name format (expected user@host): $host" >&2
        return 1
    fi

    # Extract user and IP/hostname
    local user="${host%%@*}"
    local host_part="${host##*@}"

    # Validate user
    if ! validate_safe_string "$user" "username"; then
        return 1
    fi

    # Validate host part (could be IP or hostname)
    if ! validate_ip_address "$host_part" "host" 2>/dev/null; then
        if ! validate_hostname "$host_part" "host"; then
            return 1
        fi
    fi

    return 0
}

# Validate Docker image reference (registry/image:tag)
# Args: $1 - image reference to validate
#       $2 - parameter name (optional)
# Returns: 0 if valid, 1 if invalid
# Usage: validate_docker_image "$image" "docker_image" || return 1
validate_docker_image() {
    local image="$1"
    local name="${2:-Docker image}"

    if [ -z "$image" ]; then
        echo "Error: $name cannot be empty" >&2
        return 1
    fi

    # Check for command injection characters
    if [[ "$image" =~ [\;\&\|\$\`\<\>\(\)\{\}\[\]\!] ]]; then
        echo "Error: $name contains dangerous characters: $image" >&2
        return 1
    fi

    # Basic format validation (simplified)
    local image_pattern='^[a-zA-Z0-9][a-zA-Z0-9._/-]*:[a-zA-Z0-9][a-zA-Z0-9._-]*$'
    if [[ "$image" =~ $image_pattern ]]; then
        return 0
    fi

    # Also allow without tag (will use :latest)
    image_pattern='^[a-zA-Z0-9][a-zA-Z0-9._/-]*$'
    if [[ "$image" =~ $image_pattern ]]; then
        return 0
    fi

    echo "Error: Invalid $name format: $image" >&2
    return 1
}

################################################################################
# Array Validation Functions
################################################################################

# Validate array of service names
# Args: $@ - service names to validate
# Returns: 0 if all valid, 1 if any invalid
# Usage: validate_service_names "${services[@]}" || return 1
validate_service_names() {
    local service
    for service in "$@"; do
        if ! validate_service_name "$service"; then
            return 1
        fi
    done
    return 0
}

# Validate array of IP addresses
# Args: $@ - IP addresses to validate
# Returns: 0 if all valid, 1 if any invalid
# Usage: validate_ip_addresses "${ips[@]}" || return 1
validate_ip_addresses() {
    local ip
    for ip in "$@"; do
        if ! validate_ip_address "$ip"; then
            return 1
        fi
    done
    return 0
}

################################################################################
# Utility Functions
################################################################################

# Check if string contains dangerous characters
# Args: $1 - string to check
# Returns: 0 if contains dangerous chars, 1 if safe
# Usage: if contains_dangerous_chars "$input"; then ... fi
contains_dangerous_chars() {
    local value="$1"
    [[ "$value" =~ [\;\&\|\$\`\<\>\(\)\{\}\[\]\!\*\?] ]]
}

# Check if path is absolute
# Args: $1 - path to check
# Returns: 0 if absolute, 1 if relative
# Usage: if is_absolute_path "$path"; then ... fi
is_absolute_path() {
    local path="$1"
    [[ "$path" =~ ^/ ]]
}

################################################################################
# Export all functions
################################################################################

export -f validate_safe_string
export -f validate_ip_address
export -f validate_hostname
export -f validate_port
export -f validate_path
export -f validate_service_name
export -f validate_url
export -f validate_docker_tag
export -f validate_environment_name
export -f sanitize_for_shell
export -f validate_ssh_host
export -f validate_docker_image
export -f validate_service_names
export -f validate_ip_addresses
export -f contains_dangerous_chars
export -f is_absolute_path
