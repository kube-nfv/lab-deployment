# Talos Linux ISO Builder

TALOS_VERSION := v1.11.3
IMAGER_IMAGE := ghcr.io/siderolabs/imager:$(TALOS_VERSION)
ISO_CONFIG := $(CURDIR)/iso-profile.yaml
VMLINUZ_CONFIG := $(CURDIR)/vmlinuz-profile.yaml
INITRAMFS_CONFIG := $(CURDIR)/initramfs-profile.yaml
OUT_DIR := $(CURDIR)/../_out/talos

.PHONY: help iso clean vmlinuz initramfs

.DEFAULT_GOAL := help

help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Build

iso: ## Build Talos ISO image
	@echo "Building Talos ISO..."
	test -f $(ISO_CONFIG) || (echo "Error: $(ISO_CONFIG) not found" && exit 1)
	mkdir -p $(OUT_DIR)
	cat $(ISO_CONFIG) | docker run -i --rm \
		-v $(OUT_DIR):/out \
		$(IMAGER_IMAGE) -
	@echo "ISO created"


vmlinuz: ## Build Talos vmlinuz
	@echo "Building Talos vmlinuz..."
	test -f $(VMLINUZ_CONFIG) || (echo "Error: $(VMLINUZ_CONFIG) not found" && exit 1)
	mkdir -p $(OUT_DIR)
	cat $(VMLINUZ_CONFIG) | docker run -i --rm \
		-v $(OUT_DIR):/out \
		$(IMAGER_IMAGE) -
	@echo "Vmlinuz created"

initramfs: ## Build Talos initramfs
	@echo "Buiding Talos initramfs..."
	test -f $(INITRAMFS_CONFIG) || (echo "Error: $(INITRAMFS_CONFIG) not found" && exit 1)
	mkdir -p $(OUT_DIR)
	cat $(INITRAMFS_CONFIG) | docker run -i --rm \
		-v $(OUT_DIR):/out \
		$(IMAGER_IMAGE) -
	@echo "Initramfs created"

##@ Cleanup

clean: ## Remove generated ISO
	@echo "Removing generated artifacts..."
	rm -rf $(OUT_DIR)
	@echo "✓ Cleanup complete"
