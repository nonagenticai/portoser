#!/usr/bin/env bash
################################################################################
# Health Command Module
#
# Health checking and status reporting for services.
#
# Usage: portoser health <subcommand> [options]
################################################################################

set -euo pipefail

# Health command handler
cmd_health() {
    if [ $# -eq 0 ]; then
        health_help
        exit 1
    fi

    local subcommand="$1"
    shift

    case "$subcommand" in
        -h|--help)
            health_help
            exit 0
            ;;
        check)
            if [ $# -eq 0 ]; then
                echo "Usage: portoser health check SERVICE"
                exit 1
            fi
            check_service_health "$1"
            ;;
        check-all)
            check_all_services_health
            ;;
        status)
            if [ $# -eq 0 ]; then
                echo "Usage: portoser health status SERVICE"
                exit 1
            fi
            service_status_report "$1"
            ;;
        --all)
            # Quick health check for all services
            local json_output=0
            if [ "$1" = "--json-output" ]; then
                json_output=1
            fi

            if [ $json_output -eq 1 ]; then
                echo '{"services":['
                local first=1
                local services
                services=$(list_services)
                while IFS= read -r service; do
                    if [ -z "$service" ]; then
                        continue
                    fi

                    local machine
                    machine=$(get_service_host "$service" 2>/dev/null)
                    if [ -z "$machine" ] || [ "$machine" = "null" ]; then
                        continue
                    fi

                    # Run quick health check
                    OBSERVATION_RESULTS=()
                    observe_deployment_readiness "$service" "$machine" >/dev/null 2>&1
                    local health_score
                    health_score=$(calculate_health_score "$service" "$machine")

                    # Determine status
                    local status="unhealthy"
                    if [ "$health_score" -ge 90 ]; then
                        status="healthy"
                    elif [ "$health_score" -ge 70 ]; then
                        status="degraded"
                    fi

                    # Collect issues
                    local issues=""
                    local issue_first=1
                    for obs_key in "${!OBSERVATION_RESULTS[@]}"; do
                        local obs_data="${OBSERVATION_RESULTS[$obs_key]}"
                        if [[ "$obs_data" == ERROR* ]] || [[ "$obs_data" == WARNING* ]]; then
                            local message="${obs_data##*|}"

                            if [ $issue_first -eq 0 ]; then
                                issues="$issues,"
                            fi
                            issue_first=0
                            issues="$issues{\"type\":\"$obs_key\",\"message\":\"${message//\"/\\\"}\"}"
                        fi
                    done

                    if [ $first -eq 0 ]; then
                        echo ","
                    fi
                    first=0
                    echo -n "{\"service\":\"$service\",\"machine\":\"$machine\",\"status\":\"$status\",\"health_score\":$health_score,\"issues\":[$issues]}"
                done <<< "$services"
                echo ']}'
            else
                # Text output
                local services
                services=$(list_services)
                printf "%-25s %-15s %-12s %-6s\n" "SERVICE" "MACHINE" "STATUS" "SCORE"
                echo "------------------------------------------------------------------------"
                while IFS= read -r service; do
                    if [ -z "$service" ]; then
                        continue
                    fi

                    local machine
                    machine=$(get_service_host "$service" 2>/dev/null)
                    if [ -z "$machine" ] || [ "$machine" = "null" ]; then
                        continue
                    fi

                    OBSERVATION_RESULTS=()
                    observe_deployment_readiness "$service" "$machine" >/dev/null 2>&1
                    local health_score
                    health_score=$(calculate_health_score "$service" "$machine")

                    local status="UNHEALTHY"
                    if [ "$health_score" -ge 90 ]; then
                        status="HEALTHY"
                    elif [ "$health_score" -ge 70 ]; then
                        status="DEGRADED"
                    fi

                    printf "%-25s %-15s %-12s %-6s\n" "$service" "$machine" "$status" "$health_score"
                done <<< "$services"
            fi
            ;;
        *)
            # Assume first argument is service name, second is machine
            local service="$subcommand"
            local machine="$1"
            local json_output=0

            if [ "$2" = "--json-output" ]; then
                json_output=1
            fi

            if [ -z "$machine" ]; then
                # Try to get machine from registry
                machine=$(get_service_host "$service" 2>/dev/null)
            fi

            if [ -z "$machine" ] || [ "$machine" = "null" ]; then
                if [ $json_output -eq 1 ]; then
                    echo "{\"error\":\"Service not deployed or machine not specified\"}"
                else
                    print_color "$RED" "Error: Service '$service' is not deployed or machine not specified"
                fi
                exit 1
            fi

            # Run quick health check
            OBSERVATION_RESULTS=()
            observe_deployment_readiness "$service" "$machine" >/dev/null 2>&1
            local health_score
            health_score=$(calculate_health_score "$service" "$machine")

            # Determine status
            local status="unhealthy"
            if [ "$health_score" -ge 90 ]; then
                status="healthy"
            elif [ "$health_score" -ge 70 ]; then
                status="degraded"
            fi

            if [ "$json_output" -eq 1 ]; then
                # Collect issues
                local issues=""
                local first=1
                for obs_key in "${!OBSERVATION_RESULTS[@]}"; do
                    local obs_data="${OBSERVATION_RESULTS[$obs_key]}"
                    if [[ "$obs_data" == ERROR* ]] || [[ "$obs_data" == WARNING* ]]; then
                        local message="${obs_data##*|}"

                        if [ $first -eq 0 ]; then
                            issues="$issues,"
                        fi
                        first=0
                        issues="$issues{\"type\":\"$obs_key\",\"message\":\"${message//\"/\\\"}\"}"
                    fi
                done

                echo "{\"service\":\"$service\",\"machine\":\"$machine\",\"status\":\"$status\",\"health_score\":$health_score,\"issues\":[$issues]}"
            else
                print_color "$BLUE" "Health Check: $service on $machine"
                echo "Status: $status"
                echo "Health Score: $health_score/100"
                echo ""

                # Show issues
                local has_issues=0
                for obs_key in "${!OBSERVATION_RESULTS[@]}"; do
                    local obs_data="${OBSERVATION_RESULTS[$obs_key]}"
                    if [[ "$obs_data" == ERROR* ]] || [[ "$obs_data" == WARNING* ]]; then
                        if [ $has_issues -eq 0 ]; then
                            echo "Issues:"
                            has_issues=1
                        fi
                        local status_part="${obs_data%%|*}"
                        local message="${obs_data##*|}"
                        echo "  - [$status_part] $message"
                    fi
                done

                if [ $has_issues -eq 0 ]; then
                    echo "No issues detected"
                fi
            fi
            ;;
    esac
}

# Help function for health command
health_help() {
    cat <<EOF
Usage: portoser health <subcommand> [options]

Health checking commands for services.

Subcommands:
  check SERVICE              Check if a specific service is healthy
  check-all                  Check health of all services
  status SERVICE             Get detailed status report for a service
  SERVICE MACHINE [--json-output]   Quick health check for service on machine
  --all [--json-output]      Quick health check for all services

Examples:
  portoser health check myservice
  portoser health check-all
  portoser health status myservice
  portoser health requirements host-b --json-output
  portoser health --all --json-output

EOF
}

################################################################################
# End of health.sh
################################################################################
