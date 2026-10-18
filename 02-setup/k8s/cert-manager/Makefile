helm-upgrade:
	helm upgrade -i --create-namespace -n cert-manager cert-manager ../../../k8s/helm/cert-manager/ -f ../../../k8s/helm/cert-manager/values.yaml -f values.yaml

TLS_DIR := ../../tls

# Load the Cluster CA from tls/ into cert-manager and create the lab-ca ClusterIssuer
lab-ca:
	set -e; tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; umask 077; \
	cat $(TLS_DIR)/cluster-ca.crt $(TLS_DIR)/ca.crt > "$$tmp/tls.crt"; \
	sops -d --input-type binary --output-type binary $(TLS_DIR)/cluster-ca.key > "$$tmp/tls.key"; \
	kubectl -n cert-manager create secret generic lab-cluster-ca --type=kubernetes.io/tls \
		--from-file=tls.crt="$$tmp/tls.crt" --from-file=tls.key="$$tmp/tls.key" --from-file=ca.crt=$(TLS_DIR)/ca.crt \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f lab-ca.yaml
