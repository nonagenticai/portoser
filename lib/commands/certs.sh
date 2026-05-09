#!/usr/bin/env bash
################################################################################
# Certs Command Module
#
# SSL/TLS certificate management.
#
# Usage: portoser certs <subcommand> [options]
################################################################################

set -euo pipefail

# Certificates command handler (dispatches to lib/certificates.sh functions)
cmd_certs() {
    # Delegate to existing certificates library functions
    if declare -f certificates_main > /dev/null 2>&1; then
        certificates_main "$@"
    else
        print_color "$RED" "Error: Certificate functions not available"
        exit 1
    fi
}

################################################################################
# End of certs.sh
################################################################################
