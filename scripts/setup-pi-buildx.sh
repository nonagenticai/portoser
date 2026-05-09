#!/usr/bin/env bash
# setup-pi-buildx.sh
# Configure Docker buildx for building arm64 containers for Raspberry Pis
#
# This script sets up:
# - Docker buildx builder with arm64 support
# - Docker contexts for each Pi
# - Build helper functions

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

PORTOSER_ROOT="${PORTOSER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REGISTRY_FILE="${REGISTRY_FILE:-$PORTOSER_ROOT/registry.yml}"
HELPER_DIR="${HELPER_DIR:-$PORTOSER_ROOT/build-helpers}"
BUILDER_NAME="pi-builder"
mkdir -p "$HELPER_DIR"

log() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $*"
}

log_info() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $*"
}

log_error() {
    echo -e "${RED}[$(date +'%H:%M:%S')] ERROR:${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%H:%M:%S')] WARNING:${NC} $*"
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."

    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker is not installed"
        exit 1
    fi

    if ! command -v yq >/dev/null 2>&1; then
        log_error "yq is not installed. Install with: brew install yq"
        exit 1
    fi

    if [ ! -f "$REGISTRY_FILE" ]; then
        log_error "Registry file not found: $REGISTRY_FILE"
        exit 1
    fi

    log "✓ Prerequisites met"
}

# Get Pi hosts from registry
get_pi_hosts() {
    yq eval '.hosts | to_entries | .[] | select(.key | test("^pi[0-9]+$")) | .key' "$REGISTRY_FILE"
}

get_host_ip() {
    local host=$1
    yq eval ".hosts.${host}.ip" "$REGISTRY_FILE"
}

get_host_user() {
    local host=$1
    yq eval ".hosts.${host}.ssh_user" "$REGISTRY_FILE"
}

# Setup Docker buildx builder
setup_buildx() {
    log ""
    log "Setting up Docker buildx builder..."

    # Check if builder already exists
    if docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
        log_warning "Builder '$BUILDER_NAME' already exists"
        read -r -p "$(echo -e "${YELLOW}Remove and recreate? [y/N]:${NC} ")" -n 1
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            docker buildx rm "$BUILDER_NAME"
            log "✓ Removed existing builder"
        else
            log_info "Using existing builder"
            return 0
        fi
    fi

    # Create new builder with arm64 support
    docker buildx create \
        --name "$BUILDER_NAME" \
        --driver docker-container \
        --bootstrap \
        --use

    log "✓ Created buildx builder: $BUILDER_NAME"

    # Verify platform support
    log_info "Supported platforms:"
    docker buildx inspect --bootstrap | grep Platforms
}

# Setup Docker contexts for each Pi
setup_docker_contexts() {
    log ""
    log "Setting up Docker contexts for Pis..."

    local pi_hosts
    mapfile -t pi_hosts < <(get_pi_hosts)

    for pi_name in "${pi_hosts[@]}"; do
        local pi_ip
        pi_ip=$(get_host_ip "$pi_name")
        local pi_user
        pi_user=$(get_host_user "$pi_name")

        log_info "Setting up context for ${pi_name} (${pi_user}@${pi_ip})"

        # Check if context exists
        if docker context inspect "$pi_name" >/dev/null 2>&1; then
            log_warning "Context '$pi_name' already exists - updating"
            docker context rm "$pi_name" 2>/dev/null || true
        fi

        # Test SSH connection first
        if ssh -o ConnectTimeout=5 -o BatchMode=yes "${pi_user}@${pi_ip}" "echo 'SSH OK'" >/dev/null 2>&1; then
            # Create context
            docker context create "$pi_name" \
                --description "Docker context for ${pi_name}" \
                --docker "host=ssh://${pi_user}@${pi_ip}"

            log "✓ Created context: $pi_name"
        else
            log_error "Cannot connect to ${pi_name} via SSH - skipping context creation"
        fi
    done
}

# Create build helper script
create_build_helper() {
    local helper_script="$HELPER_DIR/build-for-pi.sh"

    log ""
    log "Creating build helper script..."

    cat > "$helper_script" << 'EOF'
#!/usr/bin/env bash
# build-for-pi.sh - Helper script to build Docker images for Pis
# Usage: ./build-for-pi.sh <pi-name> <app-directory> [image-name]

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <pi-name> <app-directory> [image-name]"
    echo ""
    echo "Examples:"
    echo "  $0 pi1 ./pi1/myservice"
    echo "  $0 pi2 ./pi2/workers myorg/workers:latest"
    exit 1
fi

PI_NAME=$1
APP_DIR=$2
IMAGE_NAME=${3:-}

# Get directory name as default image name
if [ -z "$IMAGE_NAME" ]; then
    IMAGE_NAME=$(basename "$APP_DIR"):latest
fi

echo "Building $IMAGE_NAME for $PI_NAME from $APP_DIR"

# Check if directory exists
if [ ! -d "$APP_DIR" ]; then
    echo "Error: Directory not found: $APP_DIR"
    exit 1
fi

# Check if Dockerfile exists
if [ ! -f "$APP_DIR/Dockerfile" ]; then
    echo "Error: Dockerfile not found in $APP_DIR"
    exit 1
fi

# Build using buildx for arm64
docker buildx build \
    --builder pi-builder \
    --platform linux/arm64 \
    --tag "$IMAGE_NAME" \
    --load \
    "$APP_DIR"

echo "✓ Built $IMAGE_NAME"
echo ""
echo "To deploy to $PI_NAME:"
echo "  docker save $IMAGE_NAME | docker --context $PI_NAME load"
echo "  docker --context $PI_NAME compose -f $APP_DIR/docker-compose.yml up -d"
EOF

    chmod +x "$helper_script"
    log "✓ Created build helper: $helper_script"
}

# Create deployment helper script
create_deploy_helper() {
    local helper_script="$HELPER_DIR/deploy-to-pi.sh"

    log ""
    log "Creating deployment helper script..."

    cat > "$helper_script" << 'EOF'
#!/usr/bin/env bash
# deploy-to-pi.sh - Helper script to deploy containers to Pis
# Usage: ./deploy-to-pi.sh <pi-name> <image-name> <app-directory>

set -euo pipefail

if [ $# -lt 3 ]; then
    echo "Usage: $0 <pi-name> <image-name> <app-directory>"
    echo ""
    echo "Examples:"
    echo "  $0 pi1 myservice:latest ./pi1/myservice"
    exit 1
fi

PI_NAME=$1
IMAGE_NAME=$2
APP_DIR=$3

echo "Deploying $IMAGE_NAME to $PI_NAME from $APP_DIR"

# Check if image exists locally
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "Error: Image not found locally: $IMAGE_NAME"
    echo "Build it first with: ./build-for-pi.sh $PI_NAME $APP_DIR"
    exit 1
fi

# Check if docker-compose.yml exists
if [ ! -f "$APP_DIR/docker-compose.yml" ]; then
    echo "Error: docker-compose.yml not found in $APP_DIR"
    exit 1
fi

# Save and transfer image
echo "Transferring image to $PI_NAME..."
docker save "$IMAGE_NAME" | docker --context "$PI_NAME" load

# Deploy with docker-compose
echo "Deploying with docker-compose..."
docker --context "$PI_NAME" compose -f "$APP_DIR/docker-compose.yml" up -d

echo "✓ Deployed $IMAGE_NAME to $PI_NAME"
echo ""
echo "Check status:"
echo "  docker --context $PI_NAME ps"
echo "  docker --context $PI_NAME logs <container-name>"
EOF

    chmod +x "$helper_script"
    log "✓ Created deploy helper: $helper_script"
}

# Display summary
show_summary() {
    log ""
    log "================================================"
    log "Setup Complete!"
    log "================================================"
    log ""
    log "Docker buildx builder: $BUILDER_NAME"
    log "Supported platforms: linux/arm64, linux/amd64"
    log ""
    log "Docker contexts created for Pis:"
    docker context ls | grep -E "^(pi[0-9]+|NAME)" || true
    log ""
    log "Helper scripts created in $HELPER_DIR:"
    log "  $HELPER_DIR/build-for-pi.sh"
    log "  $HELPER_DIR/deploy-to-pi.sh"
    log ""
    log "Usage examples:"
    log "  1. Build an image:"
    log "     cd $HELPER_DIR"
    log "     ./build-for-pi.sh pi1 ./pi1/myservice"
    log ""
    log "  2. Deploy to Pi:"
    log "     ./deploy-to-pi.sh pi1 myservice:latest ./pi1/myservice"
    log ""
    log "  3. Check Pi status:"
    log "     docker --context pi1 ps"
    log ""
    log "  4. Build all images for a Pi:"
    log "     for dir in ./pi1/*/; do"
    log "       [ -f \"\$dir/Dockerfile\" ] && ./build-for-pi.sh pi1 \"\$dir\""
    log "     done"
}

# Main execution
main() {
    log "================================================"
    log "Pi Docker Buildx Setup"
    log "================================================"

    check_prerequisites
    setup_buildx
    setup_docker_contexts
    create_build_helper
    create_deploy_helper
    show_summary
}

main "$@"
