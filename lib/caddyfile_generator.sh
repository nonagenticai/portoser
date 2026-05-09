#!/usr/bin/env bash
# caddyfile_generator.sh - Generate Caddyfile from registry.yml

set -euo pipefail
# This ensures registry.yml is the single source of truth

# Generate complete Caddyfile from registry
# Usage: generate_caddyfile_from_registry [OUTPUT_FILE]
# shellcheck disable=SC2120  # OUTPUT_FILE is optional; some callers stream to stdout
generate_caddyfile_from_registry() {
    local output_file="${1:-}"
    local registry_file="${CADDY_REGISTRY_PATH}"

    if [ ! -f "$registry_file" ]; then
        echo "Error: Registry file not found: $registry_file" >&2
        return 1
    fi

    # Generate header
    local services_root="${SERVICES_ROOT:-${HOME}/portoser-services}"

    # Choose log path with fallback to avoid validation failures on protected dirs
    local default_log_path="${services_root}/caddy/logs/caddy.log"
    local log_path="${CADDY_LOG_PATH:-$default_log_path}"
    if ! mkdir -p "$(dirname "$log_path")" 2>/dev/null || ! touch "$log_path" 2>/dev/null || ! [ -w "$log_path" ]; then
        # First fallback: try /tmp/portoser-caddy.log
        log_path="/tmp/portoser-caddy.log"
        if ! touch "$log_path" 2>/dev/null || ! [ -w "$log_path" ]; then
            # Second fallback: use user-specific log file
            log_path="/tmp/portoser-caddy-$(whoami).log"
            touch "$log_path" 2>/dev/null || true
            chmod 644 "$log_path" 2>/dev/null || true
            # Final check - if still not writable, this will cause validation to fail
            # which is better than silently proceeding with an unwritable log
            if ! [ -w "$log_path" ]; then
                echo "Warning: Could not create writable log file. Using $log_path anyway." >&2
            fi
        fi
    fi

    # Per-service log root with fallback
    local service_log_root="${CADDY_SERVICE_LOG_ROOT:-${services_root}/caddy/logs}"
    if ! mkdir -p "$service_log_root" 2>/dev/null || ! touch "$service_log_root/.write_test" 2>/dev/null; then
        # First fallback: try /tmp/portoser-caddy-logs
        service_log_root="/tmp/portoser-caddy-logs"
        if ! mkdir -p "$service_log_root" 2>/dev/null || ! [ -w "$service_log_root" ]; then
            # Second fallback: user-specific directory
            service_log_root="/tmp/portoser-caddy-logs-$(whoami)"
            mkdir -p "$service_log_root" 2>/dev/null || true
            chmod 755 "$service_log_root" 2>/dev/null || true
        fi
    fi
    rm -f "$service_log_root/.write_test" 2>/dev/null || true
    cat <<EOF
# ============================================================================
# Caddyfile - Reverse Proxy Configuration
# ============================================================================
# AUTO-GENERATED from registry.yml - DO NOT EDIT MANUALLY
# To update: ./portoser caddy regenerate
# Source: registry.yml
#
# Architecture:
# - All *.internal domains resolve to Caddy ingress (via dnsmasq)
# - Caddy routes requests to backend services based on hostname
# - Services can be moved between machines without changing client configuration
# ============================================================================

# Global options
{
	admin 127.0.0.1:2019
	log {
		output file ${log_path}
		level INFO
	}
}

# Health check endpoint for Caddy itself
:2020 {
	respond /health 200 {
		body "Caddy OK"
	}
}

EOF

    # Get list of services with HTTP endpoints
    local services
    services=$(yq eval '.services | keys | .[]' "$registry_file")

    # Convert to array for iteration (more robust with set -e)
    local service_array=()
    while IFS= read -r service; do
        if [ -n "$service" ]; then
            service_array+=("$service")
        fi
    done <<< "$services"

    # Generate a route block for each HTTP service
    for service in "${service_array[@]}"; do

        # Get service details - NO local keyword to avoid ZSH stdout leak in while loops
        hostname=$(yq eval ".services.${service}.hostname" "$registry_file")
        current_host=$(yq eval ".services.${service}.current_host" "$registry_file")
        # Read port from registry.yml (source of truth)
        exposed_port=$(yq eval ".services.${service}.port" "$registry_file")
        deployment_type=$(yq eval ".services.${service}.deployment_type" "$registry_file")
        description=$(yq eval ".services.${service}.description" "$registry_file")
        dependencies=$(yq eval ".services.${service}.dependencies[]" "$registry_file" 2>/dev/null | tr '\n' ', ' | sed 's|,$||' || true)
        healthcheck_url=$(yq eval ".services.${service}.healthcheck_url" "$registry_file")
        # Extract path from healthcheck URL
        health_path=$(echo "$healthcheck_url" | sed 's|^[^/]*//[^/]*/|/|' | sed 's|^[^/]*//[^/]*$|/|')
        # Default to /health if extraction failed or null
        if [ "$health_path" = "null" ] || [ -z "$health_path" ]; then
            health_path="/health"
        fi

        # Determine backend protocol from healthcheck_url (defaults to http)
        local backend_protocol="http"
        if [[ "$healthcheck_url" == https://* ]]; then
            backend_protocol="https"
        fi

        # Get TLS cert/key paths if they exist
        tls_cert=$(yq eval ".services.${service}.tls_cert" "$registry_file" 2>/dev/null || true)
        tls_key=$(yq eval ".services.${service}.tls_key" "$registry_file" 2>/dev/null || true)
        ca_cert=$(yq eval ".services.${service}.ca_cert" "$registry_file" 2>/dev/null || true)

        # Determine frontend protocol (http or https)
        local frontend_protocol="http"
        if [ "$tls_cert" != "null" ] && [ "$tls_key" != "null" ] && [ -n "$tls_cert" ] && [ -n "$tls_key" ]; then
            frontend_protocol="https"
        fi

        # Skip services without hostname or that don't have HTTP endpoints
        if [ "$hostname" = "null" ] || [ -z "$hostname" ]; then
            continue
        fi

        # Skip services without port (likely TCP-only services)
        if [ "$exposed_port" = "null" ] || [ -z "$exposed_port" ]; then
            continue
        fi

        # Skip TCP-only services (postgres, pgbouncer, neo4j) and caddy itself
        case "$service" in
            postgres|pgbouncer|neo4j|dnsmasq|caddy)
                continue
                ;;
        esac

        # Get machine IP - use localhost if service is on same machine as Caddy
        ingress_host=$(yq eval '.caddy.ingress_host' "$registry_file" || true)
        if [ "$current_host" = "$ingress_host" ]; then
            machine_ip="127.0.0.1"
        else
            machine_ip=$(get_machine_ip "$current_host" 2>/dev/null || echo "unknown")
        fi

        # Generate service block
        service_upper=$(echo "$service" | tr '[:lower:]' '[:upper:]')
        cat <<EOF
# ============================================================================
# ${service_upper} - ${description}
# ============================================================================
# Fixed hostname: ${hostname}
# Current location: ${current_host} @ ${machine_ip}:${exposed_port}
# Type: ${deployment_type}
EOF

        if [ -n "$dependencies" ]; then
            echo "# Dependencies: ${dependencies}"
        fi

        # Generate site block - hostname only (no protocol prefix)
        cat <<EOF

${hostname} {
EOF

        # Add TLS configuration if HTTPS frontend AND service is on Caddy's host
        # (Remote services can't have their certs accessed by Caddy)
        if [ "$frontend_protocol" = "https" ] && [ "$current_host" = "$ingress_host" ]; then
            # Expand cert paths to full paths for local services
            local base_path
            base_path=$(yq eval ".hosts.${current_host}.path" "$registry_file")
            local full_tls_cert="${base_path}${tls_cert}"
            local full_tls_key="${base_path}${tls_key}"
            local full_ca_cert=""
            if [ "$ca_cert" != "null" ] && [ -n "$ca_cert" ]; then
                full_ca_cert="${base_path}${ca_cert}"
            fi

            cat <<EOF
	# TLS configuration using server certificates
	tls ${full_tls_cert} ${full_tls_key} {
EOF
            # Add client auth if CA cert is provided
            if [ -n "$full_ca_cert" ]; then
                cat <<EOF
		client_auth {
			mode request
			trust_pool file {
				pem_file ${full_ca_cert}
			}
		}
EOF
            fi
            cat <<EOF
	}

EOF
        fi

        # Add special directives for keycloak (redirect root to realm account page)
        if [ "$service" = "keycloak" ]; then
            cat <<EOF
	# Redirect root to secure-apps realm account page (GitHub login)
	redir / /realms/secure-apps/account

EOF
        fi

        # Generate reverse proxy configuration
        cat <<EOF
	# Reverse proxy to backend service
	reverse_proxy ${backend_protocol}://${machine_ip}:${exposed_port} {
EOF

        # Add transport_insecure if backend is HTTPS
        if [ "$backend_protocol" = "https" ]; then
            cat <<EOF
		transport http {
			tls_insecure_skip_verify
		}
EOF
        fi

        # Skip health check for keycloak (uses redirect) and vault (returns 5xx when sealed)
        if [ "$service" != "keycloak" ] && [ "$service" != "vault" ]; then
            cat <<EOF
		# Health check endpoint
		health_uri ${health_path}
		health_interval 10s
		health_timeout 5s
		health_status 2xx
EOF
        fi

        cat <<EOF
	}

	# Logging
	log {
		output file ${service_log_root}/${service}.log
		format json
	}
}

EOF

        # Add HTTP->HTTPS redirect if frontend is HTTPS
        if [ "$frontend_protocol" = "https" ]; then
            cat <<EOF
# HTTP redirect to HTTPS for ${service}
http://${hostname} {
	redir https://${hostname}{uri} permanent
}

EOF
        fi
    done

    return 0
}

# Generate and save Caddyfile to file
# Usage: save_caddyfile OUTPUT_FILE
# save_caddyfile() {
#     local output_file="$1"

#     if [ -z "$output_file" ]; then
#         echo "Error: Output file required" >&2
#         return 1
#     fi

#     # Generate to temp file first
#     local temp_file=$(mktemp)
#     echo "Generating Caddyfile to temporary file $temp_file..."
#     generate_caddyfile_from_registry > "$temp_file"
#     echo "Caddyfile generated, validating..."

#     # Validate before replacing
#     if caddy validate --adapter caddyfile --config "$temp_file" > /dev/null 2>&1; then
#         # Format the file before moving it
#         echo "Formatting Caddyfile..."
#         if ! caddy fmt --overwrite "$temp_file" > /dev/null 2>&1; then
#             echo "Warning: Failed to format Caddyfile, but it's valid" >&2
#         fi
#         # echo "Moving Caddyfile $temp_file to $output_file..."
#         # mv "$temp_file" "$output_file"
#         echo "Writing Caddyfile to $output_file..."
#         if cat "$temp_file" > "$output_file"; then
#             echo "✓ Caddyfile written successfully: $output_file"
#             rm -f "$temp_file"
#             return 0
#         else
#             echo "Warning: direct write failed, trying mv fallback" >&2
#             if mv "$temp_file" "$output_file"; then
#                 echo "✓ Caddyfile moved successfully: $output_file"
#                 return 0
#             else
#                 echo "Error: Failed to write Caddyfile to $output_file" >&2
#                 rm -f "$temp_file"
#                 return 1
#             fi
#         fi
#     else
#         echo "Error: Generated Caddyfile is invalid" >&2
#         echo "Validation errors:" >&2
#         caddy validate --adapter caddyfile --config "$temp_file"
#         rm -f "$temp_file"
#         return 1
#     fi
#     echo "fi from end of save_caddyfile"
# }

# Generate and save Caddyfile to file (direct-write version)
# Usage: save_caddyfile OUTPUT_FILE
save_caddyfile() {
    local output_file="$1"

    if [ -z "$output_file" ]; then
        echo "Error: Output file required" >&2
        return 1
    fi

    # Generate full content (on stdout), and write directly to output_file.
    # shellcheck disable=SC2119  # streaming-to-stdout mode, intentionally no args
    if ! generate_caddyfile_from_registry > "$output_file"; then
        echo "Error: Failed to generate Caddyfile content" >&2
        return 1
    fi
    echo "--- AFTER WRITE ---"; stat "$output_file"; head -n 5 "$output_file"

    # Validate the written file before accepting it
    if ! caddy validate --adapter caddyfile --config "$output_file" > /dev/null 2>&1; then
        echo "Error: Written Caddyfile is invalid (after direct write)" >&2
        caddy validate --adapter caddyfile --config "$output_file"
        return 1
    fi

    # Optionally format in place
    if ! caddy fmt --overwrite "$output_file" > /dev/null 2>&1; then
        echo "Warning: Failed to format Caddyfile, but it's valid" >&2
    fi
    # pwd; ls -la "$(dirname "$output_file")"
    # cat "$temp_file" | head -n 20
    # cat "$output_file" | head -n 20
    echo "✓ Caddyfile written successfully: $output_file"
    return 0
}

# Update machine IPs in registry (bulk update)
# Usage: update_machine_ips_in_registry MACHINE IP [MACHINE IP ...]
update_machine_ips_in_registry() {
    local registry_file="${CADDY_REGISTRY_PATH}"

    if [ ! -f "$registry_file" ]; then
        echo "Error: Registry file not found: $registry_file" >&2
        return 1
    fi

    if [ $# -eq 0 ] || [ $(($# % 2)) -ne 0 ]; then
        echo "Usage: update_machine_ips_in_registry MACHINE IP [MACHINE IP ...]" >&2
        echo "" >&2
        echo "Example:" >&2
        echo "  update_machine_ips_in_registry host-a 10.0.0.1 host-b 10.0.0.2 host-c 10.0.0.3" >&2
        return 1
    fi

    # Backup registry
    echo "Backing up registry file..."
    cp "$registry_file" "${registry_file}.backup.$(date +%Y%m%d_%H%M%S)"
    echo "Backup created."

    echo "Updating machine IPs in registry..."

    # Process machine/IP pairs
    while [ $# -gt 0 ]; do
        local machine="$1"
        local new_ip="$2"
        shift 2

        # Validate machine exists
        if ! is_machine "$machine"; then
            echo "  ✗ Unknown machine: $machine (skipping)" >&2
            continue
        fi

        # Get current IP
        local old_ip
        old_ip=$(yq eval ".hosts.${machine}.ip" "$registry_file")

        if [ "$old_ip" = "$new_ip" ]; then
            echo "  - $machine: $new_ip (unchanged)"
            continue
        fi

        # Update machine IP in hosts section
        yq eval -i ".hosts.${machine}.ip = \"${new_ip}\"" "$registry_file"

        echo "  ✓ $machine: $old_ip → $new_ip"

        # Now update all services on this machine
        local services
        services=$(yq eval ".services | to_entries | .[] | select(.value.current_host == \"${machine}\") | .key" "$registry_file")

        while IFS= read -r service; do
            if [ -z "$service" ]; then
                continue
            fi

            local old_health_url
            old_health_url=$(yq eval ".services.${service}.healthcheck_url" "$registry_file")

            # Update healthcheck URL if it exists and contains the old IP
            if [ "$old_health_url" != "null" ] && [[ "$old_health_url" == *"$old_ip"* ]]; then
                local new_health_url="${old_health_url//$old_ip/$new_ip}"
                yq eval -i ".services.${service}.healthcheck_url = \"${new_health_url}\"" "$registry_file"
                echo "    ↳ Updated $service healthcheck URL"
            fi
        done <<< "$services"
    done

    echo ""
    echo "✓ Registry updated successfully"
    return 0
}

# Full workflow: Update IPs and regenerate Caddyfile
# Usage: update_network_and_regenerate MACHINE IP [MACHINE IP ...]
update_network_and_regenerate() {
    echo "==========================================="
    echo "NETWORK MIGRATION WORKFLOW"
    echo "==========================================="
    echo ""

    # Step 1: Update machine IPs in registry
    echo "Step 1: Updating machine IPs in registry..."
    if ! update_machine_ips_in_registry "$@"; then
        echo "Error: Failed to update machine IPs" >&2
        return 1
    fi
    echo "fi for update machine IPs"

    # Step 2: Regenerate Caddyfile
    echo "Step 2: Regenerating Caddyfile from registry..."
    local caddyfile="${CADDYFILE_PATH:-${SERVICES_ROOT:-${HOME}/portoser-services}/caddy/Caddyfile}"
    if ! save_caddyfile "$caddyfile"; then
        echo "Error: Failed to regenerate Caddyfile" >&2
        return 1
    else
        echo "Caddyfile regenerated: $caddyfile"
    fi
    echo "fi for regenerate Caddyfile"

    # Step 3: Reload Caddy
    echo "Step 3: Reloading Caddy configuration..."
    if ! reload_caddyfile; then
        echo "Error: Failed to reload Caddy" >&2
        return 1
    else
        echo "Caddy reloaded successfully"
    fi
    echo "fi for reload Caddy"

    # Step 4: Verify all services
    echo "Step 4: Verifying services..."
    local services
    services=$(list_services)
    local failed=0

    while IFS= read -r service; do
        if [ -z "$service" ]; then
            continue
        fi

        # Skip TCP services
        case "$service" in
            postgres|pgbouncer|neo4j)
                continue
                ;;
        esac

        if check_service_health "$service" 1 > /dev/null 2>&1; then
            echo "  ✓ $service"
        else
            echo "  ✗ $service (not responding)"
            failed=$((failed + 1))
        fi
    done <<< "$services"

    echo ""

    if [ $failed -eq 0 ]; then
        echo "==========================================="
        echo "✓ NETWORK MIGRATION COMPLETED SUCCESSFULLY"
        echo "==========================================="
        return 0
    else
        echo "==========================================="
        echo "⚠  MIGRATION COMPLETED WITH $failed FAILURES"
        echo "==========================================="
        echo "Check service health: ./portoser health check-all"
        return 1
    fi
}
