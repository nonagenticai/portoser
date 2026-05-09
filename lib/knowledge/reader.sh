#!/usr/bin/env bash
# reader.sh - Knowledge Base Reader
# Functions for reading playbooks, insights, and statistics from the knowledge base
# Used by web UI and CLI commands

set -euo pipefail

# Knowledge base paths
KNOWLEDGE_BASE_DIR="${KNOWLEDGE_BASE_DIR:-$HOME/.portoser/knowledge}"
PLAYBOOKS_DIR="$KNOWLEDGE_BASE_DIR/playbooks"
PATTERNS_HISTORY_DIR="$KNOWLEDGE_BASE_DIR/patterns_history"
OBSERVATIONS_DIR="${OBSERVATIONS_DIR:-$HOME/.portoser/observations}"
DIAGNOSTICS_DIR="${DIAGNOSTICS_DIR:-$HOME/.portoser/diagnostics}"

# Ensure directories exist
mkdir -p "$KNOWLEDGE_BASE_DIR" "$PLAYBOOKS_DIR" "$PATTERNS_HISTORY_DIR" "$OBSERVATIONS_DIR" "$DIAGNOSTICS_DIR"

# Read all playbooks and return metadata
# Usage: read_playbooks [--json-output]
read_playbooks() {
    local json_output=0
    if [ "${1:-}" = "--json-output" ]; then
        json_output=1
    fi

    local playbooks=()
    local json_items=""
    local first=1

    # Check if playbooks directory exists
    if [ ! -d "$PLAYBOOKS_DIR" ]; then
        if [ "$json_output" -eq 1 ]; then
            echo '{"playbooks":[]}'
        else
            echo "No playbooks found"
        fi
        return 0
    fi

    # Use glob with nullglob to handle no matches
    shopt -s nullglob
    local playbook_files=("$PLAYBOOKS_DIR"/*.md)
    shopt -u nullglob

    if [ ${#playbook_files[@]} -eq 0 ]; then
        if [ "$json_output" -eq 1 ]; then
            echo '{"playbooks":[]}'
        else
            echo "No playbooks found"
        fi
        return 0
    fi

    for playbook_file in "${playbook_files[@]}"; do
        if [ ! -f "$playbook_file" ]; then
            continue
        fi

        local name
        name=$(basename "$playbook_file" .md)
        local description
        description=$(grep -A1 "^## Problem Description" "$playbook_file" | tail -1 | sed 's/^[[:space:]]*//')

        # Extract success rate from playbook
        local success_rate
        success_rate=$(grep "Success Rate:" "$playbook_file" | grep -o '[0-9]\+%' | sed 's/%//')
        [ -z "$success_rate" ] && success_rate="0"

        # Extract occurrence count
        local occurrences
        occurrences=$(grep "Occurrences:" "$playbook_file" | grep -o '[0-9]\+')
        [ -z "$occurrences" ] && occurrences="0"

        if [ "$json_output" -eq 1 ]; then
            if [ "$first" -eq 0 ]; then
                json_items="$json_items,"
            fi
            first=0
            json_items="$json_items{\"name\":\"$name\",\"description\":\"${description//\"/\\\"}\",\"success_rate\":$success_rate,\"occurrences\":$occurrences}"
        else
            playbooks+=("$name")
        fi
    done

    if [ "$json_output" -eq 1 ]; then
        echo "{\"playbooks\":[$json_items]}"
    else
        printf '%s\n' "${playbooks[@]}"
    fi
}

# Read specific playbook content
# Usage: read_playbook_content PLAYBOOK_NAME [--json-output]
read_playbook_content() {
    local playbook_name="$1"
    local json_output=0

    if [ "${2:-}" = "--json-output" ]; then
        json_output=1
    fi

    if [ -z "$playbook_name" ]; then
        if [ "$json_output" -eq 1 ]; then
            echo '{"error":"Playbook name required"}'
        else
            echo "Error: Playbook name required"
        fi
        return 1
    fi

    local playbook_file="$PLAYBOOKS_DIR/${playbook_name}.md"

    if [ ! -f "$playbook_file" ]; then
        if [ "$json_output" -eq 1 ]; then
            echo "{\"error\":\"Playbook not found: $playbook_name\"}"
        else
            echo "Error: Playbook not found: $playbook_name"
        fi
        return 1
    fi

    if [ "$json_output" -eq 1 ]; then
        # Extract metadata
        local description
        description=$(grep -A1 "^## Problem Description" "$playbook_file" | tail -1 | sed 's/^[[:space:]]*//' | sed 's/"/\\"/g')
        local occurrences
        occurrences=$(grep "Occurrences:" "$playbook_file" | grep -o '[0-9]\+')
        local success_rate
        success_rate=$(grep "Success Rate:" "$playbook_file" | grep -o '[0-9]\+%' | sed 's/%//')
        local solution_pattern
        # shellcheck disable=SC2016  # backticks here are literal markdown delimiters in the regex, not command substitution
        solution_pattern=$(grep "Solution Pattern:" "$playbook_file" | sed 's/.*`\(.*\)`.*/\1/')

        [ -z "$occurrences" ] && occurrences="0"
        [ -z "$success_rate" ] && success_rate="0"

        # Base64 encode the content to avoid escaping issues
        local content_base64
        content_base64=$(base64 < "$playbook_file")

        # Get related problems (similar problem types)
        local related_problems="[]"

        echo "{\"name\":\"$playbook_name\",\"description\":\"$description\",\"markdown_content_base64\":\"$content_base64\",\"stats\":{\"occurrences\":$occurrences,\"success_rate\":$success_rate,\"solution_pattern\":\"$solution_pattern\"},\"related_problems\":$related_problems}"
    else
        cat "$playbook_file"
    fi
}

# Get insights for a specific service
# Usage: get_service_insights SERVICE_NAME [--json-output]
get_service_insights() {
    local service="$1"
    local json_output=0

    if [ "${2:-}" = "--json-output" ]; then
        json_output=1
    fi

    if [ -z "$service" ]; then
        if [ "$json_output" -eq 1 ]; then
            echo '{"error":"Service name required"}'
        else
            echo "Error: Service name required"
        fi
        return 1
    fi

    local frequency_file="$KNOWLEDGE_BASE_DIR/problem_frequency.txt"

    # Calculate deployment count (from observations).
    # `grep -c` exits 1 with output "0" on no matches, so don't pipe it
    # through `|| echo`, which would double-emit and produce "0\n0".
    local deployment_count=0
    if [ -f "$frequency_file" ]; then
        local _dc
        _dc=$(grep -c "|$service|" "$frequency_file" 2>/dev/null) || _dc=0
        deployment_count=$_dc
    fi

    # Calculate average deployment time (from diagnostic reports)
    local avg_time="N/A"

    # Get common problems for this service.
    # The pipeline is wrapped in `|| true` so grep's no-match exit (1) under
    # `set -o pipefail` doesn't kill the function before we render output.
    local common_problems=""
    local common_problems_json=""
    local first=1

    if [ -f "$frequency_file" ]; then
        local problems
        problems=$( { grep "|$service|" "$frequency_file" 2>/dev/null \
                      | cut -d'|' -f2 | sort | uniq -c | sort -rn | head -5; } || true )

        while IFS= read -r line; do
            if [ -n "$line" ]; then
                local count
                count=$(echo "$line" | awk '{print $1}')
                local problem
                problem=$(echo "$line" | awk '{print $2}')

                if [ "$json_output" -eq 1 ]; then
                    if [ "$first" -eq 0 ]; then
                        common_problems_json="$common_problems_json,"
                    fi
                    first=0
                    common_problems_json="$common_problems_json{\"problem\":\"$problem\",\"count\":$count}"
                else
                    common_problems+=$'\n  - '"$problem: $count occurrences"
                fi
            fi
        done <<< "$problems"
    fi

    # Get solutions applied count (from patterns history)
    local solutions_applied=0
    if [ -d "$PATTERNS_HISTORY_DIR" ]; then
        solutions_applied=$(find "$PATTERNS_HISTORY_DIR" -name "*.json" -exec grep -l "\"service\": \"$service\"" {} \; 2>/dev/null | wc -l | tr -d ' ')
    fi

    if [ "$json_output" -eq 1 ]; then
        echo "{\"service\":\"$service\",\"deployment_count\":$deployment_count,\"avg_time\":\"$avg_time\",\"common_problems\":[$common_problems_json],\"solutions_applied\":$solutions_applied}"
    else
        echo "Service Insights: $service"
        echo "================================"
        echo "Deployment Count: $deployment_count"
        echo "Average Time: $avg_time"
        if [ -n "$common_problems" ]; then
            printf 'Common Problems:%s\n' "$common_problems"
        else
            echo "Common Problems: (none recorded)"
        fi
        echo "Solutions Applied: $solutions_applied"
    fi
}

# Get overall learning statistics
# Usage: get_learning_stats [--json-output]
get_learning_stats() {
    local json_output=0

    if [ "${1:-}" = "--json-output" ]; then
        json_output=1
    fi

    local frequency_file="$KNOWLEDGE_BASE_DIR/problem_frequency.txt"

    # Total deployments tracked
    local total_deployments=0
    if [ -f "$frequency_file" ]; then
        total_deployments=$(wc -l < "$frequency_file" | tr -d ' ')
    fi

    # Total unique problems
    local total_problems=0
    if [ -f "$frequency_file" ]; then
        total_problems=$(cut -d'|' -f2 "$frequency_file" | sort -u | wc -l | tr -d ' ')
    fi

    # Total solutions (from patterns history)
    local total_solutions=0
    if [ -d "$PATTERNS_HISTORY_DIR" ]; then
        shopt -s nullglob
        local solution_files=("$PATTERNS_HISTORY_DIR"/*.json)
        shopt -u nullglob
        total_solutions=${#solution_files[@]}
    fi

    # Playbook count
    local playbook_count=0
    if [ -d "$PLAYBOOKS_DIR" ]; then
        shopt -s nullglob
        local playbook_files=("$PLAYBOOKS_DIR"/*.md)
        shopt -u nullglob
        playbook_count=${#playbook_files[@]}
    fi

    if [ "$json_output" -eq 1 ]; then
        echo "{\"total_deployments\":$total_deployments,\"total_problems\":$total_problems,\"total_solutions\":$total_solutions,\"playbook_count\":$playbook_count}"
    else
        echo "Knowledge Base Statistics"
        echo "================================"
        echo "Total Deployments: $total_deployments"
        echo "Total Problems: $total_problems"
        echo "Total Solutions: $total_solutions"
        echo "Playbook Count: $playbook_count"
    fi
}

# Calculate health score for a service based on historical data
# Usage: calculate_health_score SERVICE MACHINE
calculate_health_score() {
    local service="$1"
    local machine="$2"
    local score=100

    # Each observation category is checked once and may dock the score.
    # The previous *_ok per-category booleans were declared but never read,
    # so their assignments have been removed.
    if [ -n "${OBSERVATION_RESULTS[ssh_$machine]:-}" ]; then
        local obs="${OBSERVATION_RESULTS[ssh_$machine]:-}"
        [[ "$obs" == ERROR* ]] && score=$((score - 30))
    fi

    if [ -n "${OBSERVATION_RESULTS[docker_$machine]:-}" ]; then
        local obs="${OBSERVATION_RESULTS[docker_$machine]:-}"
        [[ "$obs" == ERROR* ]] && score=$((score - 25))
    fi

    local port
    port=$(get_service_port "$service" 2>/dev/null)
    if [ -n "$port" ] && [ -n "${OBSERVATION_RESULTS[port_${machine}_${port}]:-}" ]; then
        local obs="${OBSERVATION_RESULTS[port_${machine}_${port}]:-}"
        [[ "$obs" == ERROR* ]] && score=$((score - 20))
    fi

    if [ -n "${OBSERVATION_RESULTS[disk_$machine]:-}" ]; then
        local obs="${OBSERVATION_RESULTS[disk_$machine]:-}"
        if [[ "$obs" == WARNING* ]]; then
            score=$((score - 10))
        elif [[ "$obs" == ERROR* ]]; then
            score=$((score - 15))
        fi
    fi

    if [ -n "${OBSERVATION_RESULTS[deps_$service]:-}" ]; then
        local obs="${OBSERVATION_RESULTS[deps_$service]:-}"
        [[ "$obs" == ERROR* ]] && score=$((score - 15))
    fi

    if [ -n "${OBSERVATION_RESULTS[health_$service]:-}" ]; then
        local obs="${OBSERVATION_RESULTS[health_$service]:-}"
        [[ "$obs" == ERROR* ]] && score=$((score - 20))
    fi

    # Ensure score is between 0 and 100
    [ "$score" -lt 0 ] && score=0
    [ "$score" -gt 100 ] && score=100

    echo $score
}

# Get problem frequency for a specific problem type
# Usage: get_problem_frequency PROBLEM_FINGERPRINT
get_problem_frequency() {
    local fingerprint="$1"
    local frequency_file="$KNOWLEDGE_BASE_DIR/problem_frequency.txt"

    if [ ! -f "$frequency_file" ]; then
        echo "0"
        return 0
    fi

    local count
    count=$(grep -c "$fingerprint" "$frequency_file" 2>/dev/null) || count=0
    echo "$count"
}

# Get solution success rate for a problem type
# Usage: get_solution_success_rate PROBLEM_FINGERPRINT
get_solution_success_rate() {
    local fingerprint="$1"
    local success_count=0
    local failure_count=0

    # Check if directory exists and has matching files
    if [ -d "$PATTERNS_HISTORY_DIR" ]; then
        shopt -s nullglob
        # Glob expansion is intended; nullglob ensures empty result on no matches.
        # shellcheck disable=SC2206
        local files=("$PATTERNS_HISTORY_DIR"/${fingerprint}_*.json)
        shopt -u nullglob
        for history_file in "${files[@]}"; do
            if [ -f "$history_file" ]; then
                local solution_status
                solution_status=$(grep '"solution_status"' "$history_file" | cut -d'"' -f4)
                if [ "$solution_status" = "SUCCESS" ]; then
                    ((success_count++))
                else
                    ((failure_count++))
                fi
            fi
        done
    fi

    local total
    total=$((success_count + failure_count))
    if [ "$total" -eq 0 ]; then
        echo "0"
        return 0
    fi

    local rate
    rate=$((success_count * 100 / total))
    echo "$rate"
}

# Categorize observations for better reporting
# Usage: categorize_observations
# Returns JSON object with categorized observations
categorize_observations() {
    local network_obs=""
    local resources_obs=""
    local config_obs=""
    local deps_obs=""

    local net_first=1
    local res_first=1
    local conf_first=1
    local dep_first=1

    for obs_key in "${!OBSERVATION_RESULTS[@]}"; do
        local obs_data="${OBSERVATION_RESULTS[$obs_key]:-}"
        local obs_status="${obs_data%%|*}"
        local rest="${obs_data#*|}"
        local value="${rest%%|*}"
        local message="${rest#*|}"

        local obs_json
        obs_json="{\"key\":\"$obs_key\",\"status\":\"$obs_status\",\"value\":\"$value\",\"message\":\"${message//\"/\\\"}\"}"

        case "$obs_key" in
            ssh_*|port_*)
                if [ $net_first -eq 0 ]; then
                    network_obs="$network_obs,"
                fi
                net_first=0
                network_obs="$network_obs$obs_json"
                ;;
            disk_*|docker_*)
                if [ $res_first -eq 0 ]; then
                    resources_obs="$resources_obs,"
                fi
                res_first=0
                resources_obs="$resources_obs$obs_json"
                ;;
            health_*|process_*)
                if [ $conf_first -eq 0 ]; then
                    config_obs="$config_obs,"
                fi
                conf_first=0
                config_obs="$config_obs$obs_json"
                ;;
            deps_*)
                if [ $dep_first -eq 0 ]; then
                    deps_obs="$deps_obs,"
                fi
                dep_first=0
                deps_obs="$deps_obs$obs_json"
                ;;
        esac
    done

    echo "{\"network\":[$network_obs],\"resources\":[$resources_obs],\"configuration\":[$config_obs],\"dependencies\":[$deps_obs]}"
}
