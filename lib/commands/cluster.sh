#!/usr/bin/env bash
################################################################################
# Cluster Command Module
#
# Cluster management and orchestration.
#
# Usage: portoser cluster <subcommand> [options]
################################################################################

set -euo pipefail

# Cluster command handler (dispatches to lib/cluster/* functions)
cmd_cluster() {
    # Delegate to existing cluster library functions
    if declare -f cluster_main > /dev/null 2>&1; then
        cluster_main "$@"
    else
        print_color "$RED" "Error: Cluster functions not available"
        exit 1
    fi
}

################################################################################
# End of cluster.sh
################################################################################
