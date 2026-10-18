VERSION := 26.8.1
BASE    := https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/$(VERSION)/kubernetes
FILES   := kustomization.yml kubernetes.yml \
	keycloaks.k8s.keycloak.org-v1.yml keycloakrealmimports.k8s.keycloak.org-v1.yml \
	keycloakoidcclients.k8s.keycloak.org-v1.yml keycloaksamlclients.k8s.keycloak.org-v1.yml

update:
	rm -rf templates
	mkdir templates
	for f in $(FILES); do wget -q $(BASE)/$$f -O templates/$$f; done
