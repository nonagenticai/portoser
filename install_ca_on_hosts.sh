#!/usr/bin/env bash
# Install a CA certificate on every host listed in cluster.conf.
#
# Usage:
#   CA_CERT=/path/to/ca-cert.pem ./install_ca_on_hosts.sh
#
# Optional env vars:
#   CA_CERT       Path to the PEM-encoded CA certificate to install (required).
#   CLUSTER_CONF  Path to cluster.conf (defaults to ./cluster.conf).
#   CA_NAME       Filename to install under /usr/local/share/ca-certificates
#                 (defaults to portoser-ca.crt).
#
# Targets every entry in CLUSTER_HOSTS. Assumes Debian/Ubuntu-style hosts
# with `update-ca-certificates`; adjust for other distros as needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CA_CERT="${CA_CERT:-}"
CA_NAME="${CA_NAME:-portoser-ca.crt}"

if [ -z "$CA_CERT" ]; then
    echo "ERROR: Set CA_CERT to the path of the CA certificate to install." >&2
    exit 1
fi

if [ ! -f "$CA_CERT" ]; then
    echo "❌ CA certificate not found at: $CA_CERT" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Load cluster topology (CLUSTER_HOSTS)
# -----------------------------------------------------------------------------
CLUSTER_CONF="${CLUSTER_CONF:-$SCRIPT_DIR/cluster.conf}"
if [[ ! -f "$CLUSTER_CONF" ]]; then
    echo "ERROR: cluster.conf not found at $CLUSTER_CONF" >&2
    echo "       Copy cluster.conf.example to cluster.conf and edit for your environment." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CLUSTER_CONF"

echo "📋 Installing CA certificate ($CA_CERT) on ${#CLUSTER_HOSTS[@]} host(s)..."
echo ""

for host_label in "${!CLUSTER_HOSTS[@]}"; do
    ssh_target="${CLUSTER_HOSTS[$host_label]}"

    echo "🔧 Processing $host_label ($ssh_target)..."

    echo "  📤 Copying CA certificate..."
    if scp -o StrictHostKeyChecking=accept-new "$CA_CERT" "$ssh_target:/tmp/$CA_NAME"; then
        echo "  ✅ Certificate copied"
    else
        echo "  ❌ Failed to copy certificate to $host_label"
        continue
    fi

    echo "  🔐 Installing CA certificate..."
    if ssh -o StrictHostKeyChecking=accept-new "$ssh_target" \
        "sudo cp /tmp/$CA_NAME /usr/local/share/ca-certificates/$CA_NAME && sudo update-ca-certificates && rm /tmp/$CA_NAME"; then
        echo "  ✅ CA certificate installed on $host_label"
    else
        echo "  ❌ Failed to install CA certificate on $host_label"
    fi

    echo ""
done

echo "✅ CA certificate installation complete on all hosts!"
