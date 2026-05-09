#!/usr/bin/env bash
# solver.sh - GET TO SOLUTION
# Apply solution patterns to fix identified problems
# Part of Toyota Engagement Equation implementation

set -euo pipefail

# Get script directory
SOLVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERNS_DIR="$SOLVER_DIR/patterns"

# Solutions storage
SOLUTIONS_DIR="${SOLUTIONS_DIR:-$HOME/.portoser/solutions}"
mkdir -p "$SOLUTIONS_DIR"

# Color codes — `[[ -v VAR ]]` works regardless of whether the var was set
# as readonly by utils.sh or left unset on a minimal load path.
[[ -v BLUE   ]] || BLUE='\033[0;34m'
[[ -v YELLOW ]] || YELLOW='\033[1;33m'
[[ -v GREEN  ]] || GREEN='\033[0;32m'
[[ -v RED    ]] || RED='\033[0;31m'
[[ -v NC     ]] || NC='\033[0m'
# CYAN isn't defined by utils.sh; declare it unconditionally.
[[ -v CYAN   ]] || CYAN='\033[0;36m'

# Solution results
declare -A SOLUTION_RESULTS
declare -A SOLUTION_ACTIONS

# Print solver message
solve_print() {
    local level="$1"
    shift
    case "$level" in
        INFO)
            echo -e "${CYAN}🔧 $*${NC}" >&2
            ;;
        SUCCESS)
            echo -e "${GREEN}   ✓ $*${NC}" >&2
            ;;
        FAILED)
            echo -e "${RED}   ✗ $*${NC}" >&2
            ;;
        ACTION)
            echo -e "${BLUE}   → $*${NC}" >&2
            ;;
        WARNING)
            echo -e "${YELLOW}   ⚠ $*${NC}" >&2
            ;;
    esac
}

# Record solution attempt
# Usage: record_solution FINGERPRINT STATUS ACTIONS_TAKEN
record_solution() {
    local fingerprint="$1"
    local solution_status="$2"       # SUCCESS, FAILED, PARTIAL
    local actions="$3"      # Description of actions taken

    SOLUTION_RESULTS[$fingerprint]="$solution_status"
    SOLUTION_ACTIONS[$fingerprint]="$actions"

    # Log to history
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp|$fingerprint|$solution_status|$actions" >> "$SOLUTIONS_DIR/solutions.log"
}

# Load and execute solution pattern
# Usage: execute_solution_pattern PATTERN_NAME PROBLEM_DATA
execute_solution_pattern() {
    local pattern_name="$1"
    local problem_data="$2"
    local pattern_file="$PATTERNS_DIR/${pattern_name}.sh"

    if [ ! -f "$pattern_file" ]; then
        solve_print WARNING "Solution pattern not found: $pattern_name"
        return 1
    fi

    solve_print INFO "Applying solution pattern: $pattern_name"

    # Source the pattern (it will have a solve_* function)
    # shellcheck source=/dev/null
    source "$pattern_file"

    # Execute the pattern's solve function
    local solve_function="solve_${pattern_name}"
    if typeset -f "$solve_function" > /dev/null; then
        if $solve_function "$problem_data"; then
            solve_print SUCCESS "Solution applied successfully"
            return 0
        else
            solve_print FAILED "Solution failed to resolve problem"
            return 1
        fi
    else
        solve_print WARNING "Solution function not found: $solve_function"
        return 1
    fi
}

# Attempt to solve a single problem
# Usage: solve_problem FINGERPRINT
solve_problem() {
    local fingerprint="$1"
    local problem_data
    problem_data=$(get_problem_details "$fingerprint")

    if [ -z "$problem_data" ]; then
        solve_print WARNING "No problem data for: $fingerprint"
        return 1
    fi

    # Get recommended solution pattern
    local pattern
    pattern=$(get_solution_pattern "$fingerprint")

    if [ "$pattern" = "unknown" ]; then
        solve_print WARNING "No solution pattern available for: $fingerprint"
        record_solution "$fingerprint" "FAILED" "No solution pattern available"
        return 1
    fi

    solve_print INFO "Problem: $fingerprint"

    # Execute solution pattern
    if execute_solution_pattern "$pattern" "$problem_data"; then
        record_solution "$fingerprint" "SUCCESS" "Applied pattern: $pattern"
        return 0
    else
        record_solution "$fingerprint" "FAILED" "Pattern failed: $pattern"
        return 1
    fi
}

# Solve all identified problems
# Usage: solve_all_problems [--auto-heal]
solve_all_problems() {
    local auto_heal=0
    if [ "$1" = "--auto-heal" ]; then
        auto_heal=1
    fi

    local problems
    problems=$(get_identified_problems)

    if [ -z "$problems" ]; then
        solve_print INFO "No problems to solve"
        return 0
    fi

    local problem_count
    problem_count=$(echo "$problems" | wc -w | tr -d ' ')

    if [ $auto_heal -eq 1 ]; then
        solve_print INFO "Auto-healing enabled: Attempting to resolve $problem_count problem(s)..."
    else
        solve_print INFO "Found $problem_count problem(s). Would you like to attempt auto-healing?"
        return 1
    fi

    echo ""

    local solved=0
    local failed=0
    local problem_num=0

    for fingerprint in $problems; do
        ((problem_num++))
        echo ""
        solve_print INFO "[$problem_num/$problem_count] Solving: $fingerprint"

        if solve_problem "$fingerprint"; then
            ((solved++))
        else
            ((failed++))
        fi
    done

    echo ""
    solve_print INFO "Auto-healing complete: ${GREEN}$solved solved${NC}, ${RED}$failed failed${NC}"

    if [ $failed -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

# Get solution summary
# Usage: get_solution_summary
get_solution_summary() {
    local total=${#SOLUTION_RESULTS[@]}
    local success=0
    local failed=0

    for fingerprint in "${!SOLUTION_RESULTS[@]}"; do
        local solution_status="${SOLUTION_RESULTS[$fingerprint]}"
        if [ "$solution_status" = "SUCCESS" ]; then
            ((success++))
        else
            ((failed++))
        fi
    done

    echo "Total: $total | Success: $success | Failed: $failed"
}

# Generate solution report
# Usage: generate_solution_report SERVICE TARGET_MACHINE
generate_solution_report() {
    local service="$1"
    local target_machine="$2"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local report_file
    report_file="$SOLUTIONS_DIR/${service}_${target_machine}_$(date +%s).md"

    cat > "$report_file" <<EOF
# Solution Report

**Service:** $service
**Target Machine:** $target_machine
**Timestamp:** $timestamp

## Solutions Applied

EOF

    if [ ${#SOLUTION_RESULTS[@]} -eq 0 ]; then
        echo "No solutions were applied." >> "$report_file"
    else
        for fingerprint in "${!SOLUTION_RESULTS[@]}"; do
            local solution_status="${SOLUTION_RESULTS[$fingerprint]}"
            local actions="${SOLUTION_ACTIONS[$fingerprint]}"

            {
                echo "### $fingerprint"
                echo ""
                echo "**Status:** $solution_status"
                echo "**Actions:** $actions"
                echo ""
            } >> "$report_file"
        done
    fi

    cat >> "$report_file" <<EOF

## Summary

$(get_solution_summary)

---
*Generated by Portoser Solution Engine*
EOF

    echo "$report_file"
}

# Verify solutions worked (re-observe)
# Usage: verify_solutions SERVICE TARGET_MACHINE
verify_solutions() {
    local service="$1"
    local target_machine="$2"

    solve_print INFO "Verifying solutions..."
    echo ""

    # Re-run observations to check if problems are resolved
    # Clear previous observations (these arrays live in observer.sh / analyzer.sh).
    # shellcheck disable=SC2034 # cleared here, populated by sourced observer.sh
    OBSERVATION_RESULTS=()
    # shellcheck disable=SC2034 # cleared here, populated by sourced analyzer.sh
    IDENTIFIED_PROBLEMS=()
    # shellcheck disable=SC2034 # cleared here, populated by sourced analyzer.sh
    ROOT_CAUSES=()

    # Re-observe
    observe_deployment_readiness "$service" "$target_machine" >/dev/null 2>&1

    # Re-analyze
    analyze_observations >/dev/null 2>&1

    # Check if any problems remain
    local remaining
    remaining=$(get_identified_problems)
    if [ -z "$remaining" ]; then
        solve_print SUCCESS "All problems resolved!"
        return 0
    else
        local count
        count=$(echo "$remaining" | wc -w | tr -d ' ')
        solve_print WARNING "$count problem(s) still remain"
        return 1
    fi
}
