#!/usr/bin/env bash
################################################################################
# Repos Command Module
#
# Repository management and synchronization commands.
#
# Usage: portoser repos <subcommand> [options]
################################################################################

set -euo pipefail

# Show help for repos command
show_repos_help() {
    cat <<EOF
Usage: portoser repos <subcommand> [OPTIONS]

Repository management and synchronization commands.

Subcommands:
  commit <message>     Commit changes across all service repositories
                       Options:
                         --push     Also push changes to remote
                         --dry-run  Show what would happen without executing
  status [--all]       Show status of all repositories
                       Options:
                         --all      Show detailed status including changes

Examples:
  portoser repos status
  portoser repos status --all
  portoser repos commit "Fix bug in service"
  portoser repos commit "Update dependencies" --push
  portoser repos commit "WIP" --dry-run

EOF
}

# Main repos command function
cmd_repos() {
    if [ $# -eq 0 ]; then
        show_repos_help
        exit 1
    fi

    local subcommand="$1"
    shift

    case "$subcommand" in
        -h|--help|help)
            show_repos_help
            exit 0
            ;;
        commit)
            if [ $# -eq 0 ]; then
                print_color "$RED" "Error: Commit message required"
                echo ""
                echo "Usage: portoser repos commit <message> [--push] [--dry-run]"
                exit 1
            fi
            perform_git_commit "$@"
            exit $?
            ;;
        status)
            show_repos_status "$@"
            exit $?
            ;;
        *)
            print_color "$RED" "Error: Unknown repos subcommand '$subcommand'"
            echo ""
            show_repos_help
            exit 1
            ;;
    esac
}

################################################################################
# End of repos.sh
################################################################################
