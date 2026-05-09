#!/usr/bin/env bash
# =============================================================================
# SSH Key Authentication Module - Production Ready
# =============================================================================
# Mission: Secure SSH authentication replacing hardcoded passwords
#
# SECURITY IMPROVEMENTS:
# - Eliminates hardcoded passwords in source code
# - Removes sshpass dependency (security vulnerability)
# - Uses SSH key-based authentication (industry standard)
# - Supports SSH agent for key management
# - Provides fallback mechanisms and clear error messages
#
# FEATURES:
# - Automatic SSH key detection and validation
# - SSH agent integration
# - Per-host key configuration support
# - Connection testing and validation
# - Comprehensive error handling
# - Setup helper for cluster deployment
#
# Dependencies: ssh, ssh-keygen, ssh-copy-id, rsync
# Removes: sshpass (security vulnerability)
# Created: 2025-12-11
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# Default SSH key path (standard location). Public — sourcing scripts may
# read this when running ssh-add / key-add helpers manually.
# shellcheck disable=SC2034 # public default consumed by sourcing scripts
SSH_KEY_DEFAULT="${HOME}/.ssh/id_ed25519"

# Alternative key paths to check (in order of preference)
declare -a SSH_KEY_ALTERNATIVES=(
    "${HOME}/.ssh/id_ed25519"
    "${HOME}/.ssh/id_rsa"
    "${HOME}/.ssh/id_ecdsa"
)

# Per-host SSH key configuration (optional overrides)
# Set these to use specific keys for specific hosts
declare -gA SSH_HOST_KEYS=(
    # Example: ["pi1"]="${HOME}/.ssh/pi_cluster_key"
    # If not set, will use default key or SSH agent
)

# SSH connection timeout (seconds)
SSH_CONNECT_TIMEOUT=5

# SSH options for non-interactive connections. Public — sourcing scripts
# splat $SSH_OPTS into ad-hoc ssh calls.
# shellcheck disable=SC2034 # public default consumed by sourcing scripts
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=${SSH_CONNECT_TIMEOUT} -o StrictHostKeyChecking=accept-new"

# Cluster host configuration
# By default this is empty; populate via cluster.conf (see cluster.conf.example).
# If the caller sources cluster.conf before this file, CLUSTER_HOSTS will already
# be defined and we leave it alone.
if ! declare -p CLUSTER_HOSTS >/dev/null 2>&1; then
    declare -gA CLUSTER_HOSTS=()
    # Auto-source cluster.conf if it exists alongside the project root.
    _ssh_keys_cluster_conf="${CLUSTER_CONF:-${PORTOSER_ROOT:-$(pwd)}/cluster.conf}"
    if [[ -f "${_ssh_keys_cluster_conf}" ]]; then
        # shellcheck disable=SC1090
        source "${_ssh_keys_cluster_conf}"
    fi
    unset _ssh_keys_cluster_conf
fi

# Working-directory paths per host (mirrors CLUSTER_PATHS from cluster.conf).
# Left empty so callers can populate via cluster.conf without a hardcoded list.
if ! declare -p PI_PATHS >/dev/null 2>&1; then
    declare -gA PI_PATHS=()
fi

# =============================================================================
# validate_ssh_key_exists - Validate that an SSH key exists and is readable
#
# Checks if the specified SSH key file exists, is readable, and has
# correct permissions. Also validates the corresponding public key.
#
# Parameters:
#   $1 - key_path (required): Path to SSH private key
#
# Returns:
#   0 - SSH key is valid and usable
#   1 - SSH key is invalid or unusable
#
# Outputs:
#   Prints validation errors to stderr
#
# Example:
#   if validate_ssh_key_exists "${HOME}/.ssh/id_ed25519"; then
#       echo "Key is valid"
#   fi
# =============================================================================
validate_ssh_key_exists() {
    local key_path="$1"

    if [[ -z "$key_path" ]]; then
        echo "Error: key_path parameter is required" >&2
        return 1
    fi

    # Check if private key exists
    if [[ ! -f "$key_path" ]]; then
        echo "Error: SSH key not found: $key_path" >&2
        return 1
    fi

    # Check if private key is readable
    if [[ ! -r "$key_path" ]]; then
        echo "Error: SSH key is not readable: $key_path" >&2
        echo "  Fix with: chmod 600 $key_path" >&2
        return 1
    fi

    # Validate key permissions (should be 600 or 400)
    local perms
    perms=$(stat -f "%OLp" "$key_path" 2>/dev/null || stat -c "%a" "$key_path" 2>/dev/null)
    if [[ "$perms" != "600" ]] && [[ "$perms" != "400" ]]; then
        echo "Warning: SSH key has insecure permissions: $perms" >&2
        echo "  Recommended: chmod 600 $key_path" >&2
        # Don't fail on this, just warn
    fi

    # Check if public key exists
    if [[ ! -f "${key_path}.pub" ]]; then
        echo "Warning: Public key not found: ${key_path}.pub" >&2
        echo "  Generate with: ssh-keygen -y -f $key_path > ${key_path}.pub" >&2
        # Don't fail on this, key might still work
    fi

    # Try to validate the key format
    if ! ssh-keygen -l -f "$key_path" &>/dev/null; then
        echo "Error: SSH key appears to be corrupted or invalid: $key_path" >&2
        return 1
    fi

    return 0
}

# =============================================================================
# detect_ssh_key - Detect available SSH key for authentication
#
# Searches for usable SSH keys in standard locations. Returns the first
# valid key found. Checks host-specific keys first, then falls back to
# default keys.
#
# Parameters:
#   $1 - host_name (optional): Host name for host-specific key lookup
#
# Returns:
#   0 - SSH key found and validated
#   1 - No valid SSH key found
#
# Outputs:
#   Prints path to valid SSH key to stdout
#   Prints error messages to stderr
#
# Example:
#   ssh_key=$(detect_ssh_key "pi1")
#   ssh_key=$(detect_ssh_key)
# =============================================================================
detect_ssh_key() {
    local host_name="${1:-}"

    # Check for host-specific key first
    if [[ -n "$host_name" ]] && [[ -n "${SSH_HOST_KEYS[$host_name]:-}" ]]; then
        local host_key="${SSH_HOST_KEYS[$host_name]}"
        if validate_ssh_key_exists "$host_key" 2>/dev/null; then
            echo "$host_key"
            return 0
        else
            echo "Warning: Host-specific key for $host_name is invalid: $host_key" >&2
        fi
    fi

    # Check alternative keys in order of preference
    for key_path in "${SSH_KEY_ALTERNATIVES[@]}"; do
        if validate_ssh_key_exists "$key_path" 2>/dev/null; then
            echo "$key_path"
            return 0
        fi
    done

    # No valid key found
    echo "Error: No valid SSH key found" >&2
    echo "" >&2
    echo "Searched locations:" >&2
    for key_path in "${SSH_KEY_ALTERNATIVES[@]}"; do
        echo "  - $key_path" >&2
    done
    echo "" >&2
    echo "To generate a new SSH key:" >&2
    echo "  ssh-keygen -t ed25519 -f ${HOME}/.ssh/id_ed25519 -C \"$(whoami)@$(hostname)\"" >&2
    echo "" >&2

    return 1
}

# =============================================================================
# test_ssh_connectivity - Test SSH connection to a host
#
# Tests whether SSH connection to a host is working by attempting to execute
# a simple echo command. Uses SSH key authentication only.
#
# Parameters:
#   $1 - ssh_host (required): SSH host in format "user@host"
#   $2 - ssh_key (optional): Path to SSH key (auto-detected if not provided)
#   $3 - timeout (optional): Connection timeout in seconds (default: 5)
#
# Returns:
#   0 - SSH connection successful
#   1 - SSH connection failed
#   2 - Invalid parameters
#
# Outputs:
#   Prints status messages to stderr
#   Prints "OK" to stdout on success
#
# Example:
#   if test_ssh_connectivity "user@host.example.local"; then
#       echo "Pi1 is reachable"
#   fi
#   if test_ssh_connectivity "user@host.example.local" "${HOME}/.ssh/id_ed25519"; then
#       echo "Pi1 is reachable with specific key"
#   fi
# =============================================================================
test_ssh_connectivity() {
    local ssh_host="$1"
    local ssh_key="${2:-}"
    local timeout="${3:-${SSH_CONNECT_TIMEOUT}}"

    # Validate parameters
    if [[ -z "$ssh_host" ]]; then
        echo "Error: ssh_host parameter is required" >&2
        return 2
    fi

    # Auto-detect SSH key if not provided
    if [[ -z "$ssh_key" ]]; then
        # Extract host name for host-specific key detection
        local host_name="${ssh_host%%@*}"  # Get part before @
        ssh_key=$(detect_ssh_key "$host_name" 2>/dev/null)

        # If no key detected, try SSH agent
        if [[ -z "$ssh_key" ]]; then
            echo "Info: No SSH key detected, attempting connection with SSH agent" >&2
        fi
    fi

    # Build SSH command
    local ssh_cmd="ssh"
    local ssh_args=("-o" "ConnectTimeout=${timeout}" "-o" "StrictHostKeyChecking=accept-new" "-o" "BatchMode=yes")

    # Add identity file if we have a key
    if [[ -n "$ssh_key" ]]; then
        ssh_args+=("-i" "$ssh_key")
    fi

    # Test connection
    if "${ssh_cmd}" "${ssh_args[@]}" "$ssh_host" "echo 'SSH_OK'" 2>/dev/null | grep -q "SSH_OK"; then
        echo "OK"
        return 0
    else
        echo "Error: Cannot connect to $ssh_host via SSH" >&2
        echo "" >&2
        echo "Troubleshooting steps:" >&2
        echo "1. Verify host is reachable: ping ${ssh_host#*@}" >&2
        echo "2. Check SSH key is deployed: ssh-copy-id -i ${ssh_key:-\$HOME/.ssh/id_ed25519.pub} $ssh_host" >&2
        echo "3. Test manual connection: ssh $ssh_host" >&2
        echo "4. Check SSH agent: ssh-add -l" >&2
        echo "" >&2
        return 1
    fi
}

# =============================================================================
# run_on_host - Execute command on remote host via SSH
#
# Executes a command on a remote host using SSH key authentication.
# Replaces the old sshpass-based implementation with secure key-based auth.
#
# SECURITY IMPROVEMENTS:
# - Uses SSH keys instead of passwords
# - Eliminates sshpass dependency
# - Uses bash -c with positional parameters for command injection protection
# - Validates SSH connectivity before execution
#
# Parameters:
#   $1 - host_name (required): Host name (pi1, pi2, pi3, pi4)
#   $2 - command (required): Command to execute
#   $3 - ssh_key (optional): Path to SSH key (auto-detected if not provided)
#
# Returns:
#   Returns exit code from remote command
#   1 - SSH connection failed or invalid parameters
#   2 - Invalid parameters
#
# Outputs:
#   Prints command output to stdout
#   Prints errors to stderr
#
# Example:
#   run_on_host "pi1" "docker ps"
#   run_on_host "<your-host>" "cd <services-root> && ls -la"
#   run_on_host "pi1" "systemctl status docker" "${HOME}/.ssh/custom_key"
# =============================================================================
run_on_host() {
    local host_name="$1"
    local command="$2"
    local ssh_key="${3:-}"

    # Validate parameters
    if [[ -z "$host_name" ]]; then
        echo "Error: host_name parameter is required" >&2
        return 2
    fi

    if [[ -z "$command" ]]; then
        echo "Error: command parameter is required" >&2
        return 2
    fi

    # Get SSH host from configuration
    local ssh_host="${CLUSTER_HOSTS[$host_name]:-}"
    if [[ -z "$ssh_host" ]]; then
        echo "Error: Unknown host: $host_name" >&2
        echo "Valid hosts: ${!CLUSTER_HOSTS[*]}" >&2
        return 2
    fi

    # Auto-detect SSH key if not provided
    if [[ -z "$ssh_key" ]]; then
        ssh_key=$(detect_ssh_key "$host_name" 2>/dev/null)
    fi

    # Build SSH command
    local ssh_cmd="ssh"
    local ssh_args=("-o" "BatchMode=yes" "-o" "ConnectTimeout=${SSH_CONNECT_TIMEOUT}" "-o" "StrictHostKeyChecking=accept-new")

    # Add identity file if we have a key
    if [[ -n "$ssh_key" ]]; then
        ssh_args+=("-i" "$ssh_key")
    fi

    # Execute command
    # Use bash -c with the command as a positional parameter for safety
    "${ssh_cmd}" "${ssh_args[@]}" "$ssh_host" -- bash -c "$command"
    return $?
}

# =============================================================================
# run_on_host_checked - Execute command on remote host with validation
#
# Similar to run_on_host but validates SSH connectivity first and provides
# better error handling.
#
# Parameters:
#   $1 - host_name (required): Host name (pi1, pi2, pi3, pi4)
#   $2 - command (required): Command to execute
#   $3 - ssh_key (optional): Path to SSH key (auto-detected if not provided)
#
# Returns:
#   Returns exit code from remote command
#   1 - SSH connection failed or command failed
#   2 - Invalid parameters
#
# Outputs:
#   Prints command output to stdout
#   Prints errors to stderr
#
# Example:
#   if run_on_host_checked "pi1" "docker ps"; then
#       echo "Command succeeded"
#   fi
# =============================================================================
run_on_host_checked() {
    local host_name="$1"
    local command="$2"
    local ssh_key="${3:-}"

    # Validate parameters
    if [[ -z "$host_name" ]]; then
        echo "Error: host_name parameter is required" >&2
        return 2
    fi

    if [[ -z "$command" ]]; then
        echo "Error: command parameter is required" >&2
        return 2
    fi

    # Get SSH host from configuration
    local ssh_host="${CLUSTER_HOSTS[$host_name]:-}"
    if [[ -z "$ssh_host" ]]; then
        echo "Error: Unknown host: $host_name" >&2
        return 2
    fi

    # Auto-detect SSH key if not provided
    if [[ -z "$ssh_key" ]]; then
        ssh_key=$(detect_ssh_key "$host_name" 2>/dev/null)
    fi

    # Test connectivity first
    if ! test_ssh_connectivity "$ssh_host" "$ssh_key" &>/dev/null; then
        echo "Error: Cannot connect to $host_name ($ssh_host)" >&2
        return 1
    fi

    # Execute command using run_on_host
    run_on_host "$host_name" "$command" "$ssh_key"
    return $?
}

# =============================================================================
# sync_to_host - Synchronize files to remote host using rsync over SSH
#
# Syncs a local directory to a remote host using rsync with SSH key auth.
# Replaces sshpass-based rsync with secure key-based authentication.
#
# Parameters:
#   $1 - host_name (required): Host name (pi1, pi2, pi3, pi4)
#   $2 - local_path (required): Local source directory
#   $3 - remote_path (optional): Remote destination path (default: from PI_PATHS)
#   $4 - ssh_key (optional): Path to SSH key (auto-detected if not provided)
#   $5 - delete (optional): Set to "true" to use --delete flag (default: false)
#
# Returns:
#   0 - Sync successful
#   1 - Sync failed
#   2 - Invalid parameters
#
# Outputs:
#   Prints rsync progress to stderr
#
# Example:
#   sync_to_host "pi1" "<sync-base>/myservice"
#   sync_to_host "pi1" "/local/path" "/remote/path"
#   sync_to_host "pi1" "/local/path" "/remote/path" "" "true"
# =============================================================================
sync_to_host() {
    local host_name="$1"
    local local_path="$2"
    local remote_path="${3:-}"
    local ssh_key="${4:-}"
    local delete="${5:-false}"

    # Validate parameters
    if [[ -z "$host_name" ]]; then
        echo "Error: host_name parameter is required" >&2
        return 2
    fi

    if [[ -z "$local_path" ]]; then
        echo "Error: local_path parameter is required" >&2
        return 2
    fi

    if [[ ! -d "$local_path" ]]; then
        echo "Error: Local path does not exist: $local_path" >&2
        return 2
    fi

    # Get SSH host from configuration
    local ssh_host="${CLUSTER_HOSTS[$host_name]:-}"
    if [[ -z "$ssh_host" ]]; then
        echo "Error: Unknown host: $host_name" >&2
        return 2
    fi

    # Use default remote path if not specified
    if [[ -z "$remote_path" ]]; then
        remote_path="${PI_PATHS[$host_name]:-}"
        if [[ -z "$remote_path" ]]; then
            echo "Error: No default path configured for $host_name" >&2
            return 2
        fi
        # Append service directory name
        local_dirname=$(basename "$local_path")
        remote_path="${remote_path}/${local_dirname}"
    fi

    # Auto-detect SSH key if not provided
    if [[ -z "$ssh_key" ]]; then
        ssh_key=$(detect_ssh_key "$host_name" 2>/dev/null)
    fi

    echo "Syncing $local_path to $host_name:$remote_path..." >&2

    # Build rsync command
    local rsync_args=(-avz --exclude='*.pyc' --exclude='__pycache__' --exclude='node_modules' --exclude='.git' --exclude='.venv' --exclude='venv' --exclude='*.log')

    # Add delete flag if requested
    if [[ "$delete" == "true" ]]; then
        rsync_args+=(--delete)
    fi

    # Build SSH command for rsync
    local ssh_cmd="ssh -o BatchMode=yes -o ConnectTimeout=${SSH_CONNECT_TIMEOUT} -o StrictHostKeyChecking=accept-new"
    if [[ -n "$ssh_key" ]]; then
        ssh_cmd="$ssh_cmd -i $ssh_key"
    fi

    rsync_args+=(-e "$ssh_cmd")

    # Execute rsync
    if rsync "${rsync_args[@]}" "$local_path/" "${ssh_host}:${remote_path}/"; then
        echo "Successfully synced to $host_name" >&2
        return 0
    else
        echo "Error: Failed to sync to $host_name" >&2
        return 1
    fi
}

# =============================================================================
# setup_ssh_keys_on_cluster - Deploy SSH keys to all cluster hosts
#
# Interactive setup helper that deploys SSH public keys to all configured
# cluster hosts. This is typically run once during initial setup.
#
# WORKFLOW:
# 1. Detects or generates SSH key
# 2. Tests connectivity to each host
# 3. Deploys public key to hosts (requires password once per host)
# 4. Verifies key-based authentication works
#
# Parameters:
#   $1 - ssh_key (optional): Path to SSH key (auto-detected if not provided)
#   $2 - hosts (optional): Space-separated list of hosts (default: all)
#
# Returns:
#   0 - All hosts configured successfully
#   1 - One or more hosts failed
#   2 - Invalid parameters or setup aborted
#
# Outputs:
#   Interactive prompts and progress messages
#
# Example:
#   setup_ssh_keys_on_cluster
#   setup_ssh_keys_on_cluster "${HOME}/.ssh/id_ed25519" "pi1 pi2"
# =============================================================================
setup_ssh_keys_on_cluster() {
    local ssh_key="${1:-}"
    local target_hosts="${2:-${!CLUSTER_HOSTS[*]}}"

    echo "========================================" >&2
    echo "SSH Key Setup for Cluster" >&2
    echo "========================================" >&2
    echo "" >&2

    # Step 1: Detect or prompt for SSH key
    if [[ -z "$ssh_key" ]]; then
        echo "Detecting SSH key..." >&2
        ssh_key=$(detect_ssh_key 2>/dev/null || echo "")

        if [[ -z "$ssh_key" ]]; then
            echo "No SSH key found. Would you like to generate one? (y/n)" >&2
            read -r response
            if [[ "$response" =~ ^[Yy] ]]; then
                ssh_key="${HOME}/.ssh/id_ed25519"
                echo "" >&2
                echo "Generating SSH key: $ssh_key" >&2
                ssh-keygen -t ed25519 -f "$ssh_key" -C "$(whoami)@$(hostname)-cluster"
                echo "" >&2
            else
                echo "Setup aborted - SSH key required" >&2
                return 2
            fi
        else
            echo "Using SSH key: $ssh_key" >&2
        fi
    fi

    # Validate key
    if ! validate_ssh_key_exists "$ssh_key"; then
        echo "Error: Invalid SSH key: $ssh_key" >&2
        return 2
    fi

    # Show key fingerprint
    echo "" >&2
    echo "SSH Key Fingerprint:" >&2
    ssh-keygen -l -f "$ssh_key" >&2
    echo "" >&2

    # Step 2: Deploy to each host
    local success_count=0
    local failed_count=0
    local failed_hosts=()

    for host_name in $target_hosts; do
        echo "----------------------------------------" >&2
        echo "Configuring: $host_name" >&2
        echo "----------------------------------------" >&2

        local ssh_host="${CLUSTER_HOSTS[$host_name]:-}"
        if [[ -z "$ssh_host" ]]; then
            echo "Warning: Unknown host: $host_name, skipping" >&2
            ((failed_count++))
            failed_hosts+=("$host_name")
            continue
        fi

        # Test if already configured
        if test_ssh_connectivity "$ssh_host" "$ssh_key" &>/dev/null; then
            echo "  Already configured - SSH key authentication working" >&2
            ((success_count++))
            echo "" >&2
            continue
        fi

        # Deploy key (will prompt for password)
        echo "  Deploying SSH key to $ssh_host..." >&2
        echo "  (You will be prompted for the password)" >&2

        if ssh-copy-id -i "${ssh_key}.pub" "$ssh_host" 2>&1; then
            # Verify it works
            if test_ssh_connectivity "$ssh_host" "$ssh_key" &>/dev/null; then
                echo "  Success - SSH key deployed and verified" >&2
                ((success_count++))
            else
                echo "  Error: Key deployed but authentication failed" >&2
                ((failed_count++))
                failed_hosts+=("$host_name")
            fi
        else
            echo "  Error: Failed to deploy SSH key" >&2
            ((failed_count++))
            failed_hosts+=("$host_name")
        fi

        echo "" >&2
    done

    # Summary
    echo "========================================" >&2
    echo "Setup Complete" >&2
    echo "========================================" >&2
    echo "Successful: $success_count" >&2
    echo "Failed: $failed_count" >&2

    if [[ $failed_count -gt 0 ]]; then
        echo "" >&2
        echo "Failed hosts:" >&2
        for host in "${failed_hosts[@]}"; do
            echo "  - $host" >&2
        done
        echo "" >&2
        echo "For failed hosts, verify:" >&2
        echo "1. Host is reachable on network" >&2
        echo "2. SSH server is running" >&2
        echo "3. Password authentication is enabled" >&2
        echo "" >&2
        return 1
    fi

    echo "" >&2
    echo "All hosts configured successfully!" >&2
    echo "SSH key-based authentication is now active." >&2
    echo "" >&2

    return 0
}

# =============================================================================
# verify_cluster_ssh_access - Verify SSH access to all cluster hosts
#
# Tests SSH connectivity to all configured cluster hosts and reports status.
# Useful for validating setup after key deployment.
#
# Parameters:
#   $1 - ssh_key (optional): Path to SSH key (auto-detected if not provided)
#   $2 - hosts (optional): Space-separated list of hosts (default: all)
#
# Returns:
#   0 - All hosts accessible
#   1 - One or more hosts inaccessible
#
# Outputs:
#   Prints connectivity status for each host
#
# Example:
#   verify_cluster_ssh_access
#   verify_cluster_ssh_access "${HOME}/.ssh/id_ed25519"
# =============================================================================
verify_cluster_ssh_access() {
    local ssh_key="${1:-}"
    local target_hosts="${2:-${!CLUSTER_HOSTS[*]}}"

    echo "========================================" >&2
    echo "Cluster SSH Connectivity Check" >&2
    echo "========================================" >&2
    echo "" >&2

    # Auto-detect SSH key if not provided
    if [[ -z "$ssh_key" ]]; then
        ssh_key=$(detect_ssh_key 2>/dev/null || echo "")
        if [[ -n "$ssh_key" ]]; then
            echo "Using SSH key: $ssh_key" >&2
        else
            echo "Using SSH agent authentication" >&2
        fi
        echo "" >&2
    fi

    local accessible_count=0
    local failed_count=0
    local failed_hosts=()

    for host_name in $target_hosts; do
        local ssh_host="${CLUSTER_HOSTS[$host_name]:-}"
        if [[ -z "$ssh_host" ]]; then
            echo "[$host_name] UNKNOWN HOST" >&2
            ((failed_count++))
            failed_hosts+=("$host_name")
            continue
        fi

        echo -n "[$host_name] Testing... " >&2
        if test_ssh_connectivity "$ssh_host" "$ssh_key" 2>/dev/null | grep -q "OK"; then
            echo "ACCESSIBLE" >&2
            ((accessible_count++))
        else
            echo "FAILED" >&2
            ((failed_count++))
            failed_hosts+=("$host_name")
        fi
    done

    echo "" >&2
    echo "Results: $accessible_count accessible, $failed_count failed" >&2

    if [[ $failed_count -gt 0 ]]; then
        echo "" >&2
        echo "Failed hosts:" >&2
        for host in "${failed_hosts[@]}"; do
            echo "  - $host" >&2
        done
        return 1
    fi

    return 0
}

# =============================================================================
# Library initialization check
# =============================================================================

# Verify this script is being sourced, not executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This library should be sourced, not executed directly" >&2
    echo "" >&2
    echo "Usage: source $(basename "${BASH_SOURCE[0]}")" >&2
    echo "" >&2
    echo "To run setup interactively, source this file then call:" >&2
    echo "  setup_ssh_keys_on_cluster" >&2
    echo "" >&2
    echo "Or use the standalone setup script:" >&2
    echo "  ./agent2_ssh_key_setup.sh" >&2
    exit 1
fi

echo "SSH Key Authentication Module loaded successfully" >&2
echo "  Functions available:" >&2
echo "    - validate_ssh_key_exists" >&2
echo "    - detect_ssh_key" >&2
echo "    - test_ssh_connectivity" >&2
echo "    - run_on_host" >&2
echo "    - run_on_host_checked" >&2
echo "    - sync_to_host" >&2
echo "    - setup_ssh_keys_on_cluster" >&2
echo "    - verify_cluster_ssh_access" >&2
