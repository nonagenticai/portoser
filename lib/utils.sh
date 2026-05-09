#!/usr/bin/env bash
# utils.sh - Shared utility functions for portoser
#
# This library provides common utility functions used across multiple
# portoser library files, reducing code duplication and improving maintainability.
#
# Functions:
#   - print_color() - Print colored messages
#   - print_if_not_json() - Conditional printing for JSON mode
#   - echo_if_not_json() - Conditional echo for JSON mode
#   - validate_required() - Validate required parameters
#   - validate_required_multi() - Validate multiple required parameters
#   - parse_host_user() - Extract user from host string
#   - parse_host_ip() - Extract IP from host string
#   - parse_host() - Parse both user and IP from host string
#   - check_dir_exists() - Check if directory exists
#   - check_file_exists() - Check if file exists
#   - check_path_exists() - Check if path exists
#   - print_operation_summary() - Print operation summary

# Guard against multiple sourcing
[[ -n "${_UTILS_SH_LOADED:-}" ]] && return 0
readonly _UTILS_SH_LOADED=1

set -euo pipefail

################################################################################
# Color Constants
################################################################################

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

################################################################################
# String Constants
################################################################################

# Public constants exported by lib/utils.sh; consumed by sourcing scripts
# (and by tests/lib/test_utils.sh, which asserts their presence).
# shellcheck disable=SC2034 # public API surface
readonly ERROR_PREFIX="Error:"
# shellcheck disable=SC2034
readonly WARNING_PREFIX="Warning:"
readonly SEPARATOR_LINE="======================================"
# shellcheck disable=SC2034
readonly STATUS_SUCCESS="✓"
# shellcheck disable=SC2034
readonly STATUS_FAILURE="✗"
# shellcheck disable=SC2034
readonly STATUS_WARNING="⚠"
# shellcheck disable=SC2034
readonly STATUS_SKIP="⊘"

################################################################################
# Color Printing Functions
################################################################################

# Print colored message
# Args: $1 - color name (red, green, yellow, blue)
#       $2 - message
# Usage: print_color "red" "Error message"
print_color() {
    local color="$1"
    local message="$2"

    # Empty messages produce no output (caller intent: nothing to print).
    [ -z "$message" ] && return 0

    case "$color" in
        red)    echo -e "${RED}${message}${NC}" ;;
        green)  echo -e "${GREEN}${message}${NC}" ;;
        yellow) echo -e "${YELLOW}${message}${NC}" ;;
        blue)   echo -e "${BLUE}${message}${NC}" ;;
        *)      echo "$message" ;;
    esac
}

# Print colored message only if not in JSON mode
# Args: $1 - color name
#       $2 - message
# Usage: print_if_not_json "blue" "Processing..."
print_if_not_json() {
    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        print_color "$1" "$2"
    fi
}

# Print plain message only if not in JSON mode
# Args: $1 - message
# Usage: echo_if_not_json "Processing complete"
echo_if_not_json() {
    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo "$1"
    fi
}

################################################################################
# Parameter Validation Functions
################################################################################

# Validate required parameter
# Args: $1 - parameter value
#       $2 - parameter name
#       $3 - error message (optional)
# Returns: 0 if valid, 1 if empty
# Usage: validate_required "$var" "var" "Error: var is required" || return 1
validate_required() {
    local value="$1"
    local name="$2"
    local msg="${3:-Error: $name is required}"

    if [ -z "$value" ]; then
        echo "$msg" >&2
        return 1
    fi
    return 0
}

# Validate multiple required parameters
# Args: pairs of "value" "name"
# Returns: 0 if all valid, 1 if any empty
# Usage: validate_required_multi "$var1" "var1" "$var2" "var2" || return 1
validate_required_multi() {
    while [ $# -ge 2 ]; do
        local value="$1"
        local name="$2"
        if ! validate_required "$value" "$name"; then
            return 1
        fi
        shift 2
    done
    return 0
}

################################################################################
# Host Parsing Functions
################################################################################

# Parse user from SSH host string
# Args: $1 - host string (user@ip)
# Returns: user portion
# Usage: user=$(parse_host_user "user@host.example.local")
parse_host_user() {
    local host="$1"
    echo "$host" | cut -d@ -f1
}

# Parse IP from SSH host string
# Args: $1 - host string (user@ip)
# Returns: IP portion
# Usage: ip=$(parse_host_ip "user@host.example.local")
parse_host_ip() {
    local host="$1"
    echo "$host" | cut -d@ -f2
}

# Parse both user and IP from SSH host string
# Args: $1 - host string (user@ip)
# Returns: user and IP separated by space
# Usage: read user ip < <(parse_host "user@host.example.local")
parse_host() {
    local host="$1"
    local user
    user=$(echo "$host" | cut -d@ -f1)
    local ip
    ip=$(echo "$host" | cut -d@ -f2)
    echo "$user $ip"
}

################################################################################
# Path Existence Check Functions
################################################################################

# Check if directory exists
# Args: $1 - directory path
#       $2 - error message (optional)
# Returns: 0 if exists, 1 if not
# Usage: check_dir_exists "$dir" || return 1
check_dir_exists() {
    local dir="$1"
    local msg="${2:-Error: Directory not found: $dir}"

    if [ ! -d "$dir" ]; then
        print_color "red" "$msg"
        return 1
    fi
    return 0
}

# Check if file exists
# Args: $1 - file path
#       $2 - error message (optional)
# Returns: 0 if exists, 1 if not
# Usage: check_file_exists "$file" || return 1
check_file_exists() {
    local file="$1"
    local msg="${2:-Error: File not found: $file}"

    if [ ! -f "$file" ]; then
        print_color "red" "$msg"
        return 1
    fi
    return 0
}

# Check if path exists (file or directory)
# Args: $1 - path
#       $2 - error message (optional)
# Returns: 0 if exists, 1 if not
# Usage: check_path_exists "$path" || return 1
check_path_exists() {
    local path="$1"
    local msg="${2:-Error: Path not found: $path}"

    if [ ! -e "$path" ]; then
        print_color "red" "$msg"
        return 1
    fi
    return 0
}

################################################################################
# Summary Printing Functions
################################################################################

# Print operation summary
# Args: $1 - success count
#       $2 - skipped count (optional, default 0)
#       $3 - error count (optional, default 0)
# Usage: print_operation_summary 10 2 1
print_operation_summary() {
    local success="${1:-0}"
    local skipped="${2:-0}"
    local error="${3:-0}"

    echo ""
    print_color "blue" "$SEPARATOR_LINE"
    print_color "blue" "Summary"
    print_color "blue" "$SEPARATOR_LINE"
    print_color "green" "Success: $success"

    if [ "$skipped" -gt 0 ]; then
        print_color "yellow" "Skipped: $skipped"
    fi

    if [ "$error" -gt 0 ]; then
        print_color "red" "Errors: $error"
    fi

    echo ""
    print_color "blue" "Total: $((success + skipped + error))"
}

################################################################################
# Export all functions
################################################################################

export -f print_color
export -f print_if_not_json
export -f echo_if_not_json
export -f validate_required
export -f validate_required_multi
export -f parse_host_user
export -f parse_host_ip
export -f parse_host
export -f check_dir_exists
export -f check_file_exists
export -f check_path_exists
export -f print_operation_summary
