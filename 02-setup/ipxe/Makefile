# iPXE EFI binary trusting only the 02-Setup CA, with the iPXE client cert for mTLS
# The output embeds the client private key in plaintext: keep it out of git.

SHELL       := bash
.SHELLFLAGS := -euo pipefail -c

IPXE_VERSION := v2.0.0
ARCH         ?= arm64

TLS_DIR := $(CURDIR)/../tls
OUT_DIR := $(CURDIR)/../_out/ipxe/$(ARCH)

ifeq ($(ARCH),arm64)
PLATFORM := linux/arm64
else ifeq ($(ARCH),x86_64)
PLATFORM := linux/amd64
else
$(error ARCH must be arm64 or x86_64)
endif

.PHONY: help build clean

.DEFAULT_GOAL := help

help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

build: ## Build _out/ipxe/$(ARCH)/ipxe.efi (ARCH=arm64|x86_64)
	mkdir -p $(OUT_DIR)
	tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; umask 077; \
	cp $(TLS_DIR)/ca.crt $(TLS_DIR)/ipxe-client.crt "$$tmp/"; \
	sops -d --input-type binary --output-type binary $(TLS_DIR)/ipxe-client.key > "$$tmp/ipxe-client.key"; \
	chmod 644 "$$tmp"/*; chmod 755 "$$tmp"; \
	docker run --rm --platform $(PLATFORM) -v "$$tmp":/tls:ro -v $(OUT_DIR):/out \
		debian:bookworm-slim bash -euo pipefail -c ' \
		apt-get update -qq && apt-get install -qq -y --no-install-recommends \
			build-essential ca-certificates git liblzma-dev mtools perl >/dev/null; \
		git clone -q --depth 1 --branch $(IPXE_VERSION) https://github.com/ipxe/ipxe /ipxe; \
		cd /ipxe/src; \
		echo "#define DOWNLOAD_PROTO_HTTPS" > config/local/general.h; \
		make -s -j$$(nproc) bin-$(ARCH)-efi/ipxe.efi \
			TRUST=/tls/ca.crt CERT=/tls/ipxe-client.crt PRIVKEY=/tls/ipxe-client.key; \
		cp bin-$(ARCH)-efi/ipxe.efi /out/ipxe.efi'
	@echo "✓ $(OUT_DIR)/ipxe.efi"

clean: ## Remove built binaries
	rm -rf $(CURDIR)/../_out/ipxe
