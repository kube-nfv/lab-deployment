# CRS504-4XQ dataplane switch - 02-setup edge site
#
# base.rsc     permanent management config
# scenarios/   swappable dataplane layouts
#
# Needs CRS504_PASSWORD in the environment and network reach to the switch,
# which sits on the lab management subnet.

-include .local.mk

SWITCH      ?= 192.168.88.2
SWITCH_USER ?= admin
SCENARIO    ?= basic-l2

SSH_OPTS := -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o PreferredAuthentications=password,keyboard-interactive \
            -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1
SSH := sshpass -p "$$CRS504_PASSWORD" ssh $(SSH_OPTS) $(SWITCH_USER)@$(SWITCH)
SCP := sshpass -p "$$CRS504_PASSWORD" scp -O $(SSH_OPTS)

.PHONY: help apply base show ssh
.DEFAULT_GOAL := help

help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo
	@echo "Scenarios:"
	@ls scenarios/*.rsc 2>/dev/null | sed 's|scenarios/|  |;s|\.rsc$$||'
	@echo

apply: ## Apply a dataplane scenario: make apply SCENARIO=basic-l2
	@test -f scenarios/$(SCENARIO).rsc || { echo "no such scenario: $(SCENARIO)"; exit 1; }
	$(SCP) scenarios/$(SCENARIO).rsc $(SWITCH_USER)@$(SWITCH):scenario.rsc
	$(SSH) '/import file-name=scenario.rsc'
	$(SSH) '/file remove [find where name="scenario.rsc"]'

base: ## Apply the permanent management config (drops the session mid-run)
	$(SCP) base.rsc $(SWITCH_USER)@$(SWITCH):base.rsc
	-$(SSH) '/import file-name=base.rsc'

show: ## Show the current dataplane VLAN layout
	@$(SSH) '/interface bridge vlan print; /interface bridge port print brief where bridge=bridge'

ssh: ## Open an interactive RouterOS shell
	@$(SSH)
