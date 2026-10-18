# 02-setup - cloud and edge Talos cluster over Tailscale

A single Kubernetes cluster whose control plane runs in a public cloud and whose workers
can sit anywhere, including bare metal behind NAT at an edge site. Nodes are joined by a
Tailscale mesh rather than a shared L2 network.

Every node registers kubelet and etcd on its Tailscale address. This is what removes the
need for a shared subnet, a public IP at the edge, or any inbound port forwarding. Talos
adds Tailscale addresses to the API server certificate SANs, so once the control plane has
joined the tailnet, its Tailscale address becomes the cluster endpoint.

More documentation:

- [docs/deployed-setup.md](docs/deployed-setup.md) - versions and components of the
  reference cluster
- [docs/pitfalls.md](docs/pitfalls.md) - known pitfalls when bringing the cluster up,
  re-provisioning a node or upgrading components
- [docs/osm-smoke-test.md](docs/osm-smoke-test.md) - registering the cluster with OSM and
  the end-to-end tests, including SR-IOV traffic
- [docs/network-boot.md](docs/network-boot.md) - iPXE network boot over mutual TLS, and a
  local Docker path to test it

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
replace a single `talosctl apply-config`. The trade-off changes with many sites. The
iPXE stage now has a local test path, see [docs/network-boot.md](docs/network-boot.md);
edge nodes are still provisioned from the ISO.

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

Images are built by [Talos Image Factory](https://factory.talos.dev) from the schematics
in `talos/schematics/`. Cloud and edge nodes use different ones:

| Schematic | Extensions | Kernel args |
|---|---|---|
| `cloud.yaml` | `tailscale` | - |
| `edge.yaml` | `tailscale`, `drbd`, `zfs`, `iscsi-tools`, `intel-ucode` | `iommu=pt intel_iommu=on` (VFIO passthrough) |

The `tailscale` extension lets a node join the mesh before it joins the cluster. It is
required on both sides.

`make schematics` in `talos/` registers both with the factory and prints their IDs. The
`gen-config-*` targets derive each node's installer image from the same schematic, so
the extensions survive upgrades.

Download and import the cloud image once:

```sh
cd talos && make image-cloud
gsutil cp ../_out/talos/images/talos-gcp-<talos-version>.raw.tar.gz gs://<your-bucket>/
gcloud compute images create talos-<talos-version> \
  --source-uri=gs://<your-bucket>/talos-gcp-<talos-version>.raw.tar.gz \
  --guest-os-features=VIRTIO_SCSI_MULTIQUEUE
```

For the edge, `make image-edge` downloads the metal ISO; write it to USB and boot from it.

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


Limit `allowed_cidrs` to your own address: the public ports are only needed until the nodes
have joined the tailnet.

The external IPs are needed only for the first config apply, before Tailscale is running:

```sh
terraform output master_external_ip
terraform output worker_external_ip
```

## Phase 3 - Generate machine configs

Talos configs are generated from patches, never edited directly. The patches use the
multi-document format of Talos 1.14, so `talosctl` must match.

| Patch | Purpose |
|---|---|
| `base.yaml` | Binds kubelet and etcd to the Tailscale address; external cloud provider; no Flannel |
| `controlplane.yaml` | Metrics bind addresses, kube-proxy in iptables mode, bundled CoreDNS disabled, Talos API access for the CCM |
| `cloud-nodes.yaml`, `edge-nodes.yaml` | Location labels and taints, install disk, edge kernel modules |
| `<node>-node.yaml` | Per-node install disk, hostname, volumes and udev rules |
| `tailscale.yaml` | Auth key via `ExtensionServiceConfig` (encrypted) |
| `registry-auth.yaml` | Pull credentials (encrypted) |

```sh
cd talos
sops -d -i secrets.yaml patches/tailscale.yaml patches/registry-auth.yaml
make gen-config CLUSTER_ENDPOINT=https://<master-external-ip>:6443
sops -e -i secrets.yaml patches/tailscale.yaml patches/registry-auth.yaml
```

Configs are written to `_out/talos/configs/`, one per node, plus `talosconfig`. The first
configs use the control plane's external IP as the endpoint, because its Tailscale address
does not exist yet; Phase 4 switches it.

## Phase 4 - Bootstrap the cloud cluster

Apply over the external IPs, since Tailscale is not yet running on a fresh node:

```sh
cd _out/talos/configs
export TALOSCONFIG=./talosconfig
talosctl apply-config --insecure --nodes <master-external-ip> --file cloud-master-1.yaml
talosctl apply-config --insecure --nodes <worker-external-ip> --file cloud-worker-1.yaml
talosctl bootstrap --nodes <master-external-ip>
```

The nodes reboot and join the tailnet within about 90 seconds. Set `CLUSTER_ENDPOINT` in
`talos/Makefile` to `https://<master-tailscale-ip>:6443`, regenerate, and apply again; the
change needs no reboot. From here on everything uses Tailscale addresses:

```sh
talosctl health    --nodes <master-tailscale-ip>
talosctl kubeconfig ./kubeconfig --nodes <master-tailscale-ip>
kubectl --kubeconfig=./kubeconfig get nodes -o wide
```

`INTERNAL-IP` should be a `100.x.x.x` address on every node. If it shows a VPC address,
`base.yaml` did not take effect; fix that before continuing, because the edge node cannot
reach a VPC address. Nodes stay `NotReady` until the CNI is installed.

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

Re-using a machine that already ran Talos is not this simple; see
[docs/pitfalls.md](docs/pitfalls.md#re-provisioning-an-edge-node).

A KVM-based edge path using OVS, dnsmasq and libvirt is available under `infra/` for
testing the join flow without hardware. It is not needed for a bare-metal edge node.
Network boot through iPXE is tested separately under `infra/pxe/`, see
[docs/network-boot.md](docs/network-boot.md).

## Phase 6 - Networking

Each component is a Helm or kustomize overlay; `cd` into its directory first, as the paths
are relative.

```sh
cd k8s/kube-ovn && make helm-upgrade    # CNI; nodes become Ready
cd ../coredns   && make helm-upgrade    # replaces the bundled CoreDNS
cd ../multus    && make helm-upgrade
```

Then the SR-IOV stack, if the edge node has suitable NICs:

```sh
cd ../sriov-network-operator && make helm-upgrade
kubectl apply -f split/policies.yaml     # VF pools, switchdev
kubectl apply -f ../kube-ovn/k8s/        # one OVS bridge per PF, with the PF as uplink
```

Talos needs two things here that upstream does not provide. The operator build must allow
its `/etc` paths to be configured, since Talos has no writable `/etc` - point `hostEtcPath`
and `hostUdevPath` at `/var/etc`. And the node's machine config must carry static udev
rules to give switchdev VF representors predictable names, because Talos reads udev rules
only from `/usr/lib/udev/rules.d` and ignores the ones the operator writes at runtime.

## Phase 7 - Cloud controller and storage

`externalCloudProvider` taints every node with `node.cloudprovider.kubernetes.io/uninitialized`
at boot. Deploy the CCM promptly, or workloads stay stuck behind that taint.

```sh
cd k8s/talos-ccm        && make helm-upgrade
cd ../pd-csi            && kubectl apply -k .
cd ../cert-manager      && make helm-upgrade
cd ../piraeus-operator  && make helm-upgrade
cd ../linstor           && make helm-upgrade
```

Talos CCM queries each node's Talos API, which is why Kubernetes Talos API access is
enabled in `controlplane.yaml`. It works for cloud and metal nodes alike: it clears the
taint, sets `providerID`, and applies topology labels.

Storage is split by location: the GCP PD driver for cloud nodes, and Linstor on a ZFS pool
for the edge. Linstor is the default StorageClass.

## Phase 8 - Platform services

```sh
cd k8s/kubevirt-operator     && make apply
cd ../kubevirt               && make apply
cd ../kubevirt-cdi-operator  && make apply
cd ../kubevirt-cdi           && make apply
cd ../monitoring             && make helm-upgrade
cd ../tailscale-operator     && make helm-upgrade
cd ../minio                  && make helm-upgrade
cd ../gitea                  && make helm-upgrade
cd ../kube-vim               && make helm-upgrade
cd ../osm                    && make helm-upgrade && make create-secrets
```

Once monitoring is up, run the `servicemonitor` targets of kube-ovn, kubevirt,
kubevirt-cdi and sriov-network-operator. Registering the cluster with OSM, and the
end-to-end tests, are in [docs/osm-smoke-test.md](docs/osm-smoke-test.md).

## Phase 9 - Verify

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
pod-to-service, DNS resolution, and external egress. Storage on each side can be checked
with `tests/test-linstor-pvc.yaml` and a `pd-standard` PVC on a cloud node.

## Node taints and Talos-managed manifests

Every node carries a `node.kubernetes.io/location` NoSchedule taint, so workloads must
tolerate their target location. The component charts under `k8s/` already do.

Talos's bundled CoreDNS does not tolerate custom taints, and `KubeCoreDNSConfig` exposes
only `enabled` and `image`, so this setup disables it and installs CoreDNS from
`k8s/coredns` under the same names. Upgrading Kubernetes with `talosctl upgrade-k8s` then
needs care; see [docs/pitfalls.md](docs/pitfalls.md#talos-managed-manifests).

## Layout

```
terraform/    cloud VPC and instances (modules: infrastructure, talos-cluster)
talos/        Makefile, patches/, schematics/, secrets.yaml
k8s/<comp>/   one overlay per component; most use `make helm-upgrade`, some use kustomize
infra/        optional KVM edge path: OVS, dnsmasq, libvirt
infra/pxe/    iPXE network boot test path in Docker: dnsmasq, QEMU VM, stub script server
tls/          lab PKI: root, Boot and Cluster CAs, iPXE server and client certificates (keys SOPS-encrypted)
ipxe/         builds ipxe.efi with the Boot CA and client certificate embedded
tests/        connectivity, storage and SSH test manifests
docs/         documentation
_out/talos/   generated configs, kubeconfig, talosconfig (gitignored)
_out/ipxe/    built ipxe.efi, contains the client key (gitignored)
```
