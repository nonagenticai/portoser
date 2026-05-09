#!/usr/bin/env bash
# setup-buildx.sh - Configure Docker buildx for multi-platform builds
#
# Sets up:
# - Buildx builder for arm64/darwin and arm64/linux
# - Docker contexts for each Pi
# - Build cache optimization
#
# Usage: ./setup-buildx.sh

set -euo pipefail

PORTOSER_ROOT="${PORTOSER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REGISTRY_FILE="${REGISTRY_FILE:-$PORTOSER_ROOT/registry.yml}"

echo "========================================"
echo "Docker Buildx Setup"
echo "========================================"
echo ""

# Check dependencies
for cmd in docker yq; do
    if ! command -v $cmd &> /dev/null; then
        echo "❌ Error: $cmd is not installed"
        exit 1
    fi
done

echo "✓ Dependencies installed"
echo ""

# Create or recreate the builder
BUILDER_NAME="portoser-builder"

echo "Configuring buildx builder..."
if docker buildx inspect "$BUILDER_NAME" &> /dev/null; then
    echo "  Removing existing builder: $BUILDER_NAME"
    docker buildx rm "$BUILDER_NAME" || true
fi

echo "  Creating new builder: $BUILDER_NAME"
docker buildx create \
    --name "$BUILDER_NAME" \
    --driver docker-container \
    --bootstrap \
    --use

echo "  Inspecting builder..."
docker buildx inspect "$BUILDER_NAME"

echo ""
echo "✓ Buildx builder configured"
echo ""

# Setup Docker contexts for each Pi
echo "Setting up Docker contexts for Pis..."

# Get Pi hosts from registry
PI_HOSTS=$(yq eval '.hosts | to_entries | .[] | select(.value.arch == "arm64-linux") | .key' "$REGISTRY_FILE")

for pi in $PI_HOSTS; do
    echo "  Configuring context for $pi..."

    # Get Pi details
    PI_IP=$(yq eval ".hosts.$pi.ip" "$REGISTRY_FILE")
    PI_USER=$(yq eval ".hosts.$pi.ssh_user" "$REGISTRY_FILE")

    # Remove existing context if present
    if docker context inspect "$pi" &> /dev/null; then
        docker context rm "$pi" -f || true
    fi

    # Create SSH-based context
    docker context create "$pi" \
        --description "Docker on $pi ($PI_IP)" \
        --docker "host=ssh://${PI_USER}@${pi}.local" || echo "    (context may already exist)"

    echo "    ✓ Context created: $pi → ssh://${PI_USER}@${pi}.local"
done

echo ""
echo "✓ Docker contexts configured"
echo ""

# Test contexts
echo "Testing Docker contexts..."
for pi in $PI_HOSTS; do
    echo -n "  $pi: "
    if timeout 5 docker --context "$pi" info &> /dev/null; then
        echo "✓ Connected"
    else
        echo "✗ Failed (Pi may be offline)"
    fi
done

echo ""
echo "========================================"
echo "Setup Complete"
echo "========================================"
echo ""
echo "Builder: $BUILDER_NAME"
echo "Platforms: linux/arm64, linux/amd64"
echo ""
echo "Docker Contexts:"
docker context ls
echo ""
echo "Next steps:"
echo "  1. Build services: ./build-service.sh <service-name>"
echo "  2. Deploy services: ./deploy-service.sh <service-name>"
echo "  3. Or use: portoser deploy <service-name>"
echo ""
