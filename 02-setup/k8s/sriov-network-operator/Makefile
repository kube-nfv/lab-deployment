apply-ns:
	kubectl apply -f namespace.yaml

helm-upgrade: apply-ns
	helm upgrade -i -n sriov-network-operator sriov-network-operator ../../../k8s/helm/sriov-network-operator/charts/sriov-network-operator-chart -f values.yaml
