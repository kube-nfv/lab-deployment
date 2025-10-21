# 01-Setup Network Infrastructure
# Network: 10.0.10.0/24

BRIDGE_NAME := 01-setup-net
BRIDGE_IP := 10.0.10.1/24
NETWORK_CIDR := 10.0.10.0/24

DNSMASQ_CONTAINER := dnsmasq-01-setup
DNSMASQ_IP := 10.0.10.2
DNSMASQ_CONF := $(CURDIR)/dnsmasq.conf

MATCHBOX_CONTAINER := matchbox-01-setup
MATCHBOX_IP := 10.0.10.3
MATCHBOX_DATA := $(CURDIR)/matchbox-data
MATCHBOX_OUT := $(CURDIR)/../_out/matchbox-data
MATCHBOX_CONFIG := $(CURDIR)/matchbox
TALOS_OUT := $(CURDIR)/../_out/talos
TLS_DIR := $(CURDIR)/../tls

GATEWAY_IP := 10.0.10.1

.PHONY: help setup clean bridge dnsmasq matchbox matchbox-prepare verify install-service uninstall-service enable-service disable-service reconnect

.DEFAULT_GOAL := help

help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Setup

setup: bridge dnsmasq matchbox ## Create complete setup
	@echo "✓ Setup complete"

matchbox-prepare: ## Prepare Matchbox data in _out with configs and assets
	@echo "Preparing Matchbox data directory..."
	mkdir -p $(MATCHBOX_OUT)/var/lib/matchbox/assets
	mkdir -p $(MATCHBOX_OUT)/var/lib/matchbox/profiles
	mkdir -p $(MATCHBOX_OUT)/var/lib/matchbox/groups
	mkdir -p $(MATCHBOX_OUT)/var/lib/matchbox/ignition
	mkdir -p $(MATCHBOX_OUT)/etc/matchbox
	@echo "Copying TLS certificates..."
	test -f $(TLS_DIR)/matchbox-server.crt || (echo "Error: TLS certificates not found in $(TLS_DIR)" && exit 1)
	cp $(TLS_DIR)/matchbox-server.crt $(MATCHBOX_OUT)/etc/matchbox/server.crt
	cp $(TLS_DIR)/matchbox-server.key $(MATCHBOX_OUT)/etc/matchbox/server.key
	cp $(TLS_DIR)/ca.crt $(MATCHBOX_OUT)/etc/matchbox/ca.crt
	@echo "Copying Talos assets..."
	test -f $(TALOS_OUT)/kernel-amd64 || (echo "Error: Talos kernel not found. Run 'make vmlinuz' in talos/" && exit 1)
	test -f $(TALOS_OUT)/initramfs-metal-amd64.xz || (echo "Error: Talos initramfs not found. Run 'make initramfs' in talos/" && exit 1)
	cp $(TALOS_OUT)/kernel-amd64 $(MATCHBOX_OUT)/var/lib/matchbox/assets/talos-kernel-amd64
	cp $(TALOS_OUT)/initramfs-metal-amd64.xz $(MATCHBOX_OUT)/var/lib/matchbox/assets/talos-initramfs-amd64.xz
	@echo "Copying Matchbox configs..."
	cp $(MATCHBOX_CONFIG)/profiles/*.json $(MATCHBOX_OUT)/var/lib/matchbox/profiles/
	cp $(MATCHBOX_CONFIG)/groups/*.json $(MATCHBOX_OUT)/var/lib/matchbox/groups/
	@echo "✓ Matchbox data prepared in $(MATCHBOX_OUT)"

bridge: ## Create OVS bridge (10.0.10.1/24)
	@echo "Creating OVS bridge: $(BRIDGE_NAME)"
	sudo ovs-vsctl --may-exist add-br $(BRIDGE_NAME)
	sudo ip link set $(BRIDGE_NAME) up
	sudo ip addr add $(BRIDGE_IP) dev $(BRIDGE_NAME) 2>/dev/null || true
	sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
	sudo iptables -t nat -C POSTROUTING -s $(NETWORK_CIDR) ! -d $(NETWORK_CIDR) -j MASQUERADE 2>/dev/null || \
		sudo iptables -t nat -A POSTROUTING -s $(NETWORK_CIDR) ! -d $(NETWORK_CIDR) -j MASQUERADE
	@echo "✓ Bridge created: $(BRIDGE_NAME) at $(BRIDGE_IP)"

dnsmasq: ## Create DNSMasq (10.0.10.2/24)
	@echo "Creating DNSMasq container"
	test -f $(DNSMASQ_CONF) || (echo "Error: $(DNSMASQ_CONF) not found" && exit 1)
	sudo ovs-docker del-port $(BRIDGE_NAME) eth0 $(DNSMASQ_CONTAINER) 2>/dev/null || true
	docker rm -f $(DNSMASQ_CONTAINER) 2>/dev/null || true
	docker run -d \
		--name $(DNSMASQ_CONTAINER) \
		--network none \
		--cap-add NET_ADMIN \
		--restart unless-stopped \
		--entrypoint /bin/sh \
		-v $(DNSMASQ_CONF):/etc/dnsmasq.conf:ro \
		quay.io/poseidon/dnsmasq:v0.5.0-44-g91f75d9-amd64 \
		-c "sleep 5 && exec /usr/sbin/dnsmasq -k"
	@echo "Waiting for container network namespace..."
	@for i in $$(seq 1 10); do \
		docker exec $(DNSMASQ_CONTAINER) ip link show lo >/dev/null 2>&1 && break; \
		sleep 1; \
	done
	sudo ovs-docker add-port $(BRIDGE_NAME) eth0 $(DNSMASQ_CONTAINER) \
		--ipaddress=$(DNSMASQ_IP)/24 --gateway=$(GATEWAY_IP)
	@echo "✓ DNSMasq created: $(DNSMASQ_IP)/24 (includes iPXE bootloaders)"

matchbox: matchbox-prepare ## Create Matchbox PXE server (10.0.10.3/24)
	@echo "Creating Matchbox PXE server"
	sudo ovs-docker del-port $(BRIDGE_NAME) eth0 $(MATCHBOX_CONTAINER) 2>/dev/null || true
	docker rm -f $(MATCHBOX_CONTAINER) 2>/dev/null || true
	docker run -d \
		--name $(MATCHBOX_CONTAINER) \
		--network none \
		--cap-add NET_ADMIN \
		--restart unless-stopped \
		-v $(MATCHBOX_OUT)/var/lib/matchbox:/var/lib/matchbox:Z \
		-v $(MATCHBOX_OUT)/etc/matchbox:/etc/matchbox:Z \
		quay.io/poseidon/matchbox:latest \
		-address=0.0.0.0:8080 \
		-rpc-address=0.0.0.0:8081 \
		-log-level=debug
	@echo "Waiting for container network namespace..."
	@for i in $$(seq 1 10); do \
		docker exec $(MATCHBOX_CONTAINER) ip link show lo >/dev/null 2>&1 && break; \
		sleep 1; \
	done
	sudo ovs-docker add-port $(BRIDGE_NAME) eth0 $(MATCHBOX_CONTAINER) \
		--ipaddress=$(MATCHBOX_IP)/24 --gateway=$(GATEWAY_IP)
	@echo "✓ Matchbox created: $(MATCHBOX_IP)/24 (matchbox.setup01.local)"

##@ Persistence

install-service: ## Install systemd service for persistent networking
	@echo "Installing systemd service..."
	sudo cp $(CURDIR)/01-setup-net.service /etc/systemd/system/
	sudo systemctl daemon-reload
	@echo "✓ Service installed. Run 'make enable-service' to enable on boot"

uninstall-service: disable-service ## Uninstall systemd service
	@echo "Uninstalling systemd service..."
	sudo rm -f /etc/systemd/system/01-setup-net.service
	sudo systemctl daemon-reload
	@echo "✓ Service uninstalled"

enable-service: ## Enable service to run on boot
	@echo "Enabling service..."
	sudo systemctl enable 01-setup-net.service
	@echo "✓ Service enabled. Network will be configured automatically on boot"

disable-service: ## Disable service from running on boot
	@echo "Disabling service..."
	sudo systemctl disable 01-setup-net.service 2>/dev/null || true
	sudo systemctl stop 01-setup-net.service 2>/dev/null || true
	@echo "✓ Service disabled"

reconnect: ## Reconnect containers to OVS bridge (manual fix after reboot)
	@echo "Reconnecting containers to OVS bridge..."
	@$(MAKE) clean-matchbox clean-dnsmasq
	@$(MAKE) bridge dnsmasq matchbox
	@echo "✓ Containers reconnected"

##@ Verification

verify: ## Verify setup
	@echo "=== OVS Bridge ==="
	sudo ovs-vsctl show | grep -A 5 "$(BRIDGE_NAME)" || echo "Bridge not found"
	@echo ""
	@echo "=== Containers ==="
	docker ps -f name=01-setup
	@echo ""
	@echo "=== DNS Tests ==="
	nslookup matchbox.setup01.local $(DNSMASQ_IP) 2>/dev/null || echo "DNS failed"
	@echo ""
	@echo "=== Connectivity ==="
	ping -c 2 $(DNSMASQ_IP) || echo "DNSMasq unreachable"
	ping -c 2 $(MATCHBOX_IP) || echo "Matchbox unreachable"

##@ Cleanup

clean: clean-matchbox clean-dnsmasq clean-bridge ## Remove all components
	@echo "✓ Cleanup complete"

clean-matchbox: ## Remove Matchbox container
	@echo "Removing Matchbox..."
	sudo ovs-docker del-port $(BRIDGE_NAME) eth0 $(MATCHBOX_CONTAINER) 2>/dev/null || true
	docker rm -f $(MATCHBOX_CONTAINER) 2>/dev/null || true

clean-dnsmasq: ## Remove DNSMasq container
	@echo "Removing DNSMasq..."
	sudo ovs-docker del-port $(BRIDGE_NAME) eth0 $(DNSMASQ_CONTAINER) 2>/dev/null || true
	docker rm -f $(DNSMASQ_CONTAINER) 2>/dev/null || true

clean-bridge: ## Remove OVS bridge
	@echo "Removing OVS bridge..."
	sudo ovs-vsctl list-ports $(BRIDGE_NAME) 2>/dev/null | xargs -I {} sudo ovs-vsctl del-port $(BRIDGE_NAME) {} 2>/dev/null || true
	sudo ovs-vsctl del-br $(BRIDGE_NAME) 2>/dev/null || true
	sudo iptables -t nat -D POSTROUTING -s $(NETWORK_CIDR) ! -d $(NETWORK_CIDR) -j MASQUERADE 2>/dev/null || true
