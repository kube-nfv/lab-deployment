update:
	rm -rf templates
	mkdir templates
	export RELEASE=$$(curl https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt) && \
	wget https://github.com/kubevirt/kubevirt/releases/download/$${RELEASE}/kubevirt-operator.yaml -O templates/kubevirt-operator.yaml
