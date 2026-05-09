#!/usr/bin/env bash
################################################################################
# Vault Command Module
#
# HashiCorp Vault secrets management.
#
# Usage: portoser vault <subcommand> [options]
################################################################################

set -euo pipefail

# Vault command handler (dispatches to lib/vault.sh functions)
cmd_vault() {
    # Delegate to existing vault library functions
    if declare -f vault_main > /dev/null 2>&1; then
        vault_main "$@"
    else
        print_color "$RED" "Error: Vault functions not available"
        exit 1
    fi
}

################################################################################
# End of vault.sh
################################################################################
