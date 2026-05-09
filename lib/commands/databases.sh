#!/usr/bin/env bash
################################################################################
# Databases Command Module
#
# Database management and synchronization commands.
#
# Usage: portoser databases <subcommand> [options]
################################################################################

set -euo pipefail

# Show help for databases command
show_databases_help() {
    cat <<EOF
Usage: portoser databases <subcommand> [OPTIONS]

Database management and synchronization commands.

Subcommands:
  switch <prod|test|status>  Switch database mode or show status
  status [--json-output]     Show database status
  sync [options]             Sync databases between environments
  setup-test [options]       Setup test database environment

Database Mode:
  prod, production           Use production database
  test                       Use test database
  status                     Show current database mode

Sync Options:
  --source SRC               Source database server (default: production)
  --target TGT               Target database server (default: test)
  --dry-run                  Show what would be copied without executing

Setup Options:
  --host MACHINE             Target machine for test setup (default: host-b)

Examples:
  portoser databases status
  portoser databases switch prod
  portoser databases switch test
  portoser databases sync --dry-run
  portoser databases sync --source production --target test
  portoser databases setup-test --host host-b

EOF
}

# Main databases command function
cmd_databases() {
    local subcommand="${1:-}"
    shift || true

    case "$subcommand" in
        switch)
            # Parse mode argument
            local mode="${1:-status}"
            shift || true

            # Validate mode
            case "$mode" in
                prod|production)
                    mode="production"
                    ;;
                test)
                    mode="test"
                    ;;
                status)
                    mode="status"
                    ;;
                *)
                    print_color "$RED" "Error: Invalid mode '$mode'"
                    echo "Valid modes: prod, test, status"
                    echo ""
                    echo "Usage: portoser databases switch <prod|test|status>"
                    exit 1
                    ;;
            esac

            # Call library function
            switch_database_mode "$mode"
            exit $?
            ;;

        status)
            # Parse arguments
            local json_output=false

            while [ $# -gt 0 ]; do
                case "$1" in
                    --json-output|--json)
                        json_output=true
                        shift
                        ;;
                    -*)
                        print_color "$RED" "Error: Unknown option: $1"
                        echo "Usage: portoser databases status [--json-output]"
                        exit 1
                        ;;
                    *)
                        print_color "$RED" "Error: Unexpected argument: $1"
                        echo "Usage: portoser databases status [--json-output]"
                        exit 1
                        ;;
                esac
            done

            # Call library function
            if [ "$json_output" = true ]; then
                show_database_status --json
                exit $?
            else
                show_database_status
                exit $?
            fi
            ;;

        sync)
            # Parse arguments
            local source=""
            local target=""
            local dry_run=false

            while [ $# -gt 0 ]; do
                case "$1" in
                    --source)
                        if [ -z "${2:-}" ]; then
                            print_color "$RED" "Error: --source requires a value"
                            exit 1
                        fi
                        source="$2"
                        shift 2
                        ;;
                    --target)
                        if [ -z "${2:-}" ]; then
                            print_color "$RED" "Error: --target requires a value"
                            exit 1
                        fi
                        target="$2"
                        shift 2
                        ;;
                    --dry-run)
                        dry_run=true
                        shift
                        ;;
                    -h|--help)
                        echo "Usage: portoser databases sync [--source SRC] [--target TGT] [--dry-run]"
                        echo ""
                        echo "Sync databases between environments"
                        echo ""
                        echo "Options:"
                        echo "  --source SRC     Source database server (default: production)"
                        echo "  --target TGT     Target database server (default: test)"
                        echo "  --dry-run        Show what would be copied without executing"
                        exit 0
                        ;;
                    -*)
                        print_color "$RED" "Error: Unknown option: $1"
                        echo "Usage: portoser databases sync [--source SRC] [--target TGT] [--dry-run]"
                        exit 1
                        ;;
                    *)
                        print_color "$RED" "Error: Unexpected argument: $1"
                        echo "Usage: portoser databases sync [--source SRC] [--target TGT] [--dry-run]"
                        exit 1
                        ;;
                esac
            done

            # Call library function
            sync_databases "$source" "$target" "$dry_run"
            exit $?
            ;;

        setup-test)
            # Parse arguments
            local target_host="host-b"

            while [ $# -gt 0 ]; do
                case "$1" in
                    --host)
                        if [ -z "${2:-}" ]; then
                            print_color "$RED" "Error: --host requires a value"
                            exit 1
                        fi
                        target_host="$2"
                        shift 2
                        ;;
                    -h|--help)
                        echo "Usage: portoser databases setup-test [--host MACHINE]"
                        echo ""
                        echo "Setup test database environment on specified host"
                        echo ""
                        echo "Options:"
                        echo "  --host MACHINE   Target machine for test setup (default: host-b)"
                        exit 0
                        ;;
                    -*)
                        print_color "$RED" "Error: Unknown option: $1"
                        echo "Usage: portoser databases setup-test [--host MACHINE]"
                        exit 1
                        ;;
                    *)
                        print_color "$RED" "Error: Unexpected argument: $1"
                        echo "Usage: portoser databases setup-test [--host MACHINE]"
                        exit 1
                        ;;
                esac
            done

            # Call library function
            setup_test_databases "$target_host"
            exit $?
            ;;

        -h|--help|help|"")
            show_databases_help
            exit 0
            ;;

        *)
            print_color "$RED" "Error: Unknown databases subcommand: $subcommand"
            echo ""
            show_databases_help
            exit 1
            ;;
    esac
}

################################################################################
# End of databases.sh
################################################################################
