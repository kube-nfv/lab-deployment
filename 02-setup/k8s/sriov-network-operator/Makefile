apply-ns:
	kubectl apply -f namespace.yaml

# metrics-exporter-cert provisions the TLS secret the kube-rbac-proxy sidecar
# needs; the operator only creates it on OpenShift, so we supply it via cert-manager.
apply-metrics-cert: apply-ns
	kubectl apply -f metrics-exporter-cert.yaml

helm-upgrade: apply-ns apply-metrics-cert
	helm upgrade -i -n sriov-network-operator sriov-network-operator ../../../k8s/helm/sriov-network-operator/charts/sriov-network-operator-chart -f values.yaml

servicemonitor:
	kubectl apply -f servicemonitor.yaml
