#!/usr/bin/env bash
# list-services.sh - Show all services and their deployment targets from registry.yml
#
# Usage:
#   ./list-services.sh
#   ./list-services.sh --docker-only

set -euo pipefail

PORTOSER_ROOT="${PORTOSER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REGISTRY_FILE="${REGISTRY_FILE:-$PORTOSER_ROOT/registry.yml}"
DOCKER_ONLY=false

if [ $# -gt 0 ] && [ "$1" = "--docker-only" ]; then
    DOCKER_ONLY=true
fi

echo "========================================"
echo "Portoser Services (from registry.yml)"
echo "========================================"
echo ""

# Get all services
SERVICES=$(yq eval '.services | keys | .[]' "$REGISTRY_FILE")

# Group by host
declare -A SERVICES_BY_HOST

for service in $SERVICES; do
    HOST=$(yq eval ".services.\"$service\".current_host" "$REGISTRY_FILE")
    TYPE=$(yq eval ".services.\"$service\".deployment_type" "$REGISTRY_FILE")

    # Skip non-docker if docker-only flag
    if [ "$DOCKER_ONLY" = true ] && [ "$TYPE" != "docker" ]; then
        continue
    fi

    # Check if host key exists in associative array (bash 4+ safe way)
    if [ -z "${SERVICES_BY_HOST[$HOST]:-}" ]; then
        SERVICES_BY_HOST[$HOST]="$service"
    else
        SERVICES_BY_HOST[$HOST]="${SERVICES_BY_HOST[$HOST]},$service"
    fi
done

# Print by host
for host in $(echo "${!SERVICES_BY_HOST[@]}" | tr ' ' '\n' | sort); do
    # Get host details
    ARCH=$(yq eval ".hosts.\"$host\".arch" "$REGISTRY_FILE")
    IP=$(yq eval ".hosts.\"$host\".ip" "$REGISTRY_FILE")
    
    echo "Host: $host ($ARCH - $IP)"
    echo "────────────────────────────────────"
    
    # Split services and show each
    IFS=',' read -ra SERVICE_LIST <<< "${SERVICES_BY_HOST[$host]}"
    for svc in "${SERVICE_LIST[@]}"; do
        TYPE=$(yq eval ".services.\"$svc\".deployment_type" "$REGISTRY_FILE")
        PORT=$(yq eval ".services.\"$svc\".port" "$REGISTRY_FILE")
        
        if [ "$TYPE" = "docker" ]; then
            ICON="🐳"
        else
            ICON="⚙️ "
        fi
        
        echo "  $ICON $svc ($TYPE) - :$PORT"
    done
    
    echo ""
done

echo "Summary:"
echo "  Total services: $(echo "$SERVICES" | wc -l | xargs)"
if [ "$DOCKER_ONLY" = true ]; then
    DOCKER_COUNT=$(yq eval '.services | to_entries | .[] | select(.value.deployment_type == "docker") | .key' "$REGISTRY_FILE" | wc -l | xargs)
    echo "  Docker services: $DOCKER_COUNT"
fi
echo ""
echo "To deploy a service:"
echo "  ./deploy.sh <service-name>"
echo ""
