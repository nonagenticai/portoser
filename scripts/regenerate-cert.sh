#!/usr/bin/env bash
#
# Regenerate a service certificate with the correct hostname / SAN entries.
#
# Usage:
#   ./regenerate-cert.sh SERVICE_NAME HOSTNAME [IP_ADDRESS]
#
# Example:
#   ./regenerate-cert.sh keycloak keycloak.example.local 10.0.0.10
#
# Configuration (env vars):
#   PORTOSER_ROOT  Path to the portoser checkout (default: parent of this script)
#   REGISTRY       Path to registry.yml (default: $PORTOSER_ROOT/registry.yml)
#   CA_BASE        Directory containing ca-cert.pem and ca-key.pem
#                  (default: parent of $PORTOSER_ROOT)

set -euo pipefail

SERVICE="${1:-}"
HOSTNAME="${2:-}"
IP_ADDRESS="${3:-}"

if [[ -z "$SERVICE" ]] || [[ -z "$HOSTNAME" ]]; then
    echo "Usage: $0 SERVICE_NAME HOSTNAME [IP_ADDRESS]"
    echo "Example: $0 keycloak keycloak.example.local 10.0.0.10"
    exit 1
fi

# Registry and CA paths
PORTOSER_ROOT="${PORTOSER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REGISTRY="${REGISTRY:-$PORTOSER_ROOT/registry.yml}"
CA_BASE="${CA_BASE:-$(dirname "$PORTOSER_ROOT")}"
BASE_PATH="$CA_BASE"
CA_CERT="${CA_CERT:-$CA_BASE/ca-cert.pem}"
CA_KEY="${CA_KEY:-$CA_BASE/ca-key.pem}"

# Get service info from registry
CERT_PATH=$(yq eval ".services.${SERVICE}.tls_cert" "$REGISTRY")
KEY_PATH=$(yq eval ".services.${SERVICE}.tls_key" "$REGISTRY")

if [[ "$CERT_PATH" == "null" ]] || [[ "$KEY_PATH" == "null" ]]; then
    echo "Error: Service '$SERVICE' not found in registry or has no certificate paths"
    exit 1
fi

FULL_CERT_PATH="$BASE_PATH$CERT_PATH"
FULL_KEY_PATH="$BASE_PATH$KEY_PATH"
CERT_DIR=$(dirname "$FULL_CERT_PATH")

# Create cert directory if it doesn't exist
mkdir -p "$CERT_DIR"

echo "Regenerating certificate for $SERVICE..."
echo "  Hostname: $HOSTNAME"
echo "  Cert: $FULL_CERT_PATH"
echo "  Key: $FULL_KEY_PATH"

# Backup existing certificate if it exists
if [[ -f "$FULL_CERT_PATH" ]]; then
    BACKUP="$FULL_CERT_PATH.backup.$(date +%Y%m%d_%H%M%S)"
    echo "  Backing up existing cert to: $BACKUP"
    cp "$FULL_CERT_PATH" "$BACKUP"
fi

if [[ -f "$FULL_KEY_PATH" ]]; then
    BACKUP="$FULL_KEY_PATH.backup.$(date +%Y%m%d_%H%M%S)"
    echo "  Backing up existing key to: $BACKUP"
    cp "$FULL_KEY_PATH" "$BACKUP"
fi

# Generate new private key
echo "  Generating new private key..."
openssl genrsa -out "$FULL_KEY_PATH" 2048 2>/dev/null

# Build SAN extension
SAN="DNS:${HOSTNAME},DNS:localhost"
if [[ -n "$IP_ADDRESS" ]]; then
    SAN="${SAN},IP:${IP_ADDRESS}"
fi
SAN="${SAN},IP:127.0.0.1"

# Create CSR
CSR_PATH="$CERT_DIR/${SERVICE}-csr.pem"
echo "  Creating certificate signing request..."
openssl req -new -key "$FULL_KEY_PATH" -out "$CSR_PATH" \
    -subj "/C=US/ST=State/L=City/O=HomeOrg/OU=IT/CN=${HOSTNAME}" \
    2>/dev/null

# Create extension file for SANs
EXT_FILE="$CERT_DIR/${SERVICE}-ext.cnf"
cat > "$EXT_FILE" <<EOF
subjectAltName=${SAN}
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
EOF

# Sign with CA
echo "  Signing certificate with CA..."
openssl x509 -req -in "$CSR_PATH" \
    -CA "$CA_CERT" -CAkey "$CA_KEY" \
    -CAcreateserial -out "$FULL_CERT_PATH" \
    -days 3650 \
    -extfile "$EXT_FILE" \
    2>/dev/null

# Verify certificate
echo "  Verifying certificate..."
if openssl verify -CAfile "$CA_CERT" "$FULL_CERT_PATH" &>/dev/null; then
    echo "  ✓ Certificate verification successful"
else
    echo "  ✗ Certificate verification failed"
    exit 1
fi

# Show certificate details
echo ""
echo "Certificate details:"
openssl x509 -in "$FULL_CERT_PATH" -noout -subject -ext subjectAltName

# Clean up temporary files
rm -f "$CSR_PATH" "$EXT_FILE"

echo ""
echo "✓ Certificate regenerated successfully!"
echo ""
echo "Next steps:"
echo "  1. Restart the $SERVICE service"
echo "  2. Test with: curl https://${HOSTNAME}/"
