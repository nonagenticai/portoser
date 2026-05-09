#!/usr/bin/env bash
# =============================================================================
# run_all_tests.sh - Run all library tests
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================"
echo "Running All Library Tests"
echo -e "========================================${NC}"
echo ""

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
FAILED_SUITES=()

run_test_suite() {
    local test_file="$1"
    local test_name=$(basename "$test_file" .sh)

    echo -e "${BLUE}Running $test_name...${NC}"

    if timeout 30 bash "$test_file" > "/tmp/${test_name}.log" 2>&1; then
        echo -e "${GREEN}✓ $test_name passed${NC}"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        echo -e "${RED}✗ $test_name failed${NC}"
        echo -e "${YELLOW}  See /tmp/${test_name}.log for details${NC}"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_SUITES+=("$test_name")
        return 1
    fi
}

# Run each test suite
for test_file in "$SCRIPT_DIR"/test_*.sh; do
    if [[ -f "$test_file" ]]; then
        TOTAL_TESTS=$((TOTAL_TESTS + 1))
        run_test_suite "$test_file" || true
    fi
done

echo ""
echo -e "${BLUE}========================================"
echo "Test Summary"
echo -e "========================================${NC}"
echo "Total test suites: $TOTAL_TESTS"
echo -e "${GREEN}Passed: $PASSED_TESTS${NC}"

if [[ $FAILED_TESTS -gt 0 ]]; then
    echo -e "${RED}Failed: $FAILED_TESTS${NC}"
    echo ""
    echo -e "${RED}Failed test suites:${NC}"
    for suite in "${FAILED_SUITES[@]}"; do
        echo -e "  ${RED}✗${NC} $suite"
    done
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
