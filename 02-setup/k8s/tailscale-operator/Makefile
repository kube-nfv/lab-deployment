helm-upgrade:
	helm upgrade -i --create-namespace -n tailscale-operator tailscale-operator ../../../k8s/helm/tailscale-operator/ -f ../../../k8s/helm/tailscale-operator/values.yaml -f values.yaml -f secrets.yaml
	$(MAKE) apply-bmc-proxy
	$(MAKE) apply-netdev-proxy

apply-bmc-proxy:
	kubectl apply -f bmc-proxy.yaml

apply-netdev-proxy:
	kubectl apply -f network-devices-proxy.yaml
