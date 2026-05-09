#!/usr/bin/env bash
# verify-all-services.sh — probe HTTP health for every service in the registry.
#
# Reads `services.<name>.{hostname,port,healthcheck_url}` from registry.yml
# (or $REGISTRY_FILE), constructs a URL per service, and curls it.
#
# Per-service overrides via env: <NAME>_URL=https://... (the env var name is
# the service name, uppercased, with `-` replaced by `_`, suffixed `_URL`).
#
# Usage: verify-all-services.sh
# Env:
#   REGISTRY_FILE       Path to registry.yml (default: <repo>/registry.yml)
#   HTTP_TIMEOUT        Per-request timeout in seconds (default: 5)
#   HTTP_OK_CODES       Space-separated list of "OK" codes (default: 200 204)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_FILE="${REGISTRY_FILE:-$SCRIPT_DIR/../registry.yml}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-5}"
HTTP_OK_CODES="${HTTP_OK_CODES:-200 204}"

if [ ! -f "$REGISTRY_FILE" ]; then
    echo "Error: registry not found: $REGISTRY_FILE" >&2
    echo "Set REGISTRY_FILE to override." >&2
    exit 2
fi

if ! command -v yq >/dev/null 2>&1; then
    echo "Error: yq is required but not installed." >&2
    exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is required but not installed." >&2
    exit 2
fi

echo "=== Service Health Verification ==="
echo "Registry: $REGISTRY_FILE"
echo ""

passed=0
failed=0
skipped=0

# Build the HTTP probe URL for a service.
# Priority:
#   1. $<NAME>_URL env var
#   2. services.<name>.healthcheck_url from registry
#   3. http://<hostname>:<port>/health if both fields are present
#   4. http://<hostname>/health if only hostname is present
build_url() {
    local svc="$1"
    local var
    var="$(echo "$svc" | tr '[:lower:]-' '[:upper:]_')_URL"
    if [ -n "${!var:-}" ]; then
        echo "${!var}"
        return
    fi

    local hc
    hc=$(yq eval ".services.\"$svc\".healthcheck_url // \"\"" "$REGISTRY_FILE" 2>/dev/null)
    if [ -n "$hc" ] && [ "$hc" != "null" ]; then
        echo "$hc"
        return
    fi

    local host port
    host=$(yq eval ".services.\"$svc\".hostname // \"\"" "$REGISTRY_FILE" 2>/dev/null)
    port=$(yq eval ".services.\"$svc\".port // \"\"" "$REGISTRY_FILE" 2>/dev/null)
    if [ -z "$host" ] || [ "$host" = "null" ]; then
        echo ""
        return
    fi
    if [ -n "$port" ] && [ "$port" != "null" ]; then
        echo "http://${host}:${port}/health"
    else
        echo "http://${host}/health"
    fi
}

# List services from the registry, preserving declaration order.
mapfile -t services < <(yq eval '.services | keys | .[]' "$REGISTRY_FILE")

for svc in "${services[@]}"; do
    url=$(build_url "$svc")

    if [ -z "$url" ]; then
        echo "⊘ $svc — no URL resolvable (skipped)"
        skipped=$((skipped + 1))
        continue
    fi

    code=$(curl -sk -o /dev/null -w "%{http_code}" -m "$HTTP_TIMEOUT" "$url" 2>/dev/null || echo "000")

    matched=0
    for ok in $HTTP_OK_CODES; do
        if [ "$code" = "$ok" ]; then
            matched=1
            break
        fi
    done

    if [ "$matched" = "1" ]; then
        echo "✓ $svc — $url"
        passed=$((passed + 1))
    else
        echo "✗ $svc — $url (HTTP $code)"
        failed=$((failed + 1))
    fi
done

echo ""
echo "=== Summary ==="
echo "Passed:  $passed"
echo "Failed:  $failed"
echo "Skipped: $skipped"

if [ "$failed" -eq 0 ]; then
    exit 0
fi
exit 1
