#!/usr/bin/env bash
# tests/framework.sh - Comprehensive test framework for portoser
#
# Provides assertion functions, test runners, and reporting capabilities
# for testing shell scripts across the portoser project.
#
# Features:
#   - Assert functions (assert_equal, assert_success, assert_failure, etc.)
#   - Test case structure (setup, teardown, test runners)
#   - JSON and console output modes
#   - Code coverage tracking
#   - Performance metrics
#
# Usage:
#   source ./tests/framework.sh
#   test_some_feature() { ... assertions ... }
#   run_tests "test_*.sh"

set -euo pipefail

################################################################################
# Global Variables & Configuration
################################################################################

declare -g TEST_COUNTER=0
declare -g PASS_COUNTER=0
declare -g FAIL_COUNTER=0
declare -g SKIP_COUNTER=0
declare -g TEST_TOTAL_TIME=0
declare -g TEST_OUTPUT_MODE="${TEST_OUTPUT_MODE:-console}" # console|json
declare -ga FAILED_TESTS=()
declare -ga SKIPPED_TESTS=()
declare -gA TEST_TIMINGS=()
declare -g TEST_VERBOSE="${TEST_VERBOSE:-0}"
declare -g TEST_COVERAGE="${TEST_COVERAGE:-0}"

# Color codes — guarded so the framework can be sourced multiple times
# (e.g. by run_tests.sh wrapper and again by an individual test file).
if [ -z "${TEST_RED:-}" ]; then
    readonly TEST_RED='\033[0;31m'
    readonly TEST_GREEN='\033[0;32m'
    readonly TEST_YELLOW='\033[1;33m'
    readonly TEST_BLUE='\033[0;34m'
    readonly TEST_NC='\033[0m'
fi

################################################################################
# Core Assertion Functions
################################################################################

# Assert equality
# Args: $1 - expected value
#       $2 - actual value
#       $3 - assertion message
# Returns: 0 on success, 1 on failure
assert_equal() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should be equal}"

    if [ "$expected" = "$actual" ]; then
        _test_pass "assert_equal" "$message"
        return 0
    else
        _test_fail "assert_equal" "$message" "Expected: '$expected' but got: '$actual'"
        return 1
    fi
}

# Assert not equal
assert_not_equal() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should not be equal}"

    if [ "$expected" != "$actual" ]; then
        _test_pass "assert_not_equal" "$message"
        return 0
    else
        _test_fail "assert_not_equal" "$message" "Expected different values but got: '$actual'"
        return 1
    fi
}

# Assert command succeeds (exit code 0)
assert_success() {
    local command="$1"
    local message="${2:-Command should succeed}"

    if eval "$command" &>/dev/null; then
        _test_pass "assert_success" "$message"
        return 0
    else
        _test_fail "assert_success" "$message" "Command failed: $command"
        return 1
    fi
}

# Assert command fails (non-zero exit code)
assert_failure() {
    local command="$1"
    local message="${2:-Command should fail}"

    if ! eval "$command" &>/dev/null; then
        _test_pass "assert_failure" "$message"
        return 0
    else
        _test_fail "assert_failure" "$message" "Command unexpectedly succeeded: $command"
        return 1
    fi
}

# Assert string contains substring
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should contain substring}"

    if [[ "$haystack" == *"$needle"* ]]; then
        _test_pass "assert_contains" "$message"
        return 0
    else
        _test_fail "assert_contains" "$message" "Expected to find '$needle' in '$haystack'"
        return 1
    fi
}

# Assert string does not contain substring
assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should not contain substring}"

    if [[ "$haystack" != *"$needle"* ]]; then
        _test_pass "assert_not_contains" "$message"
        return 0
    else
        _test_fail "assert_not_contains" "$message" "Expected NOT to find '$needle' in '$haystack'"
        return 1
    fi
}

# Assert file exists
assert_file_exists() {
    local file="$1"
    local message="${2:-File should exist: $file}"

    if [ -f "$file" ]; then
        _test_pass "assert_file_exists" "$message"
        return 0
    else
        _test_fail "assert_file_exists" "$message" "File not found: $file"
        return 1
    fi
}

# Assert file does not exist
assert_file_not_exists() {
    local file="$1"
    local message="${2:-File should not exist: $file}"

    if [ ! -f "$file" ]; then
        _test_pass "assert_file_not_exists" "$message"
        return 0
    else
        _test_fail "assert_file_not_exists" "$message" "File exists but shouldn't: $file"
        return 1
    fi
}

# Assert directory exists
assert_dir_exists() {
    local dir="$1"
    local message="${2:-Directory should exist: $dir}"

    if [ -d "$dir" ]; then
        _test_pass "assert_dir_exists" "$message"
        return 0
    else
        _test_fail "assert_dir_exists" "$message" "Directory not found: $dir"
        return 1
    fi
}

# Assert directory does not exist
assert_dir_not_exists() {
    local dir="$1"
    local message="${2:-Directory should not exist: $dir}"

    if [ ! -d "$dir" ]; then
        _test_pass "assert_dir_not_exists" "$message"
        return 0
    else
        _test_fail "assert_dir_not_exists" "$message" "Directory exists but shouldn't: $dir"
        return 1
    fi
}

# Assert true condition
assert_true() {
    local condition="$1"
    local message="${2:-Condition should be true}"

    if eval "$condition"; then
        _test_pass "assert_true" "$message"
        return 0
    else
        _test_fail "assert_true" "$message" "Condition evaluated to false: $condition"
        return 1
    fi
}

# Assert false condition
assert_false() {
    local condition="$1"
    local message="${2:-Condition should be false}"

    if ! eval "$condition"; then
        _test_pass "assert_false" "$message"
        return 0
    else
        _test_fail "assert_false" "$message" "Condition evaluated to true: $condition"
        return 1
    fi
}

# Assert variable is empty
assert_empty() {
    local value="$1"
    local message="${2:-Variable should be empty}"

    if [ -z "$value" ]; then
        _test_pass "assert_empty" "$message"
        return 0
    else
        _test_fail "assert_empty" "$message" "Expected empty but got: '$value'"
        return 1
    fi
}

# Assert variable is not empty
assert_not_empty() {
    local value="$1"
    local message="${2:-Variable should not be empty}"

    if [ -n "$value" ]; then
        _test_pass "assert_not_empty" "$message"
        return 0
    else
        _test_fail "assert_not_empty" "$message" "Variable is empty"
        return 1
    fi
}

################################################################################
# Test Execution Helpers
################################################################################

# Mark test as passed
_test_pass() {
    local type="$1"
    local message="$2"
    PASS_COUNTER=$((PASS_COUNTER + 1))
    TEST_COUNTER=$((TEST_COUNTER + 1))

    if [ "$TEST_VERBOSE" = "1" ]; then
        _test_output "PASS" "$type" "$message"
    fi
}

# Mark test as failed
_test_fail() {
    local type="$1"
    local message="$2"
    local detail="$3"
    FAIL_COUNTER=$((FAIL_COUNTER + 1))
    TEST_COUNTER=$((TEST_COUNTER + 1))

    _test_output "FAIL" "$type" "$message" "$detail"
    FAILED_TESTS+=("$message")
}

# Output test result
_test_output() {
    local status="$1"
    local type="$2"
    local message="$3"
    local detail="${4:-}"

    if [ "$TEST_OUTPUT_MODE" = "json" ]; then
        _test_output_json "$status" "$type" "$message" "$detail"
    else
        _test_output_console "$status" "$type" "$message" "$detail"
    fi
}

# Console output formatting
_test_output_console() {
    local status="$1"
    local type="$2"
    local message="$3"
    local detail="${4:-}"

    case "$status" in
        PASS)
            echo -e "${TEST_GREEN}✓${TEST_NC} $message"
            ;;
        FAIL)
            echo -e "${TEST_RED}✗${TEST_NC} $message"
            [ -n "$detail" ] && echo -e "${TEST_RED}  Detail: $detail${TEST_NC}"
            ;;
        SKIP)
            echo -e "${TEST_YELLOW}⊘${TEST_NC} $message"
            ;;
    esac
}

# JSON output formatting
_test_output_json() {
    local status="$1"
    local type="$2"
    local message="$3"
    local detail="${4:-}"

    # Simple JSON format (can be enhanced)
    printf '{"status":"%s","type":"%s","message":"%s"' "$status" "$type" "$message"
    [ -n "$detail" ] && printf ',"detail":"%s"' "$detail"
    printf '}\n'
}

# Skip test with message
skip_test() {
    local message="$1"
    SKIP_COUNTER=$((SKIP_COUNTER + 1))
    SKIPPED_TESTS+=("$message")
    _test_output "SKIP" "skip" "$message"
}

################################################################################
# Test Setup/Teardown
################################################################################

# Setup function (called before each test)
setup() {
    :  # Override in test files
}

# Teardown function (called after each test)
teardown() {
    :  # Override in test files
}

################################################################################
# Test Runner Functions
################################################################################

# Run a single test function
run_test() {
    local test_name="$1"
    local start_time=$(date +%s%N)

    if ! declare -f "$test_name" &>/dev/null; then
        echo -e "${TEST_RED}Error: Test function not found: $test_name${TEST_NC}"
        return 1
    fi

    # Run setup and teardown
    if declare -f setup &>/dev/null; then
        setup
    fi

    # Run the test function
    if eval "$test_name" 2>/dev/null; then
        :
    fi

    # Run teardown
    if declare -f teardown &>/dev/null; then
        teardown
    fi

    local end_time=$(date +%s%N)
    local duration=$((end_time - start_time))
    TEST_TIMINGS["$test_name"]=$duration
    TEST_TOTAL_TIME=$((TEST_TOTAL_TIME + duration))
}

# Run all tests matching pattern
run_tests() {
    local pattern="${1:-test_*.sh}"
    local test_dir="${2:-.}"
    local test_files

    test_files=$(find "$test_dir" -name "$pattern" -type f)

    if [ -z "$test_files" ]; then
        echo "No test files found matching: $pattern"
        return 1
    fi

    echo -e "${TEST_BLUE}Running tests...${TEST_NC}"
    echo ""

    while IFS= read -r test_file; do
        # Source the test file
        if [ -f "$test_file" ]; then
            source "$test_file"

            # Extract test functions from the file
            local test_functions
            test_functions=$(grep -o "^test_[a-zA-Z0-9_]*\s*()" "$test_file" | sed 's/\s*()//')

            for test_func in $test_functions; do
                run_test "$test_func"
            done
        fi
    done <<< "$test_files"
}

################################################################################
# Reporting Functions
################################################################################

# Print test summary
print_test_summary() {
    local total=$((PASS_COUNTER + FAIL_COUNTER + SKIP_COUNTER))
    local pass_rate=0

    if [ "$total" -gt 0 ]; then
        pass_rate=$((PASS_COUNTER * 100 / total))
    fi

    echo ""
    echo -e "${TEST_BLUE}====== TEST SUMMARY ======${TEST_NC}"
    echo -e "${TEST_GREEN}Passed: $PASS_COUNTER${TEST_NC}"
    echo -e "${TEST_RED}Failed: $FAIL_COUNTER${TEST_NC}"
    echo -e "${TEST_YELLOW}Skipped: $SKIP_COUNTER${TEST_NC}"
    echo -e "${TEST_BLUE}Total: $total${TEST_NC}"
    echo -e "${TEST_BLUE}Pass Rate: $pass_rate%${TEST_NC}"
    echo -e "${TEST_BLUE}Total Time: ${TEST_TOTAL_TIME}ms${TEST_NC}"
    echo -e "${TEST_BLUE}==========================${TEST_NC}"
    echo ""

    # Print failed tests
    if [ "${#FAILED_TESTS[@]}" -gt 0 ]; then
        echo -e "${TEST_RED}Failed Tests:${TEST_NC}"
        for test in "${FAILED_TESTS[@]}"; do
            echo -e "  ${TEST_RED}✗${TEST_NC} $test"
        done
        echo ""
    fi

    # Return appropriate exit code
    [ "$FAIL_COUNTER" -eq 0 ] && return 0 || return 1
}

# Print detailed timing report
print_timing_report() {
    echo ""
    echo -e "${TEST_BLUE}====== TIMING REPORT ======${TEST_NC}"

    # Sort by duration
    if [ "${#TEST_TIMINGS[@]}" -gt 0 ]; then
        for test in "${!TEST_TIMINGS[@]}"; do
            echo "  ${TEST_TIMINGS[$test]}ms - $test"
        done | sort -rn
    fi

    echo -e "${TEST_BLUE}============================${TEST_NC}"
    echo ""
}

# Initialize coverage tracking
init_coverage() {
    TEST_COVERAGE=1
    export COVERAGE_FILE="${COVERAGE_FILE:-.coverage}"
}

# Print coverage report
print_coverage_report() {
    if [ "$TEST_COVERAGE" = "0" ]; then
        return 0
    fi

    echo ""
    echo -e "${TEST_BLUE}====== COVERAGE REPORT ======${TEST_NC}"
    # Coverage implementation would go here
    echo "Coverage tracking initialized"
    echo -e "${TEST_BLUE}==============================${TEST_NC}"
    echo ""
}

################################################################################
# Utility Functions
################################################################################

# Create temporary test directory
create_test_dir() {
    local tmpdir
    tmpdir=$(mktemp -d)
    echo "$tmpdir"
    return 0
}

# Clean up test directory
cleanup_test_dir() {
    local dir="$1"
    if [ -d "$dir" ]; then
        rm -rf "$dir"
    fi
}

# Mock a command
mock_command() {
    local cmd="$1"
    local output="$2"

    eval "${cmd}() { echo '$output'; }"
    export -f "$cmd"
}

# Restore mocked command
unmock_command() {
    local cmd="$1"
    unset -f "$cmd"
}

################################################################################
# Export Functions
################################################################################

export -f assert_equal
export -f assert_not_equal
export -f assert_success
export -f assert_failure
export -f assert_contains
export -f assert_not_contains
export -f assert_file_exists
export -f assert_file_not_exists
export -f assert_dir_exists
export -f assert_dir_not_exists
export -f assert_true
export -f assert_false
export -f assert_empty
export -f assert_not_empty
export -f skip_test
export -f setup
export -f teardown
export -f run_test
export -f run_tests
export -f print_test_summary
export -f print_timing_report
export -f print_coverage_report
export -f init_coverage
export -f create_test_dir
export -f cleanup_test_dir
export -f mock_command
export -f unmock_command
