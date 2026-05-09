#!/usr/bin/env bash
################################################################################
# DNS Command Module
#
# DNS management and configuration commands.
#
# Usage: portoser dns <subcommand> [options]
################################################################################

set -euo pipefail

# DNS command handler (dispatches to lib/dns.sh functions)
cmd_dns() {
    # Delegate to existing dns library functions
    if declare -f dns_main > /dev/null 2>&1; then
        dns_main "$@"
    else
        print_color "$RED" "Error: DNS functions not available"
        exit 1
    fi
}

################################################################################
# End of dns.sh
################################################################################
