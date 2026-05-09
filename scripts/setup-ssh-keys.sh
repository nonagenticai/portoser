#!/usr/bin/env bash
# =============================================================================
# SSH Key Setup Script for Cluster
# =============================================================================
# Standalone script to deploy SSH keys to every host listed in cluster.conf.
#
# Topology (CLUSTER_HOSTS / CLUSTER_PATHS / CLUSTER_ARCH) is loaded from
# cluster.conf. Copy cluster.conf.example to cluster.conf and edit it for
# your environment before running this script.
#
# This script automates the one-time setup process of deploying SSH public
# keys to cluster hosts, eliminating the need for password authentication
# and removing the security vulnerability of hardcoded passwords.
#
# WHAT THIS SCRIPT DOES:
# 1. Detects or generates SSH key pair
# 2. Shows key fingerprint for verification
# 3. Tests connectivity to each cluster host
# 4. Deploys public key to each host (prompts for password once per host)
# 5. Verifies key-based authentication works
# 6. Provides summary and next steps
#
# REQUIREMENTS:
# - ssh-keygen (generates keys)
# - ssh-copy-id (deploys keys)
# - ssh (tests connectivity)
# - Network access to cluster hosts
# - Host passwords (for initial deployment only)
#
# USAGE:
#   ./setup-ssh-keys.sh
#   ./setup-ssh-keys.sh --key /path/to/key
#   ./setup-ssh-keys.sh --hosts "host1 host2"
#   ./setup-ssh-keys.sh --key ~/.ssh/id_ed25519
# =============================================================================

set -euo pipefail

# =============================================================================
# LOAD CLUSTER TOPOLOGY (cluster.conf)
# =============================================================================
# Resolve cluster.conf using $CLUSTER_CONF, then $PORTOSER_ROOT, then the
# repository root inferred from this script's location.
CLUSTER_CONF="${CLUSTER_CONF:-${PORTOSER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/cluster.conf}"
if [[ ! -f "$CLUSTER_CONF" ]]; then
    echo "ERROR: cluster.conf not found at $CLUSTER_CONF" >&2
    echo "       Copy cluster.conf.example to cluster.conf and edit for your environment." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CLUSTER_CONF"

if ! declare -p CLUSTER_HOSTS &>/dev/null || [[ ${#CLUSTER_HOSTS[@]} -eq 0 ]]; then
    echo "ERROR: CLUSTER_HOSTS is empty or unset in $CLUSTER_CONF" >&2
    echo "       See cluster.conf.example for the expected layout." >&2
    exit 1
fi

# =============================================================================
# CONFIGURATION
# =============================================================================

# Default SSH key path
DEFAULT_SSH_KEY="${HOME}/.ssh/id_ed25519"

# Alternative keys to check
declare -a SSH_KEY_ALTERNATIVES=(
    "${HOME}/.ssh/id_ed25519"
    "${HOME}/.ssh/id_rsa"
    "${HOME}/.ssh/id_ecdsa"
)

# Default hosts to configure: every key in CLUSTER_HOSTS, sorted for stable
# output across runs.
DEFAULT_HOSTS="$(printf '%s\n' "${!CLUSTER_HOSTS[@]}" | sort | tr '\n' ' ')"
DEFAULT_HOSTS="${DEFAULT_HOSTS% }"

# SSH connection timeout
SSH_TIMEOUT=5

# =============================================================================
# FUNCTIONS
# =============================================================================

# Print usage information
print_usage() {
    cat << EOF
SSH Key Setup Script for Cluster

USAGE:
    ./setup-ssh-keys.sh [OPTIONS]

OPTIONS:
    --key PATH               Path to SSH private key (default: auto-detect)
    --hosts "host1 host2"    Space-separated list of host keys from cluster.conf
                             (default: all hosts in CLUSTER_HOSTS)
    --generate               Force generate a new SSH key
    --help                   Show this help message

EXAMPLES:
    # Setup all hosts with auto-detected key
    ./setup-ssh-keys.sh

    # Setup specific hosts (keys from CLUSTER_HOSTS)
    ./setup-ssh-keys.sh --hosts "host1 host2"

    # Use specific key
    ./setup-ssh-keys.sh --key ~/.ssh/cluster_key

    # Generate new key and setup all hosts
    ./setup-ssh-keys.sh --generate

WHAT THIS DOES:
    1. Detects or generates SSH key pair
    2. Tests connectivity to each cluster host (loaded from cluster.conf)
    3. Deploys public key (prompts for password once per host)
    4. Verifies key-based authentication works
    5. Reports results and provides recommendations

REQUIREMENTS:
    - ssh-keygen, ssh-copy-id, ssh
    - cluster.conf in repository root (copy from cluster.conf.example)
    - Network access to cluster hosts
    - Host passwords (for initial deployment)

Configured hosts (from \$CLUSTER_CONF):
    ${DEFAULT_HOSTS}

After successful setup, password authentication will no longer be needed.

EOF
}

# Print colored status messages
print_status() {
    echo "[INFO] $*" >&2
}

print_success() {
    echo "[SUCCESS] $*" >&2
}

print_error() {
    echo "[ERROR] $*" >&2
}

print_warning() {
    echo "[WARNING] $*" >&2
}

# Detect existing SSH key
detect_ssh_key() {
    for key_path in "${SSH_KEY_ALTERNATIVES[@]}"; do
        if [[ -f "$key_path" ]] && [[ -r "$key_path" ]]; then
            # Validate key
            if ssh-keygen -l -f "$key_path" &>/dev/null; then
                echo "$key_path"
                return 0
            fi
        fi
    done
    return 1
}

# Generate new SSH key
generate_ssh_key() {
    local key_path="$1"

    print_status "Generating new SSH key: $key_path"

    # Check if key already exists
    if [[ -f "$key_path" ]]; then
        print_warning "Key already exists: $key_path"
        read -r -p "Overwrite? (y/N): " response
        if [[ ! "$response" =~ ^[Yy] ]]; then
            print_error "Key generation cancelled"
            return 1
        fi
    fi

    # Generate key
    if ssh-keygen -t ed25519 -f "$key_path" -C "$(whoami)@$(hostname)-cluster"; then
        print_success "SSH key generated successfully"
        return 0
    else
        print_error "Failed to generate SSH key"
        return 1
    fi
}

# Test SSH connectivity
test_ssh_connectivity() {
    local ssh_host="$1"
    local ssh_key="${2:-}"

    local ssh_args=("-o" "ConnectTimeout=${SSH_TIMEOUT}" "-o" "StrictHostKeyChecking=accept-new" "-o" "BatchMode=yes")

    if [[ -n "$ssh_key" ]]; then
        ssh_args+=("-i" "$ssh_key")
    fi

    if ssh "${ssh_args[@]}" "$ssh_host" "echo 'SSH_OK'" 2>/dev/null | grep -q "SSH_OK"; then
        return 0
    else
        return 1
    fi
}

# Deploy SSH key to host
deploy_ssh_key() {
    local ssh_host="$1"
    local ssh_key="$2"

    print_status "Deploying SSH key to $ssh_host..."
    print_status "(You will be prompted for the password)"

    if ssh-copy-id -o StrictHostKeyChecking=accept-new -i "${ssh_key}.pub" "$ssh_host" 2>&1; then
        return 0
    else
        return 1
    fi
}

# Main setup function
main_setup() {
    local ssh_key="$1"
    local target_hosts="$2"

    echo ""
    echo "========================================"
    echo "SSH Key Setup for Portoser Cluster"
    echo "========================================"
    echo ""

    # Step 1: SSH Key Detection/Generation
    print_status "Step 1: SSH Key Detection"
    echo ""

    if [[ -z "$ssh_key" ]]; then
        print_status "Detecting existing SSH keys..."
        ssh_key=$(detect_ssh_key || echo "")

        if [[ -z "$ssh_key" ]]; then
            print_warning "No SSH key found"
            read -r -p "Generate a new SSH key? (Y/n): " response
            if [[ ! "$response" =~ ^[Nn] ]]; then
                ssh_key="$DEFAULT_SSH_KEY"
                if ! generate_ssh_key "$ssh_key"; then
                    return 1
                fi
            else
                print_error "SSH key required for setup"
                return 1
            fi
        else
            print_success "Found existing SSH key: $ssh_key"
        fi
    fi

    # Validate key
    if [[ ! -f "$ssh_key" ]]; then
        print_error "SSH key not found: $ssh_key"
        return 1
    fi

    if ! ssh-keygen -l -f "$ssh_key" &>/dev/null; then
        print_error "Invalid SSH key: $ssh_key"
        return 1
    fi

    # Show key fingerprint
    echo ""
    print_status "SSH Key Information:"
    echo "  Path: $ssh_key"
    echo -n "  Fingerprint: "
    ssh-keygen -l -f "$ssh_key"
    echo ""

    # Step 2: Host Configuration
    print_status "Step 2: Deploying to Hosts"
    echo ""
    print_status "Target hosts: $target_hosts"
    echo ""

    local success_count=0
    local failed_count=0
    local already_configured=0
    declare -a failed_hosts=()
    declare -a configured_hosts=()

    for host_name in $target_hosts; do
        echo "----------------------------------------"
        echo "Configuring: $host_name"
        echo "----------------------------------------"

        # Get SSH host
        local ssh_host="${CLUSTER_HOSTS[$host_name]:-}"
        if [[ -z "$ssh_host" ]]; then
            print_warning "Unknown host: $host_name (skipping)"
            ((failed_count++))
            failed_hosts+=("$host_name")
            echo ""
            continue
        fi

        # Test if already configured
        print_status "Testing connectivity to $ssh_host..."
        if test_ssh_connectivity "$ssh_host" "$ssh_key"; then
            print_success "Already configured - SSH key authentication working"
            ((already_configured++))
            ((success_count++))
            configured_hosts+=("$host_name")
            echo ""
            continue
        fi

        # Deploy key
        if deploy_ssh_key "$ssh_host" "$ssh_key"; then
            # Verify it works
            sleep 1
            if test_ssh_connectivity "$ssh_host" "$ssh_key"; then
                print_success "SSH key deployed and verified"
                ((success_count++))
                configured_hosts+=("$host_name")
            else
                print_error "Key deployed but authentication failed"
                ((failed_count++))
                failed_hosts+=("$host_name")
            fi
        else
            print_error "Failed to deploy SSH key"
            ((failed_count++))
            failed_hosts+=("$host_name")
        fi

        echo ""
    done

    # Step 3: Summary
    echo "========================================"
    echo "Setup Complete"
    echo "========================================"
    echo ""
    echo "Results:"
    echo "  Total hosts: $((success_count + failed_count))"
    echo "  Successful: $success_count"
    echo "  Already configured: $already_configured"
    echo "  Failed: $failed_count"
    echo ""

    if [[ ${#configured_hosts[@]} -gt 0 ]]; then
        echo "Configured hosts:"
        for host in "${configured_hosts[@]}"; do
            echo "  ✓ $host"
        done
        echo ""
    fi

    if [[ $failed_count -gt 0 ]]; then
        echo "Failed hosts:"
        for host in "${failed_hosts[@]}"; do
            echo "  ✗ $host"
        done
        echo ""
        echo "Troubleshooting steps for failed hosts:"
        echo "1. Verify host is reachable: ping <host>.local"
        echo "2. Check SSH server is running on host"
        echo "3. Verify password authentication is enabled"
        echo "4. Check network connectivity"
        echo "5. Try manual connection: ssh <user>@<host>.local"
        echo ""
        return 1
    fi

    # Success message
    echo "========================================"
    echo "SSH Key Authentication Active"
    echo "========================================"
    echo ""
    echo "All cluster hosts are now configured for SSH key authentication."
    echo "Password authentication is no longer required."
    echo ""
    echo "Next steps:"
    echo "1. Update deployment scripts to use SSH keys (remove sshpass)"
    echo "2. Remove hardcoded passwords from source code"
    echo "3. Test deployment with: run_on_host <host> 'docker ps'"
    echo ""
    echo "Recommended ~/.ssh/config entries:"
    echo ""
    for host_name in $target_hosts; do
        local ssh_user="${CLUSTER_HOSTS[$host_name]%%@*}"
        local ssh_hostname="${CLUSTER_HOSTS[$host_name]#*@}"
        cat << EOF
Host ${host_name}
    HostName ${ssh_hostname}
    User ${ssh_user}
    IdentityFile ${ssh_key}
    IdentitiesOnly yes
    ControlMaster auto
    ControlPath ~/.ssh/control-%r@%h:%p
    ControlPersist 10m

EOF
    done

    echo ""
    echo "Add these to ~/.ssh/config for optimized connections."
    echo ""

    return 0
}

# =============================================================================
# MAIN SCRIPT
# =============================================================================

# Parse command line arguments
SSH_KEY=""
TARGET_HOSTS="$DEFAULT_HOSTS"
FORCE_GENERATE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --key)
            SSH_KEY="$2"
            shift 2
            ;;
        --hosts)
            TARGET_HOSTS="$2"
            shift 2
            ;;
        --generate)
            FORCE_GENERATE=true
            shift
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Force generate if requested
if [[ "$FORCE_GENERATE" == "true" ]]; then
    SSH_KEY="$DEFAULT_SSH_KEY"
    if ! generate_ssh_key "$SSH_KEY"; then
        exit 1
    fi
fi

# Run main setup
if main_setup "$SSH_KEY" "$TARGET_HOSTS"; then
    exit 0
else
    print_error "Setup failed"
    exit 1
fi
