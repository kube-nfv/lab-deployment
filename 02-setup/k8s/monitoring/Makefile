apply-ns:
	kubectl apply -f namespace.yaml

helm-upgrade: apply-ns
	helm upgrade -i -n monitoring monitoring kube-prometheus-stack \
		--repo https://prometheus-community.github.io/helm-charts \
		-f ../../../k8s/helm/monitoring/values.yaml -f values.yaml

# Copy Grafana admin secret into the osm namespace so mon can read it via secretKeyRef.
# TODO: replace with ExternalSecrets operator once ESO is available in the cluster.
sync-grafana-secret:
	kubectl get secret -n monitoring grafana -o json | \
		jq 'del(.metadata.namespace,.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.annotations,.metadata.ownerReferences) | .metadata.name = "grafana-monitoring" | .metadata.namespace = "osm"' | \
		kubectl apply -f -
