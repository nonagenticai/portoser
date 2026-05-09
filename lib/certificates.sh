#!/usr/bin/env bash
# certificates.sh - Certificate management for mTLS services


# Returns 0 (true) if MACHINE refers to the host running this script.
# Recognises both the literal "local" alias and the actual short hostname.
_is_local_machine() {
    local machine="$1"
    local self
    self=$(hostname -s 2>/dev/null || hostname | cut -d. -f1)
    [ "$machine" = "local" ] || [ "$machine" = "$self" ]
}

set -euo pipefail

# Configuration
CERT_DIR="${CERT_DIR:-$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")")/client-certs}"
# Use postgres-ssl-setup as primary CA location (the original/complete CA)
CA_CERT_DIR="${CA_CERT_DIR:-${HOME}/portoser/ca/certs}"
CA_CERT="${CA_CERT:-$CA_CERT_DIR/ca-cert.pem}"
CA_KEY="${CA_KEY:-$CA_CERT_DIR/ca-key.pem}"
CERT_VALIDITY_DAYS="${CERT_VALIDITY_DAYS:-3650}"
# Caddy certificate base directory.
CADDY_CERT_BASE_DIR="${CADDY_CERT_BASE_DIR:-${HOME}/portoser/caddy/certs}"

# Check if CA exists
# Usage: check_ca_exists
check_ca_exists() {
    if [ ! -f "$CA_CERT" ] || [ ! -f "$CA_KEY" ]; then
        echo "Error: CA certificates not found" >&2
        echo "  Expected CA cert: $CA_CERT" >&2
        echo "  Expected CA key: $CA_KEY" >&2
        echo "" >&2
        echo "Run 'portoser certs init-ca' to create Certificate Authority" >&2
        return 1
    fi
    return 0
}

# Generate client certificate for a service
# Usage: generate_client_cert SERVICE_NAME [OUTPUT_DIR]
# SERVICE_NAME should be the directory name (with underscores)
# Certificate files will use dashes (underscores converted to dashes)
generate_client_cert() {
    local service_name="$1"
    local output_dir="${2:-$CERT_DIR}"

    if [ -z "$service_name" ]; then
        echo "Error: Service name required" >&2
        return 1
    fi

    if ! check_ca_exists; then
        echo "Run 'portoser certs init-ca' first to create Certificate Authority" >&2
        return 1
    fi

    mkdir -p "$output_dir"

    # Convert underscores to dashes for certificate filenames
    local cert_name="${service_name//_/-}"

    local cert_file="$output_dir/${cert_name}-cert.pem"
    local key_file="$output_dir/${cert_name}-key.pem"
    local req_file="$output_dir/${cert_name}-req.pem"

    echo "Generating client certificate for $service_name..."

    # Generate private key and CSR
    openssl req -new -nodes \
        -out "$req_file" \
        -keyout "$key_file" \
        -subj "/C=US/ST=State/L=City/O=HomeOrg/OU=IT/CN=${cert_name}_client" \
        2>&1 | grep -v "writing"

    # Sign certificate with CA
    openssl x509 -req -in "$req_file" \
        -days "$CERT_VALIDITY_DAYS" \
        -CA "$CA_CERT" \
        -CAkey "$CA_KEY" \
        -CAcreateserial \
        -out "$cert_file" \
        2>&1 | grep -v "Signature ok"

    # Set permissions
    chmod 600 "$key_file"
    chmod 644 "$cert_file"

    # Clean up
    rm -f "$req_file"

    echo "✓ Certificate generated:"
    echo "  Cert: $cert_file"
    echo "  Key:  $key_file"
    echo "  CA:   $CA_CERT"

    return 0
}

# Initialize Certificate Authority
# Usage: init_ca [OUTPUT_DIR]
init_ca() {
    local output_dir="${1:-$CA_CERT_DIR}"

    mkdir -p "$output_dir"

    local ca_cert="$output_dir/ca-cert.pem"
    local ca_key="$output_dir/ca-key.pem"

    if [ -f "$ca_cert" ] && [ -f "$ca_key" ]; then
        echo "CA already exists:"
        echo "  Cert: $ca_cert"
        echo "  Key:  $ca_key"
        echo ""
        echo "To regenerate, remove these files first:"
        echo "  rm $ca_cert $ca_key"
        return 1
    fi

    echo "Generating Certificate Authority..."

    openssl req -new -x509 -days "$CERT_VALIDITY_DAYS" -nodes \
        -out "$ca_cert" \
        -keyout "$ca_key" \
        -subj "/C=US/ST=State/L=City/O=HomeOrg/OU=IT/CN=PortoserCA" \
        2>&1 | grep -v "writing"

    chmod 600 "$ca_key"
    chmod 644 "$ca_cert"

    echo "✓ Certificate Authority created:"
    echo "  Cert: $ca_cert"
    echo "  Key:  $ca_key"

    return 0
}

# Deploy certificate to remote machine
# Usage: deploy_cert SERVICE_NAME MACHINE
deploy_cert() {
    local service_name="$1"
    local machine="$2"

    if [ -z "$service_name" ] || [ -z "$machine" ]; then
        echo "Error: Service name and machine required" >&2
        return 1
    fi

    local cert_file="$CERT_DIR/${service_name}-cert.pem"
    local key_file="$CERT_DIR/${service_name}-key.pem"

    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
        echo "Error: Certificate not found for $service_name" >&2
        echo "Run 'portoser certs generate $service_name' first" >&2
        return 1
    fi

    # Get machine info
    local machine_ip
    machine_ip=$(get_machine_ip "$machine")
    local ssh_user
    ssh_user=$(get_machine_ssh_user "$machine")

    echo "Deploying certificate to $machine ($machine_ip)..."

    # Get service working directory
    local working_dir
    working_dir=$(get_service_working_dir "$service_name" 2>/dev/null)

    if [ "$working_dir" = "null" ] || [ -z "$working_dir" ]; then
        echo "Error: No working directory found for $service_name" >&2
        return 1
    fi

    # Create certs directory on remote machine
    ssh -o ConnectTimeout=10 -o BatchMode=yes "${ssh_user}@${machine_ip}" "mkdir -p ${working_dir}/certs"

    # Copy certificates
    scp -o ConnectTimeout=10 "$cert_file" "${ssh_user}@${machine_ip}:${working_dir}/certs/"
    scp -o ConnectTimeout=10 "$key_file" "${ssh_user}@${machine_ip}:${working_dir}/certs/"
    scp -o ConnectTimeout=10 "$CA_CERT" "${ssh_user}@${machine_ip}:${working_dir}/certs/"

    # Set permissions on remote
    ssh -o ConnectTimeout=10 -o BatchMode=yes "${ssh_user}@${machine_ip}" "chmod 600 ${working_dir}/certs/*-key.pem && chmod 644 ${working_dir}/certs/*-cert.pem ${working_dir}/certs/ca-cert.pem"

    echo "✓ Certificates deployed to $machine:$working_dir/certs/"

    return 0
}

# List all certificates
# Usage: list_certs
list_certs() {
    echo "Certificate Authority:"
    if [ -f "$CA_CERT" ]; then
        echo "  ✓ CA Cert: $CA_CERT"
        openssl x509 -in "$CA_CERT" -noout -subject -dates 2>/dev/null
    else
        echo "  ✗ CA not found (run 'portoser certs init-ca')"
    fi

    echo ""
    echo "Client Certificates:"

    if [ ! -d "$CERT_DIR" ]; then
        echo "  No certificates directory"
        return 0
    fi

    local found=0
    for cert in "$CERT_DIR"/*-cert.pem; do
        if [ -f "$cert" ] && [ "$cert" != "$CA_CERT" ]; then
            found=1
            local service
            service=$(basename "$cert" -cert.pem)
            local key="${cert%-cert.pem}-key.pem"

            if [ -f "$key" ]; then
                echo "  ✓ $service"
                openssl x509 -in "$cert" -noout -subject -dates 2>/dev/null | sed 's/^/    /'
            else
                echo "  ⚠ $service (missing key)"
            fi
        fi
    done

    if [ $found -eq 0 ]; then
        echo "  No client certificates found"
    fi
}

# Check certificate expiry
# Usage: check_cert_expiry SERVICE_NAME
check_cert_expiry() {
    local service_name="${1:-all}"

    if [ "$service_name" = "all" ]; then
        # Check all certificates
        echo "Checking all certificates..."
        echo ""

        for cert in "$CERT_DIR"/*-cert.pem "$CA_CERT"; do
            if [ -f "$cert" ]; then
                local name
                name=$(basename "$cert" .pem)
                echo "$name:"
                openssl x509 -in "$cert" -noout -dates 2>/dev/null | sed 's/^/  /'

                # Check if expiring soon (30 days)
                local expiry
                expiry=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)
                # Use cross-platform date parsing with GNU date fallback for macOS
                local expiry_epoch
                if date --version >/dev/null 2>&1; then
                    # GNU date (Linux)
                    expiry_epoch=$(date -d "$expiry" "+%s" 2>/dev/null)
                else
                    # BSD date (macOS)
                    expiry_epoch=$(date -j -f "%b %d %T %Y %Z" "$expiry" "+%s" 2>/dev/null)
                fi
                local now_epoch
                now_epoch=$(date "+%s")
                local days_left
                days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

                if [ $days_left -lt 30 ]; then
                    echo "  ⚠️  WARNING: Expires in $days_left days!"
                fi
                echo ""
            fi
        done
    else
        # Check specific certificate
        local cert_file="$CERT_DIR/${service_name}-cert.pem"

        if [ ! -f "$cert_file" ]; then
            echo "Error: Certificate not found for $service_name" >&2
            return 1
        fi

        openssl x509 -in "$cert_file" -noout -text
    fi
}

# Generate certificate for all services that need it
# Usage: generate_all_service_certs
generate_all_service_certs() {
    echo "Generating certificates for all services with PostgreSQL mTLS..."
    echo ""

    local services
    services=$(yq eval '.services | to_entries | .[] | select(.value.notes // "" | test("[Mm][Tt][Ll][Ss]|certificate")) | .key' "$CADDY_REGISTRY_PATH")

    if [ -z "$services" ]; then
        echo "No services require mTLS certificates"
        return 0
    fi

    while IFS= read -r service; do
        if [ -n "$service" ]; then
            local cert_file="$CERT_DIR/${service}-cert.pem"

            if [ -f "$cert_file" ]; then
                echo "⊘ $service - certificate already exists"
            else
                if generate_client_cert "$service"; then
                    echo ""
                fi
            fi
        fi
    done <<< "$services"

    echo "✓ Certificate generation complete"
}

# Generate server certificate for a service
# Usage: generate_server_cert SERVICE_NAME HOSTNAME IP [OUTPUT_DIR]
# SERVICE_NAME should be the directory name (with underscores)
# Certificate files will use dashes (underscores converted to dashes)
generate_server_cert() {
    local service_name="$1"
    local hostname="$2"
    local ip="$3"
    local output_dir="${4:-$CADDY_CERT_BASE_DIR/$service_name}"

    if [ -z "$service_name" ] || [ -z "$hostname" ] || [ -z "$ip" ]; then
        echo "Error: Service name, hostname, and IP required" >&2
        echo "Usage: generate_server_cert SERVICE_NAME HOSTNAME IP [OUTPUT_DIR]" >&2
        return 1
    fi

    # Use the default CA (postgres-ssl-setup)
    if ! check_ca_exists; then
        echo "Run 'portoser certs init-ca' first to create Certificate Authority" >&2
        return 1
    fi
    local server_ca_cert="$CA_CERT"
    local server_ca_key="$CA_KEY"

    mkdir -p "$output_dir"

    # Convert underscores to dashes for certificate filenames
    local cert_name="${service_name//_/-}"

    echo "Generating server certificate for $service_name ($hostname @ $ip)..."

    # Generate private key and CSR
    openssl req -new -nodes \
        -out "$output_dir/${cert_name}-server-req.pem" \
        -keyout "$output_dir/${cert_name}-server-key.pem" \
        -subj "/C=US/ST=State/L=City/O=HomeOrg/OU=IT/CN=$hostname" \
        2>&1 | grep -v "writing"

    # Create extensions file with SAN
    cat > "$output_dir/${cert_name}-server-ext.cnf" <<EOF
basicConstraints=CA:FALSE
nsCertType=server
nsComment="OpenSSL Generated Server Certificate"
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer:always
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=@alt_names

[alt_names]
DNS.1=$hostname
DNS.2=localhost
IP.1=$ip
IP.2=127.0.0.1
EOF

    # Sign certificate with CA
    openssl x509 -req -in "$output_dir/${cert_name}-server-req.pem" \
        -days "$CERT_VALIDITY_DAYS" \
        -CA "$server_ca_cert" \
        -CAkey "$server_ca_key" \
        -CAcreateserial \
        -out "$output_dir/${cert_name}-server-cert.pem" \
        -extfile "$output_dir/${cert_name}-server-ext.cnf" \
        2>&1 | grep -v "Signature ok"

    # Set permissions
    chmod 600 "$output_dir/${cert_name}-server-key.pem"
    chmod 644 "$output_dir/${cert_name}-server-cert.pem"

    # Copy CA cert to service directory
    cp "$server_ca_cert" "$output_dir/${cert_name}-ca-cert.pem"
    chmod 644 "$output_dir/${cert_name}-ca-cert.pem"

    # Clean up temporary files
    rm -f "$output_dir/${cert_name}-server-req.pem" "$output_dir/${cert_name}-server-ext.cnf"

    echo "✓ Server certificate generated:"
    echo "  Cert: $output_dir/${cert_name}-server-cert.pem"
    echo "  Key:  $output_dir/${cert_name}-server-key.pem"
    echo "  CA:   $output_dir/${cert_name}-ca-cert.pem"

    return 0
}

# Generate server certificates for all services
# Usage: generate_all_server_certs
generate_all_server_certs() {
    local registry_file="${CADDY_REGISTRY_PATH}"

    echo "🔐 Generating server certificates for all HTTP services..."
    echo ""

    # Get list of all HTTP services (exclude TCP-only services)
    local services
    services=$(yq eval '.services | keys | .[]' "$registry_file")

    local count=0
    while IFS= read -r service; do
        if [ -z "$service" ]; then
            continue
        fi

        # Skip TCP-only services
        case "$service" in
            postgres|pgbouncer|neo4j|example_local)
                continue
                ;;
        esac

        # Get service details
        local hostname
        hostname=$(yq eval ".services.${service}.hostname" "$registry_file")
        local current_host
        current_host=$(yq eval ".services.${service}.current_host" "$registry_file")

        if [ "$hostname" = "null" ] || [ -z "$hostname" ] || [ "$current_host" = "null" ] || [ -z "$current_host" ]; then
            continue
        fi

        # Get machine IP
        local machine_ip
        machine_ip=$(get_machine_ip "$current_host" 2>/dev/null)
        if [ -z "$machine_ip" ] || [ "$machine_ip" = "unknown" ]; then
            echo "⚠ $service - skipping (cannot determine IP for $current_host)"
            continue
        fi

        # Generate certificate
        if generate_server_cert "$service" "$hostname" "$machine_ip"; then
            count=$((count + 1))
            echo ""
        fi
    done <<< "$services"

    echo "✓ Generated $count server certificates"
    echo ""
    echo "📌 Next step: Add TLS config to registry with 'portoser certs update-registry'"
    return 0
}

# Update registry with TLS certificate paths
# Usage: update_registry_tls_paths
update_registry_tls_paths() {
    local registry_file="${CADDY_REGISTRY_PATH}"
    local cert_base_dir="$CADDY_CERT_BASE_DIR"

    echo "📝 Updating registry with TLS certificate paths..."
    echo ""

    local services
    services=$(yq eval '.services | keys | .[]' "$registry_file")
    local count=0

    while IFS= read -r service; do
        if [ -z "$service" ]; then
            continue
        fi

        # Convert underscores to hyphens for directory/file names
        local file_name
        file_name=$(echo "$service" | tr '_' '-')

        # Skip services without certificates
        local cert_dir="$cert_base_dir/$file_name"
        local cert_file="$cert_dir/${file_name}-server-cert.pem"

        if [ ! -f "$cert_file" ]; then
            continue
        fi

        # Add TLS paths to registry
        yq eval -i ".services.${service}.tls_cert = \"${cert_dir}/${file_name}-server-cert.pem\"" "$registry_file"
        yq eval -i ".services.${service}.tls_key = \"${cert_dir}/${file_name}-server-key.pem\"" "$registry_file"
        yq eval -i ".services.${service}.ca_cert = \"${cert_dir}/${file_name}-ca-cert.pem\"" "$registry_file"

        echo "  ✓ $service"
        count=$((count + 1))
    done <<< "$services"

    echo ""
    echo "✓ Updated $count services in registry"
    echo ""
    echo "📌 Next steps:"
    echo "   1. Regenerate Caddyfile: portoser caddy regenerate"
    echo "   2. Reload Caddy: portoser caddy reload"
    return 0
}

# Deploy server certificates to remote machines
# Usage: deploy_server_certs [SERVICE...]
deploy_server_certs() {
    local registry_file="${CADDY_REGISTRY_PATH}"
    local cert_staging_dir="$CADDY_CERT_BASE_DIR"

    echo "🚀 Deploying server certificates to service directories..."
    echo ""

    # If specific services provided, deploy only those
    local services_to_deploy=""
    if [ $# -gt 0 ]; then
        services_to_deploy="$*"
    else
        # Deploy all services with certificates
        services_to_deploy=$(ls -1 "$cert_staging_dir" 2>/dev/null)
    fi

    local count=0
    for service in $services_to_deploy; do
        if [ -z "$service" ]; then
            continue
        fi

        local cert_dir="$cert_staging_dir/$service"

        if [ ! -d "$cert_dir" ]; then
            echo "⚠ $service - no certificates found, skipping"
            continue
        fi

        # Get service details from registry
        local current_host
        current_host=$(yq eval ".services.${service}.current_host" "$registry_file")
        local working_dir
        working_dir=$(get_service_working_dir "$service" 2>/dev/null)

        if [ "$current_host" = "null" ] || [ -z "$current_host" ]; then
            echo "⚠ $service - not deployed, skipping"
            continue
        fi

        if [ "$working_dir" = "null" ] || [ -z "$working_dir" ]; then
            echo "⚠ $service - no working directory in registry, skipping"
            continue
        fi

        local dest_path="$working_dir/certs"

        echo "📦 Deploying $service certificates to $current_host:$dest_path..."

        if _is_local_machine "$current_host"; then
            # Local deployment
            mkdir -p "$dest_path"
            cp "$cert_dir"/*.pem "$dest_path/"
            chmod 600 "$dest_path"/*-key.pem
            chmod 644 "$dest_path"/*-cert.pem "$dest_path"/*-ca-cert.pem
            echo "   ✓ Deployed locally"
        else
            # Remote deployment
            local machine_ip
            machine_ip=$(get_machine_ip "$current_host")
            local ssh_user
            ssh_user=$(get_machine_ssh_user "$current_host")

            if [ -z "$ssh_user" ] || [ "$ssh_user" = "null" ]; then
                echo "   ✗ Cannot determine SSH user for $current_host"
                continue
            fi

            ssh -o ConnectTimeout=10 -o BatchMode=yes "${ssh_user}@${current_host}.local" "mkdir -p $dest_path" 2>/dev/null || \
                ssh -o ConnectTimeout=10 -o BatchMode=yes "${ssh_user}@${machine_ip}" "mkdir -p $dest_path"
            scp -o ConnectTimeout=10 "$cert_dir"/*.pem "${ssh_user}@${current_host}.local:$dest_path/" 2>/dev/null || \
                scp -o ConnectTimeout=10 "$cert_dir"/*.pem "${ssh_user}@${machine_ip}:$dest_path/"
            ssh -o ConnectTimeout=10 -o BatchMode=yes "${ssh_user}@${current_host}.local" "chmod 600 $dest_path/*-key.pem && chmod 644 $dest_path/*-cert.pem $dest_path/*-ca-cert.pem" 2>/dev/null || \
                ssh -o ConnectTimeout=10 -o BatchMode=yes "${ssh_user}@${machine_ip}" "chmod 600 $dest_path/*-key.pem && chmod 644 $dest_path/*-cert.pem $dest_path/*-ca-cert.pem"
            echo "   ✓ Deployed to $current_host"
        fi

        count=$((count + 1))
    done

    echo ""
    echo "✓ Deployed certificates to $count services"
    return 0
}

# Distribute server certificates to all machines for service-to-service SSL verification
# Usage: distribute_all_server_certs
distribute_all_server_certs() {
    local registry_file="${CADDY_REGISTRY_PATH}"
    local cert_source_dir="$CADDY_CERT_BASE_DIR"

    echo "📦 Distributing server certificates to all machines..."
    echo ""

    # Get all machines from registry
    local machines
    machines=$(yq eval '.hosts | keys | .[]' "$registry_file")

    if [ -z "$machines" ]; then
        echo "No machines found in registry"
        return 1
    fi

    local total_distributed=0

    while IFS= read -r machine; do
        if [ -z "$machine" ] || _is_local_machine "$machine"; then
            # Skip empty entries and the local (source) machine
            continue
        fi

        echo "🔹 Processing machine: $machine"

        # Get machine details
        local machine_ip
        machine_ip=$(get_machine_ip "$machine")
        local ssh_user
        ssh_user=$(get_machine_ssh_user "$machine")
        local machine_path
        machine_path=$(yq eval ".hosts.$machine.path" "$registry_file" 2>/dev/null)

        if [ -z "$ssh_user" ] || [ "$ssh_user" = "null" ]; then
            echo "   ⚠ Cannot determine SSH user for $machine, skipping"
            continue
        fi

        # Determine target directory using host's path
        if [ -z "$machine_path" ] || [ "$machine_path" = "null" ]; then
            # Fallback when hosts.<machine>.path isn't set in the registry.
            local target_cert_dir="/home/${ssh_user}/caddy/certs"
        else
            local target_cert_dir="${machine_path}/caddy/certs"
        fi

        # Create base directory on remote machine
        ssh -o ConnectTimeout=10 -o BatchMode=yes "${ssh_user}@${machine}.local" "mkdir -p ${target_cert_dir}" 2>/dev/null || \
            ssh -o ConnectTimeout=10 -o BatchMode=yes "${ssh_user}@${machine_ip}" "mkdir -p ${target_cert_dir}"

        # Get services running on this machine
        local services_on_machine
        services_on_machine=$(yq eval ".services | to_entries | .[] | select(.value.current_host == \"$machine\") | .key" "$registry_file")

        # Build list of certificates needed (services on machine + their dependencies)
        local certs_needed=()

        # Add services running on this machine
        while IFS= read -r service; do
            if [ -n "$service" ]; then
                local file_name
                file_name=$(echo "$service" | tr '_' '-')
                certs_needed+=("$file_name")
            fi
        done <<< "$services_on_machine"

        # Pull in any explicit "always-distribute" services configured in the
        # registry (services every host might call into). Keep this list
        # data-driven so it works on any cluster, not the author's.
        local always_certs
        always_certs=$(yq eval '.cert_distribution.always // [] | .[]' "$registry_file" 2>/dev/null || true)
        while IFS= read -r svc; do
            [ -n "$svc" ] && certs_needed+=("$(echo "$svc" | tr '_' '-')")
        done <<< "$always_certs"

        # Cross-machine service dependencies: pull in certs for services this
        # machine's services depend on (registry's `dependencies:` field).
        while IFS= read -r service; do
            [ -z "$service" ] && continue
            local deps
            deps=$(yq eval ".services.${service}.dependencies // [] | .[]" "$registry_file" 2>/dev/null || true)
            while IFS= read -r dep; do
                [ -n "$dep" ] && certs_needed+=("$(echo "$dep" | tr '_' '-')")
            done <<< "$deps"
        done <<< "$services_on_machine"

        # Remove duplicates and sort
        local unique_certs
        mapfile -t unique_certs < <(printf '%s\n' "${certs_needed[@]}" | sort -u)

        echo "   Distributing ${#unique_certs[@]} certificate sets..."

        # Copy each certificate directory
        local machine_count=0
        for cert in "${unique_certs[@]}"; do
            local source_path="${cert_source_dir}/${cert}"

            if [ ! -d "$source_path" ]; then
                continue
            fi

            # Create target directory and copy certificates
            ssh -o ConnectTimeout=10 -o BatchMode=yes "${ssh_user}@${machine}.local" "mkdir -p ${target_cert_dir}/${cert}" 2>/dev/null || \
                ssh -o ConnectTimeout=10 -o BatchMode=yes "${ssh_user}@${machine_ip}" "mkdir -p ${target_cert_dir}/${cert}"

            if scp -o ConnectTimeout=10 -r "${source_path}"/*.pem "${ssh_user}@${machine}.local:${target_cert_dir}/${cert}/" 2>/dev/null || \
               scp -o ConnectTimeout=10 -r "${source_path}"/*.pem "${ssh_user}@${machine_ip}:${target_cert_dir}/${cert}/"; then
                machine_count=$((machine_count + 1))
            fi
        done

        echo "   ✓ Distributed ${machine_count} certificate sets to $machine"
        total_distributed=$((total_distributed + machine_count))
        echo ""
    done <<< "$machines"

    echo "✓ Certificate distribution complete!"
    echo ""
    echo "📌 Next steps:"
    echo "   1. Verify services can access certificates"
    echo "   2. Restart services to load new certificates"
    echo "   3. Test HTTPS connectivity between services"
    return 0
}

# Full deployment: Generate, distribute, and reload
# Usage: full_deploy_certs
full_deploy_certs() {
    echo "🚀 Full certificate deployment starting..."
    echo ""

    # Step 1: Generate all server certificates
    echo "═══════════════════════════════════════════════"
    echo "Step 1: Generating server certificates"
    echo "═══════════════════════════════════════════════"
    if ! generate_all_server_certs; then
        echo "✗ Certificate generation failed"
        return 1
    fi

    # Step 2: Update registry
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "Step 2: Updating registry with certificate paths"
    echo "═══════════════════════════════════════════════"
    if ! update_registry_tls_paths; then
        echo "✗ Registry update failed"
        return 1
    fi

    # Step 3: Distribute to all machines
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "Step 3: Distributing certificates to all machines"
    echo "═══════════════════════════════════════════════"
    if ! distribute_all_server_certs; then
        echo "✗ Certificate distribution failed"
        return 1
    fi

    # Step 4: Regenerate Caddyfile
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "Step 4: Regenerating Caddyfile"
    echo "═══════════════════════════════════════════════"
    if ! regenerate_caddyfile; then
        echo "⚠ Caddyfile regeneration failed, but continuing..."
    fi

    # Step 5: Reload Caddy
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "Step 5: Reloading Caddy"
    echo "═══════════════════════════════════════════════"
    if ! reload_caddyfile; then
        echo "⚠ Caddy reload failed, you may need to reload manually"
    fi

    echo ""
    echo "═══════════════════════════════════════════════"
    echo "✅ Full certificate deployment complete!"
    echo "═══════════════════════════════════════════════"
    echo ""
    echo "📝 Summary:"
    echo "   ✓ Generated server certificates"
    echo "   ✓ Updated registry with certificate paths"
    echo "   ✓ Distributed certificates to all machines"
    echo "   ✓ Regenerated Caddyfile"
    echo "   ✓ Reloaded Caddy"
    echo ""
    echo "📌 Recommendations:"
    echo "   - Restart services on remote machines to load new certificates"
    echo "   - Test HTTPS connectivity: curl -k https://SERVICE.${SERVICE_DNS_SUFFIX:-example.local}/health"
    echo "   - Monitor service logs for SSL/TLS errors"
    return 0
}

# ============================================================================
# Browser Certificate Management
# ============================================================================

# Check which CA certificates are installed in macOS System Keychain
# Usage: check_browser_certs [SERVICE]
check_browser_certs() {
    local service="${1:-all}"
    local registry_file="${CADDY_REGISTRY_PATH}"
    local cert_base_dir="$CADDY_CERT_BASE_DIR"

    echo "🔍 Checking installed CA certificates in System Keychain..."
    echo ""

    # Gather services to check
    local services_to_check=()
    if [ "$service" = "all" ]; then
        # Get all HTTP services with certificates
        local all_services
        all_services=$(yq eval '.services | keys | .[]' "$registry_file")
        while IFS= read -r svc; do
            if [ -z "$svc" ]; then
                continue
            fi
            # Skip TCP-only services
            case "$svc" in
                postgres|pgbouncer|neo4j|example_local|dnsmasq|caddy)
                    continue
                    ;;
            esac
            services_to_check+=("$svc")
        done <<< "$all_services"
    else
        services_to_check=("$service")
    fi

    local installed=0
    local missing=0

    for svc in "${services_to_check[@]}"; do
        if [ -z "$svc" ]; then
            continue
        fi

        local file_name
        file_name=$(echo "$svc" | tr '_' '-')
        local cert_name="${file_name}-ca-cert"
        local ca_cert_path="${cert_base_dir}/${file_name}/${file_name}-ca-cert.pem"

        # Check if certificate file exists
        if [ ! -f "$ca_cert_path" ]; then
            continue
        fi

        # Check if installed in System Keychain
        if security find-certificate -c "$cert_name" -a /Library/Keychains/System.keychain >/dev/null 2>&1; then
            echo "  ✓ ${svc} (${cert_name})"
            ((installed++))
        else
            echo "  ✗ ${svc} (${cert_name}) - NOT INSTALLED"
            ((missing++))
        fi
    done

    echo ""
    echo "Summary:"
    echo "  Installed: ${installed}"
    echo "  Missing: ${missing}"
    echo ""

    if [ $missing -gt 0 ]; then
        echo "💡 Run 'portoser certs install-browser' to install missing certificates"
    else
        echo "✅ All CA certificates are installed!"
    fi

    return 0
}

# Install CA certificates to macOS System Keychain for browser trust
# Usage: install_browser_certs [SERVICE]
install_browser_certs() {
    local service="${1:-all}"
    local registry_file="${CADDY_REGISTRY_PATH}"
    local cert_base_dir="$CADDY_CERT_BASE_DIR"

    echo "🔐 Installing CA certificates to System Keychain..."
    echo ""
    echo "This will allow your browser (Safari, Chrome, Firefox) to trust"
    echo "HTTPS connections to *.internal services."
    echo ""
    echo "⚠️  You will be prompted for your macOS password for each certificate."
    echo ""

    read -p "Continue? (y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        return 1
    fi

    echo ""

    # Gather services to install
    local services_to_install=()
    if [ "$service" = "all" ]; then
        # Get all HTTP services with certificates
        local all_services
        all_services=$(yq eval '.services | keys | .[]' "$registry_file")
        while IFS= read -r svc; do
            if [ -z "$svc" ]; then
                continue
            fi
            # Skip TCP-only services
            case "$svc" in
                postgres|pgbouncer|neo4j|example_local|dnsmasq|caddy)
                    continue
                    ;;
            esac
            services_to_install+=("$svc")
        done <<< "$all_services"
    else
        services_to_install=("$service")
    fi

    local installed=0
    local skipped=0
    local failed=0

    for svc in "${services_to_install[@]}"; do
        if [ -z "$svc" ]; then
            continue
        fi

        local file_name
        file_name=$(echo "$svc" | tr '_' '-')
        local cert_name="${file_name}-ca-cert"
        local ca_cert_path="${cert_base_dir}/${file_name}/${file_name}-ca-cert.pem"

        # Check if certificate file exists
        if [ ! -f "$ca_cert_path" ]; then
            echo "  ✗ ${svc}: Certificate file not found"
            echo "     Expected: ${ca_cert_path}"
            ((failed++))
            continue
        fi

        # Check if already installed
        if security find-certificate -c "$cert_name" -a /Library/Keychains/System.keychain >/dev/null 2>&1; then
            echo "  ⊙ ${svc}: Already installed (skipping)"
            ((skipped++))
            continue
        fi

        # Install certificate to System keychain
        echo "  Installing ${svc} (${cert_name})..."
        if sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$ca_cert_path" 2>/dev/null; then
            echo "  ✓ ${svc}: Installed successfully"
            ((installed++))
        else
            echo "  ✗ ${svc}: Installation failed"
            ((failed++))
        fi
    done

    echo ""
    echo "═══════════════════════════════════════════════"
    echo "Installation Summary"
    echo "═══════════════════════════════════════════════"
    echo "  Installed: ${installed}"
    echo "  Skipped (already installed): ${skipped}"
    echo "  Failed: ${failed}"
    echo ""

    if [ $installed -gt 0 ] || [ $skipped -gt 0 ]; then
        echo "✅ Certificates are now trusted by your browser!"
        echo ""
        echo "📝 Test these URLs in your browser:"
        local sample_services
        sample_services=$(yq eval '.services | keys | .[]' "$registry_file" | head -5)
        while IFS= read -r sample_svc; do
            if [ -n "$sample_svc" ]; then
                local hostname
                hostname=$(yq eval ".services.${sample_svc}.hostname" "$registry_file")
                if [ "$hostname" != "null" ] && [ -n "$hostname" ]; then
                    echo "  https://${hostname}/health"
                fi
            fi
        done <<< "$sample_services"
        echo ""
        echo "⚠️  Note: You may need to restart your browser for changes to take effect"
    else
        echo "❌ No certificates were installed. Please check the errors above."
    fi

    return 0
}

# Uninstall CA certificates from macOS System Keychain
# Usage: uninstall_browser_certs [SERVICE]
uninstall_browser_certs() {
    local service="${1:-all}"
    local registry_file="${CADDY_REGISTRY_PATH}"
    local cert_base_dir="$CADDY_CERT_BASE_DIR"

    echo "🗑️  Removing CA certificates from System Keychain..."
    echo ""
    echo "⚠️  This will remove trust for *.internal services in your browser."
    echo ""

    read -p "Continue? (y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        return 1
    fi

    echo ""

    # Gather services to uninstall
    local services_to_remove=()
    if [ "$service" = "all" ]; then
        # Get all HTTP services
        local all_services
        all_services=$(yq eval '.services | keys | .[]' "$registry_file")
        while IFS= read -r svc; do
            if [ -z "$svc" ]; then
                continue
            fi
            # Skip TCP-only services
            case "$svc" in
                postgres|pgbouncer|neo4j|example_local|dnsmasq|caddy)
                    continue
                    ;;
            esac
            services_to_remove+=("$svc")
        done <<< "$all_services"
    else
        services_to_remove=("$service")
    fi

    local removed=0
    local not_found=0

    for svc in "${services_to_remove[@]}"; do
        if [ -z "$svc" ]; then
            continue
        fi

        local file_name
        file_name=$(echo "$svc" | tr '_' '-')
        local cert_name="${file_name}-ca-cert"

        # Check if installed
        if ! security find-certificate -c "$cert_name" -a /Library/Keychains/System.keychain >/dev/null 2>&1; then
            echo "  ⊙ ${svc}: Not installed (skipping)"
            ((not_found++))
            continue
        fi

        # Get certificate hash
        local cert_hash
        cert_hash=$(security find-certificate -c "$cert_name" -a /Library/Keychains/System.keychain -Z | grep "^SHA-1" | awk '{print $3}')

        if [ -z "$cert_hash" ]; then
            echo "  ✗ ${svc}: Could not find certificate hash"
            continue
        fi

        # Delete certificate
        echo "  Removing ${svc} (${cert_name})..."
        if sudo security delete-certificate -Z "$cert_hash" /Library/Keychains/System.keychain 2>/dev/null; then
            echo "  ✓ ${svc}: Removed successfully"
            ((removed++))
        else
            echo "  ✗ ${svc}: Removal failed"
        fi
    done

    echo ""
    echo "═══════════════════════════════════════════════"
    echo "Removal Summary"
    echo "═══════════════════════════════════════════════"
    echo "  Removed: ${removed}"
    echo "  Not found: ${not_found}"
    echo ""

    if [ $removed -gt 0 ]; then
        echo "✅ Certificates removed from System Keychain"
        echo ""
        echo "⚠️  Note: You may need to restart your browser"
    fi

    return 0
}

# ============================================================================
# Keycloak CA Distribution
# ============================================================================

# Copy Keycloak CA certificate to service directory
# Usage: copy_keycloak_ca_to_service SERVICE [MACHINE]
copy_keycloak_ca_to_service() {
    local service_name="$1"
    local machine="${2:-}"
    local registry_file="${CADDY_REGISTRY_PATH}"
    local keycloak_ca_source="${KEYCLOAK_CA_SOURCE:-${HOME}/portoser/keycloak/certs/ca-cert.pem}"

    if [ -z "$service_name" ]; then
        echo "Error: Service name required" >&2
        echo "Usage: copy_keycloak_ca_to_service SERVICE [MACHINE]" >&2
        return 1
    fi

    # Check if Keycloak CA exists
    if [ ! -f "$keycloak_ca_source" ]; then
        echo "Error: Keycloak CA certificate not found at $keycloak_ca_source" >&2
        return 1
    fi

    # Get service details from registry
    if [ -z "$machine" ]; then
        machine=$(yq eval ".services.${service_name}.current_host" "$registry_file")
    fi

    if [ "$machine" = "null" ] || [ -z "$machine" ]; then
        echo "Error: Cannot determine machine for service $service_name" >&2
        return 1
    fi

    local working_dir
    working_dir=$(get_service_working_dir "$service_name" 2>/dev/null)

    if [ "$working_dir" = "null" ] || [ -z "$working_dir" ]; then
        echo "Error: Cannot determine working directory for $service_name" >&2
        return 1
    fi

    local dest_path="$working_dir/certs/keycloak-ca-cert.pem"

    echo "📦 Copying Keycloak CA certificate to $service_name..."
    echo "   Source: $keycloak_ca_source"
    echo "   Destination: $machine:$dest_path"

    if _is_local_machine "$machine"; then
        # Local copy
        mkdir -p "$(dirname "$dest_path")"
        cp "$keycloak_ca_source" "$dest_path"
        chmod 644 "$dest_path"
        echo "   ✓ Copied locally"
    else
        # Remote copy
        local machine_ip
        machine_ip=$(get_machine_ip "$machine")
        local ssh_user
        ssh_user=$(get_machine_ssh_user "$machine")

        if [ -z "$ssh_user" ] || [ "$ssh_user" = "null" ]; then
            echo "   ✗ Cannot determine SSH user for $machine"
            return 1
        fi

        # Create certs directory and copy. dirname runs locally (the result is
        # baked into the SSH command string), so quote $dest_path here.
        local dest_dir
        dest_dir=$(dirname "$dest_path")
        ssh -o ConnectTimeout=10 -o BatchMode=yes "${ssh_user}@${machine}.local" "mkdir -p '$dest_dir'" 2>/dev/null || \
            ssh -o ConnectTimeout=10 -o BatchMode=yes "${ssh_user}@${machine_ip}" "mkdir -p '$dest_dir'"

        scp -o ConnectTimeout=10 "$keycloak_ca_source" "${ssh_user}@${machine}.local:$dest_path" 2>/dev/null || \
            scp -o ConnectTimeout=10 "$keycloak_ca_source" "${ssh_user}@${machine_ip}:$dest_path"

        ssh -o ConnectTimeout=10 -o BatchMode=yes "${ssh_user}@${machine}.local" "chmod 644 $dest_path" 2>/dev/null || \
            ssh -o ConnectTimeout=10 -o BatchMode=yes "${ssh_user}@${machine_ip}" "chmod 644 $dest_path"

        echo "   ✓ Copied to $machine"
    fi

    return 0
}

# Copy Keycloak CA to all services that need it
# Usage: copy_keycloak_ca_to_all_services
copy_keycloak_ca_to_all_services() {
    local registry_file="${CADDY_REGISTRY_PATH}"

    echo "📦 Copying Keycloak CA certificate to all services..."
    echo ""

    # Get all services
    local services
    services=$(yq eval '.services | keys | .[]' "$registry_file")

    local count=0
    local skipped=0

    while IFS= read -r service; do
        if [ -z "$service" ]; then
            continue
        fi

        # Skip services that don't use Keycloak (infrastructure services)
        case "$service" in
            postgres|pgbouncer|neo4j|dnsmasq|caddy|storage_service)
                ((skipped++))
                continue
                ;;
        esac

        if copy_keycloak_ca_to_service "$service"; then
            ((count++))
        fi
        echo ""
    done <<< "$services"

    echo "✓ Copied Keycloak CA to $count services (skipped $skipped infrastructure services)"
    return 0
}

# ============================================================================
# Certificate Validation
# ============================================================================

# Validate that a service has all required certificates
# Usage: validate_service_certs SERVICE
validate_service_certs() {
    local service_name="$1"
    local registry_file="${CADDY_REGISTRY_PATH}"

    if [ -z "$service_name" ]; then
        echo "Error: Service name required" >&2
        echo "Usage: validate_service_certs SERVICE" >&2
        return 1
    fi

    echo "🔍 Validating certificates for $service_name..."
    echo ""

    # Get service details
    local current_host
    current_host=$(yq eval ".services.${service_name}.current_host" "$registry_file")
    local working_dir
    working_dir=$(get_service_working_dir "$service_name" 2>/dev/null)

    if [ "$current_host" = "null" ] || [ -z "$current_host" ]; then
        echo "  ✗ Service not found in registry"
        return 1
    fi

    local all_valid=true
    local certs_checked=0

    # Check PostgreSQL client certificates (if service uses database)
    case "$service_name" in
        neo4j|dnsmasq|caddy|storage_service)
            # Services without PostgreSQL
            ;;
        *)
            # Most services use PostgreSQL
            echo "  Checking PostgreSQL client certificates..."
            local pg_certs=("ca-cert.pem" "${service_name}-cert.pem" "${service_name}-key.pem")

            for cert_file in "${pg_certs[@]}"; do
                local cert_path="$working_dir/certs/$cert_file"

                if _is_local_machine "$current_host"; then
                    if [ -f "$cert_path" ]; then
                        echo "    ✓ $cert_file"
                        ((certs_checked++))
                    else
                        echo "    ✗ $cert_file - MISSING"
                        all_valid=false
                    fi
                else
                    # Check on remote machine
                    local ssh_user
                    ssh_user=$(get_machine_ssh_user "$current_host")
                    if ssh -o ConnectTimeout=10 -o BatchMode=yes "${ssh_user}@${current_host}.local" "[ -f $cert_path ]" 2>/dev/null || \
                       ssh -o ConnectTimeout=10 -o BatchMode=yes "${ssh_user}@$(get_machine_ip "$current_host")" "[ -f $cert_path ]" 2>/dev/null; then
                        echo "    ✓ $cert_file"
                        ((certs_checked++))
                    else
                        echo "    ✗ $cert_file - MISSING"
                        all_valid=false
                    fi
                fi
            done
            ;;
    esac

    # Check Keycloak CA certificate (if service uses Keycloak)
    case "$service_name" in
        postgres|pgbouncer|neo4j|dnsmasq|caddy|storage_service)
            # Services without Keycloak auth
            ;;
        *)
            echo "  Checking Keycloak CA certificate..."
            local keycloak_ca_path="$working_dir/certs/keycloak-ca-cert.pem"

            if _is_local_machine "$current_host"; then
                if [ -f "$keycloak_ca_path" ]; then
                    echo "    ✓ keycloak-ca-cert.pem"
                    ((certs_checked++))
                else
                    echo "    ⚠  keycloak-ca-cert.pem - MISSING (may need: portoser certs copy-keycloak-ca $service_name)"
                    all_valid=false
                fi
            else
                local ssh_user
                ssh_user=$(get_machine_ssh_user "$current_host")
                if ssh -o ConnectTimeout=10 -o BatchMode=yes "${ssh_user}@${current_host}.local" "[ -f $keycloak_ca_path ]" 2>/dev/null || \
                   ssh -o ConnectTimeout=10 -o BatchMode=yes "${ssh_user}@$(get_machine_ip "$current_host")" "[ -f $keycloak_ca_path ]" 2>/dev/null; then
                    echo "    ✓ keycloak-ca-cert.pem"
                    ((certs_checked++))
                else
                    echo "    ⚠  keycloak-ca-cert.pem - MISSING (may need: portoser certs copy-keycloak-ca $service_name)"
                    all_valid=false
                fi
            fi
            ;;
    esac

    # Check Caddy server certificates (on the local machine only, for all services)
    echo "  Checking Caddy server certificates (local)..."
    local file_name
    file_name=$(echo "$service_name" | tr '_' '-')
    local caddy_cert_dir="$CADDY_CERT_BASE_DIR/$file_name"
    local server_certs=("${file_name}-server-cert.pem" "${file_name}-server-key.pem" "${file_name}-ca-cert.pem")

    for cert_file in "${server_certs[@]}"; do
        local cert_path="$caddy_cert_dir/$cert_file"
        if [ -f "$cert_path" ]; then
            echo "    ✓ $cert_file"
            ((certs_checked++))
        else
            echo "    ✗ $cert_file - MISSING (run: portoser certs generate-server $service_name)"
            all_valid=false
        fi
    done

    echo ""
    if [ "$all_valid" = true ]; then
        echo "✅ All certificates valid ($certs_checked certificates checked)"
        return 0
    else
        echo "❌ Missing certificates! Service may fail to start."
        echo ""
        echo "💡 Recommended actions:"
        echo "   1. Generate PostgreSQL client certs: portoser certs generate $service_name"
        echo "   2. Deploy to machine: portoser certs deploy $service_name $current_host"
        echo "   3. Copy Keycloak CA: portoser certs copy-keycloak-ca $service_name"
        echo "   4. Generate Caddy server certs: portoser certs generate-server $service_name"
        return 1
    fi
}
