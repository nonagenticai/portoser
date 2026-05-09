#!/usr/bin/env bash
#=============================================================================
# File: lib/utils/registry_cache.sh
# Purpose: Registry caching layer for improved performance
#
# Description:
#   Implements caching for YAML registry file reads to avoid expensive
#   repeated yq eval operations. Uses in-memory associative arrays with
#   time-based expiration.
#
# Key Features:
#   - In-memory registry field caching
#   - Time-based cache expiration (30 seconds default)
#   - Batch query optimization
#   - Cache statistics
#   - Automatic cleanup on timeout
#
# Usage Examples:
#   registry_cache_init "$CADDY_REGISTRY_PATH"
#   get_machine_ip_cached "host-a"
#   registry_cache_clear
#   registry_cache_stats
#
#=============================================================================

set -euo pipefail

# Cache configuration
REGISTRY_CACHE_TTL="${REGISTRY_CACHE_TTL:-30}"         # Cache time-to-live in seconds
REGISTRY_CACHE_BATCH_SIZE="${REGISTRY_CACHE_BATCH_SIZE:-10}"  # Batch operations

# Cache storage
declare -A REGISTRY_CACHE_DATA=()        # Stores cached values: "key|field" => "value"
declare -A REGISTRY_CACHE_TIMESTAMP=()   # Stores cache timestamps
declare -A REGISTRY_CACHE_STATS=(
    ["hits"]=0
    ["misses"]=0
    ["expires"]=0
)

# Current registry path being cached
REGISTRY_CACHE_PATH=""

#=============================================================================
# Function: registry_cache_init
# Description: Initialize registry cache with a YAML file
# Parameters: REGISTRY_FILE_PATH
# Returns: 0 on success
#=============================================================================
registry_cache_init() {
    local registry_path="$1"

    if [ -z "$registry_path" ]; then
        echo "Error: Registry path required" >&2
        return 1
    fi

    if [ ! -f "$registry_path" ]; then
        echo "Error: Registry file not found: $registry_path" >&2
        return 1
    fi

    REGISTRY_CACHE_PATH="$registry_path"

    [ "$DEBUG" = "1" ] && echo "Debug: Registry cache initialized for $registry_path" >&2
    return 0
}

#=============================================================================
# Function: registry_cache_make_key
# Description: Create cache key from query path
# Parameters: QUERY_PATH (e.g., ".hosts.host-a.ip")
# Returns: Normalized cache key
#=============================================================================
registry_cache_make_key() {
    local query="$1"
    # Normalize path by removing leading dot and spaces
    echo "$query" | sed 's/^\.//; s/ //g'
}

#=============================================================================
# Function: registry_cache_is_expired
# Description: Check if a cache entry has expired
# Parameters: CACHE_KEY
# Returns: 0 if expired, 1 if valid
#=============================================================================
registry_cache_is_expired() {
    local cache_key="$1"
    local timestamp="${REGISTRY_CACHE_TIMESTAMP[$cache_key]:-0}"
    local now
    now=$(date +%s)

    if [ $((now - timestamp)) -gt "$REGISTRY_CACHE_TTL" ]; then
        return 0  # Expired
    else
        return 1  # Still valid
    fi
}

#=============================================================================
# Function: registry_cache_get
# Description: Get value from cache with automatic expiration
# Parameters: QUERY_PATH (e.g., ".hosts.host-a.ip")
# Returns: Cached value or empty if not found/expired
#=============================================================================
registry_cache_get() {
    local query="$1"
    local cache_key

    if [ -z "$query" ]; then
        return 1
    fi

    cache_key=$(registry_cache_make_key "$query")

    # Check if key exists and is not expired
    if [ -v "REGISTRY_CACHE_DATA[$cache_key]" ]; then
        if ! registry_cache_is_expired "$cache_key"; then
            ((REGISTRY_CACHE_STATS["hits"]++))
            echo "${REGISTRY_CACHE_DATA[$cache_key]}"
            return 0
        else
            # Expired, remove from cache
            unset "REGISTRY_CACHE_DATA[$cache_key]"
            unset "REGISTRY_CACHE_TIMESTAMP[$cache_key]"
            ((REGISTRY_CACHE_STATS["expires"]++))
        fi
    fi

    ((REGISTRY_CACHE_STATS["misses"]++))
    return 1
}

#=============================================================================
# Function: registry_cache_set
# Description: Store value in cache with timestamp
# Parameters: QUERY_PATH VALUE
# Returns: 0 always
#=============================================================================
registry_cache_set() {
    local query="$1"
    local value="$2"
    local cache_key

    if [ -z "$query" ]; then
        return 1
    fi

    cache_key=$(registry_cache_make_key "$query")
    REGISTRY_CACHE_DATA[$cache_key]="$value"
    REGISTRY_CACHE_TIMESTAMP[$cache_key]=$(date +%s)

    return 0
}

#=============================================================================
# Function: registry_cache_read
# Description: Read value from cache or fetch from file
# Parameters: QUERY_PATH (e.g., ".hosts.host-a.ip")
# Returns: Value from cache or YAML file
#=============================================================================
registry_cache_read() {
    local query="$1"

    if [ -z "$query" ] || [ -z "$REGISTRY_CACHE_PATH" ]; then
        return 1
    fi

    # Try to get from cache first. The cache hit path was previously silent —
    # cached_value was assigned but never echoed, so callers got an empty
    # string for any query that hit the cache.
    local cached_value
    if cached_value=$(registry_cache_get "$query"); then
        echo "$cached_value"
        return 0
    fi

    # Not in cache, fetch from YAML file
    local value
    value=$(yq eval "$query" "$REGISTRY_CACHE_PATH" 2>/dev/null || echo "")

    if [ -n "$value" ] && [ "$value" != "null" ]; then
        registry_cache_set "$query" "$value"
        echo "$value"
        return 0
    fi

    return 1
}

#=============================================================================
# Function: registry_cache_batch_read
# Description: Read multiple values efficiently
# Parameters: QUERY1 [QUERY2 ...]
# Returns: Space-separated values
#=============================================================================
registry_cache_batch_read() {
    local results=()

    for query in "$@"; do
        if result=$(registry_cache_read "$query"); then
            results+=("$result")
        else
            results+=("")
        fi
    done

    echo "${results[@]}"
}

#=============================================================================
# Function: registry_cache_clear
# Description: Clear all cached data
# Returns: 0 always
#=============================================================================
registry_cache_clear() {
    REGISTRY_CACHE_DATA=()
    REGISTRY_CACHE_TIMESTAMP=()
    REGISTRY_CACHE_STATS=(
        ["hits"]=0
        ["misses"]=0
        ["expires"]=0
    )

    [ "$DEBUG" = "1" ] && echo "Debug: Registry cache cleared" >&2
    return 0
}

#=============================================================================
# Function: registry_cache_stats
# Description: Display cache statistics
# Returns: 0 always
#=============================================================================
registry_cache_stats() {
    local total_hits="${REGISTRY_CACHE_STATS[hits]:-0}"
    local total_misses="${REGISTRY_CACHE_STATS[misses]:-0}"
    local total_expires="${REGISTRY_CACHE_STATS[expires]:-0}"
    local total_queries
    total_queries=$((total_hits + total_misses))
    local hit_rate=0

    if [ $total_queries -gt 0 ]; then
        hit_rate=$((total_hits * 100 / total_queries))
    fi

    echo "Registry Cache Statistics:"
    echo "  Total Queries: $total_queries"
    echo "  Cache Hits: $total_hits"
    echo "  Cache Misses: $total_misses"
    echo "  Expired Entries: $total_expires"
    echo "  Hit Rate: ${hit_rate}%"
    echo "  Current Size: ${#REGISTRY_CACHE_DATA[@]} entries"
    echo "  TTL: ${REGISTRY_CACHE_TTL}s"

    return 0
}

#=============================================================================
# Function: get_machine_ip_cached
# Description: Get machine IP with caching
# Parameters: MACHINE_NAME
# Returns: IP address or empty
#=============================================================================
get_machine_ip_cached() {
    local machine="$1"

    if [ -z "$machine" ]; then
        echo "Error: Machine name required" >&2
        return 1
    fi

    registry_cache_read ".hosts.${machine}.ip"
}

#=============================================================================
# Function: get_machine_ssh_user_cached
# Description: Get SSH user with caching
# Parameters: MACHINE_NAME
# Returns: SSH user or empty
#=============================================================================
get_machine_ssh_user_cached() {
    local machine="$1"

    if [ -z "$machine" ]; then
        echo "Error: Machine name required" >&2
        return 1
    fi

    registry_cache_read ".hosts.${machine}.ssh_user"
}

#=============================================================================
# Function: get_machine_ssh_port_cached
# Description: Get SSH port with caching
# Parameters: MACHINE_NAME
# Returns: SSH port or default 22
#=============================================================================
get_machine_ssh_port_cached() {
    local machine="$1"

    if [ -z "$machine" ]; then
        echo "Error: Machine name required" >&2
        return 1
    fi

    local port
    port=$(registry_cache_read ".hosts.${machine}.ssh_port" 2>/dev/null || echo "22")
    echo "${port:-22}"
}

#=============================================================================
# Function: get_service_property_cached
# Description: Get service property with caching
# Parameters: SERVICE_NAME PROPERTY
# Returns: Property value or empty
#=============================================================================
get_service_property_cached() {
    local service="$1"
    local property="$2"

    if [ -z "$service" ] || [ -z "$property" ]; then
        echo "Error: Service and property required" >&2
        return 1
    fi

    registry_cache_read ".services.${service}.${property}"
}

#=============================================================================
# Function: registry_cache_load_all
# Description: Pre-load entire registry into cache (batch optimization)
# Returns: 0 on success
#=============================================================================
registry_cache_load_all() {
    if [ -z "$REGISTRY_CACHE_PATH" ] || [ ! -f "$REGISTRY_CACHE_PATH" ]; then
        return 1
    fi

    # Load all hosts
    local hosts
    hosts=$(yq eval '.hosts | keys | .[]' "$REGISTRY_CACHE_PATH" 2>/dev/null || echo "")

    while IFS= read -r host; do
        if [ -n "$host" ]; then
            registry_cache_read ".hosts.${host}.ip" > /dev/null
            registry_cache_read ".hosts.${host}.ssh_user" > /dev/null
            registry_cache_read ".hosts.${host}.ssh_port" > /dev/null
        fi
    done <<< "$hosts"

    # Load all services
    local services
    services=$(yq eval '.services | keys | .[]' "$REGISTRY_CACHE_PATH" 2>/dev/null || echo "")

    while IFS= read -r service; do
        if [ -n "$service" ]; then
            registry_cache_read ".services.${service}.type" > /dev/null
            registry_cache_read ".services.${service}.docker_compose" > /dev/null
        fi
    done <<< "$services"

    [ "$DEBUG" = "1" ] && echo "Debug: Registry fully pre-loaded into cache" >&2
    return 0
}

# Export functions for use in other scripts
export -f registry_cache_init
export -f registry_cache_make_key
export -f registry_cache_is_expired
export -f registry_cache_get
export -f registry_cache_set
export -f registry_cache_read
export -f registry_cache_batch_read
export -f registry_cache_clear
export -f registry_cache_stats
export -f get_machine_ip_cached
export -f get_machine_ssh_user_cached
export -f get_machine_ssh_port_cached
export -f get_service_property_cached
export -f registry_cache_load_all
