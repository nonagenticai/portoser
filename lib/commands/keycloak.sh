#!/usr/bin/env bash
################################################################################
# Keycloak Command Module
#
# Keycloak identity and access management.
#
# Usage: portoser keycloak <subcommand> [options]
################################################################################

set -euo pipefail

# Keycloak command handler (dispatches to lib/keycloak.sh functions)
cmd_keycloak() {
    # Delegate to existing keycloak library functions
    if declare -f keycloak_main > /dev/null 2>&1; then
        keycloak_main "$@"
    else
        print_color "$RED" "Error: Keycloak functions not available"
        exit 1
    fi
}

################################################################################
# End of keycloak.sh
################################################################################
