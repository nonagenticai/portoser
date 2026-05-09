#!/usr/bin/env bash
################################################################################
# Verify Command Module
#
# Verification and health checking commands for services and configurations.
#
# Usage: portoser verify <subcommand> [options]
################################################################################

set -euo pipefail

# Show help for verify command
show_verify_help() {
    cat <<EOF
Usage: portoser verify <subcommand> [options]

Verification and health checking commands.

Subcommands:
  services               Verify all services are running correctly (default)

  postgres-passwords     Verify PostgreSQL passwords across services
                         Options:
                           --sync   Show passwords that would be synced (dry-run)
                           --fix    Actually sync passwords from DB to .env files

  all                    Run all verification checks
                         (services + postgres-passwords)

  help                   Show this help message

Examples:
  portoser verify
  portoser verify services
  portoser verify postgres-passwords
  portoser verify postgres-passwords --sync
  portoser verify postgres-passwords --fix
  portoser verify all
  portoser verify help

EOF
}

# Verify all services are running
verify_services() {
    local script_dir="${SCRIPT_DIR:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"

    # Check if verify-all-services.sh exists
    if [ -f "$script_dir/bin/verify-all-services.sh" ]; then
        print_color "$BLUE" "=== Verifying All Services ==="
        echo ""
        "$script_dir/bin/verify-all-services.sh"
        return $?
    else
        print_color "$RED" "Error: verify-all-services.sh not found"
        return 1
    fi
}

# Verify PostgreSQL passwords
verify_postgres_passwords() {
    local sync_mode=0
    local fix_mode=0

    # Parse flags
    for arg in "$@"; do
        case "$arg" in
            --sync)
                sync_mode=1
                ;;
            --fix)
                fix_mode=1
                sync_mode=1
                ;;
        esac
    done

    local script_dir="${SCRIPT_DIR:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"

    # Check if verify-postgres-passwords.sh exists
    if [ -f "$script_dir/bin/verify-postgres-passwords.sh" ]; then
        print_color "$BLUE" "=== Verifying PostgreSQL Passwords ==="
        echo ""

        local args=()
        if [ $sync_mode -eq 1 ]; then
            args+=("--sync")
        fi
        if [ $fix_mode -eq 1 ]; then
            args+=("--fix")
        fi

        "$script_dir/bin/verify-postgres-passwords.sh" "${args[@]}"
        return $?
    else
        print_color "$RED" "Error: verify-postgres-passwords.sh not found"
        return 1
    fi
}

# Run all verification checks
verify_all() {
    local services_status=0
    local postgres_status=0

    print_color "$BLUE" "=== Running All Verification Checks ==="
    echo ""

    # Run services verification
    if verify_services; then
        services_status=0
    else
        services_status=1
    fi

    echo ""
    echo "=================="
    echo ""

    # Run postgres passwords verification
    if verify_postgres_passwords; then
        postgres_status=0
    else
        postgres_status=1
    fi

    echo ""
    echo "=================="
    print_color "$BLUE" "=== All Verification Summary ==="

    if [ $services_status -eq 0 ]; then
        print_color "$GREEN" "✓ Services verification passed"
    else
        print_color "$RED" "✗ Services verification failed"
    fi

    if [ $postgres_status -eq 0 ]; then
        print_color "$GREEN" "✓ PostgreSQL passwords verification passed"
    else
        print_color "$RED" "✗ PostgreSQL passwords verification failed"
    fi

    echo ""

    if [ $services_status -ne 0 ] || [ $postgres_status -ne 0 ]; then
        return 1
    fi
    return 0
}

# Main verify command handler
cmd_verify() {
    if [ $# -eq 0 ]; then
        # Default: verify services only
        verify_services
        return $?
    fi

    local subcommand="$1"
    shift

    case "$subcommand" in
        -h|--help|help)
            show_verify_help
            exit 0
            ;;
        services)
            verify_services "$@"
            exit $?
            ;;
        postgres-passwords)
            verify_postgres_passwords "$@"
            exit $?
            ;;
        all)
            verify_all "$@"
            exit $?
            ;;
        *)
            print_color "$RED" "Error: Unknown verify subcommand '$subcommand'"
            echo ""
            show_verify_help
            exit 1
            ;;
    esac
}

################################################################################
# End of verify.sh
################################################################################
