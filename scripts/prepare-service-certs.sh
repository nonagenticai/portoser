#!/usr/bin/env bash
# prepare-service-certs.sh - Generate and prepare TLS certificates for service deployment
#
# Handles:
# - Generating fresh server certificates with correct IP
# - Copying certs to service directory in Documents
# - Ensuring cert paths match registry expectations
#
# Usage:
#   ./prepare-service-certs.sh <service-name>
#   ./prepare-service-certs.sh myservice

set -euo pipefail

PORTOSER_ROOT="${PORTOSER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REGISTRY_FILE="${REGISTRY_FILE:-$PORTOSER_ROOT/registry.yml}"
DOCUMENTS_DIR="${DOCUMENTS_DIR:-$(dirname "$PORTOSER_ROOT")}"
SERVER_CERTS_DIR="${SERVER_CERTS_DIR:-$(dirname "$PORTOSER_ROOT")/server-certs}"
PORTOSER_LIB="${PORTOSER_LIB:-$PORTOSER_ROOT/lib/certificates.sh}"

if [ $# -eq 0 ]; then
    echo "Usage: $0 <service-name>"
    exit 1
fi

SERVICE_NAME="$1"

echo "========================================"
echo "Preparing Certificates: $SERVICE_NAME"
echo "========================================"
echo ""

# Check if service needs TLS
TLS_CERT=$(yq eval ".services.\"$SERVICE_NAME\".tls_cert // \"null\"" "$REGISTRY_FILE")

if [ "$TLS_CERT" = "null" ]; then
    echo "ℹ️  Service does not require TLS certificates"
    exit 0
fi

echo "Service requires TLS certificate"
echo "  Registry path: $TLS_CERT"
echo ""

# Get service details
CURRENT_HOST=$(yq eval ".services.\"$SERVICE_NAME\".current_host" "$REGISTRY_FILE")
HOSTNAME=$(yq eval ".services.\"$SERVICE_NAME\".hostname" "$REGISTRY_FILE")
HOST_IP=$(yq eval ".hosts.\"$CURRENT_HOST\".ip" "$REGISTRY_FILE")

echo "Target deployment:"
echo "  Host: $CURRENT_HOST"
echo "  Hostname: $HOSTNAME"
echo "  IP: $HOST_IP"
echo ""

# Determine service directory
DOCKER_COMPOSE_PATH=$(yq eval ".services.\"$SERVICE_NAME\".docker_compose // .services.\"$SERVICE_NAME\".service_file" "$REGISTRY_FILE")
SERVICE_DIR=$(echo "$DOCKER_COMPOSE_PATH" | cut -d'/' -f2)
SERVICE_PATH="$DOCUMENTS_DIR/$SERVICE_DIR"

if [ ! -d "$SERVICE_PATH" ]; then
    echo "❌ Service directory not found: $SERVICE_PATH"
    exit 1
fi

# Create certs directory in service
CERTS_DIR="$SERVICE_PATH/certs"
mkdir -p "$CERTS_DIR"

echo "Certificate destination: $CERTS_DIR"
echo ""

# Check if certificate already exists with correct IP
EXISTING_CERT="$CERTS_DIR/${SERVICE_NAME}-server-cert.pem"
if [ -f "$EXISTING_CERT" ]; then
    echo "Checking existing certificate..."
    CERT_IP=$(openssl x509 -in "$EXISTING_CERT" -noout -text 2>/dev/null | grep -oP 'IP Address:\K[0-9.]+' | head -1 || echo "")
    
    if [ "$CERT_IP" = "$HOST_IP" ]; then
        echo "✓ Existing certificate has correct IP ($HOST_IP)"
        echo ""
        echo "Certificate files:"
        ls -lh "$CERTS_DIR"
        exit 0
    else
        echo "⚠️  Existing certificate has wrong IP: $CERT_IP (expected $HOST_IP)"
        echo "   Will regenerate..."
        echo ""
    fi
fi

# Generate new certificate
echo "Generating new certificate..."
echo "  Service: $SERVICE_NAME"
echo "  Hostname: $HOSTNAME"  
echo "  IP: $HOST_IP"
echo ""

# Use portoser certificate library
export CERT_DIR="${CERT_DIR:-$PORTOSER_ROOT/client-certs}"
export CA_CERT_DIR="${CA_CERT_DIR:-$(dirname "$PORTOSER_ROOT")/postgres-ssl-setup/certs}"
export CADDY_CERT_BASE_DIR="${CADDY_CERT_BASE_DIR:-$SERVER_CERTS_DIR}"

# shellcheck source=/dev/null
source "$PORTOSER_LIB"

# Generate certificate to server-certs first
if generate_server_cert "$SERVICE_NAME" "$HOSTNAME" "$HOST_IP" "$SERVER_CERTS_DIR/$SERVICE_NAME"; then
    echo ""
    echo "✓ Certificate generated in server-certs"
    echo ""
    
    # Copy to service directory with registry-expected names
    echo "Copying to service directory..."
    
    # The registry expects these names (without -server suffix)
    cp "$SERVER_CERTS_DIR/$SERVICE_NAME/${SERVICE_NAME}-server-cert.pem" "$CERTS_DIR/${SERVICE_NAME}-cert.pem"
    cp "$SERVER_CERTS_DIR/$SERVICE_NAME/${SERVICE_NAME}-server-key.pem" "$CERTS_DIR/${SERVICE_NAME}-key.pem"
    cp "$SERVER_CERTS_DIR/$SERVICE_NAME/${SERVICE_NAME}-ca-cert.pem" "$CERTS_DIR/ca-cert.pem"
    
    echo "✓ Certificates ready in $CERTS_DIR"
    echo ""
    ls -lh "$CERTS_DIR"
else
    echo "❌ Failed to generate certificate"
    exit 1
fi

echo ""
echo "========================================"
echo "✅ Certificates Prepared"
echo "========================================"
echo ""
echo "Certificate files:"
echo "  Cert: ${SERVICE_NAME}-cert.pem"
echo "  Key:  ${SERVICE_NAME}-key.pem"
echo "  CA:   ca-cert.pem"
echo ""
echo "Ready for deployment!"
