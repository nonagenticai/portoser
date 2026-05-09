#!/usr/bin/env bash
# verify-postgres-passwords.sh - Verify PostgreSQL passwords across all services
# Usage: verify-postgres-passwords.sh [--sync] [--fix]
#   --sync    Show passwords that would be synced from DB to .env
#   --fix     Actually sync passwords from DB to .env files

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_FILE="${REGISTRY_FILE:-$SCRIPT_DIR/../registry.yml}"
POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_SUPERUSER="${POSTGRES_SUPERUSER:-postgres}"
PSQL="${PSQL:-psql}"
SYNC_MODE=false

# Optionally load cluster topology so we know how to ssh into remote hosts.
CLUSTER_CONF="${CLUSTER_CONF:-$SCRIPT_DIR/../cluster.conf}"
if [[ -f "$CLUSTER_CONF" ]]; then
    # shellcheck source=/dev/null
    source "$CLUSTER_CONF"
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --sync)
            SYNC_MODE=true
            shift
            ;;
        --fix)
            # NOTE: --fix is currently a synonym for --sync. The historical
            # plan was for --fix to write resolved passwords back to each
            # service's .env, but that path was never wired up — the only
            # SYNC_MODE consumer just prints "Manually verify password".
            SYNC_MODE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Verify PostgreSQL passwords match between database and service .env files"
            echo ""
            echo "Options:"
            echo "  --sync    Show mismatches (manual verification required)"
            echo "  --fix     Currently a synonym for --sync (auto-write not implemented)"
            echo "  -h, --help Show this help"
            echo ""
            echo "Examples:"
            echo "  $0              # Verify all passwords"
            echo "  $0 --sync       # Show mismatches"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Get PostgreSQL username for a service. Returns empty string if the registry
# doesn't declare a postgres user for this service AND no env override is set —
# the caller treats that as "this service doesn't use postgres, skip it."
#
# Resolution order:
#   1. services.<svc>.postgres.user from the registry
#   2. <SERVICE>_PG_USER env var (uppercased, "-" → "_")
#   (no default — services that don't declare a postgres user are skipped)
get_pg_user() {
    local service="$1"
    local registry_user
    registry_user=$(yq eval ".services.\"$service\".postgres.user // \"\"" "$REGISTRY_FILE" 2>/dev/null)
    if [[ -n "$registry_user" && "$registry_user" != "null" ]]; then
        echo "$registry_user"
        return
    fi

    local env_var
    env_var="$(echo "$service" | tr '[:lower:]-' '[:upper:]_')_PG_USER"
    if [[ -n "${!env_var:-}" ]]; then
        echo "${!env_var}"
        return
    fi

    echo ""
}

# Get .env variable suffix for a service.
#
# Resolution order:
#   1. services.<svc>.postgres.env_suffix from the registry
#   2. uppercased service name with "-" → "_" (e.g. my-app → MY_APP)
get_env_suffix() {
    local service="$1"
    local registry_suffix
    registry_suffix=$(yq eval ".services.\"$service\".postgres.env_suffix // \"\"" "$REGISTRY_FILE" 2>/dev/null)
    if [[ -n "$registry_suffix" && "$registry_suffix" != "null" ]]; then
        echo "$registry_suffix"
        return
    fi
    echo "${service}" | tr '[:lower:]-' '[:upper:]_'
}

# Get SSH username for a host.
# Resolution order:
#   1. Per-host override in env: SSH_USER_<HOST>=user (host uppercased,
#      non-alphanumerics replaced with "_")
#   2. CLUSTER_HOSTS associative array from cluster.conf, if sourced
#   3. $SSH_USER (global default)
#   4. Current user
get_ssh_user() {
    local host="$1"
    local var
    var="SSH_USER_$(echo "$host" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
    if [[ -n "${!var:-}" ]]; then
        echo "${!var}"
        return
    fi
    if declare -p CLUSTER_HOSTS >/dev/null 2>&1; then
        local entry="${CLUSTER_HOSTS[$host]:-}"
        if [[ -n "$entry" && "$entry" == *"@"* ]]; then
            echo "${entry%%@*}"
            return
        fi
    fi
    echo "${SSH_USER:-$(whoami)}"
}

# Extract password from .env file
get_env_password() {
    local env_file="$1"
    local service="$2"
    local host="$3"

    local suffix
    suffix=$(get_env_suffix "$service")
    local var_name="POSTGRES_PASSWORD_${suffix}"

    # Handle remote vs local files
    local local_host_label
    local_host_label="${LOCAL_HOST_LABEL:-$(hostname -s)}"
    if [[ "$host" == "$local_host_label" ]] || [[ "$host" == "$(hostname -s)" ]] || [[ "$host" == "localhost" ]]; then
        # Local file
        if [[ -f "$env_file" ]]; then
            grep "^${var_name}=" "$env_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo ""
        else
            echo ""
        fi
    else
        # Remote file - use SSH (keys should be set up).
        # Resolve the SSH target: prefer CLUSTER_HOSTS["$host"] if present,
        # else fall back to "<user>@<host>".
        local ssh_target=""
        if declare -p CLUSTER_HOSTS >/dev/null 2>&1 && [[ -n "${CLUSTER_HOSTS[$host]:-}" ]]; then
            ssh_target="${CLUSTER_HOSTS[$host]}"
        else
            local ssh_user
            ssh_user=$(get_ssh_user "$host")
            ssh_target="${ssh_user}@${host}"
        fi
        ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "$ssh_target" "grep '^${var_name}=' '$env_file' 2>/dev/null | cut -d'=' -f2- | tr -d '\"'" 2>/dev/null || echo ""
    fi
}

# Test PostgreSQL password
test_pg_password() {
    local username="$1"
    local password="$2"

    # Use PGPASSWORD environment variable for authentication (not visible in ps)
    # Run in subshell to limit PGPASSWORD scope
    (
        export PGPASSWORD="$password"
        "$PSQL" -U "$username" -h "$POSTGRES_HOST" -d postgres -c "SELECT 1;" >/dev/null 2>&1
    )
    return $?
}

# Parse registry.yml and get docker services
echo -e "${BLUE}=== PostgreSQL Password Verification ===${NC}"
echo ""

# Create temp file for results
RESULTS_FILE=$(mktemp)

# Get list of services
SERVICES=$(grep -E "^  [a-z_-]+:$" "$REGISTRY_FILE" | sed 's/^[[:space:]]*//;s/:$//')

# Process each service
for service in $SERVICES; do
    # Skip if not a service definition
    [[ -z "$service" ]] && continue

    # Get PostgreSQL username
    pg_user=$(get_pg_user "$service")
    [[ -z "$pg_user" ]] && continue

    # Get service details from registry
    # Extract docker_compose path and host directly
    docker_compose=$(awk "/^  ${service}:/{found=1} found && /docker_compose:/{print \$2; exit} /^  [a-z_-]+:/ && found && !/^  ${service}:/{exit}" "$REGISTRY_FILE")
    current_host=$(awk "/^  ${service}:/{found=1} found && /current_host:/{print \$2; exit} /^  [a-z_-]+:/ && found && !/^  ${service}:/{exit}" "$REGISTRY_FILE")

    [[ -z "$docker_compose" ]] && continue

    # Derive .env file path (same directory as docker-compose.yml)
    env_dir=$(dirname "$docker_compose")
    env_file="${env_dir}/.env"

    # Get password from .env
    env_password=$(get_env_password "$env_file" "$service" "$current_host")

    if [[ -z "$env_password" ]]; then
        echo -e "${YELLOW}⚠${NC} $service ($pg_user)"
        echo "    Host: $current_host"
        echo "    Env:  $env_file"
        echo "    Status: Password not found in .env"
        echo "MISSING:$service" >> "$RESULTS_FILE"
        echo ""
        continue
    fi

    # Test the password
    if test_pg_password "$pg_user" "$env_password"; then
        echo -e "${GREEN}✓${NC} $service ($pg_user)"
        echo "    Host: $current_host"
        echo "    Env:  $env_file"
        echo "    Status: Password matches"
        echo "PASSED:$service" >> "$RESULTS_FILE"
    else
        echo -e "${RED}✗${NC} $service ($pg_user)"
        echo "    Host: $current_host"
        echo "    Env:  $env_file"
        echo "    Status: Password mismatch or connection failed"

        if [[ "$SYNC_MODE" == true ]]; then
            echo -e "    ${YELLOW}Action needed: Manually verify password${NC}"
        fi

        echo "FAILED:$service" >> "$RESULTS_FILE"
    fi
    echo ""
done

# Count results (disable exit on error for counting)
set +e
total=$(wc -l < "$RESULTS_FILE" 2>/dev/null | tr -d ' \n')
[[ -z "$total" ]] && total=0
passed=$(grep -c "^PASSED:" "$RESULTS_FILE" 2>/dev/null || echo 0)
failed=$(grep -c "^FAILED:" "$RESULTS_FILE" 2>/dev/null || echo 0)
missing=$(grep -c "^MISSING:" "$RESULTS_FILE" 2>/dev/null || echo 0)
set -e

# Get service lists
failed_services=$(grep "^FAILED:" "$RESULTS_FILE" 2>/dev/null | cut -d':' -f2 | tr '\n' ',' | sed 's/,$//' || echo "")
missing_services=$(grep "^MISSING:" "$RESULTS_FILE" 2>/dev/null | cut -d':' -f2 | tr '\n' ',' | sed 's/,$//' || echo "")

# Summary
echo -e "${BLUE}=== SUMMARY ===${NC}"
echo "Total services checked: $total"
echo -e "${GREEN}Passed: $passed${NC}"
echo -e "${RED}Failed: $failed${NC}"
echo -e "${YELLOW}Missing: $missing${NC}"
echo ""

if [[ $failed -gt 0 ]]; then
    echo -e "${RED}Failed services:${NC}"
    echo "  $failed_services"
    echo ""
fi

if [[ $missing -gt 0 ]]; then
    echo -e "${YELLOW}Services with missing passwords in .env:${NC}"
    echo "  $missing_services"
    echo ""
fi

# Cleanup
rm -f "$RESULTS_FILE"

# Exit status
if [[ $failed -eq 0 ]] && [[ $missing -eq 0 ]]; then
    echo -e "${GREEN}✓ All PostgreSQL passwords are correct${NC}"
    exit 0
else
    echo -e "${RED}✗ Some passwords need attention${NC}"
    echo ""
    echo "To see what would be synced: $0 --sync"
    echo "To fix all mismatches: $0 --fix"
    exit 1
fi
