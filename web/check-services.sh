#!/usr/bin/env bash

# Quick service check

set -euo pipefail

echo "Checking services..."
echo ""

# Vault
if curl -s http://localhost:8200/v1/sys/health > /dev/null 2>&1; then
    echo "Vault: Running on http://localhost:8200"
else
    echo "Vault: Not running"
    echo "   Start: docker compose up -d in your vault directory (see vault docs)"
fi

# Keycloak
if curl -s http://localhost:8080/health > /dev/null 2>&1; then
    echo "Keycloak: Running on http://localhost:8080"
else
    echo "Keycloak: Not running"
    echo "   Start: docker compose up -d in your keycloak directory (see Keycloak docs)"
fi

# Backend
if curl -s http://localhost:8988/api/health > /dev/null 2>&1; then
    echo "✅ Backend: Running on http://localhost:8988"
else
    echo "❌ Backend: Not running"
fi

# Frontend
if curl -s http://localhost:8989 > /dev/null 2>&1; then
    echo "✅ Frontend: Running on http://localhost:8989"
else
    echo "❌ Frontend: Not running"
fi

echo ""
echo "Configuration:"
if [ -f .env ]; then
    echo "✅ .env file exists"
    echo ""
    echo "Settings:"
    grep "ENABLED" .env
else
    echo "❌ .env file missing"
fi
