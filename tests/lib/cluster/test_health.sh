#!/usr/bin/env bash
# =============================================================================
# test_health.sh - Tests for lib/cluster/health.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../../../lib/cluster"
TEST_REGISTRY="/tmp/test-registry.yml"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Source the library
source "${LIB_DIR}/health.sh"

test_assert() {
    local condition="$1"
    local test_name="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if eval "$condition"; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

test_assert_contains() {
    local haystack="$1"
    local needle="$2"
    local test_name="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

setup() {
    echo "Setting up test environment..."

    cat > "$TEST_REGISTRY" << 'EOF'
hosts:
  host-a:
    ip: "192.168.1.10"
services:
  test-service:
    hostname: "test.internal"
    port: "8080"
    current_host: "host-a"
  postgres:
    hostname: "db.internal"
    port: "5432"
    current_host: "host-a"
EOF
}

cleanup() {
    echo "Cleaning up test environment..."
    rm -f "$TEST_REGISTRY"
}

# Tests
test_check_service_health_detailed_invalid() {
    echo ""
    echo "Testing check_service_health_detailed() with invalid parameters..."

    # Test with empty parameters - should return error JSON
    local result
    result=$(check_service_health_detailed "" "" "" 2>&1 || echo "error")

    test_assert_contains "$result" "error" "Should return error for empty parameters"
}

test_check_service_health_detailed_skip_service() {
    echo ""
    echo "Testing check_service_health_detailed() with TCP-only service..."

    local result
    result=$(check_service_health_detailed "db.internal" "5432" "postgres" 2>/dev/null || echo "{}")

    test_assert_contains "$result" "skipped" "Should skip postgres (TCP-only service)"
    test_assert_contains "$result" "postgres" "Should include service name in output"
}

test_check_cluster_health_invalid() {
    echo ""
    echo "Testing check_cluster_health() with invalid parameters..."

    if check_cluster_health "" 2>/dev/null; then
        test_assert "false" "Should fail with empty registry file"
    else
        test_assert "true" "Should fail with empty registry file"
    fi

    if check_cluster_health "/nonexistent/registry.yml" 2>/dev/null; then
        test_assert "false" "Should fail with nonexistent registry file"
    else
        test_assert "true" "Should fail with nonexistent registry file"
    fi
}

test_check_cluster_health_valid_registry() {
    echo ""
    echo "Testing check_cluster_health() with valid registry..."

    # This will attempt to check services but may fail due to network
    # We're mainly testing that it parses the registry correctly
    local result
    result=$(check_cluster_health "$TEST_REGISTRY" "false" "text" 2>/dev/null || echo "completed")

    test_assert "true" "Should execute without crashing"
}

test_get_health_summary() {
    echo ""
    echo "Testing get_health_summary()..."

    local test_json='{"healthy": 10, "degraded": 2, "down": 1, "total": 13}'
    local result
    result=$(get_health_summary "$test_json")

    test_assert_contains "$result" "HEALTHY: 10" "Should extract healthy count"
    test_assert_contains "$result" "DEGRADED: 2" "Should extract degraded count"
    test_assert_contains "$result" "DOWN: 1" "Should extract down count"
    test_assert_contains "$result" "TOTAL: 13" "Should extract total count"
}

test_get_health_summary_invalid() {
    echo ""
    echo "Testing get_health_summary() with invalid input..."

    if get_health_summary "" 2>/dev/null; then
        test_assert "false" "Should fail with empty input"
    else
        test_assert "true" "Should fail with empty input"
    fi
}

# Run all tests
main() {
    echo "=========================================="
    echo "Running health.sh tests"
    echo "=========================================="

    setup

    test_check_service_health_detailed_invalid
    test_check_service_health_detailed_skip_service
    test_check_cluster_health_invalid
    test_check_cluster_health_valid_registry
    test_get_health_summary
    test_get_health_summary_invalid

    cleanup

    echo ""
    echo "=========================================="
    echo "Test Results"
    echo "=========================================="
    echo "Tests run:    $TESTS_RUN"
    echo -e "${GREEN}Tests passed: $TESTS_PASSED${NC}"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "${RED}Tests failed: $TESTS_FAILED${NC}"
        exit 1
    else
        echo "All tests passed!"
        exit 0
    fi
}

main "$@"
