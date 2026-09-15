# The reference deployment

What the 02-setup lab runs, as of 2026-09-13. The [README](../README.md) is written
generically so it can be followed against any cloud project and edge site; this page
records the actual instance.

Addresses, MAC addresses, hardware serials and credentials are not listed here. Anything
needed to operate the cluster is read at runtime, with `kubectl get nodes -o wide` or the
cloud CLI, rather than copied from a document.

## Versions

| Component | Version |
|---|---|
| Talos Linux | v1.13.6 |
| Kubernetes | v1.34.1 |
| containerd | 2.2.5 |
| Open vSwitch | 3.5.5 |
| KubeVirt | v1.8.4 |

Cluster name is `setup02-cluster`. The nodes were upgraded in place past the Talos version
baked into the original cloud image, so the image version and the running version differ.
`talosctl version` is authoritative.

## Nodes

| Role | Location | Shape |
|---|---|---|
| control plane | cloud | GCE `e2-standard-2` |
| worker | cloud | GCE `e2-standard-4` |
| worker | edge | bare metal, Xeon Gold 6140 (36 threads), 64 GB, dual-port 25G SR-IOV NIC |

Both cloud nodes are in one zone of a single region. The edge node is a separate site,
labelled `topology.kubernetes.io/zone=edge-site-1`.

Every node carries `node.kubernetes.io/location` as a label (`cloud` or `edge`) and as a
NoSchedule taint. Cloud nodes get a `gce://` providerID from the Talos CCM; the edge node
gets `talos://metal/<address>`.

## Networking

| | |
|---|---|
| Overlay | Tailscale (WireGuard); kubelet and etcd register on `100.64.0.0/10` |
| CNI | Kube-OVN, with `cluster.network.cni.name: none`. There is no Flannel in this cluster |
| Multi-NIC | Multus |
| Cloud VPC | a single private /24 |
| Pod traffic between nodes | Geneve tunnels over the tailnet |

The edge site is a flat subnet behind a router that NATs outbound only, with no inbound
path from outside. This is why the Tailscale mesh is load-bearing rather than a
convenience.

### Dataplane

The edge node's two 25G ports are not part of the overlay. Each is a Kube-OVN
`ProviderNetwork` with its own hardware-offloaded OVS bridge, carrying VNF traffic only:

| ProviderNetwork | Bridge | Role |
|---|---|---|
| `mx5p0` | `br-mx5p0` | VNF dataplane, PF0 |
| `mx5p1` | `br-mx5p1` | VNF dataplane, PF1 |

Both ports run in switchdev mode with 18 VFs each, split between `vfio-pci` VFs passed
through to KubeVirt VMs and `netdevice` VFs for container workloads. They are advertised as
`openshift.io/mlx_vf_pf{0,1}_{vfio,netdev}`. Traffic between a VF and the wire is switched
in NIC hardware through TC-flower, not by the host CPU.

Both ports reach a traffic generator through a MikroTik CRS504-4XQ, using QSFP28 to 4x
SFP28 breakout cables so each box takes 2x25G from one cage. The switch carries the
dataplane only - its management port is deliberately kept out of that bridge, because the
RouterOS factory config bridges the two together and merges the dataplane into the lab
management subnet.

Each PF is paired with one traffic-generator port over an untagged access VLAN, so the two
paths are separate L2 segments and nothing in the dataplane carries an IP address. Which
port is paired with which is switch configuration rather than cabling, and the layouts are
kept as swappable RouterOS scripts under `infra/crs504/`.

## Storage

| StorageClass | Backing | Scope |
|---|---|---|
| `local` (default) | Linstor / Piraeus | all nodes |
| `pd-standard` | cloud PD CSI | cloud nodes only; the node DaemonSet is pinned to `location=cloud` |

## Installed components

cert-manager, kube-ovn, multus, SR-IOV network operator, KubeVirt and CDI,
Linstor/Piraeus, kube-prometheus-stack, Talos CCM, PD CSI, Tailscale operator, minio,
gitea, kube-vim and OSM.

Two things that are not as they appear:

`ingress-nginx` has an overlay under `k8s/` but is not installed. Services are published
through the Tailscale operator instead, which puts them on the tailnet rather than behind a
public ingress.

OSM's helm-based execution environments appear as extra Helm releases in UUID-named
namespaces (`eechart-*`). They are managed by OSM and should not be removed by hand.

Several components ship a separate `make servicemonitor` target that Helm does not apply
(`kube-ovn`, `kubevirt`, `kubevirt-cdi`, `sriov-network-operator`, `multus`). Run those
after the monitoring stack is up.

## Deviations from the generic guide

The SR-IOV network operator is a fork rather than upstream. It makes the daemon's `/etc`
paths configurable, because Talos has no writable `/etc`, and the node's machine config
carries static udev rules so switchdev VF representors get predictable names. Talos reads
udev rules only from `/usr/lib/udev/rules.d`, so the rules the operator writes at runtime
have no effect.

The ovs-cni image is pinned and should not be moved to `:latest`. A build published after
2025-11-01 regressed VF discovery, which stops SR-IOV workloads from starting.

Upstream Helm charts are vendored rather than fetched at install time, so bumping one means
re-pulling into `charts/` and committing the result. The wrapper chart versions are all
`0.0.1` and carry no meaning; read `charts/` for the real upstream version.
