#!/usr/bin/env bash
# =============================================================================
# lib/cluster/health.sh - Service Health Monitoring Library
#
# Provides functions for checking the health status of services across the
# cluster, with support for HTTP health endpoints and JSON output.
#
# Functions:
#   - check_cluster_health()           Check health of all cluster services
#   - check_service_health_detailed()  Detailed health check for a service
#   - get_health_summary()             Get summary statistics
#
# Dependencies: curl, yq
# Created: 2025-12-03
# =============================================================================

set -euo pipefail

# Default configuration
HEALTH_DEFAULT_TIMEOUT=3
HEALTH_DEFAULT_CA_CERT="${HEALTH_DEFAULT_CA_CERT:-${HOME}/portoser/ca/certs/ca-cert.pem}"

# Services to skip (TCP-only, no HTTP)
HEALTH_SKIP_SERVICES="postgres pgbouncer neo4j dnsmasq caddy redis"

# =============================================================================
# check_service_health_detailed - Perform detailed health check on a service
#
# Checks the health of a service by attempting to connect to its health
# endpoints. Distinguishes between healthy (200 OK), degraded (non-200
# HTTP response), and down (connection failed).
#
# Parameters:
#   $1 - hostname (required): Service hostname (e.g., myservice.internal)
#   $2 - port (required): Service port number
#   $3 - service_name (required): Name of the service
#   $4 - verify_ssl (optional): Set to "false" to disable SSL verification
#                               Default: "true"
#   $5 - timeout (optional): Request timeout in seconds
#                           Default: 3
#
# Returns:
#   0 - Service is healthy (200 OK)
#   1 - Service is degraded (non-200 response)
#   2 - Service is down (connection failed)
#   3 - Service should be skipped (TCP-only)
#
# Outputs:
#   Prints JSON object to stdout with status and details:
#   {
#     "service": "myservice",
#     "hostname": "myservice.internal",
#     "port": "8080",
#     "status": "healthy|degraded|down|skipped",
#     "http_code": "200",
#     "endpoint": "/health",
#     "message": "details"
#   }
#
# Example:
#   check_service_health_detailed "myservice.internal" "8080" "myservice"
# =============================================================================
check_service_health_detailed() {
    local hostname="$1"
    local port="$2"
    local service_name="$3"
    local verify_ssl="${4:-true}"
    local timeout="${5:-$HEALTH_DEFAULT_TIMEOUT}"

    # Validate parameters
    if [[ -z "$hostname" ]] || [[ -z "$port" ]] || [[ -z "$service_name" ]]; then
        echo '{"status":"error","message":"Invalid parameters"}' >&2
        return 2
    fi

    # Check if service should be skipped
    for skip_service in $HEALTH_SKIP_SERVICES; do
        if [[ "$service_name" == "$skip_service" ]]; then
            echo "{\"service\":\"$service_name\",\"hostname\":\"$hostname\",\"port\":\"$port\",\"status\":\"skipped\",\"message\":\"TCP-only service (no HTTP health check)\"}"
            return 3
        fi
    done

    # Build curl options as an array so each flag stays a separate argv entry
    local curl_opts=(-sS -w '\n%{http_code}' --max-time "$timeout" --connect-timeout 2)

    if [[ "$verify_ssl" == "false" ]]; then
        curl_opts+=(-k)
    elif [[ -f "$HEALTH_DEFAULT_CA_CERT" ]]; then
        curl_opts+=(--cacert "$HEALTH_DEFAULT_CA_CERT")
    fi

    # Build the URL prefixes to try, honoring the registry-supplied port.
    #   port 443 → https://host           (TLS-fronted service, e.g. behind Caddy)
    #   port 80  → http://host
    #   else     → http://host:port first, then https://host:port as fallback
    #              (handles homelab services on 3000/8080/9090/etc and the
    #              rare TLS-on-non-default-port case)
    local url_prefixes=()
    case "$port" in
        443) url_prefixes=("https://${hostname}") ;;
        80)  url_prefixes=("http://${hostname}") ;;
        *)   url_prefixes=("http://${hostname}:${port}" "https://${hostname}:${port}") ;;
    esac

    # Try health endpoints. Order matters: most specific first, "/" last as
    # a "anything serves a homepage" fallback. Covers common conventions —
    # Prometheus (/-/ready), n8n/k8s (/healthz), Gitea (/api/v1/version),
    # Vaultwarden (/alive), Pi-hole (/admin/), plus the canonical /health*.
    local endpoints=(
        "/health" "/health/ready" "/healthz" "/api/health"
        "/-/ready" "/-/healthy" "/api/v1/version" "/alive" "/admin/" "/"
    )
    local status=""
    local http_code=""
    local endpoint_found=""
    local message=""

    for url_prefix in "${url_prefixes[@]}"; do
        # Reset per-prefix so a prior prefix's hard-down verdict doesn't carry over.
        local prefix_status=""
        local prefix_message=""
        local prefix_http_code=""
        local prefix_endpoint=""
        # Remember the best non-200 we've seen so far on this prefix so we
        # only fall back to "degraded (404)" after trying every endpoint.
        local fallback_status=""
        local fallback_message=""
        local fallback_http_code=""
        local fallback_endpoint=""

        for endpoint in "${endpoints[@]}"; do
            local response_full
            response_full=$(curl "${curl_opts[@]}" "${url_prefix}${endpoint}" 2>&1 || true)

            # Extract HTTP code (last line) and body (everything else)
            prefix_http_code=$(echo "$response_full" | tail -1)
            local response_body
            response_body=$(echo "$response_full" | sed '$d')

            # If we got a valid 3-digit HTTP code, the request reached the
            # server — skip the curl-error regexes (they otherwise trigger
            # false positives on response bodies that contain words like
            # "SSL" or "certificate", e.g. Gitea's /install form).
            if ! [[ "$prefix_http_code" =~ ^[0-9]{3}$ ]] || [[ "$prefix_http_code" == "000" ]]; then
                if [[ "$response_full" =~ (SSL|certificate|wrong\ version\ number|handshake) ]]; then
                    prefix_status="down"
                    prefix_message="SSL certificate verification failed"
                    break
                elif [[ "$response_full" =~ "Could not resolve" ]]; then
                    prefix_status="down"
                    prefix_message="DNS resolution failed"
                    break
                elif [[ "$response_full" =~ (Connection refused|Failed to connect) ]]; then
                    prefix_status="down"
                    prefix_message="Connection refused (service not running)"
                    break
                elif [[ "$response_full" =~ (timed out|timeout|Operation timed out) ]]; then
                    prefix_status="down"
                    prefix_message="Connection timeout (${timeout}s)"
                    break
                elif [[ "$response_full" =~ (Empty\ reply\ from\ server|Recv\ failure) ]]; then
                    # Server closed without responding. Often means it expects
                    # TLS on a port we're hitting plain — let the next
                    # url_prefix try.
                    prefix_status="down"
                    prefix_message="Empty reply (server may require TLS)"
                    break
                fi
            fi

            # Check HTTP response
            if [[ "$prefix_http_code" =~ ^[0-9]{3}$ ]] && [[ "$prefix_http_code" != "000" ]]; then
                if [[ "$prefix_http_code" == "200" ]]; then
                    # Verify it's actual health data
                    if [[ "$response_body" =~ (status|health|healthy|ok) ]] || [[ ${#response_body} -gt 10 ]]; then
                        prefix_status="healthy"
                        prefix_endpoint="$endpoint"
                        prefix_message="HTTP $prefix_http_code"
                        break
                    fi
                    # 200 with empty body — keep trying other endpoints, but
                    # remember it so we don't downgrade to "down" later.
                    if [[ -z "$fallback_status" ]]; then
                        fallback_status="degraded"
                        fallback_endpoint="$endpoint"
                        fallback_http_code="$prefix_http_code"
                        fallback_message="HTTP 200 (empty response)"
                    fi
                    continue
                fi

                # 3xx — service responded, just redirecting (e.g. unauth
                # homepages → /login). Count as alive.
                if [[ "$prefix_http_code" =~ ^3[0-9]{2}$ ]]; then
                    prefix_status="healthy"
                    prefix_endpoint="$endpoint"
                    prefix_message="HTTP $prefix_http_code (redirect)"
                    break
                fi

                # Non-200 response. 404 is the common "this endpoint doesn't
                # exist on this service" — keep trying the next endpoint, and
                # only stick on definitive verdicts (5xx, auth, redirect-loop).
                local current_message
                if [[ "$prefix_http_code" == "503" ]]; then
                    current_message="HTTP $prefix_http_code (backend down)"
                elif [[ "$prefix_http_code" == "404" ]]; then
                    current_message="HTTP $prefix_http_code (not found)"
                elif [[ "$prefix_http_code" =~ ^40[13]$ ]]; then
                    current_message="HTTP $prefix_http_code (auth required)"
                else
                    current_message="HTTP $prefix_http_code"
                fi

                if [[ "$prefix_http_code" == "404" ]]; then
                    # Save 404 as a fallback; keep probing other endpoints.
                    if [[ -z "$fallback_status" ]] || [[ "$fallback_http_code" == "404" ]]; then
                        fallback_status="degraded"
                        fallback_endpoint="$endpoint"
                        fallback_http_code="$prefix_http_code"
                        fallback_message="$current_message"
                    fi
                    continue
                fi

                # 5xx, 401/403, redirects, etc. — definitive enough to stop.
                prefix_status="degraded"
                prefix_endpoint="$endpoint"
                prefix_message="$current_message"
                break
            fi
        done

        # If no endpoint matched cleanly and we're not on a hard-down verdict,
        # promote the saved 404/empty-body fallback so the prefix returns a
        # meaningful status instead of "Unknown error".
        if [[ -z "$prefix_status" ]] && [[ -n "$fallback_status" ]]; then
            prefix_status="$fallback_status"
            prefix_endpoint="$fallback_endpoint"
            prefix_http_code="$fallback_http_code"
            prefix_message="$fallback_message"
        fi

        # Promote prefix verdict to the outer scope.
        status="$prefix_status"
        message="$prefix_message"
        http_code="$prefix_http_code"
        endpoint_found="$prefix_endpoint"

        # Stop on a definitive answer; otherwise let the next prefix have a go.
        # "down" is definitive only when DNS or refused — TLS/empty-reply gets
        # a retry with the alternate scheme.
        case "$prefix_status" in
            healthy|degraded) break ;;
            down)
                if [[ "$prefix_message" == "DNS resolution failed" ]] \
                   || [[ "$prefix_message" =~ ^Connection\ refused ]]; then
                    break
                fi
                ;;
        esac
    done

    # Default if nothing worked
    if [[ -z "$status" ]]; then
        status="down"
        message="Unknown error"
        http_code="0"
    fi

    # Output JSON
    local json_output
    json_output=$(cat <<EOF
{
  "service": "$service_name",
  "hostname": "$hostname",
  "port": "$port",
  "status": "$status",
  "http_code": "$http_code",
  "endpoint": "$endpoint_found",
  "message": "$message"
}
EOF
    )

    echo "$json_output"

    # Return appropriate exit code
    case "$status" in
        healthy) return 0 ;;
        degraded) return 1 ;;
        down) return 2 ;;
        *) return 2 ;;
    esac
}

# =============================================================================
# check_cluster_health - Check health of all services in the cluster
#
# Reads registry.yml and checks the health of all configured services.
# Returns aggregated results with statistics.
#
# Parameters:
#   $1 - registry_file (required): Path to registry.yml
#   $2 - verify_ssl (optional): Set to "false" to disable SSL verification
#                               Default: "true"
#   $3 - output_format (optional): "json" or "text"
#                                  Default: "text"
#
# Returns:
#   0 - All services healthy
#   1 - Some services degraded
#   2 - Some services down
#
# Outputs:
#   If output_format is "json":
#     {
#       "timestamp": "ISO-8601",
#       "healthy": 10,
#       "degraded": 2,
#       "down": 1,
#       "skipped": 3,
#       "total": 16,
#       "services": [...]
#     }
#   If output_format is "text":
#     Human-readable status report
#
# Example:
#   check_cluster_health "/path/to/registry.yml" "true" "json"
# =============================================================================
check_cluster_health() {
    local registry_file="$1"
    local verify_ssl="${2:-true}"
    local output_format="${3:-text}"

    # Validate parameters
    if [[ -z "$registry_file" ]]; then
        echo "Error: registry_file parameter is required" >&2
        return 2
    fi

    if [[ ! -f "$registry_file" ]]; then
        echo "Error: Registry file not found: $registry_file" >&2
        return 2
    fi

    # Check dependencies
    if ! command -v yq &> /dev/null; then
        echo "Error: yq is not installed or not in PATH" >&2
        return 2
    fi

    if ! command -v curl &> /dev/null; then
        echo "Error: curl is not installed or not in PATH" >&2
        return 2
    fi

    # Get all hosts
    local all_hosts
    all_hosts=$(yq eval '.hosts | keys | .[]' "$registry_file" 2>/dev/null)

    # Statistics
    local healthy=0
    local degraded=0
    local down=0
    local skipped=0
    local service_results=()

    # Check each host's services
    for host in $all_hosts; do
        # Get services on this host
        local services
        services=$(yq eval ".services | to_entries | .[] | select(.value.current_host == \"$host\") | .key" "$registry_file" 2>/dev/null)

        [[ -z "$services" ]] && continue

        # Check each service
        while IFS= read -r service; do
            [[ -z "$service" ]] && continue

            local hostname
            local port
            hostname=$(yq eval ".services.${service}.hostname" "$registry_file" 2>/dev/null)
            port=$(yq eval ".services.${service}.port" "$registry_file" 2>/dev/null)

            [[ -z "$hostname" ]] || [[ "$hostname" == "null" ]] && continue
            [[ -z "$port" ]] || [[ "$port" == "null" ]] && continue

            # Check service health.
            # `check_service_health_detailed` always prints a JSON object
            # to stdout, even on the down/degraded paths — and it returns a
            # non-zero exit code to signal that. The previous form
            #   $(check... || echo '{"status":"error"}')
            # appended the fallback after every non-healthy probe, double-
            # entrying the services array. Capture stdout, ignore the exit
            # code, and only synthesize an error object if nothing was
            # printed at all (truly unexpected).
            local result
            result=$(check_service_health_detailed "$hostname" "$port" "$service" "$verify_ssl" 2>/dev/null) || true
            [[ -z "$result" ]] && result='{"status":"error"}'

            service_results+=("$result")

            # Extract status from the per-service JSON. The pretty-printed
            # output has a space after the colon ("status": "healthy"), so
            # the regex must allow optional whitespace or it never matches.
            local status
            status=$(echo "$result" | grep -oE '"status":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')

            # Use plain assignment instead of (( var++ )); the post-increment
            # form returns the *previous* value, which is 0 on first hit and
            # makes bash treat the arithmetic command as failing — under
            # set -e that aborts the whole probe loop silently.
            case "$status" in
                healthy)  healthy=$((healthy + 1)) ;;
                degraded) degraded=$((degraded + 1)) ;;
                down)     down=$((down + 1)) ;;
                skipped)  skipped=$((skipped + 1)) ;;
            esac
        done <<< "$services"
    done

    local total
    total=$((healthy + degraded + down + skipped))

    # Output results
    if [[ "$output_format" == "json" ]]; then
        # JSON output
        local timestamp
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        echo "{"
        echo "  \"timestamp\": \"$timestamp\","
        echo "  \"healthy\": $healthy,"
        echo "  \"degraded\": $degraded,"
        echo "  \"down\": $down,"
        echo "  \"skipped\": $skipped,"
        echo "  \"total\": $total,"
        echo "  \"services\": ["

        local first=true
        for result in "${service_results[@]}"; do
            if [[ "$first" == true ]]; then
                first=false
            else
                echo ","
            fi
            echo -n "    $result"
        done

        echo ""
        echo "  ]"
        echo "}"
    else
        # Text output
        echo "Cluster Health Summary"
        echo "======================"
        echo ""
        echo "Healthy:   $healthy"
        echo "Degraded:  $degraded"
        echo "Down:      $down"
        echo "Skipped:   $skipped"
        echo "Total:     $total"
    fi

    # Return appropriate exit code
    if [[ $down -gt 0 ]]; then
        return 2
    elif [[ $degraded -gt 0 ]]; then
        return 1
    else
        return 0
    fi
}

# =============================================================================
# get_health_summary - Get health statistics summary
#
# Parses health check results and returns summary statistics.
#
# Parameters:
#   $1 - results_json (required): JSON string from check_cluster_health
#
# Returns:
#   0 - Always successful if input is valid
#   1 - Invalid input
#
# Outputs:
#   Prints summary statistics to stdout:
#   "HEALTHY: X, DEGRADED: Y, DOWN: Z, TOTAL: N"
#
# Example:
#   summary=$(get_health_summary "$health_results")
# =============================================================================
get_health_summary() {
    local results_json="$1"

    # Validate parameters
    if [[ -z "$results_json" ]]; then
        echo "Error: results_json parameter is required" >&2
        return 1
    fi

    # Extract statistics (basic parsing without jq dependency)
    local healthy
    local degraded
    local down
    local total

    healthy=$(echo "$results_json" | grep -o '"healthy": [0-9]*' | grep -o '[0-9]*' || echo "0")
    degraded=$(echo "$results_json" | grep -o '"degraded": [0-9]*' | grep -o '[0-9]*' || echo "0")
    down=$(echo "$results_json" | grep -o '"down": [0-9]*' | grep -o '[0-9]*' || echo "0")
    total=$(echo "$results_json" | grep -o '"total": [0-9]*' | grep -o '[0-9]*' || echo "0")

    echo "HEALTHY: $healthy, DEGRADED: $degraded, DOWN: $down, TOTAL: $total"
    return 0
}

# =============================================================================
# Library initialization check
# =============================================================================

# Verify this script is being sourced, not executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This library should be sourced, not executed directly" >&2
    echo "Usage: source lib/cluster/health.sh" >&2
    exit 1
fi
