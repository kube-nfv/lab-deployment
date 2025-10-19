# TLS Certificates

This directory contains the Root CA and TLS certificates for the 01-setup network infrastructure.

## Root CA

**Files:**
- `ca.crt` - Root CA certificate (for trusting signed certificates)
- `ca.key` - Root CA private key (for signing new certificates)

**Details:**
- Subject: CN=01-Setup Root CA
- Validity: 10 years
- Purpose: Sign server certificates for 01-setup infrastructure

## Provision New Certificate

```bash
cd ~/dev/github.com/kube-nfv/lab-deployments/01-setup/tls

# 1. Generate private key
openssl genrsa -out service-name.key 2048

# 2. Create certificate signing request
openssl req -new -key service-name.key -out service-name.csr \
    -subj "/C=US/ST=Lab/L=Lab/O=01-Setup/CN=service.setup01.local"

# 3. Create SAN configuration
cat > service-name-san.cnf <<EOF
subjectAltName = @alt_names
extendedKeyUsage = serverAuth
keyUsage = keyEncipherment, dataEncipherment

[alt_names]
DNS.1 = service.setup01.local
DNS.2 = service
IP.1 = 10.0.10.X
EOF

# 4. Sign certificate with Root CA
openssl x509 -req -in service-name.csr \
    -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out service-name.crt \
    -days 365 -sha256 \
    -extfile service-name-san.cnf

# 5. Verify certificate
openssl x509 -in service-name.crt -text -noout | grep -A 3 "Subject Alternative Name"

# 6. Clean up
rm service-name.csr service-name-san.cnf ca.srl
```

## Generated Certificates

### Matchbox Server
- **Files:** `matchbox-server.crt`, `matchbox-server.key`
- **CN:** matchbox.setup01.local
- **SAN:** DNS:matchbox.setup01.local, DNS:matchbox, IP:10.0.10.3
- **Validity:** 365 days
