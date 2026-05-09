#!/usr/bin/env bash
# vault.sh - HashiCorp Vault integration for portoser

set -euo pipefail
# Provides centralized secret management across all services

# Check for required dependencies
# Note: These are warnings, not hard requirements - allow script to continue loading
if ! command -v jq >/dev/null 2>&1; then
    echo "Warning: jq is recommended for Vault operations but not installed" >&2
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "Warning: curl is recommended for Vault operations but not installed" >&2
fi

# Vault configuration
# SECURITY: Always use HTTPS for Vault communication to protect secrets in transit
VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:8200}"
VAULT_CONFIG_DIR="${VAULT_CONFIG_DIR:-${HOME}/portoser/vault}"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-$HOME/.portoser/vault-token}"
VAULT_CACERT="${VAULT_CACERT:-}"  # Path to CA certificate for TLS verification
VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-false}"  # Set to true only for development

# Helper function to build curl TLS options
# Usage: _vault_curl_opts
_vault_curl_opts() {
    local opts=""

    # Enforce HTTPS
    if [[ "$VAULT_ADDR" == http://* ]]; then
        echo "ERROR: Vault HTTP connections are not allowed. Use HTTPS." >&2
        echo "Current VAULT_ADDR: $VAULT_ADDR" >&2
        echo "Set VAULT_ADDR to use https:// instead." >&2
        return 1
    fi

    # Add CA certificate if provided
    if [[ -n "$VAULT_CACERT" ]] && [[ -f "$VAULT_CACERT" ]]; then
        opts="--cacert $VAULT_CACERT"
    elif [[ "$VAULT_SKIP_VERIFY" == "true" ]]; then
        echo "WARNING: TLS verification disabled (VAULT_SKIP_VERIFY=true)" >&2
        echo "This should only be used in development environments!" >&2
        opts="--insecure"
    fi

    echo "$opts"
}

# Check if Vault is available and unsealed
# Usage: vault_is_ready
vault_is_ready() {
    local tls_opts_str
    tls_opts_str=$(_vault_curl_opts) || return 1
    local tls_opts=()
    [ -n "$tls_opts_str" ] && read -ra tls_opts <<< "$tls_opts_str"
    local vault_status
    vault_status=$(curl -s --max-time 10 "${tls_opts[@]}" -o /dev/null -w "%{http_code}" "$VAULT_ADDR/v1/sys/health" 2>/dev/null)

    # Vault returns 200 if initialized, unsealed, and active
    # Returns 429 if unsealed and standby
    # Returns 472 if disaster recovery mode replication secondary and active
    # Returns 473 if performance standby
    # Returns 501 if not initialized
    # Returns 503 if sealed

    if [ "$vault_status" = "200" ] || [ "$vault_status" = "429" ] || [ "$vault_status" = "473" ]; then
        return 0
    else
        return 1
    fi
}

# Initialize Vault (first-time setup only)
# Usage: vault_init
vault_init() {
    print_color "$BLUE" "Initializing HashiCorp Vault..."

    if ! vault_is_ready 2>/dev/null; then
        # Check if it's sealed or not initialized
        local init_status
        init_status=$(curl -s --max-time 10 "$VAULT_ADDR/v1/sys/health" 2>/dev/null | jq -r '.initialized // false')

        if [ "$init_status" = "false" ]; then
            print_color "$YELLOW" "Vault is not initialized. Initializing now..."

            # Initialize with 3 key shares and 2 required to unseal
            local init_output
            if init_output=$(curl -s --max-time 30 --request POST \
                --data '{"secret_shares": 3, "secret_threshold": 2}' \
                "$VAULT_ADDR/v1/sys/init") && [ -n "$init_output" ]; then
                local root_token
                root_token=$(echo "$init_output" | jq -r '.root_token')
                local unseal_keys
                unseal_keys=$(echo "$init_output" | jq -r '.keys[]')

                if [ -z "$root_token" ] || [ "$root_token" = "null" ]; then
                    print_color "$RED" "✗ Failed to initialize Vault: Invalid response"
                    return 1
                fi

                # Save to secure location
                mkdir -p "$HOME/.portoser"
                chmod 700 "$HOME/.portoser"

                echo "$root_token" > "$VAULT_TOKEN_FILE"
                chmod 600 "$VAULT_TOKEN_FILE"

                echo "$init_output" > "$HOME/.portoser/vault-init.json"
                chmod 600 "$HOME/.portoser/vault-init.json"

                print_color "$GREEN" "✓ Vault initialized successfully"
                print_color "$YELLOW" "⚠ IMPORTANT: Save these unseal keys securely!"
                echo "" >&2
                echo "SECURITY: Unseal keys and root token saved to:" >&2
                echo "  - Root token: $VAULT_TOKEN_FILE" >&2
                echo "  - Full init data: $HOME/.portoser/vault-init.json" >&2
                echo "" >&2
                print_color "$YELLOW" "Store these in a password manager and DELETE the files after backup!" >&2
                echo "" >&2
                echo "Unseal keys (save these separately):" >&2
                echo "$unseal_keys" | nl -w2 -s'. ' >&2
                echo "" >&2

                # Unseal vault. The function reads keys from disk when called
                # without args, so we intentionally don't forward $@.
                # shellcheck disable=SC2119
                vault_unseal
            else
                print_color "$RED" "✗ Failed to initialize Vault"
                return 1
            fi
        else
            print_color "$YELLOW" "Vault is already initialized but sealed. Use 'portoser vault unseal' to unseal it."
        fi
    else
        print_color "$GREEN" "✓ Vault is already initialized and unsealed"
    fi
}

# Unseal Vault using unseal keys
# Usage: vault_unseal [KEY1] [KEY2]
# shellcheck disable=SC2120  # called both with and without args (initialize_vault uses no args)
vault_unseal() {
    # Args are optional; vault_unseal is also invoked from initialize_vault
    # without them, falling back to keys read from $HOME/.portoser/vault-init.json.
    local key1="${1:-}"
    local key2="${2:-}"

    print_color "$BLUE" "Unsealing Vault..."

    # If keys not provided, try to read from init file
    if [ -z "$key1" ] && [ -f "$HOME/.portoser/vault-init.json" ]; then
        key1=$(jq -r '.keys[0]' "$HOME/.portoser/vault-init.json")
        key2=$(jq -r '.keys[1]' "$HOME/.portoser/vault-init.json")
    fi

    if [ -z "$key1" ] || [ -z "$key2" ]; then
        print_color "$RED" "Error: Unseal keys required"
        echo "Usage: portoser vault unseal KEY1 KEY2"
        return 1
    fi

    # Unseal with first key (using stdin to avoid process exposure)
    echo "{\"key\": \"$key1\"}" | curl -s --request POST --data @- "$VAULT_ADDR/v1/sys/unseal" > /dev/null

    # Unseal with second key (using stdin to avoid process exposure)
    local result
    result=$(echo "{\"key\": \"$key2\"}" | curl -s --request POST --data @- "$VAULT_ADDR/v1/sys/unseal")

    local sealed
    sealed=$(echo "$result" | jq -r '.sealed')

    if [ "$sealed" = "false" ]; then
        print_color "$GREEN" "✓ Vault unsealed successfully"
        return 0
    else
        print_color "$RED" "✗ Failed to unseal Vault"
        return 1
    fi
}

# Get Vault token from file or environment
# Usage: get_vault_token
get_vault_token() {
    if [ -n "$VAULT_TOKEN" ]; then
        echo "$VAULT_TOKEN"
    elif [ -f "$VAULT_TOKEN_FILE" ]; then
        cat "$VAULT_TOKEN_FILE"
    else
        echo ""
    fi
}

# Enable secrets engine (KV v2)
# Usage: vault_enable_kv
vault_enable_kv() {
    local token
    token=$(get_vault_token)

    if [ -z "$token" ]; then
        print_color "$RED" "Error: Vault token not found"
        return 1
    fi

    print_color "$BLUE" "Enabling KV secrets engine..."

    if curl -s --header "X-Vault-Token: $token" \
        --request POST \
        --data '{"type": "kv-v2"}' \
        "$VAULT_ADDR/v1/sys/mounts/secret" > /dev/null; then
        print_color "$GREEN" "✓ KV secrets engine enabled at 'secret/'"
    else
        print_color "$YELLOW" "⚠ KV engine may already be enabled"
    fi
    return 0
}

# Create AppRole for a machine
# Usage: vault_create_approle MACHINE_NAME
vault_create_approle() {
    local machine="$1"
    local token
    token=$(get_vault_token)

    if [ -z "$machine" ]; then
        echo "Error: Machine name required" >&2
        return 1
    fi

    if [ -z "$token" ]; then
        print_color "$RED" "Error: Vault token not found"
        return 1
    fi

    print_color "$BLUE" "Creating AppRole for machine: $machine"

    # Enable AppRole auth method if not already enabled
    curl -s --header "X-Vault-Token: $token" \
        --request POST \
        --data '{"type": "approle"}' \
        "$VAULT_ADDR/v1/sys/auth/approle" 2>/dev/null

    # Create policy for this machine
    local policy_name="${machine}-policy"
    local policy_path="$VAULT_CONFIG_DIR/policies/${machine}-policy.hcl"

    # Create policy file
    cat > "$policy_path" <<EOF
# Policy for machine: $machine
# Allows read access to all service secrets

path "secret/data/services/*" {
  capabilities = ["read", "list"]
}

path "secret/data/shared/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/services/*" {
  capabilities = ["list"]
}

path "secret/metadata/shared/*" {
  capabilities = ["list"]
}
EOF

    # Upload policy to Vault
    # Security: Use jq to properly escape policy content and construct JSON
    local policy_data
    policy_data=$(cat "$policy_path")
    jq -n --arg p "$policy_data" '{policy: $p}' | \
        curl -s --header "X-Vault-Token: $token" \
        --request PUT \
        --data @- \
        "$VAULT_ADDR/v1/sys/policies/acl/$policy_name" > /dev/null

    # Create AppRole
    # Security: Use jq to construct JSON properly
    jq -n --arg p "$policy_name" '{policies: [$p], bind_secret_id: true, token_ttl: "1h", token_max_ttl: "4h"}' | \
        curl -s --header "X-Vault-Token: $token" \
        --request POST \
        --data @- \
        "$VAULT_ADDR/v1/auth/approle/role/$machine" > /dev/null

    # Get Role ID
    local role_id
    role_id=$(curl -s --header "X-Vault-Token: $token" \
        "$VAULT_ADDR/v1/auth/approle/role/$machine/role-id" | jq -r '.data.role_id')

    # Generate Secret ID
    local secret_id
    secret_id=$(curl -s --header "X-Vault-Token: $token" \
        --request POST \
        "$VAULT_ADDR/v1/auth/approle/role/$machine/secret-id" | jq -r '.data.secret_id')

    print_color "$GREEN" "✓ AppRole created for $machine"
    echo "" >&2
    echo "SECURITY: Credentials saved securely (not displayed)" >&2
    echo "" >&2
    print_color "$YELLOW" "Credentials saved to: $HOME/.portoser/approles/$machine.json" >&2
    echo "Role ID length: ${#role_id} chars" >&2
    echo "Secret ID length: ${#secret_id} chars" >&2
    echo "" >&2
    print_color "$YELLOW" "Retrieve with: cat $HOME/.portoser/approles/$machine.json | jq" >&2
    echo "" >&2

    # Save to machine-specific file
    mkdir -p "$HOME/.portoser/approles"
    chmod 700 "$HOME/.portoser/approles"
    cat > "$HOME/.portoser/approles/$machine.json" <<EOF
{
  "machine": "$machine",
  "role_id": "$role_id",
  "secret_id": "$secret_id"
}
EOF
    chmod 600 "$HOME/.portoser/approles/$machine.json"
}

# Login to Vault using AppRole and get token
# Usage: vault_login_approle MACHINE_NAME
vault_login_approle() {
    local machine="$1"
    local approle_file="$HOME/.portoser/approles/$machine.json"

    if [ ! -f "$approle_file" ]; then
        echo "Error: AppRole credentials not found for $machine" >&2
        return 1
    fi

    local role_id
    role_id=$(jq -r '.role_id' "$approle_file")
    local secret_id
    secret_id=$(jq -r '.secret_id' "$approle_file")

    # Use stdin to avoid exposing credentials in process list
    local response
    response=$(jq -n \
        --arg role_id "$role_id" \
        --arg secret_id "$secret_id" \
        '{role_id: $role_id, secret_id: $secret_id}' | \
        curl -s --request POST --data @- "$VAULT_ADDR/v1/auth/approle/login")

    local token
    token=$(echo "$response" | jq -r '.auth.client_token')

    if [ -n "$token" ] && [ "$token" != "null" ]; then
        echo "$token"
        return 0
    else
        echo "Error: Failed to login with AppRole" >&2
        return 1
    fi
}

# Store a secret in Vault
# Usage: vault_put_secret PATH KEY VALUE
vault_put_secret() {
    local path="$1"
    local key="$2"
    local value="$3"
    local token
    token=$(get_vault_token)

    if [ -z "$token" ]; then
        echo "Error: Vault token not found" >&2
        return 1
    fi

    # Read existing secrets at this path
    local existing
    existing=$(curl -s --header "X-Vault-Token: $token" \
        "$VAULT_ADDR/v1/secret/data/$path" | jq -r '.data.data // {}')

    # Merge with new secret
    local updated
    updated=$(echo "$existing" | jq --arg key "$key" --arg value "$value" '. + {($key): $value}')

    # Write back to Vault
    # Security: updated is already JSON from jq, wrap it properly
    jq -n --argjson d "$updated" '{data: $d}' | \
        curl -s --header "X-Vault-Token: $token" \
        --request POST \
        --data @- \
        "$VAULT_ADDR/v1/secret/data/$path" > /dev/null
}

# Get a secret from Vault
# Usage: vault_get_secret PATH KEY
vault_get_secret() {
    local path="$1"
    local key="$2"
    local token
    token=$(get_vault_token)

    if [ -z "$token" ]; then
        echo "Error: Vault token not found" >&2
        return 1
    fi

    local value
    value=$(curl -s --header "X-Vault-Token: $token" \
        "$VAULT_ADDR/v1/secret/data/$path" | jq -r ".data.data.${key} // empty")

    if [ -n "$value" ]; then
        echo "$value"
        return 0
    else
        return 1
    fi
}

# Get all secrets for a service as key=value pairs
# Usage: vault_get_service_secrets SERVICE_NAME [MACHINE]
vault_get_service_secrets() {
    local service="$1"
    local machine="${2:-$(hostname -s 2>/dev/null || hostname | cut -d. -f1)}"
    local token
    token=$(get_vault_token)

    # Try to login with AppRole if we don't have a token
    if [ -z "$token" ]; then
        token=$(vault_login_approle "$machine" 2>/dev/null)
        if [ -z "$token" ]; then
            echo "Error: Could not authenticate with Vault" >&2
            return 1
        fi
    fi

    # Get secrets from Vault
    local secrets
    secrets=$(curl -s --header "X-Vault-Token: $token" \
        "$VAULT_ADDR/v1/secret/data/services/$service" 2>/dev/null | jq -r '.data.data // {}')

    if [ "$secrets" = "{}" ]; then
        # No secrets found for this service
        return 1
    fi

    # Convert to key=value format
    echo "$secrets" | jq -r 'to_entries | .[] | "\(.key)=\(.value)"'
}

# Export service secrets as environment variables
# Usage: vault_export_service_secrets SERVICE_NAME [MACHINE]
vault_export_service_secrets() {
    local service="$1"
    local machine="${2:-$(hostname -s 2>/dev/null || hostname | cut -d. -f1)}"

    local secrets
    secrets=$(vault_get_service_secrets "$service" "$machine")

    if [ -z "$secrets" ]; then
        return 1
    fi

    # Export each secret as an environment variable
    while IFS='=' read -r key value; do
        export "$key=$value"
    done <<< "$secrets"

    return 0
}

# Migrate .env file to Vault
# Usage: vault_migrate_env SERVICE_NAME ENV_FILE_PATH
vault_migrate_env() {
    local service="$1"
    local env_file="$2"
    local token
    token=$(get_vault_token)

    if [ -z "$token" ]; then
        print_color "$RED" "Error: Vault token not found"
        return 1
    fi

    if [ ! -f "$env_file" ]; then
        print_color "$RED" "Error: .env file not found: $env_file"
        return 1
    fi

    print_color "$BLUE" "Migrating $env_file to Vault for service: $service"

    # Parse .env file and upload to Vault
    local secrets="{}"
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        if [[ "$key" =~ ^[[:space:]]*# ]] || [ -z "$key" ]; then
            continue
        fi

        # Remove leading/trailing whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)

        # Remove quotes from value if present (using parameter expansion for security)
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"

        # Add to secrets JSON
        secrets=$(echo "$secrets" | jq --arg key "$key" --arg value "$value" '. + {($key): $value}')

        echo "  ✓ $key"
    done < "$env_file"

    # Upload all secrets at once
    # Security: secrets is already JSON from jq, wrap it properly
    if jq -n --argjson s "$secrets" '{data: $s}' | \
        curl -s --header "X-Vault-Token: $token" \
        --request POST \
        --data @- \
        "$VAULT_ADDR/v1/secret/data/services/$service" > /dev/null; then
        print_color "$GREEN" "✓ Successfully migrated secrets to Vault"
        echo ""
        print_color "$YELLOW" "Original .env file: $env_file"
        print_color "$YELLOW" "Consider backing up and removing the .env file"
        return 0
    fi
    print_color "$RED" "✗ Failed to migrate secrets"
    return 1
}

# List all secrets for a service
# Usage: vault_list_service_secrets SERVICE_NAME
vault_list_service_secrets() {
    local service="$1"
    local token
    token=$(get_vault_token)

    if [ -z "$token" ]; then
        print_color "$RED" "Error: Vault token not found"
        return 1
    fi

    print_color "$BLUE" "Secrets for service: $service"
    echo ""

    local secrets
    secrets=$(curl -s --header "X-Vault-Token: $token" \
        "$VAULT_ADDR/v1/secret/data/services/$service" | jq -r '.data.data // {}')

    if [ "$secrets" = "{}" ]; then
        print_color "$YELLOW" "No secrets found for $service"
        return 1
    fi

    echo "$secrets" | jq -r 'to_entries | .[] | "  \(.key) = \(.value[0:20])..."'
    echo ""
}

# List all services with secrets in Vault
# Usage: vault_list_all_services
vault_list_all_services() {
    local token
    token=$(get_vault_token)

    if [ -z "$token" ]; then
        print_color "$RED" "Error: Vault token not found"
        return 1
    fi

    print_color "$BLUE" "Services with secrets in Vault:"
    echo ""

    local services
    services=$(curl -s --header "X-Vault-Token: $token" \
        --request LIST \
        "$VAULT_ADDR/v1/secret/metadata/services" | jq -r '.data.keys[]' 2>/dev/null)

    if [ -z "$services" ]; then
        print_color "$YELLOW" "No services found in Vault"
        return 1
    fi

    # shellcheck disable=SC2001  # per-line prefix; bash parameter expansion can't anchor with ^
    echo "$services" | sed 's/^/  - /'
    echo ""
}

# Check Vault status
# Usage: vault_status
vault_status() {
    local health
    health=$(curl -s "$VAULT_ADDR/v1/sys/health" 2>/dev/null)

    if [ -z "$health" ]; then
        print_color "$RED" "✗ Vault is not reachable at $VAULT_ADDR"
        return 1
    fi

    local initialized
    initialized=$(echo "$health" | jq -r '.initialized')
    local sealed
    sealed=$(echo "$health" | jq -r '.sealed')
    local standby
    standby=$(echo "$health" | jq -r '.standby')

    print_color "$BLUE" "=== Vault Status ==="
    echo ""
    echo "Address: $VAULT_ADDR"
    echo "Initialized: $initialized"
    echo "Sealed: $sealed"
    echo "Standby: $standby"
    echo ""

    if [ "$initialized" = "true" ] && [ "$sealed" = "false" ]; then
        print_color "$GREEN" "✓ Vault is ready"
        return 0
    elif [ "$sealed" = "true" ]; then
        print_color "$YELLOW" "⚠ Vault is sealed - run 'portoser vault unseal'"
        return 1
    else
        print_color "$YELLOW" "⚠ Vault needs initialization - run 'portoser vault init'"
        return 1
    fi
}
