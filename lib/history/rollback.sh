#!/usr/bin/env bash
# rollback.sh - Deployment rollback capabilities

set -euo pipefail
# Rollback to a previous deployment configuration

# Rollback to a previous deployment
# Usage: rollback_deployment DEPLOYMENT_ID [--force]
rollback_deployment() {
    local deployment_id="$1"
    local force_flag="${2:-}"

    json_print_color "$BLUE" "Rollback: Loading deployment $deployment_id..."
    json_print ""

    # Load deployment record
    local record
    record=$(get_deployment_details "$deployment_id" true 2>/dev/null)

    if [ -z "$record" ]; then
        json_print_color "$RED" "Error: Deployment $deployment_id not found"
        return 1
    fi

    # Extract deployment details
    local service
    service=$(echo "$record" | grep -o '"service"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    local machine
    machine=$(echo "$record" | grep -o '"machine"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    local action
    action=$(echo "$record" | grep -o '"action"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    local deployment_status
    deployment_status=$(echo "$record" | grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)

    if [ "$deployment_status" != "success" ]; then
        json_print_color "$RED" "Error: Cannot rollback to a failed deployment"
        json_print_color "$YELLOW" "Deployment status: $deployment_status"
        return 1
    fi

    json_print "  Service: $service"
    json_print "  Machine: $machine"
    json_print "  Action: $action"
    json_print "  Status: $deployment_status"
    json_print ""

    # Extract config snapshot
    local config_snapshot
    config_snapshot=$(echo "$record" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    config = data.get('config_snapshot', {})
    print(json.dumps(config, indent=2))
except:
    print('{}')
" 2>/dev/null || echo "{}")

    if [ "$config_snapshot" = "{}" ]; then
        json_print_color "$RED" "Error: No configuration snapshot found in deployment record"
        return 1
    fi

    # Get current configuration
    local registry_path="${CADDY_REGISTRY_PATH:-${HOME}/portoser/registry.yml}"
    local current_config=""

    if command -v yq &> /dev/null; then
        current_config=$(yq eval ".services.\"$service\"" "$registry_path" -o=json 2>/dev/null || echo "{}")
    elif command -v python3 &> /dev/null; then
        current_config=$(python3 -c "
import yaml, json
try:
    with open('$registry_path', 'r') as f:
        data = yaml.safe_load(f)
        service_config = data.get('services', {}).get('$service', {})
        print(json.dumps(service_config))
except:
    print('{}')
" 2>/dev/null || echo "{}")
    fi

    # Show diff
    json_print_color "$BLUE" "Configuration Comparison:"
    json_print ""
    json_print "Current Configuration:"
    echo "$current_config" | python3 -m json.tool 2>/dev/null || echo "$current_config"
    json_print ""
    json_print "Target Configuration (from $deployment_id):"
    echo "$config_snapshot" | python3 -m json.tool 2>/dev/null || echo "$config_snapshot"
    json_print ""

    # Check if configs are the same
    local configs_match
    configs_match=$(python3 -c "
import json
current = json.loads('''$current_config''')
target = json.loads('''$config_snapshot''')
print('true' if current == target else 'false')
" 2>/dev/null || echo "false")

    if [ "$configs_match" = "true" ]; then
        json_print_color "$YELLOW" "Notice: Current configuration matches target - no changes needed"
        json_print_color "$YELLOW" "Will restart service to ensure consistency"
        json_print ""
    fi

    # Confirm unless forced
    if [ "$force_flag" != "--force" ] && [ "$force_flag" != "-f" ]; then
        json_print_color "$YELLOW" "⚠️  ROLLBACK CONFIRMATION REQUIRED"
        json_print ""
        json_print "This will:"
        json_print "  1. Update registry.yml with the old configuration"
        json_print "  2. Re-deploy $service to $machine"
        json_print "  3. Create a rollback record in history"
        json_print ""
        read -r -p "Type 'yes' to proceed: " confirm

        if [ "$confirm" != "yes" ]; then
            json_print_color "$YELLOW" "Rollback cancelled"
            return 1
        fi
    fi

    json_print ""
    json_print_color "$BLUE" "Executing Rollback..."
    json_print ""

    # Update registry with old configuration
    json_print "  [1/4] Updating registry with previous configuration..."

    if command -v python3 &> /dev/null; then
        if ! python3 <<EOF
import yaml, json

# Load registry
with open('$registry_path', 'r') as f:
    registry = yaml.safe_load(f)

# Load target config
target_config = json.loads('''$config_snapshot''')

# Update service config
if 'services' not in registry:
    registry['services'] = {}

registry['services']['$service'] = target_config

# Save registry (backup first)
import shutil
from datetime import datetime
backup_path = '$registry_path.rollback-backup.' + datetime.now().strftime('%Y%m%d_%H%M%S')
shutil.copy('$registry_path', backup_path)

with open('$registry_path', 'w') as f:
    yaml.dump(registry, f, default_flow_style=False, sort_keys=False)

print("Registry updated successfully")
EOF
        then
            json_print_color "$RED" "  ✗ Failed to update registry"
            return 1
        fi
    else
        json_print_color "$RED" "  ✗ Python3 required for rollback"
        return 1
    fi

    json_print_color "$GREEN" "  ✓ Registry updated"
    json_print ""

    # Re-deploy service
    json_print "  [2/4] Re-deploying service with previous configuration..."

    # Use intelligent deploy with the old config
    if intelligent_deploy_service "$service" "$machine" "--auto-heal"; then
        json_print_color "$GREEN" "  ✓ Service re-deployed successfully"
    else
        json_print_color "$RED" "  ✗ Service re-deployment failed"
        json_print_color "$YELLOW" "  Attempting to restore registry from backup..."

        # Try to restore from backup
        local backup_file
        # shellcheck disable=SC2012  # mtime-sort needed; backup filenames are controlled (timestamped)
        backup_file=$(ls -t "${registry_path}.rollback-backup."* 2>/dev/null | head -1)
        if [ -n "$backup_file" ]; then
            cp "$backup_file" "$registry_path"
            json_print_color "$YELLOW" "  Registry restored from backup"
        fi

        return 1
    fi

    json_print ""

    # Verify deployment
    json_print "  [3/4] Verifying deployment..."

    sleep 2

    if wait_for_service_health "$service" 30 > /dev/null 2>&1; then
        json_print_color "$GREEN" "  ✓ Service is healthy"
    else
        json_print_color "$YELLOW" "  ⚠ Health check inconclusive, but rollback completed"
    fi

    json_print ""

    # Create rollback record
    json_print "  [4/4] Creating rollback record..."

    # Initialize tracking for rollback
    init_deployment_tracking "$service" "$machine" "rollback"
    track_observation "rollback" "Rolled back to deployment $deployment_id" "info"

    # Save with rolled_back status
    local rollback_id
    rollback_id=$(save_deployment_record "rolled_back" 0)

    json_print_color "$GREEN" "  ✓ Rollback record created: $rollback_id"
    json_print ""

    json_print_color "$GREEN" "✓ Rollback completed successfully!"
    json_print ""
    json_print "  Rolled back to: $deployment_id"
    json_print "  Rollback ID: $rollback_id"

    return 0
}

# Preview rollback changes
# Usage: preview_rollback DEPLOYMENT_ID
preview_rollback() {
    local deployment_id="$1"

    json_print_color "$BLUE" "Rollback Preview: $deployment_id"
    json_print ""

    # Load deployment record
    local record
    record=$(get_deployment_details "$deployment_id" true 2>/dev/null)

    if [ -z "$record" ]; then
        json_print_color "$RED" "Error: Deployment $deployment_id not found"
        return 1
    fi

    # Extract deployment details
    local service
    service=$(echo "$record" | grep -o '"service"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    local machine
    machine=$(echo "$record" | grep -o '"machine"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    local timestamp
    timestamp=$(echo "$record" | grep -o '"timestamp"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    local deployment_status
    deployment_status=$(echo "$record" | grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)

    json_print "Deployment Information:"
    json_print "  ID: $deployment_id"
    json_print "  Service: $service"
    json_print "  Machine: $machine"
    json_print "  Timestamp: $timestamp"
    json_print "  Status: $deployment_status"
    json_print ""

    if [ "$deployment_status" != "success" ]; then
        json_print_color "$RED" "⚠️  Warning: This deployment was not successful"
        json_print_color "$RED" "Cannot rollback to a failed deployment"
        return 1
    fi

    # Extract config snapshot
    local config_snapshot
    config_snapshot=$(echo "$record" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    config = data.get('config_snapshot', {})
    print(json.dumps(config, indent=2))
except:
    print('{}')
" 2>/dev/null || echo "{}")

    # Get current configuration
    local registry_path="${CADDY_REGISTRY_PATH:-${HOME}/portoser/registry.yml}"
    local current_config=""

    if command -v python3 &> /dev/null; then
        current_config=$(python3 -c "
import yaml, json
try:
    with open('$registry_path', 'r') as f:
        data = yaml.safe_load(f)
        service_config = data.get('services', {}).get('$service', {})
        print(json.dumps(service_config, indent=2))
except:
    print('{}')
" 2>/dev/null || echo "{}")
    fi

    # Show diff using Python
    json_print_color "$BLUE" "Configuration Changes:"
    json_print ""

    python3 <<EOF
import json
from difflib import unified_diff

current = json.loads('''$current_config''')
target = json.loads('''$config_snapshot''')

# Pretty print configs
current_str = json.dumps(current, indent=2, sort_keys=True)
target_str = json.dumps(target, indent=2, sort_keys=True)

print("CURRENT → TARGET")
print("")

# Show diff
diff = list(unified_diff(
    current_str.splitlines(keepends=True),
    target_str.splitlines(keepends=True),
    fromfile='Current Configuration',
    tofile='Target Configuration (from rollback)',
    lineterm=''
))

if not diff:
    print("No changes - configurations are identical")
else:
    for line in diff:
        print(line, end='')
        if not line.endswith('\n'):
            print()

print()
EOF

    json_print ""
    json_print_color "$YELLOW" "Rollback Actions:"
    json_print "  1. Update registry.yml with target configuration"
    json_print "  2. Re-deploy $service to $machine"
    json_print "  3. Wait for health check"
    json_print "  4. Create rollback record"
    json_print ""
    json_print "To execute: portoser history rollback $deployment_id"
    json_print "To force without confirmation: portoser history rollback $deployment_id --force"

    return 0
}

# Compare two deployments
# Usage: compare_deployments DEPLOYMENT_ID_1 DEPLOYMENT_ID_2
compare_deployments() {
    local id1="$1"
    local id2="$2"

    local record1
    record1=$(get_deployment_details "$id1" true 2>/dev/null)
    local record2
    record2=$(get_deployment_details "$id2" true 2>/dev/null)

    if [ -z "$record1" ] || [ -z "$record2" ]; then
        json_print_color "$RED" "Error: One or both deployments not found"
        return 1
    fi

    json_print_color "$BLUE" "Comparing Deployments:"
    json_print ""
    json_print "  $id1"
    json_print "  vs"
    json_print "  $id2"
    json_print ""

    # Extract and compare configs
    python3 <<EOF
import json
from difflib import unified_diff

record1 = json.loads('''$record1''')
record2 = json.loads('''$record2''')

config1 = record1.get('config_snapshot', {})
config2 = record2.get('config_snapshot', {})

config1_str = json.dumps(config1, indent=2, sort_keys=True)
config2_str = json.dumps(config2, indent=2, sort_keys=True)

print("Configuration Differences:")
print()

diff = list(unified_diff(
    config1_str.splitlines(keepends=True),
    config2_str.splitlines(keepends=True),
    fromfile=f"{record1['id']} ({record1['timestamp']})",
    tofile=f"{record2['id']} ({record2['timestamp']})",
    lineterm=''
))

if not diff:
    print("No differences - configurations are identical")
else:
    for line in diff:
        print(line, end='')
        if not line.endswith('\n'):
            print()

print()
print(f"Deployment 1: {record1['service']} on {record1['machine']} - {record1['status']}")
print(f"Deployment 2: {record2['service']} on {record2['machine']} - {record2['status']}")
EOF

    return 0
}
