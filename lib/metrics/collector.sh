#!/usr/bin/env bash
set -euo pipefail

# Cross-Platform Metrics Collector
# Collects CPU, memory, disk, and network metrics across macOS and Linux

# Source dependencies
# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

source "$SCRIPT_DIR/lib/platform/detector.sh"
source "$SCRIPT_DIR/lib/metrics/docker_stats.sh"

# Get CPU usage percentage (0-100)
get_cpu_usage() {
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            get_cpu_usage_macos
            ;;
        linux)
            get_cpu_usage_linux
            ;;
        *)
            echo "0"
            ;;
    esac
}

# Get CPU usage on macOS
get_cpu_usage_macos() {
    # Use top to get CPU usage
    if has_command top; then
        # Get idle percentage and calculate usage
        local idle_percent
        idle_percent=$(top -l 1 -n 0 | grep "CPU usage" | awk '{print $7}' | sed 's/%//')

        if [ -n "$idle_percent" ] && [[ "$idle_percent" =~ ^[0-9.]+$ ]]; then
            echo "scale=2; 100 - ${idle_percent}" | bc
        else
            # Fallback: use ps to sum CPU percentages
            ps -A -o %cpu | awk '{sum+=$1} END {print sum}'
        fi
    else
        echo "0"
    fi
}

# Get CPU usage on Linux
get_cpu_usage_linux() {
    if [ -f /proc/stat ]; then
        # Read CPU times from /proc/stat
        local cpu_line
        cpu_line=$(grep "^cpu " /proc/stat)

        local user nice system idle iowait irq softirq
        read -r _ user nice system idle iowait irq softirq _ <<< "$cpu_line"

        # Calculate total and idle time
        local total
        total=$((user + nice + system + idle + iowait + irq + softirq))
        local idle_time
        idle_time=$((idle + iowait))

        # Sleep briefly and read again for accurate measurement
        sleep 0.1

        cpu_line=$(grep "^cpu " /proc/stat)
        read -r _ user nice system idle iowait irq softirq _ <<< "$cpu_line"

        local total2
        total2=$((user + nice + system + idle + iowait + irq + softirq))
        local idle_time2
        idle_time2=$((idle + iowait))

        # Calculate differences
        local total_diff
        total_diff=$((total2 - total))
        local idle_diff
        idle_diff=$((idle_time2 - idle_time))

        # Calculate CPU usage percentage
        if [ "$total_diff" -gt 0 ]; then
            echo "scale=2; 100 * ($total_diff - $idle_diff) / $total_diff" | bc
        else
            echo "0"
        fi
    elif has_command top; then
        # Fallback: use top
        top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}'
    else
        echo "0"
    fi
}

# Get memory usage (returns: used_mb total_mb)
get_memory_usage() {
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            get_memory_usage_macos
            ;;
        linux)
            get_memory_usage_linux
            ;;
        *)
            echo "0 0"
            ;;
    esac
}

# Get memory usage on macOS
get_memory_usage_macos() {
    if has_command vm_stat; then
        # Get page size
        local page_size=4096

        # Get vm_stat output
        local vm_output
        vm_output=$(vm_stat)

        # Parse values. Only active+wired pages count toward "used" memory;
        # free/inactive/speculative are reclaimable.
        local pages_active
        pages_active=$(echo "$vm_output" | grep "Pages active" | awk '{print $3}' | sed 's/\.//') || pages_active=0
        local pages_wired
        pages_wired=$(echo "$vm_output" | grep "Pages wired down" | awk '{print $4}' | sed 's/\.//') || pages_wired=0

        # Validate numeric values
        [[ "$pages_active" =~ ^[0-9]+$ ]] || pages_active=0
        [[ "$pages_wired" =~ ^[0-9]+$ ]] || pages_wired=0

        # Calculate memory in MB
        local used_pages
        used_pages=$((pages_active + pages_wired))
        local used_mb
        used_mb=$(echo "scale=0; $used_pages * $page_size / 1024 / 1024" | bc)

        # Get total memory
        local total_bytes
        total_bytes=$(get_total_memory_bytes)
        local total_mb
        total_mb=$(echo "scale=0; $total_bytes / 1024 / 1024" | bc)

        echo "$used_mb $total_mb"
    elif has_command top; then
        # Fallback: parse top output
        local top_output
        top_output=$(top -l 1 -n 0 | grep "PhysMem")

        local used
        used=$(echo "$top_output" | awk '{print $2}' | sed 's/[^0-9]//g')
        local total
        total=$(echo "$top_output" | awk '{print $6}' | sed 's/[^0-9]//g')

        echo "$used $total"
    else
        echo "0 0"
    fi
}

# Get memory usage on Linux
get_memory_usage_linux() {
    if has_command free; then
        # Use free command (most reliable)
        local free_output
        free_output=$(free -b | grep Mem)

        local total
        total=$(echo "$free_output" | awk '{print $2}')
        local used
        used=$(echo "$free_output" | awk '{print $3}')

        # Convert to MB
        local total_mb
        total_mb=$(echo "scale=0; $total / 1024 / 1024" | bc)
        local used_mb
        used_mb=$(echo "scale=0; $used / 1024 / 1024" | bc)

        echo "$used_mb $total_mb"
    elif [ -f /proc/meminfo ]; then
        # Fallback: parse /proc/meminfo
        local total_kb
        total_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
        local available_kb
        available_kb=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)

        if [ -z "$available_kb" ]; then
            # Older kernels don't have MemAvailable
            local free_kb
            free_kb=$(awk '/MemFree:/ {print $2}' /proc/meminfo)
            local buffers_kb
            buffers_kb=$(awk '/Buffers:/ {print $2}' /proc/meminfo)
            local cached_kb
            cached_kb=$(awk '/Cached:/ {print $2}' /proc/meminfo)
            available_kb=$((free_kb + buffers_kb + cached_kb))
        fi

        local used_kb
        used_kb=$((total_kb - available_kb))

        # Convert to MB
        local total_mb
        total_mb=$(echo "scale=0; $total_kb / 1024" | bc)
        local used_mb
        used_mb=$(echo "scale=0; $used_kb / 1024" | bc)

        echo "$used_mb $total_mb"
    else
        echo "0 0"
    fi
}

# Get disk usage (returns: used_gb total_gb available_gb)
get_disk_usage() {
    local path="${1:-.}"

    if has_command df; then
        # Use df (works on all Unix systems)
        local df_output
        df_output=$(df -k "$path" 2>/dev/null | tail -1)

        if [ -n "$df_output" ]; then
            local total_kb
            total_kb=$(echo "$df_output" | awk '{print $2}')
            local used_kb
            used_kb=$(echo "$df_output" | awk '{print $3}')
            local available_kb
            available_kb=$(echo "$df_output" | awk '{print $4}')

            # Convert to GB
            local total_gb
            total_gb=$(echo "scale=2; $total_kb / 1024 / 1024" | bc)
            local used_gb
            used_gb=$(echo "scale=2; $used_kb / 1024 / 1024" | bc)
            local available_gb
            available_gb=$(echo "scale=2; $available_kb / 1024 / 1024" | bc)

            echo "$used_gb $total_gb $available_gb"
        else
            echo "0 0 0"
        fi
    else
        echo "0 0 0"
    fi
}

# Get network I/O (returns: bytes_received bytes_transmitted)
get_network_io() {
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            get_network_io_macos
            ;;
        linux)
            get_network_io_linux
            ;;
        *)
            echo "0 0"
            ;;
    esac
}

# Get network I/O on macOS
get_network_io_macos() {
    if has_command netstat; then
        # Use netstat -ib to get interface statistics
        local netstat_output
        netstat_output=$(netstat -ib | grep -v "Name" | grep -v "lo0")

        local total_received=0
        local total_transmitted=0

        while IFS= read -r line; do
            if [ -n "$line" ]; then
                local received
                received=$(echo "$line" | awk '{print $7}')
                local transmitted
                transmitted=$(echo "$line" | awk '{print $10}')

                # Only add if numeric
                if [[ "$received" =~ ^[0-9]+$ ]]; then
                    total_received=$((total_received + received))
                fi
                if [[ "$transmitted" =~ ^[0-9]+$ ]]; then
                    total_transmitted=$((total_transmitted + transmitted))
                fi
            fi
        done <<< "$netstat_output"

        echo "$total_received $total_transmitted"
    else
        echo "0 0"
    fi
}

# Get network I/O on Linux
get_network_io_linux() {
    if [ -f /proc/net/dev ]; then
        # Parse /proc/net/dev
        local total_received=0
        local total_transmitted=0

        while IFS= read -r line; do
            # Skip header lines and loopback
            if [[ "$line" =~ ^[[:space:]]*[a-z] ]] && [[ ! "$line" =~ lo: ]]; then
                # Remove interface name and split
                local stats="${line##*:}"
                local received
                received=$(echo "$stats" | awk '{print $1}')
                local transmitted
                transmitted=$(echo "$stats" | awk '{print $9}')

                # Only add if numeric to avoid unbound variable errors
                if [[ "$received" =~ ^[0-9]+$ ]]; then
                    total_received=$((total_received + received))
                fi
                if [[ "$transmitted" =~ ^[0-9]+$ ]]; then
                    total_transmitted=$((total_transmitted + transmitted))
                fi
            fi
        done < /proc/net/dev

        echo "$total_received $total_transmitted"
    else
        echo "0 0"
    fi
}

# Get resource metrics for a specific service (via Docker or ps).
# NOTE: a per-machine metric path (SSH-based) was sketched in the original
# signature (`machine` param) but never implemented; only local metrics are
# returned today. Callers passing a machine arg are silently ignored.
get_service_resources() {
    local service_name="$1"

    # Try Docker first (most accurate for containerized services)
    if has_command docker && is_container_running "$service_name"; then
        get_service_resources_docker "$service_name"
    else
        # Fallback to process-based metrics
        get_service_resources_process "$service_name"
    fi
}

# Get service resources from Docker
get_service_resources_docker() {
    local service_name="$1"

    local stats_json
    stats_json=$(get_container_stats "$service_name")
    local exit_code=$?

    if [ "$exit_code" -eq 0 ] && [ -n "$stats_json" ]; then
        parse_docker_stats_json "$stats_json"
    else
        echo '{"error":"container_not_found"}'
    fi
}

# Get service resources from process information
get_service_resources_process() {
    local service_name="$1"

    # Find process by name
    local pids
    pids=$(pgrep -f "$service_name" 2>/dev/null || echo "")

    if [ -z "$pids" ]; then
        echo '{"error":"process_not_found"}'
        return 1
    fi

    local total_cpu=0
    local total_mem_kb=0
    local pid_count=0

    for pid in $pids; do
        # Get CPU and memory for this PID
        if has_command ps; then
            local platform
            platform=$(detect_platform)

            case "$platform" in
                macos)
                    local stats
                    stats=$(ps -p "$pid" -o %cpu,rss 2>/dev/null | tail -1)
                    if [ -n "$stats" ]; then
                        local cpu
                        cpu=$(echo "$stats" | awk '{print $1}')
                        local mem_kb
                        mem_kb=$(echo "$stats" | awk '{print $2}')

                        # Validate numeric values before arithmetic
                        if [[ "$cpu" =~ ^[0-9]+\.?[0-9]*$ ]] && [[ "$mem_kb" =~ ^[0-9]+$ ]]; then
                            total_cpu=$(echo "scale=2; $total_cpu + $cpu" | bc)
                            total_mem_kb=$((total_mem_kb + mem_kb))
                            pid_count=$((pid_count + 1))
                        fi
                    fi
                    ;;
                linux)
                    local stats
                    stats=$(ps -p "$pid" -o %cpu,rss 2>/dev/null | tail -1)
                    if [ -n "$stats" ]; then
                        local cpu
                        cpu=$(echo "$stats" | awk '{print $1}')
                        local mem_kb
                        mem_kb=$(echo "$stats" | awk '{print $2}')

                        # Validate numeric values before arithmetic
                        if [[ "$cpu" =~ ^[0-9]+\.?[0-9]*$ ]] && [[ "$mem_kb" =~ ^[0-9]+$ ]]; then
                            total_cpu=$(echo "scale=2; $total_cpu + $cpu" | bc)
                            total_mem_kb=$((total_mem_kb + mem_kb))
                            pid_count=$((pid_count + 1))
                        fi
                    fi
                    ;;
            esac
        fi
    done

    # Convert memory to MB
    local total_mem_mb
    total_mem_mb=$(echo "scale=2; $total_mem_kb / 1024" | bc)

    cat <<EOF
{
  "cpu_percent": ${total_cpu:-0},
  "memory_used_mb": ${total_mem_mb:-0},
  "process_count": $pid_count,
  "source": "process"
}
EOF
}

# Get comprehensive system metrics as JSON
get_system_metrics_json() {
    local cpu_percent
    local memory_usage
    local disk_usage
    local network_io
    local hostname
    local timestamp_iso
    local timestamp_epoch

    cpu_percent=$(get_cpu_usage)
    memory_usage=$(get_memory_usage)
    disk_usage=$(get_disk_usage /)
    network_io=$(get_network_io)
    hostname=$(hostname 2>/dev/null || echo "unknown")
    timestamp_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
    timestamp_epoch=$(date +%s 2>/dev/null || echo "0")

    local memory_used
    memory_used=$(echo "$memory_usage" | cut -d' ' -f1)
    local memory_total
    memory_total=$(echo "$memory_usage" | cut -d' ' -f2)

    local disk_used
    disk_used=$(echo "$disk_usage" | cut -d' ' -f1)
    local disk_total
    disk_total=$(echo "$disk_usage" | cut -d' ' -f2)
    local disk_available
    disk_available=$(echo "$disk_usage" | cut -d' ' -f3)

    local net_received
    net_received=$(echo "$network_io" | cut -d' ' -f1)
    local net_transmitted
    net_transmitted=$(echo "$network_io" | cut -d' ' -f2)

    cat <<EOF
{
  "hostname": "${hostname}",
  "cpu_percent": ${cpu_percent:-0},
  "memory_used_mb": ${memory_used:-0},
  "memory_total_mb": ${memory_total:-0},
  "memory": {
    "used_mb": ${memory_used:-0},
    "total_mb": ${memory_total:-0}
  },
  "disk_used_gb": ${disk_used:-0},
  "disk_total_gb": ${disk_total:-0},
  "disk": {
    "used_gb": ${disk_used:-0},
    "total_gb": ${disk_total:-0},
    "available_gb": ${disk_available:-0}
  },
  "network": {
    "received_bytes": ${net_received:-0},
    "transmitted_bytes": ${net_transmitted:-0}
  },
  "timestamp": "${timestamp_iso}",
  "timestamp_epoch": ${timestamp_epoch:-0}
}
EOF
}
