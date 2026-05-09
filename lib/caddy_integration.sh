#!/usr/bin/env bash
################################################################################
# Caddy Integration Module - Production Ready
#
# Purpose: Provides robust Caddy configuration management with comprehensive
#          error handling, logging, and rollback capabilities.
#
# Features:
#   - Proper log file permission handling
#   - Backup and rollback on validation failure
#   - Type-safe bash (set -euo pipefail maintained)
#   - Clear error messages and comprehensive logging
#   - Zero-downtime configuration updates
#
# Usage: Source this file from cluster-compose.sh to replace lines 730-858
################################################################################

set -euo pipefail

# Global log file for cluster operations
readonly CLUSTER_LOG="/tmp/cluster-compose.log"
readonly CADDY_LOG="/tmp/portoser-caddy.log"
readonly BACKUP_DIR="/tmp/caddy-backups"

################################################################################
# Function: setup_caddy_logging
#
# Purpose: Ensures Caddy log file exists and has proper permissions before
#          any Caddy operations. Prevents "permission denied" errors.
#
# Arguments: None
#
# Returns:
#   0 - Log setup successful
#   1 - Failed to setup logging
#
# Side Effects:
#   - Creates log file if it doesn't exist
#   - Fixes ownership if file is owned by root
#   - Writes status to cluster log
################################################################################
setup_caddy_logging() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[$timestamp] Setting up Caddy logging..." | tee -a "$CLUSTER_LOG"

    # Check if log file exists and is owned by root
    if [ -f "$CADDY_LOG" ]; then
        local owner
        owner=$(stat -f '%Su' "$CADDY_LOG" 2>/dev/null || stat -c '%U' "$CADDY_LOG" 2>/dev/null)

        if [ "$owner" = "root" ]; then
            echo "[$timestamp] WARNING: Caddy log owned by root, attempting to fix..." | tee -a "$CLUSTER_LOG"

            # Try to change ownership to current user
            if sudo chown "$(whoami)" "$CADDY_LOG" 2>/dev/null; then
                echo "[$timestamp] ✓ Fixed log file ownership" | tee -a "$CLUSTER_LOG"
            else
                echo "[$timestamp] ERROR: Cannot fix log ownership. Manual intervention required:" | tee -a "$CLUSTER_LOG"
                echo "[$timestamp]   Run: sudo chown \$(whoami) $CADDY_LOG" | tee -a "$CLUSTER_LOG"
                return 1
            fi
        fi

        # Verify log is writable
        if [ ! -w "$CADDY_LOG" ]; then
            echo "[$timestamp] ERROR: Caddy log is not writable: $CADDY_LOG" | tee -a "$CLUSTER_LOG"
            return 1
        fi
    else
        # Create log file with proper permissions
        if touch "$CADDY_LOG" 2>/dev/null; then
            chmod 644 "$CADDY_LOG"
            echo "[$timestamp] ✓ Created Caddy log file: $CADDY_LOG" | tee -a "$CLUSTER_LOG"
        else
            echo "[$timestamp] ERROR: Cannot create Caddy log file: $CADDY_LOG" | tee -a "$CLUSTER_LOG"
            return 1
        fi
    fi

    echo "[$timestamp] ✓ Caddy logging setup complete" | tee -a "$CLUSTER_LOG"
    return 0
}

################################################################################
# Function: backup_caddyfile
#
# Purpose: Creates a timestamped backup of the current Caddyfile before
#          any modifications. Essential for rollback on validation failure.
#
# Arguments:
#   $1 - Path to Caddyfile to backup
#
# Returns:
#   0 - Backup successful, sets global BACKUP_FILE variable
#   1 - Backup failed
#
# Side Effects:
#   - Creates backup directory if needed
#   - Creates timestamped backup file
#   - Sets BACKUP_FILE global variable
#   - Writes status to cluster log
################################################################################
backup_caddyfile() {
    local caddyfile="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [ -z "$caddyfile" ]; then
        echo "[$timestamp] ERROR: backup_caddyfile: No Caddyfile path provided" | tee -a "$CLUSTER_LOG"
        return 1
    fi

    if [ ! -f "$caddyfile" ]; then
        echo "[$timestamp] WARNING: Caddyfile does not exist yet: $caddyfile" | tee -a "$CLUSTER_LOG"
        echo "[$timestamp]   This is normal for first-time setup" | tee -a "$CLUSTER_LOG"
        BACKUP_FILE=""
        return 0
    fi

    # Create backup directory
    if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
        echo "[$timestamp] ERROR: Cannot create backup directory: $BACKUP_DIR" | tee -a "$CLUSTER_LOG"
        return 1
    fi

    # Generate backup filename with timestamp
    local backup_timestamp
    backup_timestamp=$(date '+%Y%m%d_%H%M%S')
    BACKUP_FILE="${BACKUP_DIR}/Caddyfile.backup.${backup_timestamp}"

    # Create backup
    if cp "$caddyfile" "$BACKUP_FILE" 2>/dev/null; then
        echo "[$timestamp] ✓ Backup created: $BACKUP_FILE" | tee -a "$CLUSTER_LOG"
        return 0
    else
        echo "[$timestamp] ERROR: Failed to create backup of: $caddyfile" | tee -a "$CLUSTER_LOG"
        BACKUP_FILE=""
        return 1
    fi
}

################################################################################
# Function: regenerate_caddy_config
#
# Purpose: Regenerates Caddyfile from registry.yml using portoser command.
#          Handles all error cases and provides detailed status reporting.
#
# Arguments:
#   $1 - Path to portoser script directory
#
# Returns:
#   0 - Regeneration successful
#   1 - Regeneration failed
#
# Side Effects:
#   - Runs portoser caddy regenerate command
#   - Writes detailed status to cluster log
#   - Does NOT move/modify files (that's handled by portoser)
################################################################################
regenerate_caddy_config() {
    local script_dir="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [ -z "$script_dir" ]; then
        echo "[$timestamp] ERROR: regenerate_caddy_config: No script directory provided" | tee -a "$CLUSTER_LOG"
        return 1
    fi

    if [ ! -f "$script_dir/portoser" ]; then
        echo "[$timestamp] ERROR: portoser script not found: $script_dir/portoser" | tee -a "$CLUSTER_LOG"
        return 1
    fi

    echo "[$timestamp] Regenerating Caddyfile from registry..." | tee -a "$CLUSTER_LOG"

    # Change to script directory and run regenerate command
    # Capture both stdout and stderr for logging
    local regen_output
    local regen_exit_code

    if regen_output=$(cd "$script_dir" && ./portoser caddy regenerate 2>&1); then
        regen_exit_code=0
    else
        regen_exit_code=$?
    fi

    # Log the output
    echo "$regen_output" | while IFS= read -r line; do
        echo "[$timestamp]   $line" | tee -a "$CLUSTER_LOG"
    done

    if [ $regen_exit_code -eq 0 ]; then
        echo "[$timestamp] ✓ Caddyfile regeneration successful" | tee -a "$CLUSTER_LOG"
        return 0
    else
        echo "[$timestamp] ERROR: Caddyfile regeneration failed (exit code: $regen_exit_code)" | tee -a "$CLUSTER_LOG"
        return 1
    fi
}

################################################################################
# Function: validate_caddy_config
#
# Purpose: Validates the Caddyfile syntax using caddy validate command.
#          Critical check before attempting to reload Caddy service.
#
# Arguments:
#   $1 - Path to Caddyfile to validate
#
# Returns:
#   0 - Validation successful
#   1 - Validation failed
#
# Side Effects:
#   - Runs caddy validate command
#   - Writes validation output to cluster log
################################################################################
validate_caddy_config() {
    local caddyfile="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [ -z "$caddyfile" ]; then
        echo "[$timestamp] ERROR: validate_caddy_config: No Caddyfile path provided" | tee -a "$CLUSTER_LOG"
        return 1
    fi

    if [ ! -f "$caddyfile" ]; then
        echo "[$timestamp] ERROR: Caddyfile not found: $caddyfile" | tee -a "$CLUSTER_LOG"
        return 1
    fi

    echo "[$timestamp] Validating Caddyfile..." | tee -a "$CLUSTER_LOG"

    # Run validation and capture output
    local validate_output
    local validate_exit_code

    if validate_output=$(caddy validate --adapter caddyfile --config "$caddyfile" 2>&1); then
        validate_exit_code=0
    else
        validate_exit_code=$?
    fi

    # Log validation output
    if [ -n "$validate_output" ]; then
        echo "$validate_output" | while IFS= read -r line; do
            echo "[$timestamp]   $line" | tee -a "$CLUSTER_LOG"
        done
    fi

    if [ $validate_exit_code -eq 0 ]; then
        echo "[$timestamp] ✓ Caddyfile validation successful" | tee -a "$CLUSTER_LOG"
        return 0
    else
        echo "[$timestamp] ERROR: Caddyfile validation failed (exit code: $validate_exit_code)" | tee -a "$CLUSTER_LOG"
        echo "[$timestamp]   Check validation output above for details" | tee -a "$CLUSTER_LOG"
        return 1
    fi
}

################################################################################
# Function: reload_caddy_service
#
# Purpose: Reloads Caddy service with new configuration. Uses caddy reload
#          command for zero-downtime updates.
#
# Arguments:
#   $1 - Caddy host (from registry)
#   $2 - Path to Caddyfile
#
# Returns:
#   0 - Reload successful
#   1 - Reload failed
#
# Side Effects:
#   - Runs caddy reload command (possibly via SSH)
#   - Writes reload status to cluster log
################################################################################
reload_caddy_service() {
    local caddy_host="$1"
    local caddyfile="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [ -z "$caddy_host" ]; then
        echo "[$timestamp] ERROR: reload_caddy_service: No Caddy host provided" | tee -a "$CLUSTER_LOG"
        return 1
    fi

    if [ -z "$caddyfile" ]; then
        echo "[$timestamp] ERROR: reload_caddy_service: No Caddyfile path provided" | tee -a "$CLUSTER_LOG"
        return 1
    fi

    echo "[$timestamp] Reloading Caddy on $caddy_host..." | tee -a "$CLUSTER_LOG"

    # Run reload command - use function from cluster-compose.sh if available
    local reload_output
    local reload_exit_code

    if type -t run_on_host >/dev/null 2>&1; then
        # Use run_on_host function if available
        if reload_output=$(run_on_host "$caddy_host" "caddy reload --config $caddyfile" 2>&1); then
            reload_exit_code=0
        else
            reload_exit_code=$?
        fi
    else
        # Fallback to direct caddy command (assumes local)
        if reload_output=$(caddy reload --config "$caddyfile" 2>&1); then
            reload_exit_code=0
        else
            reload_exit_code=$?
        fi
    fi

    # Log reload output
    if [ -n "$reload_output" ]; then
        echo "$reload_output" | while IFS= read -r line; do
            echo "[$timestamp]   $line" | tee -a "$CLUSTER_LOG"
        done
    fi

    if [ $reload_exit_code -eq 0 ]; then
        echo "[$timestamp] ✓ Caddy reload successful" | tee -a "$CLUSTER_LOG"
        return 0
    else
        echo "[$timestamp] ERROR: Caddy reload failed (exit code: $reload_exit_code)" | tee -a "$CLUSTER_LOG"
        return 1
    fi
}

################################################################################
# Function: rollback_caddyfile
#
# Purpose: Restores previous Caddyfile from backup when validation or reload
#          fails. Critical for maintaining system stability.
#
# Arguments:
#   $1 - Path to Caddyfile
#   $2 - Path to backup file (from BACKUP_FILE variable)
#
# Returns:
#   0 - Rollback successful
#   1 - Rollback failed or no backup available
#
# Side Effects:
#   - Restores backup file to original location
#   - Writes rollback status to cluster log
################################################################################
rollback_caddyfile() {
    local caddyfile="$1"
    local backup_file="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [ -z "$caddyfile" ]; then
        echo "[$timestamp] ERROR: rollback_caddyfile: No Caddyfile path provided" | tee -a "$CLUSTER_LOG"
        return 1
    fi

    if [ -z "$backup_file" ]; then
        echo "[$timestamp] WARNING: No backup file available for rollback" | tee -a "$CLUSTER_LOG"
        return 1
    fi

    if [ ! -f "$backup_file" ]; then
        echo "[$timestamp] ERROR: Backup file not found: $backup_file" | tee -a "$CLUSTER_LOG"
        return 1
    fi

    echo "[$timestamp] Rolling back Caddyfile from backup..." | tee -a "$CLUSTER_LOG"
    echo "[$timestamp]   Backup: $backup_file" | tee -a "$CLUSTER_LOG"
    echo "[$timestamp]   Target: $caddyfile" | tee -a "$CLUSTER_LOG"

    # Restore backup
    if cp "$backup_file" "$caddyfile" 2>/dev/null; then
        echo "[$timestamp] ✓ Caddyfile rollback successful" | tee -a "$CLUSTER_LOG"

        # Validate rolled-back config
        if validate_caddy_config "$caddyfile"; then
            echo "[$timestamp] ✓ Rolled-back Caddyfile is valid" | tee -a "$CLUSTER_LOG"
            return 0
        else
            echo "[$timestamp] ERROR: Rolled-back Caddyfile validation failed!" | tee -a "$CLUSTER_LOG"
            echo "[$timestamp]   System may be in inconsistent state" | tee -a "$CLUSTER_LOG"
            return 1
        fi
    else
        echo "[$timestamp] ERROR: Failed to restore backup" | tee -a "$CLUSTER_LOG"
        return 1
    fi
}

################################################################################
# Function: update_caddy_from_registry
#
# Purpose: Main orchestration function that coordinates the complete Caddy
#          update workflow with proper error handling and rollback.
#
# Workflow:
#   1. Setup logging (fix permissions)
#   2. Backup current Caddyfile
#   3. Regenerate from registry
#   4. Validate new configuration
#   5. Reload Caddy service
#   6. Rollback if any step fails
#
# Arguments:
#   $1 - Script directory (where portoser is located)
#   $2 - Registry file path
#
# Returns:
#   0 - Update successful
#   1 - Update failed (with rollback if applicable)
#
# Side Effects:
#   - Executes full Caddy update workflow
#   - Creates backups
#   - May rollback on failure
#   - Comprehensive logging to cluster log
#
# Example:
#   update_caddy_from_registry "<repo-root>" "registry.yml"
################################################################################
update_caddy_from_registry() {
    local script_dir="$1"
    local registry_file="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "" | tee -a "$CLUSTER_LOG"
    echo "==========================================" | tee -a "$CLUSTER_LOG"
    echo "CADDY CONFIGURATION UPDATE" | tee -a "$CLUSTER_LOG"
    echo "==========================================" | tee -a "$CLUSTER_LOG"
    echo "[$timestamp] Starting Caddy update workflow..." | tee -a "$CLUSTER_LOG"

    # Validate inputs
    if [ -z "$script_dir" ]; then
        echo "[$timestamp] ERROR: Script directory not provided" | tee -a "$CLUSTER_LOG"
        return 1
    fi

    if [ -z "$registry_file" ]; then
        echo "[$timestamp] ERROR: Registry file not provided" | tee -a "$CLUSTER_LOG"
        return 1
    fi

    if [ ! -f "$registry_file" ]; then
        echo "[$timestamp] ERROR: Registry file not found: $registry_file" | tee -a "$CLUSTER_LOG"
        return 1
    fi

    # Step 1: Setup logging
    echo "[$timestamp] Step 1/5: Setting up Caddy logging..." | tee -a "$CLUSTER_LOG"
    if ! setup_caddy_logging; then
        echo "[$timestamp] ERROR: Failed to setup Caddy logging" | tee -a "$CLUSTER_LOG"
        echo "[$timestamp] ABORTED: Cannot proceed without proper logging" | tee -a "$CLUSTER_LOG"
        return 1
    fi

    # Get Caddy host and config path from registry
    # Use awk to be compatible with cluster-compose.sh patterns
    local caddy_host
    caddy_host=$(awk '/^  caddy:/,/^  [a-z]/ {
        if (/current_host:/) {
            gsub(/^[ \t]+current_host:[ \t]+/, "")
            print
            exit
        }
    }' "$registry_file")

    if [ -z "$caddy_host" ]; then
        echo "[$timestamp] ERROR: Cannot find Caddy host in registry" | tee -a "$CLUSTER_LOG"
        return 1
    fi

    # Get Caddy config path - must match BASE_PATHS logic from cluster-compose.sh
    local caddy_config

    # Check if BASE_PATHS associative array exists and has caddy_host entry
    if declare -p BASE_PATHS >/dev/null 2>&1; then
        caddy_config="${BASE_PATHS[$caddy_host]}/caddy/Caddyfile"
    else
        # Fallback: extract path from registry for this host
        local host_base_path
        host_base_path=$(awk -v host="$caddy_host" '
            /^hosts:/ { in_hosts=1; next }
            in_hosts && $0 ~ "^  " host ":" { in_host=1; next }
            in_host && /path:/ {
                gsub(/^[ \t]+path:[ \t]+/, "")
                print
                exit
            }
            in_host && /^  [a-z]/ { in_host=0 }
        ' "$registry_file")

        if [ -n "$host_base_path" ]; then
            caddy_config="${host_base_path}/caddy/Caddyfile"
        else
            echo "[$timestamp] ERROR: Cannot determine Caddy config path" | tee -a "$CLUSTER_LOG"
            return 1
        fi
    fi

    echo "[$timestamp]   Caddy host: $caddy_host" | tee -a "$CLUSTER_LOG"
    echo "[$timestamp]   Caddy config: $caddy_config" | tee -a "$CLUSTER_LOG"

    # Step 2: Backup current Caddyfile
    echo "[$timestamp] Step 2/5: Backing up current Caddyfile..." | tee -a "$CLUSTER_LOG"
    BACKUP_FILE=""  # Global variable set by backup_caddyfile
    if ! backup_caddyfile "$caddy_config"; then
        echo "[$timestamp] ERROR: Failed to backup Caddyfile" | tee -a "$CLUSTER_LOG"
        echo "[$timestamp] ABORTED: Cannot proceed without backup" | tee -a "$CLUSTER_LOG"
        return 1
    fi

    # Step 3: Regenerate Caddyfile
    echo "[$timestamp] Step 3/5: Regenerating Caddyfile from registry..." | tee -a "$CLUSTER_LOG"
    if ! regenerate_caddy_config "$script_dir"; then
        echo "[$timestamp] ERROR: Failed to regenerate Caddyfile" | tee -a "$CLUSTER_LOG"

        # Attempt rollback if we have a backup
        if [ -n "$BACKUP_FILE" ]; then
            echo "[$timestamp] Attempting rollback..." | tee -a "$CLUSTER_LOG"
            rollback_caddyfile "$caddy_config" "$BACKUP_FILE"
        fi

        return 1
    fi

    # Step 4: Validate new Caddyfile
    echo "[$timestamp] Step 4/5: Validating new Caddyfile..." | tee -a "$CLUSTER_LOG"
    if ! validate_caddy_config "$caddy_config"; then
        echo "[$timestamp] ERROR: New Caddyfile validation failed" | tee -a "$CLUSTER_LOG"

        # Rollback to previous working configuration
        if [ -n "$BACKUP_FILE" ]; then
            echo "[$timestamp] Rolling back to previous configuration..." | tee -a "$CLUSTER_LOG"
            if rollback_caddyfile "$caddy_config" "$BACKUP_FILE"; then
                echo "[$timestamp] ✓ Rollback successful - previous config restored" | tee -a "$CLUSTER_LOG"
            else
                echo "[$timestamp] ERROR: Rollback failed - manual intervention required!" | tee -a "$CLUSTER_LOG"
            fi
        fi

        return 1
    fi

    # Step 5: Reload Caddy service
    echo "[$timestamp] Step 5/5: Reloading Caddy service..." | tee -a "$CLUSTER_LOG"
    if ! reload_caddy_service "$caddy_host" "$caddy_config"; then
        echo "[$timestamp] ERROR: Caddy reload failed" | tee -a "$CLUSTER_LOG"

        # Rollback and attempt to restore service
        if [ -n "$BACKUP_FILE" ]; then
            echo "[$timestamp] Rolling back and attempting service recovery..." | tee -a "$CLUSTER_LOG"
            if rollback_caddyfile "$caddy_config" "$BACKUP_FILE"; then
                echo "[$timestamp] Attempting to reload with previous config..." | tee -a "$CLUSTER_LOG"
                if reload_caddy_service "$caddy_host" "$caddy_config"; then
                    echo "[$timestamp] ✓ Service recovered with previous configuration" | tee -a "$CLUSTER_LOG"
                else
                    echo "[$timestamp] ERROR: Service recovery failed - manual intervention required!" | tee -a "$CLUSTER_LOG"
                fi
            fi
        fi

        return 1
    fi

    # Success!
    echo "[$timestamp] ✓ Caddy configuration update completed successfully" | tee -a "$CLUSTER_LOG"
    echo "==========================================" | tee -a "$CLUSTER_LOG"
    echo "" | tee -a "$CLUSTER_LOG"

    return 0
}

################################################################################
# INTEGRATION INSTRUCTIONS
#
# To integrate this module into cluster-compose.sh:
#
# 1. Source this file near the top of cluster-compose.sh (after set -euo pipefail):
#    source "${SCRIPT_DIR}/lib/caddy_integration.sh" || true
#
# 2. Replace lines 730-742 (Caddy regeneration section) with:
#    if [[ "$ACTION" == "restart" && "$ALL_SERVICES" == true ]]; then
#        if ! update_caddy_from_registry "$SCRIPT_DIR" "$REGISTRY_FILE"; then
#            echo "WARNING: Caddy update failed - check logs in /tmp/cluster-compose.log"
#            echo "Services will continue starting but may not be accessible via Caddy"
#        fi
#    fi
#
# 3. Replace lines 836-858 (Caddy reload section) with:
#    # Caddy reload is now handled by update_caddy_from_registry above
#    # This section can be removed
#
# 4. Ensure SCRIPT_DIR and REGISTRY_FILE variables are set before calling
#
################################################################################

################################################################################
# END OF CADDY INTEGRATION MODULE
################################################################################
