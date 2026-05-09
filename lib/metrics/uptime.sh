#!/usr/bin/env bash
set -euo pipefail

# Uptime Tracking Library
# Track service start/stop events and calculate uptime metrics

# Source dependencies
# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

source "$SCRIPT_DIR/lib/platform/detector.sh"

# Uptime data directory
UPTIME_DIR="${HOME}/.portoser/metrics/uptime"
RESOURCES_DIR="${HOME}/.portoser/metrics/resources"
SUMMARY_DIR="${HOME}/.portoser/metrics/summary"

# Initialize uptime tracking directories
init_uptime_tracking() {
    mkdir -p "$UPTIME_DIR"
    mkdir -p "$RESOURCES_DIR"
    mkdir -p "$SUMMARY_DIR"
}

# Get event log path for service
get_event_log_path() {
    local service="$1"
    local machine="$2"

    echo "$UPTIME_DIR/${service}-${machine}.log"
}

# Get stats file path for service
get_stats_file_path() {
    local service="$1"
    local machine="$2"

    echo "$UPTIME_DIR/${service}-${machine}-stats.json"
}

# Get summary file path for service
get_summary_file_path() {
    local service="$1"
    local machine="$2"

    echo "$SUMMARY_DIR/${service}-${machine}-summary.json"
}

# Record service start event
record_service_start() {
    local service="$1"
    local machine="$2"
    local pid="${3:-}"
    local details="${4:-}"

    init_uptime_tracking

    local log_file
    log_file=$(get_event_log_path "$service" "$machine")

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Format: timestamp|event_type|service|machine|details
    local event_details="pid=$pid"
    if [ -n "$details" ]; then
        event_details="$event_details,$details"
    fi

    echo "$timestamp|start|$service|$machine|$event_details" >> "$log_file"

    # Update statistics
    update_service_stats "$service" "$machine"
}

# Record service stop event
record_service_stop() {
    local service="$1"
    local machine="$2"
    local exit_code="${3:-0}"
    local details="${4:-}"

    init_uptime_tracking

    local log_file
    log_file=$(get_event_log_path "$service" "$machine")

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local event_details="exit_code=$exit_code"
    if [ -n "$details" ]; then
        event_details="$event_details,$details"
    fi

    echo "$timestamp|stop|$service|$machine|$event_details" >> "$log_file"

    # Update statistics
    update_service_stats "$service" "$machine"
}

# Record service failure event
record_service_failure() {
    local service="$1"
    local machine="$2"
    local reason="${3:-unknown}"
    local exit_code="${4:-1}"

    init_uptime_tracking

    local log_file
    log_file=$(get_event_log_path "$service" "$machine")

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    echo "$timestamp|failure|$service|$machine|reason=$reason,exit_code=$exit_code" >> "$log_file"

    # Update statistics
    update_service_stats "$service" "$machine"
}

# Record service recovery event
record_service_recovery() {
    local service="$1"
    local machine="$2"
    local auto_heal="${3:-false}"
    local details="${4:-}"

    init_uptime_tracking

    local log_file
    log_file=$(get_event_log_path "$service" "$machine")

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local event_details="auto_heal=$auto_heal"
    if [ -n "$details" ]; then
        event_details="$event_details,$details"
    fi

    echo "$timestamp|recovery|$service|$machine|$event_details" >> "$log_file"

    # Update statistics
    update_service_stats "$service" "$machine"
}

# Calculate total uptime for service (in seconds)
calculate_uptime() {
    local service="$1"
    local machine="$2"
    local since_timestamp="${3:-}"

    local log_file
    log_file=$(get_event_log_path "$service" "$machine")

    if [ ! -f "$log_file" ]; then
        echo "0"
        return 0
    fi

    local total_uptime=0
    local last_start=""

    while IFS='|' read -r timestamp event_type svc mach details; do
        # Skip if before 'since' timestamp
        if [ -n "$since_timestamp" ] && [[ "$timestamp" < "$since_timestamp" ]]; then
            continue
        fi

        case "$event_type" in
            start|recovery)
                last_start="$timestamp"
                ;;
            stop|failure)
                if [ -n "$last_start" ]; then
                    local uptime_period
                    uptime_period=$(calculate_time_diff "$last_start" "$timestamp")
                    total_uptime=$((total_uptime + uptime_period))
                    last_start=""
                fi
                ;;
        esac
    done < "$log_file"

    # If service is still running, add time until now
    if [ -n "$last_start" ]; then
        local now
        now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        local uptime_period
        uptime_period=$(calculate_time_diff "$last_start" "$now")
        total_uptime=$((total_uptime + uptime_period))
    fi

    echo "$total_uptime"
}

# Calculate total downtime for service (in seconds)
calculate_downtime() {
    local service="$1"
    local machine="$2"
    local since_timestamp="${3:-}"

    local log_file
    log_file=$(get_event_log_path "$service" "$machine")

    if [ ! -f "$log_file" ]; then
        echo "0"
        return 0
    fi

    local total_downtime=0
    local last_stop=""

    while IFS='|' read -r timestamp event_type svc mach details; do
        # Skip if before 'since' timestamp
        if [ -n "$since_timestamp" ] && [[ "$timestamp" < "$since_timestamp" ]]; then
            continue
        fi

        case "$event_type" in
            stop|failure)
                last_stop="$timestamp"
                ;;
            start|recovery)
                if [ -n "$last_stop" ]; then
                    local downtime_period
                    downtime_period=$(calculate_time_diff "$last_stop" "$timestamp")
                    total_downtime=$((total_downtime + downtime_period))
                    last_stop=""
                fi
                ;;
        esac
    done < "$log_file"

    # If service is currently down, add time until now
    if [ -n "$last_stop" ]; then
        local now
        now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        local downtime_period
        downtime_period=$(calculate_time_diff "$last_stop" "$now")
        total_downtime=$((total_downtime + downtime_period))
    fi

    echo "$total_downtime"
}

# Calculate Mean Time Between Failures (MTBF)
calculate_mtbf() {
    local service="$1"
    local machine="$2"

    local log_file
    log_file=$(get_event_log_path "$service" "$machine")

    if [ ! -f "$log_file" ]; then
        echo "0"
        return 0
    fi

    # Count failures
    local failure_count
    failure_count=$(grep -c "|failure|" "$log_file" || true)

    if [ "$failure_count" -eq 0 ]; then
        echo "0"
        return 0
    fi

    # Get total uptime
    local total_uptime
    total_uptime=$(calculate_uptime "$service" "$machine")

    # MTBF = total uptime / number of failures
    echo "scale=0; $total_uptime / $failure_count" | bc
}

# Calculate Mean Time To Recovery (MTTR)
calculate_mttr() {
    local service="$1"
    local machine="$2"

    local log_file
    log_file=$(get_event_log_path "$service" "$machine")

    if [ ! -f "$log_file" ]; then
        echo "0"
        return 0
    fi

    local total_recovery_time=0
    local recovery_count=0
    local last_failure=""

    while IFS='|' read -r timestamp event_type svc mach details; do
        case "$event_type" in
            failure)
                last_failure="$timestamp"
                ;;
            recovery)
                if [ -n "$last_failure" ]; then
                    local recovery_time
                    recovery_time=$(calculate_time_diff "$last_failure" "$timestamp")
                    total_recovery_time=$((total_recovery_time + recovery_time))
                    recovery_count=$((recovery_count + 1))
                    last_failure=""
                fi
                ;;
        esac
    done < "$log_file"

    if [ "$recovery_count" -eq 0 ]; then
        echo "0"
        return 0
    fi

    # MTTR = total recovery time / number of recoveries
    echo "scale=0; $total_recovery_time / $recovery_count" | bc
}

# Calculate availability percentage
calculate_availability() {
    local service="$1"
    local machine="$2"

    local uptime
    local downtime

    uptime=$(calculate_uptime "$service" "$machine")
    downtime=$(calculate_downtime "$service" "$machine")

    local total_time
    total_time=$((uptime + downtime))

    if [ "$total_time" -eq 0 ]; then
        echo "100"
        return 0
    fi

    # Availability = (uptime / total_time) * 100
    echo "scale=2; ($uptime * 100) / $total_time" | bc
}

# Calculate time difference between two timestamps (in seconds)
calculate_time_diff() {
    local start="$1"
    local end="$2"

    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            local start_epoch
            local end_epoch
            start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$start" "+%s" 2>/dev/null || echo "0")
            end_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$end" "+%s" 2>/dev/null || echo "0")

            # Validate epoch values
            if [ "$start_epoch" = "0" ] || [ "$end_epoch" = "0" ]; then
                echo "0"
                return 1
            fi
            echo $((end_epoch - start_epoch))
            ;;
        linux)
            local start_epoch
            local end_epoch
            start_epoch=$(date -d "$start" "+%s" 2>/dev/null || echo "0")
            end_epoch=$(date -d "$end" "+%s" 2>/dev/null || echo "0")
            echo $((end_epoch - start_epoch))
            ;;
        *)
            echo "0"
            ;;
    esac
}

# Update service statistics
update_service_stats() {
    local service="$1"
    local machine="$2"

    local stats_file
    stats_file=$(get_stats_file_path "$service" "$machine")

    local uptime
    local downtime
    local availability
    local mtbf
    local mttr

    uptime=$(calculate_uptime "$service" "$machine")
    downtime=$(calculate_downtime "$service" "$machine")
    availability=$(calculate_availability "$service" "$machine")
    mtbf=$(calculate_mtbf "$service" "$machine")
    mttr=$(calculate_mttr "$service" "$machine")

    # Get event counts
    local log_file
    log_file=$(get_event_log_path "$service" "$machine")

    local start_count=0
    local stop_count=0
    local failure_count=0
    local recovery_count=0

    if [ -f "$log_file" ]; then
        start_count=$(grep -c "|start|" "$log_file" 2>/dev/null) || start_count=0
        stop_count=$(grep -c "|stop|" "$log_file" 2>/dev/null) || stop_count=0
        failure_count=$(grep -c "|failure|" "$log_file" 2>/dev/null) || failure_count=0
        recovery_count=$(grep -c "|recovery|" "$log_file" 2>/dev/null) || recovery_count=0
    fi

    # Write statistics as JSON
    cat > "$stats_file" <<EOF
{
  "service": "$service",
  "machine": "$machine",
  "uptime_seconds": $uptime,
  "downtime_seconds": $downtime,
  "availability_percent": ${availability:-100},
  "mtbf_seconds": ${mtbf:-0},
  "mttr_seconds": ${mttr:-0},
  "event_counts": {
    "starts": $start_count,
    "stops": $stop_count,
    "failures": $failure_count,
    "recoveries": $recovery_count
  },
  "last_updated": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
}

# Get uptime statistics as JSON
get_uptime_stats_json() {
    local service="$1"
    local machine="$2"

    local stats_file
    stats_file=$(get_stats_file_path "$service" "$machine")

    if [ -f "$stats_file" ]; then
        cat "$stats_file"
    else
        # Generate fresh statistics
        update_service_stats "$service" "$machine"
        if [ -f "$stats_file" ]; then
            cat "$stats_file"
        else
            echo '{"error":"no_statistics_available"}'
        fi
    fi
}

# Get uptime history for service
get_uptime_history() {
    local service="$1"
    local machine="$2"
    local days="${3:-7}"

    local log_file
    log_file=$(get_event_log_path "$service" "$machine")

    if [ ! -f "$log_file" ]; then
        echo '{"events":[]}'
        return 0
    fi

    # Calculate cutoff timestamp
    local platform
    platform=$(detect_platform)

    local cutoff_timestamp
    case "$platform" in
        macos)
            cutoff_timestamp=$(date -v-"${days}"d -u +"%Y-%m-%dT%H:%M:%SZ")
            ;;
        linux)
            cutoff_timestamp=$(date -d "$days days ago" -u +"%Y-%m-%dT%H:%M:%SZ")
            ;;
        *)
            cutoff_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            ;;
    esac

    echo '{"events":['

    local first=true
    while IFS='|' read -r timestamp event_type svc mach details; do
        # Skip events before cutoff
        if [[ "$timestamp" < "$cutoff_timestamp" ]]; then
            continue
        fi

        if [ "$first" = true ]; then
            first=false
        else
            echo ","
        fi

        cat <<EOF
    {
      "timestamp": "$timestamp",
      "event": "$event_type",
      "service": "$svc",
      "machine": "$mach",
      "details": "$details"
    }
EOF
    done < "$log_file"

    echo ']}'
}

# Get current service status from uptime logs (running or stopped)
get_service_uptime_status() {
    local service="$1"
    local machine="$2"

    local log_file
    log_file=$(get_event_log_path "$service" "$machine")

    if [ ! -f "$log_file" ]; then
        echo "unknown"
        return 0
    fi

    # Get last event
    local last_event
    last_event=$(tail -1 "$log_file" | cut -d'|' -f2)

    case "$last_event" in
        start|recovery)
            echo "running"
            ;;
        stop|failure)
            echo "stopped"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}
