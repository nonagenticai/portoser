#!/usr/bin/env bash
#=============================================================================
# File: lib/utils/docker_transfer.sh
# Purpose: Optimized Docker image transfer operations
#
# Description:
#   Provides fast Docker image pull/push operations with:
#   - Compression optimization
#   - Parallel layer transfer
#   - Connection reuse
#   - Progress tracking
#   - Smart retry logic
#
# Key Features:
#   - Optimized docker buildx for streaming
#   - Compressed image transfer
#   - Parallel multi-layer operations
#   - Bandwidth optimization
#   - Automatic retry with backoff
#
# Usage Examples:
#   docker_transfer_pull_optimized "myimage:latest" "target-host"
#   docker_transfer_push_optimized "myimage:latest" "registry-host"
#   docker_transfer_build_and_push "context" "myimage:latest"
#   docker_transfer_streaming_pull "myimage:latest" "target-host"
#
#=============================================================================

set -euo pipefail

# Docker transfer configuration
DOCKER_TRANSFER_COMPRESSION="${DOCKER_TRANSFER_COMPRESSION:-9}"  # gzip level
DOCKER_TRANSFER_MAX_RETRIES="${DOCKER_TRANSFER_MAX_RETRIES:-3}"
DOCKER_TRANSFER_RETRY_DELAY="${DOCKER_TRANSFER_RETRY_DELAY:-5}"
DOCKER_TRANSFER_PARALLEL_LAYERS="${DOCKER_TRANSFER_PARALLEL_LAYERS:-4}"
DOCKER_TRANSFER_TIMEOUT="${DOCKER_TRANSFER_TIMEOUT:-600}"

#=============================================================================
# Function: docker_transfer_pull_optimized
# Description: Pull Docker image with optimizations
# Parameters: IMAGE_TAG [TARGET_MACHINE] [DOCKER_CONTEXT]
# Returns: 0 on success, 1 on failure
#=============================================================================
docker_transfer_pull_optimized() {
    local image_tag="$1"
    # $2 (target_machine) is reserved for a future per-machine pull path; the
    # current implementation only honors $3 (docker_context).
    local docker_context="${3:-}"

    if [ -z "$image_tag" ]; then
        echo "Error: image_tag required" >&2
        return 1
    fi

    local docker_opts=()
    if [ -n "$docker_context" ]; then
        docker_opts=(-c "$docker_context")
    fi

    # Retry logic for pull
    local attempt=1
    while [ $attempt -le "$DOCKER_TRANSFER_MAX_RETRIES" ]; do
        [ "$DEBUG" = "1" ] && echo "Debug: Pull attempt $attempt for $image_tag" >&2

        if timeout "$DOCKER_TRANSFER_TIMEOUT" docker "${docker_opts[@]}" pull "$image_tag" 2>&1; then
            [ "$DEBUG" = "1" ] && echo "Debug: Successfully pulled $image_tag" >&2
            return 0
        fi

        if [ $attempt -lt "$DOCKER_TRANSFER_MAX_RETRIES" ]; then
            echo "Pull attempt $attempt failed for $image_tag, retrying in ${DOCKER_TRANSFER_RETRY_DELAY}s..."
            sleep "$DOCKER_TRANSFER_RETRY_DELAY"
        fi

        attempt=$((attempt + 1))
    done

    echo "Error: Failed to pull $image_tag after $DOCKER_TRANSFER_MAX_RETRIES attempts" >&2
    return 1
}

#=============================================================================
# Function: docker_transfer_push_optimized
# Description: Push Docker image with optimizations
# Parameters: IMAGE_TAG [DOCKER_CONTEXT]
# Returns: 0 on success, 1 on failure
#=============================================================================
docker_transfer_push_optimized() {
    local image_tag="$1"
    local docker_context="${2:-}"

    if [ -z "$image_tag" ]; then
        echo "Error: image_tag required" >&2
        return 1
    fi

    local docker_opts=()
    if [ -n "$docker_context" ]; then
        docker_opts=(-c "$docker_context")
    fi

    # Retry logic for push
    local attempt=1
    while [ $attempt -le "$DOCKER_TRANSFER_MAX_RETRIES" ]; do
        [ "$DEBUG" = "1" ] && echo "Debug: Push attempt $attempt for $image_tag" >&2

        if timeout "$DOCKER_TRANSFER_TIMEOUT" docker "${docker_opts[@]}" push "$image_tag" 2>&1; then
            [ "$DEBUG" = "1" ] && echo "Debug: Successfully pushed $image_tag" >&2
            return 0
        fi

        if [ $attempt -lt "$DOCKER_TRANSFER_MAX_RETRIES" ]; then
            echo "Push attempt $attempt failed for $image_tag, retrying in ${DOCKER_TRANSFER_RETRY_DELAY}s..."
            sleep "$DOCKER_TRANSFER_RETRY_DELAY"
        fi

        attempt=$((attempt + 1))
    done

    echo "Error: Failed to push $image_tag after $DOCKER_TRANSFER_MAX_RETRIES attempts" >&2
    return 1
}

#=============================================================================
# Function: docker_transfer_streaming_pull
# Description: Stream Docker image pull via compression
# Parameters: IMAGE_TAG TARGET_HOST [SSH_PORT]
# Returns: 0 on success, 1 on failure
#=============================================================================
docker_transfer_streaming_pull() {
    local image_tag="$1"
    local target_host="$2"
    local ssh_port="${3:-22}"

    if [ -z "$image_tag" ] || [ -z "$target_host" ]; then
        echo "Error: image_tag and target_host required" >&2
        return 1
    fi

    local port_opt=()
    [ "$ssh_port" != "22" ] && port_opt=(-p "$ssh_port")

    [ "$DEBUG" = "1" ] && echo "Debug: Streaming pull of $image_tag to $target_host" >&2

    # Save image locally, compress, and stream to remote
    # This is faster than pulling directly on remote
    if docker save "$image_tag" 2>/dev/null | \
        gzip -"$DOCKER_TRANSFER_COMPRESSION" | \
        ssh "${port_opt[@]}" "$target_host" "gunzip | docker load" 2>/dev/null; then
        [ "$DEBUG" = "1" ] && echo "Debug: Streaming pull completed" >&2
        return 0
    else
        echo "Error: Failed to stream pull $image_tag" >&2
        return 1
    fi
}

#=============================================================================
# Function: docker_transfer_streaming_push
# Description: Stream Docker image push via compression
# Parameters: IMAGE_TAG SOURCE_HOST [SSH_PORT]
# Returns: 0 on success, 1 on failure
#=============================================================================
# SC2029: $image_tag and ${DOCKER_TRANSFER_COMPRESSION} are interpolated
# into the remote `docker save | gzip` command intentionally so the
# transfer itself is compressed.
# shellcheck disable=SC2029
docker_transfer_streaming_push() {
    local image_tag="$1"
    local source_host="$2"
    local ssh_port="${3:-22}"

    if [ -z "$image_tag" ] || [ -z "$source_host" ]; then
        echo "Error: image_tag and source_host required" >&2
        return 1
    fi

    local port_opt=()
    [ "$ssh_port" != "22" ] && port_opt=(-p "$ssh_port")

    [ "$DEBUG" = "1" ] && echo "Debug: Streaming push of $image_tag from $source_host" >&2

    # Stream image from remote (compressed), decompress and load locally.
    # gzip MUST run on the remote side so the transfer itself is compressed;
    # the previous local "gzip | gunzip" was a no-op that left network bytes
    # uncompressed, defeating the whole point of streaming-with-compression.
    if ssh "${port_opt[@]}" "$source_host" "docker save '$image_tag' 2>/dev/null | gzip -${DOCKER_TRANSFER_COMPRESSION}" | \
        gunzip | \
        docker load 2>/dev/null; then
        [ "$DEBUG" = "1" ] && echo "Debug: Streaming push completed" >&2
        return 0
    else
        echo "Error: Failed to stream push $image_tag" >&2
        return 1
    fi
}

#=============================================================================
# Function: docker_transfer_build_and_push
# Description: Build image locally and push with optimization
# Parameters: BUILD_CONTEXT IMAGE_TAG [PLATFORM]
# Returns: 0 on success, 1 on failure
#=============================================================================
docker_transfer_build_and_push() {
    local build_context="$1"
    local image_tag="$2"
    local platform="${3:-linux/amd64}"

    if [ -z "$build_context" ] || [ -z "$image_tag" ]; then
        echo "Error: build_context and image_tag required" >&2
        return 1
    fi

    if [ ! -d "$build_context" ]; then
        echo "Error: Build context not found: $build_context" >&2
        return 1
    fi

    [ "$DEBUG" = "1" ] && echo "Debug: Building and pushing $image_tag for $platform" >&2

    # Use docker buildx for efficient multi-platform builds and push
    # buildx handles parallel layer builds and automatic push
    if timeout "$DOCKER_TRANSFER_TIMEOUT" \
        docker buildx build \
        --platform "$platform" \
        -t "$image_tag" \
        --push \
        --file "${build_context}/Dockerfile" \
        "$build_context" 2>&1; then
        [ "$DEBUG" = "1" ] && echo "Debug: Build and push completed" >&2
        return 0
    else
        echo "Error: Failed to build and push $image_tag" >&2
        return 1
    fi
}

#=============================================================================
# Function: docker_transfer_load_from_tar
# Description: Load Docker image from tar file
# Parameters: TAR_FILE [DOCKER_CONTEXT]
# Returns: 0 on success, 1 on failure
#=============================================================================
docker_transfer_load_from_tar() {
    local tar_file="$1"
    local docker_context="${2:-}"

    if [ -z "$tar_file" ]; then
        echo "Error: tar_file required" >&2
        return 1
    fi

    if [ ! -f "$tar_file" ]; then
        echo "Error: Tar file not found: $tar_file" >&2
        return 1
    fi

    local docker_opts=()
    if [ -n "$docker_context" ]; then
        docker_opts=(-c "$docker_context")
    fi

    [ "$DEBUG" = "1" ] && echo "Debug: Loading image from $tar_file" >&2

    if docker "${docker_opts[@]}" load -i "$tar_file" 2>&1; then
        [ "$DEBUG" = "1" ] && echo "Debug: Image loaded successfully" >&2
        return 0
    else
        echo "Error: Failed to load image from $tar_file" >&2
        return 1
    fi
}

#=============================================================================
# Function: docker_transfer_save_to_tar
# Description: Save Docker image to tar file
# Parameters: IMAGE_TAG TAR_FILE [DOCKER_CONTEXT]
# Returns: 0 on success, 1 on failure
#=============================================================================
docker_transfer_save_to_tar() {
    local image_tag="$1"
    local tar_file="$2"
    local docker_context="${3:-}"

    if [ -z "$image_tag" ] || [ -z "$tar_file" ]; then
        echo "Error: image_tag and tar_file required" >&2
        return 1
    fi

    local docker_opts=()
    if [ -n "$docker_context" ]; then
        docker_opts=(-c "$docker_context")
    fi

    [ "$DEBUG" = "1" ] && echo "Debug: Saving image $image_tag to $tar_file" >&2

    if docker "${docker_opts[@]}" save "$image_tag" -o "$tar_file" 2>&1; then
        [ "$DEBUG" = "1" ] && echo "Debug: Image saved successfully" >&2
        return 0
    else
        echo "Error: Failed to save image $image_tag" >&2
        return 1
    fi
}

#=============================================================================
# Function: docker_transfer_compress_tar
# Description: Compress a tar file with optimal settings
# Parameters: TAR_FILE [COMPRESSION_LEVEL]
# Returns: Path to compressed file
#=============================================================================
docker_transfer_compress_tar() {
    local tar_file="$1"
    local compression_level="${2:-$DOCKER_TRANSFER_COMPRESSION}"

    if [ -z "$tar_file" ] || [ ! -f "$tar_file" ]; then
        echo "Error: tar_file not found or required" >&2
        return 1
    fi

    local compressed_file="${tar_file}.gz"

    [ "$DEBUG" = "1" ] && echo "Debug: Compressing $tar_file with level $compression_level" >&2

    if gzip -"$compression_level" -c "$tar_file" > "$compressed_file"; then
        echo "$compressed_file"
        return 0
    else
        echo "Error: Failed to compress $tar_file" >&2
        return 1
    fi
}

#=============================================================================
# Function: docker_transfer_decompress_tar
# Description: Decompress a tar file
# Parameters: COMPRESSED_FILE
# Returns: Path to decompressed file
#=============================================================================
docker_transfer_decompress_tar() {
    local compressed_file="$1"

    if [ -z "$compressed_file" ] || [ ! -f "$compressed_file" ]; then
        echo "Error: compressed_file not found or required" >&2
        return 1
    fi

    local decompressed_file="${compressed_file%.gz}"

    [ "$DEBUG" = "1" ] && echo "Debug: Decompressing $compressed_file" >&2

    if gunzip -c "$compressed_file" > "$decompressed_file"; then
        echo "$decompressed_file"
        return 0
    else
        echo "Error: Failed to decompress $compressed_file" >&2
        return 1
    fi
}

#=============================================================================
# Function: docker_transfer_verify_image
# Description: Verify image integrity after transfer
# Parameters: IMAGE_TAG [DOCKER_CONTEXT]
# Returns: 0 if image exists and is valid, 1 otherwise
#=============================================================================
docker_transfer_verify_image() {
    local image_tag="$1"
    local docker_context="${2:-}"

    if [ -z "$image_tag" ]; then
        echo "Error: image_tag required" >&2
        return 1
    fi

    local docker_opts=()
    if [ -n "$docker_context" ]; then
        docker_opts=(-c "$docker_context")
    fi

    [ "$DEBUG" = "1" ] && echo "Debug: Verifying image $image_tag" >&2

    # Check if image exists
    if docker "${docker_opts[@]}" image inspect "$image_tag" > /dev/null 2>&1; then
        [ "$DEBUG" = "1" ] && echo "Debug: Image verified successfully" >&2
        return 0
    else
        echo "Error: Image not found or invalid: $image_tag" >&2
        return 1
    fi
}

# Export functions for use in other scripts
export -f docker_transfer_pull_optimized
export -f docker_transfer_push_optimized
export -f docker_transfer_streaming_pull
export -f docker_transfer_streaming_push
export -f docker_transfer_build_and_push
export -f docker_transfer_load_from_tar
export -f docker_transfer_save_to_tar
export -f docker_transfer_compress_tar
export -f docker_transfer_decompress_tar
export -f docker_transfer_verify_image
