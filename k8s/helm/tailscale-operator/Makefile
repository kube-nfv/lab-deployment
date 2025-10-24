update:
	rm -rf charts
	helm repo add tailscale https://pkgs.tailscale.com/helmcharts
	helm repo update tailscale
	helm pull tailscale/tailscale-operator --untar --untardir charts
