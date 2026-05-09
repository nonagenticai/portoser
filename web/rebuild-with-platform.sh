#!/bin/bash

# Platform-aware Docker build script
# Handles architecture detection, platform configuration, and multi-platform builds

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script configuration
VERBOSE=${VERBOSE:-false}
CLEANUP_IMAGES=${CLEANUP_IMAGES:-false}
MULTI_ARCH=${MULTI_ARCH:-false}
BUILD_METHOD=${BUILD_METHOD:-"compose"}  # "compose" or "buildx"

# Logging functions
log() {
    echo -e "${BLUE}[BUILD]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1"
    fi
}

# Function to detect host architecture
detect_architecture() {
    local arch
    arch=$(uname -m)
    case $arch in
        arm64|aarch64)
            ARCH="arm64"
            PLATFORM="linux/arm64"
            PLATFORM_LABEL="ARM64 (M1/M2/M3)"
            ;;
        x86_64|x86)
            ARCH="amd64"
            PLATFORM="linux/amd64"
            PLATFORM_LABEL="AMD64 (Intel)"
            ;;
        *)
            error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac

    verbose "Detected native architecture: $arch -> $ARCH"
    verbose "Docker platform: $PLATFORM"
}

# Function to verify Docker installation and availability
verify_docker() {
    log "Verifying Docker installation..."

    if ! command -v docker &> /dev/null; then
        error "Docker is not installed or not in PATH"
        exit 1
    fi

    verbose "Docker found at: $(command -v docker)"

    if ! docker ps > /dev/null 2>&1; then
        error "Docker daemon is not running or inaccessible"
        exit 1
    fi

    success "Docker is available and running"
}

# Function to verify Docker buildx availability (for multi-arch builds)
verify_buildx() {
    log "Verifying Docker buildx availability..."

    if ! docker buildx version > /dev/null 2>&1; then
        warn "Docker buildx is not available"
        return 1
    fi

    verbose "Docker buildx version: $(docker buildx version | head -1)"
    success "Docker buildx is available"
    return 0
}

# Function to verify Docker Compose availability
verify_compose() {
    log "Verifying Docker Compose installation..."

    if ! command -v docker-compose &> /dev/null && ! docker compose > /dev/null 2>&1; then
        error "Docker Compose is not installed"
        exit 1
    fi

    verbose "Docker Compose found"
    success "Docker Compose is available"
}

# Function to display platform information
display_platform_info() {
    log "=== Platform Configuration ==="
    echo "  Host Architecture: $PLATFORM_LABEL"
    echo "  Docker Platform:  $PLATFORM"
    echo "  Build Method:     $BUILD_METHOD"
    if [ "$MULTI_ARCH" = true ]; then
        echo "  Multi-Arch:       Enabled (linux/amd64,linux/arm64)"
    else
        echo "  Multi-Arch:       Disabled (single platform)"
    fi
    if [ "$VERBOSE" = true ]; then
        echo "  Verbose Output:   Enabled"
    fi
    if [ "$CLEANUP_IMAGES" = true ]; then
        echo "  Cleanup:          Enabled"
    fi
    echo "================================="
}

# Function to set environment variables
set_environment() {
    log "Setting environment variables..."

    export DOCKER_DEFAULT_PLATFORM=$PLATFORM
    verbose "DOCKER_DEFAULT_PLATFORM=$DOCKER_DEFAULT_PLATFORM"

    # Additional platform-specific settings if needed
    if [ "$ARCH" = "arm64" ]; then
        verbose "Applying ARM64-specific settings..."
        # ARM64-specific environment variables can be set here if needed
    else
        verbose "Applying AMD64-specific settings..."
        # AMD64-specific environment variables can be set here if needed
    fi

    success "Environment variables configured"
}

# Function to clean up old images
cleanup_images() {
    if [ "$CLEANUP_IMAGES" = false ]; then
        return
    fi

    log "Cleaning up old Docker images..."

    # Remove dangling images
    verbose "Removing dangling images..."
    docker image prune -f --filter "dangling=true" || true

    # Optionally remove all unused images (with confirmation in interactive mode)
    if [ -t 0 ]; then  # Check if running in interactive mode
        read -p "Remove all unused images? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            verbose "Removing unused images..."
            docker image prune -af || true
        fi
    fi

    success "Cleanup completed"
}

# Function to build using docker compose
build_with_compose() {
    log "Building with Docker Compose (single platform)..."

    if [ ! -f "docker-compose.yml" ] && [ ! -f "docker-compose.yaml" ]; then
        error "docker-compose.yml not found in current directory"
        return 1
    fi

    verbose "Running: docker compose build --platform $PLATFORM"
    docker compose build --platform $PLATFORM

    success "Docker Compose build completed successfully"
}

# Function to build using docker buildx for multi-platform
build_with_buildx() {
    log "Building with Docker buildx (multi-platform)..."

    if [ ! -f "Dockerfile" ]; then
        error "Dockerfile not found in current directory"
        return 1
    fi

    local platforms="linux/amd64,linux/arm64"
    if [ "$MULTI_ARCH" = false ]; then
        platforms=$PLATFORM
    fi

    verbose "Running: docker buildx build --platform $platforms -t . ."
    docker buildx build --platform $platforms -t portoser:latest . || {
        error "Docker buildx build failed"
        return 1
    }

    success "Docker buildx build completed successfully"
}

# Function to perform the build
perform_build() {
    log "=== Starting Build Process ==="

    case $BUILD_METHOD in
        compose)
            build_with_compose || return 1
            ;;
        buildx)
            build_with_buildx || return 1
            ;;
        *)
            error "Unknown build method: $BUILD_METHOD"
            return 1
            ;;
    esac
}

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Platform-aware Docker build script for multi-architecture support.

OPTIONS:
    -h, --help              Show this help message
    -v, --verbose           Enable verbose output
    -c, --cleanup           Clean up old Docker images after build
    -m, --multi-arch        Build for multiple architectures (arm64 and amd64)
    -b, --buildx            Use docker buildx instead of docker compose
    --compose               Use docker compose (default)

ENVIRONMENT VARIABLES:
    VERBOSE=true            Enable verbose output
    CLEANUP_IMAGES=true     Clean up images after build
    MULTI_ARCH=true         Build for multiple architectures
    BUILD_METHOD=buildx     Use buildx build method

EXAMPLES:
    # Basic build with platform detection
    $0

    # Verbose build with cleanup
    $0 -v -c

    # Multi-platform build using buildx
    $0 -m -b

    # With environment variables
    VERBOSE=true CLEANUP_IMAGES=true $0

EOF
}

# Parse command-line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -c|--cleanup)
                CLEANUP_IMAGES=true
                shift
                ;;
            -m|--multi-arch)
                MULTI_ARCH=true
                shift
                ;;
            -b|--buildx)
                BUILD_METHOD="buildx"
                shift
                ;;
            --compose)
                BUILD_METHOD="compose"
                shift
                ;;
            *)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Main execution function
main() {
    log "Docker Build Script Starting..."
    echo

    # Parse arguments first
    parse_arguments "$@"

    # Detect architecture
    detect_architecture

    # Verify Docker is available
    verify_docker

    # Verify required tools based on build method
    if [ "$BUILD_METHOD" = "buildx" ]; then
        verify_buildx || {
            warn "Buildx not available, falling back to compose"
            BUILD_METHOD="compose"
        }
    fi

    if [ "$BUILD_METHOD" = "compose" ]; then
        verify_compose
    fi

    # Display configuration
    echo
    display_platform_info
    echo

    # Set environment variables
    set_environment
    echo

    # Perform the build
    perform_build || {
        error "Build failed"
        exit 1
    }

    echo

    # Cleanup if requested
    if [ "$CLEANUP_IMAGES" = true ]; then
        cleanup_images
    fi

    echo
    success "=== Build Process Completed Successfully ==="
    log "The Docker images have been built for $PLATFORM_LABEL"

    if [ "$MULTI_ARCH" = true ]; then
        log "Multi-platform images: linux/amd64, linux/arm64"
    fi
}

# Trap errors and cleanup
trap 'error "Script interrupted"; exit 130' INT TERM

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
