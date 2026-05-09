#!/usr/bin/env bash
# tracker.sh - Deployment history tracking

set -euo pipefail
# Saves deployment records to ~/.portoser/deployments/

# Global deployment tracking variables
DEPLOYMENT_ID=""
DEPLOYMENT_START_TIME=""
DEPLOYMENT_SERVICE=""
DEPLOYMENT_MACHINE=""
DEPLOYMENT_ACTION=""
DEPLOYMENT_PHASES=()
DEPLOYMENT_OBSERVATIONS=()
DEPLOYMENT_PROBLEMS=()
DEPLOYMENT_SOLUTIONS=()
DEPLOYMENT_CONFIG_SNAPSHOT=""

# Initialize deployment history
# Usage: init_deployment_tracking SERVICE MACHINE ACTION
init_deployment_tracking() {
    local service="$1"
    local machine="$2"
    local action="$3"  # deploy, restart, migrate

    # Generate unique ID (fallback if uuidgen not available)
    local uuid_part
    if command -v uuidgen >/dev/null 2>&1; then
        uuid_part=$(uuidgen | cut -d'-' -f1)
    else
        # Fallback: generate random hex string (with error handling)
        uuid_part=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c 8 || date +%s)
    fi
    DEPLOYMENT_ID="deploy-$(date +%Y%m%d-%H%M%S)-${uuid_part}"
    DEPLOYMENT_START_TIME=$(date +%s%3N)
    DEPLOYMENT_SERVICE="$service"
    DEPLOYMENT_MACHINE="$machine"
    DEPLOYMENT_ACTION="$action"

    # Clear tracking arrays
    DEPLOYMENT_PHASES=()
    DEPLOYMENT_OBSERVATIONS=()
    DEPLOYMENT_PROBLEMS=()
    DEPLOYMENT_SOLUTIONS=()

    # Capture config snapshot
    capture_config_snapshot "$service"
}

# Capture configuration snapshot from registry
capture_config_snapshot() {
    local service="$1"
    local registry_path="${CADDY_REGISTRY_PATH:-${HOME}/portoser/registry.yml}"

    if [ ! -f "$registry_path" ]; then
        DEPLOYMENT_CONFIG_SNAPSHOT="{}"
        return
    fi

    # Extract service config using yq or python
    if command -v yq &> /dev/null; then
        local config
        config=$(yq eval ".services.\"$service\"" "$registry_path" -o=json 2>/dev/null || echo "{}")
        DEPLOYMENT_CONFIG_SNAPSHOT="$config"
    elif command -v python3 &> /dev/null; then
        DEPLOYMENT_CONFIG_SNAPSHOT=$(python3 -c "
import yaml, json, sys
try:
    with open('$registry_path', 'r') as f:
        data = yaml.safe_load(f)
        service_config = data.get('services', {}).get('$service', {})
        print(json.dumps(service_config))
except:
    print('{}')
" 2>/dev/null || echo "{}")
    else
        DEPLOYMENT_CONFIG_SNAPSHOT="{}"
    fi
}

# Add phase to tracking
# Usage: track_deployment_phase PHASE_NAME STATUS DURATION_MS METADATA
track_deployment_phase() {
    local phase_name="$1"
    local phase_status="$2"
    local duration_ms="$3"
    local metadata="${4:-{}}"

    local phase_json="{\"name\":\"$phase_name\",\"status\":\"$phase_status\",\"duration_ms\":$duration_ms,\"metadata\":$metadata}"
    DEPLOYMENT_PHASES+=("$phase_json")
}

# Add observation to tracking
# Usage: track_observation TYPE MESSAGE SEVERITY
track_observation() {
    local type="$1"
    local message="$2"
    local severity="${3:-info}"

    # Escape quotes in message
    message="${message//\"/\\\"}"

    local obs_json
    obs_json="{\"type\":\"$type\",\"message\":\"$message\",\"severity\":\"$severity\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
    DEPLOYMENT_OBSERVATIONS+=("$obs_json")
}

# Add problem to tracking
# Usage: track_problem FINGERPRINT DESCRIPTION
track_problem() {
    local fingerprint="$1"
    local description="$2"

    # Escape quotes
    description="${description//\"/\\\"}"

    local prob_json
    prob_json="{\"fingerprint\":\"$fingerprint\",\"description\":\"$description\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
    DEPLOYMENT_PROBLEMS+=("$prob_json")
}

# Add solution to tracking
# Usage: track_solution FINGERPRINT ACTION RESULT
track_solution() {
    local fingerprint="$1"
    local action="$2"
    local result="$3"

    # Escape quotes
    action="${action//\"/\\\"}"
    result="${result//\"/\\\"}"

    local sol_json
    sol_json="{\"fingerprint\":\"$fingerprint\",\"action\":\"$action\",\"result\":\"$result\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
    DEPLOYMENT_SOLUTIONS+=("$sol_json")
}

# Save deployment record
# Usage: save_deployment_record STATUS EXIT_CODE
save_deployment_record() {
    local deployment_status="$1"  # success, failure, rolled_back
    local exit_code="${2:-0}"

    # Calculate duration
    local end_time
    end_time=$(date +%s%3N)
    local duration_ms
    duration_ms=$((end_time - DEPLOYMENT_START_TIME))

    # Create deployment record directory
    local date_dir
    date_dir=$(date +%Y-%m-%d)
    local history_dir="$HOME/.portoser/deployments/$date_dir"
    mkdir -p "$history_dir"

    # Create filename
    local timestamp
    timestamp=$(date +%H%M%S)
    local filename="${DEPLOYMENT_SERVICE}-${DEPLOYMENT_MACHINE}-${timestamp}.json"
    local filepath="$history_dir/$filename"

    # Build phases array
    local phases_array="["
    local first_phase=true
    for phase in "${DEPLOYMENT_PHASES[@]}"; do
        if [ "$first_phase" = true ]; then
            first_phase=false
        else
            phases_array+=","
        fi
        phases_array+="$phase"
    done
    phases_array+="]"

    # Build observations array
    local obs_array="["
    local first_obs=true
    for obs in "${DEPLOYMENT_OBSERVATIONS[@]}"; do
        if [ "$first_obs" = true ]; then
            first_obs=false
        else
            obs_array+=","
        fi
        obs_array+="$obs"
    done
    obs_array+="]"

    # Build problems array
    local prob_array="["
    local first_prob=true
    for prob in "${DEPLOYMENT_PROBLEMS[@]}"; do
        if [ "$first_prob" = true ]; then
            first_prob=false
        else
            prob_array+=","
        fi
        prob_array+="$prob"
    done
    prob_array+="]"

    # Build solutions array
    local sol_array="["
    local first_sol=true
    for sol in "${DEPLOYMENT_SOLUTIONS[@]}"; do
        if [ "$first_sol" = true ]; then
            first_sol=false
        else
            sol_array+=","
        fi
        sol_array+="$sol"
    done
    sol_array+="]"

    # Create deployment record
    local record record_ts
    record_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    record="{
  \"id\": \"$DEPLOYMENT_ID\",
  \"timestamp\": \"$record_ts\",
  \"service\": \"$DEPLOYMENT_SERVICE\",
  \"machine\": \"$DEPLOYMENT_MACHINE\",
  \"action\": \"$DEPLOYMENT_ACTION\",
  \"status\": \"$deployment_status\",
  \"duration_ms\": $duration_ms,
  \"phases\": $phases_array,
  \"observations\": $obs_array,
  \"problems\": $prob_array,
  \"solutions_applied\": $sol_array,
  \"config_snapshot\": $DEPLOYMENT_CONFIG_SNAPSHOT,
  \"exit_code\": $exit_code
}"

    # Save to file
    echo "$record" > "$filepath"

    # Also save to latest link
    ln -sf "$filepath" "$HOME/.portoser/deployments/latest.json"

    # Log save location
    if ! is_json_output_mode; then
        echo "  Deployment record saved: $filepath"
    fi

    # Return deployment ID for reference
    echo "$DEPLOYMENT_ID"
}

# List deployment history
# Usage: list_deployment_history [SERVICE] [LIMIT]
list_deployment_history() {
    local service_filter="${1:-}"
    local limit="${2:-50}"
    local json_output="${3:-false}"

    local history_base="$HOME/.portoser/deployments"

    if [ ! -d "$history_base" ]; then
        if [ "$json_output" = "true" ]; then
            echo '{"deployments":[],"total":0}'
        else
            echo "No deployment history found"
        fi
        return 0
    fi

    # Find all deployment records (sorted by modification time, newest first)
    local records=()
    while IFS= read -r file; do
        records+=("$file")
    done < <(find "$history_base" -name "*.json" -not -name "latest.json" -type f -print0 | xargs -0 ls -t 2>/dev/null || true)

    # Filter by service if specified
    local filtered_records=()
    for record in "${records[@]}"; do
        if [ -n "$service_filter" ]; then
            # Check if service matches
            local record_service
            record_service=$(grep -o '"service"[[:space:]]*:[[:space:]]*"[^"]*"' "$record" 2>/dev/null | cut -d'"' -f4)
            if [ "$record_service" = "$service_filter" ]; then
                filtered_records+=("$record")
            fi
        else
            filtered_records+=("$record")
        fi
    done

    # Limit results
    local display_records=("${filtered_records[@]:0:$limit}")

    if [ "$json_output" = "true" ]; then
        # Output as JSON array
        echo -n '{"deployments":['
        local first=true
        for record in "${display_records[@]}"; do
            if [ "$first" = true ]; then
                first=false
            else
                echo -n ","
            fi
            cat "$record"
        done
        echo "],"
        echo "\"total\":${#display_records[@]},"
        echo "\"filtered\":${#filtered_records[@]},"
        echo "\"service_filter\":\"$service_filter\""
        echo "}"
    else
        # Human-readable output
        echo "Recent Deployments (showing ${#display_records[@]} of ${#filtered_records[@]}):"
        echo ""

        for record in "${display_records[@]}"; do
            local id
            id=$(grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' "$record" | cut -d'"' -f4)
            local timestamp
            timestamp=$(grep -o '"timestamp"[[:space:]]*:[[:space:]]*"[^"]*"' "$record" | cut -d'"' -f4)
            local svc
            # head -1 throughout: deployment records have nested phase
            # objects that carry their own status/duration_ms, and grep
            # returns one match per occurrence. We want only the top-level
            # field's value.
            svc=$(grep -o '"service"[[:space:]]*:[[:space:]]*"[^"]*"' "$record" | head -1 | cut -d'"' -f4)
            local mach
            mach=$(grep -o '"machine"[[:space:]]*:[[:space:]]*"[^"]*"' "$record" | head -1 | cut -d'"' -f4)
            local st
            st=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$record" | head -1 | cut -d'"' -f4)
            local act
            act=$(grep -o '"action"[[:space:]]*:[[:space:]]*"[^"]*"' "$record" | head -1 | cut -d'"' -f4)

            # Color code status
            local status_display="$st"
            if [ "$st" = "success" ]; then
                status_display="\033[32m✓ $st\033[0m"
            elif [ "$st" = "failure" ]; then
                status_display="\033[31m✗ $st\033[0m"
            elif [ "$st" = "rolled_back" ]; then
                status_display="\033[33m⟲ $st\033[0m"
            fi

            echo -e "  $id"
            echo -e "    $timestamp | $svc → $mach | $act | $status_display"
            echo ""
        done
    fi
}

# Get specific deployment details
# Usage: get_deployment_details DEPLOYMENT_ID [--json-output]
get_deployment_details() {
    local deployment_id="$1"
    local json_output="${2:-false}"

    local history_base="$HOME/.portoser/deployments"

    if [ ! -d "$history_base" ]; then
        echo "Error: No deployment history found" >&2
        return 1
    fi

    # Find the deployment record
    local record_file=""
    while IFS= read -r file; do
        local id
        id=$(grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' "$file" 2>/dev/null | cut -d'"' -f4)
        if [ "$id" = "$deployment_id" ]; then
            record_file="$file"
            break
        fi
    done < <(find "$history_base" -name "*.json" -not -name "latest.json" -type f 2>/dev/null || true)

    if [ -z "$record_file" ]; then
        echo "Error: Deployment $deployment_id not found" >&2
        return 1
    fi

    if [ "$json_output" = "true" ] || [ "$json_output" = "--json-output" ]; then
        cat "$record_file"
    else
        # Pretty print JSON
        if command -v jq &> /dev/null; then
            jq . "$record_file"
        elif command -v python3 &> /dev/null; then
            python3 -m json.tool "$record_file"
        else
            cat "$record_file"
        fi
    fi
}

# Clean old deployment records (keep last N or last X days)
# Usage: cleanup_old_deployments [KEEP_COUNT] [KEEP_DAYS]
cleanup_old_deployments() {
    local keep_count="${1:-1000}"
    local keep_days="${2:-90}"

    local history_base="$HOME/.portoser/deployments"

    if [ ! -d "$history_base" ]; then
        return 0
    fi

    # Find all deployment records
    local all_records=()
    while IFS= read -r file; do
        all_records+=("$file")
    done < <(find "$history_base" -name "*.json" -not -name "latest.json" -type f -print0 | xargs -0 ls -t 2>/dev/null || true)

    local total_count=${#all_records[@]}

    # Delete old records by count
    if [ "$total_count" -gt "$keep_count" ]; then
        local to_delete_count
        to_delete_count=$((total_count - keep_count))
        local records_to_delete=("${all_records[@]:$keep_count}")

        for record in "${records_to_delete[@]}"; do
            rm -f "$record"
        done

        echo "Deleted $to_delete_count old deployment records (keeping last $keep_count)"
    fi

    # Delete records older than X days
    find "$history_base" -name "*.json" -not -name "latest.json" -type f -mtime "+$keep_days" -delete 2>/dev/null || true

    # Clean empty date directories
    find "$history_base" -type d -empty -delete 2>/dev/null || true
}

# Get deployment statistics
# Usage: get_deployment_stats [SERVICE] [DAYS]
get_deployment_stats() {
    local service_filter="${1:-}"
    local days="${2:-30}"

    local history_base="$HOME/.portoser/deployments"

    if [ ! -d "$history_base" ]; then
        echo '{"total":0,"success":0,"failure":0,"success_rate":0}'
        return 0
    fi

    # Find recent records
    local records=()
    while IFS= read -r file; do
        records+=("$file")
    done < <(find "$history_base" -name "*.json" -not -name "latest.json" -type f -mtime "-$days" 2>/dev/null || true)

    local total=0
    local success=0
    local failure=0
    local rolled_back=0
    local total_duration=0

    for record in "${records[@]}"; do
        # Filter by service if specified. head -1 because record
        # JSON has nested phase objects that may carry the same field name.
        if [ -n "$service_filter" ]; then
            local svc
            svc=$(grep -o '"service"[[:space:]]*:[[:space:]]*"[^"]*"' "$record" | head -1 | cut -d'"' -f4)
            if [ "$svc" != "$service_filter" ]; then
                continue
            fi
        fi

        total=$((total + 1))

        local record_status
        record_status=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$record" | head -1 | cut -d'"' -f4)
        if [ "$record_status" = "success" ]; then
            success=$((success + 1))
        elif [ "$record_status" = "failure" ]; then
            failure=$((failure + 1))
        elif [ "$record_status" = "rolled_back" ]; then
            rolled_back=$((rolled_back + 1))
        fi

        # head -1 because deployment records have nested phase objects that
        # also carry their own duration_ms; without this the grep returns
        # multiple values and bash arithmetic chokes with a syntax error.
        local duration
        duration=$(grep -o '"duration_ms"[[:space:]]*:[[:space:]]*[0-9]*' "$record" \
            | head -1 \
            | grep -o '[0-9]*$')
        if [ -n "$duration" ]; then
            total_duration=$((total_duration + duration))
        fi
    done

    local success_rate=0
    local avg_duration=0

    if [ $total -gt 0 ]; then
        success_rate=$(awk "BEGIN {printf \"%.2f\", ($success / $total) * 100}")
        avg_duration=$((total_duration / total))
    fi

    echo "{\"total\":$total,\"success\":$success,\"failure\":$failure,\"rolled_back\":$rolled_back,\"success_rate\":$success_rate,\"avg_duration_ms\":$avg_duration,\"days\":$days}"
}
