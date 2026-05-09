#!/usr/bin/env bash
#
# Audit all service certificates in the registry
# Checks for proper hostname matching, SANs, expiration, and CA signing
#
# Usage:
#   ./audit-certificates.sh
#   ./audit-certificates.sh --fix    # Auto-fix issues (interactive)

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
BASE_PATH="${BASE_PATH:-$(dirname "$PORTOSER_ROOT")}"

# Statistics
TOTAL=0
VALID=0
INVALID=0
MISSING=0
HOSTNAME_MISMATCH=0

# Check if yq is available
if ! command -v yq &> /dev/null; then
    echo -e "${RED}Error: yq is not installed${NC}"
    echo "Install with: brew install yq"
    exit 1
fi

# Print header
echo -e "\n${BLUE}================================================================================${NC}"
echo -e "${BLUE}Certificate Audit - All Services in Registry${NC}"
echo -e "${BLUE}================================================================================${NC}\n"

# Get all services that have certificates
services=$(yq eval '.services | to_entries | .[] | select(.value.tls_cert != null) | .key' "$REGISTRY" 2>/dev/null)

if [[ -z "$services" ]]; then
    echo -e "${YELLOW}No services with certificates found in registry${NC}\n"
    exit 0
fi

echo -e "${GRAY}Found $(echo "$services" | wc -l | tr -d ' ') services with certificates${NC}\n"

# Function to check certificate
check_certificate() {
    local service="$1"
    local hostname="$2"
    local cert_path="$3"
    local ca_path="$4"

    ((TOTAL++))

    printf "%-30s " "$service"

    # Check if certificate file exists
    if [[ ! -f "$cert_path" ]]; then
        echo -e "${RED}✗ MISSING${NC}"
        echo -e "            ${GRAY}Certificate file not found: $cert_path${NC}"
        ((MISSING++))
        return 1
    fi

    # Extract certificate details
    local cert_cn
    cert_cn=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed -n 's/.*CN[= ]*\([^,]*\).*/\1/p')
    local cert_sans
    cert_sans=$(openssl x509 -in "$cert_path" -noout -ext subjectAltName 2>/dev/null | grep -v "Subject Alternative Name" | sed 's/^[[:space:]]*//' || echo "")
    local cert_expiry
    cert_expiry=$(openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | cut -d= -f2)

    # Check if certificate is valid
    if [[ -z "$cert_cn" ]]; then
        echo -e "${RED}✗ INVALID${NC}"
        echo -e "            ${GRAY}Unable to read certificate${NC}"
        ((INVALID++))
        return 1
    fi

    # Check hostname match
    local hostname_match=false
    if [[ "$cert_cn" == "$hostname" ]]; then
        hostname_match=true
    elif [[ "$cert_sans" == *"$hostname"* ]]; then
        hostname_match=true
    fi

    # Check if CA signed
    local ca_signed=false
    if [[ -n "$ca_path" ]] && [[ -f "$ca_path" ]]; then
        if openssl verify -CAfile "$ca_path" "$cert_path" &>/dev/null; then
            ca_signed=true
        fi
    fi

    # Check expiration
    local expiry_epoch
    expiry_epoch=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$cert_expiry" +%s 2>/dev/null)
    local now_epoch
    now_epoch=$(date +%s)
    local days_until_expiry
    days_until_expiry=$(( (expiry_epoch - now_epoch) / 86400 ))
    local expired=false
    if [[ $days_until_expiry -lt 0 ]]; then
        expired=true
    fi

    # Determine overall status
    local status="valid"
    local issues=()

    if ! $hostname_match; then
        status="invalid"
        issues+=("CN/SAN mismatch")
        ((HOSTNAME_MISMATCH++))
    fi

    if ! $ca_signed; then
        status="invalid"
        issues+=("not CA-signed")
    fi

    if $expired; then
        status="invalid"
        issues+=("expired")
    fi

    # Print status
    if [[ "$status" == "valid" ]]; then
        echo -e "${GREEN}✓ VALID${NC}"
        echo -e "            ${GRAY}CN: $cert_cn${NC}"
        if [[ -n "$cert_sans" ]]; then
            echo -e "            ${GRAY}SANs: $(echo "$cert_sans" | tr '\n' ' ')${NC}"
        fi
        echo -e "            ${GRAY}Expires: $cert_expiry (${days_until_expiry} days)${NC}"
        ((VALID++))
    else
        echo -e "${RED}✗ INVALID${NC}"
        echo -e "            ${GRAY}Expected: $hostname${NC}"
        echo -e "            ${GRAY}CN: $cert_cn${NC}"
        if [[ -n "$cert_sans" ]]; then
            echo -e "            ${GRAY}SANs: $(echo "$cert_sans" | tr '\n' ' ')${NC}"
        else
            echo -e "            ${GRAY}SANs: none${NC}"
        fi
        echo -e "            ${GRAY}Issues: ${RED}${issues[*]}${NC}"
        ((INVALID++))
    fi
}

# Check each service
while IFS= read -r service; do
    if [[ -z "$service" ]]; then
        continue
    fi

    hostname=$(yq eval ".services.${service}.hostname" "$REGISTRY")
    tls_cert=$(yq eval ".services.${service}.tls_cert" "$REGISTRY")
    ca_cert=$(yq eval ".services.${service}.ca_cert" "$REGISTRY")

    # Resolve paths
    cert_path="${BASE_PATH}${tls_cert}"
    ca_path=""
    if [[ -n "$ca_cert" ]] && [[ "$ca_cert" != "null" ]]; then
        ca_path="${BASE_PATH}${ca_cert}"
    else
        # Default CA path
        ca_path="${BASE_PATH}/ca-cert.pem"
    fi

    check_certificate "$service" "$hostname" "$cert_path" "$ca_path"
    echo ""
done <<< "$services"

# Print summary
echo -e "${BLUE}================================================================================${NC}"
echo -e "${BLUE}Summary${NC}"
echo -e "${BLUE}================================================================================${NC}\n"

echo -e "  Total certificates checked: $TOTAL"
[[ $VALID -gt 0 ]] && echo -e "  ${GREEN}✓${NC} Valid:                  $VALID"
[[ $INVALID -gt 0 ]] && echo -e "  ${RED}✗${NC} Invalid:                $INVALID"
[[ $MISSING -gt 0 ]] && echo -e "  ${RED}✗${NC} Missing:                $MISSING"
[[ $HOSTNAME_MISMATCH -gt 0 ]] && echo -e "  ${YELLOW}⚠${NC} Hostname mismatches:    $HOSTNAME_MISMATCH"

echo ""

# Exit code based on results
if [[ $INVALID -gt 0 ]] || [[ $MISSING -gt 0 ]]; then
    echo -e "${RED}✗  Found $((INVALID + MISSING)) certificate issue(s)${NC}\n"
    exit 1
else
    echo -e "${GREEN}✓  All certificates are valid!${NC}\n"
    exit 0
fi
