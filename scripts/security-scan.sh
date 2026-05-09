#!/usr/bin/env bash
# security-scan.sh - Security vulnerability scanner for portoser
#
# Scans the codebase for common security vulnerabilities including:
# - Command injection vulnerabilities
# - Unsafe variable expansion
# - Unquoted variables in dangerous contexts
# - Use of eval and similar dangerous constructs
# - Hard-coded credentials
# - Insecure file permissions
#
# Usage: ./scripts/security-scan.sh [--fix] [--verbose] [directory]
#
# Options:
#   --fix      Attempt to automatically fix some issues
#   --verbose  Show detailed output for all checks
#   directory  Directory to scan (default: current directory)
#
# Exit codes:
#   0 - No issues found
#   1 - Issues found
#   2 - Usage error

set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Default options
FIX_MODE=false
VERBOSE=false
SCAN_DIR="${1:-.}"

# Issue counters
CRITICAL_COUNT=0
HIGH_COUNT=0
MEDIUM_COUNT=0
LOW_COUNT=0
INFO_COUNT=0

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fix)
                FIX_MODE=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                if [[ -d "$1" ]]; then
                    SCAN_DIR="$1"
                    shift
                else
                    echo "Error: '$1' is not a valid directory" >&2
                    exit 2
                fi
                ;;
        esac
    done
}

show_help() {
    cat << EOF
Security Scanner for Portoser

Usage: $0 [OPTIONS] [DIRECTORY]

Options:
  --fix       Attempt to automatically fix some issues
  --verbose   Show detailed output for all checks
  --help, -h  Show this help message

Arguments:
  DIRECTORY   Directory to scan (default: current directory)

Examples:
  $0                    # Scan current directory
  $0 --verbose lib/     # Scan lib/ directory with verbose output
  $0 --fix .            # Scan and attempt to fix issues

Exit Codes:
  0 - No issues found
  1 - Issues found
  2 - Usage error
EOF
}

# Print colored message
print_color() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${NC}"
}

# Report an issue
report_issue() {
    local severity="$1"  # CRITICAL, HIGH, MEDIUM, LOW, INFO
    local file="$2"
    local line="$3"
    local message="$4"
    local code="${5:-}"

    case "$severity" in
        CRITICAL)
            print_color "$RED" "[CRITICAL] $file:$line - $message"
            ((CRITICAL_COUNT++))
            ;;
        HIGH)
            print_color "$RED" "[HIGH] $file:$line - $message"
            ((HIGH_COUNT++))
            ;;
        MEDIUM)
            print_color "$YELLOW" "[MEDIUM] $file:$line - $message"
            ((MEDIUM_COUNT++))
            ;;
        LOW)
            print_color "$YELLOW" "[LOW] $file:$line - $message"
            ((LOW_COUNT++))
            ;;
        INFO)
            if [[ "$VERBOSE" == "true" ]]; then
                print_color "$BLUE" "[INFO] $file:$line - $message"
            fi
            ((INFO_COUNT++))
            ;;
    esac

    if [[ -n "$code" && "$VERBOSE" == "true" ]]; then
        echo "  Code: $code"
    fi
}

# Check for command injection vulnerabilities
check_command_injection() {
    print_color "$BLUE" "\n=== Checking for Command Injection Vulnerabilities ==="

    # Pattern 1: Unquoted variables in command execution contexts
    while IFS=: read -r file line code; do
        if [[ -n "$file" ]]; then
            report_issue "HIGH" "$file" "$line" "Unquoted variable in command execution" "$code"
        fi
    done < <(grep -rn --include="*.sh" -E '\$\([^"]*\$[A-Za-z_][A-Za-z0-9_]*[^"]*\)' "$SCAN_DIR" 2>/dev/null || true)

    # Pattern 2: eval usage (dangerous!)
    while IFS=: read -r file line code; do
        if [[ -n "$file" ]]; then
            report_issue "CRITICAL" "$file" "$line" "Use of 'eval' - extremely dangerous!" "$code"
        fi
    done < <(grep -rn --include="*.sh" -E '\beval\s+' "$SCAN_DIR" 2>/dev/null || true)

    # Pattern 3: Unquoted SSH command arguments
    while IFS=: read -r file line code; do
        if [[ -n "$file" ]]; then
            # Check if the line doesn't have proper quoting or -- separator
            if ! echo "$code" | grep -q '\-\-\s*bash' && ! echo "$code" | grep -q 'bash -c '\'''; then
                report_issue "HIGH" "$file" "$line" "Potentially unsafe SSH command execution" "$code"
            fi
        fi
    done < <(grep -rn --include="*.sh" -E 'ssh\s+.*"[^"]*\$' "$SCAN_DIR" 2>/dev/null || true)

    # Pattern 4: Command substitution in double quotes
    while IFS=: read -r file line code; do
        if [[ -n "$file" ]]; then
            report_issue "MEDIUM" "$file" "$line" "Command substitution in double quotes may allow injection" "$code"
        fi
    done < <(grep -rn --include="*.sh" -E '"[^"]*\$\([^)]+\)[^"]*"' "$SCAN_DIR" 2>/dev/null || true)

    # Pattern 5: Dangerous characters in user input
    while IFS=: read -r file line code; do
        if [[ -n "$file" ]]; then
            if echo "$code" | grep -qE '\$[A-Za-z_][A-Za-z0-9_]*.*[\;\|\&\`]'; then
                report_issue "HIGH" "$file" "$line" "Variable used with dangerous shell metacharacters" "$code"
            fi
        fi
    done < <(grep -rn --include="*.sh" -E 'ssh.*\$[A-Za-z_]' "$SCAN_DIR" 2>/dev/null || true)
}

# Check for unvalidated input
check_unvalidated_input() {
    print_color "$BLUE" "\n=== Checking for Unvalidated Input ==="

    # Check for functions that accept user input but don't validate
    while IFS=: read -r file line code; do
        if [[ -n "$file" ]]; then
            # Check if there's a validate_ call within next 10 lines
            local start_line
            start_line=$((line))
            local end_line
            end_line=$((line + 10))
            local has_validation=false

            if sed -n "${start_line},${end_line}p" "$file" 2>/dev/null | grep -q 'validate_'; then
                has_validation=true
            fi

            if [[ "$has_validation" == "false" ]]; then
                report_issue "MEDIUM" "$file" "$line" "Function parameter may be unvalidated" "$code"
            fi
        fi
    done < <(grep -rn --include="*.sh" -E '^\s*local\s+[a-z_]+="?\$[1-9]"?' "$SCAN_DIR" 2>/dev/null | head -20 || true)
}

# Check for hardcoded credentials
check_hardcoded_credentials() {
    print_color "$BLUE" "\n=== Checking for Hardcoded Credentials ==="

    # Pattern 1: Hardcoded passwords
    while IFS=: read -r file line code; do
        if [[ -n "$file" ]]; then
            # Exclude comments and known false positives
            if ! echo "$code" | grep -q '^\s*#'; then
                report_issue "CRITICAL" "$file" "$line" "Possible hardcoded password" "$code"
            fi
        fi
    done < <(grep -rn --include="*.sh" --include="*.yml" --include="*.yaml" -iE '(password|passwd|pwd)\s*[=:]\s*["\047][^"\047]{3,}["\047]' "$SCAN_DIR" 2>/dev/null | grep -v 'DEPLOY_PI_PASSWORDS' || true)

    # Pattern 2: API keys and tokens
    while IFS=: read -r file line code; do
        if [[ -n "$file" ]]; then
            if ! echo "$code" | grep -q '^\s*#'; then
                report_issue "CRITICAL" "$file" "$line" "Possible API key or token" "$code"
            fi
        fi
    done < <(grep -rn --include="*.sh" --include="*.yml" --include="*.yaml" -iE '(api[_-]?key|api[_-]?token|access[_-]?token)\s*[=:]\s*["\047][A-Za-z0-9+/=]{20,}["\047]' "$SCAN_DIR" 2>/dev/null || true)
}

# Check for insecure file operations
check_insecure_file_operations() {
    print_color "$BLUE" "\n=== Checking for Insecure File Operations ==="

    # Pattern 1: Temporary file creation without mktemp
    while IFS=: read -r file line code; do
        if [[ -n "$file" ]]; then
            if ! echo "$code" | grep -q 'mktemp'; then
                report_issue "MEDIUM" "$file" "$line" "Insecure temporary file creation" "$code"
            fi
        fi
    done < <(grep -rn --include="*.sh" -E '/tmp/[a-z_-]+\.' "$SCAN_DIR" 2>/dev/null | grep -v mktemp || true)

    # Pattern 2: World-writable files
    while IFS=: read -r file line code; do
        if [[ -n "$file" ]]; then
            report_issue "HIGH" "$file" "$line" "Creating world-writable file" "$code"
        fi
    done < <(grep -rn --include="*.sh" -E 'chmod\s+(0?777|0?[0-7]?[2367][2367])' "$SCAN_DIR" 2>/dev/null || true)

    # Pattern 3: Unsafe path traversal
    while IFS=: read -r file line code; do
        if [[ -n "$file" ]]; then
            if echo "$code" | grep -qE '\$[A-Za-z_][A-Za-z0-9_]*/\.\./'; then
                report_issue "HIGH" "$file" "$line" "Possible path traversal vulnerability" "$code"
            fi
        fi
    done < <(grep -rn --include="*.sh" -E '\.\.[/\\]' "$SCAN_DIR" 2>/dev/null || true)
}

# Check for SQL injection (if database queries exist)
check_sql_injection() {
    print_color "$BLUE" "\n=== Checking for SQL Injection Vulnerabilities ==="

    # Check for string concatenation in SQL queries
    while IFS=: read -r file line code; do
        if [[ -n "$file" ]]; then
            if echo "$code" | grep -qE 'SELECT|INSERT|UPDATE|DELETE|WHERE' && echo "$code" | grep -qE '\$[A-Za-z_]'; then
                report_issue "CRITICAL" "$file" "$line" "Possible SQL injection - unsanitized variable in query" "$code"
            fi
        fi
    done < <(grep -rn --include="*.sh" --include="*.py" -iE '(SELECT|INSERT|UPDATE|DELETE).*\$' "$SCAN_DIR" 2>/dev/null || true)
}

# Check for unsafe shell options
check_shell_options() {
    print_color "$BLUE" "\n=== Checking Shell Safety Options ==="

    # Check for missing 'set -euo pipefail'
    while read -r file; do
        if ! grep -q 'set.*-.*e' "$file" 2>/dev/null; then
            report_issue "MEDIUM" "$file" "1" "Missing 'set -e' (exit on error)" ""
        fi
        if ! grep -q 'set.*-.*u' "$file" 2>/dev/null; then
            report_issue "LOW" "$file" "1" "Missing 'set -u' (exit on undefined variable)" ""
        fi
        if ! grep -q 'set.*-.*o pipefail' "$file" 2>/dev/null; then
            report_issue "LOW" "$file" "1" "Missing 'set -o pipefail' (catch pipeline errors)" ""
        fi
    done < <(find "$SCAN_DIR" -name "*.sh" -type f 2>/dev/null || true)
}

# Check for best practices
check_best_practices() {
    print_color "$BLUE" "\n=== Checking Security Best Practices ==="

    # Check for use of security validation library
    while read -r file; do
        # Skip the validation library itself
        if [[ "$file" == *"security_validation.sh" ]]; then
            continue
        fi

        # Check if file sources security_validation.sh
        if ! grep -q 'source.*security_validation\.sh' "$file" 2>/dev/null && \
           ! grep -q '\. .*security_validation\.sh' "$file" 2>/dev/null; then
            report_issue "INFO" "$file" "1" "File does not source security validation library" ""
        fi
    done < <(find "$SCAN_DIR" -name "*.sh" -type f ! -name "security_validation.sh" 2>/dev/null || true)
}

# Generate summary report
generate_summary() {
    print_color "$BLUE" "\n=== Security Scan Summary ==="
    echo "Directory scanned: $SCAN_DIR"
    echo ""

    local total_issues
    total_issues=$((CRITICAL_COUNT + HIGH_COUNT + MEDIUM_COUNT + LOW_COUNT))

    if [[ $total_issues -eq 0 ]]; then
        print_color "$GREEN" "✓ No security issues found!"
        return 0
    else
        echo "Issues found:"
        [[ $CRITICAL_COUNT -gt 0 ]] && print_color "$RED" "  Critical: $CRITICAL_COUNT"
        [[ $HIGH_COUNT -gt 0 ]] && print_color "$RED" "  High: $HIGH_COUNT"
        [[ $MEDIUM_COUNT -gt 0 ]] && print_color "$YELLOW" "  Medium: $MEDIUM_COUNT"
        [[ $LOW_COUNT -gt 0 ]] && print_color "$YELLOW" "  Low: $LOW_COUNT"
        [[ $VERBOSE == "true" && $INFO_COUNT -gt 0 ]] && print_color "$BLUE" "  Info: $INFO_COUNT"
        echo ""
        print_color "$RED" "✗ Total issues: $total_issues"
        echo ""
        echo "Recommendation: Review and fix issues, prioritizing CRITICAL and HIGH severity."
        return 1
    fi
}

# Main execution
main() {
    parse_args "$@"

    print_color "$GREEN" "=================================================="
    print_color "$GREEN" "  Portoser Security Scanner"
    print_color "$GREEN" "=================================================="
    echo "Scanning directory: $SCAN_DIR"
    echo "Fix mode: $FIX_MODE"
    echo "Verbose: $VERBOSE"
    echo ""

    # Run all checks
    check_command_injection
    check_unvalidated_input
    check_hardcoded_credentials
    check_insecure_file_operations
    check_sql_injection
    check_shell_options
    check_best_practices

    # Generate summary
    generate_summary
}

# Run main function
main "$@"
