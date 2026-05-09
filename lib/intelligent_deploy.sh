#!/usr/bin/env bash
# intelligent_deploy.sh - Intelligent deployment using Toyota Engagement Equation
# This replaces the basic deployment with self-healing, observability, and learning

set -euo pipefail

# Cleanup background jobs on exit (only when any exist).
_intelligent_deploy_cleanup_jobs() {
    local pids
    pids=$(jobs -p)
    if [ -n "$pids" ]; then
        # shellcheck disable=SC2086 # word-split intentional: pids is space-separated
        kill $pids 2>/dev/null || true
    fi
}
trap _intelligent_deploy_cleanup_jobs EXIT INT TERM

# Source uptime tracking
SCRIPT_DIR_IDEPLOY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR_IDEPLOY/../metrics/uptime.sh" ]; then
    # Note: relative path here is `lib/intelligent_deploy.sh` → `lib/metrics/uptime.sh`
    # shellcheck source=lib/metrics/uptime.sh
    source "$SCRIPT_DIR_IDEPLOY/../metrics/uptime.sh"
fi

# Circuit breaker for auto-heal
AUTO_HEAL_TRACKING_DIR="${HOME}/.portoser/auto-heal"
mkdir -p "$AUTO_HEAL_TRACKING_DIR"

# Check if auto-heal circuit breaker should trip
# Returns 0 if auto-heal is allowed, 1 if circuit breaker trips
check_auto_heal_circuit_breaker() {
    local max_attempts=3
    local time_window=3600  # 1 hour in seconds
    local tracking_file="$AUTO_HEAL_TRACKING_DIR/attempts.log"
    local now
    now=$(date +%s)

    # Clean up old entries (older than time window)
    if [ -f "$tracking_file" ]; then
        local temp_file
        temp_file=$(mktemp)
        while IFS= read -r line; do
            local timestamp
            timestamp=$(echo "$line" | cut -d' ' -f1)
            if [ $((now - timestamp)) -lt $time_window ]; then
                echo "$line" >> "$temp_file"
            fi
        done < "$tracking_file"
        mv "$temp_file" "$tracking_file"
    fi

    # Count recent attempts
    local attempt_count=0
    if [ -f "$tracking_file" ]; then
        attempt_count=$(wc -l < "$tracking_file")
    fi

    # Check if we've exceeded max attempts
    if [ "$attempt_count" -ge "$max_attempts" ]; then
        return 1  # Circuit breaker trips
    fi

    # Record this attempt
    echo "$now auto-heal-attempt" >> "$tracking_file"
    return 0  # Allow auto-heal
}

# Intelligent deploy with auto-healing
# Usage: intelligent_deploy_service SERVICE TARGET_MACHINE [--auto-heal]
intelligent_deploy_service() {
    local service="$1"
    local target_machine="$2"
    local auto_heal="${3:-}"  # Auto-heal disabled by default - must use --auto-heal flag
    local current_host
    current_host=$(get_service_host "$service" 2>/dev/null)
    local service_type
    service_type=$(get_service_type "$service")
    local port
    port=$(get_service_port "$service")

    # Determine deployment action
    local deploy_action=""
    if [ -z "$current_host" ] || [ "$current_host" = "null" ]; then
        deploy_action="deploy"
    elif [ "$current_host" = "$target_machine" ]; then
        deploy_action="restart"
    else
        deploy_action="migrate"
    fi

    # Initialize deployment tracking
    init_deployment_tracking "$service" "$target_machine" "$deploy_action"

    # Initialize JSON output if enabled
    if is_json_output_mode; then
        init_json_deploy_output
        # JSON_DEPLOY_DATA is the assoc array declared in lib/json_output.sh;
        # we populate keys here for the eventual finalize_json_deploy_output call.
        # shellcheck disable=SC2034 # populated for sourced lib/json_output.sh
        JSON_DEPLOY_DATA["service"]="$service"
        # shellcheck disable=SC2034
        JSON_DEPLOY_DATA["machine"]="$target_machine"
        # shellcheck disable=SC2034
        JSON_DEPLOY_DATA["deployment_id"]="$DEPLOYMENT_ID"
    fi

    json_print_color "$BLUE" "🚀 Intelligent Deploy: $service → $target_machine"
    json_print ""

    # ================================================================
    # PHASE 1: GO TO SEE (Observe)
    # ================================================================
    local observe_start
    observe_start=$(date +%s%3N)
    observe_print_json_safe INFO "Phase 1: GO TO SEE - Observing deployment environment..."
    json_print ""

    # Clear previous observations
    OBSERVATION_RESULTS=()

    # Run comprehensive observations
    local observe_result=0
    if ! observe_deployment_readiness "$service" "$target_machine"; then
        observe_result=1
        json_print ""
        observe_print_json_safe WARNING "Issues detected during observation"

        # ================================================================
        # PHASE 2: GRASP THE SITUATION (Diagnose)
        # ================================================================
        local diagnose_start
        diagnose_start=$(date +%s%3N)
        diagnose_print_json_safe INFO "Phase 2: GRASP THE SITUATION - Analyzing issues..."
        json_print ""

        # Clear previous diagnostics
        IDENTIFIED_PROBLEMS=()
        ROOT_CAUSES=()

        # Analyze observations
        local diagnose_result=0
        if diagnose_deployment_issues "$service" "$target_machine"; then
            # No problems found (observation warnings were non-critical)
            json_print ""
        else
            diagnose_result=1
            # Problems identified
            json_print ""

            # ================================================================
            # PHASE 3: GET TO SOLUTION (Solve)
            # ================================================================
            if [ "$auto_heal" = "--auto-heal" ]; then
                # Check circuit breaker
                if ! check_auto_heal_circuit_breaker; then
                    solve_print_json_safe ERROR "Auto-heal circuit breaker triggered!"
                    solve_print_json_safe ERROR "Maximum auto-heal attempts (3) reached in the last hour"
                    solve_print_json_safe WARNING "Manual intervention required - problems may cause deployment failure"
                    json_print ""
                else
                    local solve_start
                    solve_start=$(date +%s%3N)
                    solve_print_json_safe INFO "Phase 3: GET TO SOLUTION - Auto-healing enabled..."
                    json_print ""

                    # Show confirmation prompt if not in JSON mode
                    local user_cancelled=0
                    if ! is_json_output_mode; then
                        solve_print_json_safe WARNING "Auto-healing will make destructive changes to fix issues"
                        echo -n "  Continue with auto-healing? [y/N]: "
                        read -r response
                        if [[ ! "$response" =~ ^[Yy]$ ]]; then
                            solve_print_json_safe INFO "Auto-healing cancelled by user"
                            json_print ""
                            user_cancelled=1
                        fi
                    fi

                    # Proceed with auto-heal if user confirmed (or in JSON mode)
                    if [ $user_cancelled -eq 0 ]; then
                        # Clear previous solutions (these arrays live in solver.sh).
                        # shellcheck disable=SC2034 # cleared here, populated by sourced solver.sh
                        SOLUTION_RESULTS=()
                        # shellcheck disable=SC2034
                        SOLUTION_ACTIONS=()

                        # Attempt to solve all problems
                        local solve_result=0
                        if solve_all_problems --auto-heal; then
                            json_print ""
                            solve_print_json_safe SUCCESS "All problems resolved!"

                            # Verify solutions worked
                            if verify_solutions "$service" "$target_machine"; then
                                json_print ""
                                solve_print_json_safe SUCCESS "Solutions verified - proceeding with deployment"
                            else
                                json_print ""
                                solve_print_json_safe WARNING "Some issues remain - deployment may fail"
                                solve_result=1
                            fi
                        else
                            solve_result=1
                            json_print ""
                            solve_print_json_safe WARNING "Auto-healing partially successful"
                            solve_print_json_safe WARNING "Proceeding with deployment anyway..."
                        fi

                        local solve_end
                        solve_end=$(date +%s%3N)
                        local solve_duration
                        solve_duration=$((solve_end - solve_start))

                        # Track solutions in history
                        for action in "${SOLUTION_ACTIONS[@]}"; do
                            track_solution "auto_heal" "$action" "applied"
                        done

                        # Add solve phase to JSON
                        if is_json_output_mode; then
                            local solve_status="completed"
                            [ $solve_result -ne 0 ] && solve_status="partial"
                            json_add_deploy_phase "solve" "$solve_status" "$solve_duration" "{}"
                        fi

                        # Track phase in history
                        track_deployment_phase "solve" "$([ $solve_result -eq 0 ] && echo completed || echo partial)" "$solve_duration" "{}"
                    fi  # End of user_cancelled check
                fi  # End of circuit breaker check
            else
                solve_print_json_safe WARNING "Auto-healing disabled - problems may cause deployment failure"
                json_print ""
                solve_print_json_safe INFO "To enable auto-healing, use: --auto-heal flag"
                json_print ""
            fi
        fi

        local diagnose_end
        diagnose_end=$(date +%s%3N)
        local diagnose_duration
        diagnose_duration=$((diagnose_end - diagnose_start))

        # Track problems in history
        for fp in "${!IDENTIFIED_PROBLEMS[@]}"; do
            local desc="${IDENTIFIED_PROBLEMS[$fp]}"
            track_problem "$fp" "$desc"
        done

        # Add diagnose phase to JSON
        if is_json_output_mode; then
            local diagnose_status="completed"
            [ $diagnose_result -ne 0 ] && diagnose_status="issues_found"
            local problems_json="[]"
            if [ ${#IDENTIFIED_PROBLEMS[@]} -gt 0 ]; then
                local prob_items=""
                for fp in "${!IDENTIFIED_PROBLEMS[@]}"; do
                    [ -n "$prob_items" ] && prob_items="$prob_items,"
                    prob_items="$prob_items\"$fp\""
                done
                problems_json="[$prob_items]"
            fi
            json_add_deploy_phase "diagnose" "$diagnose_status" "$diagnose_duration" "{\"problems\":$problems_json}"
        fi

        # Track phase in history
        track_deployment_phase "diagnose" "$([ $diagnose_result -eq 0 ] && echo completed || echo issues_found)" "$diagnose_duration" "{}"
    else
        json_print ""
        observe_print_json_safe SUCCESS "Environment ready - no issues detected"
        json_print ""
    fi

    local observe_end
    observe_end=$(date +%s%3N)
    local observe_duration
    observe_duration=$((observe_end - observe_start))

    # Track observations in history
    for obs in "${OBSERVATION_RESULTS[@]}"; do
        track_observation "deployment_readiness" "$obs" "info"
    done

    # Add observe phase to JSON
    if is_json_output_mode; then
        local observe_status="completed"
        [ $observe_result -ne 0 ] && observe_status="issues_detected"
        local obs_count=${#OBSERVATION_RESULTS[@]}
        json_add_deploy_phase "observe" "$observe_status" "$observe_duration" "{\"observation_count\":$obs_count}"
    fi

    # Track phase in history
    track_deployment_phase "observe" "$([ $observe_result -eq 0 ] && echo completed || echo issues_detected)" "$observe_duration" "{}"

    # ================================================================
    # PHASE 4: EXECUTE DEPLOYMENT
    # ================================================================
    local deploy_start
    deploy_start=$(date +%s%3N)
    json_print_color "$BLUE" "Executing deployment..."
    json_print ""

    # Determine deployment action
    local deploy_result=0
    local deploy_action=""
    if [ -z "$current_host" ] || [ "$current_host" = "null" ]; then
        # Fresh deployment
        deploy_action="fresh"
        json_print "  Action: Fresh deployment (not currently deployed)"
        if ! execute_fresh_deployment "$service" "$target_machine"; then
            json_print_color "$RED" "  ✗ Deployment failed"
            deploy_result=1
        fi

    elif [ "$current_host" = "$target_machine" ]; then
        # Restart in place
        deploy_action="restart"
        json_print "  Action: Restart in place (already on $target_machine)"
        if ! execute_restart_deployment "$service" "$target_machine"; then
            json_print_color "$RED" "  ✗ Restart failed"
            deploy_result=1
        fi

    else
        # Migration
        deploy_action="migrate"
        json_print "  Action: Migrate (from $current_host to $target_machine)"
        json_print "  Preparing image for target architecture..."

        local build_status="completed"
        local build_details="{}"
        local build_start
        build_start=$(date +%s%3N)

        if ! build_details=$(build_for_target_architecture "$service" "$current_host" "$target_machine"); then
            build_status="failed"
            [ -z "$build_details" ] && build_details="{\"status\":\"failed\"}"
            deploy_result=1
        fi
        [ -z "$build_details" ] && build_details="{}"

        local build_end
        build_end=$(date +%s%3N)
        local build_duration
        build_duration=$((build_end - build_start))

        if is_json_output_mode; then
            json_add_deploy_phase "build" "$build_status" "$build_duration" "$build_details"
        fi
        track_deployment_phase "build" "$build_status" "$build_duration" "$build_details"

        if [ "$build_status" = "failed" ]; then
            json_print_color "$RED" "  ✗ Build for target architecture failed"
        fi

        if [ $deploy_result -eq 0 ]; then
            if ! execute_migration_deployment "$service" "$current_host" "$target_machine"; then
                json_print_color "$RED" "  ✗ Migration failed"
                deploy_result=1
            fi
        fi
    fi

    local deploy_end
    deploy_end=$(date +%s%3N)
    local deploy_duration
    deploy_duration=$((deploy_end - deploy_start))

    # Add deploy phase to JSON
    if is_json_output_mode; then
        local deploy_status="completed"
        [ $deploy_result -ne 0 ] && deploy_status="failed"
        json_add_deploy_phase "deploy" "$deploy_status" "$deploy_duration" "{\"action\":\"$deploy_action\"}"
    fi

    # Track phase in history
    track_deployment_phase "deploy" "$([ $deploy_result -eq 0 ] && echo completed || echo failed)" "$deploy_duration" "{\"action\":\"$deploy_action\"}"

    # ================================================================
    # PHASE 5: GET TO STANDARDIZATION (Learn)
    # ================================================================
    json_print ""
    learn_print_json_safe INFO "Phase 4: GET TO STANDARDIZATION - Learning from deployment..."
    json_print ""

    # Learn from this deployment
    learn_from_deployment "$service" "$target_machine"

    # Show insights
    json_print ""
    if ! is_json_output_mode; then
        show_learning_summary
    fi

    # Save deployment history
    local history_status="success"
    [ $deploy_result -ne 0 ] && history_status="failure"
    local history_id
    history_id=$(save_deployment_record "$history_status" $deploy_result)

    # Record uptime tracking events
    if command -v record_service_start >/dev/null 2>&1; then
        if [ $deploy_result -eq 0 ]; then
            record_service_start "$service" "$target_machine" "" "deployment_id=$history_id"
        else
            record_service_failure "$service" "$target_machine" "deployment_failed" "$deploy_result"
        fi
    fi

    # Set overall status and output JSON if enabled
    if is_json_output_mode; then
        if [ $deploy_result -eq 0 ]; then
            json_set_deploy_status "success"
        else
            json_set_deploy_status "failure"
        fi
        output_json_deploy
    else
        if [ $deploy_result -eq 0 ]; then
            json_print_color "$GREEN" "  ✓ Deployment completed successfully"
            json_print ""
            json_print "  Deployment ID: $history_id"
        else
            json_print_color "$RED" "  ✗ Deployment failed"
            json_print ""
            json_print "  Deployment ID: $history_id"
        fi
    fi

    return $deploy_result
}

# Execute fresh deployment
execute_fresh_deployment() {
    local service="$1"
    local target_machine="$2"
    local service_type
    service_type=$(get_service_type "$service")
    local port
    port=$(get_service_port "$service")

    if [ "$service_type" = "docker" ]; then
        if ! docker_deploy "$service" "$target_machine"; then
            return 1
        fi
    else
        if ! remote_start_service "$service" "$target_machine"; then
            return 1
        fi
    fi

    # Update registry
    update_service_host "$service" "$target_machine" > /dev/null
    local new_ip
    new_ip=$(get_machine_ip "$target_machine")
    update_service_health_url "$service" "http://$new_ip:$port/health" > /dev/null

    # Setup Caddy routing
    update_caddy_for_migration "$service" "none" "$target_machine" > /dev/null 2>&1

    # Verify DNS
    echo "  Verifying DNS resolution..."
    verify_dns_after_migration "$service" > /dev/null 2>&1

    # Update metadata
    update_service_metadata "$service"

    return 0
}

# Execute restart in place
execute_restart_deployment() {
    local service="$1"
    local target_machine="$2"
    local service_type
    service_type=$(get_service_type "$service")

    if [ "$service_type" = "docker" ]; then
        if ! docker_restart "$service" "$target_machine"; then
            return 1
        fi
    else
        if ! remote_restart_service "$service" "$target_machine"; then
            return 1
        fi
    fi

    # Update metadata
    update_service_metadata "$service"

    return 0
}

# Patch compose file with extra_hosts for central services when migrating
patch_compose_extra_hosts() {
    local compose_file="$1"
    local from_machine="$2"
    local to_machine="$3"

    if [ -z "$compose_file" ] || [ ! -f "$compose_file" ]; then
        return 0
    fi

    if ! command -v yq >/dev/null 2>&1; then
        echo "Warning: yq not available to patch extra_hosts" >&2
        return 0
    fi

    local extra_hosts=()
    local pgb_machine
    pgb_machine=$(get_service_host "pgbouncer" 2>/dev/null || true)
    local kc_machine
    kc_machine=$(get_service_host "keycloak" 2>/dev/null || true)
    local ingress_ip
    ingress_ip=$(yq eval ".dns.ingress_ip" "$CADDY_REGISTRY_PATH" 2>/dev/null)

    if [ -n "$pgb_machine" ]; then
        local pgb_ip
        pgb_ip=$(get_machine_ip "$pgb_machine" 2>/dev/null || true)
        [ -n "$pgb_ip" ] && extra_hosts+=("${PGBOUNCER_INTERNAL_HOST:-pgbouncer.internal}:${pgb_ip}")
    fi

    if [ -n "$kc_machine" ]; then
        local kc_ip
        kc_ip=$(get_machine_ip "$kc_machine" 2>/dev/null || true)
        [ -n "$kc_ip" ] && extra_hosts+=("${KEYCLOAK_INTERNAL_HOST:-keycloak.internal}:${kc_ip}")
    fi

    if [ -n "$ingress_ip" ] && [ "$ingress_ip" != "null" ]; then
        extra_hosts+=("host.docker.internal:${ingress_ip}")
    fi

    # Avoid double-patching when nothing to add
    if [ ${#extra_hosts[@]} -eq 0 ]; then
        return 0
    fi

    for host_entry in "${extra_hosts[@]}"; do
        local host_name="${host_entry%%:*}"
        local host_ip="${host_entry#*:}"
        yq eval -i ".services |= with_entries(.value.extra_hosts = ((.value.extra_hosts // []) + [\"${host_name}:${host_ip}\"]))" "$compose_file" >/dev/null 2>&1 || true
    done
}

# SC2029: $service / $remote_path are sanitized via local checks before
# being interpolated into the remote command; intentional.
# shellcheck disable=SC2029
copy_native_service_to_machine() {
    local service="$1"
    local from_machine="$2"
    local to_machine="$3"

    local service_file
    service_file=$(yq eval ".services.${service}.service_file" "$CADDY_REGISTRY_PATH")
    local from_ip
    from_ip=$(get_machine_ip "$from_machine")
    local from_user
    from_user=$(get_machine_ssh_user "$from_machine")
    local to_ip
    to_ip=$(get_machine_ip "$to_machine")
    local to_user
    to_user=$(get_machine_ssh_user "$to_machine")

    if [ -z "$from_ip" ] || [ -z "$from_user" ] || [ -z "$to_ip" ] || [ -z "$to_user" ]; then
        echo "Error: Could not get SSH info for machines" >&2
        return 1
    fi

    # Determine working dir from service.yml on source machine
    local working_dir=""
    if [ -n "$service_file" ] && [ "$service_file" != "null" ]; then
        working_dir=$(ssh "${from_user}@${from_ip}" "yq eval '.working_dir' $(printf '%q' "$service_file")" 2>/dev/null || echo "")
        if [ -z "$working_dir" ] || [ "$working_dir" = "null" ]; then
            working_dir=$(dirname "$service_file")
        fi
    else
        working_dir=$(get_service_working_dir "$service" 2>/dev/null || echo "")
    fi

    if [ -z "$working_dir" ] || [ "$working_dir" = "null" ]; then
        echo "Error: Could not determine working directory for $service" >&2
        return 1
    fi

    local target_dir="${working_dir//\/Users\/$from_user\//\/Users\/$to_user\/}"
    target_dir="${target_dir//\/home\/$from_user\//\/home\/$to_user\/}"
    local target_parent
    target_parent=$(dirname "$target_dir")

    echo "      Copying $working_dir from $from_machine to $target_dir on $to_machine..."
    if ! ssh "${to_user}@${to_ip}" "mkdir -p $(printf '%q' "$target_parent")"; then
        echo "Error: Failed to create parent directory on $to_machine" >&2
        return 1
    fi

    local temp_dir
    temp_dir=$(mktemp -d)

    if ! rsync -e ssh -avz --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' --exclude='.venv' --exclude='node_modules' \
        "${from_user}@${from_ip}:${working_dir}/" "$temp_dir/"; then
        echo "Error: Failed to rsync from $from_machine" >&2
        rm -rf "$temp_dir"
        return 1
    fi

    if ! rsync -e ssh -avz "$temp_dir/" "${to_user}@${to_ip}:${target_dir}/"; then
        echo "Error: Failed to rsync to $to_machine" >&2
        rm -rf "$temp_dir"
        return 1
    fi

    rm -rf "$temp_dir"

    # Update registry paths to point at target
    if [ -n "$service_file" ] && [ "$service_file" != "null" ]; then
        local service_filename
        service_filename=$(basename "$service_file")
        local target_service_file="${target_dir}/${service_filename}"
        yq eval -i ".services.${service}.service_file = \"${target_service_file}\"" "$CADDY_REGISTRY_PATH"
        # Patch service.yml on target to reflect new working_dir
        ssh "${to_user}@${to_ip}" "if command -v yq >/dev/null 2>&1; then yq eval -i '.working_dir = \"${target_dir}\"' $(printf '%q' "$target_service_file"); fi" >/dev/null 2>&1 || true
    fi
    yq eval -i ".services.${service}.working_dir = \"${target_dir}\"" "$CADDY_REGISTRY_PATH"

    return 0
}

# Copy service directory from source machine to target machine
# Usage: copy_service_to_machine SERVICE FROM_MACHINE TO_MACHINE
# SC2029: paths are validated/sanitized; intentional remote interpolation.
# shellcheck disable=SC2029
copy_service_to_machine() {
    local service="$1"
    local from_machine="$2"
    local to_machine="$3"
    local service_type
    service_type=$(get_service_type "$service")

    if [ "$service_type" != "docker" ]; then
        copy_native_service_to_machine "$service" "$from_machine" "$to_machine"
        return $?
    fi

    # Get service directory path (on source machine)
    local docker_compose_path
    docker_compose_path=$(yq eval ".services.${service}.docker_compose" "$CADDY_REGISTRY_PATH")
    if [ "$docker_compose_path" = "null" ] || [ -z "$docker_compose_path" ]; then
        echo "Error: No docker_compose path found for $service" >&2
        return 1
    fi

    # Extract directory from docker-compose.yml path
    local service_dir
    service_dir=$(dirname "$docker_compose_path")

    # Get SSH info for both machines
    local from_ip
    from_ip=$(get_machine_ip "$from_machine")
    local from_user
    from_user=$(get_machine_ssh_user "$from_machine")
    local to_ip
    to_ip=$(get_machine_ip "$to_machine")
    local to_user
    to_user=$(get_machine_ssh_user "$to_machine")

    if [ -z "$from_ip" ] || [ -z "$from_user" ] || [ -z "$to_ip" ] || [ -z "$to_user" ]; then
        echo "Error: Could not get SSH info for machines" >&2
        return 1
    fi

    # Determine target path (replace source user with target user in path)
    # Security: Use parameter expansion instead of sed to avoid injection
    local target_dir="${service_dir//\/Users\/$from_user\//\/Users\/$to_user\/}"
    target_dir="${target_dir//\/home\/$from_user\//\/home\/$to_user\/}"

    echo "      Copying $service_dir from $from_machine to $target_dir on $to_machine..."

    # Create parent directory on target
    # Security: Properly quote the path
    local parent_dir
    parent_dir=$(dirname "$target_dir")
    if ! ssh "${to_user}@${to_ip}" "mkdir -p $(printf '%q' "$parent_dir")"; then
        echo "Error: Failed to create parent directory on $to_machine" >&2
        return 1
    fi

    # Use rsync to copy files from source to target via current machine
    local temp_dir
    temp_dir=$(mktemp -d)

    if ! rsync -e ssh -avz --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' --exclude='node_modules' \
        "${from_user}@${from_ip}:${service_dir}/" "$temp_dir/"; then
        echo "Error: Failed to rsync from $from_machine" >&2
        rm -rf "$temp_dir"
        return 1
    fi

    # Patch compose for target networking expectations before syncing to target
    local temp_compose
    temp_compose="$temp_dir/$(basename "$docker_compose_path")"
    patch_compose_extra_hosts "$temp_compose" "$from_machine" "$to_machine"

    if ! rsync -e ssh -avz "$temp_dir/" "${to_user}@${to_ip}:${target_dir}/"; then
        echo "Error: Failed to rsync to $to_machine" >&2
        rm -rf "$temp_dir"
        return 1
    fi

    rm -rf "$temp_dir"

    # Update registry with new path
    yq eval -i ".services.${service}.docker_compose = \"${target_dir}/docker-compose.yml\"" "$CADDY_REGISTRY_PATH"

    return 0
}

# Rollback failed migration
# Usage: rollback_migration SERVICE FROM_MACHINE TO_MACHINE ORIGINAL_COMPOSE_PATH ORIGINAL_SERVICE_FILE
rollback_migration() {
    local service="$1"
    local from_machine="$2"
    local to_machine="$3"
    local original_compose_path="$4"
    local service_type
    service_type=$(get_service_type "$service")
    local original_service_file="$5"

    print_color "$YELLOW" "  Rolling back migration..."

    # 1. Stop failed deployment on target machine
    echo "    [1/4] Stopping failed deployment on $to_machine..."
    if [ "$service_type" = "docker" ]; then
        docker_stop "$service" "$to_machine" > /dev/null 2>&1
    else
        remote_stop_service "$service" "$to_machine" > /dev/null 2>&1
    fi

    # 2. Restore original registry.yml from backup
    echo "    [2/4] Restoring registry.yml from backup..."
    local registry_backup
    # shellcheck disable=SC2012  # mtime-sort needed; backup filenames are controlled (timestamped)
    registry_backup=$(ls -t "${CADDY_REGISTRY_PATH}.backup.migration."* 2>/dev/null | head -1)
    if [ -n "$registry_backup" ] && [ -f "$registry_backup" ]; then
        cp "$registry_backup" "$CADDY_REGISTRY_PATH"
        print_color "$GREEN" "      ✓ Registry restored from backup"
    else
        # Fallback to manual restoration
        update_service_host "$service" "$from_machine" > /dev/null
        if [ "$service_type" = "docker" ]; then
            yq eval -i ".services.${service}.docker_compose = \"${original_compose_path}\"" "$CADDY_REGISTRY_PATH"
        else
            yq eval -i ".services.${service}.service_file = \"${original_service_file}\"" "$CADDY_REGISTRY_PATH"
        fi
        local original_ip
        original_ip=$(get_machine_ip "$from_machine")
        local port
        port=$(get_service_port "$service")
        update_service_health_url "$service" "http://$original_ip:$port/health" > /dev/null
    fi

    # 3. Restart service on original machine
    echo "    [3/4] Restarting service on $from_machine..."
    if [ "$service_type" = "docker" ]; then
        if docker_deploy "$service" "$from_machine" > /dev/null 2>&1; then
            print_color "$GREEN" "      ✓ Service restored on $from_machine"
        else
            print_color "$RED" "      ✗ Failed to restart on $from_machine (manual intervention needed)"
        fi
    else
        if remote_start_service "$service" "$from_machine" > /dev/null 2>&1; then
            print_color "$GREEN" "      ✓ Service restored on $from_machine"
        else
            print_color "$RED" "      ✗ Failed to restart on $from_machine (manual intervention needed)"
        fi
    fi

    # 4. Regenerate and reload Caddy with original config
    echo "    [4/4] Reverting Caddy configuration..."
    update_caddy_for_migration "$service" "$to_machine" "$from_machine" > /dev/null 2>&1

    # 5. Clean up copied files on target machine (optional, commented out for safety)
    # local target_dir=$(yq eval ".services.${service}.docker_compose" "$CADDY_REGISTRY_PATH" | xargs dirname)
    # local to_user=$(get_machine_ssh_user "$to_machine")
    # local to_ip=$(get_machine_ip "$to_machine")
    # ssh "${to_user}@${to_ip}" "rm -rf '$target_dir'" 2>/dev/null

    print_color "$YELLOW" "  ✓ Rollback completed - service restored on $from_machine"
}

# Ensure images exist for target architecture before migration
# Returns JSON metadata to stdout for logging/JSON output
build_for_target_architecture() {
    local service="$1"
    local from_machine="$2"
    local to_machine="$3"
    local service_type
    service_type=$(get_service_type "$service")

    # Only applies to Docker services
    if [ "$service_type" != "docker" ]; then
        echo "{\"skipped\":true,\"reason\":\"non_docker\"}"
        return 0
    fi

    local current_arch
    current_arch=$(get_machine_arch "$from_machine" 2>/dev/null || true)
    local target_arch
    target_arch=$(get_machine_arch "$to_machine" 2>/dev/null || true)
    local target_platform
    target_platform=$(get_service_platform "$service" "$to_machine" 2>/dev/null || echo "linux/arm64")
    local build_arch="arm64"
    if [[ "$target_platform" =~ amd64 ]]; then
        build_arch="amd64"
    fi

    if [ -z "$current_arch" ] || [ -z "$target_arch" ]; then
        echo "{\"status\":\"failed\",\"reason\":\"arch_lookup_failed\"}"
        return 1
    fi

    if [ "$current_arch" = "$target_arch" ]; then
        echo "{\"skipped\":true,\"reason\":\"arch_match\",\"target_arch\":\"$target_arch\"}"
        return 0
    fi

    local compose_path
    compose_path=$(get_service_compose_file "$service")
    local service_dir
    service_dir=$(dirname "$compose_path")
    if [ ! -d "$service_dir" ]; then
        echo "{\"status\":\"failed\",\"reason\":\"service_dir_missing\",\"path\":\"$service_dir\"}"
        return 1
    fi

    local registry="${REGISTRY:-registry.portoser.local}"
    local build_target_platform="$target_platform"
    local target_tag
    target_tag=$(get_service_target_tag "$service" "$to_machine" 2>/dev/null || echo "${to_machine}-latest")
    local image_tag="${registry}/portoser/${service}:${target_tag}"
    local build_api_url="${BUILD_API_URL:-http://localhost:8080}"
    local build_api_token="${BUILD_API_TOKEN:-}"
    local build_api_ok=0
    local has_python=0
    command -v python3 >/dev/null 2>&1 && has_python=1

    # Prefer Build API if reachable and token available
    if curl -fsS --max-time 3 "$build_api_url/health" >/dev/null 2>&1 && [ -n "$build_api_token" ]; then
        build_api_ok=1
    fi

    if [ $build_api_ok -eq 1 ]; then
        local payload="{\"machine\":\"$to_machine\",\"services\":[\"$service\"],\"architectures\":[\"$build_arch\"],\"tag\":\"${target_tag}\"}"
        local create_resp
        if ! create_resp=$(curl -fsS -X POST "$build_api_url/api/v1/builds" \
            -H "X-Build-Token: $build_api_token" \
            -H "Content-Type: application/json" \
            -d "$payload"); then
            echo "{\"status\":\"failed\",\"method\":\"build_api\",\"reason\":\"create_failed\"}"
            return 1
        fi

        local build_id=""
        if [ $has_python -eq 1 ]; then
            build_id=$(printf "%s" "$create_resp" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("build_id",""))' 2>/dev/null || true)
        else
            build_id=$(printf "%s" "$create_resp" | sed -n 's/.*\"build_id\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p')
        fi

        if [ -z "$build_id" ]; then
            echo "{\"status\":\"failed\",\"method\":\"build_api\",\"reason\":\"missing_build_id\"}"
            return 1
        fi

        local status=""
        local attempts=0
        while [ $attempts -lt 180 ]; do
            local status_resp=""
            status_resp=$(curl -fsS -H "X-Build-Token: $build_api_token" "$build_api_url/api/v1/builds/$build_id/status" 2>/dev/null || true)

            if [ -n "$status_resp" ]; then
                if [ $has_python -eq 1 ]; then
                    status=$(printf "%s" "$status_resp" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)
                else
                    status=$(printf "%s" "$status_resp" | sed -n 's/.*\"status\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p')
                fi
            fi

            if [ "$status" = "completed" ]; then
                echo "{\"method\":\"build_api\",\"build_id\":\"$build_id\",\"target_arch\":\"$target_arch\",\"platform\":\"$build_target_platform\",\"image\":\"$image_tag\"}"
                return 0
            elif [ "$status" = "failed" ] || [ "$status" = "cancelled" ]; then
                echo "{\"status\":\"failed\",\"method\":\"build_api\",\"build_id\":\"$build_id\",\"reason\":\"$status\"}"
                return 1
            fi

            sleep 5
            attempts=$((attempts + 1))
        done

        echo "{\"status\":\"failed\",\"method\":\"build_api\",\"build_id\":\"$build_id\",\"reason\":\"timeout\"}"
        return 1
    fi

    # Fallback to local buildx
    if docker buildx build --platform "$build_target_platform" -t "$image_tag" --push "$service_dir"; then
        echo "{\"method\":\"buildx\",\"target_arch\":\"$target_arch\",\"platform\":\"$build_target_platform\",\"image\":\"$image_tag\"}"
        return 0
    fi

    echo "{\"status\":\"failed\",\"method\":\"buildx\",\"reason\":\"build_failed\"}"
    return 1
}

bootstrap_native_dependencies_on_target() {
    local service="$1"
    local target_machine="$2"

    local working_dir
    working_dir=$(get_service_working_dir "$service" 2>/dev/null || echo "")
    local ssh_user
    ssh_user=$(get_machine_ssh_user "$target_machine")
    local ssh_host
    ssh_host=$(get_ssh_host "$target_machine")

    if [ -z "$working_dir" ] || [ "$working_dir" = "null" ]; then
        return 0
    fi

    ssh "${ssh_user}@${ssh_host}" bash <<'EOF'
set -e
cd "$working_dir" || exit 0

if [ -f "requirements.txt" ]; then
    python3 -m venv .venv >/dev/null 2>&1 || true
    if [ -f ".venv/bin/activate" ]; then
        source .venv/bin/activate
        pip install --upgrade pip >/dev/null 2>&1 || true
        if ! pip install -r requirements.txt; then
            echo "Dependency install failed (pip)" >&2
            exit 1
        fi
    fi
fi

if [ -f "package.json" ]; then
    if command -v yarn >/dev/null 2>&1; then
        yarn install --frozen-lockfile || yarn install || { echo "Dependency install failed (yarn)" >&2; exit 1; }
    else
        npm install || { echo "Dependency install failed (npm)" >&2; exit 1; }
    fi
fi
EOF
}

# Execute migration deployment
execute_migration_deployment() {
    local service="$1"
    local from_machine="$2"
    local to_machine="$3"
    local service_type
    service_type=$(get_service_type "$service")
    local port
    port=$(get_service_port "$service")
    local from_arch
    from_arch=$(get_machine_arch "$from_machine" 2>/dev/null || echo "")
    local to_arch
    to_arch=$(get_machine_arch "$to_machine" 2>/dev/null || echo "")
    if [ "$service_type" != "docker" ] && [ -n "$from_arch" ] && [ -n "$to_arch" ] && [ "$from_arch" != "$to_arch" ]; then
        print_color "$RED" "  ✗ Arch mismatch for native/local service ($from_arch -> $to_arch). Rebuild required on target."
        return 1
    fi

    # Backup original state for rollback
    local original_compose_path
    original_compose_path=$(yq eval ".services.${service}.docker_compose" "$CADDY_REGISTRY_PATH")
    local original_service_file
    original_service_file=$(yq eval ".services.${service}.service_file" "$CADDY_REGISTRY_PATH")
    local rollback_needed=0

    # Backup registry.yml before making any changes
    local registry_backup
    registry_backup="${CADDY_REGISTRY_PATH}.backup.migration.$(date +%Y%m%d_%H%M%S)"
    cp "$CADDY_REGISTRY_PATH" "$registry_backup"
    echo "  Registry backed up to: $registry_backup"

    # Step 0: Copy service directory from source to target machine
    echo "  [1/7] Copying service files from $from_machine to $to_machine..."
    if ! copy_service_to_machine "$service" "$from_machine" "$to_machine"; then
        print_color "$RED" "      ✗ Failed to copy service files"
        return 1
    fi
    print_color "$GREEN" "      ✓ Service files copied"

    # Deploy to target
    echo "  [2/7] Deploying to $to_machine..."
    if [ "$service_type" = "docker" ]; then
        if ! docker_deploy "$service" "$to_machine"; then
            rollback_needed=1
        fi
    else
        bootstrap_native_dependencies_on_target "$service" "$to_machine"
        if ! remote_start_service "$service" "$to_machine"; then
            rollback_needed=1
        fi
    fi

    if [ $rollback_needed -eq 1 ]; then
        print_color "$RED" "      ✗ Deployment failed"
        rollback_migration "$service" "$from_machine" "$to_machine" "$original_compose_path" "$original_service_file"
        return 1
    fi

    # Update registry
    echo "  [3/7] Updating registry..."
    update_service_host "$service" "$to_machine" > /dev/null
    local new_ip
    new_ip=$(get_machine_ip "$to_machine")
    update_service_health_url "$service" "http://$new_ip:$port/health" > /dev/null

    # Health check
    echo "  [4/7] Checking health..."
    if wait_for_service_health "$service" 30 > /dev/null 2>&1; then
        print_color "$GREEN" "      ✓ Service healthy"
    else
        print_color "$YELLOW" "      ⚠ Health check failed - rolling back..."
        rollback_migration "$service" "$from_machine" "$to_machine" "$original_compose_path" "$original_service_file"
        return 1
    fi

    # Update Caddy
    echo "  [5/7] Updating Caddy routing..."
    update_caddy_for_migration "$service" "$from_machine" "$to_machine" > /dev/null 2>&1

    # Verify DNS
    echo "  [6/7] Verifying DNS resolution..."
    verify_dns_after_migration "$service" > /dev/null 2>&1

    # Stop old instance
    echo "  [7/7] Stopping old instance on $from_machine..."
    if [ "$service_type" = "docker" ]; then
        docker_stop "$service" "$from_machine" > /dev/null 2>&1
    else
        remote_stop_service "$service" "$from_machine" > /dev/null 2>&1
    fi

    # Update metadata
    update_service_metadata "$service"

    # Clean up old registry backups (keep last 10)
    # shellcheck disable=SC2012  # mtime-sort needed; backup filenames are controlled
    ls -t "${CADDY_REGISTRY_PATH}.backup.migration."* 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null

    print_color "$GREEN" "  ✓ Migration completed successfully"
    return 0
}

# Dry-run mode for deployment
# Usage: intelligent_deploy_dryrun SERVICE TARGET_MACHINE
intelligent_deploy_dryrun() {
    local service="$1"
    local target_machine="$2"

    print_color "$YELLOW" "🔍 DRY RUN MODE - No changes will be made"
    echo ""

    # Run observations
    observe_print INFO "Observing deployment environment..."
    echo ""

    OBSERVATION_RESULTS=()
    observe_deployment_readiness "$service" "$target_machine"

    echo ""

    # Run diagnostics
    diagnose_print INFO "Analyzing potential issues..."
    echo ""

    # Reset cross-module state arrays defined in analyzer.sh.
    # shellcheck disable=SC2034 # cleared here, populated by sourced analyzer.sh
    IDENTIFIED_PROBLEMS=()
    # shellcheck disable=SC2034
    ROOT_CAUSES=()
    diagnose_deployment_issues "$service" "$target_machine"

    echo ""

    # Show what would be done
    local problems
    problems=$(get_identified_problems)
    if [ -n "$problems" ]; then
        solve_print INFO "Would attempt to solve these problems:"
        for fingerprint in $problems; do
            local pattern
            pattern=$(get_solution_pattern "$fingerprint")
            echo "  - $fingerprint → $pattern"
        done
    else
        solve_print SUCCESS "No problems detected - deployment should succeed"
    fi

    echo ""
    print_color "$YELLOW" "DRY RUN COMPLETE - Use without --dry-run to execute"
}
