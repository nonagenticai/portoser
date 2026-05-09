#!/usr/bin/env bash
# =============================================================================
# test_deploy.sh - Tests for lib/cluster/deploy.sh
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
source "${LIB_DIR}/deploy.sh"

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

setup() {
    echo "Setting up test environment..."

    cat > "$TEST_REGISTRY" << 'EOF'
hosts:
  pi1:
    ip: "192.168.1.101"
    ssh_user: "pi1"
services:
  test-service:
    docker_compose: "/test-service/docker-compose.yml"
    current_host: "pi1"
    deployment_type: "docker"
EOF
}

cleanup() {
    echo "Cleaning up test environment..."
    rm -f "$TEST_REGISTRY"
}

# Tests
test_deploy_service_to_pi_invalid_params() {
    echo ""
    echo "Testing deploy_service_to_pi() with invalid parameters..."

    if deploy_service_to_pi "" "pi1" "/tmp/test" 2>/dev/null; then
        test_assert "false" "Should fail with empty service name"
    else
        test_assert "true" "Should fail with empty service name"
    fi

    if deploy_service_to_pi "test" "" "/tmp/test" 2>/dev/null; then
        test_assert "false" "Should fail with empty pi name"
    else
        test_assert "true" "Should fail with empty pi name"
    fi

    if deploy_service_to_pi "test" "pi1" "" 2>/dev/null; then
        test_assert "false" "Should fail with empty service dir"
    else
        test_assert "true" "Should fail with empty service dir"
    fi

    if deploy_service_to_pi "test" "pi1" "/nonexistent" 2>/dev/null; then
        test_assert "false" "Should fail with nonexistent service dir"
    else
        test_assert "true" "Should fail with nonexistent service dir"
    fi
}

test_deploy_to_pi_invalid_params() {
    echo ""
    echo "Testing deploy_to_pi() with invalid parameters..."

    if deploy_to_pi "" "$TEST_REGISTRY" 2>/dev/null; then
        test_assert "false" "Should fail with empty pi name"
    else
        test_assert "true" "Should fail with empty pi name"
    fi

    if deploy_to_pi "pi1" "" 2>/dev/null; then
        test_assert "false" "Should fail with empty registry file"
    else
        test_assert "true" "Should fail with empty registry file"
    fi

    if deploy_to_pi "pi1" "/nonexistent/registry.yml" 2>/dev/null; then
        test_assert "false" "Should fail with nonexistent registry file"
    else
        test_assert "true" "Should fail with nonexistent registry file"
    fi
}

test_verify_deployment_invalid_params() {
    echo ""
    echo "Testing verify_deployment() with invalid parameters..."

    if verify_deployment "" "pi1" 2>/dev/null; then
        test_assert "false" "Should fail with empty service name"
    else
        test_assert "true" "Should fail with empty service name"
    fi

    if verify_deployment "test" "" 2>/dev/null; then
        test_assert "false" "Should fail with empty pi name"
    else
        test_assert "true" "Should fail with empty pi name"
    fi
}

test_rollback_deployment_invalid_params() {
    echo ""
    echo "Testing rollback_deployment() with invalid parameters..."

    if rollback_deployment "" "pi1" 2>/dev/null; then
        test_assert "false" "Should fail with empty service name"
    else
        test_assert "true" "Should fail with empty service name"
    fi

    if rollback_deployment "test" "" 2>/dev/null; then
        test_assert "false" "Should fail with empty pi name"
    else
        test_assert "true" "Should fail with empty pi name"
    fi
}

test_data_loss_protection() {
    echo ""
    echo "Testing data loss protection (CRITICAL)..."

    # Test 1: Verify --volumes is NOT in default deploy command
    # We'll test this by checking the script source directly
    if grep -q 'local down_flags="--remove-orphans"' "${LIB_DIR}/deploy.sh"; then
        test_assert "true" "Default down_flags does NOT include --volumes"
    else
        test_assert "false" "CRITICAL: Default down_flags may include --volumes (DATA LOSS BUG!)"
    fi

    # Test 2: Verify --volumes is only added when DEPLOY_DELETE_VOLUMES is true
    if grep -q 'if \[\[ "$DEPLOY_DELETE_VOLUMES" == "true" \]\]' "${LIB_DIR}/deploy.sh"; then
        test_assert "true" "Volume deletion is conditional on DEPLOY_DELETE_VOLUMES flag"
    else
        test_assert "false" "Volume deletion is not properly protected"
    fi

    # Test 3: Verify warning is shown for volume deletion
    if grep -q 'PERMANENTLY DELETE all data' "${LIB_DIR}/deploy.sh"; then
        test_assert "true" "Warning message exists for volume deletion"
    else
        test_assert "false" "Warning message NOT found for volume deletion"
    fi

    # Test 4: Verify confirmation is required
    if grep -q 'Type.*DELETE.*to confirm' "${LIB_DIR}/deploy.sh"; then
        test_assert "true" "Confirmation prompt exists for volume deletion"
    else
        test_assert "false" "Confirmation prompt NOT found"
    fi

    # Test 5: Verify non-interactive protection
    if grep -q 'requires interactive confirmation' "${LIB_DIR}/deploy.sh"; then
        test_assert "true" "Non-interactive mode protection exists"
    else
        test_assert "false" "Non-interactive mode protection NOT found"
    fi
}

test_dry_run_mode() {
    echo ""
    echo "Testing dry-run mode..."

    # Test 1: Verify dry-run mode check exists
    if grep -q 'if \[\[ "$DEPLOY_DRY_RUN" == "true" \]\]' "${LIB_DIR}/deploy.sh"; then
        test_assert "true" "Dry-run mode check exists"
    else
        test_assert "false" "Dry-run mode check NOT found"
    fi

    # Test 2: Verify dry-run message exists
    if grep -q 'DRY RUN MODE' "${LIB_DIR}/deploy.sh"; then
        test_assert "true" "Dry-run mode message exists"
    else
        test_assert "false" "Dry-run mode message NOT found"
    fi

    # Test 3: Verify command preview exists
    if grep -q 'Commands that would be executed' "${LIB_DIR}/deploy.sh"; then
        test_assert "true" "Commands preview message exists"
    else
        test_assert "false" "Commands preview message NOT found"
    fi
}

test_environment_variable_defaults() {
    echo ""
    echo "Testing environment variable defaults..."

    # Test 1: DEPLOY_DELETE_VOLUMES should default to false
    test_assert "[[ \"\$DEPLOY_DELETE_VOLUMES\" == \"false\" ]]" "DEPLOY_DELETE_VOLUMES defaults to false"

    # Test 2: DEPLOY_DRY_RUN should default to false
    test_assert "[[ \"\$DEPLOY_DRY_RUN\" == \"false\" ]]" "DEPLOY_DRY_RUN defaults to false"

    # Test 3: DEPLOY_AUTO_VERIFY should default to true
    test_assert "[[ \"\$DEPLOY_AUTO_VERIFY\" == \"true\" ]]" "DEPLOY_AUTO_VERIFY defaults to true"

    # Test 4: DEPLOY_AUTO_ROLLBACK should default to true
    test_assert "[[ \"\$DEPLOY_AUTO_ROLLBACK\" == \"true\" ]]" "DEPLOY_AUTO_ROLLBACK defaults to true"

    # Test 5: DEPLOY_STARTUP_TIMEOUT should be set
    test_assert "[[ -n \"\$DEPLOY_STARTUP_TIMEOUT\" ]]" "DEPLOY_STARTUP_TIMEOUT is set"

    # Test 6: DEPLOY_STARTUP_TIMEOUT should be numeric
    test_assert "[[ \"\$DEPLOY_STARTUP_TIMEOUT\" =~ ^[0-9]+$ ]]" "DEPLOY_STARTUP_TIMEOUT is numeric"
}

test_volume_deletion_requires_confirmation() {
    echo ""
    echo "Testing volume deletion confirmation requirement..."

    # Test 1: Verify interactive check exists
    if grep -q 'if \[\[ -t 0 \]\]' "${LIB_DIR}/deploy.sh"; then
        test_assert "true" "Interactive mode check exists"
    else
        test_assert "false" "Interactive mode check NOT found"
    fi

    # Test 2: Verify confirmation prompt exists. Match either `read -p` or
    # `read -r -p` (the -r form is preferred for shellcheck SC2162).
    if grep -qE 'read (-r )?-p' "${LIB_DIR}/deploy.sh"; then
        test_assert "true" "Confirmation prompt exists"
    else
        test_assert "false" "Confirmation prompt NOT found"
    fi

    # Test 3: Verify aborted message for wrong confirmation
    if grep -q 'Volume deletion cancelled' "${LIB_DIR}/deploy.sh"; then
        test_assert "true" "Cancellation message exists"
    else
        test_assert "false" "Cancellation message NOT found"
    fi
}

# Run all tests
main() {
    echo "=========================================="
    echo "Running deploy.sh tests"
    echo "=========================================="
    echo ""
    echo "CRITICAL: Testing data loss protection fixes"
    echo ""

    setup

    # Critical tests first
    test_data_loss_protection
    test_environment_variable_defaults
    test_volume_deletion_requires_confirmation

    # Feature tests
    test_dry_run_mode

    # Parameter validation tests
    test_deploy_service_to_pi_invalid_params
    test_deploy_to_pi_invalid_params
    test_verify_deployment_invalid_params
    test_rollback_deployment_invalid_params

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
