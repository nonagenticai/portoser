#!/usr/bin/env bash
# keycloak.sh - Keycloak client and service account management

set -euo pipefail

# Get Keycloak admin credentials from environment or prompt
get_keycloak_admin_token() {
    local keycloak_url="${KEYCLOAK_URL:-https://keycloak.example.local}"
    local admin_user="${KEYCLOAK_ADMIN_USER:-admin}"
    local admin_pass="${KEYCLOAK_ADMIN_PASSWORD}"

    if [ -z "$admin_pass" ]; then
        echo "Error: KEYCLOAK_ADMIN_PASSWORD not set" >&2
        echo "Set it in environment or .env file" >&2
        return 1
    fi

    # Get access token
    local response
    response=$(curl -s -X POST "${keycloak_url}/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "username=${admin_user}" \
        --data-urlencode "password=${admin_pass}" \
        -d 'grant_type=password' \
        -d 'client_id=admin-cli')

    local token
    token=$(echo "$response" | jq -r '.access_token // empty' 2>/dev/null)

    if [ -z "$token" ]; then
        echo "Error: Failed to get Keycloak admin token" >&2
        local error_msg
        error_msg=$(echo "$response" | jq -r '.error_description // .error // "Unknown error"' 2>/dev/null || echo "$response")
        echo "$error_msg" >&2
        return 1
    fi

    echo "$token"
}

# Create Keycloak client for a service
# Usage: create_keycloak_client SERVICE_NAME REALM [CLIENT_TYPE]
create_keycloak_client() {
    local service_name="$1"
    local realm="${2:-secure-apps}"
    local client_type="${3:-confidential}"  # confidential or public

    if [ -z "$service_name" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    local keycloak_url="${KEYCLOAK_URL:-https://keycloak.example.local}"
    local client_id="${service_name}"

    echo "Creating Keycloak client: $client_id in realm $realm..."

    # Get admin token
    local token
    if ! token=$(get_keycloak_admin_token); then
        return 1
    fi

    # Check if client already exists
    local existing
    existing=$(curl -s -X GET "${keycloak_url}/admin/realms/${realm}/clients" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" | \
        jq -r ".[] | select(.clientId == \"${client_id}\") | .id")

    if [ -n "$existing" ] && [ "$existing" != "null" ]; then
        echo "Client $client_id already exists (ID: $existing)"
        echo "Client URL: ${keycloak_url}/admin/master/console/#/${realm}/clients/${existing}"
        return 0
    fi

    # Create client. The public/confidential distinction comes from $client_type:
    # public clients have no client secret and serviceAccounts can't be enabled.
    local public_client="false"
    local service_accounts="true"
    if [ "$client_type" = "public" ]; then
        public_client="true"
        service_accounts="false"
    fi

    local client_data
    client_data=$(jq -n \
        --arg clientId "$client_id" \
        --arg name "$service_name" \
        --arg desc "Service account for $service_name" \
        --argjson publicClient "$public_client" \
        --argjson serviceAccounts "$service_accounts" \
        '{
          clientId: $clientId,
          name: $name,
          description: $desc,
          enabled: true,
          publicClient: $publicClient,
          serviceAccountsEnabled: $serviceAccounts,
          directAccessGrantsEnabled: false,
          standardFlowEnabled: false,
          implicitFlowEnabled: false,
          protocol: "openid-connect"
        }')

    local response
    response=$(curl -s -w "\n%{http_code}" -X POST "${keycloak_url}/admin/realms/${realm}/clients" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "$client_data")

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | head -n -1)

    if [ "$http_code" = "201" ]; then
        echo "✓ Client created successfully"

        # Get the client ID (UUID)
        local client_uuid
        client_uuid=$(curl -s -X GET "${keycloak_url}/admin/realms/${realm}/clients" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" | \
            jq -r ".[] | select(.clientId == \"${client_id}\") | .id")

        # Get client secret
        local secret
        secret=$(curl -s -X GET "${keycloak_url}/admin/realms/${realm}/clients/${client_uuid}/client-secret" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" | \
            jq -r '.value')

        echo "" >&2
        echo "Client Configuration:" >&2
        echo "  Client ID: $client_id" >&2
        echo "  Client Secret: [REDACTED - saved to secure location]" >&2
        echo "  Realm: $realm" >&2
        echo "  Service Account: Enabled" >&2
        echo "" >&2
        echo "IMPORTANT: Client secret has been generated but not displayed for security." >&2
        echo "Retrieve the secret using: portoser keycloak get-secret $client_id" >&2
        echo "" >&2
        echo "Add to service .env file:" >&2
        echo "  KEYCLOAK_CLIENT_ID=$client_id" >&2
        echo "  KEYCLOAK_CLIENT_SECRET=<use get-secret command>" >&2
        echo "  KEYCLOAK_REALM=$realm" >&2
        echo "  KEYCLOAK_URL=$keycloak_url" >&2

        return 0
    else
        echo "✗ Failed to create client (HTTP $http_code)" >&2
        echo "$body" | jq -r '.error_description // .error // .' >&2
        return 1
    fi
}

# List Keycloak clients in a realm
# Usage: list_keycloak_clients [REALM]
list_keycloak_clients() {
    local realm="${1:-secure-apps}"
    local keycloak_url="${KEYCLOAK_URL:-https://keycloak.example.local}"

    echo "Keycloak clients in realm: $realm"
    echo ""

    local token
    if ! token=$(get_keycloak_admin_token); then
        return 1
    fi

    curl -s -X GET "${keycloak_url}/admin/realms/${realm}/clients" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" | \
        jq -r '.[] | select(.clientId | startswith("system-") or . == "admin-cli" or . == "account" or . == "broker" or . == "realm-management" | not) | "\(.clientId)\t\(.enabled)\t\(.serviceAccountsEnabled)"' | \
        awk 'BEGIN {print "CLIENT_ID\t\t\tENABLED\tSERVICE_ACCOUNT"} {print}'
}

# Get client secret
# Usage: get_client_secret CLIENT_ID [REALM]
get_client_secret() {
    local client_id="$1"
    local realm="${2:-secure-apps}"
    local keycloak_url="${KEYCLOAK_URL:-https://keycloak.example.local}"

    if [ -z "$client_id" ]; then
        echo "Error: Client ID required" >&2
        return 1
    fi

    local token
    if ! token=$(get_keycloak_admin_token); then
        return 1
    fi

    # Get client UUID
    local client_uuid
    client_uuid=$(curl -s -X GET "${keycloak_url}/admin/realms/${realm}/clients" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" | \
        jq -r ".[] | select(.clientId == \"${client_id}\") | .id")

    if [ -z "$client_uuid" ] || [ "$client_uuid" = "null" ]; then
        echo "Error: Client $client_id not found in realm $realm" >&2
        return 1
    fi

    # Get client secret
    local secret
    secret=$(curl -s -X GET "${keycloak_url}/admin/realms/${realm}/clients/${client_uuid}/client-secret" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" | \
        jq -r '.value')

    echo "Client: $client_id" >&2
    echo "Secret: [length: ${#secret} chars]" >&2
    echo "" >&2
    echo "SECURITY: Secret not displayed. Use this value in .env files only." >&2
}

# Create Keycloak clients for all services that need them
# Usage: create_all_keycloak_clients
create_all_keycloak_clients() {
    echo "Creating Keycloak clients for all services..."
    echo ""

    # Get services that mention Keycloak in dependencies or notes
    local services
    services=$(yq eval '.services | to_entries | .[] | select(.value.dependencies // [] | contains(["keycloak"])) | .key' "$CADDY_REGISTRY_PATH")

    if [ -z "$services" ]; then
        echo "No services depend on Keycloak"
        return 0
    fi

    while IFS= read -r service; do
        if [ -n "$service" ]; then
            echo "=== $service ==="
            create_keycloak_client "$service" "secure-apps" "confidential"
            echo ""
        fi
    done <<< "$services"

    echo "✓ Keycloak client creation complete"
}

# Patch Keycloak secrets into service .env files using registry
# Usage: patch_keycloak_secrets [--restart]
patch_keycloak_secrets() {
    # Save the current state of `set -e` so we can restore it before returning.
    # We need -e off inside this function because `((var++))` returns non-zero
    # when the result is 0, and the body uses several counter increments.
    # Using a trap-on-RETURN keeps the restore on every exit path.
    local _saved_eflag=""
    case "$-" in *e*) _saved_eflag="e" ;; esac
    set +e
    # shellcheck disable=SC2064
    trap "[ -n \"$_saved_eflag\" ] && set -e; trap - RETURN" RETURN

    local restart_services=false

    # Default ${1:-} so a no-arg invocation under `set -u` doesn't blow up
    # before we ever reach the trap-on-RETURN.
    if [ "${1:-}" = "--restart" ]; then
        restart_services=true
    fi

    local keycloak_dir="${SERVICES_ROOT}/keycloak"
    local env_file="${keycloak_dir}/.env.keycloak"

    # Check if .env.keycloak exists
    if [ ! -f "$env_file" ]; then
        echo "Error: $env_file not found" >&2
        echo "Run setup-realm.sh first to generate client secrets" >&2
        return 1
    fi

    echo "Reading Keycloak secrets from $env_file..."
    echo ""

    # Source the secrets
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a

    # Define service-to-secret mappings
    # Format: "service_name|env_var_name|secret_value"
    local -a secret_mappings=(
        "coding|KEYCLOAK_CLIENT_SECRET|${LOCALHOST_READER_CLIENT_SECRET:-}"
    )

    local updated_count=0
    local failed_count=0

    echo "=========================================="
    echo "PATCHING KEYCLOAK SECRETS"
    echo "=========================================="
    echo ""

    for mapping in "${secret_mappings[@]}"; do
        IFS='|' read -r service_name env_var secret_value <<< "$mapping"

        # Skip if secret is empty
        if [ -z "$secret_value" ]; then
            echo "⚠ Skipping $service_name: No secret value"
            continue
        fi

        echo ""
        echo "📝 Updating $service_name..."

        # Get service deployment info from registry
        local service_info
        service_info=$(get_service_info "$service_name")
        if [ -z "$service_info" ]; then
            echo "  ✗ Service $service_name not found in registry"
            ((failed_count++))
            continue
        fi

        local current_host
        current_host=$(echo "$service_info" | yq eval '.current_host' -)
        local deployment_type
        deployment_type=$(echo "$service_info" | yq eval '.deployment_type' -)

        # Determine service directory based on deployment type
        local service_dir=""
        if [ "$deployment_type" = "docker" ]; then
            local docker_compose_path
            docker_compose_path=$(echo "$service_info" | yq eval '.docker_compose' -)
            service_dir=$(dirname "$docker_compose_path")
        else
            local service_file_path
            service_file_path=$(echo "$service_info" | yq eval '.service_file' -)
            service_dir=$(dirname "$service_file_path")
        fi

        local env_file_path="${service_dir}/.env"

        # Get SSH user for remote machine
        local ssh_user=""
        local _self
        _self=$(hostname -s 2>/dev/null || hostname | cut -d. -f1)
        if [ "$current_host" != "$_self" ] && [ "$current_host" != "local" ]; then
            ssh_user=$(get_machine_ssh_user "$current_host")
        fi

        # Update the .env file (local or remote)
        if [ "$current_host" = "$_self" ] || [ "$current_host" = "local" ] || [ -z "$ssh_user" ]; then
            # Local update
            if update_env_file_local "$env_file_path" "$env_var" "$secret_value"; then
                echo "  ✓ Updated $service_name on $current_host (local)"
                ((updated_count++))
            else
                echo "  ✗ Failed to update $service_name"
                ((failed_count++))
            fi
        else
            # Remote update via SSH (with proper quoting)
            if update_env_file_remote "$ssh_user@${current_host}.local" "$env_file_path" "$env_var" "$secret_value"; then
                echo "  ✓ Updated $service_name on $current_host (remote)"
                ((updated_count++))
            else
                echo "  ✗ Failed to update $service_name"
                ((failed_count++))
            fi
        fi

        echo ""
    done

    echo "=========================================="
    echo "SUMMARY"
    echo "=========================================="
    echo ""
    echo "Successfully updated: $updated_count service(s)"
    echo "Failed: $failed_count service(s)"
    echo ""

    # Restart services if requested
    if [ "$restart_services" = true ] && [ $updated_count -gt 0 ]; then
        echo "=========================================="
        echo "RESTARTING SERVICES"
        echo "=========================================="
        echo ""

        for mapping in "${secret_mappings[@]}"; do
            IFS='|' read -r service_name env_var secret_value <<< "$mapping"

            local service_info
            service_info=$(get_service_info "$service_name")
            if [ -n "$service_info" ]; then
                local current_host
                current_host=$(echo "$service_info" | yq eval '.current_host' -)

                echo "🔄 Restarting $service_name on $current_host..."
                if portoser_restart_service "$service_name" "$current_host"; then
                    echo "  ✓ Restarted successfully"
                else
                    echo "  ⚠ Restart may have failed"
                fi
                echo ""
            fi
        done
    fi

    if [ $failed_count -gt 0 ]; then
        return 1
    fi

    return 0
}

# Helper: Update .env file locally
update_env_file_local() {
    local file_path="$1"
    local var_name="$2"
    local var_value="$3"

    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$file_path")" 2>/dev/null || true

    # Backup existing file
    if [ -f "$file_path" ]; then
        cp "$file_path" "${file_path}.bak.$(date +%s)" 2>/dev/null || true
    fi

    # Update or add variable
    if [ -f "$file_path" ] && grep -q "^${var_name}=" "$file_path"; then
        # Replace existing - handle both macOS and Linux sed
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s|^${var_name}=.*|${var_name}=${var_value}|" "$file_path"
        else
            sed -i "s|^${var_name}=.*|${var_name}=${var_value}|" "$file_path"
        fi
    else
        # Add new
        echo "${var_name}=${var_value}" >> "$file_path"
    fi

    return $?
}

# Helper: Update .env file on remote machine via SSH
update_env_file_remote() {
    local ssh_host="$1"
    local file_path="$2"
    local var_name="$3"
    local var_value="$4"

    # Pass values as positional parameters into a quoted heredoc so the remote
    # shell receives them as literal strings — no client-side expansion, no
    # sed-replacement escaping, and secrets never appear on the SSH command line.
    ssh -o ConnectTimeout=10 "$ssh_host" \
        bash -s -- "$file_path" "$var_name" "$var_value" <<'REMOTE'
file_path="$1"
var_name="$2"
var_value="$3"

mkdir -p "$(dirname "$file_path")" 2>/dev/null || true

if [ -f "$file_path" ]; then
    cp "$file_path" "${file_path}.bak.$(date +%s)" 2>/dev/null || true
fi

if [ -f "$file_path" ] && grep -q "^${var_name}=" "$file_path"; then
    # Replace the line in-place via awk to avoid sed-replacement escaping headaches.
    tmp=$(mktemp)
    awk -v n="$var_name" -v v="$var_value" '
        BEGIN { found=0 }
        $0 ~ "^"n"=" { print n"="v; found=1; next }
        { print }
        END { if (!found) print n"="v }
    ' "$file_path" > "$tmp" && mv "$tmp" "$file_path"
else
    printf '%s=%s\n' "$var_name" "$var_value" >> "$file_path"
fi
REMOTE
}

# Helper: Restart service using portoser
# SC2029: $service_dir comes from yq eval on registry-controlled config
# (not user input) and gets cd'd into on the remote side; intentional.
# shellcheck disable=SC2029
portoser_restart_service() {
    local service_name="$1"
    local machine="$2"

    # Check if service is on local machine
    local _self
    _self=$(hostname -s 2>/dev/null || hostname | cut -d. -f1)
    if [ "$machine" = "$_self" ] || [ "$machine" = "local" ]; then
        "$SCRIPT_DIR/portoser" restart "$service_name" 2>&1 | grep -q "Success\|✓" && return 0 || return 1
    else
        # Remote restart via SSH
        local ssh_user
        ssh_user=$(get_machine_ssh_user "$machine")
        local service_info
        service_info=$(get_service_info "$service_name")
        local deployment_type
        deployment_type=$(echo "$service_info" | yq eval '.deployment_type' -)

        if [ "$deployment_type" = "docker" ]; then
            local docker_compose_path
            docker_compose_path=$(echo "$service_info" | yq eval '.docker_compose' -)
            local service_dir
            service_dir=$(dirname "$docker_compose_path")

            ssh "${ssh_user}@${machine}.local" \
                "cd \"$service_dir\" && docker compose up -d --force-recreate --no-build" 2>&1 | tail -1 | grep -q "Started\|Running" && return 0 || return 1
        fi
    fi

    return 1
}
