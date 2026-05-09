#!/usr/bin/env bash
################################################################################
# Base Command Framework for portoser
#
# This file provides the base infrastructure for modular command extraction.
# All extracted commands should be sourced from this directory.
#
# Usage:
#   source "$SCRIPT_DIR/lib/commands/base.sh"
#   call_command "deploy" "$@"
################################################################################

set -euo pipefail

# Get the directory where commands are located
COMMANDS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

################################################################################
# Command Registry and Loader
################################################################################

# Associative array to track loaded commands
declare -A COMMANDS_LOADED

# List of available commands (for help/discovery)
declare -a COMMANDS_AVAILABLE=(
    "deploy"
    "start"
    "stop"
    "status"
    "health"
    "verify"
    "databases"
    "repos"
    "docker"
    "network"
    "dns"
    "caddy"
    "certs"
    "cluster"
    "keycloak"
    "vault"
    "registry"
    "remote"
    "diagnose"
    "learn"
    "history"
    "dependencies"
    "metrics"
    "uptime"
    "local"
    "move"
)

################################################################################
# Command Loading Functions
################################################################################

# Load a specific command module
# Usage: load_command "deploy"
load_command() {
    local command="$1"
    local cmd_file="$COMMANDS_DIR/${command}.sh"

    if [ "${COMMANDS_LOADED[$command]:-0}" = "1" ]; then
        return 0
    fi

    if [ ! -f "$cmd_file" ]; then
        print_color "$RED" "Error: Command module not found: $cmd_file"
        return 1
    fi

    # Source the command file
    # shellcheck source=/dev/null
    source "$cmd_file"
    COMMANDS_LOADED[$command]=1

    [ "$DEBUG" = "1" ] && print_color "$BLUE" "Debug: Loaded command module: $command"
    return 0
}

# Check if a command is available
# Usage: is_command_available "deploy"
is_command_available() {
    local command="$1"
    local cmd_file="$COMMANDS_DIR/${command}.sh"
    [ -f "$cmd_file" ]
}

# Get list of all available commands
# Usage: get_available_commands
get_available_commands() {
    printf '%s\n' "${COMMANDS_AVAILABLE[@]}"
}

# Get help for a specific command
# Usage: get_command_help "deploy"
get_command_help() {
    local command="$1"
    local cmd_file="$COMMANDS_DIR/${command}.sh"

    if [ ! -f "$cmd_file" ]; then
        print_color "$RED" "No help available for command: $command"
        return 1
    fi

    # Look for a help function in the command file
    local help_func="${command}_help"

    if declare -f "$help_func" > /dev/null 2>&1; then
        "$help_func"
    else
        print_color "$YELLOW" "No help function defined for: $command"
    fi
}

################################################################################
# Command Dispatcher
################################################################################

# Call a command module (lazy loading)
# Usage: call_command "deploy" "$@"
call_command() {
    local command="$1"
    shift || true

    # Validate command
    if ! is_command_available "$command"; then
        print_color "$RED" "Error: Unknown command '$command'"
        return 1
    fi

    # Load command if not already loaded
    if ! load_command "$command"; then
        return 1
    fi

    # Call the command handler function
    local cmd_func="cmd_${command}"
    if ! declare -f "$cmd_func" > /dev/null 2>&1; then
        print_color "$RED" "Error: Command handler function not found: $cmd_func"
        return 1
    fi

    # Execute the command
    "$cmd_func" "$@"
}

################################################################################
# Command Template
################################################################################

# Template for new command modules
#
# Each command module should:
# 1. Define cmd_<command>() function as the main entry point
# 2. Define <command>_help() function for help output (optional)
# 3. Use local variables to avoid polluting global scope
# 4. Source required library files at the top
# 5. Keep the module under 500 lines

# Example structure:
# #!/usr/bin/env bash
#
# # Deploy command - Deploy services to target machines
# # Usage: portoser deploy MACHINE SERVICE [SERVICE...] [OPTIONS]
#
# cmd_deploy() {
#     # Parse and validate arguments
#     # Execute deployment logic (delegating to lib functions)
#     # Return status code
# }
#
# deploy_help() {
#     echo "Usage: portoser deploy MACHINE SERVICE [SERVICE...] [OPTIONS]"
#     echo ""
#     echo "Deploy services to target machines."
#     # ... help text
# }

################################################################################
# Global Helper Functions (available to all commands)
################################################################################

# Validate a registry file
# Sourced from main portoser script
validate_registry() {
    if ! command -v validate_registry > /dev/null 2>&1; then
        # Function not yet loaded, return true (will be validated by main)
        return 0
    fi
    validate_registry "$@"
}

# Print colored output (should be defined in main or utils)
if ! declare -f print_color > /dev/null 2>&1; then
    print_color() {
        local color="$1"
        shift
        echo -e "${color}$*${NC}"
    }
fi

# Color definitions (should be defined in main or utils). Public — sourcing
# scripts use $RED / $GREEN / $YELLOW / $BLUE / $NC in their own messages.
if [ -z "${RED:-}" ]; then
    RED='\033[0;31m'
    # shellcheck disable=SC2034 # public palette member
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
fi

################################################################################
# End of base.sh
################################################################################
