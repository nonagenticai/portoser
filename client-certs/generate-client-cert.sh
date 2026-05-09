#!/bin/bash
# Usage: ./generate-client-cert.sh <client-name> <ca-cert-path> <ca-key-path>

CLIENT_NAME=$1
CA_CERT=$2
CA_KEY=$3

cat > ${CLIENT_NAME}.cnf << CERTEOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
C=US
ST=State
L=City
O=HomeOrg
OU=IT
CN=${CLIENT_NAME}

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
CERTEOF

# Generate private key
openssl genrsa -out ${CLIENT_NAME}-key.pem 2048

# Generate CSR
openssl req -new -key ${CLIENT_NAME}-key.pem -out ${CLIENT_NAME}.csr -config ${CLIENT_NAME}.cnf

# Sign with CA
openssl x509 -req -in ${CLIENT_NAME}.csr -CA ${CA_CERT} -CAkey ${CA_KEY} -CAcreateserial \
  -out ${CLIENT_NAME}-cert.pem -days 3650 -extensions v3_req -extfile ${CLIENT_NAME}.cnf

echo "Generated client certificate for: ${CLIENT_NAME}"
echo "  Certificate: ${CLIENT_NAME}-cert.pem"
echo "  Private Key: ${CLIENT_NAME}-key.pem"
