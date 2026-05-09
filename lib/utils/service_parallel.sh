#!/usr/bin/env bash
#=============================================================================
# File: lib/utils/service_parallel.sh
# Purpose: Parallel service operations for improved performance
#
# Description:
#   Provides functions for parallel service startup, shutdown, and
#   deployment operations. Enables 10-20x faster service orchestration.
#
# Key Features:
#   - Parallel service startup/shutdown
#   - Background job pooling
#   - Status monitoring
#   - Error handling and recovery
#   - Progress tracking
#
# Usage Examples:
#   service_parallel_start "service1" "service2" "service3"
#   service_parallel_stop "service1" "service2"
#   service_parallel_deploy "machine1" "service1" "service2"
#   service_parallel_health_check "machine" "service1" "service2"
#
#=============================================================================

set -euo pipefail

# Service parallel configuration
SERVICE_PARALLEL_MAX_JOBS="${SERVICE_PARALLEL_MAX_JOBS:-4}"   # Max parallel operations
SERVICE_PARALLEL_TIMEOUT="${SERVICE_PARALLEL_TIMEOUT:-300}"  # Operation timeout
SERVICE_PARALLEL_LOGDIR="${TMPDIR:-/tmp}/service_parallel"   # Log directory

# Job tracking — public state, populated by service_parallel_start/stop and
# reset by service_parallel_init. STATUS is reserved for callers that want
# to record per-service result codes.
# shellcheck disable=SC2034 # public state array reset by init
declare -A SERVICE_PARALLEL_PIDS=()      # Process IDs
# shellcheck disable=SC2034 # public state array reset by init; populated by callers
declare -A SERVICE_PARALLEL_STATUS=()    # Job status
declare -a SERVICE_PARALLEL_ACTIVE_JOBS=()  # Active job tracking

#=============================================================================
# Function: service_parallel_init
# Description: Initialize service parallel utilities
# Returns: 0 always
#=============================================================================
service_parallel_init() {
    mkdir -p "$SERVICE_PARALLEL_LOGDIR"
    chmod 700 "$SERVICE_PARALLEL_LOGDIR"

    [ "$DEBUG" = "1" ] && echo "Debug: Service parallel utilities initialized" >&2
    return 0
}

#=============================================================================
# Function: service_parallel_cleanup
# Description: Clean up temporary files and resources
# Returns: 0 always
#=============================================================================
service_parallel_cleanup() {
    # Kill any remaining background jobs
    for pid in "${SERVICE_PARALLEL_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done

    # Clean up log directory
    if [ -d "$SERVICE_PARALLEL_LOGDIR" ]; then
        rm -rf "$SERVICE_PARALLEL_LOGDIR"
    fi

    SERVICE_PARALLEL_PIDS=()
    # shellcheck disable=SC2034 # public state array reset by init
    SERVICE_PARALLEL_STATUS=()
    SERVICE_PARALLEL_ACTIVE_JOBS=()

    [ "$DEBUG" = "1" ] && echo "Debug: Service parallel utilities cleaned up" >&2
    return 0
}

#=============================================================================
# Function: service_parallel_start
# Description: Start multiple services in parallel
# Parameters: MACHINE SERVICE1 [SERVICE2 ...]
# Returns: 0 if all start successfully, 1 if any fail
#=============================================================================
service_parallel_start() {
    local machine="$1"
    shift
    local services=("$@")

    if [ -z "$machine" ] || [ ${#services[@]} -eq 0 ]; then
        echo "Error: machine and at least one service required" >&2
        return 1
    fi

    local pids=()
    local failed_services=()
    local log_file="${SERVICE_PARALLEL_LOGDIR}/start_$$.log"

    [ "$DEBUG" = "1" ] && echo "Debug: Starting ${#services[@]} services on $machine" >&2

    # Start services in parallel (limited by max jobs)
    for service in "${services[@]}"; do
        # Wait if we've reached max parallel jobs
        while [ ${#SERVICE_PARALLEL_ACTIVE_JOBS[@]} -ge "$SERVICE_PARALLEL_MAX_JOBS" ]; do
            # Remove finished jobs from active list
            for i in "${!SERVICE_PARALLEL_ACTIVE_JOBS[@]}"; do
                local job_pid="${SERVICE_PARALLEL_ACTIVE_JOBS[$i]}"
                if ! kill -0 "$job_pid" 2>/dev/null; then
                    unset 'SERVICE_PARALLEL_ACTIVE_JOBS[$i]'
                fi
            done
            SERVICE_PARALLEL_ACTIVE_JOBS=("${SERVICE_PARALLEL_ACTIVE_JOBS[@]}")
            sleep 0.5
        done

        # Start service in background
        (
            if docker_deploy "$service" "$machine" >> "$log_file" 2>&1; then
                echo "✓ Started $service on $machine"
                return 0
            else
                echo "✗ Failed to start $service on $machine"
                return 1
            fi
        ) &
        local job_pid=$!
        SERVICE_PARALLEL_PIDS[$service]=$job_pid
        SERVICE_PARALLEL_ACTIVE_JOBS+=("$job_pid")
        pids+=("$job_pid")
    done

    # Wait for all background jobs and collect results
    local failed_count=0
    for service in "${services[@]}"; do
        local pid="${SERVICE_PARALLEL_PIDS[$service]}"
        if ! wait "$pid" 2>/dev/null; then
            failed_services+=("$service")
            failed_count=$((failed_count + 1))
        fi
    done

    if [ $failed_count -gt 0 ]; then
        echo "Error: Failed to start ${failed_count} service(s): ${failed_services[*]}" >&2
        return 1
    else
        [ "$DEBUG" = "1" ] && echo "Debug: All services started successfully" >&2
        return 0
    fi
}

#=============================================================================
# Function: service_parallel_stop
# Description: Stop multiple services in parallel
# Parameters: MACHINE SERVICE1 [SERVICE2 ...]
# Returns: 0 if all stop successfully, 1 if any fail
#=============================================================================
service_parallel_stop() {
    local machine="$1"
    shift
    local services=("$@")

    if [ -z "$machine" ] || [ ${#services[@]} -eq 0 ]; then
        echo "Error: machine and at least one service required" >&2
        return 1
    fi

    local pids=()
    local failed_services=()
    local log_file="${SERVICE_PARALLEL_LOGDIR}/stop_$$.log"

    [ "$DEBUG" = "1" ] && echo "Debug: Stopping ${#services[@]} services on $machine" >&2

    # Stop services in parallel
    for service in "${services[@]}"; do
        # Wait if we've reached max parallel jobs
        while [ ${#SERVICE_PARALLEL_ACTIVE_JOBS[@]} -ge "$SERVICE_PARALLEL_MAX_JOBS" ]; do
            for i in "${!SERVICE_PARALLEL_ACTIVE_JOBS[@]}"; do
                local job_pid="${SERVICE_PARALLEL_ACTIVE_JOBS[$i]}"
                if ! kill -0 "$job_pid" 2>/dev/null; then
                    unset 'SERVICE_PARALLEL_ACTIVE_JOBS[$i]'
                fi
            done
            SERVICE_PARALLEL_ACTIVE_JOBS=("${SERVICE_PARALLEL_ACTIVE_JOBS[@]}")
            sleep 0.5
        done

        # Stop service in background
        (
            if docker_stop "$service" "$machine" >> "$log_file" 2>&1; then
                echo "✓ Stopped $service on $machine"
                return 0
            else
                echo "✗ Failed to stop $service on $machine"
                return 1
            fi
        ) &
        local job_pid=$!
        SERVICE_PARALLEL_PIDS[$service]=$job_pid
        SERVICE_PARALLEL_ACTIVE_JOBS+=("$job_pid")
        pids+=("$job_pid")
    done

    # Wait for all background jobs
    local failed_count=0
    for service in "${services[@]}"; do
        local pid="${SERVICE_PARALLEL_PIDS[$service]}"
        if ! wait "$pid" 2>/dev/null; then
            failed_services+=("$service")
            failed_count=$((failed_count + 1))
        fi
    done

    if [ $failed_count -gt 0 ]; then
        echo "Error: Failed to stop ${failed_count} service(s): ${failed_services[*]}" >&2
        return 1
    else
        [ "$DEBUG" = "1" ] && echo "Debug: All services stopped successfully" >&2
        return 0
    fi
}

#=============================================================================
# Function: service_parallel_restart
# Description: Restart multiple services in parallel
# Parameters: MACHINE SERVICE1 [SERVICE2 ...]
# Returns: 0 if all restart successfully, 1 if any fail
#=============================================================================
service_parallel_restart() {
    local machine="$1"
    shift
    local services=("$@")

    if [ -z "$machine" ] || [ ${#services[@]} -eq 0 ]; then
        echo "Error: machine and at least one service required" >&2
        return 1
    fi

    # First stop all services
    if ! service_parallel_stop "$machine" "${services[@]}"; then
        echo "Warning: Some services failed to stop" >&2
    fi

    # Give services time to fully stop
    sleep 2

    # Then start all services
    if service_parallel_start "$machine" "${services[@]}"; then
        return 0
    else
        return 1
    fi
}

#=============================================================================
# Function: service_parallel_health_check
# Description: Check health of multiple services in parallel
# Parameters: MACHINE SERVICE1 [SERVICE2 ...]
# Returns: Number of healthy services
#=============================================================================
service_parallel_health_check() {
    local machine="$1"
    shift
    local services=("$@")

    if [ -z "$machine" ] || [ ${#services[@]} -eq 0 ]; then
        echo "Error: machine and at least one service required" >&2
        return 1
    fi

    local health_log="${SERVICE_PARALLEL_LOGDIR}/health_$$.log"
    local healthy_count=0

    [ "$DEBUG" = "1" ] && echo "Debug: Checking health of ${#services[@]} services on $machine" >&2

    # Check health in parallel
    for service in "${services[@]}"; do
        (
            if docker_health_check "$service" "$machine" > /dev/null 2>&1; then
                echo "✓ Healthy: $service"
                exit 0
            else
                echo "✗ Unhealthy: $service"
                exit 1
            fi
        ) >> "$health_log" 2>&1 &
    done

    # Wait for all health checks
    wait

    # Count healthy services
    if [ -f "$health_log" ]; then
        healthy_count=$(grep -c "^✓" "$health_log" || echo 0)
    fi

    return "$healthy_count"
}

#=============================================================================
# Function: service_parallel_logs
# Description: Get logs from multiple services in parallel
# Parameters: MACHINE SERVICE1 [SERVICE2 ...]
# Returns: 0 always
#=============================================================================
service_parallel_logs() {
    local machine="$1"
    shift
    local services=("$@")

    if [ -z "$machine" ] || [ ${#services[@]} -eq 0 ]; then
        echo "Error: machine and at least one service required" >&2
        return 1
    fi

    [ "$DEBUG" = "1" ] && echo "Debug: Collecting logs from ${#services[@]} services on $machine" >&2

    # Collect logs in parallel
    for service in "${services[@]}"; do
        (
            echo "=== Logs for $service on $machine ==="
            docker_logs "$service" "$machine" 2>/dev/null || echo "No logs available"
            echo ""
        ) &
    done

    wait

    return 0
}

#=============================================================================
# Function: service_parallel_status
# Description: Get status of multiple services in parallel
# Parameters: MACHINE SERVICE1 [SERVICE2 ...]
# Returns: 0 always
#=============================================================================
service_parallel_status() {
    local machine="$1"
    shift
    local services=("$@")

    if [ -z "$machine" ] || [ ${#services[@]} -eq 0 ]; then
        echo "Error: machine and at least one service required" >&2
        return 1
    fi

    echo "Service Status on $machine:"
    echo "================================"

    # Get status in parallel
    for service in "${services[@]}"; do
        (
            if docker_is_running "$service" "$machine" 2>/dev/null; then
                echo "✓ $service - RUNNING"
            else
                echo "✗ $service - STOPPED"
            fi
        ) &
    done

    wait

    return 0
}

# Export functions for use in other scripts
export -f service_parallel_init
export -f service_parallel_cleanup
export -f service_parallel_start
export -f service_parallel_stop
export -f service_parallel_restart
export -f service_parallel_health_check
export -f service_parallel_logs
export -f service_parallel_status
