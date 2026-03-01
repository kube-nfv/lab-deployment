update:
	rm -rf charts
	helm repo add bitnami https://charts.bitnami.com/bitnami
	helm repo update bitnami
	helm pull bitnami/minio --untar --untardir charts
