#!/usr/bin/env bash
# caddy.sh - Functions for managing Caddy configuration

set -euo pipefail

# Check if Caddy is running
# Usage: check_caddy_running
check_caddy_running() {
    local caddy_admin
    caddy_admin=$(get_caddy_admin_endpoint)
    if curl -s -f "$caddy_admin/config/" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Get current Caddy configuration
# Usage: get_caddy_config
get_caddy_config() {
    if ! check_caddy_running; then
        echo "Error: Caddy is not running or Admin API is not accessible" >&2
        return 1
    fi

    local caddy_admin
    caddy_admin=$(get_caddy_admin_endpoint)
    curl -s "$caddy_admin/config/" | jq '.'
}

# Get Caddy route ID for a service
# Usage: get_caddy_route_id SERVICE_NAME
# Returns: Route ID (the @id value from Caddy config)
get_caddy_route_id() {
    local service="$1"
    local caddy_admin
    caddy_admin=$(get_caddy_admin_endpoint)
    local caddy_host
    caddy_host=$(get_registry_value ".caddy.ingress_host")
    local ssh_user
    ssh_user=$(get_registry_value ".hosts.${caddy_host}.ssh_user")
    local caddy_ip
    caddy_ip=$(get_machine_ip "$caddy_host")

    # Admin API is localhost-only, so we need to SSH to the Caddy host
    local route_id
    route_id=$(ssh "${ssh_user}@${caddy_ip}" \
        "curl -s http://127.0.0.1:2019/config/apps/http/servers/srv0/routes" | \
        jq -r ".[] | select(.[\"@id\"] == \"$service\") | .[\"@id\"]")

    if [ -n "$route_id" ] && [ "$route_id" != "null" ]; then
        echo "$route_id"
        return 0
    else
        return 1
    fi
}

# Update Caddy upstream via Admin API (zero-downtime)
# Usage: update_caddy_upstream_api SERVICE_NAME IP:PORT
# SC2029: $service / $upstream are interpolated into the remote curl command
# intentionally; the registry is the source of truth and these values are
# constrained by the same validation that gates registry edits.
# shellcheck disable=SC2029
update_caddy_upstream_api() {
    local service="$1"
    local new_upstream="$2"

    if [ -z "$service" ] || [ -z "$new_upstream" ]; then
        echo "Error: Service name and upstream (IP:PORT) required" >&2
        return 1
    fi

    local caddy_host
    caddy_host=$(get_registry_value ".caddy.ingress_host")
    local ssh_user
    ssh_user=$(get_registry_value ".hosts.${caddy_host}.ssh_user")
    local caddy_ip
    caddy_ip=$(get_machine_ip "$caddy_host")

    echo "Updating Caddy route via Admin API..."
    echo "  Service: $service"
    echo "  New upstream: $new_upstream"

    # Update via Admin API (SSH to Caddy host since API is localhost-only).
    # We don't care about the response body; only the ssh exit code.
    if ! ssh "${ssh_user}@${caddy_ip}" \
        "curl -sf -X PATCH \
        http://127.0.0.1:2019/config/apps/http/servers/srv0/routes/@id:${service}/handle/0/upstreams/0 \
        -H 'Content-Type: application/json' \
        -d '{\"dial\": \"${new_upstream}\"}'" >/dev/null; then
        echo "Error: Failed to update route via Admin API" >&2
        return 1
    fi

    # Verify update
    sleep 1
    local current_upstream
    current_upstream=$(ssh "${ssh_user}@${caddy_ip}" \
        "curl -s http://127.0.0.1:2019/config/apps/http/servers/srv0/routes/@id:${service}" | \
        jq -r '.handle[0].upstreams[0].dial')

    if [ "$current_upstream" = "$new_upstream" ]; then
        echo "✓ Caddy route updated successfully (zero-downtime)"
        echo "  Verified: $service now routes to $current_upstream"
        return 0
    else
        echo "✗ Route update verification failed" >&2
        echo "  Expected: $new_upstream" >&2
        echo "  Got: $current_upstream" >&2
        return 1
    fi
}

# Add new Caddy route via Admin API
# Usage: add_caddy_route SERVICE_NAME HOSTNAME IP:PORT
# SC2029: $route_json is built locally (heredoc) and intentionally
# interpolated into the remote curl POST body.
# shellcheck disable=SC2029
add_caddy_route() {
    local service="$1"
    local hostname="$2"
    local upstream="$3"

    if [ -z "$service" ] || [ -z "$hostname" ] || [ -z "$upstream" ]; then
        echo "Error: Service name, hostname, and upstream required" >&2
        return 1
    fi

    local caddy_host
    caddy_host=$(get_registry_value ".caddy.ingress_host")
    local ssh_user
    ssh_user=$(get_registry_value ".hosts.${caddy_host}.ssh_user")
    local caddy_ip
    caddy_ip=$(get_machine_ip "$caddy_host")

    echo "Adding new Caddy route via Admin API..."
    echo "  Service: $service"
    echo "  Hostname: $hostname"
    echo "  Upstream: $upstream"

    # Create route JSON
    local route_json
    route_json=$(cat <<EOF
{
  "@id": "${service}",
  "match": [{"host": ["${hostname}"]}],
  "handle": [{
    "handler": "reverse_proxy",
    "upstreams": [{"dial": "${upstream}"}],
    "health_checks": {
      "active": {
        "uri": "/health",
        "interval": "10s",
        "timeout": "5s"
      }
    }
  }]
}
EOF
)

    # Add route via Admin API. -f makes curl exit non-zero on HTTP 4xx/5xx so
    # ssh's exit code reflects the API call's actual outcome (the previous
    # version would silently accept a 404 from the Admin API as success).
    if ssh "${ssh_user}@${caddy_ip}" \
        "curl -sf -X POST \
        http://127.0.0.1:2019/config/apps/http/servers/srv0/routes \
        -H 'Content-Type: application/json' \
        -d '${route_json}'"; then
        echo "✓ Route added successfully"
        return 0
    fi
    echo "✗ Failed to add route" >&2
    return 1
}

# Update Caddy route for a service using Admin API
# Usage: update_caddy_route SERVICE_NAME
update_caddy_route() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    if ! check_caddy_running; then
        echo "Error: Caddy is not running or Admin API is not accessible" >&2
        echo "  Trying to reload Caddyfile instead..." >&2
        reload_caddyfile
        return $?
    fi

    # Get service information. Only get_machine_ip can fail; the others fall
    # back to defaults. The previous "if [ $? -ne 0 ]" after the 4-call block
    # only inspected the *last* assignment, so an unknown host silently
    # produced an empty IP.
    local current_host
    current_host=$(get_service_host "$service")
    local port
    port=$(get_service_port "$service")
    local ip
    if ! ip=$(get_machine_ip "$current_host"); then
        echo "Error: Could not resolve IP for host '$current_host' (service '$service')" >&2
        return 1
    fi
    local hostname
    hostname=$(get_service_hostname "$service")

    echo "Updating Caddy route for $service:"
    echo "  Hostname: $hostname"
    echo "  Backend: $ip:$port"

    # Check if we should use Admin API
    local use_admin_api
    use_admin_api=$(get_registry_value ".caddy.use_admin_api" 2>/dev/null || echo "false")

    if [ "$use_admin_api" = "true" ]; then
        echo "  Method: Admin API (zero-downtime)"
        # Try Admin API first
        if update_caddy_upstream_api "$service" "$ip:$port"; then
            return 0
        else
            echo "  Admin API update failed, falling back to Caddyfile reload..." >&2
        fi
    else
        echo "  Method: Caddyfile reload"
    fi

    # Fallback to Caddyfile regenerate + reload
    local caddyfile_path="${CADDYFILE_PATH:-${HOME}/portoser/caddy/Caddyfile}"

    echo "  Regenerating Caddyfile from registry..."
    if ! save_caddyfile "$caddyfile_path"; then
        echo "✗ Failed to regenerate Caddyfile" >&2
        return 1
    fi

    echo "  Reloading Caddy configuration..."
    if reload_caddyfile; then
        echo "✓ Caddy route updated via Caddyfile regenerate + reload"

        # Verify routing actually works
        if verify_caddy_routing "$service"; then
            echo "✓ Caddy routing verified working"
            return 0
        else
            echo "⚠  Caddy updated but routing verification failed" >&2
            echo "   Service may not be accessible via hostname" >&2
            # Still return success since Caddy reload worked
            return 0
        fi
    else
        echo "✗ Failed to reload Caddy" >&2
        return 1
    fi
}

# Verify Caddy routing for a service by testing HTTP access via hostname
# Usage: verify_caddy_routing SERVICE_NAME
verify_caddy_routing() {
    local service="$1"

    if [ -z "$service" ]; then
        return 1
    fi

    # Skip verification for non-HTTP services
    case "$service" in
        postgres|pgbouncer|neo4j)
            return 0  # Can't verify HTTP for TCP services
            ;;
    esac

    [ "$DEBUG" = "1" ] && echo "Debug: Verifying Caddy routing for $service" >&2

    # Wait a moment for Caddy to fully reload
    sleep 2

    # Use the health check function that tests via hostname
    if check_service_health_via_caddy "$service" 2>/dev/null; then
        return 0
    else
        # Try once more after a brief delay
        sleep 3
        if check_service_health_via_caddy "$service" 2>/dev/null; then
            return 0
        else
            return 1
        fi
    fi
}

# Reload Caddy configuration from Caddyfile
# Usage: reload_caddyfile
reload_caddyfile() {
    local caddy_dir
    caddy_dir=$(get_caddy_config_dir)
    local caddyfile_path="${CADDYFILE_PATH:-$caddy_dir/Caddyfile}"

    if [ ! -f "$caddyfile_path" ]; then
        echo "Error: Caddyfile not found: $caddyfile_path" >&2
        return 1
    fi

    echo "Reloading Caddy configuration from Caddyfile..."

    # Validate Caddyfile first
    if ! caddy validate --config "$caddyfile_path" > /dev/null 2>&1; then
        echo "Error: Caddyfile validation failed" >&2
        caddy validate --config "$caddyfile_path"
        return 1
    fi

    # Reload Caddy
    if caddy reload --config "$caddyfile_path" > /dev/null 2>&1; then
        echo "✓ Caddy configuration reloaded successfully"
        return 0
    else
        echo "Error: Failed to reload Caddy" >&2
        return 1
    fi
}

# Validate Caddyfile
# Usage: validate_caddyfile
validate_caddyfile() {
    local caddy_dir
    caddy_dir=$(get_caddy_config_dir)
    local caddyfile_path="${CADDYFILE_PATH:-$caddy_dir/Caddyfile}"

    if [ ! -f "$caddyfile_path" ]; then
        echo "Error: Caddyfile not found: $caddyfile_path" >&2
        return 1
    fi

    echo "Validating Caddyfile..."

    if caddy validate --config "$caddyfile_path"; then
        echo "✓ Caddyfile is valid"
        return 0
    else
        echo "✗ Caddyfile validation failed"
        return 1
    fi
}

# Update Caddyfile with new service backend
# Usage: update_caddyfile_service SERVICE_NAME
update_caddyfile_service() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    local caddy_dir
    caddy_dir=$(get_caddy_config_dir)
    local caddyfile_path="${CADDYFILE_PATH:-$caddy_dir/Caddyfile}"

    # Get service information
    local current_host
    current_host=$(get_service_host "$service")
    local port
    port=$(get_service_port "$service")
    local ip
    if ! ip=$(get_machine_ip "$current_host"); then
        echo "Error: Could not resolve IP for host '$current_host' (service '$service')" >&2
        return 1
    fi
    local hostname
    hostname=$(get_service_hostname "$service")

    echo "Updating Caddyfile for service $service..."
    echo "  Hostname: $hostname"
    echo "  New backend: $ip:$port"

    # Backup Caddyfile
    cp "$caddyfile_path" "${caddyfile_path}.backup.$(date +%Y%m%d_%H%M%S)"

    # Use sed to update the reverse_proxy line for this service
    # This is a simplified approach - assumes format: "reverse_proxy http://IP:PORT"
    # Pattern: Find the service block and update the reverse_proxy line

    # Find the line with the hostname and update the next reverse_proxy line
    # This is a simple implementation - production version would be more robust
    local temp_file
    temp_file=$(mktemp)

    awk -v hostname="$hostname" -v newbackend="http://$ip:$port" '
    {
        if ($0 ~ hostname) {
            in_block = 1
            print
            next
        }
        if (in_block && $0 ~ /reverse_proxy/) {
            # Replace the reverse_proxy line (handles both http:// and https://)
            sub(/https?:\/\/[0-9.]+:[0-9]+/, newbackend)
            # Also handle localhost
            sub(/https?:\/\/localhost:[0-9]+/, newbackend)
            in_block = 0
        }
        print
    }
    ' "$caddyfile_path" > "$temp_file"

    # Check if update was successful
    if [ -s "$temp_file" ]; then
        mv "$temp_file" "$caddyfile_path"
        echo "✓ Caddyfile updated for $service"
        return 0
    else
        echo "Error: Failed to update Caddyfile" >&2
        rm -f "$temp_file"
        return 1
    fi
}

# Regenerate Caddyfile from registry (if template exists)
# Usage: regenerate_caddyfile
regenerate_caddyfile() {
    local caddy_dir
    caddy_dir=$(get_caddy_config_dir)
    local caddyfile_path="${CADDYFILE_PATH:-$caddy_dir/Caddyfile}"
    local template_file="${caddyfile_path}.template"

    if [ ! -f "$template_file" ]; then
        echo "Warning: Caddyfile template not found, skipping regeneration" >&2
        echo "  Using manual update method instead" >&2
        return 1
    fi

    echo "Regenerating Caddyfile from template..."

    # Backup current Caddyfile
    cp "$caddyfile_path" "${caddyfile_path}.backup.$(date +%Y%m%d_%H%M%S)"

    # This would need a proper templating system
    # For now, we'll just note that this is a placeholder
    echo "  Template-based regeneration not yet implemented"
    echo "  Use update_caddyfile_service instead"

    return 1
}

# Get Caddy logs for a service
# Usage: get_caddy_service_logs SERVICE_NAME [LINES]
get_caddy_service_logs() {
    local service="$1"
    local lines="${2:-50}"

    local caddy_dir
    caddy_dir=$(get_caddy_config_dir)
    local log_file="$caddy_dir/logs/${service}.log"

    if [ ! -f "$log_file" ]; then
        echo "Warning: Log file not found for service '$service'" >&2
        return 1
    fi

    tail -n "$lines" "$log_file"
}

# Update Caddy for service migration
# Usage: update_caddy_for_migration SERVICE_NAME OLD_HOST NEW_HOST
update_caddy_for_migration() {
    local service="$1"
    local old_host="$2"
    local new_host="$3"

    if [ -z "$service" ] || [ -z "$old_host" ] || [ -z "$new_host" ]; then
        echo "Error: Service name, old host, and new host required" >&2
        return 1
    fi

    echo ""
    echo "==========================================="
    echo "UPDATING CADDY ROUTING"
    echo "==========================================="
    echo "Service: $service"
    echo "Old host: $old_host"
    echo "New host: $new_host"
    echo ""

    # Option 1: Try Admin API update
    if check_caddy_running; then
        echo "Attempting Caddy Admin API update..."
        if update_caddy_route "$service"; then
            return 0
        fi
    fi

    # Option 2: Update Caddyfile and reload
    echo "Updating Caddyfile and reloading..."
    if update_caddyfile_service "$service"; then
        if validate_caddyfile; then
            if reload_caddyfile; then
                # Verify routing works
                if verify_caddy_routing "$service"; then
                    echo "✓ Caddy routing verified working"
                    return 0
                else
                    echo "⚠  Caddy updated but routing verification failed" >&2
                    return 0  # Still return success since reload worked
                fi
            else
                echo "Error: Failed to reload Caddy" >&2
                return 1
            fi
        else
            echo "Error: Caddyfile validation failed" >&2
            return 1
        fi
    fi

    echo "Error: Failed to update Caddy configuration" >&2
    return 1
}

# Check if service is accessible via Caddy
# Usage: check_caddy_proxy SERVICE_NAME
check_caddy_proxy() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    local hostname
    hostname=$(get_service_hostname "$service")

    echo "Checking Caddy proxy for $service ($hostname)..."

    if curl -f -s -m 5 "http://$hostname/health" > /dev/null 2>&1; then
        echo "✓ Service is accessible via Caddy at $hostname"
        return 0
    else
        echo "✗ Service is not accessible via Caddy at $hostname"
        return 1
    fi
}
