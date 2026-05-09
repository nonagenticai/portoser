#!/usr/bin/env bash
################################################################################
# Caddy Command Module
#
# Caddy reverse proxy management and configuration.
#
# Usage: portoser caddy <subcommand> [options]
################################################################################

set -euo pipefail

# Caddy command handler
cmd_caddy() {
    if [ $# -eq 0 ]; then
        caddy_help
        exit 1
    fi

    local subcommand="$1"
    shift

    case "$subcommand" in
        -h|--help)
            caddy_help
            exit 0
            ;;
        update)
            if [ $# -eq 0 ]; then
                echo "Usage: portoser caddy update SERVICE"
                exit 1
            fi
            update_caddy_route "$1"
            ;;
        reload)
            reload_caddyfile
            ;;
        validate)
            validate_caddyfile
            ;;
        regenerate)
            if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
                cat <<EOF
Usage: portoser caddy regenerate

Regenerates the Caddyfile from registry.yml and saves it to the configured path.

Creates a timestamped backup of the existing file (if present), then validates
the generated config with 'caddy validate' and formats it with 'caddy fmt'
before replacing the file.
EOF
                return 0
            fi
            local caddyfile="${CADDYFILE_PATH:-$(dirname "$SCRIPT_DIR")/caddy/Caddyfile}"
            save_caddyfile "$caddyfile"
            return $?
            ;;
        sync)
            print_color "$BLUE" "Syncing Caddy configuration from registry..."
            local caddyfile="${CADDYFILE_PATH:-$(dirname "$SCRIPT_DIR")/caddy/Caddyfile}"
            if save_caddyfile "$caddyfile"; then
                echo ""
                reload_caddyfile
            else
                print_color "$RED" "✗ Failed to regenerate Caddyfile"
                exit 1
            fi
            ;;
        proxy)
            if [ $# -eq 0 ]; then
                echo "Usage: portoser caddy proxy SERVICE"
                exit 1
            fi
            check_caddy_proxy "$1"
            ;;
        *)
            print_color "$RED" "Error: Unknown caddy subcommand '$subcommand'"
            caddy_help
            exit 1
            ;;
    esac
}

# Help function for caddy command
caddy_help() {
    cat <<EOF
Usage: portoser caddy <subcommand> [options]

Caddy reverse proxy management and configuration.

Subcommands:
  update SERVICE      Update Caddy routing for a service
  reload              Reload Caddy configuration from Caddyfile
  validate            Validate Caddyfile syntax
  regenerate          Regenerate Caddyfile from registry.yml
  sync                Regenerate from registry and reload (regenerate + reload)
  proxy SERVICE       Test Caddy proxy for a service

Examples:
  portoser caddy sync              # Update Caddy from registry
  portoser caddy update myservice        # Update routing for myservice service
  portoser caddy validate          # Check Caddyfile syntax

EOF
}

################################################################################
# End of caddy.sh
################################################################################
