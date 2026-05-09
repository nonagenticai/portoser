#!/usr/bin/env bash
# command_check.sh - Command existence validation for portoser
#
# This library provides functions to check for required command availability
# at startup and provide helpful error messages if commands are missing.
#
# Functions:
#   - check_command_exists() - Check if a single command is available
#   - check_commands_exist() - Check if multiple commands are available
#   - check_required_commands() - Check a predefined list of required commands
#   - get_install_instructions() - Get installation instructions for a command

# Guard against multiple sourcing
[[ -n "${_COMMAND_CHECK_SH_LOADED:-}" ]] && return 0
readonly _COMMAND_CHECK_SH_LOADED=1

set -euo pipefail

# Source utils.sh if available
if [ -f "$(dirname "${BASH_SOURCE[0]}")/utils.sh" ]; then
    # shellcheck source=lib/utils.sh
    source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
fi

################################################################################
# Installation Instructions Database
################################################################################

# Get installation instructions for a specific command
# Args: $1 - command name
# Returns: installation instructions
# Usage: get_install_instructions "docker"
get_install_instructions() {
    local cmd="$1"

    case "$cmd" in
        docker)
            echo "Install Docker from: https://www.docker.com/products/docker-desktop"
            echo "Or via Homebrew (macOS): brew install docker"
            echo "Or via package manager (Linux): sudo apt-get install docker.io"
            ;;
        docker-compose)
            echo "Install Docker Compose from: https://docs.docker.com/compose/install/"
            echo "Or via Homebrew (macOS): brew install docker-compose"
            echo "Or via pip: pip install docker-compose"
            ;;
        ssh)
            echo "SSH is typically pre-installed on macOS and Linux"
            echo "For Windows, use WSL2 or Git Bash"
            ;;
        scp)
            echo "SCP comes with SSH. Install SSH first:"
            echo "macOS: brew install openssh"
            echo "Linux: sudo apt-get install openssh-client"
            ;;
        yq)
            echo "Install yq from: https://github.com/mikefarah/yq"
            echo "Or via Homebrew (macOS): brew install yq"
            echo "Or via package manager (Linux): sudo apt-get install yq"
            ;;
        awk)
            echo "AWK is typically pre-installed on macOS and Linux"
            echo "macOS: brew install gawk"
            echo "Linux: sudo apt-get install gawk"
            ;;
        sed)
            echo "SED is typically pre-installed on macOS and Linux"
            echo "macOS (GNU sed): brew install gnu-sed"
            echo "Linux: sudo apt-get install sed"
            ;;
        timeout)
            echo "Timeout utility is typically pre-installed"
            echo "macOS: brew install coreutils (for GNU timeout)"
            echo "Linux: sudo apt-get install coreutils"
            ;;
        *)
            echo "Please install $cmd"
            ;;
    esac
}

################################################################################
# Command Existence Check Functions
################################################################################

# Check if a single command exists
# Args: $1 - command name
#       $2 - error message (optional)
# Returns: 0 if command exists, 1 if not
# Usage: check_command_exists "docker" || exit 1
check_command_exists() {
    local cmd="$1"
    local msg="${2:-}"

    if ! command -v "$cmd" &> /dev/null; then
        if [ -z "$msg" ]; then
            msg="Error: Required command '$cmd' not found"
        fi

        print_color "red" "$msg"
        print_color "yellow" ""
        print_color "yellow" "$(get_install_instructions "$cmd")"
        print_color "yellow" ""
        return 1
    fi

    return 0
}

# Check if multiple commands exist
# Args: $@ - command names
# Returns: 0 if all commands exist, 1 if any missing
# Usage: check_commands_exist "docker" "docker-compose" "yq" || exit 1
check_commands_exist() {
    local missing_commands=()
    local cmd

    for cmd in "$@"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_commands+=("$cmd")
        fi
    done

    if [ ${#missing_commands[@]} -gt 0 ]; then
        print_color "red" "Error: The following required commands are not found:"
        print_color "yellow" ""

        for cmd in "${missing_commands[@]}"; do
            print_color "yellow" "  - $cmd"
            print_color "yellow" "    $(get_install_instructions "$cmd" | head -1)"
        done

        print_color "yellow" ""
        return 1
    fi

    return 0
}

# Check all required commands for portoser
# This is the main entry point for command validation
# Returns: 0 if all required commands exist, 1 if any missing
# Usage: check_required_commands || exit 1
check_required_commands() {
    local all_commands=(
        "docker"
        "docker-compose"
        "ssh"
        "scp"
        "yq"
        "awk"
        "sed"
        "timeout"
    )

    print_if_not_json "blue" "Checking for required commands..."
    print_if_not_json "blue" ""

    local found_all=true
    local cmd

    for cmd in "${all_commands[@]}"; do
        if command -v "$cmd" &> /dev/null; then
            local version=""
            case "$cmd" in
                docker)
                    version=$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')
                    ;;
                docker-compose)
                    version=$(docker-compose --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')
                    ;;
                yq)
                    version=$(yq --version 2>/dev/null | awk '{print $NF}')
                    ;;
                *)
                    version=$(command -v "$cmd" | cut -d' ' -f1)
                    ;;
            esac

            local version_label=""
            [ -n "$version" ] && version_label="($version)"
            print_if_not_json "green" "  ✓ $cmd" "$version_label"
        else
            print_if_not_json "red" "  ✗ $cmd (MISSING)"
            found_all=false
        fi
    done

    print_if_not_json "blue" ""

    if [ "$found_all" = false ]; then
        print_color "red" "Error: Some required commands are missing!"
        print_color "yellow" "Please install the missing commands listed above and try again."
        return 1
    fi

    print_if_not_json "green" "All required commands are available!"
    print_if_not_json "blue" ""

    return 0
}

################################################################################
# Export all functions
################################################################################

export -f get_install_instructions
export -f check_command_exists
export -f check_commands_exist
export -f check_required_commands
