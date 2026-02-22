export NAME=kubeovn
export NAMESPACE=kube-system

update:
	rm -rf charts
	tag=$$(git ls-remote --tags --sort="v:refname" https://github.com/kubeovn/kube-ovn | awk -F'[/^]' 'END{print $$3}') && \
	curl -sSL https://github.com/kubeovn/kube-ovn/archive/refs/tags/$${tag}.tar.gz | \
	tar xzvf - --strip 2 kube-ovn-$${tag#*v}/charts/kube-ovn && \
	mkdir -p charts && mv kube-ovn charts/
