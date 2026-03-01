update:
	rm -rf charts
	helm repo add gitea-charts https://dl.gitea.com/charts/
	helm repo update gitea-charts
	helm pull gitea-charts/gitea --untar --untardir charts
	helm dependency update .
