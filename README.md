# lab-deployment

Deployment configuration for the [kube-nfv](https://github.com/kube-nfv) lab clusters,
used to develop and demonstrate kube-vim - a Kubernetes-native Virtual Infrastructure
Manager for NFV.

This repository contains Talos Linux machine configs, Terraform for the cloud
infrastructure, and Helm values and kustomize overlays for the components installed on top
(kube-vim, OSM, KubeVirt, Kube-OVN, SR-IOV, storage, monitoring). There is nothing to
build; changes are applied by running a `make` target against a cluster.

## Setups

Two lab environments are kept here.

**[02-setup](02-setup/) - current.** A single Kubernetes cluster spanning cloud instances
and a bare-metal edge node, connected by a Tailscale mesh. Nodes register on their
Tailscale address, so the edge node needs no public IP and shares no subnet with the cloud.
VNF dataplane traffic stays off the overlay, on SR-IOV virtual functions switched in NIC
hardware. Talos images come from Image Factory; the cloud side is Terraform.

**[01-setup](01-setup/) - earlier iteration.** Fully local on a single KVM host, PXE-booted
with dnsmasq and Matchbox over an OVS bridge, flat L2. Kept for reference.

Both run Kube-OVN and Linstor/Piraeus.

## Documentation

- [02-setup/README.md](02-setup/README.md) - architecture and deployment walkthrough
- [02-setup/docs/deployed-setup.md](02-setup/docs/deployed-setup.md) - versions and
  components the reference cluster runs
- [01-setup/README.md](01-setup/README.md) - the local PXE environment

Addresses and hostnames in these documents are placeholders. The lab runs on cloud free
tier with ephemeral external IPs, so published addresses go stale quickly.

## Conventions

Talos configs are generated, not hand-written: edit the patches under `talos/patches/` and
run a `make gen-config-*` target. Generated output goes to `_out/` and is gitignored.

Secrets are encrypted with SOPS and age in place, keeping the original filename. Decrypt
with `sops -d -i`, run the target, then re-encrypt with `sops -e -i`.

Upstream Helm charts are vendored under `charts/` rather than fetched at install time.
Wrapper chart versions are all `0.0.1` and do not track upstream.

Component overlays use relative paths, so `cd` into the component directory before running
its `make` target.

## Related repositories

| Repository | Purpose |
|---|---|
| [kube-vim](https://github.com/kube-nfv/kube-vim) | The VIM - gRPC services for the ETSI Or-Vi and Vi-Vnfm reference points |
| [kube-vim-api](https://github.com/kube-nfv/kube-vim-api) | Protobuf and OpenAPI definitions |
| [query-filter](https://github.com/kube-nfv/query-filter) | ETSI GS NFV-SOL 013 filter expression parser |

Project documentation: [kubevim.kubenfv.io](https://kubevim.kubenfv.io)

## License

Apache 2.0 - see [LICENSE](LICENSE).
