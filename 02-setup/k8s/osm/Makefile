KUBECONFIG_FILE := ../../_out/talos/configs/kubeconfig

create-secrets:
	kubectl -n osm create secret generic mgmtcluster-secret \
		--from-file=kubeconfig=$(KUBECONFIG_FILE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n osm create secret generic auxcluster-secret \
		--from-file=kubeconfig=$(KUBECONFIG_FILE) --dry-run=client -o yaml | kubectl apply -f -

helm-upgrade:
	helm upgrade -i --create-namespace -n osm osm ../../../k8s/helm/osm/ -f ../../../k8s/helm/osm/values.yaml -f values.yaml
