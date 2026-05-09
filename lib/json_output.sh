#!/usr/bin/env bash
# json_output.sh - JSON output formatting for CLI commands

set -euo pipefail
# Provides structured JSON output for web UI consumption

# Global flag to enable JSON output mode
JSON_OUTPUT_MODE="${JSON_OUTPUT_MODE:-0}"

# JSON output buffer for structured data
declare -A JSON_DEPLOY_DATA
declare -A JSON_DIAGNOSE_DATA

# Initialize JSON deploy output structure
init_json_deploy_output() {
    JSON_DEPLOY_DATA=(
        [service]=""
        [machine]=""
        [overall_status]="in_progress"
        [timestamp]=""
        [phases]=""
    )
}

# Initialize JSON diagnose output structure
init_json_diagnose_output() {
    JSON_DIAGNOSE_DATA=(
        [service]=""
        [machine]=""
        [timestamp]=""
        [observations]=""
        [problems]=""
        [solutions]=""
    )
}

# Escape JSON string (basic escaping for quotes and backslashes)
json_escape() {
    local string="$1"
    # Escape backslashes first, then quotes
    printf '%s' "$string" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g'
}

# Build JSON array from items
# Usage: json_array "item1" "item2" "item3"
json_array() {
    local items=("$@")
    local result="["
    local first=1

    for item in "${items[@]}"; do
        if [ $first -eq 0 ]; then
            result="$result,"
        fi
        first=0
        result="$result\"$(json_escape "$item")\""
    done

    result="$result]"
    echo "$result"
}

# Build JSON object from key-value pairs
# Usage: json_object "key1" "value1" "key2" "value2"
json_object() {
    local args=("$@")
    local result="{"
    local first=1

    for ((i=1; i<=${#args[@]}; i+=2)); do
        local key="${args[$i]}"
        local value="${args[$((i+1))]}"

        if [ $first -eq 0 ]; then
            result="$result,"
        fi
        first=0

        # Check if value looks like a number, boolean, null, array, or object
        if [[ "$value" =~ ^[0-9]+$ ]] || \
           [[ "$value" =~ ^[0-9]+\.[0-9]+$ ]] || \
           [ "$value" = "true" ] || [ "$value" = "false" ] || \
           [ "$value" = "null" ] || \
           [[ "$value" =~ ^\[.*\]$ ]] || \
           [[ "$value" =~ ^\{.*\}$ ]]; then
            result="$result\"$key\":$value"
        else
            result="$result\"$key\":\"$(json_escape "$value")\""
        fi
    done

    result="$result}"
    echo "$result"
}

# Add phase to deploy output
# Usage: json_add_deploy_phase "observe" "completed" 1234 '{"key":"value"}'
json_add_deploy_phase() {
    local phase_name="$1"
    local phase_status="$2"
    local duration_ms="$3"
    local details="$4"

    local phase_obj
    phase_obj=$(json_object \
        "name" "$phase_name" \
        "status" "$phase_status" \
        "duration_ms" "$duration_ms" \
        "details" "$details")

    # Append to phases array
    if [ ! "${JSON_DEPLOY_DATA[phases]+_}" ] || [ -z "${JSON_DEPLOY_DATA[phases]}" ]; then
        JSON_DEPLOY_DATA[phases]="$phase_obj"
    else
        JSON_DEPLOY_DATA[phases]="${JSON_DEPLOY_DATA[phases]},$phase_obj"
    fi
}

# Set deploy output status
json_set_deploy_status() {
    JSON_DEPLOY_DATA[overall_status]="$1"
}

# Add observation to diagnose output
# Usage: json_add_observation "type" "status" "details"
json_add_observation() {
    local obs_type="$1"
    local obs_status="$2"
    local details="$3"

    local obs_obj
    obs_obj=$(json_object \
        "type" "$obs_type" \
        "status" "$obs_status" \
        "details" "$details")

    # Append to observations array
    if [ ! "${JSON_DIAGNOSE_DATA[observations]+_}" ] || [ -z "${JSON_DIAGNOSE_DATA[observations]}" ]; then
        JSON_DIAGNOSE_DATA[observations]="$obs_obj"
    else
        JSON_DIAGNOSE_DATA[observations]="${JSON_DIAGNOSE_DATA[observations]},$obs_obj"
    fi
}

# Add problem to diagnose output
# Usage: json_add_problem "id" "severity" "description"
json_add_problem() {
    local problem_id="$1"
    local severity="$2"
    local description="$3"

    local prob_obj
    prob_obj=$(json_object \
        "id" "$problem_id" \
        "severity" "$severity" \
        "description" "$description")

    # Append to problems array
    if [ ! "${JSON_DIAGNOSE_DATA[problems]+_}" ] || [ -z "${JSON_DIAGNOSE_DATA[problems]}" ]; then
        JSON_DIAGNOSE_DATA[problems]="$prob_obj"
    else
        JSON_DIAGNOSE_DATA[problems]="${JSON_DIAGNOSE_DATA[problems]},$prob_obj"
    fi
}

# Add solution to diagnose output
# Usage: json_add_solution "id" "problem_id" '["step1","step2"]'
json_add_solution() {
    local solution_id="$1"
    local problem_id="$2"
    local steps="$3"

    local sol_obj
    sol_obj=$(json_object \
        "id" "$solution_id" \
        "problem_id" "$problem_id" \
        "steps" "$steps")

    # Append to solutions array
    if [ ! "${JSON_DIAGNOSE_DATA[solutions]+_}" ] || [ -z "${JSON_DIAGNOSE_DATA[solutions]}" ]; then
        JSON_DIAGNOSE_DATA[solutions]="$sol_obj"
    else
        JSON_DIAGNOSE_DATA[solutions]="${JSON_DIAGNOSE_DATA[solutions]},$sol_obj"
    fi
}

# Output final JSON for deploy command
output_json_deploy() {
    local service="${JSON_DEPLOY_DATA[service]}"
    local machine="${JSON_DEPLOY_DATA[machine]}"
    local overall_status="${JSON_DEPLOY_DATA[overall_status]}"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local phases="${JSON_DEPLOY_DATA[phases]}"

    # Build final JSON
    cat <<EOF
{
  "service": "$service",
  "machine": "$machine",
  "phases": [$phases],
  "overall_status": "$overall_status",
  "timestamp": "$timestamp"
}
EOF
}

# Output final JSON for diagnose command
output_json_diagnose() {
    local service="${JSON_DIAGNOSE_DATA[service]}"
    local machine="${JSON_DIAGNOSE_DATA[machine]}"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local observations="${JSON_DIAGNOSE_DATA[observations]}"
    local problems="${JSON_DIAGNOSE_DATA[problems]}"
    local solutions="${JSON_DIAGNOSE_DATA[solutions]}"

    # Build final JSON
    cat <<EOF
{
  "service": "$service",
  "machine": "$machine",
  "observations": [$observations],
  "problems": [$problems],
  "solutions": [$solutions],
  "timestamp": "$timestamp"
}
EOF
}

# Check if JSON output mode is enabled
is_json_output_mode() {
    [ "$JSON_OUTPUT_MODE" = "1" ]
}

# Print message only if NOT in JSON mode
json_print() {
    if ! is_json_output_mode; then
        echo "$@"
    fi
}

# Print colored message only if NOT in JSON mode
json_print_color() {
    if ! is_json_output_mode; then
        print_color "$@"
    fi
}

# Wrapper for observe_print that respects JSON mode
observe_print_json_safe() {
    if ! is_json_output_mode; then
        observe_print "$@"
    fi
}

# Wrapper for diagnose_print that respects JSON mode
diagnose_print_json_safe() {
    if ! is_json_output_mode; then
        diagnose_print "$@"
    fi
}

# Wrapper for solve_print that respects JSON mode
solve_print_json_safe() {
    if ! is_json_output_mode; then
        solve_print "$@"
    fi
}

# Wrapper for learn_print that respects JSON mode
learn_print_json_safe() {
    if ! is_json_output_mode; then
        learn_print "$@"
    fi
}
