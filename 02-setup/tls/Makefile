# 02-Setup PKI: root CA, Boot and Cluster intermediate CAs, iPXE server and client certificates
# Private keys are SOPS-encrypted in place; plaintext only exists in a temp dir.

SHELL       := bash
.SHELLFLAGS := -euo pipefail -c

SUBJ_BASE := /C=US/ST=Lab/L=Lab/O=02-Setup
CA_DAYS   := 3650
DAYS      := 365
BITS      := 2048
BC        := CA:FALSE

SERVER_CN  := ipxe.setup02.local
SERVER_SAN := DNS:ipxe.setup02.local,DNS:ipxe,IP:10.0.20.3
CLIENT_CN  := edge-site-1

.PHONY: help ca boot-ca cluster-ca ipxe-server ipxe-client sign verify

.DEFAULT_GOAL := help

help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Issue

ca: ## Create the root CA (refuses to overwrite)
	test ! -e ca.key || (echo "Error: ca.key exists, remove it to recreate the CA" && exit 1)
	tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; umask 077; \
	openssl req -x509 -new -newkey rsa:4096 -noenc -sha256 -days $(CA_DAYS) \
		-keyout "$$tmp/ca.key" -out ca.crt -subj "$(SUBJ_BASE)/CN=02-Setup Root CA" \
		-addext "basicConstraints=critical,CA:TRUE,pathlen:1" \
		-addext "keyUsage=critical,keyCertSign,cRLSign"; \
	sops -e --input-type binary --output-type binary --filename-override ca.key "$$tmp/ca.key" > ca.key
	@echo "✓ CA: ca.crt, ca.key (encrypted)"

boot-ca: ## Issue the Boot CA, the iPXE trust anchor that signs the iPXE certificates
	$(MAKE) sign NAME=boot-ca CN="02-Setup Boot CA" ISSUER=ca BITS=4096 DAYS=$(CA_DAYS) \
		BC="CA:TRUE,pathlen:0" KU=keyCertSign,cRLSign

cluster-ca: ## Issue the Cluster CA, held by cert-manager as the lab-ca ClusterIssuer
	$(MAKE) sign NAME=cluster-ca CN="02-Setup Cluster CA" ISSUER=ca BITS=4096 DAYS=$(CA_DAYS) \
		BC="CA:TRUE,pathlen:0" KU=keyCertSign,cRLSign

ipxe-server: ## Issue the iPXE script server certificate
	$(MAKE) sign NAME=ipxe-server CN=$(SERVER_CN) ISSUER=boot-ca \
		EXT="subjectAltName=$(SERVER_SAN)" EKU=serverAuth KU=digitalSignature,keyEncipherment

ipxe-client: ## Issue the iPXE client certificate for mTLS
	$(MAKE) sign NAME=ipxe-client CN=$(CLIENT_CN) ISSUER=boot-ca \
		EXT="subjectAltName=DNS:$(CLIENT_CN)" EKU=clientAuth KU=digitalSignature

# Generic issuance: NAME, CN, ISSUER, KU; optional EKU, EXT, BC, BITS, DAYS
sign:
	tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; umask 077; \
	openssl req -new -newkey rsa:$(BITS) -noenc -keyout "$$tmp/$(NAME).key" -out "$$tmp/$(NAME).csr" \
		-subj "$(SUBJ_BASE)/CN=$(CN)"; \
	printf '%s\n' "basicConstraints=critical,$(BC)" "keyUsage=critical,$(KU)" \
		$(if $(EKU),"extendedKeyUsage=$(EKU)") "$(EXT)" > "$$tmp/ext.cnf"; \
	sops -d --input-type binary --output-type binary $(ISSUER).key > "$$tmp/issuer.key"; \
	openssl x509 -req -in "$$tmp/$(NAME).csr" -CA $(ISSUER).crt -CAkey "$$tmp/issuer.key" -CAcreateserial \
		-CAserial "$$tmp/issuer.srl" -days $(DAYS) -sha256 -extfile "$$tmp/ext.cnf" -out $(NAME).crt; \
	sops -e --input-type binary --output-type binary --filename-override $(NAME).key "$$tmp/$(NAME).key" > $(NAME).key
	@echo "✓ $(NAME): $(NAME).crt, $(NAME).key (encrypted)"

##@ Verification

verify: ## Verify the chain and show each certificate's validity
	openssl verify -CAfile ca.crt boot-ca.crt cluster-ca.crt
	openssl verify -CAfile ca.crt -untrusted boot-ca.crt ipxe-server.crt ipxe-client.crt
	for c in ca boot-ca cluster-ca ipxe-server ipxe-client; do \
		openssl x509 -in $$c.crt -noout -subject -issuer -enddate -ext basicConstraints,subjectAltName,extendedKeyUsage 2>/dev/null; echo; done
