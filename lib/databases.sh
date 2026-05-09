#!/usr/bin/env bash
#=============================================================================
# File: databases.sh
# Author: Portoser Development Team
# Purpose: Database management library for production/test mode switching
#
# Description:
#   Provides comprehensive functions for managing database mode switching between
#   production and test environments, database synchronization, and status checking.
#   Supports PostgreSQL, Neo4j, and PgBouncer on remote hosts via SSH.
#
# Dependencies:
#   - ssh (for remote host access)
#   - dig (for DNS resolution checking)
#   - postgresql@18 command-line tools (psql, pg_dump, pg_restore)
#   - dnsmasq (for DNS management)
#   - brew services (for service management)
#
# Usage Examples:
#   # Check current mode
#   current_mode=$(check_database_mode)
#
#   # Switch to test mode
#   switch_database_mode "test"
#
#   # Show status report
#   show_database_status
#
#   # Sync databases
#   sync_databases "$PROD_DB_HOST" "$TEST_DB_HOST" ""
#=============================================================================

set -euo pipefail

# Import validation library. Resolve via this file's own directory so we
# don't depend on the caller having $SCRIPT_DIR set (broken under set -u).
_DATABASES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/utils/validation.sh
source "${_DATABASES_LIB_DIR}/utils/validation.sh"
unset _DATABASES_LIB_DIR

# NOTE: This library encodes a specific home-lab workflow: two hosts (a
# "production-databases" host and a "test-databases" host) and a local dnsmasq
# instance that flips the *.internal hostnames between them. The defaults
# below are placeholders (TEST-NET-2 / RFC 5737); set the env vars in your
# .env (or before sourcing this file) for your environment.

# Machine IP configuration
PROD_DB_IP="${PROD_DB_IP:-198.51.100.10}"    # Production databases host
TEST_DB_IP="${TEST_DB_IP:-198.51.100.20}"    # Test databases host

# DNS configuration
DNSMASQ_CONF="${DNSMASQ_CONF:-/opt/homebrew/etc/dnsmasq.conf}"

# DNS suffix used for the DB-mode internal hostnames generated below.
# Override with DB_DNS_SUFFIX (e.g. "lab.local" or "internal").
DB_DNS_SUFFIX="${DB_DNS_SUFFIX:-internal}"

# Host configuration (user@host for SSH)
PROD_DB_HOST="${PROD_DB_HOST:-prod@${PROD_DB_IP}}"
TEST_DB_HOST="${TEST_DB_HOST:-test@${TEST_DB_IP}}"

# PostgreSQL configuration
PG_BIN="${PG_BIN:-/opt/homebrew/opt/postgresql@18/bin}"
PG_PORT="${PG_PORT:-5432}"

# Neo4j configuration
NEO4J_DATA_DIR="${NEO4J_DATA_DIR:-/opt/homebrew/var/neo4j/data}"

# Color codes (only used when not in JSON mode)
if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
    DB_RED='\033[0;31m'
    DB_GREEN='\033[0;32m'
    DB_YELLOW='\033[1;33m'
    DB_BLUE='\033[0;34m'
    DB_NC='\033[0m'
else
    DB_RED=''
    DB_GREEN=''
    DB_YELLOW=''
    DB_BLUE=''
    DB_NC=''
fi

################################################################################
# Core Database Mode Functions
################################################################################

#=============================================================================
# Function: check_database_mode
# Description: Check current database mode by inspecting DNS resolution
# Parameters: None
# Returns:
#   PRODUCTION - Production mode is active
#   TEST - Test mode is active
#   UNKNOWN - Mode cannot be determined
# Example:
#   current_mode=$(check_database_mode)
#=============================================================================
check_database_mode() {
    local postgres_ip
    postgres_ip=$(dig +short postgres.internal @127.0.0.1 2>/dev/null | head -1)
    local neo4j_ip
    neo4j_ip=$(dig +short neo4j.internal @127.0.0.1 2>/dev/null | head -1)

    # If dig fails, try fallback to /etc/hosts
    if [ -z "$postgres_ip" ]; then
        postgres_ip=$(grep -E "^\s*[0-9.]+\s+postgres\.internal" /etc/hosts 2>/dev/null | awk '{print $1}')
    fi

    if [ -z "$neo4j_ip" ]; then
        neo4j_ip=$(grep -E "^\s*[0-9.]+\s+neo4j\.internal" /etc/hosts 2>/dev/null | awk '{print $1}')
    fi

    if [[ "$postgres_ip" == "$PROD_DB_IP" ]] && [[ "$neo4j_ip" == "$PROD_DB_IP" ]]; then
        echo "PRODUCTION"
    elif [[ "$postgres_ip" == "$TEST_DB_IP" ]] && [[ "$neo4j_ip" == "$TEST_DB_IP" ]]; then
        echo "TEST"
    else
        echo "UNKNOWN"
    fi
}

#=============================================================================
# Function: update_dnsmasq_config
# Description: Update dnsmasq configuration to switch database mode
# Parameters:
#   $1 - target_mode (prod or test) - Database mode to switch to
# Returns:
#   0 - Configuration updated successfully
#   1 - Invalid parameters or configuration failed
# Example:
#   update_dnsmasq_config "prod"
#=============================================================================
update_dnsmasq_config() {
    local target_mode="$1"

    if [ -z "$target_mode" ]; then
        echo "Error: Target mode required (prod or test)" >&2
        return 1
    fi

    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo -e "${DB_BLUE}Updating dnsmasq configuration...${DB_NC}"
    fi

    # Create backup
    if ! sudo cp "$DNSMASQ_CONF" "${DNSMASQ_CONF}.backup.$(date +%Y%m%d_%H%M%S)"; then
        echo "ERROR: Failed to create backup of dnsmasq configuration" >&2
        return 1
    fi

    # Pick the active endpoints for this mode.
    if [[ "$target_mode" == "prod" ]]; then
        local active_ip="$PROD_DB_IP"
        local mode_label="PRODUCTION"
    else
        local active_ip="$TEST_DB_IP"
        local mode_label="TEST"
    fi

    # Build the full new file in a temp location so we can swap it into place
    # atomically. Doing the strip + append directly against $DNSMASQ_CONF
    # leaves the file half-written if the second write fails — which is how
    # operators ended up with a config that resolves "postgres" to nothing
    # because the strip succeeded but the append didn't.
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/dnsmasq.XXXXXX")
    if [ -z "$tmp" ] || [ ! -f "$tmp" ]; then
        echo "ERROR: Could not create temp file for dnsmasq config" >&2
        return 1
    fi
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN

    # The redirect runs as the invoking user, which is intended: $tmp was
    # created by mktemp() under $TMPDIR (typically /tmp), so the user owns it.
    # Only the sed (reading the privileged $DNSMASQ_CONF) needs sudo.
    # shellcheck disable=SC2024
    if ! sudo sed '/^# === DATABASE MODE CONFIGURATION ===/,/^# === END DATABASE MODE ===/d' "$DNSMASQ_CONF" > "$tmp"; then
        echo "ERROR: Failed to strip old database entries into temp file" >&2
        return 1
    fi

    if ! cat >> "$tmp" <<EOF

# === DATABASE MODE CONFIGURATION ===
# Current Mode: $mode_label
# Last Updated: $(date)
#
# Production Endpoints (always available)
address=/postgres-prod.${DB_DNS_SUFFIX}/$PROD_DB_IP
address=/pgbouncer-prod.${DB_DNS_SUFFIX}/$PROD_DB_IP
address=/neo4j-prod.${DB_DNS_SUFFIX}/$PROD_DB_IP

# Test Endpoints (always available)
address=/postgres-test.${DB_DNS_SUFFIX}/$TEST_DB_IP
address=/pgbouncer-test.${DB_DNS_SUFFIX}/$TEST_DB_IP
address=/neo4j-test.${DB_DNS_SUFFIX}/$TEST_DB_IP

# Active Endpoints (MODE: $mode_label)
# These are what applications use via the unsuffixed hostnames
address=/postgres.${DB_DNS_SUFFIX}/$active_ip
address=/pgbouncer.${DB_DNS_SUFFIX}/$active_ip
address=/neo4j.${DB_DNS_SUFFIX}/$active_ip
# === END DATABASE MODE ===
EOF
    then
        echo "ERROR: Failed to append new configuration to temp file" >&2
        return 1
    fi

    # Atomic swap: a single mv replaces the file in one syscall, so the
    # config either has the old content or the new content — never partial.
    if ! sudo mv "$tmp" "$DNSMASQ_CONF"; then
        echo "ERROR: Failed to swap new dnsmasq config into place" >&2
        return 1
    fi

    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo -e "${DB_GREEN}✓ Configuration updated${DB_NC}"
    fi

    return 0
}

#=============================================================================
# Function: reload_dnsmasq
# Description: Reload dnsmasq service to apply configuration changes
# Parameters: None
# Returns:
#   0 - Service reloaded successfully
#   1 - Service reload failed
# Example:
#   reload_dnsmasq
#=============================================================================
reload_dnsmasq() {
    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo -e "${DB_BLUE}Reloading dnsmasq...${DB_NC}"
    fi

    if ! sudo /opt/homebrew/bin/brew services restart dnsmasq; then
        echo "ERROR: Failed to restart dnsmasq service" >&2
        return 1
    fi
    sleep 2

    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo -e "${DB_GREEN}✓ dnsmasq reloaded${DB_NC}"
    fi

    return 0
}

#=============================================================================
# Function: verify_database_switch
# Description: Verify database mode switch was successful
# Parameters:
#   $1 - expected_mode (prod or test) - Mode to verify
# Returns:
#   0 - Switch verified successfully
#   1 - Verification failed or mode mismatch
# Example:
#   verify_database_switch "prod"
#=============================================================================
verify_database_switch() {
    local expected_mode="$1"

    if [ -z "$expected_mode" ]; then
        echo "Error: Expected mode required (prod or test)" >&2
        return 1
    fi

    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo -e "${DB_BLUE}Verifying switch...${DB_NC}"
    fi

    sleep 1

    local current_mode
    current_mode=$(check_database_mode)

    if [[ "$expected_mode" == "prod" ]] && [[ "$current_mode" == "PRODUCTION" ]]; then
        if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
            echo -e "${DB_GREEN}✓ Successfully switched to PRODUCTION mode${DB_NC}"
        fi
        return 0
    elif [[ "$expected_mode" == "test" ]] && [[ "$current_mode" == "TEST" ]]; then
        if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
            echo -e "${DB_GREEN}✓ Successfully switched to TEST mode${DB_NC}"
        fi
        return 0
    else
        if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
            echo -e "${DB_RED}✗ Verification failed. Current mode: $current_mode${DB_NC}"
        fi
        return 1
    fi
}

#=============================================================================
# Function: switch_database_mode
# Description: Switch database mode between production and test environments
# Parameters:
#   $1 - mode (prod/production or test/testing) - Target database mode
# Returns:
#   0 - Mode switched successfully
#   1 - Switch failed or invalid mode specified
# Example:
#   switch_database_mode "test"
#=============================================================================
switch_database_mode() {
    local mode="$1"

    if [ -z "$mode" ]; then
        echo "Error: Mode required (prod or test)" >&2
        return 1
    fi

    # Normalize mode input
    case "$mode" in
        prod|production)
            mode="prod"
            ;;
        test|testing)
            mode="test"
            ;;
        *)
            echo "Error: Invalid mode '$mode'. Must be 'prod' or 'test'" >&2
            return 1
            ;;
    esac

    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        if [[ "$mode" == "test" ]]; then
            echo -e "${DB_YELLOW}=== Switching to TEST mode ===${DB_NC}"
            echo -e "${DB_YELLOW}WARNING: All applications will now connect to TEST databases${DB_NC}"
            echo -e "${DB_YELLOW}Make sure test database instances are running!${DB_NC}"
            echo ""
        else
            echo -e "${DB_BLUE}=== Switching to PRODUCTION mode ===${DB_NC}"
            echo ""
        fi
    fi

    # Update DNS configuration
    if ! update_dnsmasq_config "$mode"; then
        echo "Error: Failed to update dnsmasq configuration" >&2
        return 1
    fi

    # Reload dnsmasq
    if ! reload_dnsmasq; then
        echo "Error: Failed to reload dnsmasq" >&2
        return 1
    fi

    # Verify the switch
    if ! verify_database_switch "$mode"; then
        echo "Error: Database mode switch verification failed" >&2
        return 1
    fi

    return 0
}

################################################################################
# Database Status Functions
################################################################################

#=============================================================================
# Function: check_postgres_status
# Description: Get PostgreSQL status on a specific host via SSH
# Parameters:
#   $1 - host (user@ip format) - SSH host specification
# Returns:
#   0 - PostgreSQL is running
#   1 - PostgreSQL is not running or host unreachable
# Example:
#   check_postgres_status "$PROD_DB_HOST"
#=============================================================================
check_postgres_status() {
    local host="$1"

    if [ -z "$host" ]; then
        echo "Error: Host required" >&2
        return 1
    fi

    local pg_status
    pg_status=$(ssh "$host" "/opt/homebrew/bin/brew services list | grep postgresql@18" 2>/dev/null || echo "unknown")

    if echo "$pg_status" | grep -q "started"; then
        return 0
    else
        return 1
    fi
}

#=============================================================================
# Function: get_postgres_db_count
# Description: Get PostgreSQL database count on a specific host
# Parameters:
#   $1 - host (user@ip format) - SSH host specification
# Returns:
#   0 - Count retrieved successfully
#   1 - Failed to retrieve count
# Output: Number of non-template databases
# Example:
#   count=$(get_postgres_db_count "$PROD_DB_HOST")
#=============================================================================
# SC2029: PG_BIN/PG_PORT/user are local config / validated above; the remote
# psql command is built and sent intentionally as a string.
# shellcheck disable=SC2029
get_postgres_db_count() {
    local host="$1"
    local user
    user=$(echo "$host" | cut -d@ -f1)
    local ip
    ip=$(echo "$host" | cut -d@ -f2)

    # Validate and sanitize inputs
    if ! validate_env_var_name "$user" 2>/dev/null; then
        echo "0"
        return 1
    fi
    if ! validate_ip "$ip" 2>/dev/null; then
        echo "0"
        return 1
    fi
    if ! validate_port "$PG_PORT" 2>/dev/null; then
        echo "0"
        return 1
    fi

    ssh "$host" "${PG_BIN}/psql -h localhost -p \"${PG_PORT}\" -U \"${user}\" -d postgres -t -A -c \"SELECT COUNT(*) FROM pg_database WHERE datistemplate = false;\"" 2>/dev/null || echo "0"
}

#=============================================================================
# Function: get_postgres_ssl_status
# Description: Get PostgreSQL SSL status on a specific host
# Parameters:
#   $1 - host (user@ip format) - SSH host specification
# Returns:
#   0 - Status retrieved successfully
#   1 - Failed to retrieve status
# Output: SSL status (on, off, or unknown)
# Example:
#   ssl_status=$(get_postgres_ssl_status "$PROD_DB_HOST")
#=============================================================================
# SC2029: PG_BIN/PG_PORT/user are local config / validated above; the remote
# psql command is built and sent intentionally as a string.
# shellcheck disable=SC2029
get_postgres_ssl_status() {
    local host="$1"
    local user
    user=$(echo "$host" | cut -d@ -f1)

    # Validate user input
    if ! validate_env_var_name "$user" 2>/dev/null; then
        echo "unknown"
        return 1
    fi
    if ! validate_port "$PG_PORT" 2>/dev/null; then
        echo "unknown"
        return 1
    fi

    ssh "$host" "${PG_BIN}/psql -h localhost -p \"${PG_PORT}\" -U \"${user}\" -d postgres -t -A -c \"SHOW ssl;\"" 2>/dev/null || echo "unknown"
}

#=============================================================================
# Function: check_pgbouncer_status
# Description: Check PgBouncer status on a specific host
# Parameters:
#   $1 - host (user@ip format) - SSH host specification
# Returns:
#   0 - PgBouncer is running
#   1 - PgBouncer is not running or host unreachable
# Example:
#   check_pgbouncer_status "$PROD_DB_HOST"
#=============================================================================
check_pgbouncer_status() {
    local host="$1"

    if ssh "$host" "ps aux | grep -v grep | grep pgbouncer" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

#=============================================================================
# Function: check_neo4j_status
# Description: Check Neo4j status on a specific host
# Parameters:
#   $1 - host (user@ip format) - SSH host specification
# Returns:
#   0 - Neo4j is running
#   1 - Neo4j is not running or host unreachable
# Example:
#   check_neo4j_status "$PROD_DB_HOST"
#=============================================================================
check_neo4j_status() {
    local host="$1"

    local neo4j_status
    neo4j_status=$(ssh "$host" "/opt/homebrew/bin/brew services list | grep neo4j" 2>/dev/null || echo "unknown")

    if echo "$neo4j_status" | grep -q "started"; then
        return 0
    else
        return 1
    fi
}

#=============================================================================
# Function: show_database_status
# Description: Show detailed database status for both environments (prod/test)
# Parameters: None
# Returns:
#   0 - Status displayed successfully
#   1 - Status check failed
# Output: Colored status report or JSON (if JSON_OUTPUT_MODE=1)
# Example:
#   show_database_status
#=============================================================================
show_database_status() {
    if [ "${JSON_OUTPUT_MODE:-0}" = "1" ]; then
        # JSON output mode
        show_database_status_json
        return $?
    fi

    # Human-readable output
    echo -e "${DB_BLUE}=== Database Mode Status ===${DB_NC}"
    echo ""

    local current_mode
    current_mode=$(check_database_mode)

    if [[ "$current_mode" == "PRODUCTION" ]]; then
        echo -e "Current Mode: ${DB_GREEN}PRODUCTION${DB_NC}"
    elif [[ "$current_mode" == "TEST" ]]; then
        echo -e "Current Mode: ${DB_YELLOW}TEST${DB_NC}"
    else
        echo -e "Current Mode: ${DB_RED}UNKNOWN${DB_NC}"
    fi

    echo ""
    echo "DNS Resolution:"
    echo "  postgres.internal  -> $(dig +short postgres.internal @127.0.0.1 2>/dev/null | head -1)"
    echo "  pgbouncer.internal -> $(dig +short pgbouncer.internal @127.0.0.1 2>/dev/null | head -1)"
    echo "  neo4j.internal     -> $(dig +short neo4j.internal @127.0.0.1 2>/dev/null | head -1)"
    echo ""
    echo "Endpoints:"
    echo "  Production:"
    echo "    postgres-prod.internal  -> $PROD_DB_IP"
    echo "    pgbouncer-prod.internal -> $PROD_DB_IP"
    echo "    neo4j-prod.internal     -> $PROD_DB_IP"
    echo ""
    echo "  Test:"
    echo "    postgres-test.internal  -> $TEST_DB_IP"
    echo "    pgbouncer-test.internal -> $TEST_DB_IP"
    echo "    neo4j-test.internal     -> $TEST_DB_IP"
    echo ""

    # Check production environment
    echo -e "${DB_BLUE}=== PRODUCTION Environment (prod-db - ${PROD_DB_IP}) ===${DB_NC}"
    echo ""

    if ping -c 1 -W 1 "${PROD_DB_IP}" >/dev/null 2>&1; then
        echo "  PostgreSQL:"
        if check_postgres_status "$PROD_DB_HOST"; then
            echo -e "    Status: ${DB_GREEN}✓ Running${DB_NC}"
            echo "    Databases: $(get_postgres_db_count "$PROD_DB_HOST")"
            local ssl_status
            ssl_status=$(get_postgres_ssl_status "$PROD_DB_HOST")
            if [ "$ssl_status" == "on" ]; then
                echo -e "    SSL: ${DB_GREEN}✓ Enabled${DB_NC}"
            else
                echo -e "    SSL: ${DB_RED}✗ Disabled${DB_NC}"
            fi
        else
            echo -e "    Status: ${DB_RED}✗ Not running${DB_NC}"
        fi
        echo ""

        echo "  PgBouncer:"
        if check_pgbouncer_status "$PROD_DB_HOST"; then
            echo -e "    Status: ${DB_GREEN}✓ Running${DB_NC}"
        else
            echo -e "    Status: ${DB_RED}✗ Not running${DB_NC}"
        fi
        echo ""

        echo "  Neo4j:"
        if check_neo4j_status "$PROD_DB_HOST"; then
            echo -e "    Status: ${DB_GREEN}✓ Running${DB_NC}"
        else
            echo -e "    Status: ${DB_RED}✗ Not running${DB_NC}"
        fi
        echo ""
    else
        echo -e "  ${DB_RED}⚠️  Cannot reach ${PROD_DB_IP}${DB_NC}"
        echo ""
    fi

    # Check test environment
    echo -e "${DB_BLUE}=== TEST Environment (test-db - ${TEST_DB_IP}) ===${DB_NC}"
    echo ""

    if ping -c 1 -W 1 "${TEST_DB_IP}" >/dev/null 2>&1; then
        echo "  PostgreSQL:"
        if check_postgres_status "$TEST_DB_HOST"; then
            echo -e "    Status: ${DB_GREEN}✓ Running${DB_NC}"
            echo "    Databases: $(get_postgres_db_count "$TEST_DB_HOST")"
            local ssl_status
            ssl_status=$(get_postgres_ssl_status "$TEST_DB_HOST")
            if [ "$ssl_status" == "on" ]; then
                echo -e "    SSL: ${DB_GREEN}✓ Enabled${DB_NC}"
            else
                echo -e "    SSL: ${DB_RED}✗ Disabled${DB_NC}"
            fi
        else
            echo -e "    Status: ${DB_RED}✗ Not running${DB_NC}"
        fi
        echo ""

        echo "  PgBouncer:"
        if check_pgbouncer_status "$TEST_DB_HOST"; then
            echo -e "    Status: ${DB_GREEN}✓ Running${DB_NC}"
        else
            echo -e "    Status: ${DB_RED}✗ Not running${DB_NC}"
        fi
        echo ""

        echo "  Neo4j:"
        if check_neo4j_status "$TEST_DB_HOST"; then
            echo -e "    Status: ${DB_GREEN}✓ Running${DB_NC}"
        else
            echo -e "    Status: ${DB_RED}✗ Not running${DB_NC}"
        fi
        echo ""
    else
        echo -e "  ${DB_RED}⚠️  Cannot reach ${TEST_DB_IP}${DB_NC}"
        echo ""
    fi

    return 0
}

#=============================================================================
# Function: show_database_status_json
# Description: Show database status in JSON format
# Parameters: None
# Returns:
#   0 - JSON status displayed successfully
#   1 - Status check failed
# Output: JSON object with complete database status information
# Example:
#   show_database_status_json
#=============================================================================
show_database_status_json() {
    local current_mode
    current_mode=$(check_database_mode)
    local postgres_ip
    postgres_ip=$(dig +short postgres.internal @127.0.0.1 2>/dev/null | head -1)
    local pgbouncer_ip
    pgbouncer_ip=$(dig +short pgbouncer.internal @127.0.0.1 2>/dev/null | head -1)
    local neo4j_ip
    neo4j_ip=$(dig +short neo4j.internal @127.0.0.1 2>/dev/null | head -1)

    # Check production environment
    local prod_reachable="false"
    if ping -c 1 -W 1 "${PROD_DB_IP}" >/dev/null 2>&1; then
        prod_reachable="true"
    fi

    local prod_pg_running="false"
    local prod_pg_db_count="0"
    local prod_pg_ssl="unknown"
    if [ "$prod_reachable" = "true" ]; then
        if check_postgres_status "$PROD_DB_HOST"; then
            prod_pg_running="true"
            prod_pg_db_count=$(get_postgres_db_count "$PROD_DB_HOST")
            prod_pg_ssl=$(get_postgres_ssl_status "$PROD_DB_HOST")
        fi
    fi

    local prod_pgbouncer_running="false"
    if [ "$prod_reachable" = "true" ] && check_pgbouncer_status "$PROD_DB_HOST"; then
        prod_pgbouncer_running="true"
    fi

    local prod_neo4j_running="false"
    if [ "$prod_reachable" = "true" ] && check_neo4j_status "$PROD_DB_HOST"; then
        prod_neo4j_running="true"
    fi

    # Check test environment
    local test_reachable="false"
    if ping -c 1 -W 1 "${TEST_DB_IP}" >/dev/null 2>&1; then
        test_reachable="true"
    fi

    local test_pg_running="false"
    local test_pg_db_count="0"
    local test_pg_ssl="unknown"
    if [ "$test_reachable" = "true" ]; then
        if check_postgres_status "$TEST_DB_HOST"; then
            test_pg_running="true"
            test_pg_db_count=$(get_postgres_db_count "$TEST_DB_HOST")
            test_pg_ssl=$(get_postgres_ssl_status "$TEST_DB_HOST")
        fi
    fi

    local test_pgbouncer_running="false"
    if [ "$test_reachable" = "true" ] && check_pgbouncer_status "$TEST_DB_HOST"; then
        test_pgbouncer_running="true"
    fi

    local test_neo4j_running="false"
    if [ "$test_reachable" = "true" ] && check_neo4j_status "$TEST_DB_HOST"; then
        test_neo4j_running="true"
    fi

    cat <<EOF
{
  "current_mode": "$current_mode",
  "dns_resolution": {
    "postgres_internal": "$postgres_ip",
    "pgbouncer_internal": "$pgbouncer_ip",
    "neo4j_internal": "$neo4j_ip"
  },
  "production": {
    "ip": "$PROD_DB_IP",
    "reachable": $prod_reachable,
    "postgresql": {
      "running": $prod_pg_running,
      "database_count": $prod_pg_db_count,
      "ssl": "$prod_pg_ssl"
    },
    "pgbouncer": {
      "running": $prod_pgbouncer_running
    },
    "neo4j": {
      "running": $prod_neo4j_running
    }
  },
  "test": {
    "ip": "$TEST_DB_IP",
    "reachable": $test_reachable,
    "postgresql": {
      "running": $test_pg_running,
      "database_count": $test_pg_db_count,
      "ssl": "$test_pg_ssl"
    },
    "pgbouncer": {
      "running": $test_pgbouncer_running
    },
    "neo4j": {
      "running": $test_neo4j_running
    }
  },
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

    return 0
}

################################################################################
# Database Synchronization Functions
################################################################################

#=============================================================================
# Function: get_postgres_databases
# Description: Get list of PostgreSQL databases from a host
# Parameters:
#   $1 - host (user@ip format) - SSH host specification
# Returns:
#   0 - Database list retrieved successfully
#   1 - Failed to retrieve list or invalid host
# Output: One database name per line (excludes system databases)
# Example:
#   get_postgres_databases "$PROD_DB_HOST"
#=============================================================================
# SC2029: PG_BIN/PG_PORT/user are local config / validated above; the remote
# psql command is built and sent intentionally as a string.
# shellcheck disable=SC2029
get_postgres_databases() {
    local host="$1"
    local user
    user=$(echo "$host" | cut -d@ -f1)

    if [ -z "$host" ]; then
        echo "Error: Host required" >&2
        return 1
    fi

    # Validate inputs
    if ! validate_env_var_name "$user" 2>/dev/null; then
        echo "Error: Invalid user in host specification" >&2
        return 1
    fi
    if ! validate_port "$PG_PORT" 2>/dev/null; then
        echo "Error: Invalid PostgreSQL port" >&2
        return 1
    fi

    ssh "$host" "${PG_BIN}/psql -h localhost -p \"${PG_PORT}\" -U \"${user}\" -d postgres -t -c \"SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres' ORDER BY datname;\"" 2>/dev/null | tr -d ' ' || echo ""
}

#=============================================================================
# Function: copy_postgres_database
# Description: Copy a single PostgreSQL database from source to target
# Parameters:
#   $1 - dbname - Database name to copy
#   $2 - source_host (user@ip format) - Source SSH host
#   $3 - target_host (user@ip format) - Target SSH host
# Returns:
#   0 - Database copied successfully
#   1 - Copy failed (dump, transfer, or restore error)
# Example:
#   copy_postgres_database "mydb" "$PROD_DB_HOST" "$TEST_DB_HOST"
#=============================================================================
# SC2029: dbname/users/dirs are sanitized via sanitize_for_shell (printf %q)
# and PG_PORT/users are validated; remote interpolation is intentional.
# shellcheck disable=SC2029
copy_postgres_database() {
    local dbname="$1"
    local source_host="$2"
    local target_host="$3"

    if [ -z "$dbname" ] || [ -z "$source_host" ] || [ -z "$target_host" ]; then
        echo "Error: Database name, source host, and target host required" >&2
        return 1
    fi

    # Validate database name
    if ! validate_dbname "$dbname"; then
        echo "Error: Invalid database name" >&2
        return 1
    fi

    local source_user
    source_user=$(echo "$source_host" | cut -d@ -f1)
    local target_user
    target_user=$(echo "$target_host" | cut -d@ -f1)

    # Validate users
    if ! validate_env_var_name "$source_user" 2>/dev/null; then
        echo "Error: Invalid source user" >&2
        return 1
    fi
    if ! validate_env_var_name "$target_user" 2>/dev/null; then
        echo "Error: Invalid target user" >&2
        return 1
    fi
    if ! validate_port "$PG_PORT" 2>/dev/null; then
        echo "Error: Invalid PostgreSQL port" >&2
        return 1
    fi

    local dump_dir
    dump_dir="/tmp/db-copy-$(date +%Y%m%d_%H%M%S)"
    local dump_file="${dump_dir}/${dbname}.dump"

    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo -e "${DB_BLUE}Copying database: ${DB_YELLOW}${dbname}${DB_NC}"
    fi

    # Create dump on source
    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo "  → Dumping from source..."
    fi

    # Use printf %q for safe path/name escaping
    local safe_dump_dir
    safe_dump_dir=$(sanitize_for_shell "$dump_dir")
    local safe_dump_file
    safe_dump_file=$(sanitize_for_shell "$dump_file")
    local safe_dbname
    safe_dbname=$(sanitize_for_shell "$dbname")

    ssh "$source_host" "mkdir -p ${safe_dump_dir} && \"${PG_BIN}/pg_dump\" -h localhost -p \"${PG_PORT}\" -U \"${source_user}\" -d ${safe_dbname} -Fc -f ${safe_dump_file}" || {
        echo "Error: Failed to dump database $dbname from $source_host" >&2
        return 1
    }

    # Transfer dump to target
    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo "  → Transferring dump to target..."
    fi

    local safe_target_host
    safe_target_host=$(sanitize_for_shell "$target_host")

    ssh "$source_host" "scp ${safe_dump_file} ${safe_target_host}:${safe_dump_file}" || {
        echo "Error: Failed to transfer dump for $dbname" >&2
        ssh "$source_host" "rm -f ${safe_dump_file}"
        return 1
    }

    # Drop existing database on target
    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo "  → Preparing target database..."
    fi

    ssh "$target_host" "\"${PG_BIN}/psql\" -h localhost -p \"${PG_PORT}\" -U \"${target_user}\" -d postgres -c 'DROP DATABASE IF EXISTS \"${dbname}\";' 2>/dev/null || true"

    # Create fresh database on target
    ssh "$target_host" "\"${PG_BIN}/psql\" -h localhost -p \"${PG_PORT}\" -U \"${target_user}\" -d postgres -c 'CREATE DATABASE \"${dbname}\";'" || {
        echo "Error: Failed to create database $dbname on $target_host" >&2
        ssh "$source_host" "rm -f ${safe_dump_file}"
        ssh "$target_host" "rm -f ${safe_dump_file}"
        return 1
    }

    # Restore to target
    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo "  → Restoring to target..."
    fi

    ssh "$target_host" "\"${PG_BIN}/pg_restore\" -h localhost -p \"${PG_PORT}\" -U \"${target_user}\" -d \"${dbname}\" ${safe_dump_file} 2>&1 | grep -v 'WARNING:' | grep -v 'already exists' || true"

    # Cleanup
    ssh "$source_host" "rm -f ${safe_dump_file}"
    ssh "$target_host" "rm -f ${safe_dump_file}"

    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo -e "  ${DB_GREEN}✓ Database ${dbname} copied successfully${DB_NC}"
    fi

    return 0
}

#=============================================================================
# Function: sync_postgres_databases
# Description: Synchronize PostgreSQL databases from source to target
# Parameters:
#   $1 - source_host (user@ip format) - Source SSH host
#   $2 - target_host (user@ip format) - Target SSH host
# Options:
#   DATABASES_SKIP_CONFIRM=1 - Skip confirmation prompt
# Returns:
#   0 - All databases synchronized successfully
#   1 - One or more databases failed to sync
# Example:
#   sync_postgres_databases "$PROD_DB_HOST" "$TEST_DB_HOST"
#=============================================================================
sync_postgres_databases() {
    local source_host="$1"
    local target_host="$2"

    if [ -z "$source_host" ] || [ -z "$target_host" ]; then
        echo "Error: Source and target hosts required" >&2
        return 1
    fi

    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo -e "${DB_BLUE}Starting PostgreSQL database synchronization...${DB_NC}"
        echo ""
    fi

    local databases
    databases=$(get_postgres_databases "$source_host")
    local db_count
    db_count=$(echo "$databases" | wc -l | tr -d ' ')

    if [ -z "$databases" ]; then
        echo "No databases found to sync" >&2
        return 1
    fi

    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo "Found ${db_count} databases to copy"
        echo "$databases" | while IFS= read -r line; do
            echo "  - $line"
        done
        echo ""

        # Confirmation prompt (skip in JSON mode or if DATABASES_SKIP_CONFIRM is set)
        if [ "${DATABASES_SKIP_CONFIRM:-0}" != "1" ]; then
            echo -e "${DB_YELLOW}WARNING: This will OVERWRITE all databases on target!${DB_NC}"
            read -r -p "Continue? (yes/no): " confirm
            if [[ "$confirm" != "yes" ]]; then
                echo "Cancelled by user"
                return 0
            fi
            echo ""
        fi
    fi

    local count=0
    local failed=0

    while IFS= read -r dbname; do
        [[ -z "$dbname" ]] && continue

        count=$((count + 1))

        if copy_postgres_database "$dbname" "$source_host" "$target_host"; then
            if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
                echo "[$count/$db_count] $dbname completed"
            fi
        else
            if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
                echo "[$count/$db_count] $dbname failed"
            fi
            failed=$((failed + 1))
        fi
        echo ""
    done <<< "$databases"

    if [[ $failed -eq 0 ]]; then
        if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
            echo -e "${DB_GREEN}✓ All PostgreSQL databases synchronized successfully${DB_NC}"
        fi
        return 0
    else
        if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
            echo -e "${DB_YELLOW}⚠ $failed database(s) failed to sync${DB_NC}"
        fi
        return 1
    fi
}

#=============================================================================
# Function: sync_neo4j_database
# Description: Synchronize Neo4j database from source to target (stops services)
# Parameters:
#   $1 - source_host (user@ip format) - Source SSH host
#   $2 - target_host (user@ip format) - Target SSH host
# Returns:
#   0 - Neo4j database synchronized successfully
#   1 - Synchronization failed
# Note: Neo4j services are stopped during sync and restarted afterward
# Example:
#   sync_neo4j_database "$PROD_DB_HOST" "$TEST_DB_HOST"
#=============================================================================
# SC2029: NEO4J_DATA_DIR is validated via validate_path; safe_neo4j_dir and
# safe_target_host go through sanitize_for_shell. Remote-side interpolation
# is intentional after that validation.
# shellcheck disable=SC2029
sync_neo4j_database() {
    local source_host="$1"
    local target_host="$2"

    if [ -z "$source_host" ] || [ -z "$target_host" ]; then
        echo "Error: Source and target hosts required" >&2
        return 1
    fi

    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo -e "${DB_BLUE}Starting Neo4j database synchronization...${DB_NC}"
        echo ""
    fi

    # Stop Neo4j on both hosts
    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo "Stopping Neo4j instances..."
    fi

    if ! ssh "$source_host" "brew services stop neo4j" >/dev/null 2>&1; then
        echo "WARNING: Failed to stop Neo4j on source (may not be running)" >&2
    fi
    if ! ssh "$target_host" "brew services stop neo4j" >/dev/null 2>&1; then
        echo "WARNING: Failed to stop Neo4j on target (may not be running)" >&2
    fi
    sleep 3

    # Backup existing data on target
    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo "Backing up existing target data..."
    fi

    ssh "$target_host" "if [ -d \"$NEO4J_DATA_DIR\" ]; then mv \"$NEO4J_DATA_DIR\" \"${NEO4J_DATA_DIR}.backup.\$(date +%Y%m%d_%H%M%S)\"; fi" || {
        echo "Error: Failed to backup Neo4j data on target" >&2
        # Restart Neo4j services
        ssh "$source_host" "brew services start neo4j" >/dev/null 2>&1
        ssh "$target_host" "brew services start neo4j" >/dev/null 2>&1
        return 1
    }

    # Copy data from source to target
    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo "Copying Neo4j data from source to target..."
    fi

    # Validate and sanitize NEO4J_DATA_DIR path
    if ! validate_path "$NEO4J_DATA_DIR"; then
        echo "Error: Invalid Neo4j data directory path" >&2
        return 1
    fi

    local safe_neo4j_dir
    safe_neo4j_dir=$(sanitize_for_shell "$NEO4J_DATA_DIR")

    ssh "$source_host" "tar czf /tmp/neo4j-data.tar.gz -C \"\$(dirname ${safe_neo4j_dir})\" \"\$(basename ${safe_neo4j_dir})\"" || {
        echo "Error: Failed to create Neo4j archive on source" >&2
        ssh "$source_host" "brew services start neo4j" >/dev/null 2>&1
        ssh "$target_host" "brew services start neo4j" >/dev/null 2>&1
        return 1
    }

    local safe_target_host
    safe_target_host=$(sanitize_for_shell "$target_host")

    if ! ssh "$source_host" "scp /tmp/neo4j-data.tar.gz ${safe_target_host}:/tmp/"; then
        echo "ERROR: Failed to transfer Neo4j data from source to target" >&2
        ssh "$source_host" "rm -f /tmp/neo4j-data.tar.gz"
        ssh "$source_host" "brew services start neo4j" >/dev/null 2>&1
        ssh "$target_host" "brew services start neo4j" >/dev/null 2>&1
        return 1
    fi

    local target_user
    target_user=$(echo "$target_host" | cut -d@ -f1)

    # Validate target user
    if ! validate_env_var_name "$target_user" 2>/dev/null; then
        echo "Error: Invalid target user" >&2
        return 1
    fi

    ssh "$target_host" "mkdir -p \"\$(dirname ${safe_neo4j_dir})\" && tar xzf /tmp/neo4j-data.tar.gz -C \"\$(dirname ${safe_neo4j_dir})\"" || {
        echo "Error: Failed to extract Neo4j data on target" >&2
        ssh "$source_host" "rm -f /tmp/neo4j-data.tar.gz"
        ssh "$target_host" "rm -f /tmp/neo4j-data.tar.gz"
        ssh "$source_host" "brew services start neo4j" >/dev/null 2>&1
        ssh "$target_host" "brew services start neo4j" >/dev/null 2>&1
        return 1
    }

    # Fix permissions on target
    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo "Fixing permissions..."
    fi

    ssh "$target_host" "chown -R \"${target_user}:staff\" ${safe_neo4j_dir}" || {
        echo "Warning: Failed to fix permissions on target" >&2
    }

    # Restart Neo4j on both hosts
    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo "Starting Neo4j instances..."
    fi

    ssh "$source_host" "brew services start neo4j" >/dev/null 2>&1
    ssh "$target_host" "brew services start neo4j" >/dev/null 2>&1
    sleep 5

    # Cleanup
    ssh "$source_host" "rm -f /tmp/neo4j-data.tar.gz" >/dev/null 2>&1
    ssh "$target_host" "rm -f /tmp/neo4j-data.tar.gz" >/dev/null 2>&1

    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo -e "${DB_GREEN}✓ Neo4j database synchronized successfully${DB_NC}"
    fi

    return 0
}

#=============================================================================
# Function: sync_databases
# Description: Synchronize all databases (PostgreSQL and Neo4j) from source to target
# Parameters:
#   $1 - source_host (user@ip format) - Source SSH host
#   $2 - target_host (user@ip format) - Target SSH host
#   $3 - options - "--postgres-only", "--neo4j-only", or "" for both
# Returns:
#   0 - All selected databases synchronized successfully
#   1 - One or more databases failed to sync
# Example:
#   sync_databases "$PROD_DB_HOST" "$TEST_DB_HOST" ""
#=============================================================================
sync_databases() {
    local source_host="$1"
    local target_host="$2"
    local options="${3:-}"

    if [ -z "$source_host" ] || [ -z "$target_host" ]; then
        echo "Error: Source and target hosts required" >&2
        return 1
    fi

    local sync_postgres=1
    local sync_neo4j=1

    case "$options" in
        --postgres-only)
            sync_neo4j=0
            ;;
        --neo4j-only)
            sync_postgres=0
            ;;
        "")
            # Sync both
            ;;
        *)
            echo "Error: Invalid option '$options'. Use --postgres-only or --neo4j-only" >&2
            return 1
            ;;
    esac

    local failed=0

    if [ $sync_postgres -eq 1 ]; then
        if ! sync_postgres_databases "$source_host" "$target_host"; then
            failed=1
        fi
    fi

    if [ $sync_neo4j -eq 1 ]; then
        if [ $sync_postgres -eq 1 ] && [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
            echo ""
            echo -e "${DB_BLUE}═══════════════════════════════════════════${DB_NC}"
            echo ""
        fi

        if ! sync_neo4j_database "$source_host" "$target_host"; then
            failed=1
        fi
    fi

    return $failed
}

################################################################################
# Test Database Setup Functions
################################################################################

#=============================================================================
# Function: setup_test_databases
# Description: Set up test databases on a specific host
# Parameters:
#   $1 - target_host (user@ip format) - Target SSH host
# Returns:
#   0 - Test environment ready for synchronization
#   1 - One or more required services not running
# Note: Verifies PostgreSQL, Neo4j, and optionally PgBouncer are running
# Example:
#   setup_test_databases "$TEST_DB_HOST"
#=============================================================================
setup_test_databases() {
    local target_host="$1"

    if [ -z "$target_host" ]; then
        echo "Error: Target host required" >&2
        return 1
    fi

    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo -e "${DB_BLUE}=== Setting up test databases ===${DB_NC}"
        echo ""
        echo "Target: $target_host"
        echo ""
    fi

    # Verify PostgreSQL is running
    if ! check_postgres_status "$target_host"; then
        echo "Error: PostgreSQL is not running on $target_host" >&2
        echo "Start PostgreSQL first: ssh $target_host 'brew services start postgresql@18'"
        return 1
    fi

    # Verify Neo4j is running
    if ! check_neo4j_status "$target_host"; then
        echo "Error: Neo4j is not running on $target_host" >&2
        echo "Start Neo4j first: ssh $target_host 'brew services start neo4j'"
        return 1
    fi

    # Verify PgBouncer is running
    if ! check_pgbouncer_status "$target_host"; then
        echo "Warning: PgBouncer is not running on $target_host" >&2
        echo "You may want to start it: ssh $target_host 'pgbouncer -d /opt/homebrew/etc/pgbouncer.ini'"
    fi

    if [ "${JSON_OUTPUT_MODE:-0}" != "1" ]; then
        echo -e "${DB_GREEN}✓ All database services are running${DB_NC}"
        echo ""
        echo "Test environment is ready for database synchronization."
        echo "To sync databases from production to test, run:"
        echo "  portoser databases sync --source prod --target test"
    fi

    return 0
}

################################################################################
# Utility Functions
################################################################################

#=============================================================================
# Function: resolve_database_host
# Description: Convert host shorthand to full host specification
# Parameters:
#   $1 - host - Shorthand or full host specification
# Returns:
#   0 - Full host specification printed to stdout
#   1 - Never fails (returns full host as-is if not recognized)
# Output: Full host specification in user@ip format
# Example:
#   full_host=$(resolve_database_host "prod")
#=============================================================================
resolve_database_host() {
    local host="$1"

    case "$host" in
        prod|production)
            echo "$PROD_DB_HOST"
            ;;
        test|testing)
            echo "$TEST_DB_HOST"
            ;;
        *)
            # Assume it's already a full host specification
            echo "$host"
            ;;
    esac
}

# Export functions for use in other scripts
export -f check_database_mode
export -f switch_database_mode
export -f show_database_status
export -f verify_database_switch
export -f sync_databases
export -f setup_test_databases
export -f resolve_database_host
