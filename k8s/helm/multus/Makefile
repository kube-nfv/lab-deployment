update:
	rm -rf templates
	mkdir templates
	export VERSION=$$(basename $$(curl -s -w %{redirect_url} https://github.com/k8snetworkplumbingwg/multus-cni/releases/latest)) && \
	wget https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/$$VERSION/deployments/multus-daemonset-thick.yml -O templates/multus-daemonset-thick.yml && \
	sed -i.bak "s#multus-cni:snapshot-thick#multus-cni:$$VERSION-thick#" templates/multus-daemonset-thick.yml && rm templates/multus-daemonset-thick.yml.bak
	patch --no-backup-if-mismatch -p 1 < patches/resources.patch
