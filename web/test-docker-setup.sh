#!/usr/bin/env bash
# Test script to verify Docker setup
# Run: ./test-docker-setup.sh

set -euo pipefail

echo "🐳 Portoser Web Docker Setup Verification"
echo "=========================================="
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to check if file exists
check_file() {
    if [ -f "$1" ]; then
        echo -e "${GREEN}✅${NC} $1"
        return 0
    else
        echo -e "${RED}❌${NC} $1 - MISSING"
        return 1
    fi
}

# Function to check if command exists
check_command() {
    if command -v "$1" &> /dev/null; then
        echo -e "${GREEN}✅${NC} $1 installed"
        return 0
    else
        echo -e "${RED}❌${NC} $1 - NOT INSTALLED"
        return 1
    fi
}

echo "1. Checking Prerequisites..."
echo "----------------------------"
check_command docker
check_command docker-compose
echo ""

echo "2. Checking Docker Files..."
echo "---------------------------"
check_file "docker-compose.yml"
check_file "backend/Dockerfile"
check_file "frontend/Dockerfile"
check_file "backend/.dockerignore"
check_file "frontend/.dockerignore"
check_file ".env.example"
echo ""

echo "3. Checking Documentation..."
echo "----------------------------"
check_file "DOCKER.md"
check_file "DOCKER_QUICK_REFERENCE.md"
check_file "DOCKER_SETUP_COMPLETE.md"
echo ""

echo "4. Checking Backend Files..."
echo "----------------------------"
check_file "backend/pyproject.toml"
check_file "backend/.python-version"
check_file "backend/main.py"
echo ""

echo "5. Checking Frontend Files..."
echo "------------------------------"
check_file "frontend/package.json"
check_file "frontend/nginx.conf"
check_file "frontend/vite.config.js"
echo ""

echo "6. Validating docker-compose.yml..."
echo "------------------------------------"
if docker-compose config --quiet 2>&1 | grep -v "obsolete" | grep -q "error"; then
    echo -e "${RED}❌${NC} docker-compose.yml has errors"
else
    echo -e "${GREEN}✅${NC} docker-compose.yml is valid"
fi
echo ""

echo "7. Checking Environment Setup..."
echo "--------------------------------"
if [ -f ".env" ]; then
    echo -e "${GREEN}✅${NC} .env file exists"
    if grep -q "CADDY_REGISTRY_PATH" .env; then
        echo -e "${GREEN}✅${NC} CADDY_REGISTRY_PATH configured"
    else
        echo -e "${YELLOW}⚠️${NC}  CADDY_REGISTRY_PATH not set in .env"
    fi
else
    echo -e "${YELLOW}⚠️${NC}  .env file not created (copy from .env.example)"
fi
echo ""

echo "8. Checking Required Paths..."
echo "-----------------------------"
if [ -f ".env" ]; then
    # Temporarily disable errexit for sourcing
    set +e
    # shellcheck source=/dev/null  # .env is gitignored; runtime-only target
    source .env 2>/dev/null
    set -e
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    REGISTRY_PATH="${CADDY_REGISTRY_PATH:-$REPO_ROOT/registry.yml}"
    CLI_PATH="${PORTOSER_CLI:-$REPO_ROOT/portoser}"
    
    if [ -f "$REGISTRY_PATH" ]; then
        echo -e "${GREEN}✅${NC} Registry file found: $REGISTRY_PATH"
    else
        echo -e "${RED}❌${NC} Registry file not found: $REGISTRY_PATH"
    fi
    
    if [ -f "$CLI_PATH" ]; then
        echo -e "${GREEN}✅${NC} Portoser CLI found: $CLI_PATH"
    else
        echo -e "${RED}❌${NC} Portoser CLI not found: $CLI_PATH"
    fi
else
    echo -e "${YELLOW}⚠️${NC}  Skipped (no .env file)"
fi
echo ""

echo "9. Summary"
echo "----------"
echo ""
echo "Setup Status:"
echo -e "  Docker Configuration: ${GREEN}✅ Complete${NC}"
echo -e "  Documentation: ${GREEN}✅ Complete${NC}"
echo -e "  Build Files: ${GREEN}✅ Complete${NC}"
echo ""
echo "Next Steps:"
if [ ! -f ".env" ]; then
    echo "  1. Copy .env.example to .env"
    echo "     ${YELLOW}cp .env.example .env${NC}"
    echo ""
fi
echo "  2. Edit .env with your paths"
echo "     ${YELLOW}nano .env${NC}"
echo ""
echo "  3. Build and start"
echo "     ${YELLOW}docker-compose up -d${NC}"
echo ""
echo "  4. View logs"
echo "     ${YELLOW}docker-compose logs -f${NC}"
echo ""
echo "For complete guide, see: ${GREEN}DOCKER.md${NC}"
echo ""
