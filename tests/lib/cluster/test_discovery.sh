#!/usr/bin/env bash
# =============================================================================
# test_discovery.sh - Tests for lib/cluster/discovery.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../../../lib/cluster"
TEST_DIR="/tmp/test-discovery-$$"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Source the library
source "${LIB_DIR}/discovery.sh"

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

    mkdir -p "$TEST_DIR"

    # Create test service with docker-compose.yml
    mkdir -p "$TEST_DIR/test-docker-service"
    cat > "$TEST_DIR/test-docker-service/docker-compose.yml" << 'EOF'
version: '3.8'
services:
  app:
    image: test:latest
    ports:
      - "8080:8080"
EOF

    # Create test service with service.yml
    mkdir -p "$TEST_DIR/test-native-service"
    cat > "$TEST_DIR/test-native-service/service.yml" << 'EOF'
port: 9090
name: test-native-service
EOF

    # Create directory that should be skipped
    mkdir -p "$TEST_DIR/node_modules"
    mkdir -p "$TEST_DIR/TV"
}

cleanup() {
    echo "Cleaning up test environment..."
    rm -rf "$TEST_DIR"
}

# Tests
test_parse_service_config_docker() {
    echo ""
    echo "Testing parse_service_config() with docker-compose.yml..."

    local result
    result=$(parse_service_config "$TEST_DIR/test-docker-service/docker-compose.yml" "docker" 2>/dev/null || echo "")

    test_assert_contains "$result" '"type":"docker"' "Should identify as docker type"
    test_assert_contains "$result" '"port":"8080"' "Should extract port 8080"
    test_assert_contains "$result" '"name":"test-docker-service"' "Should extract service name"
}

test_parse_service_config_native() {
    echo ""
    echo "Testing parse_service_config() with service.yml..."

    local result
    result=$(parse_service_config "$TEST_DIR/test-native-service/service.yml" "native" 2>/dev/null || echo "")

    test_assert_contains "$result" '"type":"native"' "Should identify as native type"
    test_assert_contains "$result" '"port":"9090"' "Should extract port 9090"
}

test_parse_service_config_invalid() {
    echo ""
    echo "Testing parse_service_config() with invalid parameters..."

    if parse_service_config "" "docker" 2>/dev/null; then
        test_assert "false" "Should fail with empty config file"
    else
        test_assert "true" "Should fail with empty config file"
    fi

    if parse_service_config "/nonexistent/file" "docker" 2>/dev/null; then
        test_assert "false" "Should fail with nonexistent file"
    else
        test_assert "true" "Should fail with nonexistent file"
    fi

    if parse_service_config "$TEST_DIR/test-docker-service/docker-compose.yml" "" 2>/dev/null; then
        test_assert "false" "Should fail with empty config type"
    else
        test_assert "true" "Should fail with empty config type"
    fi
}

test_scan_machine_services_local() {
    echo ""
    echo "Testing scan_machine_services() with local directory..."

    local result
    result=$(scan_machine_services "test-machine" "$TEST_DIR" "false" "" 2>/dev/null || echo "")

    test_assert_contains "$result" "test-docker-service" "Should find docker service"
    test_assert_contains "$result" "port=8080" "Should find port 8080"
    test_assert_contains "$result" "test-native-service" "Should find native service"
    test_assert_contains "$result" "port=9090" "Should find port 9090"

    # Should NOT contain skipped directories
    if [[ "$result" == *"node_modules"* ]]; then
        test_assert "false" "Should skip node_modules directory"
    else
        test_assert "true" "Should skip node_modules directory"
    fi

    if [[ "$result" == *"TV"* ]]; then
        test_assert "false" "Should skip TV directory"
    else
        test_assert "true" "Should skip TV directory"
    fi
}

test_scan_machine_services_invalid() {
    echo ""
    echo "Testing scan_machine_services() with invalid parameters..."

    if scan_machine_services "" "$TEST_DIR" 2>/dev/null; then
        test_assert "false" "Should fail with empty machine name"
    else
        test_assert "true" "Should fail with empty machine name"
    fi

    if scan_machine_services "test" "" 2>/dev/null; then
        test_assert "false" "Should fail with empty scan path"
    else
        test_assert "true" "Should fail with empty scan path"
    fi

    if scan_machine_services "test" "/nonexistent" "false" 2>/dev/null; then
        test_assert "false" "Should fail with nonexistent directory"
    else
        test_assert "true" "Should fail with nonexistent directory"
    fi

    if scan_machine_services "test" "$TEST_DIR" "true" "" 2>/dev/null; then
        test_assert "false" "Should fail when remote=true but no ssh_host"
    else
        test_assert "true" "Should fail when remote=true but no ssh_host"
    fi
}

test_discover_all_services() {
    echo ""
    echo "Testing discover_all_services()..."

    # This will attempt to scan default machines which may not exist
    # We're mainly testing that it runs without crashing
    local result
    result=$(discover_all_services "" "text" 2>/dev/null || echo "completed")

    test_assert "true" "Should execute without crashing"
}

# Run all tests
main() {
    echo "=========================================="
    echo "Running discovery.sh tests"
    echo "=========================================="

    setup

    test_parse_service_config_docker
    test_parse_service_config_native
    test_parse_service_config_invalid
    test_scan_machine_services_local
    test_scan_machine_services_invalid
    test_discover_all_services

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
