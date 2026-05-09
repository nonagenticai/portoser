#!/usr/bin/env bash

# Portoser Web - Start with Vault & Keycloak Authentication

set -euo pipefail

# Trap to cleanup background processes on exit
trap 'kill $(jobs -p) 2>/dev/null' EXIT INT TERM

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     Portoser Web - Starting with Authentication             ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if services are running
echo -e "${YELLOW}[1/4] Checking services...${NC}"

if ! curl -s http://localhost:8200/v1/sys/health > /dev/null 2>&1; then
    echo -e "${RED}Vault is not running${NC}"
    echo -e "${YELLOW}   Start a Vault instance on http://localhost:8200 (see Vault docs)${NC}"
    exit 1
fi
echo -e "${GREEN}Vault is running${NC}"

if ! curl -s http://localhost:8080/health > /dev/null 2>&1; then
    echo -e "${RED}Keycloak is not running${NC}"
    echo -e "${YELLOW}   Start a Keycloak instance on http://localhost:8080 (see Keycloak docs)${NC}"
    exit 1
fi
echo -e "${GREEN}Keycloak is running${NC}"

# Check .env file
if [ ! -f .env ]; then
    echo -e "${RED}❌ .env file not found${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Configuration file loaded${NC}"

# Start backend
echo ""
echo -e "${YELLOW}[2/4] Starting backend...${NC}"
cd backend

# Kill any existing backend process (more specific pattern)
# Verify processes exist before killing
if pgrep -f "python.*main.py" > /dev/null; then
    pkill -f "python.*main.py" || true
    sleep 1
fi

# Start backend in background
python main.py > ../logs/backend.log 2>&1 &
BACKEND_PID=$!
echo $BACKEND_PID > ../logs/backend.pid

# Wait for backend to start
sleep 3

# Security: Validate PID is numeric before using it
if [[ "$BACKEND_PID" =~ ^[0-9]+$ ]] && ps -p "$BACKEND_PID" > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Backend started (PID: $BACKEND_PID)${NC}"
else
    echo -e "${RED}❌ Backend failed to start${NC}"
    cat ../logs/backend.log
    exit 1
fi

cd ..

# Start frontend
echo ""
echo -e "${YELLOW}[3/4] Starting frontend...${NC}"
cd frontend

# Check if node_modules exists
if [ ! -d node_modules ]; then
    echo -e "${YELLOW}Installing frontend dependencies...${NC}"
    npm install
fi

# Kill any existing frontend process (more specific pattern)
# Verify processes exist before killing
if pgrep -f "vite" > /dev/null; then
    pkill -f "vite" || true
    sleep 1
fi

# Start frontend in background
npm run dev > ../logs/frontend.log 2>&1 &
FRONTEND_PID=$!
echo $FRONTEND_PID > ../logs/frontend.pid

# Wait for frontend to start
sleep 5

# Security: Validate PID is numeric before using it
if [[ "$FRONTEND_PID" =~ ^[0-9]+$ ]] && ps -p "$FRONTEND_PID" > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Frontend started (PID: $FRONTEND_PID)${NC}"
else
    echo -e "${RED}❌ Frontend failed to start${NC}"
    cat ../logs/frontend.log
    exit 1
fi

cd ..

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              Services Started! 🎉                           ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}📦 Services Running:${NC}"
echo -e "   Backend:  http://localhost:8988"
echo -e "   Frontend: http://localhost:8989"
echo ""
echo -e "${GREEN}🔐 Authentication:${NC}"
echo -e "   Vault:    http://localhost:8200"
echo -e "   Keycloak: http://localhost:8080"
echo ""
echo -e "${GREEN}👤 Login Credentials:${NC}"
echo -e "   Username: admin"
echo -e "   Password: admin123"
echo ""
echo -e "${YELLOW}📋 Logs:${NC}"
echo -e "   Backend:  tail -f logs/backend.log"
echo -e "   Frontend: tail -f logs/frontend.log"
echo ""
echo -e "${YELLOW}🛑 To stop:${NC}"
echo -e "   kill \$(cat logs/backend.pid logs/frontend.pid 2>/dev/null) 2>/dev/null"
echo ""

# Wait for background processes to complete (they won't, but keeps script alive)
wait 2>/dev/null || true
