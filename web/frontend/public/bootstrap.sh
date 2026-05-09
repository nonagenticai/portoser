#!/usr/bin/env bash
#
# Portoser Bootstrap Script
# Zero-touch onboarding for new Linux devices joining a Portoser cluster.
#
# Usage:
#   curl -fsSL http://<central-host>:<port>/bootstrap.sh | \
#       PORTOSER_CENTRAL=<central-host> PORTOSER_API_PORT=<port> bash
#
# All configuration is overridable via environment variables; defaults are
# documented next to each variable below.
#

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ----------------------------------------------------------------------------
# Configuration (override via environment)
# ----------------------------------------------------------------------------
# Hostname of the central Portoser controller this device should register with.
PORTOSER_CENTRAL="${PORTOSER_CENTRAL:-portoser}"
# Port the central controller's HTTP API listens on.
PORTOSER_API_PORT="${PORTOSER_API_PORT:-8700}"
# Local directory where portoser-managed files (configs, data, logs) live.
PORTOSER_HOME="${PORTOSER_HOME:-${HOME}/portoser}"
# OS user that will own the portoser install on this device.
PORTOSER_USER="${PORTOSER_USER:-${USER}}"
# Path to the SSH key used for cluster operations (created if absent).
SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.ssh/id_rsa}"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Banner
print_banner() {
    echo -e "${GREEN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║   ██████╗  ██████╗ ██████╗ ████████╗ ██████╗ ███████╗   ║
║   ██╔══██╗██╔═══██╗██╔══██╗╚══██╔══╝██╔═══██╗██╔════╝   ║
║   ██████╔╝██║   ██║██████╔╝   ██║   ██║   ██║███████╗   ║
║   ██╔═══╝ ██║   ██║██╔══██╗   ██║   ██║   ██║╚════██║   ║
║   ██║     ╚██████╔╝██║  ██║   ██║   ╚██████╔╝███████║   ║
║   ╚═╝      ╚═════╝ ╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚══════╝   ║
║                                                           ║
║              Zero-Touch Device Onboarding                 ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# Step 1: Detect System
detect_system() {
    log_info "Step 1: Detecting system information..."

    # Detect OS
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null  # OS-supplied, only present on Linux
        . /etc/os-release
        OS_NAME="$NAME"
        OS_VERSION="$VERSION_ID"
        OS_ID="$ID"
    else
        log_error "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi

    # Detect architecture
    ARCH=$(uname -m)

    # Detect kernel
    KERNEL=$(uname -r)

    # Detect hostname
    HOSTNAME=$(hostname)

    # Detect primary IP
    PRIMARY_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}' || echo "unknown")

    # Detect resources
    TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
    CPU_CORES=$(nproc)
    DISK_SPACE=$(df -h / | awk 'NR==2 {print $4}')

    log_success "System detected:"
    echo "  OS: $OS_NAME $OS_VERSION ($OS_ID)"
    echo "  Architecture: $ARCH"
    echo "  Kernel: $KERNEL"
    echo "  Hostname: $HOSTNAME"
    echo "  IP Address: $PRIMARY_IP"
    echo "  RAM: ${TOTAL_RAM}MB"
    echo "  CPU Cores: $CPU_CORES"
    echo "  Free Disk: $DISK_SPACE"
    echo ""
}

# Step 2: Install Dependencies
install_dependencies() {
    log_info "Step 2: Installing dependencies..."

    # Determine package manager
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
    elif command -v pacman &> /dev/null; then
        PKG_MANAGER="pacman"
    else
        log_error "Unsupported package manager. Supported: apt, dnf, pacman"
        exit 1
    fi

    log_info "Using package manager: $PKG_MANAGER"

    # Install Docker
    install_docker

    # Install essential tools
    install_essential_tools

    log_success "Dependencies installed successfully"
    echo ""
}

install_docker() {
    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version | awk '{print $3}' | tr -d ',')
        log_info "Docker already installed: $DOCKER_VERSION"

        # Ensure user is in docker group
        if ! groups "$PORTOSER_USER" | grep -q docker; then
            log_info "Adding $PORTOSER_USER to docker group..."
            sudo usermod -aG docker "$PORTOSER_USER"
            log_warn "You may need to log out and back in for docker group to take effect"
        fi
        return
    fi

    log_info "Installing Docker..."

    case $PKG_MANAGER in
        apt)
            # Ubuntu/Debian
            sudo apt-get update -qq
            sudo apt-get install -y ca-certificates curl gnupg
            sudo install -m 0755 -d /etc/apt/keyrings
            curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            sudo chmod a+r /etc/apt/keyrings/docker.gpg

            # shellcheck source=/dev/null  # OS-supplied, only present on Linux
            echo \
              "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS_ID \
              $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
              sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

            sudo apt-get update -qq
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;

        dnf)
            # Fedora
            sudo dnf -y install dnf-plugins-core
            sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;

        pacman)
            # Arch Linux
            sudo pacman -Sy --noconfirm docker docker-compose
            ;;
    esac

    # Start and enable Docker
    sudo systemctl start docker
    sudo systemctl enable docker

    # Add user to docker group
    sudo usermod -aG docker "$PORTOSER_USER"

    log_success "Docker installed successfully"
}

install_essential_tools() {
    log_info "Installing essential tools..."

    case $PKG_MANAGER in
        apt)
            sudo apt-get install -y curl wget git jq ssh rsync net-tools iproute2
            ;;
        dnf)
            sudo dnf install -y curl wget git jq openssh-clients rsync net-tools iproute
            ;;
        pacman)
            sudo pacman -S --noconfirm curl wget git jq openssh rsync net-tools iproute2
            ;;
    esac

    log_success "Essential tools installed"
}

# Step 3: Setup SSH Keys
setup_ssh_keys() {
    log_info "Step 3: Setting up SSH keys..."

    if [ -f "$SSH_KEY_PATH" ]; then
        log_info "SSH key already exists at $SSH_KEY_PATH"
    else
        log_info "Generating new SSH key pair..."
        mkdir -p "${HOME}/.ssh"
        chmod 700 "${HOME}/.ssh"

        ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -C "${PORTOSER_USER}@${HOSTNAME}"

        log_success "SSH key generated"
    fi

    # Get public key
    SSH_PUBLIC_KEY=$(cat "${SSH_KEY_PATH}.pub")

    echo "  Public Key: ${SSH_PUBLIC_KEY:0:60}..."
    echo ""
}

# Step 4: Create Directory Structure
create_directory_structure() {
    log_info "Step 4: Creating portoser directory structure..."

    mkdir -p "$PORTOSER_HOME"/{portoser,configs,data,logs,scripts}

    log_success "Directory structure created at $PORTOSER_HOME"
    echo "  Created:"
    echo "    - $PORTOSER_HOME/portoser"
    echo "    - $PORTOSER_HOME/configs"
    echo "    - $PORTOSER_HOME/data"
    echo "    - $PORTOSER_HOME/logs"
    echo "    - $PORTOSER_HOME/scripts"
    echo ""
}

# Step 5: Download compose.sh Template
download_compose_template() {
    log_info "Step 5: Downloading compose.sh template..."

    COMPOSE_SCRIPT="$PORTOSER_HOME/portoser/compose.sh"

    if curl -fsSL "http://${PORTOSER_CENTRAL}:${PORTOSER_API_PORT}/compose.sh" -o "$COMPOSE_SCRIPT" 2>/dev/null; then
        chmod +x "$COMPOSE_SCRIPT"
        log_success "compose.sh downloaded successfully"
    else
        log_warn "Could not download compose.sh from central server (may not be available yet)"

        # Create a placeholder
        cat > "$COMPOSE_SCRIPT" << 'COMPOSE_EOF'
#!/usr/bin/env bash
# Portoser Compose Script Placeholder
# Will be replaced with the real template once the central controller is reachable.

echo "Compose script placeholder - waiting for central server configuration"
COMPOSE_EOF
        chmod +x "$COMPOSE_SCRIPT"
    fi

    echo ""
}

# Step 6: Register with Central Controller
register_with_central() {
    log_info "Step 6: Registering with central controller (${PORTOSER_CENTRAL})..."

    # Create registration payload
    REGISTRATION_DATA=$(cat <<EOF
{
  "hostname": "$HOSTNAME",
  "ip_address": "$PRIMARY_IP",
  "os": "$OS_NAME $OS_VERSION",
  "os_id": "$OS_ID",
  "architecture": "$ARCH",
  "kernel": "$KERNEL",
  "ram_mb": $TOTAL_RAM,
  "cpu_cores": $CPU_CORES,
  "disk_free": "$DISK_SPACE",
  "ssh_public_key": "$SSH_PUBLIC_KEY",
  "user": "$PORTOSER_USER",
  "portoser_home": "$PORTOSER_HOME",
  "docker_version": "$(docker --version 2>/dev/null || echo 'not installed')",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)

    # Try to register with central API
    if curl -fsSL -X POST \
        -H "Content-Type: application/json" \
        -d "$REGISTRATION_DATA" \
        "http://${PORTOSER_CENTRAL}:${PORTOSER_API_PORT}/api/register" \
        2>/dev/null | grep -q "success\|registered"; then
        log_success "Successfully registered with central controller"
    else
        log_warn "Could not reach central controller API (may not be running yet)"
        log_info "Saving registration data locally for manual sync..."

        # Save registration data locally
        echo "$REGISTRATION_DATA" > "$PORTOSER_HOME/configs/registration.json"

        # Create a local registry entry
        cat > "$PORTOSER_HOME/configs/device-info.yml" << EOF
device:
  hostname: $HOSTNAME
  ip_address: $PRIMARY_IP
  os: $OS_NAME $OS_VERSION
  architecture: $ARCH
  kernel: $KERNEL
  resources:
    ram_mb: $TOTAL_RAM
    cpu_cores: $CPU_CORES
    disk_free: $DISK_SPACE
  user: $PORTOSER_USER
  home: $PORTOSER_HOME
  ssh_public_key: |
    $SSH_PUBLIC_KEY
  registered_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

        log_info "Registration data saved locally"
    fi

    echo ""
}

# Step 7: Self-Test
run_self_test() {
    log_info "Step 7: Running self-test..."

    TESTS_PASSED=0
    TESTS_FAILED=0

    # Test 1: Docker
    if docker --version &> /dev/null && docker ps &> /dev/null; then
        log_success "✓ Docker is installed and running"
        ((TESTS_PASSED++))
    else
        log_error "✗ Docker is not working properly"
        ((TESTS_FAILED++))
    fi

    # Test 2: SSH Key
    if [ -f "$SSH_KEY_PATH" ] && [ -f "${SSH_KEY_PATH}.pub" ]; then
        log_success "✓ SSH keys are present"
        ((TESTS_PASSED++))
    else
        log_error "✗ SSH keys are missing"
        ((TESTS_FAILED++))
    fi

    # Test 3: Directory Structure
    if [ -d "$PORTOSER_HOME/portoser" ] && [ -d "$PORTOSER_HOME/configs" ]; then
        log_success "✓ Directory structure created"
        ((TESTS_PASSED++))
    else
        log_error "✗ Directory structure incomplete"
        ((TESTS_FAILED++))
    fi

    # Test 4: Network connectivity to the central controller
    if ping -c 1 -W 2 "$PORTOSER_CENTRAL" &> /dev/null; then
        log_success "✓ Network connectivity to ${PORTOSER_CENTRAL}"
        ((TESTS_PASSED++))
    else
        log_warn "✗ Cannot ping ${PORTOSER_CENTRAL} (may not be configured in /etc/hosts yet)"
        ((TESTS_FAILED++))
    fi

    # Test 5: Essential tools
    MISSING_TOOLS=""
    for tool in curl wget git jq ssh docker; do
        if ! command -v "$tool" &> /dev/null; then
            MISSING_TOOLS="$MISSING_TOOLS $tool"
        fi
    done

    if [ -z "$MISSING_TOOLS" ]; then
        log_success "✓ All essential tools installed"
        ((TESTS_PASSED++))
    else
        log_error "✗ Missing tools:$MISSING_TOOLS"
        ((TESTS_FAILED++))
    fi

    echo ""
    echo "Self-test results: $TESTS_PASSED passed, $TESTS_FAILED failed"
    echo ""
}

# Step 8: Generate Bootstrap Report
generate_report() {
    log_info "Step 8: Generating bootstrap report..."

    REPORT_FILE="$PORTOSER_HOME/logs/bootstrap-report.txt"

    cat > "$REPORT_FILE" << EOF
Portoser Bootstrap Report
=========================
Generated: $(date)

System Information:
-------------------
Hostname: $HOSTNAME
IP Address: $PRIMARY_IP
OS: $OS_NAME $OS_VERSION ($OS_ID)
Architecture: $ARCH
Kernel: $KERNEL

Resources:
----------
RAM: ${TOTAL_RAM}MB
CPU Cores: $CPU_CORES
Disk Free: $DISK_SPACE

Configuration:
--------------
User: $PORTOSER_USER
Home: $PORTOSER_HOME
SSH Key: $SSH_KEY_PATH

Docker:
-------
Version: $(docker --version 2>/dev/null || echo 'Not installed')
Running: $(docker ps &> /dev/null && echo 'Yes' || echo 'No')

Network:
--------
Primary IP: $PRIMARY_IP
Can reach ${PORTOSER_CENTRAL}: $(ping -c 1 -W 2 "$PORTOSER_CENTRAL" &> /dev/null && echo 'Yes' || echo 'No')

SSH Public Key:
---------------
$SSH_PUBLIC_KEY

Bootstrap Status: COMPLETE
EOF

    log_success "Bootstrap report saved to $REPORT_FILE"
    echo ""
}

# Step 9: Print Next Steps
print_next_steps() {
    log_info "Bootstrap Complete!"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Next Steps:${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "1. Add this device to ${PORTOSER_CENTRAL}'s /etc/hosts:"
    echo "   ${PRIMARY_IP}  ${HOSTNAME}"
    echo ""
    echo "2. Add ${PORTOSER_CENTRAL} to this device's /etc/hosts (if not already done):"
    echo "   sudo sh -c 'echo \"<central-ip>  ${PORTOSER_CENTRAL}\" >> /etc/hosts'"
    echo ""
    echo "3. If docker group was just added, log out and back in:"
    echo "   exit"
    echo ""
    echo "4. Copy your SSH public key to ${PORTOSER_CENTRAL} for passwordless access:"
    echo "   ssh-copy-id ${PORTOSER_CENTRAL}"
    echo ""
    echo "5. Test connectivity to portoser cluster:"
    echo "   cd $PORTOSER_HOME/portoser"
    echo "   ./compose.sh status"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Device Information:"
    echo "  Hostname: $HOSTNAME"
    echo "  IP: $PRIMARY_IP"
    echo "  Home: $PORTOSER_HOME"
    echo ""
    echo "Logs and reports available at:"
    echo "  $PORTOSER_HOME/logs/"
    echo ""
}

# Main execution
main() {
    print_banner

    # Check if running as root
    if [ "$EUID" -eq 0 ]; then
        log_error "Do not run this script as root. Run as the user who will manage portoser."
        exit 1
    fi

    # Check for sudo access
    if ! sudo -n true 2>/dev/null; then
        log_info "This script requires sudo access. You may be prompted for your password."
        sudo -v
    fi

    log_info "Starting zero-touch onboarding for: $USER@$(hostname)"
    echo ""

    # Execute all steps
    detect_system
    install_dependencies
    setup_ssh_keys
    create_directory_structure
    download_compose_template
    register_with_central
    run_self_test
    generate_report
    print_next_steps

    log_success "Bootstrap completed successfully!"

    # Create success marker
    touch "$PORTOSER_HOME/.bootstrap-complete"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$PORTOSER_HOME/.bootstrap-complete"
}

# Idempotency check
check_idempotency() {
    if [ -f "$PORTOSER_HOME/.bootstrap-complete" ]; then
        log_warn "Bootstrap has already been run on this system."
        log_info "Previous run: $(cat "$PORTOSER_HOME/.bootstrap-complete")"
        echo ""
        read -p "Do you want to run it again? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Bootstrap cancelled. Exiting."
            exit 0
        fi
        log_info "Re-running bootstrap (idempotent mode)..."
        echo ""
    fi
}

# Entry point
check_idempotency
main "$@"
