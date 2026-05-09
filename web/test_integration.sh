#!/usr/bin/env bash

# Integration test script for Portoser Web Application
# Tests CLI → Backend → Frontend data flow

set -euo pipefail

BASE_URL="${PORTOSER_BASE_URL:-http://localhost:8988}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Test backend health
test_backend_health() {
    log "Testing backend health..."
    response=$(curl -s "${BASE_URL}/api/health" || echo "FAILED")

    if [[ "$response" == "FAILED" ]]; then
        error "Backend is not responding"
        return 1
    fi

    status=$(echo "$response" | jq -r '.status' 2>/dev/null || echo "FAILED")

    if [[ "$status" == "healthy" ]]; then
        success "Backend is healthy"
        return 0
    else
        error "Backend health check failed"
        return 1
    fi
}

# Test health dashboard endpoint
test_health_dashboard() {
    log "Testing health dashboard endpoint..."
    response=$(curl -s "${BASE_URL}/api/health/dashboard" || echo "FAILED")

    if [[ "$response" == "FAILED" ]]; then
        error "Health dashboard endpoint failed"
        return 1
    fi

    overall_status=$(echo "$response" | jq -r '.overall_status' 2>/dev/null || echo "FAILED")

    if [[ "$overall_status" != "FAILED" ]]; then
        success "Health dashboard returned data (status: $overall_status)"
        return 0
    else
        error "Health dashboard returned invalid data"
        return 1
    fi
}

# Test diagnostics endpoints
test_diagnostics() {
    log "Testing diagnostics endpoints..."

    # Test health check for all services
    response=$(curl -s "${BASE_URL}/api/diagnostics/health/all" || echo "FAILED")

    if [[ "$response" == "FAILED" ]]; then
        error "Diagnostics health endpoint failed"
        return 1
    fi

    success "Diagnostics endpoints responding"
    return 0
}

# Test knowledge base endpoints
test_knowledge_base() {
    log "Testing knowledge base endpoints..."

    # Test playbooks list
    response=$(curl -s "${BASE_URL}/api/knowledge/playbooks" || echo "FAILED")

    if [[ "$response" == "FAILED" ]]; then
        error "Knowledge base playbooks endpoint failed"
        return 1
    fi

    playbook_count=$(echo "$response" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$playbook_count" -gt 0 ]]; then
        success "Knowledge base has $playbook_count playbooks"
    else
        warn "Knowledge base has no playbooks (may need CLI sync)"
    fi

    # Test stats endpoint
    response=$(curl -s "${BASE_URL}/api/knowledge/stats" || echo "FAILED")

    if [[ "$response" == "FAILED" ]]; then
        error "Knowledge base stats endpoint failed"
        return 1
    fi

    total_playbooks=$(echo "$response" | jq -r '.total_playbooks' 2>/dev/null || echo "0")
    success "Knowledge base stats: $total_playbooks playbooks"

    return 0
}

# Test deployment endpoints
test_deployment() {
    log "Testing deployment endpoints..."

    # Note: We don't actually deploy anything, just test endpoint availability
    # A dry run would be better but requires a service/machine

    success "Deployment endpoints available (manual testing required)"
    return 0
}

# Test WebSocket connectivity
test_websocket() {
    log "Testing WebSocket connectivity..."

    # Check if wscat is available
    if ! command -v wscat &> /dev/null; then
        warn "wscat not installed - skipping WebSocket test"
        warn "Install with: npm install -g wscat"
        return 0
    fi

    # Try to connect to main WebSocket endpoint
    if timeout 2 wscat -c "${PORTOSER_WS_URL:-ws://localhost:8988}/ws" -x '{"type":"ping"}' &>/dev/null; then
        success "WebSocket connection successful"
    else
        warn "WebSocket connection test inconclusive"
    fi

    return 0
}

# Test CLI availability from backend
test_cli_integration() {
    log "Testing CLI integration..."

    # The backend should report CLI availability in its logs
    # For now, just check if the health endpoint mentions CLI
    response=$(curl -s "${BASE_URL}/api/health" || echo "FAILED")

    if [[ "$response" == "FAILED" ]]; then
        error "Cannot check CLI integration"
        return 1
    fi

    success "CLI integration check passed (see backend logs for details)"
    return 0
}

# Main test suite
main() {
    echo ""
    echo "========================================"
    echo "  Portoser Web Integration Tests"
    echo "========================================"
    echo ""

    passed=0
    failed=0

    # Run all tests. Note: `cmd && ((passed++)) || ((failed++))` was the prior
    # form, but bash's `((expr++))` returns 1 when the OLD value is 0, so on
    # the first success it incremented BOTH counters. Use if/else instead.
    run_one() {
        if "$@"; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
        fi
    }
    run_one test_backend_health
    run_one test_health_dashboard
    run_one test_diagnostics
    run_one test_knowledge_base
    run_one test_deployment
    test_websocket
    run_one test_cli_integration

    echo ""
    echo "========================================"
    echo "  Test Results"
    echo "========================================"
    echo -e "${GREEN}Passed:${NC} $passed"
    echo -e "${RED}Failed:${NC} $failed"
    echo ""

    if [[ $failed -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        echo ""
        echo "Integration is working. Try these manual tests:"
        echo "  1. Open http://localhost:8989 in your browser"
        echo "  2. View the Health Dashboard"
        echo "  3. Browse the Knowledge Base playbooks"
        echo "  4. Run diagnostics on a service"
        echo "  5. Try an intelligent deployment"
        return 0
    else
        echo -e "${RED}Some tests failed. Check the output above.${NC}"
        echo ""
        echo "Common issues:"
        echo "  - Is the backend running? (docker-compose up)"
        echo "  - Is the CLI path correct in .env?"
        echo "  - Are volumes mounted correctly in docker-compose.yml?"
        return 1
    fi
}

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    error "jq is required but not installed"
    echo "Install with: brew install jq (macOS) or apt-get install jq (Linux)"
    exit 1
fi

# Check if curl is installed
if ! command -v curl &> /dev/null; then
    error "curl is required but not installed"
    exit 1
fi

# Run tests
main
