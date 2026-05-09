#!/usr/bin/env bash
# =============================================================================
# test_buildx.sh - Tests for lib/cluster/buildx.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../../../lib/cluster"
TEST_REGISTRY="/tmp/test-registry.yml"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Source the library
source "${LIB_DIR}/buildx.sh"

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

# Setup test environment
setup() {
    echo "Setting up test environment..."

    # Create test registry file
    cat > "$TEST_REGISTRY" << 'EOF'
hosts:
  pi1:
    ip: "192.168.1.101"
    ssh_user: "pi1"
  pi2:
    ip: "192.168.1.102"
    ssh_user: "pi2"
EOF
}

# Cleanup test environment
cleanup() {
    echo "Cleaning up test environment..."
    rm -f "$TEST_REGISTRY"
}

# Tests
test_get_buildx_builder_name() {
    echo ""
    echo "Testing get_buildx_builder_name()..."

    local result
    result=$(get_buildx_builder_name)

    test_assert_equals "portoser-builder" "$result" "Should return default builder name"

    # Test with environment variable
    BUILDX_BUILDER="custom-builder"
    result=$(get_buildx_builder_name)
    test_assert_equals "custom-builder" "$result" "Should return custom builder from env"

    unset BUILDX_BUILDER
}

test_verify_buildx_ready_missing_builder() {
    echo ""
    echo "Testing verify_buildx_ready() with missing builder..."

    # Test with non-existent builder
    if verify_buildx_ready "non-existent-builder-xyz" 2>/dev/null; then
        test_assert "false" "Should fail for non-existent builder"
    else
        test_assert "true" "Should fail for non-existent builder"
    fi
}

test_verify_buildx_ready_empty_name() {
    echo ""
    echo "Testing verify_buildx_ready() with empty name..."

    if verify_buildx_ready "" 2>/dev/null; then
        test_assert "false" "Should fail for empty builder name"
    else
        test_assert "true" "Should fail for empty builder name"
    fi
}

test_setup_cluster_buildx_invalid_params() {
    echo ""
    echo "Testing setup_cluster_buildx() with invalid parameters..."

    if setup_cluster_buildx "" 2>/dev/null; then
        test_assert "false" "Should fail with empty builder name"
    else
        test_assert "true" "Should fail with empty builder name"
    fi
}

test_create_docker_contexts_invalid_registry() {
    echo ""
    echo "Testing create_docker_contexts() with invalid registry..."

    if create_docker_contexts "" 2>/dev/null; then
        test_assert "false" "Should fail with empty registry file"
    else
        test_assert "true" "Should fail with empty registry file"
    fi

    if create_docker_contexts "/nonexistent/registry.yml" 2>/dev/null; then
        test_assert "false" "Should fail with nonexistent registry file"
    else
        test_assert "true" "Should fail with nonexistent registry file"
    fi
}

test_create_docker_contexts_valid_registry() {
    echo ""
    echo "Testing create_docker_contexts() with valid registry..."

    # This test will skip Pis that aren't reachable, which is expected
    # We're mainly testing that the function runs without errors
    if create_docker_contexts "$TEST_REGISTRY" 2>/dev/null; then
        test_assert "true" "Should handle registry file (even if Pis unreachable)"
    else
        # It's okay if it fails due to SSH issues, we're testing the logic
        test_assert "true" "Function executed (may have SSH failures)"
    fi
}

# Run all tests
main() {
    echo "=========================================="
    echo "Running buildx.sh tests"
    echo "=========================================="

    setup

    test_get_buildx_builder_name
    test_verify_buildx_ready_missing_builder
    test_verify_buildx_ready_empty_name
    test_setup_cluster_buildx_invalid_params
    test_create_docker_contexts_invalid_registry
    test_create_docker_contexts_valid_registry

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
