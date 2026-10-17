# 02-Setup iPXE test path on Docker (macOS or Linux): dnsmasq + network-booting arm64 VM
# Network: 10.0.20.0/24 - gateway .1, dnsmasq .2, iPXE script server .3 (attached by its owner), VM .4

NETWORK      := setup02-pxe
SUBNET       := 10.0.20.0/24
GATEWAY_IP   := 10.0.20.1
DOCKER_RANGE := 10.0.20.0/28

DNSMASQ_CONTAINER := dnsmasq-setup02-pxe
DNSMASQ_IMAGE     := setup02-pxe-dnsmasq
DNSMASQ_IP        := 10.0.20.2
TFTP_ROOT         := $(CURDIR)/../../_out/ipxe

VM_CONTAINER := vm-setup02-pxe-1
VM_IMAGE     := setup02-pxe-vm
VM_IP        := 10.0.20.4
VM_MAC       := 52:54:00:00:02:10
VM_SERIAL    := SETUP02-PXE-VM-1
VM_UUID      := 5e7c0b2a-0d6f-4c1e-9a52-02a0e0000001
VM_CPUS      := 2
VM_MEM       := 4096
VM_DISK      := 20G

TEST_CONTAINER  := ipxe-test-setup02-pxe
TEST_IP         := 10.0.20.3
TEST_OUT        := $(CURDIR)/../../_out/pxe-test
TLS_DIR         := $(CURDIR)/../../tls
TALOS_VERSION   := v1.14.4
TALOS_SCHEMATIC := 376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba
TALOS_ARCH      := arm64

.PHONY: help setup network dnsmasq vm console verify clean clean-vm clean-dnsmasq clean-network \
	test-assets test-server clean-test-server

.DEFAULT_GOAL := help

help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Setup

setup: network dnsmasq ## Create network and dnsmasq (start the VM separately)
	@echo "✓ Setup complete"

network: ## Create the Docker network
	docker network inspect $(NETWORK) >/dev/null 2>&1 || \
		docker network create --subnet $(SUBNET) --gateway $(GATEWAY_IP) --ip-range $(DOCKER_RANGE) $(NETWORK)
	@echo "✓ Network $(NETWORK): $(SUBNET)"

dnsmasq: network ## Create dnsmasq: DHCP, DNS, TFTP for iPXE ($(DNSMASQ_IP))
	test -f $(TFTP_ROOT)/arm64/ipxe.efi || (echo "Error: build it first: make -C ../../ipxe build" && exit 1)
	docker build -q -t $(DNSMASQ_IMAGE) -f dnsmasq.Dockerfile .
	docker rm -f $(DNSMASQ_CONTAINER) 2>/dev/null || true
	docker run -d --name $(DNSMASQ_CONTAINER) --network $(NETWORK) --ip $(DNSMASQ_IP) \
		--cap-add NET_ADMIN --restart unless-stopped \
		-v $(CURDIR)/dnsmasq.conf:/etc/dnsmasq.conf:ro \
		-v $(TFTP_ROOT):/var/lib/tftpboot:ro \
		$(DNSMASQ_IMAGE)
	@echo "✓ DNSMasq: $(DNSMASQ_IP)"

vm: network ## Start the network-booting arm64 VM ($(VM_SERIAL))
	docker build -q -t $(VM_IMAGE) -f vm.Dockerfile .
	docker rm -f $(VM_CONTAINER) 2>/dev/null || true
	docker run -dit --name $(VM_CONTAINER) --network $(NETWORK) --ip $(VM_IP) \
		--cap-add NET_ADMIN --device /dev/net/tun \
		-e VM_MAC=$(VM_MAC) -e VM_SERIAL=$(VM_SERIAL) -e VM_UUID=$(VM_UUID) \
		-e VM_CPUS=$(VM_CPUS) -e VM_MEM=$(VM_MEM) -e VM_DISK=$(VM_DISK) \
		-v $(VM_CONTAINER):/vm \
		$(VM_IMAGE)
	@echo "✓ VM: $(VM_CONTAINER), serial console: make console"

console: ## Attach to the VM serial console (detach: Ctrl-P Ctrl-Q)
	docker attach $(VM_CONTAINER)

##@ E2E test server (stand-in for the real iPXE script server)

test-assets: ## Download Talos $(TALOS_VERSION) $(TALOS_ARCH) PXE assets and boot.ipxe into _out/pxe-test
	mkdir -p $(TEST_OUT)/talos/$(TALOS_VERSION)
	for f in kernel-$(TALOS_ARCH) initramfs-$(TALOS_ARCH).xz; do \
		test -f $(TEST_OUT)/talos/$(TALOS_VERSION)/$$f || curl -fL -o $(TEST_OUT)/talos/$(TALOS_VERSION)/$$f \
			https://factory.talos.dev/image/$(TALOS_SCHEMATIC)/$(TALOS_VERSION)/$$f; done
	{ echo '#!ipxe'; echo 'echo setup02 test server: serial=$${serial} uuid=$${uuid} mac=$${net0/mac}'; \
		curl -sf https://pxe.factory.talos.dev/pxe/$(TALOS_SCHEMATIC)/$(TALOS_VERSION)/metal-$(TALOS_ARCH) \
		| sed -e '1d' -e 's#https://pxe.factory.talos.dev/image/$(TALOS_SCHEMATIC)/#talos/#'; \
	} > $(TEST_OUT)/boot.ipxe
	@echo "✓ $(TEST_OUT)"; cat $(TEST_OUT)/boot.ipxe

test-server: network ## Run the nginx mTLS test server at $(TEST_IP) (needs test-assets)
	test -f $(TEST_OUT)/boot.ipxe || (echo "Error: run make test-assets first" && exit 1)
	docker rm -f $(TEST_CONTAINER) 2>/dev/null || true
	docker create --name $(TEST_CONTAINER) --network $(NETWORK) --ip $(TEST_IP) \
		-v $(CURDIR)/test-server.conf:/etc/nginx/conf.d/default.conf:ro -v $(TEST_OUT):/srv:ro \
		nginx:1.27-alpine >/dev/null
	tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	cp $(TLS_DIR)/ca.crt "$$tmp/"; \
	cat $(TLS_DIR)/ipxe-server.crt $(TLS_DIR)/ca.crt > "$$tmp/ipxe-server-chain.crt"; \
	(umask 077; sops -d --input-type binary --output-type binary $(TLS_DIR)/ipxe-server.key > "$$tmp/ipxe-server.key"); \
	docker cp "$$tmp/." $(TEST_CONTAINER):/etc/nginx/tls
	docker start $(TEST_CONTAINER) >/dev/null
	@echo "✓ Test server: https://ipxe.setup02.local ($(TEST_IP)), log: docker logs -f $(TEST_CONTAINER)"

##@ Verification

verify: ## Show containers and recent dnsmasq DHCP/TFTP log
	docker ps -f network=$(NETWORK)
	docker logs --tail 30 $(DNSMASQ_CONTAINER)

##@ Cleanup

clean: clean-vm clean-test-server clean-dnsmasq clean-network ## Remove everything, including the VM disk
	@echo "✓ Cleanup complete"

clean-test-server: ## Remove the nginx test server
	docker rm -f $(TEST_CONTAINER) 2>/dev/null || true

clean-vm: ## Remove the VM and its disk volume
	docker rm -f $(VM_CONTAINER) 2>/dev/null || true
	docker volume rm $(VM_CONTAINER) 2>/dev/null || true

clean-dnsmasq: ## Remove the dnsmasq container
	docker rm -f $(DNSMASQ_CONTAINER) 2>/dev/null || true

clean-network: ## Remove the Docker network
	docker network rm $(NETWORK) 2>/dev/null || true
