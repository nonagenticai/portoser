#!/usr/bin/env bash
# =============================================================================
# test_sync.sh - Tests for lib/cluster/sync.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../../../lib/cluster"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Source the library
source "${LIB_DIR}/sync.sh"

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
        echo -e "${RED}✗${NC} $test_name (expected to contain: '$needle')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Tests
test_get_sync_excludes() {
    echo ""
    echo "Testing get_sync_excludes()..."

    local excludes
    excludes=$(get_sync_excludes)

    test_assert_contains "$excludes" "--exclude='*.pyc'" "Should exclude .pyc files"
    test_assert_contains "$excludes" "--exclude='node_modules'" "Should exclude node_modules"
    test_assert_contains "$excludes" "--exclude='.git'" "Should exclude .git"
    test_assert_contains "$excludes" "--exclude='*.log'" "Should exclude log files"
}

test_test_ssh_connectivity_invalid() {
    echo ""
    echo "Testing test_ssh_connectivity() with invalid parameters..."

    if test_ssh_connectivity "" 2>/dev/null; then
        test_assert "false" "Should fail with empty pi name"
    else
        test_assert "true" "Should fail with empty pi name"
    fi
}

test_sync_pi_directory_invalid_params() {
    echo ""
    echo "Testing sync_pi_directory() with invalid parameters..."

    if sync_pi_directory "" "pull" 2>/dev/null; then
        test_assert "false" "Should fail with empty pi name"
    else
        test_assert "true" "Should fail with empty pi name"
    fi

    if sync_pi_directory "pi1" "" 2>/dev/null; then
        test_assert "false" "Should fail with empty direction"
    else
        test_assert "true" "Should fail with empty direction"
    fi

    if sync_pi_directory "pi1" "invalid" 2>/dev/null; then
        test_assert "false" "Should fail with invalid direction"
    else
        test_assert "true" "Should fail with invalid direction"
    fi
}

test_sync_all_pis_invalid_params() {
    echo ""
    echo "Testing sync_all_pis() with invalid parameters..."

    if sync_all_pis "" 2>/dev/null; then
        test_assert "false" "Should fail with empty direction"
    else
        test_assert "true" "Should fail with empty direction"
    fi

    if sync_all_pis "invalid" 2>/dev/null; then
        test_assert "false" "Should fail with invalid direction"
    else
        test_assert "true" "Should fail with invalid direction"
    fi

    if sync_all_pis "pull" "invalid-pi-name" 2>/dev/null; then
        test_assert "false" "Should fail with invalid pi name"
    else
        test_assert "true" "Should fail with invalid pi name"
    fi
}

# Run all tests
main() {
    echo "=========================================="
    echo "Running sync.sh tests"
    echo "=========================================="

    test_get_sync_excludes
    test_test_ssh_connectivity_invalid
    test_sync_pi_directory_invalid_params
    test_sync_all_pis_invalid_params

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
