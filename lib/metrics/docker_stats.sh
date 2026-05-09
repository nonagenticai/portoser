#!/usr/bin/env bash
set -euo pipefail

# Docker Statistics Collector
# Cross-platform Docker stats collection and parsing

# Source platform detector
# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

source "$SCRIPT_DIR/lib/platform/detector.sh"

# Get Docker stats for all containers (JSON format)
get_docker_stats() {
    local format_string='{"container":"{{.Container}}","name":"{{.Name}}","cpu":"{{.CPUPerc}}","memory":"{{.MemUsage}}","net_io":"{{.NetIO}}","block_io":"{{.BlockIO}}","pids":"{{.PIDs}}"}'

    if ! has_command docker; then
        echo '{"error":"docker_not_available"}' >&2
        return 1
    fi

    # Check if Docker daemon is running
    if ! docker info >/dev/null 2>&1; then
        echo '{"error":"docker_daemon_not_running"}' >&2
        return 1
    fi

    # Get stats for all running containers
    docker stats --no-stream --format "$format_string" 2>/dev/null
}

# Get Docker stats for a specific container
get_container_stats() {
    local container_name="$1"

    if [ -z "$container_name" ]; then
        echo '{"error":"container_name_required"}' >&2
        return 1
    fi

    if ! has_command docker; then
        echo '{"error":"docker_not_available"}' >&2
        return 1
    fi

    local format_string='{"container":"{{.Container}}","name":"{{.Name}}","cpu":"{{.CPUPerc}}","memory":"{{.MemUsage}}","net_io":"{{.NetIO}}","block_io":"{{.BlockIO}}","pids":"{{.PIDs}}"}'

    docker stats --no-stream --format "$format_string" "$container_name" 2>/dev/null
}

# Parse Docker memory usage string (e.g., "1.5GiB / 4GiB")
parse_docker_memory() {
    local memory_str="$1"

    # Extract used and total memory
    local used
    used=$(echo "$memory_str" | cut -d'/' -f1 | xargs)
    local total
    total=$(echo "$memory_str" | cut -d'/' -f2 | xargs)

    # Convert to MB
    local used_mb
    used_mb=$(convert_to_mb "$used")
    local total_mb
    total_mb=$(convert_to_mb "$total")

    echo "$used_mb $total_mb"
}

# Convert memory units to MB
convert_to_mb() {
    local value="$1"

    # Extract number and unit using bash parameter expansion
    local num="${value//[^0-9.]/}"
    local unit_raw="${value//[0-9.]/}"
    local unit="${unit_raw^^}"

    # Validate number
    if [ -z "$num" ] || ! [[ "$num" =~ ^[0-9.]+$ ]]; then
        echo "0"
        return 1
    fi

    case "$unit" in
        B)
            echo "scale=2; $num / 1024 / 1024" | bc
            ;;
        KIB|KB)
            echo "scale=2; $num / 1024" | bc
            ;;
        MIB|MB)
            echo "$num"
            ;;
        GIB|GB)
            echo "scale=2; $num * 1024" | bc
            ;;
        TIB|TB)
            echo "scale=2; $num * 1024 * 1024" | bc
            ;;
        *)
            echo "0"
            ;;
    esac
}

# Parse Docker network I/O string (e.g., "1.2MB / 3.4MB")
parse_docker_network_io() {
    local net_io_str="$1"

    # Extract received and transmitted
    local received
    received=$(echo "$net_io_str" | cut -d'/' -f1 | xargs)
    local transmitted
    transmitted=$(echo "$net_io_str" | cut -d'/' -f2 | xargs)

    # Convert to bytes
    local received_bytes
    received_bytes=$(convert_to_bytes "$received")
    local transmitted_bytes
    transmitted_bytes=$(convert_to_bytes "$transmitted")

    echo "$received_bytes $transmitted_bytes"
}

# Convert size units to bytes
convert_to_bytes() {
    local value="$1"

    # Extract number and unit using bash parameter expansion
    local num="${value//[^0-9.]/}"
    local unit_raw="${value//[0-9.]/}"
    local unit="${unit_raw^^}"

    case "$unit" in
        B)
            echo "$num" | cut -d. -f1
            ;;
        KB|KIB)
            echo "scale=0; $num * 1024" | bc | cut -d. -f1
            ;;
        MB|MIB)
            echo "scale=0; $num * 1024 * 1024" | bc | cut -d. -f1
            ;;
        GB|GIB)
            echo "scale=0; $num * 1024 * 1024 * 1024" | bc | cut -d. -f1
            ;;
        TB|TIB)
            echo "scale=0; $num * 1024 * 1024 * 1024 * 1024" | bc | cut -d. -f1
            ;;
        *)
            echo "0"
            ;;
    esac
}

# Parse Docker stats JSON output
parse_docker_stats_json() {
    local json_line="$1"

    # Extract fields from JSON
    local container_id
    container_id=$(echo "$json_line" | grep -o '"container":"[^"]*"' | cut -d'"' -f4)
    local name
    name=$(echo "$json_line" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
    local cpu
    cpu=$(echo "$json_line" | grep -o '"cpu":"[^"]*"' | cut -d'"' -f4 | sed 's/%//')
    local memory
    memory=$(echo "$json_line" | grep -o '"memory":"[^"]*"' | cut -d'"' -f4)
    local net_io
    net_io=$(echo "$json_line" | grep -o '"net_io":"[^"]*"' | cut -d'"' -f4)
    local block_io
    block_io=$(echo "$json_line" | grep -o '"block_io":"[^"]*"' | cut -d'"' -f4)
    local pids
    pids=$(echo "$json_line" | grep -o '"pids":"[^"]*"' | cut -d'"' -f4)

    # Parse memory
    local memory_values
    memory_values=$(parse_docker_memory "$memory")
    local memory_used
    memory_used=$(echo "$memory_values" | cut -d' ' -f1)
    local memory_total
    memory_total=$(echo "$memory_values" | cut -d' ' -f2)

    # Parse network I/O
    local net_io_values
    net_io_values=$(parse_docker_network_io "$net_io")
    local net_received
    net_received=$(echo "$net_io_values" | cut -d' ' -f1)
    local net_transmitted
    net_transmitted=$(echo "$net_io_values" | cut -d' ' -f2)

    # Output formatted JSON
    cat <<EOF
{
  "container_id": "$container_id",
  "name": "$name",
  "cpu_percent": ${cpu:-0},
  "memory_used_mb": ${memory_used:-0},
  "memory_total_mb": ${memory_total:-0},
  "network_received_bytes": ${net_received:-0},
  "network_transmitted_bytes": ${net_transmitted:-0},
  "block_io": "$block_io",
  "pids": ${pids:-0}
}
EOF
}

# Get stats for all containers as array of JSON objects
get_all_container_stats_json() {
    if ! has_command docker; then
        echo '{"error":"docker_not_available","containers":[]}'
        return 1
    fi

    local stats_output
    stats_output=$(get_docker_stats)
    local exit_code=$?

    if [ "$exit_code" -ne 0 ] || [ -z "$stats_output" ]; then
        echo '{"error":"no_containers_running","containers":[]}'
        return 0
    fi

    echo '{"containers":['

    local first=true
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            if [ "$first" = true ]; then
                first=false
            else
                echo ","
            fi
            parse_docker_stats_json "$line" | tr -d '\n'
        fi
    done <<< "$stats_output"

    echo ']}'
}

# Get container ID by name or partial match
get_container_id() {
    local name="$1"

    if ! has_command docker; then
        return 1
    fi

    docker ps --filter "name=$name" --format '{{.ID}}' | head -1
}

# Check if container is running
is_container_running() {
    local name="$1"

    if ! has_command docker; then
        return 1
    fi

    local count
    count=$(docker ps --filter "name=$name" --format '{{.ID}}' | wc -l | tr -d ' ')

    [ "$count" -gt 0 ]
}
