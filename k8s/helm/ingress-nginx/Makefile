update:
	rm -rf charts
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
	helm repo update ingress-nginx
	helm pull ingress-nginx/ingress-nginx --untar --untardir charts
	#rm -f charts/ingress-nginx/templates/controller-deployment.yaml.orig
	rm -rf charts/ingress-nginx/changelog/
