#!/usr/bin/env bash

#######################################
# SSH Host Key Management Utility
#######################################
# Manages SSH host keys for the cluster: list, clean, scan, verify,
# backup, and restore entries in ~/.ssh/known_hosts.
#
# Cluster hosts are read from your cluster.conf (the same file the rest of
# the cluster scripts use). Set CLUSTER_CONF=/path/to/cluster.conf to override
# the default.
#######################################

set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Configuration
readonly KNOWN_HOSTS_FILE="${HOME}/.ssh/known_hosts"
readonly BACKUP_DIR="${HOME}/.ssh/known_hosts_backups"

PORTOSER_ROOT="${PORTOSER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CLUSTER_CONF="${CLUSTER_CONF:-$PORTOSER_ROOT/cluster.conf}"

# Build CLUSTER_HOSTS_LIST as a flat array of "user@host" entries (and bare
# host entries) from the user's cluster.conf. Falls back to an empty list
# with a warning if the config is missing or malformed.
declare -a CLUSTER_HOSTS_LIST=()
if [[ -f "$CLUSTER_CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CLUSTER_CONF"
    if declare -p CLUSTER_HOSTS >/dev/null 2>&1; then
        for key in "${!CLUSTER_HOSTS[@]}"; do
            entry="${CLUSTER_HOSTS[$key]}"
            CLUSTER_HOSTS_LIST+=("$entry")
            # Also add the bare host portion (after @) so users can clean by IP/hostname
            CLUSTER_HOSTS_LIST+=("${entry#*@}")
        done
    fi
fi

#######################################
# Print functions
#######################################

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

#######################################
# Helper functions
#######################################

check_known_hosts() {
    if [[ ! -f "$KNOWN_HOSTS_FILE" ]]; then
        print_warning "known_hosts file does not exist: $KNOWN_HOSTS_FILE"
        return 1
    fi
    return 0
}

ensure_backup_dir() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR"
        print_info "Created backup directory: $BACKUP_DIR"
    fi
}

confirm_action() {
    local message="$1"
    echo -e "${YELLOW}$message${NC}"
    read -p "Continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Operation cancelled"
        return 1
    fi
    return 0
}

#######################################
# Main functions
#######################################

list_cluster_hosts() {
    print_header "Cluster Hosts in known_hosts"

    if ! check_known_hosts; then
        return 1
    fi

    local found=0
    for host in "${CLUSTER_HOSTS_LIST[@]}"; do
        # Extract hostname/IP without username
        local host_part="${host#*@}"

        if ssh-keygen -F "$host_part" > /dev/null 2>&1; then
            print_success "Found: $host"

            # Show key fingerprint
            local fingerprint
            fingerprint=$(ssh-keygen -l -F "$host_part" 2>/dev/null | grep -v "^#" | head -1)
            if [[ -n "$fingerprint" ]]; then
                echo -e "  ${BLUE}Fingerprint:${NC} $fingerprint"
            fi

            ((found++))
        else
            print_warning "Not found: $host"
        fi
    done

    echo ""
    print_info "Total cluster hosts found: $found/${#CLUSTER_HOSTS_LIST[@]}"

    # Show total entries in known_hosts
    if [[ -f "$KNOWN_HOSTS_FILE" ]]; then
        local total_entries
        total_entries=$(grep -cvE "^(#|$)" "$KNOWN_HOSTS_FILE")
        print_info "Total entries in known_hosts: $total_entries"
    fi
}

clean_host_keys() {
    local target_host="$1"

    print_header "Clean Host Keys"

    if ! check_known_hosts; then
        return 1
    fi

    if [[ -z "$target_host" ]]; then
        # Clean all cluster hosts
        if ! confirm_action "This will remove all cluster host keys from known_hosts."; then
            return 1
        fi

        # Backup first
        backup_known_hosts "pre-clean-all"

        local cleaned=0
        for host in "${CLUSTER_HOSTS_LIST[@]}"; do
            local host_part="${host#*@}"
            if ssh-keygen -R "$host_part" > /dev/null 2>&1; then
                print_success "Removed: $host"
                ((cleaned++))
            fi
        done

        print_info "Cleaned $cleaned host keys"
    else
        # Clean specific host
        local host_part="${target_host#*@}"

        if ! confirm_action "This will remove host key for: $target_host"; then
            return 1
        fi

        # Backup first
        backup_known_hosts "pre-clean-${host_part}"

        if ssh-keygen -R "$host_part" > /dev/null 2>&1; then
            print_success "Removed host key for: $target_host"
        else
            print_warning "No host key found for: $target_host"
        fi
    fi
}

scan_host_keys() {
    local target_host="$1"

    print_header "Scan and Add Host Keys"

    if [[ -z "$target_host" ]]; then
        # Scan all cluster hosts
        print_info "Scanning all cluster hosts..."

        local scanned=0
        local failed=0

        for host in "${CLUSTER_HOSTS_LIST[@]}"; do
            local host_part="${host#*@}"

            print_info "Scanning: $host..."

            # Try to scan the host
            if timeout 10 ssh-keyscan -H "$host_part" >> "$KNOWN_HOSTS_FILE" 2>/dev/null; then
                print_success "Added: $host"
                ((scanned++))
            else
                print_error "Failed to scan: $host (timeout or unreachable)"
                ((failed++))
            fi
        done

        echo ""
        print_info "Successfully scanned: $scanned"
        if [[ $failed -gt 0 ]]; then
            print_warning "Failed to scan: $failed"
        fi
    else
        # Scan specific host
        local host_part="${target_host#*@}"

        print_info "Scanning: $target_host..."

        if timeout 10 ssh-keyscan -H "$host_part" >> "$KNOWN_HOSTS_FILE" 2>/dev/null; then
            print_success "Added host key for: $target_host"

            # Show fingerprint
            local fingerprint
            fingerprint=$(ssh-keygen -l -F "$host_part" 2>/dev/null | grep -v "^#" | head -1)
            if [[ -n "$fingerprint" ]]; then
                echo -e "  ${BLUE}Fingerprint:${NC} $fingerprint"
            fi
        else
            print_error "Failed to scan: $target_host (timeout or unreachable)"
            return 1
        fi
    fi
}

verify_cluster_hosts() {
    print_header "Verify Cluster Host Connectivity"

    local verified=0
    local failed=0

    for host in "${CLUSTER_HOSTS_LIST[@]}"; do
        local host_part="${host#*@}"

        # Check if key exists
        if ! ssh-keygen -F "$host_part" > /dev/null 2>&1; then
            print_warning "$host - No host key found"
            ((failed++))
            continue
        fi

        # Try to connect
        print_info "Testing: $host..."

        if timeout 5 ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes "$host" "exit" 2>/dev/null; then
            print_success "$host - Connected successfully"
            ((verified++))
        else
            # Try with just the hostname if user@host format
            if [[ "$host" == *"@"* ]]; then
                local user_part="${host%@*}"
                if timeout 5 ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes "${user_part}@${host_part}" "exit" 2>/dev/null; then
                    print_success "$host - Connected successfully"
                    ((verified++))
                    continue
                fi
            fi

            print_error "$host - Connection failed"
            ((failed++))
        fi
    done

    echo ""
    print_info "Verified: $verified/${#CLUSTER_HOSTS_LIST[@]}"
    if [[ $failed -gt 0 ]]; then
        print_warning "Failed: $failed/${#CLUSTER_HOSTS_LIST[@]}"
    fi

    if [ $failed -eq 0 ]; then
        return 0
    fi
    return 1
}

backup_known_hosts() {
    local label="${1:-manual}"

    print_header "Backup known_hosts"

    if ! check_known_hosts; then
        print_error "Cannot backup: known_hosts file does not exist"
        return 1
    fi

    ensure_backup_dir

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/known_hosts_${label}_${timestamp}"

    if cp "$KNOWN_HOSTS_FILE" "$backup_file"; then
        print_success "Backup created: $backup_file"

        # Show backup info
        local size
        size=$(du -h "$backup_file" | cut -f1)
        local lines
        lines=$(wc -l < "$backup_file" | tr -d ' ')
        print_info "Size: $size, Entries: $lines"

        # Keep only last 10 backups. Backup filenames are timestamp-derived
        # (no spaces / shell metacharacters), so ls -1t is safe; the GNU-only
        # `find -printf '%T@ %p'` workaround isn't portable to macOS.
        local backup_count
        backup_count=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
        if [[ $backup_count -gt 10 ]]; then
            print_info "Cleaning old backups (keeping last 10)..."
            # shellcheck disable=SC2012  # mtime-sort needed; backup filenames are controlled
            ls -1t "$BACKUP_DIR"/* | tail -n +11 | xargs rm -f
        fi

        return 0
    else
        print_error "Backup failed"
        return 1
    fi
}

restore_known_hosts() {
    local backup_file="$1"

    print_header "Restore known_hosts"

    if [[ -z "$backup_file" ]]; then
        # List available backups
        ensure_backup_dir

        if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
            print_error "No backups found in $BACKUP_DIR"
            return 1
        fi

        print_info "Available backups:"
        echo ""

        local count=1
        while IFS= read -r backup; do
            local size
            size=$(du -h "$backup" | cut -f1)
            local date
            date=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$backup")
            echo -e "  ${BLUE}[$count]${NC} $(basename "$backup")"
            echo -e "      Size: $size, Date: $date"
            ((count++))
        done < <(ls -1t "$BACKUP_DIR"/*)

        echo ""
        read -r -p "Enter backup number to restore (or 'q' to quit): " selection

        if [[ "$selection" == "q" ]] || [[ "$selection" == "Q" ]]; then
            print_info "Restore cancelled"
            return 0
        fi

        # Get the selected backup
        # shellcheck disable=SC2012  # mtime-sort needed; backup filenames are controlled
        backup_file=$(ls -1t "$BACKUP_DIR"/* | sed -n "${selection}p")

        if [[ -z "$backup_file" ]] || [[ ! -f "$backup_file" ]]; then
            print_error "Invalid selection"
            return 1
        fi
    fi

    if [[ ! -f "$backup_file" ]]; then
        print_error "Backup file not found: $backup_file"
        return 1
    fi

    # Confirm restoration
    if ! confirm_action "This will replace your current known_hosts with: $(basename "$backup_file")"; then
        return 1
    fi

    # Backup current known_hosts first
    if [[ -f "$KNOWN_HOSTS_FILE" ]]; then
        backup_known_hosts "pre-restore"
    fi

    # Restore
    if cp "$backup_file" "$KNOWN_HOSTS_FILE"; then
        print_success "Restored from: $(basename "$backup_file")"

        local lines
        lines=$(wc -l < "$KNOWN_HOSTS_FILE" | tr -d ' ')
        print_info "Restored entries: $lines"

        return 0
    else
        print_error "Restore failed"
        return 1
    fi
}

show_help() {
    cat << EOF
SSH Host Key Management Utility
================================

USAGE:
    $(basename "$0") <command> [options]

COMMANDS:
    list                    List all cluster hosts in known_hosts
                           Shows which cluster hosts have keys stored

    clean [host]           Remove host keys from known_hosts
                           - Without host: removes all cluster hosts (with confirmation)
                           - With host: removes specific host
                           Examples:
                             $(basename "$0") clean
                             $(basename "$0") clean 10.0.0.10
                             $(basename "$0") clean user@host.example.local

    scan [host]            Scan and add host keys
                           - Without host: scans all cluster hosts
                           - With host: scans specific host
                           Examples:
                             $(basename "$0") scan
                             $(basename "$0") scan host.example.local

    verify                 Verify connectivity to all cluster hosts
                           Tests SSH connections and reports status

    backup [label]         Backup current known_hosts file
                           - Creates timestamped backup
                           - Optional label for easier identification
                           - Keeps last 10 backups automatically
                           Examples:
                             $(basename "$0") backup
                             $(basename "$0") backup before-changes

    restore [backup]       Restore known_hosts from backup
                           - Without backup: shows interactive list
                           - With backup: restores from specific file
                           Examples:
                             $(basename "$0") restore
                             $(basename "$0") restore ~/.ssh/known_hosts_backups/known_hosts_manual_20251211_120000

    help, -h, --help       Show this help message

CLUSTER HOSTS:
    The following hosts are managed by this utility:
$(for host in "${CLUSTER_HOSTS_LIST[@]}"; do echo "      - $host"; done)

FILES:
    known_hosts: $KNOWN_HOSTS_FILE
    Backups:     $BACKUP_DIR

EXAMPLES:
    # List current cluster host keys
    $(basename "$0") list

    # Remove all cluster host keys and rescan
    $(basename "$0") clean
    $(basename "$0") scan

    # Remove and rescan specific host
    $(basename "$0") clean host.example.local
    $(basename "$0") scan host.example.local

    # Verify all hosts are accessible
    $(basename "$0") verify

    # Backup before making changes
    $(basename "$0") backup before-maintenance

    # Restore from backup
    $(basename "$0") restore

WORKFLOW:
    Typical workflow for fixing SSH host key issues:

    1. Backup current state:
       $(basename "$0") backup before-fix

    2. List current state:
       $(basename "$0") list

    3. Clean problematic host:
       $(basename "$0") clean host.example.local

    4. Scan and add new key:
       $(basename "$0") scan host.example.local

    5. Verify connection:
       $(basename "$0") verify

NOTES:
    - All destructive operations require confirmation
    - Backups are created automatically before clean/restore
    - Host keys are hashed for security
    - Timeouts are set to prevent hanging on unreachable hosts

EOF
}

#######################################
# Main script logic
#######################################

main() {
    local command="${1:-}"

    case "$command" in
        list)
            list_cluster_hosts
            ;;
        clean)
            clean_host_keys "${2:-}"
            ;;
        scan)
            scan_host_keys "${2:-}"
            ;;
        verify)
            verify_cluster_hosts
            ;;
        backup)
            backup_known_hosts "${2:-manual}"
            ;;
        restore)
            restore_known_hosts "${2:-}"
            ;;
        help|-h|--help)
            show_help
            ;;
        "")
            print_error "No command specified"
            echo ""
            show_help
            exit 1
            ;;
        *)
            print_error "Unknown command: $command"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
