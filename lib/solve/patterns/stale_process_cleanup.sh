#!/usr/bin/env bash
# stale_process_cleanup.sh - Solution pattern for stale PID files

set -euo pipefail
# Handles situations where PID file exists but process is not running

# Initialize global variables
PIDS_DIR="${PIDS_DIR:-$HOME/.portoser/pids}"
LOGS_DIR="${LOGS_DIR:-$HOME/.portoser/logs}"

solve_stale_process_cleanup() {
    local problem_data="$1"

    # Parse problem data: KEY|STATUS|VALUE|MESSAGE. Only key + value are used.
    local obs_key="${problem_data%%|*}"
    local rest="${problem_data#*|}"
    rest="${rest#*|}"  # Skip status
    local value="${rest%%|*}"

    # Extract service name: process_SERVICE
    local service="${obs_key#process_}"

    # Extract PID from value: stale_pid:PID
    local stale_pid="${value#stale_pid:}"

    solve_print ACTION "Cleaning up stale PID file for service: $service"
    solve_print ACTION "Stale PID: $stale_pid"

    local pid_file="$PIDS_DIR/${service}.pid"

    if [ -f "$pid_file" ]; then
        solve_print ACTION "Removing stale PID file: $pid_file"
        if rm -f "$pid_file"; then
            solve_print SUCCESS "PID file removed"
        else
            solve_print FAILED "Could not remove PID file"
            return 1
        fi
    else
        solve_print WARNING "PID file not found (may have been cleaned already)"
    fi

    # Also check for stale lock files
    local lock_file="$PIDS_DIR/${service}.lock"
    if [ -f "$lock_file" ]; then
        solve_print ACTION "Removing stale lock file: $lock_file"
        rm -f "$lock_file"
    fi

    # Check for stale log handlers
    local log_file="$LOGS_DIR/${service}.log"
    if [ -f "$log_file" ] && command -v du >/dev/null 2>&1; then
        # Truncate if very large (>100MB)
        local log_size
        log_size=$(du -m "$log_file" 2>/dev/null | cut -f1)
        if [ -n "$log_size" ] && [ "$log_size" -gt 100 ]; then
            solve_print ACTION "Log file is ${log_size}MB, rotating..."
            mv "$log_file" "$log_file.old"
            touch "$log_file"
            solve_print SUCCESS "Log file rotated"
        fi
    fi

    solve_print SUCCESS "Stale process cleanup complete"
    return 0
}
