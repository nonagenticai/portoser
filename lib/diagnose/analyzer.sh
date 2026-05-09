#!/usr/bin/env bash
# analyzer.sh - GRASP THE SITUATION
# Analyze observations to identify root causes and problem patterns
# Part of Toyota Engagement Equation implementation

set -euo pipefail

# Diagnostics storage
DIAGNOSTICS_DIR="${DIAGNOSTICS_DIR:-$HOME/.portoser/diagnostics}"
mkdir -p "$DIAGNOSTICS_DIR"

# Color codes (only set if not already defined as readonly by utils.sh)
if ! readonly -p | grep -q "^declare -[[:alpha:]]*r[[:alpha:]]* BLUE="; then
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    PURPLE='\033[0;35m'
    NC='\033[0m'
else
    # Variables are readonly, add PURPLE which utils.sh doesn't define
    PURPLE='\033[0;35m'
fi

# Problem fingerprint storage
declare -A IDENTIFIED_PROBLEMS
declare -A ROOT_CAUSES

# Print diagnostic message
diagnose_print() {
    local level="$1"
    shift
    case "$level" in
        INFO)
            echo -e "${BLUE}📊 $*${NC}" >&2
            ;;
        PROBLEM)
            echo -e "${RED}🔴 $*${NC}" >&2
            ;;
        WARNING)
            echo -e "${YELLOW}⚠  $*${NC}" >&2
            ;;
        ROOT_CAUSE)
            echo -e "${PURPLE}→  $*${NC}" >&2
            ;;
        SUCCESS)
            echo -e "${GREEN}✓ $*${NC}" >&2
            ;;
    esac
}

# Identify problem from observations
# Usage: identify_problem "observation_key"
identify_problem() {
    local obs_key="$1"
    local obs_data
    obs_data=$(get_observation "$obs_key")

    if [ -z "$obs_data" ]; then
        return 1
    fi

    local obs_status="${obs_data%%|*}"
    local rest="${obs_data#*|}"
    local value="${rest%%|*}"
    local message="${rest#*|}"

    # Only process ERROR and WARNING observations
    if [ "$obs_status" != "ERROR" ] && [ "$obs_status" != "WARNING" ]; then
        return 0
    fi

    # Generate problem fingerprint based on observation
    local fingerprint
    fingerprint=$(generate_problem_fingerprint "$obs_key" "$value")

    IDENTIFIED_PROBLEMS[$fingerprint]="$obs_key|$obs_status|$value|$message"

    return 0
}

# Generate unique fingerprint for a problem type
# Usage: generate_problem_fingerprint "observation_key" "value"
generate_problem_fingerprint() {
    local obs_key="$1"
    local value="$2"

    # Parse observation key to understand problem type
    case "$obs_key" in
        ssh_*)
            echo "PROBLEM_SSH_CONNECTION_FAILED"
            ;;
        docker_*)
            echo "PROBLEM_DOCKER_NOT_RUNNING"
            ;;
        port_*)
            if [[ "$value" =~ ^in_use:.* ]]; then
                echo "PROBLEM_PORT_CONFLICT"
            else
                echo "PROBLEM_PORT_UNKNOWN"
            fi
            ;;
        disk_*)
            echo "PROBLEM_DISK_SPACE_LOW"
            ;;
        health_*)
            echo "PROBLEM_SERVICE_UNHEALTHY"
            ;;
        process_*)
            if [[ "$value" =~ ^stale_pid:.* ]]; then
                echo "PROBLEM_STALE_PROCESS"
            elif [[ "$value" == "not_running" ]]; then
                echo "PROBLEM_PROCESS_NOT_RUNNING"
            else
                echo "PROBLEM_PROCESS_UNKNOWN"
            fi
            ;;
        deps_*)
            echo "PROBLEM_DEPENDENCY_UNHEALTHY"
            ;;
        *)
            echo "PROBLEM_UNKNOWN"
            ;;
    esac
}

# Perform root cause analysis
# Usage: analyze_root_cause FINGERPRINT
analyze_root_cause() {
    local fingerprint="$1"
    local problem_data="${IDENTIFIED_PROBLEMS[$fingerprint]}"

    if [ -z "$problem_data" ]; then
        return 1
    fi

    local obs_key="${problem_data%%|*}"
    local rest="${problem_data#*|}"
    local obs_status="${rest%%|*}"
    rest="${rest#*|}"
    local value="${rest%%|*}"
    local message="${rest#*|}"

    diagnose_print ROOT_CAUSE "Analyzing: $fingerprint"

    case "$fingerprint" in
        PROBLEM_PORT_CONFLICT)
            # Extract PID from value
            local pid="${value#in_use:}"
            local machine="${obs_key#port_}"
            machine="${machine%_*}"
            local port="${obs_key##*_}"

            local root_cause="Port $port is occupied by process $pid on $machine. This is likely a stale process from a previous deployment that was not properly stopped."
            ROOT_CAUSES[$fingerprint]="$root_cause"
            diagnose_print ROOT_CAUSE "$root_cause"
            ;;

        PROBLEM_STALE_PROCESS)
            local pid="${value#stale_pid:}"
            local service="${obs_key#process_}"

            local root_cause="Service $service has a PID file pointing to $pid, but the process is not running. Previous shutdown was incomplete or process crashed."
            ROOT_CAUSES[$fingerprint]="$root_cause"
            diagnose_print ROOT_CAUSE "$root_cause"
            ;;

        PROBLEM_DOCKER_NOT_RUNNING)
            local machine="${obs_key#docker_}"

            local root_cause="Docker daemon is not running on $machine. Service requires Docker but daemon is stopped or failed."
            ROOT_CAUSES[$fingerprint]="$root_cause"
            diagnose_print ROOT_CAUSE "$root_cause"
            ;;

        PROBLEM_DEPENDENCY_UNHEALTHY)
            local service="${obs_key#deps_}"
            local unhealthy="${value#unhealthy:}"

            local root_cause="Service $service cannot start because its dependencies are not ready:$unhealthy. Dependencies must be healthy before deployment."
            ROOT_CAUSES[$fingerprint]="$root_cause"
            diagnose_print ROOT_CAUSE "$root_cause"
            ;;

        PROBLEM_DISK_SPACE_LOW)
            local machine="${obs_key#disk_}"
            local usage="${value}"

            local root_cause="Disk space on $machine is at $usage. High disk usage may be from accumulated logs, old containers, or temporary files."
            ROOT_CAUSES[$fingerprint]="$root_cause"
            diagnose_print ROOT_CAUSE "$root_cause"
            ;;

        PROBLEM_SSH_CONNECTION_FAILED)
            local machine="${obs_key#ssh_}"

            local root_cause="Cannot establish SSH connection to $machine. Possible causes: network issue, SSH daemon not running, key authentication failed, or wrong IP address."
            ROOT_CAUSES[$fingerprint]="$root_cause"
            diagnose_print ROOT_CAUSE "$root_cause"
            ;;

        PROBLEM_SERVICE_UNHEALTHY)
            local service="${obs_key#health_}"

            local root_cause="Service $service is not responding to health checks. Service may be crashed, misconfigured, or still starting up."
            ROOT_CAUSES[$fingerprint]="$root_cause"
            diagnose_print ROOT_CAUSE "$root_cause"
            ;;

        *)
            local root_cause="Unknown problem type: $fingerprint"
            ROOT_CAUSES[$fingerprint]="$root_cause"
            diagnose_print ROOT_CAUSE "$root_cause"
            ;;
    esac
}

# Analyze all observations and identify problems
# Usage: analyze_observations
analyze_observations() {
    diagnose_print INFO "Analyzing observations..."
    echo ""

    local problems_found=0

    # Iterate over all observations
    for obs_key in "${!OBSERVATION_RESULTS[@]}"; do
        if identify_problem "$obs_key"; then
            ((problems_found++))
        fi
    done

    # If no problems, return success
    if [ ${#IDENTIFIED_PROBLEMS[@]} -eq 0 ]; then
        diagnose_print SUCCESS "No problems identified"
        return 0
    fi

    echo ""
    diagnose_print INFO "PROBLEMS IDENTIFIED (${#IDENTIFIED_PROBLEMS[@]}):"
    echo ""

    # Perform root cause analysis for each problem
    for fingerprint in "${!IDENTIFIED_PROBLEMS[@]}"; do
        local problem_data="${IDENTIFIED_PROBLEMS[$fingerprint]}"
        local obs_key="${problem_data%%|*}"
        local rest="${problem_data#*|}"
        local obs_status="${rest%%|*}"
        rest="${rest#*|}"
        local value="${rest%%|*}"
        local message="${rest#*|}"

        if [ "$obs_status" = "ERROR" ]; then
            diagnose_print PROBLEM "Problem: $message"
        else
            diagnose_print WARNING "Warning: $message"
        fi

        # Perform root cause analysis
        analyze_root_cause "$fingerprint"
        echo ""
    done

    return 1
}

# Get recommended solution pattern for a problem
# Usage: get_solution_pattern FINGERPRINT
get_solution_pattern() {
    local fingerprint="$1"

    case "$fingerprint" in
        PROBLEM_PORT_CONFLICT)
            echo "port_conflict"
            ;;
        PROBLEM_STALE_PROCESS)
            echo "stale_process_cleanup"
            ;;
        PROBLEM_DOCKER_NOT_RUNNING)
            echo "docker_not_running"
            ;;
        PROBLEM_DEPENDENCY_UNHEALTHY)
            echo "dependency_not_ready"
            ;;
        PROBLEM_DISK_SPACE_LOW)
            echo "disk_space_cleanup"
            ;;
        PROBLEM_SSH_CONNECTION_FAILED)
            echo "ssh_connection_failed"
            ;;
        PROBLEM_SERVICE_UNHEALTHY)
            echo "service_restart"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Generate diagnostic report
# Usage: generate_diagnostic_report SERVICE TARGET_MACHINE
generate_diagnostic_report() {
    local service="$1"
    local target_machine="$2"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local report_file
    report_file="$DIAGNOSTICS_DIR/${service}_${target_machine}_$(date +%s).md"

    cat > "$report_file" <<EOF
# Diagnostic Report

**Service:** $service
**Target Machine:** $target_machine
**Timestamp:** $timestamp

## Observations

EOF

    # Add observations
    for obs_key in "${!OBSERVATION_RESULTS[@]}"; do
        local obs_data="${OBSERVATION_RESULTS[$obs_key]}"
        local obs_status="${obs_data%%|*}"
        local rest="${obs_data#*|}"
        local value="${rest%%|*}"
        local message="${rest#*|}"

        echo "- **$obs_key**: [$obs_status] $message (value: $value)" >> "$report_file"
    done

    cat >> "$report_file" <<EOF

## Identified Problems

EOF

    # Add problems
    if [ ${#IDENTIFIED_PROBLEMS[@]} -eq 0 ]; then
        echo "No problems identified." >> "$report_file"
    else
        for fingerprint in "${!IDENTIFIED_PROBLEMS[@]}"; do
            local problem_data="${IDENTIFIED_PROBLEMS[$fingerprint]}"
            local root_cause="${ROOT_CAUSES[$fingerprint]}"
            local solution_pattern
            solution_pattern=$(get_solution_pattern "$fingerprint")

            {
                echo "### $fingerprint"
                echo ""
                echo "**Root Cause:** $root_cause"
                echo ""
                echo "**Recommended Solution:** \`$solution_pattern\`"
                echo ""
            } >> "$report_file"
        done
    fi

    cat >> "$report_file" <<EOF

---
*Generated by Portoser Diagnostic Engine*
EOF

    echo "$report_file"
}

# Main diagnostic workflow
# Usage: diagnose_deployment_issues SERVICE TARGET_MACHINE
diagnose_deployment_issues() {
    local service="$1"
    local target_machine="$2"

    diagnose_print INFO "Grasping the situation for $service deployment to $target_machine..."
    echo ""

    # Analyze all observations
    if analyze_observations; then
        diagnose_print SUCCESS "No issues detected - deployment should proceed smoothly"
        return 0
    else
        # Generate diagnostic report
        local report_file
        report_file=$(generate_diagnostic_report "$service" "$target_machine")
        diagnose_print INFO "Diagnostic report saved: $report_file"
        return 1
    fi
}

# Get all identified problems (returns array of fingerprints)
# Usage: get_identified_problems
get_identified_problems() {
    echo "${!IDENTIFIED_PROBLEMS[@]}"
}

# Get problem details
# Usage: get_problem_details FINGERPRINT
get_problem_details() {
    local fingerprint="$1"
    echo "${IDENTIFIED_PROBLEMS[$fingerprint]}"
}

# Get root cause for problem
# Usage: get_root_cause FINGERPRINT
get_root_cause() {
    local fingerprint="$1"
    echo "${ROOT_CAUSES[$fingerprint]}"
}
