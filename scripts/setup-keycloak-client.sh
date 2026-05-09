#!/usr/bin/env bash
# setup-keycloak-client.sh — create or update a Keycloak OIDC client + roles
# for any portoser service.
#
# Usage (all required unless a sane default applies):
#   KEYCLOAK_URL='https://keycloak.example'    \
#   ADMIN_PASSWORD='your-admin-password'        \
#   CLIENT_ID='my-service'                      \
#   SERVICE_URL='http://my-service.example'     \
#   ./setup-keycloak-client.sh
#
# Optional env:
#   REALM             Realm to create the client in (default: secure-apps)
#   ADMIN_USER        Realm admin username (default: admin)
#   CLIENT_NAME       Display name (default: $CLIENT_ID)
#   CLIENT_DESCRIPTION  Free-form (default: derived from $CLIENT_ID)
#   CLIENT_ROLES      Space-separated role names to create. Each role can be
#                     enriched by per-role description env vars of the form
#                     ROLE_DESC_<UPPER_NAME> (with - → _).
#                     Default: "${CLIENT_ID}-admin ${CLIENT_ID}-viewer"
#
# Output: writes the generated client secret to
#   $HOME/.portoser/keycloak-${CLIENT_ID}.secret  (chmod 600)

set -euo pipefail

# ---- Required configuration --------------------------------------------------
KEYCLOAK_URL="${KEYCLOAK_URL:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
CLIENT_ID="${CLIENT_ID:-}"
SERVICE_URL="${SERVICE_URL:-${WORKER_MANAGEMENT_URL:-}}"   # back-compat alias

# ---- Optional configuration --------------------------------------------------
REALM="${REALM:-secure-apps}"
ADMIN_USER="${ADMIN_USER:-admin}"
CLIENT_NAME="${CLIENT_NAME:-$CLIENT_ID}"
CLIENT_DESCRIPTION="${CLIENT_DESCRIPTION:-Backend service client for ${CLIENT_ID}}"
# Default roles: <client>-admin (full) + <client>-viewer (read-only).
CLIENT_ROLES="${CLIENT_ROLES:-${CLIENT_ID}-admin ${CLIENT_ID}-viewer}"

# ---- Validation --------------------------------------------------------------
missing=()
[ -z "$KEYCLOAK_URL" ]    && missing+=("KEYCLOAK_URL")
[ -z "$ADMIN_PASSWORD" ]  && missing+=("ADMIN_PASSWORD")
[ -z "$CLIENT_ID" ]       && missing+=("CLIENT_ID")
[ -z "$SERVICE_URL" ]     && missing+=("SERVICE_URL")
if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: required env var(s) not set: ${missing[*]}" >&2
    echo "" >&2
    echo "Example:" >&2
    echo "  KEYCLOAK_URL='https://keycloak.example' \\" >&2
    echo "  ADMIN_PASSWORD='admin-secret' \\" >&2
    echo "  CLIENT_ID='my-service' \\" >&2
    echo "  SERVICE_URL='http://my-service.example' \\" >&2
    echo "  $0" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not installed." >&2
    exit 2
fi

echo "=========================================="
echo "Keycloak Client Setup"
echo "  Realm:    ${REALM}"
echo "  Client:   ${CLIENT_ID}"
echo "  Service:  ${SERVICE_URL}"
echo "=========================================="
echo ""

# ---- 1. Get admin token ------------------------------------------------------
echo "[1/5] Getting Keycloak admin token..."
RESPONSE=$(curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "username=${ADMIN_USER}" \
    --data-urlencode "password=${ADMIN_PASSWORD}" \
    -d 'grant_type=password' \
    -d 'client_id=admin-cli')

TOKEN=$(echo "$RESPONSE" | jq -r '.access_token // empty' 2>/dev/null)
if [ -z "$TOKEN" ]; then
    echo "✗ Failed to get admin token. Is Keycloak running?" >&2
    ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error_description // .error // "Unknown error"' 2>/dev/null || echo "$RESPONSE")
    echo "  Error: $ERROR_MSG" >&2
    echo "  Check that Keycloak is reachable at ${KEYCLOAK_URL}" >&2
    exit 1
fi
echo "✓ Admin token obtained"

# ---- 2. Create client --------------------------------------------------------
echo "[2/5] Creating client '$CLIENT_ID' in realm '$REALM'..."
CLIENT_JSON=$(jq -n \
    --arg clientId "$CLIENT_ID" \
    --arg name "$CLIENT_NAME" \
    --arg description "$CLIENT_DESCRIPTION" \
    --arg creationTime "$(date +%s)" \
    --arg svcUrl "$SERVICE_URL" \
    '{
        clientId: $clientId,
        name: $name,
        description: $description,
        enabled: true,
        protocol: "openid-connect",
        publicClient: false,
        serviceAccountsEnabled: true,
        authorizationServicesEnabled: true,
        directAccessGrantsEnabled: false,
        implicitFlowEnabled: false,
        standardFlowEnabled: true,
        redirectUris: [($svcUrl + "/*")],
        webOrigins: [$svcUrl],
        attributes: {
            "access.token.lifespan": "3600",
            "client.secret.creation.time": $creationTime
        }
    }')

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/clients" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "$CLIENT_JSON")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$ d')

if [ "$HTTP_CODE" = "201" ]; then
    echo "✓ Client created"
elif echo "$BODY" | grep -q "already exists"; then
    echo "⚠  Client already exists, continuing..."
else
    echo "✗ Failed to create client (HTTP $HTTP_CODE)"
    echo "$BODY"
    exit 1
fi

# ---- 3. Get client UUID ------------------------------------------------------
echo "[3/5] Getting client UUID..."
CLIENT_UUID=$(curl -s -X GET \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.[0].id // empty' 2>/dev/null)
if [ -z "$CLIENT_UUID" ]; then
    echo "✗ Failed to get client UUID" >&2
    exit 1
fi
echo "✓ Client UUID: $CLIENT_UUID"

# ---- 4. Get client secret ----------------------------------------------------
echo "[4/5] Getting client secret..."
CLIENT_SECRET=$(curl -s -X GET \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/client-secret" \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.value // empty' 2>/dev/null)
if [ -z "$CLIENT_SECRET" ]; then
    echo "✗ Failed to get client secret" >&2
    exit 1
fi
echo "✓ Client secret obtained"

# ---- 5. Create roles ---------------------------------------------------------
echo "[5/5] Creating roles..."
for role in $CLIENT_ROLES; do
    desc_var="ROLE_DESC_$(echo "$role" | tr '[:lower:]-' '[:upper:]_')"
    description="${!desc_var:-Role for ${CLIENT_ID}: ${role}}"
    role_json=$(jq -n --arg name "$role" --arg desc "$description" \
        '{name: $name, description: $desc, composite: false, clientRole: false}')
    if curl -sf -X POST \
        "${KEYCLOAK_URL}/admin/realms/${REALM}/roles" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H 'Content-Type: application/json' \
        -d "$role_json" >/dev/null 2>&1; then
        echo "✓ Created role: $role"
    else
        echo "⚠  Role $role may already exist"
    fi
done

# ---- Save secret ------------------------------------------------------------
mkdir -p "$HOME/.portoser"
chmod 700 "$HOME/.portoser"
SECRET_PATH="$HOME/.portoser/keycloak-${CLIENT_ID}.secret"
echo "$CLIENT_SECRET" > "$SECRET_PATH"
chmod 600 "$SECRET_PATH"

echo ""
echo "=========================================="
echo "✓ SETUP COMPLETE"
echo "=========================================="
{
    echo ""
    echo "Client credentials:"
    echo "  KEYCLOAK_URL=${KEYCLOAK_URL}"
    echo "  KEYCLOAK_REALM=${REALM}"
    echo "  KEYCLOAK_CLIENT_ID=${CLIENT_ID}"
    echo "  KEYCLOAK_CLIENT_SECRET=[REDACTED — length: ${#CLIENT_SECRET} chars]"
    echo ""
    echo "Secret saved to: ${SECRET_PATH}  (chmod 600)"
    echo "Retrieve with:    cat \"${SECRET_PATH}\""
    echo ""
    echo "SECURITY:"
    echo "  - Store these credentials in a password manager."
    echo "  - Share via an encrypted channel; never email or paste in chat."
} >&2

echo "Roles created:"
for role in $CLIENT_ROLES; do
    echo "  - $role"
done
echo ""
echo "Next steps:"
echo "  1. Configure the service host's .env with the values above."
echo "  2. Deploy/restart the service."
echo "  3. Test: curl ${SERVICE_URL}/health"
echo ""
