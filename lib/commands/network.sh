#!/usr/bin/env bash
################################################################################
# Network Command Module
#
# Network migration operations for updating machine IPs.
#
# Usage: portoser network <subcommand> [options]
################################################################################

set -euo pipefail

# Network command handler
cmd_network() {
    if [ $# -eq 0 ]; then
        network_help
        exit 1
    fi

    local subcommand="$1"
    shift

    case "$subcommand" in
        -h|--help)
            network_help
            exit 0
            ;;
        update-ips)
            if [ $# -lt 2 ]; then
                echo "Usage: portoser network update-ips MACHINE IP [MACHINE IP ...]"
                exit 1
            fi
            update_machine_ips_in_registry "$@"
            ;;
        migrate)
            if [ $# -lt 2 ]; then
                echo "Usage: portoser network migrate MACHINE IP [MACHINE IP ...]"
                echo ""
                echo "Example for changing office locations:"
                echo "  portoser network migrate host-a 10.88.0.245 host-a 10.88.0.96 host-b 10.88.0.164"
                exit 1
            fi
            update_network_and_regenerate "$@"
            ;;
        *)
            print_color "$RED" "Error: Unknown network subcommand '$subcommand'"
            network_help
            exit 1
            ;;
    esac
}

# Help function for network command
network_help() {
    cat <<EOF
Usage: portoser network <subcommand> [options]

Network migration operations for updating machine IPs.

Subcommands:
  update-ips MACHINE IP ...   Update machine IPs in bulk
  migrate MACHINE IP ...      Full migration: update IPs + regenerate + reload

Examples:
  # Update IPs in registry
  portoser network update-ips host-a 10.88.0.245 host-a 10.88.0.96

  # Full migration (updates registry, regenerates Caddyfile, reloads Caddy)
  portoser network migrate host-a 10.88.0.245 host-a 10.88.0.96 host-b 10.88.0.164

EOF
}

################################################################################
# End of network.sh
################################################################################
