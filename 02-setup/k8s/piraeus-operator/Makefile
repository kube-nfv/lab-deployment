apply-ns:
	kubectl apply -f namespace.yaml

helm-upgrade: apply-ns
	helm upgrade -i --create-namespace -n piraeus-operator piraeus-operator ../../../k8s/helm/piraeus-operator/ -f ../../../k8s/helm/piraeus-operator/values.yaml -f values.yaml
