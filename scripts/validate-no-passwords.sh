#!/usr/bin/env bash
# =============================================================================
# validate-no-passwords.sh - Validate No Hardcoded Passwords in Codebase
#
# This script scans the Portoser codebase to ensure no hardcoded passwords
# remain after migration to SSH key-based authentication.
#
# Usage:
#   ./validate-no-passwords.sh [--verbose] [--fix]
#
# Options:
#   --verbose    Show detailed output including file contents
#   --fix        Attempt to automatically fix issues (NOT IMPLEMENTED YET)
#
# Exit Codes:
#   0 - No passwords found (PASS)
#   1 - Passwords found (FAIL)
#   2 - Invalid usage or missing dependencies
#
# Created: 2025-12-08
# =============================================================================

set -euo pipefail

# Configuration
PORTOSER_ROOT="${PORTOSER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CLUSTER_CONF="${CLUSTER_CONF:-$PORTOSER_ROOT/cluster.conf}"
VERBOSE=false
FIX_MODE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --fix|-f)
            FIX_MODE=true
            shift
            ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Validate that no hardcoded passwords exist in the Portoser codebase.

Options:
  --verbose, -v    Show detailed output including context
  --fix, -f        Attempt to automatically fix issues (NOT IMPLEMENTED)
  -h, --help       Show this help message

Exit Codes:
  0 - No passwords found (PASS)
  1 - Passwords found (FAIL)
  2 - Invalid usage or dependencies missing

Examples:
  # Quick validation
  $(basename "$0")

  # Detailed validation
  $(basename "$0") --verbose

Security Notes:
  This script looks for common password patterns:
  - PASSWORD="..." or PASSWORD='...'
  - PI_PASSWORDS=(...) declarations
  - sshpass -p "..." commands
  - Literal password strings like "pi"

  Exclusions:
  - Documentation files (*.md)
  - This validation script itself
  - Database password verification tools (for legitimate use)
  - Environment variable references (OK to use)
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 2
            ;;
    esac
done

# Change to portoser root
cd "$PORTOSER_ROOT" || {
    echo -e "${RED}Error: Cannot find Portoser root: $PORTOSER_ROOT${NC}"
    exit 2
}

echo -e "${BLUE}================================================================================${NC}"
echo -e "${BLUE}Portoser Password Validation${NC}"
echo -e "${BLUE}================================================================================${NC}"
echo ""
echo "Scanning for hardcoded passwords in: $PORTOSER_ROOT"
echo ""

# Files to check. Override with $CRITICAL_FILES (newline- or space-separated).
if [[ -n "${CRITICAL_FILES_OVERRIDE:-}" ]]; then
    # shellcheck disable=SC2206
    CRITICAL_FILES=($CRITICAL_FILES_OVERRIDE)
else
    CRITICAL_FILES=(
        "lib/cluster/deploy.sh"
        "lib/cluster/sync.sh"
        "scripts/pi-build-deploy.sh"
        "scripts/sync-pi-directories.sh"
        "scripts/clean-pis.sh"
        "scripts/check-cluster-docker-health.sh"
    )
fi

# Patterns to search for (excluding legitimate uses). Each entry is a literal
# grep pattern; the ${ in the last entry is intentional, not a variable
# expansion (single quotes preserve it).
# shellcheck disable=SC2016
PATTERNS=(
    'PASSWORD="[^$]'           # PASSWORD="literal" (not $VAR)
    'PASSWORD='"'"'[^$]'       # PASSWORD='literal'
    "PI_PASSWORDS=\("          # Password array declaration
    "PI_PASSWORD=\("           # Password array declaration (singular)
    "DEPLOY_PI_PASSWORDS=\("   # Deploy library passwords
    'MINI2_PASS="'             # Mini2 password
    'PI_PASS="'                # Pi password
    'SSH_PASS="'               # SSH password
    'SUDO_PASS="'              # Sudo password
    'sshpass -p'               # sshpass with password flag
    'password="${'             # Local password variable from array
)

ISSUES_FOUND=0
FILES_WITH_ISSUES=()

# Check each critical file
echo -e "${BLUE}Checking Critical Files:${NC}"
echo ""

for file in "${CRITICAL_FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
        echo -e "  ${YELLOW}⚠${NC} $file - FILE NOT FOUND"
        ((ISSUES_FOUND++))
        continue
    fi

    file_has_issues=false
    issue_details=""

    # Check each pattern
    for pattern in "${PATTERNS[@]}"; do
        matches=$(grep -n "$pattern" "$file" 2>/dev/null || true)

        if [[ -n "$matches" ]]; then
            if [[ "$file_has_issues" == "false" ]]; then
                file_has_issues=true
                FILES_WITH_ISSUES+=("$file")
            fi

            issue_details+="$matches\n"
            ((ISSUES_FOUND++))
        fi
    done

    if [[ "$file_has_issues" == "true" ]]; then
        echo -e "  ${RED}✗${NC} $file - PASSWORDS FOUND"

        if [[ "$VERBOSE" == "true" ]]; then
            echo -e "${YELLOW}$issue_details${NC}"
        fi
    else
        echo -e "  ${GREEN}✓${NC} $file - OK"
    fi
done

echo ""
echo -e "${BLUE}Checking for sshpass Usage:${NC}"
echo ""

# Check if sshpass is still being used
SSHPASS_FILES=$(grep -r "sshpass" --include="*.sh" \
    --exclude="validate-no-passwords.sh" \
    --exclude="*.md" \
    lib/ scripts/ 2>/dev/null | cut -d: -f1 | sort -u || true)

if [[ -n "$SSHPASS_FILES" ]]; then
    echo -e "${RED}✗ Found sshpass usage in:${NC}"
    while IFS= read -r file; do
        count=$(grep -c "sshpass" "$file" || true)
        echo -e "    $file (${count} occurrences)"

        if [[ "$VERBOSE" == "true" ]]; then
            echo -e "${YELLOW}"
            grep -n "sshpass" "$file" || true
            echo -e "${NC}"
        fi
    done <<< "$SSHPASS_FILES"
    ((ISSUES_FOUND++))
else
    echo -e "${GREEN}✓ No sshpass usage found${NC}"
fi

echo ""
echo -e "${BLUE}Checking for Password Variables:${NC}"
echo ""

# Check for password array declarations
PASSWORD_ARRAYS=$(grep -r "_PASSWORD" --include="*.sh" \
    --exclude="validate-no-passwords.sh" \
    --exclude="verify-postgres-passwords.sh" \
    --exclude="*.md" \
    lib/ scripts/ 2>/dev/null | grep -E "declare.*PASSWORD|PASSWORD=\(" || true)

if [[ -n "$PASSWORD_ARRAYS" ]]; then
    echo -e "${RED}✗ Found password variable declarations:${NC}"
    echo "$PASSWORD_ARRAYS" | while IFS= read -r line; do
        echo -e "    $line"
    done
    ((ISSUES_FOUND++))
else
    echo -e "${GREEN}✓ No password variable declarations found${NC}"
fi

echo ""
echo -e "${BLUE}Checking SSH Key Configuration:${NC}"
echo ""

# Verify SSH keys are set up
SSH_KEY_EXISTS=false
if [[ -f ~/.ssh/id_ed25519 ]] || [[ -f ~/.ssh/id_rsa ]]; then
    echo -e "${GREEN}✓ SSH private key found${NC}"
    SSH_KEY_EXISTS=true
else
    echo -e "${YELLOW}⚠ No SSH private key found (id_ed25519 or id_rsa)${NC}"
    echo "  Run: ssh-keygen -t ed25519 -C \"$(whoami)@portoser-cluster\""
fi

# Test SSH key authentication to each cluster node defined in cluster.conf
if [[ "$SSH_KEY_EXISTS" == "true" ]]; then
    echo ""
    echo "Testing SSH key authentication to cluster nodes:"

    if [[ -f "$CLUSTER_CONF" ]]; then
        # shellcheck disable=SC1090
        source "$CLUSTER_CONF"
        if declare -p CLUSTER_HOSTS >/dev/null 2>&1; then
            for key in "${!CLUSTER_HOSTS[@]}"; do
                target="${CLUSTER_HOSTS[$key]}"
                if ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
                        "$target" "echo OK" &>/dev/null; then
                    echo -e "  ${GREEN}OK${NC} $key ($target) - SSH key authentication working"
                else
                    echo -e "  ${YELLOW}WARN${NC} $key ($target) - SSH key authentication NOT configured"
                    echo "       Run: ssh-copy-id $target"
                fi
            done
        else
            echo -e "  ${YELLOW}WARN${NC} CLUSTER_HOSTS not declared in $CLUSTER_CONF"
        fi
    else
        echo -e "  ${YELLOW}WARN${NC} cluster.conf not found at $CLUSTER_CONF; skipping host SSH probes."
    fi
fi

# Summary
echo ""
echo -e "${BLUE}================================================================================${NC}"
echo -e "${BLUE}Summary${NC}"
echo -e "${BLUE}================================================================================${NC}"
echo ""

if [[ $ISSUES_FOUND -eq 0 ]]; then
    echo -e "${GREEN}✓ PASS: No hardcoded passwords found${NC}"
    echo ""
    echo "Security Status: GOOD"
    echo "  - No password literals in scripts"
    echo "  - No sshpass usage"
    echo "  - No password variable declarations"
    echo ""
    echo "All scripts should now use SSH key-based authentication."
    echo ""
    exit 0
else
    echo -e "${RED}✗ FAIL: Found $ISSUES_FOUND password-related issues${NC}"
    echo ""

    if [[ ${#FILES_WITH_ISSUES[@]} -gt 0 ]]; then
        echo "Files requiring attention:"
        for file in "${FILES_WITH_ISSUES[@]}"; do
            echo -e "  ${RED}✗${NC} $file"
        done
        echo ""
    fi

    echo "Action Required:"
    echo "  1. Remove all hardcoded passwords from scripts"
    echo "  2. Replace sshpass commands with native SSH"
    echo "  3. Set up SSH keys on all cluster nodes"
    echo "  4. Test scripts with SSH key authentication"
    echo ""
    echo "Documentation: SSH_KEY_SETUP.md"
    echo ""

    if [[ "$FIX_MODE" == "true" ]]; then
        echo -e "${YELLOW}Note: Automatic fix mode not yet implemented${NC}"
        echo "      Manual fixes required for security validation"
        echo ""
    fi

    exit 1
fi
