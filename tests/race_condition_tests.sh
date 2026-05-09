#!/usr/bin/env bash
# =============================================================================
# Race-condition tests for lib/locks.sh + lib/state.sh.
# Covers atomic operations, state transitions, and rollback under concurrency.
# =============================================================================

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTOSER_ROOT="$(cd "$TEST_DIR/.." && pwd)"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Source libraries
source "$PORTOSER_ROOT/lib/locks.sh" 2>/dev/null || {
    echo "Failed to source locks.sh" >&2
    exit 1
}

source "$PORTOSER_ROOT/lib/state.sh" 2>/dev/null || {
    echo "Failed to source state.sh" >&2
    exit 1
}

# =============================================================================
# Test Utilities
# =============================================================================

run_test() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -n "  [$TESTS_RUN] $test_name... "
}

pass() {
    echo -e "${GREEN}PASS${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    local reason="${1:-Unknown reason}"
    echo -e "${RED}FAIL${NC}"
    echo "    Reason: $reason"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# =============================================================================
# File Locking System
# =============================================================================

test_locks_exclusive_acquisition() {
    run_test "Exclusive lock acquisition"

    local test_resource="test_lock_$$"
    if acquire_lock "$test_resource" 5 "Test exclusive lock"; then
        release_lock "$test_resource"
        pass
    else
        fail "Failed to acquire exclusive lock"
    fi
}

test_locks_nested_locking() {
    run_test "Nested lock acquisition"

    local test_resource="test_nested_$$"
    if acquire_lock "$test_resource" 5 && \
       acquire_lock "$test_resource" 5 && \
       release_lock "$test_resource" && \
       release_lock "$test_resource"; then
        pass
    else
        fail "Nested locking failed"
    fi
}

test_locks_shared_locking() {
    run_test "Shared lock acquisition"

    local test_resource="test_shared_$$"
    if acquire_shared_lock "$test_resource" 5 && \
       release_shared_lock "$test_resource"; then
        pass
    else
        fail "Shared lock failed"
    fi
}

test_locks_lock_timeout() {
    run_test "Lock timeout mechanism"

    local test_resource="test_timeout_$$"

    # Acquire lock
    acquire_lock "$test_resource" 30 >/dev/null 2>&1 || true

    # Try to acquire again with short timeout
    if ! acquire_lock "$test_resource" 1 >/dev/null 2>&1; then
        release_lock "$test_resource" >/dev/null 2>&1 || true
        pass
    else
        release_lock "$test_resource" >/dev/null 2>&1 || true
        fail "Lock timeout not working"
    fi
}

test_locks_is_locked_check() {
    run_test "is_locked() status check"

    local test_resource="test_check_$$"

    # Should not be locked initially
    if is_locked "$test_resource"; then
        fail "Resource should not be locked initially"
        return
    fi

    # Acquire lock
    acquire_lock "$test_resource" 5 >/dev/null 2>&1

    # Should be locked now
    if is_locked "$test_resource"; then
        release_lock "$test_resource" >/dev/null 2>&1
        pass
    else
        fail "Lock status check failed"
    fi
}

test_locks_concurrent_safety() {
    run_test "Concurrent lock safety (simulated)"

    local test_resource="test_concurrent_$$"
    local test_file="/tmp/test_concurrent_$$"

    rm -f "$test_file"
    echo "0" > "$test_file"

    # Simulate concurrent writes with lock protection
    for i in {1..5}; do
        {
            acquire_lock "$test_resource" 10 >/dev/null 2>&1 || exit 1
            local current=$(cat "$test_file")
            sleep 0.1
            echo "$((current + 1))" > "$test_file"
            release_lock "$test_resource" >/dev/null 2>&1
        } &
    done

    wait

    local final=$(cat "$test_file")
    rm -f "$test_file"

    if [[ "$final" == "5" ]]; then
        pass
    else
        fail "Concurrent writes not atomic (expected 5, got $final)"
    fi
}

# =============================================================================
# State Management
# =============================================================================

test_state_initialization() {
    run_test "State initialization"

    local test_service="test_service_$$"

    if state_init "$test_service" "pending" '{"test":"data"}'; then
        local state=$(state_get "$test_service" 2>/dev/null)
        if [[ "$state" == "pending" ]]; then
            pass
        else
            fail "Initial state not set correctly"
        fi
    else
        fail "Failed to initialize state"
    fi
}

test_state_set_and_get() {
    run_test "State set and get operations"

    local test_service="test_state_$$"

    state_init "$test_service" "unknown" >/dev/null 2>&1 || true

    if state_set "$test_service" "running" '{"test":"data"}'; then
        local state=$(state_get "$test_service" 2>/dev/null)
        if [[ "$state" == "running" ]]; then
            pass
        else
            fail "State not set correctly (expected running, got $state)"
        fi
    else
        fail "Failed to set state"
    fi
}

test_state_checkpoint_restore() {
    run_test "State checkpoint and restore"

    local test_service="test_checkpoint_$$"

    state_init "$test_service" "initial" >/dev/null 2>&1 || true

    # Create checkpoint
    local checkpoint
    checkpoint=$(state_checkpoint "$test_service" "test_check" "Test checkpoint" 2>/dev/null) || {
        fail "Failed to create checkpoint"
        return
    }

    # Change state
    state_set "$test_service" "modified" >/dev/null 2>&1 || true

    # Restore checkpoint
    if state_restore "$test_service" "$checkpoint" >/dev/null 2>&1; then
        local restored_state=$(state_get "$test_service" 2>/dev/null)
        if [[ "$restored_state" == "initial" ]]; then
            pass
        else
            fail "State not restored correctly"
        fi
    else
        fail "Failed to restore checkpoint"
    fi
}

test_state_transitions() {
    run_test "State transition validation"

    local test_service="test_transition_$$"

    state_init "$test_service" "pending" >/dev/null 2>&1 || true

    if state_transition "$test_service" "deploying" '{"reason":"testing"}' >/dev/null 2>&1; then
        local current=$(state_get "$test_service" 2>/dev/null)
        if [[ "$current" == "deploying" ]]; then
            pass
        else
            fail "State transition failed"
        fi
    else
        fail "Failed to transition state"
    fi
}

test_state_validation() {
    run_test "State consistency validation"

    local test_service="test_validation_$$"

    state_init "$test_service" "running" >/dev/null 2>&1 || true

    if state_validate "$test_service" >/dev/null 2>&1; then
        pass
    else
        fail "Valid state failed validation"
    fi
}

test_state_atomic_writes() {
    run_test "State atomic write safety"

    local test_service="test_atomic_$$"
    local test_file="/tmp/test_atomic_$$"

    state_init "$test_service" "0" >/dev/null 2>&1 || true

    # Simulate concurrent state changes (should be atomic)
    local errors=0
    for i in {1..3}; do
        {
            state_set "$test_service" "state_$i" >/dev/null 2>&1 || errors=$((errors + 1))
        } &
    done

    wait

    if [[ $errors -eq 0 ]]; then
        pass
    else
        fail "Atomic state writes had $errors errors"
    fi
}

# =============================================================================
# INTEGRATION TESTS: Cross-Agent Coordination
# =============================================================================

test_integration_locks_and_state() {
    run_test "Integration: Locks protect state changes"

    local test_service="test_integration_$$"
    local test_resource="test_integration_lock_$$"

    state_init "$test_service" "pending" >/dev/null 2>&1 || true

    if acquire_lock "$test_resource" 10 >/dev/null 2>&1; then
        state_set "$test_service" "locked_state" >/dev/null 2>&1 || true
        release_lock "$test_resource" >/dev/null 2>&1 || true

        local state=$(state_get "$test_service" 2>/dev/null)
        if [[ "$state" == "locked_state" ]]; then
            pass
        else
            fail "Lock-protected state change failed"
        fi
    else
        fail "Failed to acquire integration lock"
    fi
}

test_integration_deployment_transaction() {
    run_test "Integration: Deployment transaction simulation"

    local test_service="test_deploy_$$"
    local lock_name="${test_service}_deploy"

    # Simulate deployment transaction
    if acquire_lock "$lock_name" 10 >/dev/null 2>&1; then
        state_init "$test_service" "deploying" >/dev/null 2>&1 || true

        local checkpoint
        checkpoint=$(state_checkpoint "$test_service" "before_deploy" "Pre-deploy" 2>/dev/null) || true

        state_transition "$test_service" "running" >/dev/null 2>&1 || true

        release_lock "$lock_name" >/dev/null 2>&1

        local final_state=$(state_get "$test_service" 2>/dev/null)
        if [[ "$final_state" == "running" ]] && [[ -n "$checkpoint" ]]; then
            pass
        else
            fail "Deployment transaction simulation failed"
        fi
    else
        fail "Failed to acquire deployment lock"
    fi
}

# =============================================================================
# Race Condition Specific Tests
# =============================================================================

test_race_condition_file_access() {
    run_test "Race condition: Concurrent file access"

    local lock_resource="race_file_$$"
    local test_file="/tmp/race_test_$$"
    local expected_count=10

    rm -f "$test_file"
    echo "0" > "$test_file"

    # 10 concurrent increments without locks would cause race condition
    for i in $(seq 1 $expected_count); do
        {
            acquire_lock "$lock_resource" 10 >/dev/null 2>&1
            local val=$(cat "$test_file")
            echo "$((val + 1))" > "$test_file"
            release_lock "$lock_resource" >/dev/null 2>&1
        } &
    done

    wait

    local final=$(cat "$test_file")
    rm -f "$test_file"

    if [[ "$final" == "$expected_count" ]]; then
        pass
    else
        fail "Race condition detected: expected $expected_count, got $final"
    fi
}

test_race_condition_state_consistency() {
    run_test "Race condition: State consistency under load"

    local test_service="race_state_$$"
    local states=("pending" "deploying" "running" "stopping" "stopped")
    local errors=0

    state_init "$test_service" "pending" >/dev/null 2>&1 || true

    # Rapid state changes from multiple "processes"
    for state in "${states[@]}"; do
        {
            state_transition "$test_service" "$state" >/dev/null 2>&1 || errors=$((errors + 1))
        } &
    done

    wait

    if [[ $errors -eq 0 ]]; then
        # Verify final state is valid
        state_validate "$test_service" >/dev/null 2>&1 && pass || fail "Final state invalid"
    else
        fail "State changes failed ($errors errors)"
    fi
}

# =============================================================================
# Main Test Execution
# =============================================================================

main() {
    echo ""
    echo "=========================================="
    echo "Race Condition Test Suite"
    echo "=========================================="
    echo ""

    echo "File Locking System"
    echo "---"
    test_locks_exclusive_acquisition
    test_locks_nested_locking
    test_locks_shared_locking
    test_locks_lock_timeout
    test_locks_is_locked_check
    test_locks_concurrent_safety
    echo ""

    echo "State Management"
    echo "---"
    test_state_initialization
    test_state_set_and_get
    test_state_checkpoint_restore
    test_state_transitions
    test_state_validation
    test_state_atomic_writes
    echo ""

    echo "Integration Tests"
    echo "---"
    test_integration_locks_and_state
    test_integration_deployment_transaction
    echo ""

    echo "Race Condition Tests"
    echo "---"
    test_race_condition_file_access
    test_race_condition_state_consistency
    echo ""

    # Print summary
    echo "=========================================="
    echo "Test Summary"
    echo "=========================================="
    echo "Total Tests: $TESTS_RUN"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed!${NC}"
        return 1
    fi
}

main "$@"
