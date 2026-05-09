#!/usr/bin/env bash
# learning.sh - GET TO STANDARDIZATION & GET TO SUSTAINABILITY

set -euo pipefail
# Learn from solved problems and build knowledge base
# Part of Toyota Engagement Equation implementation

# Get script directory
LEARNING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTOSER_ROOT="$(cd "$LEARNING_DIR/../.." && pwd)"

# Knowledge base storage
KNOWLEDGE_BASE_DIR="${KNOWLEDGE_BASE_DIR:-$HOME/.portoser/knowledge}"
PLAYBOOKS_DIR="$KNOWLEDGE_BASE_DIR/playbooks"
PATTERNS_HISTORY_DIR="$KNOWLEDGE_BASE_DIR/patterns_history"
mkdir -p "$KNOWLEDGE_BASE_DIR" "$PLAYBOOKS_DIR" "$PATTERNS_HISTORY_DIR"

# Color codes. Only set if not already declared readonly by utils.sh —
# YELLOW is included for parity with the print helpers' colour palette even
# though learning_print currently doesn't emit warnings in yellow.
if ! readonly -p | grep -q "^declare -[[:alpha:]]*r[[:alpha:]]* BLUE="; then
    BLUE='\033[0;34m'
    # shellcheck disable=SC2034 # exported palette member
    YELLOW='\033[1;33m'
    GREEN='\033[0;32m'
    PURPLE='\033[0;35m'
    NC='\033[0m'
else
    # Variables are readonly, add PURPLE which utils.sh doesn't define
    PURPLE='\033[0;35m'
fi

# Print learning message
learn_print() {
    local level="$1"
    shift
    case "$level" in
        INFO)
            echo -e "${BLUE}📝 $*${NC}" >&2
            ;;
        SUCCESS)
            echo -e "${GREEN}   ✓ $*${NC}" >&2
            ;;
        INSIGHT)
            echo -e "${PURPLE}   💡 $*${NC}" >&2
            ;;
    esac
}

# Record a solved problem to knowledge base
# Usage: record_solved_problem FINGERPRINT SOLUTION_STATUS ACTIONS SERVICE TARGET_MACHINE
record_solved_problem() {
    local fingerprint="$1"
    local solution_status="$2"
    local actions="$3"
    local service="$4"
    local target_machine="$5"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Create problem-solution entry
    local entry_file
    entry_file="$PATTERNS_HISTORY_DIR/${fingerprint}_$(date +%s).json"

    cat > "$entry_file" <<EOF
{
  "fingerprint": "$fingerprint",
  "timestamp": "$timestamp",
  "service": "$service",
  "machine": "$target_machine",
  "solution_status": "$solution_status",
  "actions_taken": "$actions",
  "root_cause": "$(get_root_cause "$fingerprint")"
}
EOF

    # Update problem frequency counter.
    # Reject obvious garbage in $service / $target_machine — these are sometimes
    # called with the user's argv on dispatcher errors, which previously wrote
    # ANSI-colored error strings into the frequency log.
    local frequency_file="$KNOWLEDGE_BASE_DIR/problem_frequency.txt"
    if [[ "$service" =~ ^[A-Za-z0-9_.-]+$ ]] && [[ "$target_machine" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        echo "$timestamp|$fingerprint|$service|$target_machine" >> "$frequency_file"
    fi
}

# Generate standardized playbook for a problem type
# Usage: generate_playbook FINGERPRINT
generate_playbook() {
    local fingerprint="$1"
    local playbook_file="$PLAYBOOKS_DIR/${fingerprint}.md"

    # Get solution pattern
    local pattern
    pattern=$(get_solution_pattern "$fingerprint")

    # Count how many times we've seen this problem
    local frequency_file="$KNOWLEDGE_BASE_DIR/problem_frequency.txt"
    local occurrence_count=0
    if [ -f "$frequency_file" ]; then
        occurrence_count=$(grep -c "$fingerprint" "$frequency_file" 2>/dev/null) || occurrence_count=0
    fi

    # Get historical solutions
    local success_count=0
    local failure_count=0
    for history_file in "$PATTERNS_HISTORY_DIR/${fingerprint}_"*.json; do
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

    local success_rate=0
    if [ $((success_count + failure_count)) -gt 0 ]; then
        success_rate=$((success_count * 100 / (success_count + failure_count)))
    fi

    # Generate playbook
    cat > "$playbook_file" <<EOF
# Playbook: $fingerprint

## Problem Description

$(get_root_cause "$fingerprint" 2>/dev/null || echo "No root cause documented yet")

## Statistics

- **Occurrences:** $occurrence_count
- **Solutions Attempted:** $((success_count + failure_count))
- **Success Rate:** ${success_rate}% ($success_count successful, $failure_count failed)
- **Solution Pattern:** \`$pattern\`

## Standard Operating Procedure

### 1. Observation Phase (Go to See)

Run these checks:
\`\`\`bash
portoser observe deployment <service> <machine>
\`\`\`

### 2. Analysis Phase (Grasp the Situation)

The diagnostic engine will identify this as \`$fingerprint\`.

Common root causes:
- $(get_root_cause "$fingerprint" 2>/dev/null || echo "To be documented")

### 3. Solution Phase (Get to Solution)

Auto-healing will apply pattern: \`$pattern\`

If auto-healing fails, manual steps:
\`\`\`bash
# See solution pattern file for details
cat $PORTOSER_ROOT/lib/solve/patterns/${pattern}.sh
\`\`\`

### 4. Prevention

To prevent this problem:
$(generate_prevention_advice "$fingerprint")

## Historical Solutions

EOF

    # Add recent solutions
    local count=0
    for history_file in "$PATTERNS_HISTORY_DIR/${fingerprint}_"*.json; do
        if [ -f "$history_file" ] && [ $count -lt 5 ]; then
            local ts
            ts=$(grep '"timestamp"' "$history_file" | cut -d'"' -f4)
            local solution_status
            solution_status=$(grep '"solution_status"' "$history_file" | cut -d'"' -f4)
            local actions
            actions=$(grep '"actions_taken"' "$history_file" | cut -d'"' -f4)
            echo "- **$ts**: $solution_status - $actions" >> "$playbook_file"
            ((count++))
        fi
    done

    cat >> "$playbook_file" <<EOF

---
*Auto-generated playbook - Last updated: $(date)*
EOF

    learn_print SUCCESS "Playbook generated: $playbook_file"
}

# Generate prevention advice based on problem type
# Usage: generate_prevention_advice FINGERPRINT
generate_prevention_advice() {
    local fingerprint="$1"

    case "$fingerprint" in
        PROBLEM_PORT_CONFLICT)
            echo "- Always stop old instances before deploying"
            echo "- Add pre-deployment check for port availability"
            echo "- Use 'portoser stop <service>' before 'portoser deploy'"
            ;;
        PROBLEM_STALE_PROCESS)
            echo "- Ensure graceful shutdown completes before starting new instance"
            echo "- Add health check before considering service 'stopped'"
            echo "- Implement proper signal handling in services"
            ;;
        PROBLEM_DOCKER_NOT_RUNNING)
            echo "- Add Docker daemon check to pre-flight validations"
            echo "- Consider auto-starting Docker on machine boot"
            echo "- Monitor Docker daemon health continuously"
            ;;
        PROBLEM_DEPENDENCY_UNHEALTHY)
            echo "- Start dependencies in correct order"
            echo "- Wait for dependency health before starting dependent services"
            echo "- Implement dependency health monitoring"
            ;;
        PROBLEM_DISK_SPACE_LOW)
            echo "- Set up automated log rotation"
            echo "- Monitor disk usage proactively (alert at 80%)"
            echo "- Implement regular cleanup cron jobs"
            echo "- Clean up old Docker images and containers regularly"
            ;;
        *)
            echo "- Document prevention steps as we learn more"
            ;;
    esac
}

# Learn from deployment session
# Usage: learn_from_deployment SERVICE TARGET_MACHINE
learn_from_deployment() {
    local service="$1"
    local target_machine="$2"

    learn_print INFO "Learning from deployment session..."

    # Get all problems that were identified
    local problems
    problems=$(get_identified_problems)

    if [ -z "$problems" ]; then
        learn_print INFO "No problems encountered - smooth deployment"
        return 0
    fi

    # Record each problem-solution pair
    for fingerprint in $problems; do
        local solution_status="${SOLUTION_RESULTS[$fingerprint]:-NOT_ATTEMPTED}"
        local actions="${SOLUTION_ACTIONS[$fingerprint]:-None}"

        record_solved_problem "$fingerprint" "$solution_status" "$actions" "$service" "$target_machine"

        # Generate/update playbook
        generate_playbook "$fingerprint"
    done

    # Generate insights
    generate_insights "$service" "$target_machine"
}

# Generate insights from patterns
# Usage: generate_insights SERVICE TARGET_MACHINE
generate_insights() {
    local service="$1"
    local target_machine="$2"

    learn_print INFO "Generating insights..."

    # Analyze problem frequency
    local frequency_file="$KNOWLEDGE_BASE_DIR/problem_frequency.txt"
    if [ ! -f "$frequency_file" ]; then
        return 0
    fi

    # Find most common problems
    local most_common
    most_common=$(tail -100 "$frequency_file" | cut -d'|' -f2 | sort | uniq -c | sort -rn | head -3)

    if [ -n "$most_common" ]; then
        echo ""
        learn_print INSIGHT "Most common problems (last 100 deployments):"
        while IFS= read -r line; do
            local count
            count=$(echo "$line" | awk '{print $1}')
            local problem
            problem=$(echo "$line" | awk '{print $2}')
            learn_print INSIGHT "  $problem: $count occurrences"
        done <<< "$most_common"
    fi

    # Check if this service has recurring problems
    local service_problems
    service_problems=$(grep "|$service|" "$frequency_file" 2>/dev/null | cut -d'|' -f2 | sort | uniq -c | sort -rn | head -1)

    if [ -n "$service_problems" ]; then
        local count
        count=$(echo "$service_problems" | awk '{print $1}')
        local problem
        problem=$(echo "$service_problems" | awk '{print $2}')
        if [ "$count" -gt 2 ]; then
            learn_print INSIGHT "Service '$service' frequently encounters: $problem ($count times)"
            learn_print INSIGHT "Consider implementing prevention measures - see playbook:"
            learn_print INSIGHT "  $PLAYBOOKS_DIR/${problem}.md"
        fi
    fi
}

# Get recommended pre-checks for a service based on history
# Usage: get_recommended_prechecks SERVICE
get_recommended_prechecks() {
    local service="$1"
    local frequency_file="$KNOWLEDGE_BASE_DIR/problem_frequency.txt"

    if [ ! -f "$frequency_file" ]; then
        echo "standard"
        return
    fi

    # Get problems this service has encountered
    local service_problems
    service_problems=$(grep "|$service|" "$frequency_file" 2>/dev/null | cut -d'|' -f2 | sort | uniq)

    if [ -z "$service_problems" ]; then
        echo "standard"
        return
    fi

    # Build list of recommended checks
    local checks="standard"

    while IFS= read -r problem; do
        case "$problem" in
            PROBLEM_PORT_CONFLICT)
                checks="$checks,port_availability"
                ;;
            PROBLEM_DEPENDENCY_UNHEALTHY)
                checks="$checks,dependency_health"
                ;;
            PROBLEM_DISK_SPACE_LOW)
                checks="$checks,disk_space"
                ;;
        esac
    done <<< "$service_problems"

    echo "$checks"
}

# Show learning summary
# Usage: show_learning_summary
show_learning_summary() {
    local frequency_file="$KNOWLEDGE_BASE_DIR/problem_frequency.txt"

    echo ""
    learn_print INFO "KNOWLEDGE BASE SUMMARY"
    echo ""

    if [ ! -f "$frequency_file" ]; then
        echo "  No data yet - knowledge base is empty"
        return
    fi

    local total_problems
    total_problems=$(wc -l < "$frequency_file" | tr -d ' ')
    local unique_problems
    unique_problems=$(cut -d'|' -f2 "$frequency_file" | sort -u | wc -l | tr -d ' ')
    local playbook_count=0
    local pb
    for pb in "$PLAYBOOKS_DIR"/*.md; do
        [ -e "$pb" ] && playbook_count=$((playbook_count + 1))
    done

    echo "  Total Problems Encountered: $total_problems"
    echo "  Unique Problem Types: $unique_problems"
    echo "  Playbooks Generated: $playbook_count"
    echo ""
    echo "  Playbooks available at: $PLAYBOOKS_DIR"
    echo ""
}
