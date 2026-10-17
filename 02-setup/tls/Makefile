# 02-Setup PKI: root CA, iPXE script server and iPXE client certificates
# Private keys are SOPS-encrypted in place; plaintext only exists in a temp dir.

SHELL       := bash
.SHELLFLAGS := -euo pipefail -c

SUBJ_BASE := /C=US/ST=Lab/L=Lab/O=02-Setup
CA_DAYS   := 3650
DAYS      := 365

SERVER_CN  := ipxe.setup02.local
SERVER_SAN := DNS:ipxe.setup02.local,DNS:ipxe,IP:10.0.20.3
CLIENT_CN  := edge-site-1

.PHONY: help ca ipxe-server ipxe-client sign verify

.DEFAULT_GOAL := help

help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Issue

ca: ## Create the root CA (refuses to overwrite)
	test ! -e ca.key || (echo "Error: ca.key exists, remove it to recreate the CA" && exit 1)
	tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; umask 077; \
	openssl req -x509 -new -newkey rsa:4096 -noenc -sha256 -days $(CA_DAYS) \
		-keyout "$$tmp/ca.key" -out ca.crt -subj "$(SUBJ_BASE)/CN=02-Setup Root CA" \
		-addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
		-addext "keyUsage=critical,keyCertSign,cRLSign"; \
	sops -e --input-type binary --output-type binary --filename-override ca.key "$$tmp/ca.key" > ca.key
	@echo "✓ CA: ca.crt, ca.key (encrypted)"

ipxe-server: ## Issue the iPXE script server certificate
	$(MAKE) sign NAME=ipxe-server CN=$(SERVER_CN) \
		EXT="subjectAltName=$(SERVER_SAN)" EKU=serverAuth KU=digitalSignature,keyEncipherment

ipxe-client: ## Issue the iPXE client certificate for mTLS
	$(MAKE) sign NAME=ipxe-client CN=$(CLIENT_CN) \
		EXT="subjectAltName=DNS:$(CLIENT_CN)" EKU=clientAuth KU=digitalSignature

# Generic leaf issuance: NAME, CN, EXT, EKU, KU
sign:
	tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; umask 077; \
	openssl req -new -newkey rsa:2048 -noenc -keyout "$$tmp/$(NAME).key" -out "$$tmp/$(NAME).csr" \
		-subj "$(SUBJ_BASE)/CN=$(CN)"; \
	printf '%s\n' "basicConstraints=critical,CA:FALSE" "keyUsage=critical,$(KU)" \
		"extendedKeyUsage=$(EKU)" "$(EXT)" > "$$tmp/ext.cnf"; \
	sops -d --input-type binary --output-type binary ca.key > "$$tmp/ca.key"; \
	openssl x509 -req -in "$$tmp/$(NAME).csr" -CA ca.crt -CAkey "$$tmp/ca.key" -CAcreateserial \
		-CAserial "$$tmp/ca.srl" -days $(DAYS) -sha256 -extfile "$$tmp/ext.cnf" -out $(NAME).crt; \
	sops -e --input-type binary --output-type binary --filename-override $(NAME).key "$$tmp/$(NAME).key" > $(NAME).key
	@echo "✓ $(NAME): $(NAME).crt, $(NAME).key (encrypted)"

##@ Verification

verify: ## Verify leaf certificates against the CA and show their validity
	openssl verify -CAfile ca.crt ipxe-server.crt ipxe-client.crt
	for c in ca ipxe-server ipxe-client; do \
		openssl x509 -in $$c.crt -noout -subject -enddate -ext subjectAltName,extendedKeyUsage 2>/dev/null; echo; done
