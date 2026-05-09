#!/bin/bash
# validation.sh - Input validation library for command injection prevention
# Part of Portoser security hardening initiative
# Created: 2025-12-08

# Guard against multiple sourcing
[[ -n "${_VALIDATION_SH_LOADED:-}" ]] && return 0
readonly _VALIDATION_SH_LOADED=1

set -euo pipefail

# Color codes are defined in lib/utils.sh (already loaded by main script)

# Validation patterns
readonly PATTERN_SERVICE_NAME='^[a-zA-Z0-9_-]+$'
readonly PATTERN_MACHINE_NAME='^[a-zA-Z0-9_-]+$'
readonly PATTERN_DBNAME='^[a-zA-Z0-9_-]+$'
readonly PATTERN_PORT='^[0-9]+$'
readonly PATTERN_IPV4='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
readonly PATTERN_SAFE_PATH='^[a-zA-Z0-9/_. -]+$'

# Maximum lengths to prevent buffer overflow
readonly MAX_SERVICE_NAME_LENGTH=64
readonly MAX_MACHINE_NAME_LENGTH=64
readonly MAX_DBNAME_LENGTH=64
readonly MAX_PATH_LENGTH=4096

#######################################
# Validate service name
# Globals:
#   None
# Arguments:
#   $1 - Service name to validate
# Returns:
#   0 if valid, 1 if invalid
# Outputs:
#   Error message to stderr if invalid
#######################################
validate_service_name() {
    local service_name="$1"

    # Check if empty
    if [[ -z "$service_name" ]]; then
        echo -e "${RED}ERROR: Service name cannot be empty${NC}" >&2
        return 1
    fi

    # Check length
    if [[ ${#service_name} -gt $MAX_SERVICE_NAME_LENGTH ]]; then
        echo -e "${RED}ERROR: Service name exceeds maximum length of ${MAX_SERVICE_NAME_LENGTH}${NC}" >&2
        return 1
    fi

    # Check pattern (alphanumeric, underscore, hyphen only)
    if ! [[ "$service_name" =~ $PATTERN_SERVICE_NAME ]]; then
        echo -e "${RED}ERROR: Invalid service name '$service_name'. Only alphanumeric, underscore, and hyphen allowed${NC}" >&2
        return 1
    fi

    return 0
}

#######################################
# Validate machine name
# Globals:
#   None
# Arguments:
#   $1 - Machine name to validate
# Returns:
#   0 if valid, 1 if invalid
# Outputs:
#   Error message to stderr if invalid
#######################################
validate_machine_name() {
    local machine_name="$1"

    # Check if empty
    if [[ -z "$machine_name" ]]; then
        echo -e "${RED}ERROR: Machine name cannot be empty${NC}" >&2
        return 1
    fi

    # Check length
    if [[ ${#machine_name} -gt $MAX_MACHINE_NAME_LENGTH ]]; then
        echo -e "${RED}ERROR: Machine name exceeds maximum length of ${MAX_MACHINE_NAME_LENGTH}${NC}" >&2
        return 1
    fi

    # Check pattern (alphanumeric, underscore, hyphen only)
    if ! [[ "$machine_name" =~ $PATTERN_MACHINE_NAME ]]; then
        echo -e "${RED}ERROR: Invalid machine name '$machine_name'. Only alphanumeric, underscore, and hyphen allowed${NC}" >&2
        return 1
    fi

    return 0
}

#######################################
# Validate port number
# Globals:
#   None
# Arguments:
#   $1 - Port number to validate
# Returns:
#   0 if valid, 1 if invalid
# Outputs:
#   Error message to stderr if invalid
#######################################
validate_port() {
    local port="$1"

    # Check if empty
    if [[ -z "$port" ]]; then
        echo -e "${RED}ERROR: Port number cannot be empty${NC}" >&2
        return 1
    fi

    # Check if numeric
    if ! [[ "$port" =~ $PATTERN_PORT ]]; then
        echo -e "${RED}ERROR: Invalid port '$port'. Must be numeric${NC}" >&2
        return 1
    fi

    # Check range (1-65535)
    if [[ $port -lt 1 || $port -gt 65535 ]]; then
        echo -e "${RED}ERROR: Port $port out of valid range (1-65535)${NC}" >&2
        return 1
    fi

    # Check against reserved port (per user instructions)
    if [[ $port -eq 8000 ]]; then
        echo -e "${RED}ERROR: Port 8000 is reserved and cannot be used${NC}" >&2
        return 1
    fi

    return 0
}

#######################################
# Validate IPv4 address
# Globals:
#   None
# Arguments:
#   $1 - IP address to validate
# Returns:
#   0 if valid, 1 if invalid
# Outputs:
#   Error message to stderr if invalid
#######################################
validate_ip() {
    local ip="$1"

    # Check if empty
    if [[ -z "$ip" ]]; then
        echo -e "${RED}ERROR: IP address cannot be empty${NC}" >&2
        return 1
    fi

    # Check basic pattern
    if ! [[ "$ip" =~ $PATTERN_IPV4 ]]; then
        echo -e "${RED}ERROR: Invalid IPv4 address format '$ip'${NC}" >&2
        return 1
    fi

    # Validate each octet is 0-255
    IFS='.' read -ra OCTETS <<< "$ip"
    for octet in "${OCTETS[@]}"; do
        if [[ $octet -lt 0 || $octet -gt 255 ]]; then
            echo -e "${RED}ERROR: Invalid IPv4 address '$ip'. Octet out of range (0-255)${NC}" >&2
            return 1
        fi
    done

    return 0
}

#######################################
# Validate database name
# Globals:
#   None
# Arguments:
#   $1 - Database name to validate
# Returns:
#   0 if valid, 1 if invalid
# Outputs:
#   Error message to stderr if invalid
#######################################
validate_dbname() {
    local dbname="$1"

    # Check if empty
    if [[ -z "$dbname" ]]; then
        echo -e "${RED}ERROR: Database name cannot be empty${NC}" >&2
        return 1
    fi

    # Check length
    if [[ ${#dbname} -gt $MAX_DBNAME_LENGTH ]]; then
        echo -e "${RED}ERROR: Database name exceeds maximum length of ${MAX_DBNAME_LENGTH}${NC}" >&2
        return 1
    fi

    # Check pattern (alphanumeric, underscore, hyphen only)
    if ! [[ "$dbname" =~ $PATTERN_DBNAME ]]; then
        echo -e "${RED}ERROR: Invalid database name '$dbname'. Only alphanumeric, underscore, and hyphen allowed${NC}" >&2
        return 1
    fi

    # Database-specific checks
    # Cannot start with a number (many databases don't allow this)
    if [[ "$dbname" =~ ^[0-9] ]]; then
        echo -e "${YELLOW}WARNING: Database name '$dbname' starts with a number, which may not be supported by all databases${NC}" >&2
    fi

    return 0
}

#######################################
# Validate file/directory path
# Prevents directory traversal attacks
# Globals:
#   None
# Arguments:
#   $1 - Path to validate
# Returns:
#   0 if valid, 1 if invalid
# Outputs:
#   Error message to stderr if invalid
#######################################
validate_path() {
    local path="$1"

    # Check if empty
    if [[ -z "$path" ]]; then
        echo -e "${RED}ERROR: Path cannot be empty${NC}" >&2
        return 1
    fi

    # Check length
    if [[ ${#path} -gt $MAX_PATH_LENGTH ]]; then
        echo -e "${RED}ERROR: Path exceeds maximum length of ${MAX_PATH_LENGTH}${NC}" >&2
        return 1
    fi

    # Check for directory traversal attempts
    if [[ "$path" == *".."* ]]; then
        echo -e "${RED}ERROR: Path contains directory traversal sequence '..'${NC}" >&2
        return 1
    fi

    # Check pattern (safe characters only) - this also prevents null bytes
    if ! [[ "$path" =~ $PATTERN_SAFE_PATH ]]; then
        echo -e "${RED}ERROR: Invalid path '$path'. Contains unsafe characters${NC}" >&2
        return 1
    fi

    return 0
}

#######################################
# Validate service and machine name combination
# Commonly used together in the codebase
# Globals:
#   None
# Arguments:
#   $1 - Service name
#   $2 - Machine name
# Returns:
#   0 if both valid, 1 if either invalid
# Outputs:
#   Error message to stderr if invalid
#######################################
validate_service_and_machine() {
    local service_name="$1"
    local machine_name="$2"

    local result=0

    if ! validate_service_name "$service_name"; then
        result=1
    fi

    if ! validate_machine_name "$machine_name"; then
        result=1
    fi

    return $result
}

#######################################
# Sanitize string for shell execution
# Uses printf %q for proper shell escaping
# Globals:
#   None
# Arguments:
#   $1 - String to sanitize
# Returns:
#   0 always
# Outputs:
#   Sanitized string to stdout
#######################################
sanitize_for_shell() {
    local input="$1"
    printf %q "$input"
}

#######################################
# Validate and sanitize environment variable name
# Globals:
#   None
# Arguments:
#   $1 - Environment variable name
# Returns:
#   0 if valid, 1 if invalid
# Outputs:
#   Error message to stderr if invalid
#######################################
validate_env_var_name() {
    local var_name="$1"

    # Check if empty
    if [[ -z "$var_name" ]]; then
        echo -e "${RED}ERROR: Environment variable name cannot be empty${NC}" >&2
        return 1
    fi

    # Must start with letter or underscore, contain only alphanumeric and underscore
    if ! [[ "$var_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        echo -e "${RED}ERROR: Invalid environment variable name '$var_name'${NC}" >&2
        return 1
    fi

    return 0
}

#######################################
# Validate Docker container/image name
# Globals:
#   None
# Arguments:
#   $1 - Container/image name
# Returns:
#   0 if valid, 1 if invalid
# Outputs:
#   Error message to stderr if invalid
#######################################
validate_docker_name() {
    local name="$1"

    # Check if empty
    if [[ -z "$name" ]]; then
        echo -e "${RED}ERROR: Docker name cannot be empty${NC}" >&2
        return 1
    fi

    # Docker names: lowercase letters, digits, hyphens, underscores, periods, slashes
    # Must not start with hyphen or period
    if ! [[ "$name" =~ ^[a-z0-9][a-z0-9_.-]*(/[a-z0-9][a-z0-9_.-]*)*$ ]]; then
        echo -e "${RED}ERROR: Invalid Docker name '$name'${NC}" >&2
        return 1
    fi

    return 0
}

#######################################
# Validate URL
# Globals:
#   None
# Arguments:
#   $1 - URL to validate
# Returns:
#   0 if valid, 1 if invalid
# Outputs:
#   Error message to stderr if invalid
#######################################
validate_url() {
    local url="$1"

    # Check if empty
    if [[ -z "$url" ]]; then
        echo -e "${RED}ERROR: URL cannot be empty${NC}" >&2
        return 1
    fi

    # Basic URL pattern (http/https)
    if ! [[ "$url" =~ ^https?://[a-zA-Z0-9][a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$ ]]; then
        echo -e "${RED}ERROR: Invalid URL format '$url'${NC}" >&2
        return 1
    fi

    return 0
}

#######################################
# Test all validation functions
# Used for unit testing
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   0 if all tests pass, 1 if any fail
# Outputs:
#   Test results
#######################################
run_validation_tests() {
    local tests_passed=0
    local tests_failed=0

    echo "Running validation library tests..."
    echo

    # Test validate_service_name
    echo "Testing validate_service_name..."
    if validate_service_name "my-service_123" 2>/dev/null; then
        echo -e "${GREEN}✓ Valid service name accepted${NC}"
        ((tests_passed++))
    else
        echo -e "${RED}✗ Valid service name rejected${NC}"
        ((tests_failed++))
    fi

    if ! validate_service_name "my service" 2>/dev/null; then
        echo -e "${GREEN}✓ Invalid service name (space) rejected${NC}"
        ((tests_passed++))
    else
        echo -e "${RED}✗ Invalid service name (space) accepted${NC}"
        ((tests_failed++))
    fi

    if ! validate_service_name "my;service" 2>/dev/null; then
        echo -e "${GREEN}✓ Command injection attempt (semicolon) rejected${NC}"
        ((tests_passed++))
    else
        echo -e "${RED}✗ Command injection attempt (semicolon) accepted${NC}"
        ((tests_failed++))
    fi

    # Test validate_port
    echo
    echo "Testing validate_port..."
    if validate_port "8080" 2>/dev/null; then
        echo -e "${GREEN}✓ Valid port accepted${NC}"
        ((tests_passed++))
    else
        echo -e "${RED}✗ Valid port rejected${NC}"
        ((tests_failed++))
    fi

    if ! validate_port "8000" 2>/dev/null; then
        echo -e "${GREEN}✓ Reserved port 8000 rejected${NC}"
        ((tests_passed++))
    else
        echo -e "${RED}✗ Reserved port 8000 accepted${NC}"
        ((tests_failed++))
    fi

    if ! validate_port "70000" 2>/dev/null; then
        echo -e "${GREEN}✓ Out-of-range port rejected${NC}"
        ((tests_passed++))
    else
        echo -e "${RED}✗ Out-of-range port accepted${NC}"
        ((tests_failed++))
    fi

    # Test validate_ip
    echo
    echo "Testing validate_ip..."
    if validate_ip "192.0.2.1" 2>/dev/null; then
        echo -e "${GREEN}✓ Valid IP accepted${NC}"
        ((tests_passed++))
    else
        echo -e "${RED}✗ Valid IP rejected${NC}"
        ((tests_failed++))
    fi

    if ! validate_ip "256.1.1.1" 2>/dev/null; then
        echo -e "${GREEN}✓ Invalid IP (out-of-range octet) rejected${NC}"
        ((tests_passed++))
    else
        echo -e "${RED}✗ Invalid IP (out-of-range octet) accepted${NC}"
        ((tests_failed++))
    fi

    # Test validate_dbname
    echo
    echo "Testing validate_dbname..."
    if validate_dbname "my_database-123" 2>/dev/null; then
        echo -e "${GREEN}✓ Valid database name accepted${NC}"
        ((tests_passed++))
    else
        echo -e "${RED}✗ Valid database name rejected${NC}"
        ((tests_failed++))
    fi

    if ! validate_dbname "my db" 2>/dev/null; then
        echo -e "${GREEN}✓ Invalid database name (space) rejected${NC}"
        ((tests_passed++))
    else
        echo -e "${RED}✗ Invalid database name (space) accepted${NC}"
        ((tests_failed++))
    fi

    # Test validate_path
    echo
    echo "Testing validate_path..."
    if validate_path "/usr/local/bin/script.sh" 2>/dev/null; then
        echo -e "${GREEN}✓ Valid path accepted${NC}"
        ((tests_passed++))
    else
        echo -e "${RED}✗ Valid path rejected${NC}"
        ((tests_failed++))
    fi

    if ! validate_path "/usr/../etc/passwd" 2>/dev/null; then
        echo -e "${GREEN}✓ Directory traversal attack rejected${NC}"
        ((tests_passed++))
    else
        echo -e "${RED}✗ Directory traversal attack accepted${NC}"
        ((tests_failed++))
    fi

    # Test sanitize_for_shell
    echo
    echo "Testing sanitize_for_shell..."
    local sanitized
    sanitized=$(sanitize_for_shell "test; rm -rf /")
    if [[ "$sanitized" == *"\\"* ]]; then
        echo -e "${GREEN}✓ Shell injection attempt properly escaped${NC}"
        ((tests_passed++))
    else
        echo -e "${RED}✗ Shell injection attempt not properly escaped${NC}"
        ((tests_failed++))
    fi

    # Summary
    echo
    echo "========================================="
    echo -e "Tests passed: ${GREEN}${tests_passed}${NC}"
    echo -e "Tests failed: ${RED}${tests_failed}${NC}"
    echo "========================================="

    if [[ $tests_failed -eq 0 ]]; then
        echo -e "${GREEN}All validation tests passed!${NC}"
        return 0
    else
        echo -e "${RED}Some validation tests failed!${NC}"
        return 1
    fi
}

# If script is run directly, run tests
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_validation_tests
fi
