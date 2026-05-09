#!/usr/bin/env bash
# tests/run_tests.sh - Comprehensive test runner for portoser
#
# Runs all tests, generates reports, and tracks code coverage
#
# Usage:
#   ./tests/run_tests.sh                  # Run all tests
#   ./tests/run_tests.sh lib/test_utils.sh # Run specific test
#   ./tests/run_tests.sh --coverage       # Run with coverage tracking
#   ./tests/run_tests.sh --verbose        # Verbose output

set -euo pipefail

################################################################################
# Configuration
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_DIR="$SCRIPT_DIR"
REPORTS_DIR="${REPORTS_DIR:-$SCRIPT_DIR/../qa-reports}"
COVERAGE_FILE="${COVERAGE_FILE:-.coverage}"

# Test options
VERBOSE=0
COVERAGE=0
SPECIFIC_TEST=""
JSON_OUTPUT=0

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

################################################################################
# Parse Arguments
################################################################################

parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --coverage)
                COVERAGE=1
                ;;
            --verbose|-v)
                VERBOSE=1
                ;;
            --json)
                JSON_OUTPUT=1
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                SPECIFIC_TEST="$1"
                ;;
        esac
        shift
    done
}

################################################################################
# Usage
################################################################################

show_usage() {
    cat << EOF
Test Runner for Portoser

Usage: $0 [OPTIONS] [TEST_FILE]

Options:
    --coverage      Track code coverage
    --verbose, -v   Verbose output
    --json          JSON output format
    --help, -h      Show this help message

Examples:
    $0                          # Run all tests
    $0 lib/test_utils.sh       # Run specific test file
    $0 --coverage              # Run with coverage tracking
    $0 --verbose               # Verbose output mode
    $0 --coverage --verbose    # Coverage with verbose output

Report:
    Test results are saved to: $REPORTS_DIR/
    Coverage data: $COVERAGE_FILE

EOF
}

################################################################################
# Setup
################################################################################

setup_test_environment() {
    # Create reports directory
    mkdir -p "$REPORTS_DIR"

    # Tests that exercise the portoser CLI need a registry.yml to exist at
    # the repo root (the CLI refuses to start without one). On a fresh
    # clone, registry.yml is gitignored — copy the example into place if
    # nothing's there yet, and remember that we created it so we can clean
    # up at the end.
    PORTOSER_REGISTRY="$PROJECT_ROOT/registry.yml"
    if [ ! -f "$PORTOSER_REGISTRY" ] && [ -f "$PROJECT_ROOT/registry.example.yml" ]; then
        cp "$PROJECT_ROOT/registry.example.yml" "$PORTOSER_REGISTRY"
        TEST_CREATED_REGISTRY=1
    else
        TEST_CREATED_REGISTRY=0
    fi

    # Force the CLI to use the project-local registry regardless of the
    # developer's .env (which often points elsewhere on a real install).
    export CADDY_REGISTRY_PATH="$PORTOSER_REGISTRY"

    # Initialize test counters
    export TEST_COUNTER=0
    export PASS_COUNTER=0
    export FAIL_COUNTER=0
    export SKIP_COUNTER=0
    export TEST_VERBOSE="$VERBOSE"
    export TEST_OUTPUT_MODE="json" && [ "$JSON_OUTPUT" = "0" ] && export TEST_OUTPUT_MODE="console"

    # Each per-file subshell appends "<assert>:<pass>:<fail>:<skip>" to this
    # file so the parent runner can aggregate real assertion counts (subshell
    # variable mutations don't propagate back).
    ASSERTION_LOG="$(mktemp)"
    export ASSERTION_LOG
    : > "$ASSERTION_LOG"

    # Initialize coverage if requested
    if [ "$COVERAGE" = "1" ]; then
        export TEST_COVERAGE=1
        > "$COVERAGE_FILE"
    fi

    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Portoser Test Suite${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

################################################################################
# Test Discovery and Execution
################################################################################

discover_tests() {
    local pattern="$1"

    if [ -n "$SPECIFIC_TEST" ] && [ -f "$TEST_DIR/$SPECIFIC_TEST" ]; then
        echo "$TEST_DIR/$SPECIFIC_TEST"
        return 0
    fi

    # Tests that depend on a fully set-up cluster (running services, real
    # buildx, on-disk paths) are skipped in vanilla CI. Set RUN_INTEGRATION=1
    # to include them when the environment is ready.
    local skip_re='tests/(cluster/test_cluster_compose|lib/cluster/test_build|lib/cluster/test_buildx|lib/cluster/test_sync|lib/test_critical_path|lib/test_databases)\.sh$'
    if [ "${RUN_INTEGRATION:-0}" = "1" ]; then
        find "$TEST_DIR" -name "test_*.sh" -type f | sort
    else
        find "$TEST_DIR" -name "test_*.sh" -type f | sort | grep -Ev "$skip_re" || true
    fi
}

run_test_file() {
    local test_file="$1"
    local test_name
    test_name=$(basename "$test_file" .sh)

    echo -e "${BLUE}Running $test_name...${NC}"

    # Test files come in two shapes:
    #   1. Self-contained: source framework, define + run + exit at module
    #      level (typical pattern: `main "$@"` at EOF).
    #   2. Function-only: define `test_*` functions, expect an external
    #      runner to dispatch via framework.sh's `run_tests`.
    #
    # We run *everything* in a subshell so a stray `exit 1` from shape (1)
    # cannot kill the whole runner. Inside the subshell we first try to run
    # the file directly; if that produces no output (shape-2 only defines
    # functions and returns), we then dispatch via the framework's
    # `run_tests` helper.
    local rc=0
    (
        set +e
        # Source framework so shape-2 tests can use run_tests at the end.
        source "$TEST_DIR/framework.sh"
        set +e  # framework also sets -e; undo

        local before_counter=$TEST_COUNTER
        # shellcheck disable=SC1090
        source "$test_file"
        set +e  # test file may also have set -e
        local after_counter=$TEST_COUNTER

        # If sourcing didn't run any framework tests, fall back to dispatching
        # all `test_*` functions defined in the file via the framework.
        if [ "$after_counter" -eq "$before_counter" ]; then
            local test_functions
            test_functions=$(grep -oE '^(function +)?test_[a-zA-Z0-9_]*[[:space:]]*\(\)' "$test_file" 2>/dev/null \
                             | sed -E 's/^(function +)?(test_[a-zA-Z0-9_]+).*/\2/' || true)
            for fn in $test_functions; do
                if declare -f "$fn" >/dev/null; then
                    # Run each test in its own subshell so a `set -e` inside
                    # a test function (or a failed assertion) doesn't kill
                    # the rest of the test list. The subshell appends its
                    # counter delta to ASSERTION_LOG so framework increments
                    # survive the subshell boundary.
                    (
                        set +e
                        declare -f setup >/dev/null && setup 2>/dev/null
                        "$fn"
                        declare -f teardown >/dev/null && teardown 2>/dev/null
                        printf '%s:%s:%s:%s\n' \
                          "${TEST_COUNTER:-0}" \
                          "${PASS_COUNTER:-0}" \
                          "${FAIL_COUNTER:-0}" \
                          "${SKIP_COUNTER:-0}" \
                          >> "$ASSERTION_LOG"
                    )
                fi
            done
            # The outer subshell's counters are still 0 (all increments
            # happened in inner per-test subshells), so suppress the parent
            # printf below to avoid double-counting (each test already
            # reported its own deltas).
            local _SHAPE2_SUBSHELLS_REPORTED=1
        fi
        # Report this file's framework counters back to the parent runner —
        # but only when shape-2 dispatch did NOT already report per-test deltas
        # (each per-test subshell appends its own line in that case).
        if [ "${_SHAPE2_SUBSHELLS_REPORTED:-0}" -eq 0 ]; then
            printf '%s:%s:%s:%s\n' \
              "${TEST_COUNTER:-0}" \
              "${PASS_COUNTER:-0}" \
              "${FAIL_COUNTER:-0}" \
              "${SKIP_COUNTER:-0}" \
              >> "$ASSERTION_LOG"
        fi
        exit $FAIL_COUNTER
    )
    rc=$?

    if [ "$rc" -eq 0 ]; then
        FILE_PASS_COUNTER=$((FILE_PASS_COUNTER + 1))
        echo -e "${GREEN}✓ $test_name passed${NC}"
    else
        FILE_FAIL_COUNTER=$((FILE_FAIL_COUNTER + 1))
        echo -e "${RED}✗ $test_name failed (exit $rc)${NC}"
    fi
    echo ""
    return 0
}

# Aggregate per-file assertion counters into the parent's totals.
aggregate_assertion_log() {
    [ -s "$ASSERTION_LOG" ] || return 0
    local line t p f s
    while IFS=':' read -r t p f s; do
        TEST_COUNTER=$((TEST_COUNTER + ${t:-0}))
        PASS_COUNTER=$((PASS_COUNTER + ${p:-0}))
        FAIL_COUNTER=$((FAIL_COUNTER + ${f:-0}))
        SKIP_COUNTER=$((SKIP_COUNTER + ${s:-0}))
    done < "$ASSERTION_LOG"
}

################################################################################
# Reporting
################################################################################

generate_summary_report() {
    local total=$((PASS_COUNTER + FAIL_COUNTER + SKIP_COUNTER))
    local pass_rate=0

    if [ "$total" -gt 0 ]; then
        pass_rate=$((PASS_COUNTER * 100 / total))
    fi

    local report_file="$REPORTS_DIR/test_summary_$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "Test Summary Report"
        echo "Generated: $(date)"
        echo ""
        echo "Results:"
        echo "  Passed:  $PASS_COUNTER"
        echo "  Failed:  $FAIL_COUNTER"
        echo "  Skipped: $SKIP_COUNTER"
        echo "  Total:   $total"
        echo ""
        echo "Pass Rate: $pass_rate%"
        echo ""

        if [ "$FAIL_COUNTER" -gt 0 ]; then
            echo "Failed Tests:"
            # This would include actual failed test names
            echo "  See console output for details"
        fi
    } > "$report_file"

    echo -e "${BLUE}Report saved to: $report_file${NC}"
}

generate_json_report() {
    local report_file="$REPORTS_DIR/test_report_$(date +%Y%m%d_%H%M%S).json"

    {
        echo "{"
        echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
        echo "  \"summary\": {"
        echo "    \"passed\": $PASS_COUNTER,"
        echo "    \"failed\": $FAIL_COUNTER,"
        echo "    \"skipped\": $SKIP_COUNTER,"
        echo "    \"total\": $((PASS_COUNTER + FAIL_COUNTER + SKIP_COUNTER))"
        echo "  },"
        echo "  \"coverage\": \"See $COVERAGE_FILE\""
        echo "}"
    } > "$report_file"

    echo -e "${BLUE}JSON report saved to: $report_file${NC}"
}

generate_coverage_report() {
    if [ "$COVERAGE" != "1" ]; then
        return 0
    fi

    # bash coverage requires an external tool (e.g. kcov, bashcov) which
    # isn't bundled here. Emit a stub and tell the user how to wire it up.
    local coverage_report="$REPORTS_DIR/coverage_$(date +%Y%m%d_%H%M%S).txt"
    {
        echo "Code Coverage Report"
        echo "Generated: $(date)"
        echo ""
        echo "Coverage collection is not enabled in this build."
        echo "To collect coverage, install kcov (https://github.com/SimonKagstrom/kcov)"
        echo "and re-run tests under it; integration is not yet wired up."
    } > "$coverage_report"

    echo -e "${YELLOW}Coverage stub saved to: $coverage_report (real coverage not enabled)${NC}"
}

################################################################################
# Main Execution
################################################################################

main() {
    parse_arguments "$@"

    # Setup environment
    setup_test_environment

    # Discover tests
    local test_files
    test_files=$(discover_tests "test_*.sh")

    if [ -z "$test_files" ]; then
        echo -e "${RED}Error: No test files found${NC}"
        exit 1
    fi

    # Track per-file pass/fail (separate from the in-file assertion counters
    # the framework increments). Aggregation of the latter happens after the
    # loop via the ASSERTION_LOG tempfile.
    local test_file_count=0
    FILE_PASS_COUNTER=0
    FILE_FAIL_COUNTER=0
    while IFS= read -r test_file <&3; do
        if [ -f "$test_file" ]; then
            test_file_count=$((test_file_count + 1))
            run_test_file "$test_file"
        fi
    done 3<<< "$test_files"

    # Pull per-file assertion counters out of the subshell tempfile.
    aggregate_assertion_log
    rm -f "$ASSERTION_LOG"

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Test Execution Complete${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    # Clean up the registry.yml we copied into place during setup so we
    # don't leave a working file behind.
    if [ "${TEST_CREATED_REGISTRY:-0}" = "1" ] && [ -f "$PORTOSER_REGISTRY" ]; then
        rm -f "$PORTOSER_REGISTRY"
    fi

    # Generate reports
    generate_summary_report

    if [ "$JSON_OUTPUT" = "1" ]; then
        generate_json_report
    fi

    if [ "$COVERAGE" = "1" ]; then
        generate_coverage_report
    fi

    # Summary statistics
    local total_assertions=$((PASS_COUNTER + FAIL_COUNTER + SKIP_COUNTER))
    echo -e "${BLUE}Test Files Run:    $test_file_count${NC}"
    echo -e "${BLUE}  Files Passed:    $FILE_PASS_COUNTER${NC}"
    echo -e "${BLUE}  Files Failed:    $FILE_FAIL_COUNTER${NC}"
    echo -e "${BLUE}Total Assertions:  $total_assertions${NC}"
    echo -e "${GREEN}  Passed:          $PASS_COUNTER${NC}"
    echo -e "${RED}  Failed:          $FAIL_COUNTER${NC}"
    echo -e "${YELLOW}  Skipped:         $SKIP_COUNTER${NC}"
    echo ""

    # Exit 1 if any file failed OR any assertion failed.
    if [ "$FILE_FAIL_COUNTER" -gt 0 ] || [ "$FAIL_COUNTER" -gt 0 ]; then
        echo -e "${RED}Test suite FAILED${NC}"
        exit 1
    else
        echo -e "${GREEN}Test suite PASSED${NC}"
        exit 0
    fi
}

# Run main function
main "$@"
