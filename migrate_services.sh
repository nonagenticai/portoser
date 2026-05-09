#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Service Migration Script
# Reads from registry.yml and migrates services to their designated hosts
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_FILE="${REGISTRY_FILE:-$SCRIPT_DIR/registry.yml}"
# Fall back to the bundled example registry if the user has not yet copied it.
[[ -f "$REGISTRY_FILE" ]] || REGISTRY_FILE="$SCRIPT_DIR/registry.example.yml"
LOCAL_HOSTNAME=$(hostname -s)

# =============================================================================
# CLUSTER TOPOLOGY
# =============================================================================
# Host map (CLUSTER_HOSTS), per-host paths (CLUSTER_PATHS) and per-host
# architecture (CLUSTER_ARCH) are loaded from cluster.conf. See
# cluster.conf.example for the expected format.
CLUSTER_CONF="${CLUSTER_CONF:-$SCRIPT_DIR/cluster.conf}"
if [[ ! -f "$CLUSTER_CONF" ]]; then
    echo "ERROR: cluster.conf not found at $CLUSTER_CONF" >&2
    echo "       Copy cluster.conf.example to cluster.conf and edit for your environment." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CLUSTER_CONF"

# =============================================================================
# STARTUP VALIDATION CHECKS
# =============================================================================

# Source validation module if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/lib/cluster/validation.sh" ]; then
    source "$SCRIPT_DIR/lib/cluster/validation.sh"

    # Run startup validation checks
    echo ""
    validate_bash_version || exit 1
    validate_required_commands || exit 1
    echo ""
fi

# =============================================================================
# SSH KEY AUTHENTICATION MODULE
# =============================================================================

# Source SSH key authentication module for secure cluster operations
# This provides SSH key-based authentication functions and eliminates password usage
if [ -f "$SCRIPT_DIR/lib/cluster/ssh_keys.sh" ]; then
    source "$SCRIPT_DIR/lib/cluster/ssh_keys.sh"
fi

# =============================================================================
# SSH AUTHENTICATION - SECURITY NOTICE
# =============================================================================
# This script uses SSH KEY-BASED AUTHENTICATION ONLY.
# SSH keys must be configured for all hosts in cluster.conf before running.
# See lib/cluster/ssh_key_setup.sh, or manually `ssh-copy-id user@host`.
# =============================================================================

# Hosts to search when locating an existing copy of a service to migrate.
# Override by exporting SOURCE_HOSTS as a space-separated list, otherwise
# defaults to every key in CLUSTER_HOSTS.
if [[ -z "${SOURCE_HOSTS:-}" ]]; then
    SOURCE_HOSTS=("${!CLUSTER_HOSTS[@]}")
else
    # SOURCE_HOSTS arrives from the environment as a space-separated string
    # (env vars cannot be exported as arrays). Word-split into the array.
    # shellcheck disable=SC2206,SC2128
    SOURCE_HOSTS=($SOURCE_HOSTS)
fi

# Global array to track service failures
declare -a FAILED_SERVICES=()

# =============================================================================
# FUNCTIONS
# =============================================================================

# Track a service failure
track_service_failure() {
    local service_name="$1"
    local reason="$2"

    FAILED_SERVICES+=("$service_name|$reason")
    echo "  ⚠️  Tracked failure: $service_name - $reason"
}

# Report all failed services at the end
report_failed_services() {
    if [ ${#FAILED_SERVICES[@]} -eq 0 ]; then
        return 0
    fi

    echo ""
    echo "=========================================="
    echo "⚠️  FAILED SERVICES SUMMARY"
    echo "=========================================="
    echo ""
    echo "The following services encountered errors during migration:"
    echo ""

    local failure_num=1
    for failure in "${FAILED_SERVICES[@]}"; do
        # Parse failure entry: service|reason
        IFS='|' read -r svc_name svc_reason <<< "$failure"

        echo "  $failure_num. $svc_name"
        echo "     Reason: $svc_reason"
        echo ""

        failure_num=$((failure_num + 1))
    done

    echo "Total failures: ${#FAILED_SERVICES[@]}"
    echo ""

    return 1
}

get_service_info() {
    local service_name="$1"

    # Extract current_host and service path for this service
    awk -v service="$service_name" '
        $0 ~ "^  " service ":" { found=1; next }
        found && /^  [a-z]/ { found=0 }
        found && /current_host:/ { gsub(/^[ \t]+current_host:[ \t]+/, ""); print "target_host=" $0 }
        found && /docker_compose:/ { gsub(/^[ \t]+docker_compose:[ \t]+/, ""); print "service_path=" $0 }
        found && /service_file:/ { gsub(/^[ \t]+service_file:[ \t]+/, ""); print "service_path=" $0 }
    ' "$REGISTRY_FILE"
}

check_remote_dir() {
    local host="$1"
    local full_path="$2"

    # OPTIMIZATION: If checking local machine, use direct filesystem check
    if [ "$host" = "$LOCAL_HOSTNAME" ]; then
        if [ -d "$full_path" ] && [ "$(ls -A "$full_path" 2>/dev/null)" ]; then
            echo "EXISTS"
        else
            echo "EMPTY"
        fi
        return 0
    fi

    # Remote check via SSH (using key-based authentication)
    local ssh_host="${CLUSTER_HOSTS[$host]}"

    # Check if directory exists and has content
    result=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "$ssh_host" \
        "if [ -d '$full_path' ] && [ \"\$(ls -A '$full_path' 2>/dev/null)\" ]; then echo 'EXISTS'; else echo 'EMPTY'; fi" 2>/dev/null)

    echo "$result"
}

find_service_source() {
    local service_path="$1"

    # Search through likely source hosts to find where the service currently exists
    for source_host in "${SOURCE_HOSTS[@]}"; do
        local full_path="${CLUSTER_PATHS[$source_host]}${service_path}"
        local status
        status=$(check_remote_dir "$source_host" "$full_path")

        if [ "$status" = "EXISTS" ]; then
            echo "$source_host"
            return 0
        fi
    done

    echo ""
    return 1
}

copy_service() {
    local service_name="$1"
    local source_host="$2"
    local target_host="$3"
    local service_path="$4"  # e.g., /grafana

    local source_user_host="${CLUSTER_HOSTS[$source_host]}"
    local target_user_host="${CLUSTER_HOSTS[$target_host]}"

    local source_base="${CLUSTER_PATHS[$source_host]}"
    local target_base="${CLUSTER_PATHS[$target_host]}"

    local source_full="${source_base}${service_path}"
    local target_full="${target_base}${service_path}"

    echo "     📦 Copying $service_name: $source_host → $target_host"
    echo "        Source: $source_full"
    echo "        Target: $target_full"

    local parent_dir
    parent_dir=$(dirname "$target_full")

    # OPTIMIZATION: If source is local, stream directly to remote target
    if [ "$source_host" = "$LOCAL_HOSTNAME" ]; then
        echo "        🚀 Streaming from local to remote..."
        ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$target_user_host" \
            "mkdir -p '$parent_dir'" || {
            echo "        ❌ Failed to create target directory"
            track_service_failure "$service_name" "Failed to create target directory"
            return 1
        }

        tar czf - --no-xattrs --no-acls -C "$(dirname "$source_full")" "$(basename "$source_full")" | \
        ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$target_user_host" \
            "tar xzf - -C '$parent_dir'" || {
            echo "        ❌ Failed to copy service"
            track_service_failure "$service_name" "Failed to copy service from $source_host to $target_host"
            return 1
        }

        echo "        ✅ Copied successfully"
        return 0
    fi

    # OPTIMIZATION: If target is local, stream from remote to local
    if [ "$target_host" = "$LOCAL_HOSTNAME" ]; then
        echo "        🚀 Streaming from remote to local..."
        mkdir -p "$parent_dir" || {
            echo "        ❌ Failed to create target directory"
            track_service_failure "$service_name" "Failed to create target directory"
            return 1
        }

        ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$source_user_host" \
            "tar czf - --no-xattrs --no-acls -C '$(dirname "$source_full")' '$(basename "$source_full")'" | \
        tar xzf - -C "$parent_dir" || {
            echo "        ❌ Failed to copy service"
            track_service_failure "$service_name" "Failed to copy service from $source_host to $target_host"
            return 1
        }

        echo "        ✅ Copied successfully"
        return 0
    fi

    # Remote-to-remote: stream through local machine
    echo "        🔄 Streaming remote → local → remote..."

    # Create parent directory on target
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$target_user_host" \
        "mkdir -p '$parent_dir'" || {
        echo "        ❌ Failed to create target directory"
        track_service_failure "$service_name" "Failed to create target directory"
        return 1
    }

    # Stream from source through local to target
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$source_user_host" \
        "tar czf - --no-xattrs --no-acls -C '$(dirname "$source_full")' '$(basename "$source_full")'" | \
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$target_user_host" \
        "tar xzf - -C '$parent_dir'" || {
        echo "        ❌ Failed to copy service"
        track_service_failure "$service_name" "Failed to copy service from $source_host to $target_host"
        return 1
    }

    echo "        ✅ Copied successfully"
    return 0
}

# =============================================================================
# MAIN SCRIPT
# =============================================================================

echo "🚀 Service Migration Script"
echo "============================"
echo ""
echo "📖 Reading registry from: $REGISTRY_FILE"
echo "📍 Running on: $LOCAL_HOSTNAME"
echo ""

# Verify registry file exists
if [ ! -f "$REGISTRY_FILE" ]; then
    echo "❌ Error: Registry file not found: $REGISTRY_FILE"
    exit 1
fi

# Get all service names from registry (FIXED AWK PATTERN)
SERVICE_NAMES=$(awk '
/^services:/ { in_services=1; next }
in_services && /^[a-z]+:/ { in_services=0 }
in_services && /^  [a-z][a-z0-9_-]+:$/ {
    gsub(/:/, "", $1)
    gsub(/^[ \t]+/, "", $1)
    print $1
}' "$REGISTRY_FILE")

TOTAL_SERVICES=$(echo "$SERVICE_NAMES" | wc -l | xargs)
echo "📋 Found $TOTAL_SERVICES services in registry"
echo ""

MIGRATED=0
SKIPPED=0
ERRORS=0

for service in $SERVICE_NAMES; do
    echo "🔍 Processing: $service"

    # Get service info from registry
    unset target_host service_path
    eval "$(get_service_info "$service")"

    # Skip if no target or path found
    if [ -z "$target_host" ] || [ -z "$service_path" ]; then
        echo "   ⚠️  Missing target_host or service_path in registry - skipping"
        ((SKIPPED++)) || true
        echo ""
        continue
    fi

    # Extract directory from path (e.g., /grafana/docker-compose.yml → /grafana)
    service_dir=$(dirname "$service_path")

    echo "   Target host: $target_host"
    echo "   Service dir: $service_dir"

    # Check if service already exists at target with content
    target_full_path="${CLUSTER_PATHS[$target_host]}${service_dir}"
    target_status=$(check_remote_dir "$target_host" "$target_full_path")

    if [ "$target_status" = "EXISTS" ]; then
        echo "   ✅ Already exists at target with content - skipping"
        ((SKIPPED++)) || true
        echo ""
        continue
    fi

    # Target is empty/missing, need to find source and copy
    echo "   🔎 Target empty/missing, searching for source..."

    source_host=$(find_service_source "$service_dir")

    if [ -z "$source_host" ]; then
        echo "   ❌ Could not find service on any source host"
        ((ERRORS++)) || true
        echo ""
        continue
    fi

    echo "   📍 Found on: $source_host"

    # Skip if source and target are the same
    if [ "$source_host" = "$target_host" ]; then
        echo "   ℹ️  Source and target are the same - skipping"
        ((SKIPPED++)) || true
        echo ""
        continue
    fi

    # Perform the migration
    if copy_service "$service" "$source_host" "$target_host" "$service_dir"; then
        ((MIGRATED++)) || true
    else
        ((ERRORS++)) || true
    fi

    echo ""
done

# Report any failed services before final summary
if ! report_failed_services; then
    exit 1
fi

echo "============================"
echo "📊 Summary:"
echo "   Total services: $TOTAL_SERVICES"
echo "   Migrated: $MIGRATED"
echo "   Skipped: $SKIPPED"
echo "   Errors: $ERRORS"
echo ""

if [ $MIGRATED -gt 0 ]; then
    echo "✅ Migration complete! Migrated $MIGRATED services"
elif [ "$SKIPPED" -eq "$TOTAL_SERVICES" ]; then
    echo "✅ All services already at their target locations"
else
    echo "⚠️  Migration complete with $ERRORS errors"
fi
echo ""
echo "💡 Next steps:"
echo "   1. Verify migrated services with: ./portoser status"
echo "   2. Update Caddyfile: ./portoser caddy regenerate"
echo "   3. Reload Caddy: caddy reload --config \"\${CADDYFILE_PATH:-\$HOME/portoser/caddy/Caddyfile}\""
