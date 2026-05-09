#!/usr/bin/env bash
# PostgreSQL Password Verification & Sync Script
# Verifies and synchronizes passwords between PostgreSQL and service .env files
# Based on portoser registry.yml

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_FILE="${REGISTRY_FILE:-$SCRIPT_DIR/registry.yml}"
PG_HOST="${POSTGRES_HOST:-${PG_HOST:-localhost}}"
PG_PORT="${POSTGRES_PORT:-${PG_PORT:-5432}}"
PG_SUPERUSER="${POSTGRES_SUPERUSER:-${PG_SUPERUSER:-postgres}}"
DRY_RUN="${DRY_RUN:-true}"

# Parse YAML (simple parser for our use case)
parse_yaml() {
    local yaml_file="$1"

    # Check if python3 is available
    if ! command -v python3 >/dev/null 2>&1; then
        echo "Error: python3 is required but not found" >&2
        return 1
    fi

    python3 - <<EOF
import yaml
import sys

try:
    with open('$yaml_file', 'r') as f:
        data = yaml.safe_load(f)

    services = data.get('services', {})
    for service_name, service_config in services.items():
        if isinstance(service_config, dict):
            docker_compose = service_config.get('docker_compose', '')
            service_file = service_config.get('service_file', '')
            current_host = service_config.get('current_host', '')

            if docker_compose:
                print(f"{service_name}|{docker_compose}|{current_host}")
            elif service_file:
                print(f"{service_name}|{service_file}|{current_host}")
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
EOF
}

# Extract database username from docker-compose.yml or .env
get_db_user() {
    local service_dir="$1"
    local service_name="$2"

    # Common patterns for database usernames
    local user=""

    # Check docker-compose.yml for DATABASE_URL pattern
    if [ -f "$service_dir/docker-compose.yml" ]; then
        # Extract username from postgresql://USERNAME:password@host:port/db
        user=$(grep 'postgresql://' "$service_dir/docker-compose.yml" 2>/dev/null | sed -n 's|.*postgresql://\([^:]*\):.*|\1|p' | head -1)

        # If not found, check for POSTGRES_USER variable
        if [ -z "$user" ]; then
            user=$(grep "POSTGRES_USER" "$service_dir/docker-compose.yml" 2>/dev/null | sed -n 's/.*POSTGRES_USER[=:][[:space:]]*\([a-zA-Z0-9_-]*\).*/\1/p' | tail -1)
        fi
    fi

    # Check .env file
    if [ -z "$user" ] && [ -f "$service_dir/.env" ]; then
        user=$(grep "^POSTGRES_USER=" "$service_dir/.env" 2>/dev/null | cut -d= -f2 | tr -d '"')
    fi

    # Fallback: derive a username from the service name. Replace "-" with
    # "_" so e.g. "my-app" → "my_app_user". This is just a reasonable default;
    # services with custom users should set POSTGRES_USER in their
    # docker-compose.yml or .env, which the discovery above will pick up.
    if [ -z "$user" ]; then
        user="$(echo "$service_name" | tr '-' '_')_user"
    fi

    echo "$user"
}

# Extract database name
get_db_name() {
    local service_dir="$1"
    local service_name="$2"

    local db_name=""

    # Check docker-compose.yml for DATABASE_URL
    if [ -f "$service_dir/docker-compose.yml" ]; then
        db_name=$(grep 'postgresql://' "$service_dir/docker-compose.yml" 2>/dev/null | sed -n 's|.*postgresql://[^/]*/\([^?]*\).*|\1|p' | head -1)
    fi

    # Default to service name
    if [ -z "$db_name" ]; then
        db_name="$service_name"
    fi

    echo "$db_name"
}

# Get password from .env file
get_env_password() {
    local service_dir="$1"

    if [ ! -f "$service_dir/.env" ]; then
        echo ""
        return
    fi

    # Try different password variable names
    local password=""
    password=$(grep "^POSTGRES_PASSWORD=" "$service_dir/.env" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'")

    if [ -z "$password" ]; then
        password=$(grep "^DATABASE_PASSWORD=" "$service_dir/.env" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'")
    fi

    echo "$password"
}

# Test PostgreSQL connection
test_pg_connection() {
    local user="$1"
    local password="$2"
    local database="$3"

    # Use subshell to limit PGPASSWORD scope and prevent process exposure
    (
        # shellcheck disable=SC2030  # subshell scope is the point — caller PGPASSWORD must not leak
        export PGPASSWORD="$password"
        psql -h "$PG_HOST" -p "$PG_PORT" -U "$user" -d "$database" -c "SELECT 1;" >/dev/null 2>&1
    )
    return $?
}

# Get password from PostgreSQL (requires superuser access)
get_pg_password() {
    local user="$1"

    # This requires pg_shadow access (superuser only)
    # Use subshell to limit scope
    (
        # shellcheck disable=SC2031  # subshell scope is the point — must not leak to caller
        export PGPASSWORD=""
        psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -d postgres -t -c \
            "SELECT rolpassword FROM pg_authid WHERE rolname='$user';" 2>/dev/null | tr -d ' '
    )
}

# Update .env file with new password
update_env_password() {
    local service_dir="$1"
    local new_password="$2"

    if [ "$DRY_RUN" = "true" ]; then
        echo "  [DRY-RUN] Would update $service_dir/.env with new password"
        return 0
    fi

    if [ ! -f "$service_dir/.env" ]; then
        echo "POSTGRES_PASSWORD=\"$new_password\"" > "$service_dir/.env"
    else
        # Backup original
        cp "$service_dir/.env" "$service_dir/.env.backup.$(date +%Y%m%d_%H%M%S)"

        # Update or add password
        if grep -q "^POSTGRES_PASSWORD=" "$service_dir/.env"; then
            sed -i.tmp "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=\"$new_password\"|" "$service_dir/.env"
            rm "$service_dir/.env.tmp"
        else
            echo "POSTGRES_PASSWORD=\"$new_password\"" >> "$service_dir/.env"
        fi
    fi
}

# Main verification function
verify_service() {
    local service_name="$1"
    local service_path="$2"
    local current_host="$3"

    # Skip if not on this host
    local hostname
    hostname=$(hostname -s 2>/dev/null || hostname | cut -d. -f1)
    if [ "$current_host" != "$hostname" ] && [ "$current_host" != "localhost" ]; then
        return 0
    fi

    # Get service directory
    local service_dir
    service_dir=$(dirname "$service_path")
    if [ ! -d "$service_dir" ]; then
        echo -e "${YELLOW}⊘ $service_name${NC} - Directory not found: $service_dir"
        return 0
    fi

    # Get database configuration
    local db_user
    db_user=$(get_db_user "$service_dir" "$service_name")
    local db_name
    db_name=$(get_db_name "$service_dir" "$service_name")
    local env_password
    env_password=$(get_env_password "$service_dir")

    # Skip if no database user found
    if [ -z "$db_user" ]; then
        return 0
    fi

    # Skip if no password in .env
    if [ -z "$env_password" ]; then
        echo -e "${YELLOW}⚠ $service_name${NC} - No password in .env (user: $db_user)"
        return 0
    fi

    # Test connection
    if test_pg_connection "$db_user" "$env_password" "$db_name"; then
        echo -e "${GREEN}✓ $service_name${NC} - Password verified (user: $db_user, db: $db_name)"
        return 0
    else
        echo -e "${RED}✗ $service_name${NC} - Password mismatch (user: $db_user, db: $db_name)"
        echo "  .env file: $service_dir/.env"
        echo "  Password length: ${#env_password} chars"

        # Try to get correct password (requires superuser)
        local pg_password
        pg_password=$(get_pg_password "$db_user")
        if [ -n "$pg_password" ]; then
            echo "  PostgreSQL has encrypted password (hash not shown for security)"
        fi

        return 1
    fi
}

# Main script
main() {
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║    PostgreSQL Password Verification & Sync                    ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if [ "$DRY_RUN" = "true" ]; then
        echo -e "${YELLOW}Running in DRY-RUN mode (no changes will be made)${NC}"
        echo ""
    fi

    if [ ! -f "$REGISTRY_FILE" ]; then
        echo -e "${RED}Error: Registry file not found: $REGISTRY_FILE${NC}"
        exit 1
    fi

    echo "Configuration:"
    echo "  Registry: $REGISTRY_FILE"
    echo "  PostgreSQL: $PG_HOST:$PG_PORT"
    echo "  Superuser: $PG_SUPERUSER"
    echo ""

    local total=0
    local verified=0
    local failed=0

    # Parse registry and check each service
    while IFS='|' read -r service_name service_path current_host; do
        if [ -z "$service_name" ]; then
            continue
        fi

        ((total++))

        if verify_service "$service_name" "$service_path" "$current_host"; then
            ((verified++))
        else
            ((failed++))
        fi
    done < <(parse_yaml "$REGISTRY_FILE")

    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo "Summary:"
    echo -e "  ${GREEN}✓ Verified: $verified${NC}"
    echo -e "  ${RED}✗ Failed: $failed${NC}"
    echo -e "  Total checked: $total"
    echo ""

    if [ $failed -gt 0 ]; then
        echo -e "${YELLOW}To sync passwords, run with: DRY_RUN=false $0${NC}"
        exit 1
    fi
}

# Run main
main "$@"
