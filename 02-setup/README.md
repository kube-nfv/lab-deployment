# 02-setup - cloud and edge Talos cluster over Tailscale

A single Kubernetes cluster whose control plane runs in a public cloud and whose workers
can sit anywhere, including bare metal behind NAT at an edge site. Nodes are joined by a
Tailscale mesh rather than a shared L2 network.

Every node registers kubelet and etcd on its Tailscale address. This is what removes the
need for a shared subnet, a public IP at the edge, or any inbound port forwarding. Talos
adds Tailscale addresses to the API server certificate SANs, so the cluster endpoint can be
the control plane's Tailscale address from the first apply.

For versions and the component list of the reference cluster, see
[docs/deployed-setup.md](docs/deployed-setup.md).

Addresses, project names and node names below are placeholders written as `<…>`. The
reference lab runs on cloud free tier with ephemeral external IPs, so literal values would
be stale.

## Architecture

```
                          ┌──────────────────────────┐
                          │           Cloud          │
                          │  control plane + workers │
                          │  VPC <cloud-cidr>        │
                          └───────────┬──────────────┘
                                      │
                    Tailscale mesh (WireGuard, 100.64.0.0/10)
                    kubelet, etcd and the Talos API bind here
                                      │
                          ┌───────────┴──────────────┐
                          │        Edge site         │
                          │  bare-metal worker(s)    │
                          │  behind NAT, no inbound  │
                          │  SR-IOV NICs for VNF     │
                          │  dataplane               │
                          └──────────────────────────┘
```

### Design decisions

| Decision | Choice | Reason |
|---|---|---|
| Overlay | Tailscale (WireGuard) | Connectivity through NAT without a public IP at the edge |
| Kubelet and etcd node IP | Tailscale address (`100.64.0.0/10`) | One address family reachable from every node |
| Cluster endpoint | Control plane's Tailscale address | Reachable from the edge, and stable - it is embedded in every machine config |
| CNI | Kube-OVN, with `cluster.network.cni.name: none` | VLAN and underlay support with hardware offload, required for the NFV dataplane |
| Multi-NIC | Multus | VNFs need more interfaces than the primary CNI provides |
| OS | Talos Linux | Immutable and API-managed; machine config is declarative and reproducible |
| Cloud controller | Talos CCM only | Works for both cloud and metal nodes. A vendor CCM only adds LoadBalancer and route support, which the overlay makes unnecessary |
| Node placement | `node.kubernetes.io/location` label and NoSchedule taint | Every workload must state whether it belongs in the cloud or at the edge |

Edge nodes are provisioned by booting an Image Factory ISO and applying a machine config
over the local network, once. An earlier design provisioned them automatically by network
boot against a cloud-hosted iPXE and machine-config service. That was not adopted: for a
lab with one edge site it requires a PKI, two internet-facing services, control of the edge
DHCP server, and an answer to how a node with no credentials proves its identity - all to
replace a single `talosctl apply-config`. The trade-off changes with many sites, and the
idea may return in a later setup.

## Prerequisites

| Tool | Notes |
|---|---|
| `talosctl` | Matching the minor version of the Talos release being deployed |
| `terraform` | 1.5.0 or later |
| `kubectl`, `helm` | |
| `sops` with an age key | Secrets are encrypted in place, keeping the original filename |
| Cloud credentials | Compute API enabled, e.g. `gcloud auth application-default login` |
| A Tailscale tailnet | With a reusable, pre-authorized auth key |

The edge site needs a machine that boots from USB and has outbound internet access. No
inbound reachability and no PXE infrastructure are required.

The Makefiles pass files to their tools unchanged, and no `helm secrets` plugin is in use,
so an encrypted file would reach `talosctl` or `helm` as `ENC[AES256_GCM,…]`. Decrypt in
place, run the target, then re-encrypt, and do not commit in between.

## Phase 1 - Build Talos images

Images are built by [Talos Image Factory](https://factory.talos.dev). Cloud and edge nodes
use different schematics because they need different extensions:

| Node type | Extensions | Schematic ID |
|---|---|---|
| Cloud (GCP) | `tailscale`, `gcp-guest-agent` | `4a0d65c669d46663f377e7161e50cfd570c401f26fd9e7bda34a0216b6f1922b` |
| Edge (metal) | `tailscale` | `dd4c55ac62d0fcebfb2189927a204d5bddce05dbfee89a8ee1d557e1d416f800` |

The `tailscale` extension lets a node join the mesh before it joins the cluster. It is
required on both sides.

Import the cloud image once:

```sh
curl -L -o talos-gcp.tar.gz \
  "https://factory.talos.dev/image/<cloud-schematic-id>/<talos-version>/gcp-amd64.raw.tar.gz"
gsutil cp talos-gcp.tar.gz gs://<your-bucket>/
gcloud compute images create talos-<talos-version> \
  --source-uri=gs://<your-bucket>/talos-gcp.tar.gz \
  --guest-os-features=VIRTIO_SCSI_MULTIQUEUE
```

For the edge, write the metal ISO to USB and boot from it:

```
https://factory.talos.dev/image/<edge-schematic-id>/<talos-version>/metal-amd64.iso
```

The installer image in `talos/patches/{cloud,edge}-nodes.yaml` must use the same
schematic, otherwise the extensions are lost on the first upgrade.

## Phase 2 - Cloud infrastructure

```sh
cd terraform
sops -d -i terraform.tfvars
terraform init && terraform plan && terraform apply
sops -e -i terraform.tfvars
```

This creates a VPC and subnet, firewall rules for TCP 50000 (Talos API), TCP 6443
(Kubernetes API) and internal traffic, and the control plane and worker instances with
external IPs. Machine types and the image are set in `terraform.tfvars`; see
`terraform.tfvars.example`.

The external IPs are needed only for the first config apply, before Tailscale is running:

```sh
terraform output master_external_ip
terraform output worker_external_ip
```

## Phase 3 - Generate machine configs

Talos configs are generated from patches, never edited directly.

| Patch | Purpose |
|---|---|
| `base.yaml` | Binds kubelet and etcd to the Tailscale address; sets `cni.name: none` |
| `controlplane.yaml` | Control-plane role, `location=cloud` label and taint |
| `cloud-nodes.yaml`, `edge-nodes.yaml` | Per-location installer image, labels and taints |
| `<node>-node.yaml` | Per-node install disk and any node-specific udev rules |
| `tailscale.yaml` | Auth key via `ExtensionServiceConfig` (encrypted) |
| `registry-auth.yaml` | Pull credentials (encrypted) |

```sh
cd talos
sops -d -i secrets.yaml patches/tailscale.yaml patches/registry-auth.yaml
make gen-config
sops -e -i secrets.yaml patches/tailscale.yaml patches/registry-auth.yaml
```

Configs are written to `_out/talos/configs/`, one per node, plus `talosconfig`. Individual
`gen-config-<node>` targets exist as well.

Set `CLUSTER_ENDPOINT` in `talos/Makefile` to the control plane's Tailscale address before
generating. It is embedded in every config and should not change afterwards.

## Phase 4 - Bootstrap the cloud cluster

Apply over the external IPs, since Tailscale is not yet running on a fresh node:

```sh
cd _out/talos/configs
export TALOSCONFIG=./talosconfig
talosctl apply-config --insecure --nodes <master-external-ip> --file cloud-master-1.yaml
talosctl apply-config --insecure --nodes <worker-external-ip> --file cloud-worker-1.yaml
```

The nodes reboot and join the tailnet in about 60 to 90 seconds. Everything after this uses
Tailscale addresses:

```sh
talosctl bootstrap --nodes <master-tailscale-ip>
talosctl health    --nodes <master-tailscale-ip>
talosctl kubeconfig ./kubeconfig --nodes <master-tailscale-ip>
kubectl --kubeconfig=./kubeconfig get nodes -o wide
```

`INTERNAL-IP` should be a `100.x.x.x` address on every node. If it shows a VPC address,
`base.yaml` did not take effect; fix that before continuing, because the edge node cannot
reach a VPC address.

The generated kubeconfig points at the control plane's public IP, which changes whenever
the instance is recreated. A kubeconfig that stops connecting usually needs its `server:`
field refreshed rather than a rebuilt cluster.

## Phase 5 - Join an edge node

Boot the machine from the metal ISO. In maintenance mode it takes a DHCP address on the
local network; apply the config over that address once:

```sh
talosctl apply-config --insecure \
  --nodes <edge-lan-ip> \
  --file _out/talos/configs/<edge-node>.yaml
```

Talos installs to disk, reboots, starts Tailscale using the auth key from the config, and
joins the cluster at the control plane's Tailscale address. The local address is not needed
again.

```sh
kubectl get nodes -o wide
```

Do not set `machine.network.hostname` in a patch alongside `v1alpha1` config; it fails
validation. Let DHCP or the installer set the hostname.

A KVM-based edge path using OVS, dnsmasq and libvirt is available under `infra/` for
testing the join flow without hardware. It is not needed for a bare-metal edge node.

## Phase 6 - CNI and multi-NIC

The cluster has no pod networking until Kube-OVN is installed, because Talos is configured
with `cni.name: none`. Each component is a Helm overlay; `cd` into its directory first, as
the paths are relative.

```sh
cd k8s/kube-ovn && make helm-upgrade
cd ../multus    && make helm-upgrade
```

Then the SR-IOV stack, if the edge node has suitable NICs:

```sh
cd ../sriov-network-operator && make helm-upgrade
```

Talos needs two things here that upstream does not provide. The operator build must allow
its `/etc` paths to be configured, since Talos has no writable `/etc` - point `hostEtcPath`
and `hostUdevPath` at `/var/etc`. And the node's machine config must carry static udev
rules to give switchdev VF representors predictable names, because Talos reads udev rules
only from `/usr/lib/udev/rules.d` and ignores the ones the operator writes at runtime.

## Phase 7 - Cloud controller and storage

`externalCloudProvider` is enabled in the control-plane patch, which taints every node with
`node.cloudprovider.kubernetes.io/uninitialized` at boot. Deploy the CCM promptly, or
workloads stay stuck behind that taint.

```sh
cd k8s/talos-ccm && make helm-upgrade
```

Talos CCM queries each node's Talos API, which is why
`machine.features.kubernetesTalosAPIAccess` is set. It works for both cloud and metal
nodes: it clears the taint, sets `providerID`, and applies topology labels.

If the CCM is added to a cluster whose nodes already registered without
`--cloud-provider=external`, `providerID` is not set retroactively. Add the taint manually
once and the CCM clears it within seconds.

Storage is split by location: a cloud-only CSI driver (`kubectl apply -k k8s/pd-csi/`,
pinned by `?ref=` and patched for Talos) and a replicated local-storage provisioner
available on all nodes.

## Phase 8 - Verify

```sh
kubectl get nodes -o wide
kubectl get nodes -o custom-columns='NAME:.metadata.name,PROVIDER:.spec.providerID'
kubectl get nodes -o custom-columns='NAME:.metadata.name,LOCATION:.metadata.labels.node\.kubernetes\.io/location'
```

Every node should be `Ready` with a Tailscale `INTERNAL-IP`, a `providerID`, a location
label, and no `uninitialized` taint.

Cross-site pod networking is the test that matters, since it exercises the Tailscale hop:

```sh
kubectl apply -f tests/busybox-connectivity.yaml
```

From a pod on a cloud node, check pod-to-pod against a pod on the edge node, then
pod-to-service, DNS resolution, and external egress.

Scheduling and storage can be checked with a node selector:

```sh
kubectl run test-cloud --image=busybox --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"node.kubernetes.io/location":"cloud"}}}' -- sleep 3600
```

## Node taints and Talos-managed manifests

Every node carries a `node.kubernetes.io/location` NoSchedule taint, so workloads must
tolerate their target location. The component charts under `k8s/` already do.

Talos's own bootstrap manifests do not tolerate custom taints. CoreDNS is the one that
causes trouble: its Deployment ships only the standard control-plane tolerations, so once
every node is tainted its pods cannot be scheduled. An already-running pod keeps running,
since a NoSchedule taint does not evict, which hides the problem until a rollout happens -
usually during `talosctl upgrade-k8s`, which then hangs.

Patching the Deployment works but does not survive, because Talos rewrites the manifest on
every `upgrade-k8s` and `cluster.coreDNS` exposes only `disabled` and `image`. The durable
options are to disable the bundled CoreDNS and manage your own, inject the toleration with
an admission mutation, or re-apply it with a reconciler after upgrades. The same applies to
any customisation of a Talos-managed bootstrap manifest.

## Layout

```
terraform/    cloud VPC and instances (modules: infrastructure, talos-cluster)
talos/        Makefile, patches/, secrets.yaml
k8s/<comp>/   one overlay per component; most use `make helm-upgrade`, some use kustomize
infra/        optional KVM edge path: OVS, dnsmasq, libvirt
tests/        connectivity, storage and SSH test manifests
docs/         documentation
_out/talos/   generated configs, kubeconfig, talosconfig (gitignored)
```
