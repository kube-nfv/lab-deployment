TALOS_VERSION      := v1.14.2
KUBERNETES_VERSION := 1.36.2
CLUSTER_NAME       := setup02-cluster
CLUSTER_ENDPOINT   ?= https://100.104.125.108:6443

SECRETS_FILE   := $(CURDIR)/secrets.yaml
PATCHES_DIR    := $(CURDIR)/patches
SCHEMATICS_DIR := $(CURDIR)/schematics
OUT_DIR        := $(CURDIR)/../_out/talos
CONFIGS_DIR    := $(OUT_DIR)/configs
IMAGES_DIR     := $(OUT_DIR)/images

FACTORY := https://factory.talos.dev

# Registers schematics/<name>.yaml with Image Factory and returns its ID
schematic_id = $(or $(shell curl -sf -X POST --data-binary @$(SCHEMATICS_DIR)/$(1).yaml $(FACTORY)/schematics | jq -r .id),$(error failed to get schematic ID for $(1)))

CLOUD_SCHEMATIC = $(call schematic_id,cloud)
EDGE_SCHEMATIC  = $(call schematic_id,edge)
CLOUD_INSTALLER_PATCH = '{"apiVersion":"v1alpha1","kind":"UnattendedInstallConfig","installer":{"image":"factory.talos.dev/gcp-installer/$(CLOUD_SCHEMATIC):$(TALOS_VERSION)"}}'
EDGE_INSTALLER_PATCH  = '{"apiVersion":"v1alpha1","kind":"UnattendedInstallConfig","installer":{"image":"factory.talos.dev/metal-installer/$(EDGE_SCHEMATIC):$(TALOS_VERSION)"}}'

.PHONY: help schematics image-cloud image-edge gen-config-master1 gen-config-worker1 gen-config-edge-worker-1 gen-config gen-talosconfig clean

.DEFAULT_GOAL := help

help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Images

schematics: ## Register schematics with Image Factory and print their IDs
	@echo "cloud: $(CLOUD_SCHEMATIC)"
	@echo "edge:  $(EDGE_SCHEMATIC)"

image-cloud: ## Download the GCP disk image for the cloud schematic
	mkdir -p $(IMAGES_DIR)
	curl -fL -o $(IMAGES_DIR)/talos-gcp-$(TALOS_VERSION).raw.tar.gz \
		$(FACTORY)/image/$(CLOUD_SCHEMATIC)/$(TALOS_VERSION)/gcp-amd64.raw.tar.gz

image-edge: ## Download the metal ISO for the edge schematic
	mkdir -p $(IMAGES_DIR)
	curl -fL -o $(IMAGES_DIR)/talos-metal-$(TALOS_VERSION).iso \
		$(FACTORY)/image/$(EDGE_SCHEMATIC)/$(TALOS_VERSION)/metal-amd64.iso

##@ Cloud Configuration

gen-config-master1: ## Generate cloud master-1 controlplane config
	@echo "Generating cloud-master-1 config (endpoint: $(CLUSTER_ENDPOINT))..."
	mkdir -p $(CONFIGS_DIR)
	talosctl gen config $(CLUSTER_NAME) $(CLUSTER_ENDPOINT) \
		--with-secrets $(SECRETS_FILE) \
		--kubernetes-version $(KUBERNETES_VERSION) \
		--talos-version $(TALOS_VERSION) \
		--config-patch @$(PATCHES_DIR)/base.yaml \
		--config-patch @$(PATCHES_DIR)/controlplane.yaml \
		--config-patch $(CLOUD_INSTALLER_PATCH) \
		--config-patch @$(PATCHES_DIR)/cloud-nodes.yaml \
		--config-patch @$(PATCHES_DIR)/tailscale.yaml \
		--output $(CONFIGS_DIR)/cloud-master-1.yaml \
		--output-types controlplane \
		--force
	@echo "✓ Cloud master-1 config: $(CONFIGS_DIR)/cloud-master-1.yaml"

gen-config-worker1: ## Generate cloud worker-1 config
	@echo "Generating cloud-worker-1 config (endpoint: $(CLUSTER_ENDPOINT))..."
	mkdir -p $(CONFIGS_DIR)
	talosctl gen config $(CLUSTER_NAME) $(CLUSTER_ENDPOINT) \
		--with-secrets $(SECRETS_FILE) \
		--kubernetes-version $(KUBERNETES_VERSION) \
		--talos-version $(TALOS_VERSION) \
		--config-patch @$(PATCHES_DIR)/base.yaml \
		--config-patch @$(PATCHES_DIR)/registry-auth.yaml \
		--config-patch $(CLOUD_INSTALLER_PATCH) \
		--config-patch @$(PATCHES_DIR)/cloud-nodes.yaml \
		--config-patch @$(PATCHES_DIR)/tailscale.yaml \
		--output $(CONFIGS_DIR)/cloud-worker-1.yaml \
		--output-types worker \
		--force
	@echo "✓ Cloud worker-1 config: $(CONFIGS_DIR)/cloud-worker-1.yaml"

##@ Edge Configuration

gen-config-edge-worker-1: ## Generate edge-worker-1 config
	@echo "Generating edge-worker-1 config (endpoint: $(CLUSTER_ENDPOINT))..."
	mkdir -p $(CONFIGS_DIR)
	talosctl gen config $(CLUSTER_NAME) $(CLUSTER_ENDPOINT) \
		--with-secrets $(SECRETS_FILE) \
		--kubernetes-version $(KUBERNETES_VERSION) \
		--talos-version $(TALOS_VERSION) \
		--config-patch @$(PATCHES_DIR)/base.yaml \
		--config-patch $(EDGE_INSTALLER_PATCH) \
		--config-patch @$(PATCHES_DIR)/edge-nodes.yaml \
		--config-patch @$(PATCHES_DIR)/tailscale.yaml \
		--config-patch @$(PATCHES_DIR)/edge-worker-1-node.yaml \
		--output $(CONFIGS_DIR)/edge-worker-1.yaml \
		--output-types worker \
		--force
	@echo "✓ Edge-worker-1 config: $(CONFIGS_DIR)/edge-worker-1.yaml"

gen-config-x11spl-f-worker-1: ## Generate x11spl-f-worker-1 config
	@echo "Generating x11spl-f-worker-1 config (endpoint: $(CLUSTER_ENDPOINT))..."
	mkdir -p $(CONFIGS_DIR)
	talosctl gen config $(CLUSTER_NAME) $(CLUSTER_ENDPOINT) \
		--with-secrets $(SECRETS_FILE) \
		--kubernetes-version $(KUBERNETES_VERSION) \
		--talos-version $(TALOS_VERSION) \
		--config-patch @$(PATCHES_DIR)/base.yaml \
		--config-patch $(EDGE_INSTALLER_PATCH) \
		--config-patch @$(PATCHES_DIR)/edge-nodes.yaml \
		--config-patch @$(PATCHES_DIR)/tailscale.yaml \
		--config-patch @$(PATCHES_DIR)/x11spl-f-worker-1-node.yaml \
		--output $(CONFIGS_DIR)/x11spl-f-worker-1.yaml \
		--output-types worker \
		--force
	@echo "✓ x11spl-f-worker-1 config: $(CONFIGS_DIR)/x11spl-f-worker-1.yaml"

##@ All

gen-talosconfig: ## Generate talosconfig
	@echo "Generating talosconfig..."
	mkdir -p $(CONFIGS_DIR)
	talosctl gen config $(CLUSTER_NAME) $(CLUSTER_ENDPOINT) \
		--with-secrets $(SECRETS_FILE) \
		--output $(CONFIGS_DIR)/talosconfig \
		--output-types talosconfig \
		--force
	@echo "✓ Talosconfig: $(CONFIGS_DIR)/talosconfig"

gen-config: gen-config-master1 gen-config-worker1 gen-config-edge-worker-1 gen-config-x11spl-f-worker-1 gen-talosconfig ## Generate all machine configs
	@echo "✓ All configs generated in $(CONFIGS_DIR)/"

##@ Cleanup

clean: ## Remove generated configs
	@echo "Removing generated artifacts..."
	rm -rf $(OUT_DIR)
	@echo "✓ Cleanup complete"
