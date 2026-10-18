# Keycloak operator, then the secrets, then the Keycloak instance and the nfv realm.
# Needs the lab-ca ClusterIssuer (k8s/cert-manager: make lab-ca).
apply:
	kubectl apply -k .
	kubectl wait --for=condition=Established --timeout=60s \
		crd/keycloaks.k8s.keycloak.org crd/keycloakrealmimports.k8s.keycloak.org
	sops -d secrets.yaml | kubectl apply -f -
	kubectl apply -k instance
