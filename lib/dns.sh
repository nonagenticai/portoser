#!/usr/bin/env bash
# dns.sh - Functions for DNS verification and management

set -euo pipefail

# Source security validation library. Resolve via this file's own directory
# so we don't depend on the caller having $SCRIPT_DIR set (broken under set -u).
_DNS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_DNS_LIB_DIR/utils/security_validation.sh" ]; then
    # shellcheck source=lib/utils/security_validation.sh
    source "$_DNS_LIB_DIR/utils/security_validation.sh"
fi
unset _DNS_LIB_DIR

# Check if dnsmasq is running
# Usage: check_dnsmasq_running
check_dnsmasq_running() {
    if pgrep -x dnsmasq > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Get DNS server IP from registry
# Usage: get_dns_server_ip
get_dns_server_ip() {
    local dns_ip
    dns_ip=$(get_registry_value ".dns.ingress_ip" 2>/dev/null)

    if [ "$dns_ip" = "null" ] || [ -z "$dns_ip" ]; then
        echo "${DNS_INGRESS_IP:-127.0.0.1}"  # Default
    else
        echo "$dns_ip"
    fi
}

# Test DNS resolution for a hostname
# Usage: verify_dns_resolution HOSTNAME [EXPECTED_IP]
verify_dns_resolution() {
    local hostname="$1"
    local expected_ip="$2"

    if [ -z "$hostname" ]; then
        echo "Error: Hostname required" >&2
        return 1
    fi

    # If no expected IP provided, get from registry
    if [ -z "$expected_ip" ]; then
        expected_ip=$(get_dns_server_ip)
    fi

    local dns_server
    dns_server=$(get_dns_server_ip)
    local resolved_ip
    resolved_ip=$(dig @"$dns_server" "$hostname" +short 2>/dev/null | head -1)

    if [ -z "$resolved_ip" ]; then
        echo "✗ DNS resolution failed for $hostname" >&2
        return 1
    fi

    if [ "$resolved_ip" = "$expected_ip" ]; then
        echo "✓ DNS resolves $hostname → $resolved_ip"
        return 0
    else
        echo "✗ DNS mismatch for $hostname: got $resolved_ip, expected $expected_ip" >&2
        return 1
    fi
}

# Test DNS from a specific IP (simulates remote device)
# Usage: test_dns_from_network HOSTNAME
test_dns_from_network() {
    local hostname="$1"

    if [ -z "$hostname" ]; then
        echo "Error: Hostname required" >&2
        return 1
    fi

    local dns_server
    dns_server=$(get_dns_server_ip)

    echo "Testing DNS resolution from network:"
    echo "  DNS Server: $dns_server"
    echo "  Hostname: $hostname"

    local resolved_ip
    resolved_ip=$(dig @"$dns_server" "$hostname" +short 2>/dev/null | head -1)

    if [ -n "$resolved_ip" ]; then
        echo "  ✓ Resolved to: $resolved_ip"
        return 0
    else
        echo "  ✗ Resolution failed" >&2
        return 1
    fi
}

# Verify DNS for all registered services
# Usage: verify_all_services_dns
verify_all_services_dns() {
    echo "Verifying DNS resolution for all services..."
    echo ""

    local services
    services=$(list_services)
    local all_ok=0
    local dns_server
    dns_server=$(get_dns_server_ip)

    echo "Using DNS server: $dns_server"
    echo ""

    while IFS= read -r service; do
        if [ -z "$service" ]; then
            continue
        fi

        local hostname
        hostname=$(get_service_hostname "$service")
        printf "%-30s ... " "$service ($hostname)"

        if verify_dns_resolution "$hostname" "$dns_server" 2>/dev/null; then
            echo "✓"
        else
            echo "✗ FAILED"
            all_ok=1
        fi
    done <<< "$services"

    echo ""
    if [ "$all_ok" -eq 0 ]; then
        echo "✓ All services have correct DNS resolution"
        return 0
    else
        echo "✗ Some services have DNS issues"
        return 1
    fi
}

# Show DNS status and configuration
# Usage: show_dns_status
show_dns_status() {
    echo "DNS Configuration Status"
    echo "========================================"
    echo ""

    local dns_server
    dns_server=$(get_dns_server_ip)
    local dns_host
    dns_host=$(get_registry_value ".dns.host" 2>/dev/null || echo "local")

    echo "DNS Server: $dns_server (on $dns_host)"
    echo ""

    # Check if dnsmasq is running
    echo -n "dnsmasq status: "
    if check_dnsmasq_running; then
        echo "✓ RUNNING"
    else
        echo "✗ NOT RUNNING"
    fi
    echo ""

    # Test wildcard resolution
    echo "Testing wildcard DNS (*.internal):"
    test_dns_from_network "test.internal"
    echo ""

    # Show configured services
    echo "Registered services:"
    list_services | while IFS= read -r service; do
        [ -z "$service" ] && continue
        local hostname
        hostname=$(get_service_hostname "$service")
        echo "  - $hostname"
    done
}

# Verify DNS after service migration
# Usage: verify_dns_after_migration SERVICE_NAME
verify_dns_after_migration() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    local hostname
    hostname=$(get_service_hostname "$service")
    local dns_server
    dns_server=$(get_dns_server_ip)

    echo "Verifying DNS after migration..."
    echo "  Service: $service"
    echo "  Hostname: $hostname"
    echo "  Expected IP: $dns_server"
    echo ""

    if verify_dns_resolution "$hostname" "$dns_server"; then
        return 0
    else
        echo ""
        echo "⚠️  WARNING: DNS resolution failed after migration!" >&2
        echo "   Services may not be accessible via hostname" >&2
        return 1
    fi
}

# Check if DNS is accessible from a remote machine
# Usage: test_dns_from_machine MACHINE_NAME HOSTNAME
test_dns_from_machine() {
    local machine="$1"
    local hostname="$2"

    if [ -z "$machine" ] || [ -z "$hostname" ]; then
        echo "Error: Machine name and hostname required" >&2
        return 1
    fi

    local ip
    ip=$(get_machine_ip "$machine")
    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")
    local ssh_port
    ssh_port=$(get_machine_ssh_port "$machine")
    local dns_server
    dns_server=$(get_dns_server_ip)

    # Security: Validate hostname and DNS server
    if ! validate_hostname "$hostname" "hostname"; then
        return 1
    fi

    if ! validate_ip_address "$dns_server" "dns_server"; then
        return 1
    fi

    echo "Testing DNS from $machine ($ip)..."

    # Security: Use bash -c with positional parameters
    local result
    result=$(ssh -p "$ssh_port" -o ConnectTimeout=5 "$ssh_user@$ip" -- \
        bash -c 'dig @"$1" "$2" +short 2>/dev/null | head -1' _ "$dns_server" "$hostname" 2>/dev/null)

    if [ -n "$result" ]; then
        echo "  ✓ $hostname resolves to $result on $machine"
        return 0
    else
        echo "  ✗ DNS resolution failed on $machine" >&2
        return 1
    fi
}

# Get registry value helper (uses function from registry.sh)
get_registry_value() {
    local path="$1"
    yq eval "$path" "$CADDY_REGISTRY_PATH" 2>/dev/null
}

# Test HTTP access via hostname (tests Caddy routing)
# Usage: test_http_via_hostname SERVICE_NAME
test_http_via_hostname() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    local hostname
    hostname=$(get_service_hostname "$service")

    # Pull protocol + health path from the registry where set; fall back to
    # http+/health. Services that listen on https or expose a non-standard
    # health path can configure `services.<svc>.protocol` and
    # `services.<svc>.healthcheck_path` (or supply a full URL via
    # `services.<svc>.healthcheck_url`).
    local registry_full_url
    registry_full_url=$(get_registry_value ".services.\"$service\".healthcheck_url")
    if [ -n "$registry_full_url" ] && [ "$registry_full_url" != "null" ]; then
        local health_url="$registry_full_url"
    else
        local protocol
        protocol=$(get_registry_value ".services.\"$service\".protocol")
        [ -z "$protocol" ] || [ "$protocol" = "null" ] && protocol="http"
        local health_path
        health_path=$(get_registry_value ".services.\"$service\".healthcheck_path")
        [ -z "$health_path" ] || [ "$health_path" = "null" ] && health_path="/health"
        local health_url="${protocol}://${hostname}${health_path}"
    fi

    [ "$DEBUG" = "1" ] && echo "Debug: Testing $health_url" >&2

    # Test via hostname (with -k for self-signed certs)
    if curl -k -f -s -m 5 "$health_url" > /dev/null 2>&1; then
        echo "✓ HTTP accessible via hostname: $health_url"
        return 0
    else
        echo "✗ HTTP failed via hostname: $health_url" >&2
        return 1
    fi
}

# Comprehensive DNS health check for a single service
# Usage: dns_service_health_check SERVICE_NAME
dns_service_health_check() {
    local service="$1"

    if [ -z "$service" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    local hostname
    hostname=$(get_service_hostname "$service")
    local all_passed=0

    echo "DNS Health Check for '$service' ($hostname)"
    echo "================================================"

    # Check 1: dnsmasq running
    echo -n "1. dnsmasq service: "
    if check_dnsmasq_running; then
        echo "✓ running"
    else
        echo "✗ not running"
        all_passed=1
    fi

    # Check 2: DNS resolution
    echo -n "2. DNS resolution: "
    if verify_dns_resolution "$hostname" 2>/dev/null; then
        local resolved dns_server
        dns_server=$(get_dns_server_ip)
        resolved=$(dig "@${dns_server}" "$hostname" +short 2>/dev/null | head -1)
        echo "✓ $hostname → $resolved"
    else
        echo "✗ failed"
        all_passed=1
    fi

    # Check 3: Network-wide DNS access
    echo -n "3. Network DNS access: "
    if test_dns_from_network "$hostname" > /dev/null 2>&1; then
        echo "✓ accessible"
    else
        echo "✗ failed"
        all_passed=1
    fi

    # Check 4: HTTP via hostname (skip for non-HTTP services)
    case "$service" in
        postgres|pgbouncer|neo4j)
            echo "4. HTTP via hostname: N/A (non-HTTP service)"
            ;;
        *)
            echo -n "4. HTTP via hostname: "
            if test_http_via_hostname "$service" > /dev/null 2>&1; then
                echo "✓ accessible"
            else
                echo "✗ failed"
                all_passed=1
            fi
            ;;
    esac

    echo ""
    if [ "$all_passed" -eq 0 ]; then
        echo "✓ All DNS checks passed for '$service'"
        return 0
    else
        echo "✗ Some DNS checks failed for '$service'"
        return 1
    fi
}

# Check DNS health for all services with HTTP testing
# Usage: dns_check_all_services
dns_check_all_services() {
    echo "DNS Health Check - All Services"
    echo "================================"
    echo ""

    # Check dnsmasq first
    echo -n "dnsmasq service: "
    if check_dnsmasq_running; then
        local pid
        pid=$(pgrep -x dnsmasq | head -1)
        echo "✓ RUNNING (PID: $pid)"
    else
        echo "✗ NOT RUNNING"
        echo ""
        echo "✗ dnsmasq is not running! DNS resolution will fail."
        echo "  To fix: sudo brew services restart dnsmasq"
        return 1
    fi

    local dns_server
    dns_server=$(get_dns_server_ip)
    echo "DNS Server: $dns_server"
    echo ""

    echo "Service DNS Resolution & HTTP Status:"
    echo "-------------------------------------"

    local services
    services=$(list_services)
    local failed=0

    while IFS= read -r service; do
        if [ -z "$service" ]; then
            continue
        fi

        local hostname
        hostname=$(get_service_hostname "$service")
        printf "%-25s " "$service"

        # Test DNS resolution
        local resolved
        resolved=$(dig @"$dns_server" "$hostname" +short 2>/dev/null | head -1)
        if [ -n "$resolved" ]; then
            printf "%-18s " "$resolved"

            # Test HTTP if applicable
            case "$service" in
                postgres|pgbouncer|neo4j)
                    echo "(non-HTTP)"
                    ;;
                *)
                    if test_http_via_hostname "$service" > /dev/null 2>&1; then
                        echo "✓"
                    else
                        echo "✗ (HTTP failed)"
                        failed=$((failed + 1))
                    fi
                    ;;
            esac
        else
            echo "✗ (DNS failed)"
            failed=$((failed + 1))
        fi
    done <<< "$services"

    echo ""
    if [ "$failed" -eq 0 ]; then
        echo "✓ All DNS checks passed"
        return 0
    else
        echo "✗ $failed service(s) failed DNS checks"
        return 1
    fi
}

# Show comprehensive DNS configuration
# Usage: show_dns_config
show_dns_config() {
    echo "DNS Configuration Summary"
    echo "========================="
    echo ""

    echo "dnsmasq Status:"
    if check_dnsmasq_running; then
        local pid
        pid=$(pgrep -x dnsmasq | head -1)
        echo "  Service: ✓ RUNNING (PID: $pid)"
    else
        echo "  Service: ✗ NOT RUNNING"
    fi
    echo "  Config: /opt/homebrew/etc/dnsmasq.conf"
    echo "  DNS Server IP: $(get_dns_server_ip)"
    echo ""

    echo "DNS Configuration:"
    if [ -f "/opt/homebrew/etc/dnsmasq.conf" ]; then
        echo "  Listen Addresses:"
        grep "^listen-address=" /opt/homebrew/etc/dnsmasq.conf 2>/dev/null | sed 's/^/    /'
        echo ""
        echo "  Wildcard Rule:"
        grep "^address=/internal/" /opt/homebrew/etc/dnsmasq.conf 2>/dev/null | sed 's/^/    /'
    else
        echo "  ✗ Config file not found!"
    fi

    echo ""
    echo "Resolver Configuration (macOS):"
    if [ -f "/etc/resolver/internal" ]; then
        echo "  ✓ /etc/resolver/internal exists"
        sed 's/^/    /' /etc/resolver/internal 2>/dev/null
    else
        echo "  ⚠  /etc/resolver/internal not found"
        echo "    Create it with:"
        echo "      sudo mkdir -p /etc/resolver"
        echo "      echo 'nameserver 127.0.0.1' | sudo tee /etc/resolver/internal"
    fi

    echo ""
    echo "Network-Wide Access:"
    echo "  Status: dnsmasq is listening on $(get_dns_server_ip)"
    echo "  To enable access from other devices:"
    echo "    1. Configure your router's DHCP settings"
    echo "    2. Add $(get_dns_server_ip) as a DNS server"
    echo "    3. Devices will auto-discover on next DHCP renewal"
    echo ""
    echo "  Alternative (Manual):"
    echo "    Configure each device to use $(get_dns_server_ip) as DNS server"
    echo ""
}

# Sync DNS configuration from registry
# Usage: sync_dns_from_registry [--dry-run]
# Generates /opt/homebrew/etc/dnsmasq.d/services.conf from registry.yml
sync_dns_from_registry() {
    local dry_run=0
    local services_conf="/opt/homebrew/etc/dnsmasq.d/services.conf"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                dry_run=1
                shift
                ;;
            *)
                echo "Error: Unknown argument: $1" >&2
                echo "Usage: sync_dns_from_registry [--dry-run]" >&2
                return 1
                ;;
        esac
    done

    # Verify registry file exists
    if [ ! -f "$CADDY_REGISTRY_PATH" ]; then
        echo "Error: Registry file not found: $CADDY_REGISTRY_PATH" >&2
        return 1
    fi

    # Verify yq is available
    if ! command -v yq &> /dev/null; then
        echo "Error: yq is not installed. Install with: brew install yq" >&2
        return 1
    fi

    echo "Syncing DNS configuration from registry..."
    echo ""

    # Build the configuration content
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local config_content="# AUTO-GENERATED - DO NOT EDIT\n"
    config_content+="# Generated: $timestamp\n"
    config_content+="# Source: $CADDY_REGISTRY_PATH\n\n"

    # Get all services from registry
    local services
    services=$(yq eval '.services | keys | .[]' "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ -z "$services" ]; then
        echo "Error: No services found in registry" >&2
        return 1
    fi

    local entry_count=0
    local error_count=0

    # Process each service
    while IFS= read -r service; do
        if [ -z "$service" ]; then
            continue
        fi

        # Security: Validate service name before using in yq query
        if ! validate_service_name "$service" "service"; then
            echo "Warning: Invalid service name '$service', skipping" >&2
            error_count=$((error_count + 1))
            continue
        fi

        # Get hostname for service
        # Security: Service name validated above, safe to use in yq query
        local hostname
        hostname=$(yq eval ".services.\"$service\".hostname" "$CADDY_REGISTRY_PATH" 2>/dev/null)

        # Get current_host for service
        local current_host
        current_host=$(yq eval ".services.\"$service\".current_host" "$CADDY_REGISTRY_PATH" 2>/dev/null)

        # Validate we got both values
        if [ "$hostname" = "null" ] || [ -z "$hostname" ]; then
            echo "Warning: No hostname found for service '$service', skipping" >&2
            error_count=$((error_count + 1))
            continue
        fi

        if [ "$current_host" = "null" ] || [ -z "$current_host" ]; then
            echo "Warning: No current_host found for service '$service', skipping" >&2
            error_count=$((error_count + 1))
            continue
        fi

        # Get ingress IP (all services route through Caddy)
        local ingress_ip
        ingress_ip=$(yq eval ".dns.ingress_ip" "$CADDY_REGISTRY_PATH" 2>/dev/null)

        if [ "$ingress_ip" = "null" ] || [ -z "$ingress_ip" ]; then
            local default_ingress_ip="${DNS_INGRESS_IP:-127.0.0.1}"
            echo "Warning: No ingress IP found in registry (dns.ingress_ip), using default ${default_ingress_ip}" >&2
            ingress_ip="${default_ingress_ip}"
        fi

        # Add entry to configuration (all services point to Caddy ingress)
        config_content+="address=/$hostname/$ingress_ip\n"
        entry_count=$((entry_count + 1))

        if [ "$dry_run" -eq 1 ]; then
            echo "  $hostname -> $ingress_ip (Caddy ingress, backend on $current_host)"
        fi
    done <<< "$services"

    echo "Found $entry_count DNS entries"

    if [ "$error_count" -gt 0 ]; then
        echo "Warning: $error_count services had errors and were skipped" >&2
    fi

    if [ "$entry_count" -eq 0 ]; then
        echo "Error: No valid DNS entries generated" >&2
        return 1
    fi

    # Dry run mode - just preview
    if [ "$dry_run" -eq 1 ]; then
        echo ""
        echo "=== DRY RUN MODE - Configuration Preview ==="
        echo -e "$config_content"
        echo "=== End of preview ==="
        echo ""
        echo "Run without --dry-run to apply changes"
        return 0
    fi

    # Create backup directory if needed
    local backup_dir="/opt/homebrew/etc/dnsmasq.d/backups"
    if [ ! -d "$backup_dir" ]; then
        sudo mkdir -p "$backup_dir"
    fi

    # Backup existing config if it exists
    if [ -f "$services_conf" ]; then
        local backup_file
        backup_file="$backup_dir/services.conf.backup.$(date +%Y%m%d_%H%M%S)"
        echo "Creating backup: $backup_file"
        sudo cp "$services_conf" "$backup_file"

        # Keep only last 10 backups. Filenames are timestamped, so ls -1t is
        # safe; portable mtime-sort via find isn't available on macOS.
        local backup_count=0
        local f
        for f in "$backup_dir"/services.conf.backup.*; do
            [ -e "$f" ] && backup_count=$((backup_count + 1))
        done
        if [ "$backup_count" -gt 10 ]; then
            echo "Cleaning old backups (keeping last 10)..."
            # shellcheck disable=SC2012  # mtime-sort needed; backup filenames are controlled
            ls -1t "$backup_dir"/services.conf.backup.* | tail -n +11 | xargs sudo rm -f
        fi
    fi

    # Ensure directory exists
    sudo mkdir -p "$(dirname "$services_conf")"

    # Write new configuration
    echo "Writing configuration to $services_conf"
    if ! echo -e "$config_content" | sudo tee "$services_conf" > /dev/null; then
        echo "Error: Failed to write configuration file" >&2
        return 1
    fi

    echo "Configuration written successfully"
    echo ""

    # Reload dnsmasq
    echo "Reloading dnsmasq..."
    if sudo /opt/homebrew/bin/brew services restart dnsmasq; then
        echo "dnsmasq reloaded successfully"
    else
        echo "Error: Failed to reload dnsmasq" >&2
        return 1
    fi

    # Wait for dnsmasq to start
    sleep 2

    # Verify dnsmasq is running
    if ! check_dnsmasq_running; then
        echo "Error: dnsmasq is not running after reload!" >&2
        return 1
    fi

    echo ""
    echo "=== Verifying DNS Resolution ==="
    echo ""

    # Test a few random services to verify DNS works
    local test_count=0
    local success_count=0
    local max_tests=5

    while IFS= read -r service; do
        if [ -z "$service" ] || [ "$test_count" -ge "$max_tests" ]; then
            continue
        fi

        local hostname
        hostname=$(yq eval ".services.$service.hostname" "$CADDY_REGISTRY_PATH" 2>/dev/null)
        local current_host
        current_host=$(yq eval ".services.$service.current_host" "$CADDY_REGISTRY_PATH" 2>/dev/null)
        local expected_ip
        expected_ip=$(yq eval ".hosts.$current_host.ip" "$CADDY_REGISTRY_PATH" 2>/dev/null)

        if [ "$hostname" = "null" ] || [ "$expected_ip" = "null" ]; then
            continue
        fi

        test_count=$((test_count + 1))

        # Test DNS resolution
        local resolved_ip
        resolved_ip=$(dig @127.0.0.1 "$hostname" +short 2>/dev/null | head -1)

        printf "  %-30s ... " "$hostname"

        if [ "$resolved_ip" = "$expected_ip" ]; then
            echo "✓ $resolved_ip"
            success_count=$((success_count + 1))
        else
            echo "✗ Expected $expected_ip, got ${resolved_ip:-FAILED}"
        fi
    done <<< "$services"

    echo ""

    if [ "$success_count" -eq "$test_count" ]; then
        echo "✓ DNS sync completed successfully - all tests passed"
        return 0
    else
        echo "⚠ DNS sync completed with warnings - $success_count/$test_count tests passed" >&2
        return 1
    fi
}

# Show differences between current DNS config and what would be generated
# Usage: diff_dns_config
diff_dns_config() {
    local current_file="/opt/homebrew/etc/dnsmasq.d/services.conf"

    if [ ! -f "$current_file" ]; then
        echo "No current DNS config found at $current_file"
        echo "Run 'portoser dns sync' to create initial configuration"
        return 0
    fi

    echo "Comparing current DNS configuration with registry..."
    echo ""

    # Generate new config to temp file
    local temp_new
    temp_new=$(mktemp)
    trap 'rm -f "$temp_new"' EXIT

    # Capture the sync output
    if ! sync_dns_from_registry --dry-run > "$temp_new" 2>&1; then
        echo "✗ Failed to generate new DNS configuration" >&2
        return 1
    fi

    # Extract just the DNS entries from both files for comparison
    local current_entries
    current_entries=$(grep "^address=" "$current_file" 2>/dev/null | sort)
    local new_entries
    new_entries=$(grep "-> " "$temp_new" | sed 's/  \(.*\) -> \(.*\) (on .*)/address=\/\1\/\2/' | sort)

    if [ "$current_entries" = "$new_entries" ]; then
        echo "✓ DNS configuration is up to date with registry.yml"
        echo ""
        echo "Current entries: $(echo "$current_entries" | wc -l | tr -d ' ')"
        return 0
    fi

    echo "Differences found between current DNS and registry:"
    echo "===================================================="
    echo ""

    # Show added entries
    local added
    added=$(comm -13 <(echo "$current_entries") <(echo "$new_entries"))
    if [ -n "$added" ]; then
        echo "ADDED (new services):"
        # shellcheck disable=SC2001  # per-line prefix; bash parameter expansion can't anchor with ^
        echo "$added" | sed 's/^/  + /'
        echo ""
    fi

    # Show removed entries
    local removed
    removed=$(comm -23 <(echo "$current_entries") <(echo "$new_entries"))
    if [ -n "$removed" ]; then
        echo "REMOVED (services no longer in registry):"
        # shellcheck disable=SC2001  # per-line prefix; bash parameter expansion can't anchor with ^
        echo "$removed" | sed 's/^/  - /'
        echo ""
    fi

    # Show changed entries (same service, different IP)
    local current_services
    current_services=$(echo "$current_entries" | sed 's/address=\/\([^\/]*\)\/.*/\1/' | sort)
    local new_services
    new_services=$(echo "$new_entries" | sed 's/address=\/\([^\/]*\)\/.*/\1/' | sort)
    local common_services
    common_services=$(comm -12 <(echo "$current_services") <(echo "$new_services"))

    local has_changes=0
    while IFS= read -r service; do
        [ -z "$service" ] && continue
        local current_ip
        current_ip=$(echo "$current_entries" | grep "address=/$service/" | sed 's/.*\/\([0-9.]*\)/\1/')
        local new_ip
        new_ip=$(echo "$new_entries" | grep "address=/$service/" | sed 's/.*\/\([0-9.]*\)/\1/')

        if [ "$current_ip" != "$new_ip" ]; then
            if [ $has_changes -eq 0 ]; then
                echo "CHANGED (service moved to different host):"
                has_changes=1
            fi
            echo "  ~ $service: $current_ip -> $new_ip"
        fi
    done <<< "$common_services"

    if [ $has_changes -eq 1 ]; then
        echo ""
    fi

    echo "===================================================="
    echo ""
    echo "To apply these changes, run: portoser dns sync"

    return 1
}
