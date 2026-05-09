#!/usr/bin/env bash
#
# Distribute CA certificate to all machines in the cluster
# Installs it in the system trust store on each machine
#
# Usage:
#   ./distribute-ca-cert.sh [--dry-run]

set -uo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# Registry path
PORTOSER_ROOT="${PORTOSER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REGISTRY="${REGISTRY:-$PORTOSER_ROOT/registry.yml}"
CA_CERT="${CA_CERT:-$(dirname "$PORTOSER_ROOT")/ca-cert.pem}"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

# Check if CA cert exists
if [[ ! -f "$CA_CERT" ]]; then
    echo -e "${RED}Error: CA certificate not found at $CA_CERT${NC}"
    exit 1
fi

# Check if yq is available
if ! command -v yq &> /dev/null; then
    echo -e "${RED}Error: yq is not installed${NC}"
    echo "Install with: brew install yq"
    exit 1
fi

# Print header
echo -e "\n${BLUE}================================================================================${NC}"
echo -e "${BLUE}Distribute CA Certificate to All Machines${NC}"
echo -e "${BLUE}================================================================================${NC}\n"

if $DRY_RUN; then
    echo -e "${YELLOW}⚠  DRY RUN MODE - No changes will be made${NC}\n"
fi

echo -e "${GRAY}CA Certificate: $CA_CERT${NC}"
echo -e "${GRAY}Certificate details:${NC}"
openssl x509 -in "$CA_CERT" -noout -subject -issuer -dates | sed 's/^/  /'
echo ""

# Get all hosts
hosts=$(yq eval '.hosts | keys | .[]' "$REGISTRY" 2>/dev/null)

if [[ -z "$hosts" ]]; then
    echo -e "${RED}Error: No hosts found in registry${NC}"
    exit 1
fi

TOTAL=0
SUCCESS=0
FAILED=0
SKIPPED=0

# Function to install CA cert on macOS
install_ca_macos() {
    local host="$1"
    local ip="$2"
    local ssh_user="$3"
    local ssh_port="${4:-22}"

    echo -e "${BLUE}Installing on macOS: $host ($ip)${NC}"

    if $DRY_RUN; then
        echo -e "  ${GRAY}[DRY RUN] Would copy CA cert to $ssh_user@$ip${NC}"
        echo -e "  ${GRAY}[DRY RUN] Would run: sudo security add-trusted-cert${NC}"
        return 0
    fi

    # Copy CA cert to remote machine
    echo -e "  Copying CA certificate..."
    if ! scp -P "$ssh_port" -o ConnectTimeout=5 -o BatchMode=yes "$CA_CERT" "$ssh_user@$ip:/tmp/ca-cert.pem" >/dev/null 2>&1; then
        echo -e "  ${RED}✗ Failed to copy certificate${NC}"
        return 1
    fi

    # Install in system trust store (requires sudo)
    echo -e "  Installing in system trust store..."
    if ssh -p "$ssh_port" -o ConnectTimeout=5 -o BatchMode=yes "$ssh_user@$ip" \
        "sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/ca-cert.pem && rm /tmp/ca-cert.pem" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓ Certificate installed successfully${NC}"
        return 0
    else
        echo -e "  ${YELLOW}⚠ Installation may require manual password entry${NC}"
        echo -e "  ${GRAY}Run manually: ssh $ssh_user@$ip 'sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/ca-cert.pem'${NC}"
        return 2
    fi
}

# Function to install CA cert on Linux
install_ca_linux() {
    local host="$1"
    local ip="$2"
    local ssh_user="$3"
    local ssh_port="${4:-22}"

    echo -e "${BLUE}Installing on Linux: $host ($ip)${NC}"

    if $DRY_RUN; then
        echo -e "  ${GRAY}[DRY RUN] Would copy CA cert to $ssh_user@$ip${NC}"
        echo -e "  ${GRAY}[DRY RUN] Would install in /usr/local/share/ca-certificates/${NC}"
        return 0
    fi

    # Copy CA cert to remote machine
    echo -e "  Copying CA certificate..."
    if ! scp -P "$ssh_port" -o ConnectTimeout=5 -o BatchMode=yes "$CA_CERT" "$ssh_user@$ip:/tmp/ca-cert.pem" >/dev/null 2>&1; then
        echo -e "  ${RED}✗ Failed to copy certificate${NC}"
        return 1
    fi

    # Install in system trust store
    echo -e "  Installing in system trust store..."
    if ssh -p "$ssh_port" -o ConnectTimeout=5 -o BatchMode=yes "$ssh_user@$ip" \
        "sudo mkdir -p /usr/local/share/ca-certificates && sudo cp /tmp/ca-cert.pem /usr/local/share/ca-certificates/movies-ca.crt && sudo update-ca-certificates && rm /tmp/ca-cert.pem" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓ Certificate installed successfully${NC}"
        return 0
    else
        echo -e "  ${YELLOW}⚠ Installation may require manual password entry${NC}"
        echo -e "  ${GRAY}Run manually: ssh $ssh_user@$ip 'sudo cp /tmp/ca-cert.pem /usr/local/share/ca-certificates/movies-ca.crt && sudo update-ca-certificates'${NC}"
        return 2
    fi
}

# Install on each host
while IFS= read -r host; do
    if [[ -z "$host" ]]; then
        continue
    fi

    ((TOTAL++))

    ip=$(yq eval ".hosts.${host}.ip" "$REGISTRY")
    arch=$(yq eval ".hosts.${host}.arch" "$REGISTRY")
    ssh_user=$(yq eval ".hosts.${host}.ssh_user" "$REGISTRY")
    ssh_port=22

    echo ""
    printf "%-10s " "$host"

    # Determine OS type from arch
    if [[ "$arch" == *"apple"* ]]; then
        install_ca_macos "$host" "$ip" "$ssh_user" "$ssh_port"
        result=$?
    elif [[ "$arch" == *"linux"* ]]; then
        install_ca_linux "$host" "$ip" "$ssh_user" "$ssh_port"
        result=$?
    else
        echo -e "${YELLOW}⚠ SKIPPED${NC}"
        echo -e "  ${GRAY}Unknown architecture: $arch${NC}"
        ((SKIPPED++))
        continue
    fi

    if [[ $result -eq 0 ]]; then
        ((SUCCESS++))
    elif [[ $result -eq 2 ]]; then
        # Partial success - needs manual intervention
        ((SUCCESS++))
    else
        ((FAILED++))
    fi

done <<< "$hosts"

# Print summary
echo ""
echo -e "${BLUE}================================================================================${NC}"
echo -e "${BLUE}Summary${NC}"
echo -e "${BLUE}================================================================================${NC}\n"

echo -e "  Total machines:         $TOTAL"
[[ $SUCCESS -gt 0 ]] && echo -e "  ${GREEN}✓${NC} Successful:             $SUCCESS"
[[ $FAILED -gt 0 ]] && echo -e "  ${RED}✗${NC} Failed:                 $FAILED"
[[ $SKIPPED -gt 0 ]] && echo -e "  ${YELLOW}⊙${NC} Skipped:                $SKIPPED"

echo ""

if $DRY_RUN; then
    echo -e "${YELLOW}This was a dry run. Run without --dry-run to apply changes.${NC}\n"
    exit 0
fi

# Exit code based on results
if [[ $FAILED -gt 0 ]]; then
    echo -e "${RED}✗  Some installations failed${NC}\n"
    exit 1
else
    echo -e "${GREEN}✓  CA certificate distributed successfully!${NC}\n"
    exit 0
fi
