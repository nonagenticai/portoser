#!/usr/bin/env bash
#=============================================================================
# File: lib/utils/db_parallel.sh
# Purpose: Parallel database operations for improved performance
#
# Description:
#   Provides optimized functions for parallel database operations including:
#   - Parallel database backups
#   - Batch database operations
#   - Optimized rsync transfers
#   - Connection pooling for database operations
#
# Key Features:
#   - Parallel pg_dump with multiple threads
#   - Batch SSH commands
#   - Compressed transfers
#   - Connection reuse
#   - Progress tracking
#
# Usage Examples:
#   db_parallel_backup "user@host" "database" "/backup/path"
#   db_parallel_restore "user@host" "database" "/backup/file.sql"
#   db_parallel_sync_to "user@host" "/local/path" "/remote/path"
#   db_parallel_batch_exec "user@host" "cmd1" "cmd2" "cmd3"
#
#=============================================================================

set -euo pipefail

# Database operation configuration
DB_PARALLEL_WORKERS="${DB_PARALLEL_WORKERS:-4}"        # Number of parallel workers
DB_PARALLEL_TIMEOUT="${DB_PARALLEL_TIMEOUT:-300}"      # Operation timeout
DB_RSYNC_COMPRESSION="${DB_RSYNC_COMPRESSION:-6}"      # rsync compression level
DB_RSYNC_BWLIMIT="${DB_RSYNC_BWLIMIT:-0}"             # Bandwidth limit in KB/s (0 = unlimited)

# Database connection timeout
DB_CONNECT_TIMEOUT="${DB_CONNECT_TIMEOUT:-10}"
DB_PG_BIN="${DB_PG_BIN:-/opt/homebrew/opt/postgresql@18/bin}"

# Temporary files for parallel operations
DB_PARALLEL_TMPDIR="${TMPDIR:-/tmp}/db_parallel_$$"

#=============================================================================
# Function: db_parallel_init
# Description: Initialize parallel database utilities
# Returns: 0 on success
#=============================================================================
db_parallel_init() {
    mkdir -p "$DB_PARALLEL_TMPDIR"
    chmod 700 "$DB_PARALLEL_TMPDIR"

    [ "$DEBUG" = "1" ] && echo "Debug: Database parallel utilities initialized" >&2
    return 0
}

#=============================================================================
# Function: db_parallel_cleanup
# Description: Clean up temporary files
# Returns: 0 always
#=============================================================================
db_parallel_cleanup() {
    if [ -d "$DB_PARALLEL_TMPDIR" ]; then
        rm -rf "$DB_PARALLEL_TMPDIR"
    fi

    [ "$DEBUG" = "1" ] && echo "Debug: Database parallel utilities cleaned up" >&2
    return 0
}

#=============================================================================
# Function: db_parallel_backup
# Description: Perform parallel database backup
# Parameters: USER@HOST DATABASE OUTPUT_FILE [SSH_PORT]
# Returns: 0 on success, 1 on failure
#=============================================================================
# SC2029: $database, ${DB_PARALLEL_WORKERS} are validated upstream / config
# constants; remote pg_dump command is built and sent intentionally.
# shellcheck disable=SC2029
db_parallel_backup() {
    local host_spec="$1"
    local database="$2"
    local output_file="$3"
    local port="${4:-22}"

    if [ -z "$host_spec" ] || [ -z "$database" ] || [ -z "$output_file" ]; then
        echo "Error: host_spec, database, and output_file required" >&2
        return 1
    fi

    local port_opt=()
    [ "$port" != "22" ] && port_opt=(-p "$port")

    # Use pg_dump with jobs for parallel backup
    # NOTE: Only effective if remote database supports parallel dump (PostgreSQL 10+)
    if ssh "${port_opt[@]}" "$host_spec" "command -v pg_dump >/dev/null 2>&1"; then
        # Perform parallel dump if supported
        if ssh "${port_opt[@]}" "$host_spec" \
            "pg_dump --jobs=${DB_PARALLEL_WORKERS} --format=directory '$database' 2>/dev/null" \
            > "$output_file" 2>/dev/null && [ -s "$output_file" ]; then
            [ "$DEBUG" = "1" ] && echo "Debug: Parallel backup completed for $database" >&2
            return 0
        fi
    fi

    # Fallback to standard single-threaded backup
    ssh "${port_opt[@]}" "$host_spec" "pg_dump '$database'" > "$output_file" 2>/dev/null

    if [ -s "$output_file" ]; then
        return 0
    else
        echo "Error: Failed to backup database $database" >&2
        return 1
    fi
}

#=============================================================================
# Function: db_parallel_restore
# Description: Restore database from backup
# Parameters: USER@HOST DATABASE BACKUP_FILE [SSH_PORT]
# Returns: 0 on success, 1 on failure
#=============================================================================
# SC2029: $database is validated upstream; remote dropdb/createdb/psql
# command is built and sent intentionally.
# shellcheck disable=SC2029
db_parallel_restore() {
    local host_spec="$1"
    local database="$2"
    local backup_file="$3"
    local port="${4:-22}"

    if [ -z "$host_spec" ] || [ -z "$database" ] || [ -z "$backup_file" ]; then
        echo "Error: host_spec, database, and backup_file required" >&2
        return 1
    fi

    if [ ! -f "$backup_file" ]; then
        echo "Error: Backup file not found: $backup_file" >&2
        return 1
    fi

    local port_opt=()
    [ "$port" != "22" ] && port_opt=(-p "$port")

    # First, drop existing database (optional, controlled by environment)
    if [ "${DB_FORCE_RESTORE:-0}" = "1" ]; then
        ssh "${port_opt[@]}" "$host_spec" "dropdb '$database' 2>/dev/null || true" > /dev/null
        ssh "${port_opt[@]}" "$host_spec" "createdb '$database'" > /dev/null
    fi

    # Stream backup file to remote psql
    if ssh "${port_opt[@]}" "$host_spec" "psql '$database'" < "$backup_file" > /dev/null 2>&1; then
        [ "$DEBUG" = "1" ] && echo "Debug: Restore completed for $database" >&2
        return 0
    fi
    echo "Error: Failed to restore database $database" >&2
    return 1
}

#=============================================================================
# Function: db_parallel_batch_exec
# Description: Execute multiple database commands in parallel
# Parameters: USER@HOST CMD1 [CMD2 ...]
# Returns: 0 if all succeed, 1 if any fail
#=============================================================================
db_parallel_batch_exec() {
    local host_spec="$1"
    shift
    local commands=("$@")

    if [ -z "$host_spec" ] || [ ${#commands[@]} -eq 0 ]; then
        echo "Error: host_spec and at least one command required" >&2
        return 1
    fi

    local port_opt=()
    if [[ "$host_spec" =~ :([0-9]+)$ ]]; then
        port_opt=(-p "${BASH_REMATCH[1]}")
    fi

    # Build script with all commands
    local script="set -e;"
    for cmd in "${commands[@]}"; do
        script+=" $cmd;"
    done

    # Execute all in single SSH session
    if ssh "${port_opt[@]}" "$host_spec" bash -c "$script" > /dev/null 2>&1; then
        [ "$DEBUG" = "1" ] && echo "Debug: Batch execution completed on $host_spec" >&2
        return 0
    else
        echo "Error: Batch execution failed on $host_spec" >&2
        return 1
    fi
}

#=============================================================================
# Function: db_parallel_sync_to
# Description: Sync directory to remote with optimizations
# Parameters: USER@HOST LOCAL_PATH REMOTE_PATH [SSH_PORT]
# Returns: 0 on success, 1 on failure
#=============================================================================
# SC2029: $remote_path is interpolated into the remote mkdir intentionally.
# shellcheck disable=SC2029
db_parallel_sync_to() {
    local host_spec="$1"
    local local_path="$2"
    local remote_path="$3"
    local port="${4:-22}"

    if [ -z "$host_spec" ] || [ -z "$local_path" ] || [ -z "$remote_path" ]; then
        echo "Error: host_spec, local_path, and remote_path required" >&2
        return 1
    fi

    if [ ! -e "$local_path" ]; then
        echo "Error: Local path not found: $local_path" >&2
        return 1
    fi

    local port_opt=()
    local rsync_ssh="ssh"
    if [ "$port" != "22" ]; then
        port_opt=(-p "$port")
        rsync_ssh="ssh -p $port"
    fi

    local bwlimit_opt=()
    [ "$DB_RSYNC_BWLIMIT" -gt 0 ] && bwlimit_opt=("--bwlimit=${DB_RSYNC_BWLIMIT}")

    # Ensure remote directory exists
    ssh "${port_opt[@]}" "$host_spec" "mkdir -p '$remote_path'" 2>/dev/null || true

    # Use rsync with compression and optimization flags
    if rsync -e "$rsync_ssh" \
        -avz \
        --compress-level="$DB_RSYNC_COMPRESSION" \
        --delete \
        --exclude='.git' \
        --exclude='__pycache__' \
        --exclude='*.pyc' \
        --exclude='.venv' \
        --exclude='node_modules' \
        "${bwlimit_opt[@]}" \
        "$local_path/" "${host_spec}:${remote_path}/" > /dev/null 2>&1; then
        [ "$DEBUG" = "1" ] && echo "Debug: Sync completed to $host_spec:$remote_path" >&2
        return 0
    else
        echo "Error: Failed to sync to $host_spec:$remote_path" >&2
        return 1
    fi
}

#=============================================================================
# Function: db_parallel_sync_from
# Description: Sync directory from remote with optimizations
# Parameters: USER@HOST REMOTE_PATH LOCAL_PATH [SSH_PORT]
# Returns: 0 on success, 1 on failure
#=============================================================================
db_parallel_sync_from() {
    local host_spec="$1"
    local remote_path="$2"
    local local_path="$3"
    local port="${4:-22}"

    if [ -z "$host_spec" ] || [ -z "$remote_path" ] || [ -z "$local_path" ]; then
        echo "Error: host_spec, remote_path, and local_path required" >&2
        return 1
    fi

    local rsync_ssh="ssh"
    [ "$port" != "22" ] && rsync_ssh="ssh -p $port"

    local bwlimit_opt=()
    [ "$DB_RSYNC_BWLIMIT" -gt 0 ] && bwlimit_opt=("--bwlimit=${DB_RSYNC_BWLIMIT}")

    # Ensure local directory exists
    mkdir -p "$local_path" 2>/dev/null || true

    # Use rsync with compression and optimization flags
    if rsync -e "$rsync_ssh" \
        -avz \
        --compress-level="$DB_RSYNC_COMPRESSION" \
        --delete \
        --exclude='.git' \
        --exclude='__pycache__' \
        --exclude='*.pyc' \
        --exclude='.venv' \
        --exclude='node_modules' \
        "${bwlimit_opt[@]}" \
        "${host_spec}:${remote_path}/" "$local_path/" > /dev/null 2>&1; then
        [ "$DEBUG" = "1" ] && echo "Debug: Sync completed from $host_spec:$remote_path" >&2
        return 0
    else
        echo "Error: Failed to sync from $host_spec:$remote_path" >&2
        return 1
    fi
}

#=============================================================================
# Function: db_parallel_run_multiple
# Description: Run same command on multiple hosts in parallel
# Parameters: COMMAND HOST1 [HOST2 ...]
# Returns: 0 if all succeed, 1 if any fail
#=============================================================================
db_parallel_run_multiple() {
    local command="$1"
    shift
    local hosts=("$@")

    if [ -z "$command" ] || [ ${#hosts[@]} -eq 0 ]; then
        echo "Error: command and at least one host required" >&2
        return 1
    fi

    local pids=()
    local failed=0

    # Start commands in background
    for host in "${hosts[@]}"; do
        (
            if ssh "$host" bash -c "$command" > /dev/null 2>&1; then
                [ "$DEBUG" = "1" ] && echo "Debug: Completed on $host" >&2
                exit 0
            else
                [ "$DEBUG" = "1" ] && echo "Debug: Failed on $host" >&2
                exit 1
            fi
        ) &
        pids+=($!)
    done

    # Wait for all background jobs
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            failed=1
        fi
    done

    if [ $failed -eq 0 ]; then
        [ "$DEBUG" = "1" ] && echo "Debug: All parallel operations completed successfully" >&2
        return 0
    else
        echo "Error: Some parallel operations failed" >&2
        return 1
    fi
}

# Export functions for use in other scripts
export -f db_parallel_init
export -f db_parallel_cleanup
export -f db_parallel_backup
export -f db_parallel_restore
export -f db_parallel_batch_exec
export -f db_parallel_sync_to
export -f db_parallel_sync_from
export -f db_parallel_run_multiple
