#!/usr/bin/env bash
# Test suite for portoser cluster commands
# Tests CLI argument parsing, error handling, and integration with library functions

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTOSER_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Setup
PORTOSER_BIN="$PORTOSER_ROOT/portoser"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Helper function to assert contains
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-Assertion failed}"

    if echo "$haystack" | grep -qF -- "$needle"; then
        echo -e "${GREEN}[PASS]${NC} $message"
        return 0
    else
        echo -e "${RED}[FAIL]${NC} $message"
        echo "  Expected to contain: $needle"
        return 1
    fi
}

# Helper function to assert file exists
assert_file_exists() {
    local file="$1"
    local message="${2:-File should exist: $file}"

    if [[ -f "$file" ]]; then
        echo -e "${GREEN}[PASS]${NC} $message"
        return 0
    else
        echo -e "${RED}[FAIL]${NC} $message"
        return 1
    fi
}

# Helper function to run a test
run_test() {
    local test_name="$1"
    shift
    local test_cmd="$@"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo ""
    echo -e "${BLUE}[TEST $TOTAL_TESTS]${NC} $test_name"

    if eval "$test_cmd"; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi
}

# Test: Help command
test_cluster_help() {
    local output
    output=$("$PORTOSER_BIN" cluster --help 2>&1 || true)
    assert_contains "$output" "Raspberry Pi cluster management" "Help should contain description"
}

# Test: No subcommand shows help
test_cluster_no_subcommand() {
    local output
    output=$("$PORTOSER_BIN" cluster 2>&1 || true)
    assert_contains "$output" "Usage: portoser cluster" "No subcommand should show usage"
}

# Test: Invalid subcommand shows error
test_cluster_invalid_subcommand() {
    local output
    output=$("$PORTOSER_BIN" cluster invalid-command 2>&1 || true)
    assert_contains "$output" "Unknown cluster subcommand" "Invalid subcommand should show error"
}

# Test: build without arguments shows error
test_build_no_args() {
    local output
    output=$("$PORTOSER_BIN" cluster build 2>&1 || true)
    assert_contains "$output" "Must specify --all or one or more service names" "Build without args should error"
}

# Test: build with invalid option shows error
test_build_invalid_option() {
    local output
    output=$("$PORTOSER_BIN" cluster build --invalid 2>&1 || true)
    assert_contains "$output" "Unknown option" "Build with invalid option should error"
}

# Test: deploy without --all or --pi shows error
test_deploy_no_target() {
    local output
    output=$("$PORTOSER_BIN" cluster deploy 2>&1 || true)
    assert_contains "$output" "Must specify --all or --pi" "Deploy without target should error"
}

# Test: deploy with invalid option shows error
test_deploy_invalid_option() {
    local output
    output=$("$PORTOSER_BIN" cluster deploy --invalid 2>&1 || true)
    assert_contains "$output" "Unknown option" "Deploy with invalid option should error"
}

# Test: sync with invalid option shows error
test_sync_invalid_option() {
    local output
    output=$("$PORTOSER_BIN" cluster sync --invalid 2>&1 || true)
    assert_contains "$output" "Unknown option" "Sync with invalid option should error"
}

# Test: clean with invalid option shows error
test_clean_invalid_option() {
    local output
    output=$("$PORTOSER_BIN" cluster clean --invalid 2>&1 || true)
    assert_contains "$output" "Unknown option" "Clean with invalid option should error"
}

# Test: health with invalid option shows error
test_health_invalid_option() {
    local output
    output=$("$PORTOSER_BIN" cluster health --invalid 2>&1 || true)
    assert_contains "$output" "Unknown option" "Health with invalid option should error"
}

# Test: scan with invalid option shows error
test_scan_invalid_option() {
    local output
    output=$("$PORTOSER_BIN" cluster scan --invalid 2>&1 || true)
    assert_contains "$output" "Unknown option" "Scan with invalid option should error"
}

# Test: status with invalid option shows error
test_status_invalid_option() {
    local output
    output=$("$PORTOSER_BIN" cluster status --invalid 2>&1 || true)
    assert_contains "$output" "Unknown option" "Status with invalid option should error"
}

# Test: Verify cluster command is registered in main dispatcher
test_cluster_command_registered() {
    local output
    output=$("$PORTOSER_BIN" --help 2>&1)
    assert_contains "$output" "cluster" "Cluster command should be in main help"
}

# Test: Verify cluster examples in main help
test_cluster_examples_in_help() {
    local output
    output=$("$PORTOSER_BIN" --help 2>&1)
    assert_contains "$output" "portoser cluster" "Cluster examples should be in main help"
}

# Test: build help mentions flags
test_build_help_flags() {
    local output
    output=$("$PORTOSER_BIN" cluster --help 2>&1 || true)
    assert_contains "$output" "--all" "Build help should mention --all flag" &&
    assert_contains "$output" "--rebuild" "Build help should mention --rebuild flag" &&
    assert_contains "$output" "--batch-size" "Build help should mention --batch-size flag"
}

# Test: deploy help mentions flags
test_deploy_help_flags() {
    local output
    output=$("$PORTOSER_BIN" cluster --help 2>&1 || true)
    assert_contains "$output" "--all" "Deploy help should mention --all flag" &&
    assert_contains "$output" "--pi" "Deploy help should mention --pi flag"
}

# Test: sync help mentions flags
test_sync_help_flags() {
    local output
    output=$("$PORTOSER_BIN" cluster --help 2>&1 || true)
    assert_contains "$output" "--dry-run" "Sync help should mention --dry-run flag"
}

# Test: clean help mentions flags
test_clean_help_flags() {
    local output
    output=$("$PORTOSER_BIN" cluster --help 2>&1 || true)
    assert_contains "$output" "--dry-run" "Clean help should mention --dry-run flag"
}

# Test: health help mentions flags
test_health_help_flags() {
    local output
    output=$("$PORTOSER_BIN" cluster --help 2>&1 || true)
    assert_contains "$output" "--watch" "Health help should mention --watch flag" &&
    assert_contains "$output" "--no-ssl" "Health help should mention --no-ssl flag"
}

# Test: status help mentions flags
test_status_help_flags() {
    local output
    output=$("$PORTOSER_BIN" cluster --help 2>&1 || true)
    assert_contains "$output" "--json" "Status help should mention --json flag"
}

# Integration test: Verify library functions are sourced
test_library_functions_sourced() {
    assert_file_exists "$PORTOSER_ROOT/lib/cluster/build.sh" "build.sh should exist" &&
    assert_file_exists "$PORTOSER_ROOT/lib/cluster/deploy.sh" "deploy.sh should exist" &&
    assert_file_exists "$PORTOSER_ROOT/lib/cluster/sync.sh" "sync.sh should exist" &&
    assert_file_exists "$PORTOSER_ROOT/lib/cluster/health.sh" "health.sh should exist" &&
    assert_file_exists "$PORTOSER_ROOT/lib/cluster/discovery.sh" "discovery.sh should exist" &&
    assert_file_exists "$PORTOSER_ROOT/lib/cluster/buildx.sh" "buildx.sh should exist"
}

# Run all tests
main() {
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}Portoser Cluster CLI Test Suite${NC}"
    echo -e "${BLUE}======================================${NC}"

    # Help and basic tests
    run_test "Cluster help command" test_cluster_help
    run_test "Cluster no subcommand shows help" test_cluster_no_subcommand
    run_test "Cluster invalid subcommand shows error" test_cluster_invalid_subcommand
    run_test "Cluster command registered in main help" test_cluster_command_registered
    run_test "Cluster examples in main help" test_cluster_examples_in_help

    # Build command tests
    run_test "Build without arguments shows error" test_build_no_args
    run_test "Build with invalid option shows error" test_build_invalid_option
    run_test "Build help mentions all flags" test_build_help_flags

    # Deploy command tests
    run_test "Deploy without target shows error" test_deploy_no_target
    run_test "Deploy with invalid option shows error" test_deploy_invalid_option
    run_test "Deploy help mentions all flags" test_deploy_help_flags

    # Sync command tests
    run_test "Sync with invalid option shows error" test_sync_invalid_option
    run_test "Sync help mentions all flags" test_sync_help_flags

    # Clean command tests
    run_test "Clean with invalid option shows error" test_clean_invalid_option
    run_test "Clean help mentions all flags" test_clean_help_flags

    # Health command tests
    run_test "Health with invalid option shows error" test_health_invalid_option
    run_test "Health help mentions all flags" test_health_help_flags

    # Scan command tests
    run_test "Scan with invalid option shows error" test_scan_invalid_option

    # Status command tests
    run_test "Status with invalid option shows error" test_status_invalid_option
    run_test "Status help mentions all flags" test_status_help_flags

    # Integration tests
    run_test "Library functions are sourced" test_library_functions_sourced

    # Summary
    echo ""
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}Test Summary${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo -e "Total tests:  ${TOTAL_TESTS}"
    echo -e "${GREEN}Passed:       ${PASSED_TESTS}${NC}"
    if [ $FAILED_TESTS -gt 0 ]; then
        echo -e "${RED}Failed:       ${FAILED_TESTS}${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    fi
}

# Run main function
main "$@"
