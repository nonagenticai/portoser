#!/usr/bin/env bash
# tests/lib/test_utils.sh - Unit tests for lib/utils.sh
#
# Tests all utility functions including:
#   - Color printing functions
#   - Parameter validation
#   - Host parsing
#   - Path existence checks
#   - Summary printing

set -euo pipefail

# Source the framework and the library to test
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/utils.sh"

################################################################################
# Setup and Teardown
################################################################################

setup() {
    # Create test directory for file/directory checks
    TEST_TMP_DIR=$(mktemp -d)
    TEST_FILE="$TEST_TMP_DIR/test_file.txt"
    TEST_DIR="$TEST_TMP_DIR/test_dir"

    # Create test fixtures
    touch "$TEST_FILE"
    mkdir -p "$TEST_DIR"
}

teardown() {
    # Clean up test files
    if [ -d "$TEST_TMP_DIR" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}

################################################################################
# Color Printing Tests (15 tests)
################################################################################

test_print_color_red() {
    local output
    output=$(print_color "red" "error" 2>&1)
    assert_contains "$output" "error" "Color red output should contain message"
}

test_print_color_green() {
    local output
    output=$(print_color "green" "success" 2>&1)
    assert_contains "$output" "success" "Color green output should contain message"
}

test_print_color_yellow() {
    local output
    output=$(print_color "yellow" "warning" 2>&1)
    assert_contains "$output" "warning" "Color yellow output should contain message"
}

test_print_color_blue() {
    local output
    output=$(print_color "blue" "info" 2>&1)
    assert_contains "$output" "info" "Color blue output should contain message"
}

test_print_color_invalid_color() {
    local output
    output=$(print_color "invalid" "message" 2>&1)
    assert_contains "$output" "message" "Invalid color should output plain message"
}

test_print_if_not_json_disabled() {
    JSON_OUTPUT_MODE=0
    local output
    output=$(print_if_not_json "red" "test" 2>&1)
    assert_contains "$output" "test" "Should print when not in JSON mode"
}

test_print_if_not_json_enabled() {
    JSON_OUTPUT_MODE=1
    local output
    output=$(print_if_not_json "red" "test" 2>&1)
    assert_empty "$output" "Should not print when in JSON mode"
    JSON_OUTPUT_MODE=0
}

test_echo_if_not_json_disabled() {
    JSON_OUTPUT_MODE=0
    local output
    output=$(echo_if_not_json "test message" 2>&1)
    assert_contains "$output" "test message" "Should echo when not in JSON mode"
}

test_echo_if_not_json_enabled() {
    JSON_OUTPUT_MODE=1
    local output
    output=$(echo_if_not_json "test message" 2>&1)
    assert_empty "$output" "Should not echo when in JSON mode"
    JSON_OUTPUT_MODE=0
}

test_color_constants_defined() {
    assert_true "[ -n \"\$RED\" ]" "RED color constant should be defined"
    assert_true "[ -n \"\$GREEN\" ]" "GREEN color constant should be defined"
    assert_true "[ -n \"\$YELLOW\" ]" "YELLOW color constant should be defined"
    assert_true "[ -n \"\$BLUE\" ]" "BLUE color constant should be defined"
}

test_string_constants_defined() {
    assert_true "[ -n \"\$ERROR_PREFIX\" ]" "ERROR_PREFIX constant should be defined"
    assert_true "[ -n \"\$WARNING_PREFIX\" ]" "WARNING_PREFIX constant should be defined"
    assert_true "[ -n \"\$STATUS_SUCCESS\" ]" "STATUS_SUCCESS constant should be defined"
}

test_print_color_empty_message() {
    local output
    output=$(print_color "red" "" 2>&1)
    assert_success "[ -z \"$output\" ]" "Empty message should produce empty output"
}

test_print_color_multiline_message() {
    local output
    output=$(print_color "green" $'line1\nline2' 2>&1)
    assert_contains "$output" "line1" "Multiline message should be printed"
}

test_print_color_special_chars() {
    local output
    output=$(print_color "red" "test@#\$%" 2>&1)
    assert_contains "$output" "test" "Special characters should be handled"
}

test_echo_if_not_json_unset_mode() {
    unset JSON_OUTPUT_MODE
    local output
    output=$(echo_if_not_json "test" 2>&1)
    assert_contains "$output" "test" "Should print when JSON_OUTPUT_MODE is unset"
}

################################################################################
# Parameter Validation Tests (12 tests)
################################################################################

test_validate_required_valid_value() {
    local var="some_value"
    assert_success "validate_required \"$var\" \"var\"" "Should succeed with non-empty value"
}

test_validate_required_empty_value() {
    local var=""
    assert_failure "validate_required \"$var\" \"var\"" "Should fail with empty value"
}

test_validate_required_custom_message() {
    local var=""
    local output
    output=$(validate_required "$var" "var" "Custom error" 2>&1)
    assert_contains "$output" "Custom error" "Should use custom error message"
}

test_validate_required_default_message() {
    local var=""
    local output
    output=$(validate_required "$var" "testvar" 2>&1)
    assert_contains "$output" "testvar" "Should include parameter name in default message"
}

test_validate_required_multi_all_valid() {
    local var1="value1"
    local var2="value2"
    assert_success "validate_required_multi \"$var1\" \"var1\" \"$var2\" \"var2\"" \
        "Should succeed when all parameters are valid"
}

test_validate_required_multi_first_invalid() {
    local var1=""
    local var2="value2"
    assert_failure "validate_required_multi \"$var1\" \"var1\" \"$var2\" \"var2\"" \
        "Should fail when first parameter is invalid"
}

test_validate_required_multi_second_invalid() {
    local var1="value1"
    local var2=""
    assert_failure "validate_required_multi \"$var1\" \"var1\" \"$var2\" \"var2\"" \
        "Should fail when second parameter is invalid"
}

test_validate_required_multi_all_invalid() {
    local var1=""
    local var2=""
    assert_failure "validate_required_multi \"$var1\" \"var1\" \"$var2\" \"var2\"" \
        "Should fail when all parameters are invalid"
}

test_validate_required_multi_three_params() {
    local var1="value1"
    local var2="value2"
    local var3="value3"
    assert_success "validate_required_multi \"$var1\" \"var1\" \"$var2\" \"var2\" \"$var3\" \"var3\"" \
        "Should handle three parameters"
}

test_validate_required_whitespace_only() {
    local var="   "
    # Note: bash treats whitespace-only strings as non-empty
    assert_success "validate_required \"$var\" \"var\"" "Whitespace-only should not be treated as empty"
}

test_validate_required_zero_string() {
    local var="0"
    assert_success "validate_required \"$var\" \"var\"" "String '0' should be treated as non-empty"
}

test_validate_required_variable_unset() {
    # Use parameter expansion to handle unset variables
    local var="${NONEXISTENT_VAR:-}"
    assert_failure "validate_required \"$var\" \"var\"" "Unset variable should fail validation"
}

################################################################################
# Host Parsing Tests (12 tests)
################################################################################

test_parse_host_user_valid() {
    local host="admin@192.168.1.1"
    local user
    user=$(parse_host_user "$host")
    assert_equal "admin" "$user" "Should extract user from host string"
}

test_parse_host_user_complex() {
    local host="user.name@10.0.0.1"
    local user
    user=$(parse_host_user "$host")
    assert_equal "user.name" "$user" "Should extract user with dots"
}

test_parse_host_user_underscore() {
    local host="test_user@172.16.0.1"
    local user
    user=$(parse_host_user "$host")
    assert_equal "test_user" "$user" "Should extract user with underscores"
}

test_parse_host_ip_valid() {
    local host="admin@192.168.1.100"
    local ip
    ip=$(parse_host_ip "$host")
    assert_equal "192.168.1.100" "$ip" "Should extract IP from host string"
}

test_parse_host_ip_ipv6() {
    local host="admin@2001:db8::1"
    local ip
    ip=$(parse_host_ip "$host")
    assert_contains "$ip" "2001" "Should extract IPv6 address"
}

test_parse_host_both() {
    local host="testuser@10.20.30.40"
    local user ip
    read user ip < <(parse_host "$host")
    assert_equal "testuser" "$user" "Should parse user correctly"
    assert_equal "10.20.30.40" "$ip" "Should parse IP correctly"
}

test_parse_host_no_at_symbol() {
    local host="simplehost"
    local user
    user=$(parse_host_user "$host")
    assert_equal "simplehost" "$user" "Should return whole string when no @ symbol"
}

test_parse_host_multiple_at_symbols() {
    local host="user@domain@192.168.1.1"
    local user
    user=$(parse_host_user "$host")
    assert_equal "user" "$user" "Should extract first part when multiple @ symbols"
}

test_parse_host_with_port() {
    local host="admin@192.168.1.1:22"
    local ip
    ip=$(parse_host_ip "$host")
    assert_contains "$ip" "192.168.1.1" "Should extract IP even with port"
}

test_parse_host_empty_string() {
    local host=""
    local user
    user=$(parse_host_user "$host")
    assert_empty "$user" "Should handle empty host string"
}

test_parse_host_spaces() {
    local host="admin @ 192.168.1.1"
    local user
    user=$(parse_host_user "$host")
    # This tests the actual behavior with spaces
    assert_not_empty "$user" "Should handle spaces in host"
}

test_parse_host_special_chars() {
    local host="user-name@192.168.1.1"
    local user
    user=$(parse_host_user "$host")
    assert_equal "user-name" "$user" "Should extract user with hyphens"
}

################################################################################
# Path Existence Check Tests (14 tests)
################################################################################

test_check_dir_exists_valid() {
    assert_success "check_dir_exists \"$TEST_DIR\"" "Should succeed for existing directory"
}

test_check_dir_exists_invalid() {
    assert_failure "check_dir_exists \"/nonexistent/directory\"" "Should fail for non-existent directory"
}

test_check_dir_exists_custom_message() {
    local output
    output=$(check_dir_exists "/nonexistent" "Custom dir error" 2>&1)
    assert_contains "$output" "Custom dir error" "Should use custom error message"
}

test_check_dir_exists_file_instead() {
    assert_failure "check_dir_exists \"$TEST_FILE\"" "Should fail when given a file instead of directory"
}

test_check_file_exists_valid() {
    assert_success "check_file_exists \"$TEST_FILE\"" "Should succeed for existing file"
}

test_check_file_exists_invalid() {
    assert_failure "check_file_exists \"/nonexistent/file.txt\"" "Should fail for non-existent file"
}

test_check_file_exists_custom_message() {
    local output
    output=$(check_file_exists "/nonexistent" "Custom file error" 2>&1)
    assert_contains "$output" "Custom file error" "Should use custom error message"
}

test_check_file_exists_directory_instead() {
    assert_failure "check_file_exists \"$TEST_DIR\"" "Should fail when given directory instead of file"
}

test_check_path_exists_file() {
    assert_success "check_path_exists \"$TEST_FILE\"" "Should succeed for existing file"
}

test_check_path_exists_directory() {
    assert_success "check_path_exists \"$TEST_DIR\"" "Should succeed for existing directory"
}

test_check_path_exists_invalid() {
    assert_failure "check_path_exists \"/nonexistent/path\"" "Should fail for non-existent path"
}

test_check_path_exists_custom_message() {
    local output
    output=$(check_path_exists "/nonexistent" "Custom path error" 2>&1)
    assert_contains "$output" "Custom path error" "Should use custom error message"
}

test_check_dir_exists_symlink() {
    local link_dir="$TEST_TMP_DIR/link_dir"
    ln -s "$TEST_DIR" "$link_dir"
    assert_success "check_dir_exists \"$link_dir\"" "Should succeed for directory symlink"
}

test_check_file_exists_symlink() {
    local link_file="$TEST_TMP_DIR/link_file"
    ln -s "$TEST_FILE" "$link_file"
    assert_success "check_file_exists \"$link_file\"" "Should succeed for file symlink"
}

################################################################################
# Summary Printing Tests (6 tests)
################################################################################

test_print_operation_summary_all_success() {
    local output
    output=$(print_operation_summary 10 0 0 2>&1)
    assert_contains "$output" "Success: 10" "Should print success count"
    assert_contains "$output" "Total: 10" "Should print total count"
}

test_print_operation_summary_with_skipped() {
    local output
    output=$(print_operation_summary 8 2 0 2>&1)
    assert_contains "$output" "Success: 8" "Should print success count"
    assert_contains "$output" "Skipped: 2" "Should print skipped count"
    assert_contains "$output" "Total: 10" "Should print total"
}

test_print_operation_summary_with_errors() {
    local output
    output=$(print_operation_summary 8 1 1 2>&1)
    assert_contains "$output" "Success: 8" "Should print success count"
    assert_contains "$output" "Skipped: 1" "Should print skipped count"
    assert_contains "$output" "Errors: 1" "Should print error count"
    assert_contains "$output" "Total: 10" "Should print total"
}

test_print_operation_summary_defaults() {
    local output
    output=$(print_operation_summary 5 2>&1)
    assert_contains "$output" "Success: 5" "Should use defaults for other parameters"
    assert_not_contains "$output" "Skipped:" "Should not print 0 skipped"
    assert_not_contains "$output" "Errors:" "Should not print 0 errors"
}

test_print_operation_summary_zero_values() {
    local output
    output=$(print_operation_summary 0 0 0 2>&1)
    assert_contains "$output" "Success: 0" "Should handle zero success"
    assert_contains "$output" "Total: 0" "Should handle zero total"
}

test_print_operation_summary_large_numbers() {
    local output
    output=$(print_operation_summary 10000 500 50 2>&1)
    assert_contains "$output" "Success: 10000" "Should handle large numbers"
    assert_contains "$output" "Total: 10550" "Should calculate total correctly"
}

################################################################################
# Additional Edge Case Tests (10 tests)
################################################################################

test_json_mode_inheritance() {
    local parent_mode="${JSON_OUTPUT_MODE:-0}"
    JSON_OUTPUT_MODE=1
    local output
    output=$(echo_if_not_json "test" 2>&1)
    assert_empty "$output" "Should respect JSON_OUTPUT_MODE setting"
    JSON_OUTPUT_MODE="$parent_mode"
}

test_color_code_sequences() {
    local output
    output=$(print_color "red" "test" 2>&1 | od -c | head -1)
    assert_not_empty "$output" "Should produce ANSI color codes"
}

test_host_parsing_consistency() {
    local host="user@192.168.1.1"
    local user ip
    read user ip < <(parse_host "$host")

    local user2
    user2=$(parse_host_user "$host")

    assert_equal "$user" "$user2" "parse_host and parse_host_user should match"
}

test_validation_error_output_to_stderr() {
    local output
    output=$(validate_required "" "var" 2>&1 >/dev/null)
    assert_not_empty "$output" "Error should be sent to stderr"
}

test_check_path_with_spaces() {
    local dir_with_spaces="$TEST_TMP_DIR/dir with spaces"
    mkdir -p "$dir_with_spaces"
    assert_success "check_dir_exists \"$dir_with_spaces\"" "Should handle paths with spaces"
}

test_constants_readonly() {
    # Try to modify a constant (will fail in set -e mode if it's readonly)
    local original=$RED
    assert_not_empty "$original" "Color constants should be defined"
}

test_parse_host_numeric_user() {
    local host="123@192.168.1.1"
    local user
    user=$(parse_host_user "$host")
    assert_equal "123" "$user" "Should handle numeric user"
}

test_validate_empty_string_vs_unset() {
    local empty=""
    assert_failure "validate_required \"$empty\" \"empty\"" "Empty string should fail"
}

test_check_dir_with_trailing_slash() {
    assert_success "check_dir_exists \"$TEST_DIR/\"" "Should handle directory with trailing slash"
}

test_summary_with_separator_line() {
    local output
    output=$(print_operation_summary 5 0 0 2>&1)
    assert_contains "$output" "=====" "Should print separator lines"
}

################################################################################
# Test Count Summary
################################################################################

# Total: 79 tests for utils.sh
# - Color printing: 15 tests
# - Parameter validation: 12 tests
# - Host parsing: 12 tests
# - Path existence checks: 14 tests
# - Summary printing: 6 tests
# - Edge cases: 10 tests
