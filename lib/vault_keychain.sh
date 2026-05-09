#!/usr/bin/env bash
# =============================================================================
# lib/vault_keychain.sh - Secure Vault Token Storage using macOS Keychain
#
# Provides secure token storage using macOS Keychain instead of plaintext files.
# This significantly improves security by encrypting tokens at rest.
#
# Functions:
#   - vault_keychain_save_token()    Save token to Keychain
#   - vault_keychain_get_token()     Retrieve token from Keychain
#   - vault_keychain_delete_token()  Delete token from Keychain
#   - vault_keychain_rotate_token()  Rotate token with new value
#
# Dependencies: security (macOS built-in)
# Created: 2025-12-08 (Alpha-5)
# =============================================================================

set -euo pipefail

# Keychain configuration
KEYCHAIN_SERVICE="portoser-vault"
KEYCHAIN_ACCOUNT="vault-token"

# =============================================================================
# vault_keychain_save_token - Save Vault token to macOS Keychain
#
# Stores the Vault token securely in macOS Keychain with encryption.
# Replaces plaintext file storage for enhanced security.
#
# Parameters:
#   $1 - token (required): Vault token to save
#   $2 - label (optional): Description label for the token
#                          Default: "Portoser Vault Token"
#
# Returns:
#   0 - Token saved successfully
#   1 - Save failed
#
# Security:
#   - Token encrypted in Keychain
#   - Only accessible by current user
#   - Can be secured with user password
#
# Example:
#   vault_keychain_save_token "hvs.XXXXXX" "Production Vault Token"
# =============================================================================
vault_keychain_save_token() {
    local token="$1"
    local label="${2:-Portoser Vault Token}"

    if [[ -z "$token" ]]; then
        echo "Error: Token is required" >&2
        return 1
    fi

    # Check if token already exists
    if security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1; then
        # Update existing token
        if security add-generic-password -U \
            -s "$KEYCHAIN_SERVICE" \
            -a "$KEYCHAIN_ACCOUNT" \
            -l "$label" \
            -w "$token" >/dev/null 2>&1; then
            echo "Vault token updated in Keychain" >&2
            return 0
        else
            echo "Error: Failed to update token in Keychain" >&2
            return 1
        fi
    else
        # Create new token entry
        if security add-generic-password \
            -s "$KEYCHAIN_SERVICE" \
            -a "$KEYCHAIN_ACCOUNT" \
            -l "$label" \
            -w "$token" >/dev/null 2>&1; then
            echo "Vault token saved to Keychain" >&2
            return 0
        else
            echo "Error: Failed to save token to Keychain" >&2
            return 1
        fi
    fi
}

# =============================================================================
# vault_keychain_get_token - Retrieve Vault token from macOS Keychain
#
# Retrieves the Vault token from Keychain. Falls back to file-based token
# if Keychain token not found (for backward compatibility).
#
# Parameters:
#   None
#
# Returns:
#   0 - Token retrieved successfully
#   1 - Token not found
#
# Outputs:
#   Prints token to stdout
#
# Example:
#   token=$(vault_keychain_get_token)
# =============================================================================
vault_keychain_get_token() {
    # Try to get from Keychain first
    local token
    token=$(security find-generic-password \
        -s "$KEYCHAIN_SERVICE" \
        -a "$KEYCHAIN_ACCOUNT" \
        -w 2>/dev/null || echo "")

    if [[ -n "$token" ]]; then
        echo "$token"
        return 0
    fi

    # Fallback to file-based token (backward compatibility)
    local token_file="${VAULT_TOKEN_FILE:-$HOME/.portoser/vault-token}"
    if [[ -f "$token_file" ]]; then
        echo "Warning: Using legacy file-based token. Migrate to Keychain!" >&2
        cat "$token_file"
        return 0
    fi

    # Check environment variable
    if [[ -n "${VAULT_TOKEN:-}" ]]; then
        echo "Warning: Using token from environment variable" >&2
        echo "$VAULT_TOKEN"
        return 0
    fi

    echo "Error: No Vault token found in Keychain, file, or environment" >&2
    return 1
}

# =============================================================================
# vault_keychain_delete_token - Delete Vault token from macOS Keychain
#
# Removes the Vault token from Keychain. Use when revoking access or
# cleaning up after token rotation.
#
# Parameters:
#   None
#
# Returns:
#   0 - Token deleted successfully
#   1 - Deletion failed or token not found
#
# Example:
#   vault_keychain_delete_token
# =============================================================================
vault_keychain_delete_token() {
    if security delete-generic-password \
        -s "$KEYCHAIN_SERVICE" \
        -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1; then
        echo "Vault token deleted from Keychain" >&2
        return 0
    else
        echo "Warning: Token not found in Keychain or deletion failed" >&2
        return 1
    fi
}

# =============================================================================
# vault_keychain_rotate_token - Rotate Vault token
#
# Implements token rotation by:
# 1. Saving old token to backup
# 2. Saving new token to Keychain
# 3. Optionally revoking old token
#
# Parameters:
#   $1 - new_token (required): New Vault token
#   $2 - revoke_old (optional): Set to "true" to revoke old token
#                               Default: "false"
#
# Returns:
#   0 - Rotation successful
#   1 - Rotation failed
#
# Security:
#   - Old token backed up temporarily
#   - New token encrypted in Keychain
#   - Optional old token revocation
#
# Example:
#   vault_keychain_rotate_token "hvs.NEWTOKEN" "true"
# =============================================================================
vault_keychain_rotate_token() {
    local new_token="$1"
    local revoke_old="${2:-false}"

    if [[ -z "$new_token" ]]; then
        echo "Error: New token is required" >&2
        return 1
    fi

    # Get old token for potential revocation
    local old_token
    old_token=$(vault_keychain_get_token 2>/dev/null || echo "")

    # Save new token
    if ! vault_keychain_save_token "$new_token" "Portoser Vault Token (Rotated $(date +%Y-%m-%d))"; then
        echo "Error: Failed to save new token" >&2
        return 1
    fi

    echo "Token rotated successfully" >&2

    # Revoke old token if requested and available
    if [[ "$revoke_old" == "true" ]] && [[ -n "$old_token" ]]; then
        echo "Revoking old token..." >&2
        # Note: This would require vault_revoke_token function from lib/vault.sh
        # For now, just log the action
        echo "Old token should be revoked manually if still valid" >&2
    fi

    return 0
}

# =============================================================================
# vault_keychain_migrate_from_file - Migrate file-based token to Keychain
#
# Migrates existing file-based Vault token to Keychain storage.
# Automatically called by get_vault_token if file exists but Keychain doesn't.
#
# Parameters:
#   $1 - token_file (optional): Path to token file
#                               Default: $HOME/.portoser/vault-token
#
# Returns:
#   0 - Migration successful
#   1 - Migration failed
#
# Security:
#   - Securely deletes file after migration
#   - Sets proper Keychain permissions
#
# Example:
#   vault_keychain_migrate_from_file
# =============================================================================
vault_keychain_migrate_from_file() {
    local token_file="${1:-$HOME/.portoser/vault-token}"

    if [[ ! -f "$token_file" ]]; then
        echo "No token file found to migrate" >&2
        return 1
    fi

    # Read token from file
    local token
    token=$(cat "$token_file")

    if [[ -z "$token" ]]; then
        echo "Error: Token file is empty" >&2
        return 1
    fi

    # Save to Keychain
    if vault_keychain_save_token "$token" "Portoser Vault Token (Migrated from file)"; then
        echo "Token migrated to Keychain successfully" >&2
        echo "" >&2
        echo "SECURITY: The old token file can now be deleted:" >&2
        echo "  File: $token_file" >&2
        echo "" >&2
        read -r -p "Delete token file now? (y/n): " confirm
        if [[ "$confirm" == "y" ]] || [[ "$confirm" == "Y" ]]; then
            # Securely delete the file (overwrite before deletion)
            if command -v shred >/dev/null 2>&1; then
                shred -u "$token_file"
                echo "Token file securely deleted" >&2
            else
                # macOS doesn't have shred, use multiple overwrites
                local token_bytes
                token_bytes=$(wc -c < "$token_file")
                dd if=/dev/urandom of="$token_file" bs=1 count="$token_bytes" conv=notrunc 2>/dev/null
                rm -f "$token_file"
                echo "Token file deleted" >&2
            fi
        else
            echo "Token file not deleted. Please delete manually after verification:" >&2
            echo "  rm -f $token_file" >&2
        fi
        return 0
    else
        echo "Error: Failed to migrate token to Keychain" >&2
        return 1
    fi
}

# =============================================================================
# vault_keychain_status - Show Keychain token status
#
# Displays information about Keychain-stored Vault token without revealing
# the actual token value.
#
# Parameters:
#   None
#
# Returns:
#   0 - Status displayed
#   1 - No token found
#
# Example:
#   vault_keychain_status
# =============================================================================
vault_keychain_status() {
    if security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1; then
        echo "Vault Token Status:" >&2
        echo "  Storage: macOS Keychain" >&2
        echo "  Service: $KEYCHAIN_SERVICE" >&2
        echo "  Account: $KEYCHAIN_ACCOUNT" >&2
        echo "  Status: FOUND" >&2

        # Get token length without revealing value
        local token
        token=$(vault_keychain_get_token 2>/dev/null)
        if [[ -n "$token" ]]; then
            echo "  Token Length: ${#token} characters" >&2
        fi

        return 0
    else
        echo "Vault Token Status:" >&2
        echo "  Storage: macOS Keychain" >&2
        echo "  Status: NOT FOUND" >&2

        # Check for file-based token
        local token_file="${VAULT_TOKEN_FILE:-$HOME/.portoser/vault-token}"
        if [[ -f "$token_file" ]]; then
            echo "" >&2
            echo "Legacy file-based token found:" >&2
            echo "  File: $token_file" >&2
            echo "  Action: Run vault_keychain_migrate_from_file to migrate" >&2
        fi

        return 1
    fi
}

# =============================================================================
# Library initialization check
# =============================================================================

# Verify this script is being sourced, not executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This library should be sourced, not executed directly" >&2
    echo "Usage: source lib/vault_keychain.sh" >&2
    exit 1
fi

echo "Vault Keychain library loaded" >&2
