# Talos Linux ISO Builder

TALOS_VERSION := v1.11.3
KUBERNETES_VERSION := 1.34.1
IMAGER_IMAGE := ghcr.io/siderolabs/imager:$(TALOS_VERSION)
ISO_CONFIG := $(CURDIR)/iso-profile.yaml
VMLINUZ_CONFIG := $(CURDIR)/vmlinuz-profile.yaml
INITRAMFS_CONFIG := $(CURDIR)/initramfs-profile.yaml
INSTALLER_CONFIG := $(CURDIR)/installer-profile.yaml
INSTALLER_IMAGE := ghcr.io/kube-nfv/talos-installer:setup01-v1.0.1
OUT_DIR := $(CURDIR)/../_out/talos
CONFIGS_DIR := $(OUT_DIR)/configs
SECRETS_FILE := $(CURDIR)/secrets.yaml
PATCHES_DIR := $(CURDIR)/patches
CLUSTER_NAME := setup01-cluster
CLUSTER_ENDPOINT := https://master1.setup01.local:6443

.PHONY: help iso clean vmlinuz initramfs installer gen-config-master1 gen-config-worker1 gen-config-worker2 gen-config gen-talosconfig

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

installer: ## Build custom Talos installer image
	@echo "Building custom Talos installer image..."
	test -f $(INSTALLER_CONFIG) || (echo "Error: $(INSTALLER_CONFIG) not found" && exit 1)
	mkdir -p $(OUT_DIR)
	cat $(INSTALLER_CONFIG) | docker run -i --rm \
		-v $(OUT_DIR):/out \
		$(IMAGER_IMAGE) -
	docker load -i $(OUT_DIR)/installer-amd64.tar
	docker tag ghcr.io/siderolabs/installer:$(TALOS_VERSION) $(INSTALLER_IMAGE)
	docker push $(INSTALLER_IMAGE)
	@echo "✓ Installer image: $(INSTALLER_IMAGE)"

##@ Configuration

gen-config-master1: ## Generate master-1 machine config
	@echo "Generating master-1 config..."
	mkdir -p $(CONFIGS_DIR)
	talosctl gen config $(CLUSTER_NAME) $(CLUSTER_ENDPOINT) \
		--with-secrets $(SECRETS_FILE) \
		--kubernetes-version $(KUBERNETES_VERSION) \
		--talos-version $(TALOS_VERSION) \
		--config-patch @$(PATCHES_DIR)/common.yaml \
		--config-patch @$(PATCHES_DIR)/controlplane.yaml \
		--config-patch @$(PATCHES_DIR)/master1-node.yaml \
		--output $(CONFIGS_DIR)/master1.yaml \
		--output-types controlplane \
		--force
	@echo "✓ Master-1 config: $(CONFIGS_DIR)/master1.yaml"

gen-config-worker1: ## Generate worker-1 machine config
	@echo "Generating worker-1 config..."
	mkdir -p $(CONFIGS_DIR)
	talosctl gen config $(CLUSTER_NAME) $(CLUSTER_ENDPOINT) \
		--with-secrets $(SECRETS_FILE) \
		--kubernetes-version $(KUBERNETES_VERSION) \
		--talos-version $(TALOS_VERSION) \
		--config-patch @$(PATCHES_DIR)/common.yaml \
		--config-patch @$(PATCHES_DIR)/worker.yaml \
		--config-patch @$(PATCHES_DIR)/worker1-node.yaml \
		--output $(CONFIGS_DIR)/worker1.yaml \
		--output-types worker \
		--force
	@echo "✓ Worker-1 config: $(CONFIGS_DIR)/worker1.yaml"

gen-config-worker2: ## Generate worker-2 machine config
	@echo "Generating worker-2 config..."
	mkdir -p $(CONFIGS_DIR)
	talosctl gen config $(CLUSTER_NAME) $(CLUSTER_ENDPOINT) \
		--with-secrets $(SECRETS_FILE) \
		--kubernetes-version $(KUBERNETES_VERSION) \
		--talos-version $(TALOS_VERSION) \
		--config-patch @$(PATCHES_DIR)/common.yaml \
		--config-patch @$(PATCHES_DIR)/worker.yaml \
		--config-patch @$(PATCHES_DIR)/worker2-node.yaml \
		--output $(CONFIGS_DIR)/worker2.yaml \
		--output-types worker \
		--force
	@echo "✓ Worker-2 config: $(CONFIGS_DIR)/worker2.yaml"

gen-config: gen-config-master1 gen-config-worker1 gen-config-worker2 gen-talosconfig ## Generate all machine configs
	@echo "✓ All configs generated in $(CONFIGS_DIR)/"

gen-talosconfig: ## Generate talosconfig
	@echo "Generating talosconfig..."
	mkdir -p $(CONFIGS_DIR)
	talosctl gen config $(CLUSTER_NAME) $(CLUSTER_ENDPOINT) \
		--with-secrets $(SECRETS_FILE) \
		--output $(CONFIGS_DIR)/talosconfig \
		--output-types talosconfig \
		--force
	@echo "✓ Talosconfig: $(CONFIGS_DIR)/talosconfig"

##@ Cleanup

clean: ## Remove generated ISO
	@echo "Removing generated artifacts..."
	rm -rf $(OUT_DIR)
	@echo "✓ Cleanup complete"
