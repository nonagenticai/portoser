#!/usr/bin/env bash
# =============================================================================
# test_build.sh - Tests for lib/cluster/build.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../../../lib/cluster"
TEST_REGISTRY="/tmp/test-registry.yml"
TEST_BUILD_DIR="/tmp/test-build"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Source the library
source "${LIB_DIR}/build.sh"

# Test utilities
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

test_assert_equals() {
    local expected="$1"
    local actual="$2"
    local test_name="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name (expected: '$expected', got: '$actual')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Setup
setup() {
    echo "Setting up test environment..."

    # Create test registry
    cat > "$TEST_REGISTRY" << 'EOF'
services:
  test-service:
    docker_compose: "/test-service/docker-compose.yml"
    current_host: "pi1"
  another-service:
    service_file: "/another-service/service.yml"
    current_host: "pi2"
EOF

    # Create test build directory
    mkdir -p "$TEST_BUILD_DIR"
    cat > "$TEST_BUILD_DIR/Dockerfile" << 'EOF'
FROM alpine:latest
CMD ["echo", "test"]
EOF
}

cleanup() {
    echo "Cleaning up test environment..."
    rm -f "$TEST_REGISTRY"
    rm -rf "$TEST_BUILD_DIR"
}

# Tests
test_get_service_build_dir_valid() {
    echo ""
    echo "Testing get_service_build_dir() with valid service..."

    local result
    result=$(get_service_build_dir "test-service" "$TEST_REGISTRY" "/tmp/portoser-test" 2>/dev/null || echo "")

    # The function should return a path ending with test-service
    if [[ "$result" == *"test-service" ]]; then
        test_assert "true" "Should return build directory path"
    else
        test_assert "false" "Should return build directory path (got: $result)"
    fi
}

test_get_service_build_dir_invalid() {
    echo ""
    echo "Testing get_service_build_dir() with invalid parameters..."

    if get_service_build_dir "" "$TEST_REGISTRY" 2>/dev/null; then
        test_assert "false" "Should fail with empty service name"
    else
        test_assert "true" "Should fail with empty service name"
    fi

    if get_service_build_dir "test-service" "" 2>/dev/null; then
        test_assert "false" "Should fail with empty registry file"
    else
        test_assert "true" "Should fail with empty registry file"
    fi

    if get_service_build_dir "nonexistent" "$TEST_REGISTRY" 2>/dev/null; then
        test_assert "false" "Should fail with nonexistent service"
    else
        test_assert "true" "Should fail with nonexistent service"
    fi
}

test_build_arm64_service_invalid_params() {
    echo ""
    echo "Testing build_arm64_service() with invalid parameters..."

    if build_arm64_service "" "$TEST_BUILD_DIR" "test-builder" 2>/dev/null; then
        test_assert "false" "Should fail with empty service name"
    else
        test_assert "true" "Should fail with empty service name"
    fi

    if build_arm64_service "test" "" "test-builder" 2>/dev/null; then
        test_assert "false" "Should fail with empty build dir"
    else
        test_assert "true" "Should fail with empty build dir"
    fi

    if build_arm64_service "test" "$TEST_BUILD_DIR" "" 2>/dev/null; then
        test_assert "false" "Should fail with empty builder name"
    else
        test_assert "true" "Should fail with empty builder name"
    fi

    if build_arm64_service "test" "/nonexistent" "test-builder" 2>/dev/null; then
        test_assert "false" "Should fail with nonexistent build dir"
    else
        test_assert "true" "Should fail with nonexistent build dir"
    fi
}

test_build_arm64_service_no_dockerfile() {
    echo ""
    echo "Testing build_arm64_service() without Dockerfile..."

    local temp_dir="/tmp/no-dockerfile-$$"
    mkdir -p "$temp_dir"

    if build_arm64_service "test" "$temp_dir" "test-builder" 2>/dev/null; then
        test_assert "false" "Should fail without Dockerfile"
    else
        test_assert "true" "Should fail without Dockerfile"
    fi

    rm -rf "$temp_dir"
}

test_push_to_registry_invalid() {
    echo ""
    echo "Testing push_to_registry() with invalid parameters..."

    if push_to_registry "" 2>/dev/null; then
        test_assert "false" "Should fail with empty service name"
    else
        test_assert "true" "Should fail with empty service name"
    fi
}

test_build_services_parallel_invalid() {
    echo ""
    echo "Testing build_services_parallel() with invalid parameters..."

    if build_services_parallel "" "$TEST_REGISTRY" "test-builder" 2>/dev/null; then
        test_assert "false" "Should fail with empty services list"
    else
        test_assert "true" "Should fail with empty services list"
    fi

    if build_services_parallel "service1" "" "test-builder" 2>/dev/null; then
        test_assert "false" "Should fail with empty registry file"
    else
        test_assert "true" "Should fail with empty registry file"
    fi

    if build_services_parallel "service1" "$TEST_REGISTRY" "" 2>/dev/null; then
        test_assert "false" "Should fail with empty builder name"
    else
        test_assert "true" "Should fail with empty builder name"
    fi
}

# Run all tests
main() {
    echo "=========================================="
    echo "Running build.sh tests"
    echo "=========================================="

    setup

    test_get_service_build_dir_valid
    test_get_service_build_dir_invalid
    test_build_arm64_service_invalid_params
    test_build_arm64_service_no_dockerfile
    test_push_to_registry_invalid
    test_build_services_parallel_invalid

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
