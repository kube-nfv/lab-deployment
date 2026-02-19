# 02-Setup Edge Network Infrastructure
# Network: 10.0.20.0/24

BRIDGE_NAME  := setup02-edge
BRIDGE_IP    := 10.0.20.1/24
NETWORK_CIDR := 10.0.20.0/24
GATEWAY_IP   := 10.0.20.1

DNSMASQ_CONTAINER := dnsmasq-02-setup
DNSMASQ_IP        := 10.0.20.2
DNSMASQ_CONF      := $(CURDIR)/dnsmasq.conf

.PHONY: help setup clean bridge dnsmasq verify install-service uninstall-service enable-service disable-service reconnect

.DEFAULT_GOAL := help

help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Setup

setup: bridge dnsmasq ## Create complete setup
	@echo "✓ Setup complete"

bridge: ## Create OVS bridge (10.0.20.1/24) with NAT
	@echo "Creating OVS bridge: $(BRIDGE_NAME)"
	sudo ovs-vsctl --may-exist add-br $(BRIDGE_NAME)
	sudo ip link set $(BRIDGE_NAME) up
	sudo ip addr add $(BRIDGE_IP) dev $(BRIDGE_NAME) 2>/dev/null || true
	sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
	sudo iptables -t nat -C POSTROUTING -s $(NETWORK_CIDR) ! -d $(NETWORK_CIDR) -j MASQUERADE 2>/dev/null || \
		sudo iptables -t nat -A POSTROUTING -s $(NETWORK_CIDR) ! -d $(NETWORK_CIDR) -j MASQUERADE
	@echo "✓ Bridge created: $(BRIDGE_NAME) at $(BRIDGE_IP)"

dnsmasq: ## Create DNSMasq container (10.0.20.2/24)
	@echo "Creating DNSMasq container..."
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
	@echo "✓ DNSMasq created: $(DNSMASQ_IP)/24"

##@ Persistence

install-service: ## Install systemd service for persistent networking
	sudo cp $(CURDIR)/setup02-edge.service /etc/systemd/system/
	sudo systemctl daemon-reload
	@echo "✓ Service installed. Run 'make enable-service' to enable on boot"

uninstall-service: disable-service ## Uninstall systemd service
	sudo rm -f /etc/systemd/system/setup02-edge.service
	sudo systemctl daemon-reload
	@echo "✓ Service uninstalled"

enable-service: ## Enable service to run on boot
	sudo systemctl enable setup02-edge.service
	@echo "✓ Service enabled"

disable-service: ## Disable service from running on boot
	sudo systemctl disable setup02-edge.service 2>/dev/null || true
	sudo systemctl stop setup02-edge.service 2>/dev/null || true
	@echo "✓ Service disabled"

reconnect: ## Reconnect containers to OVS bridge (use after reboot)
	@$(MAKE) clean-dnsmasq
	@$(MAKE) bridge dnsmasq
	@echo "✓ Containers reconnected"

##@ Verification

verify: ## Verify setup
	@echo "=== OVS Bridge ==="
	sudo ovs-vsctl show | grep -A 5 "$(BRIDGE_NAME)" || echo "Bridge not found"
	@echo ""
	@echo "=== Containers ==="
	docker ps -f name=02-setup
	@echo ""
	@echo "=== Connectivity ==="
	ping -c 2 $(DNSMASQ_IP) || echo "DNSMasq unreachable"

##@ Cleanup

clean: clean-dnsmasq clean-bridge ## Remove all components
	@echo "✓ Cleanup complete"

clean-dnsmasq: ## Remove DNSMasq container
	@echo "Removing DNSMasq..."
	sudo ovs-docker del-port $(BRIDGE_NAME) eth0 $(DNSMASQ_CONTAINER) 2>/dev/null || true
	docker rm -f $(DNSMASQ_CONTAINER) 2>/dev/null || true

clean-bridge: ## Remove OVS bridge
	@echo "Removing OVS bridge..."
	sudo ovs-vsctl list-ports $(BRIDGE_NAME) 2>/dev/null | xargs -I {} sudo ovs-vsctl del-port $(BRIDGE_NAME) {} 2>/dev/null || true
	sudo ovs-vsctl del-br $(BRIDGE_NAME) 2>/dev/null || true
	sudo iptables -t nat -D POSTROUTING -s $(NETWORK_CIDR) ! -d $(NETWORK_CIDR) -j MASQUERADE 2>/dev/null || true
