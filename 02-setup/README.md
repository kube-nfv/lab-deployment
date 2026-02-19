# 02-Setup Cloud-Edge Automatic Provisioning

This setup focuses on automatic provisioning of Talos edge nodes that join an existing cloud cluster with preinstalled OSM via network boot and Tailscale overlay networking.

## Architecture

```
                         Internet
                            |
              ┌─────────────┴─────────────┐
              |                           |
     ┌────────┴────────┐        ┌────────┴────────┐
     │   Cloud Side    │        │   Edge Side      │
     └────────┬────────┘        └────────┬────────┘
              |                           |
  ┌───────────┼───────────┐        ┌─────┴─────┐
  |           |           |        |           |
[Talos     [iPXE       [Machine  [DHCP      [Edge
 Cluster]   Server]     Config    Server]    Node]
             |          Server]    (iPXE      (PXE Boot)
             |           |        options)
             └─────┬─────┘
                   |
            [Tailscale Network]
                   |
         ┌─────────┴─────────┐
         |                   |
    [Cloud Nodes]       [Edge Node]
```

## How It Works

### Boot Flow

1. **Edge Node PXE Boot**:
   - Bare-metal (or QEMU) host boots with network boot option
   - Node discovers DHCP server in the local L2 network

2. **DHCP/iPXE Stage** (Edge):
   - DHCP server is preconfigured with iPXE endpoint pointing to the cloud-based iPXE server
   - DHCP response includes security parameters for authenticated communication

3. **iPXE/HTTP Stage** (Cloud):
   - Cloud-based iPXE server identifies the node and its target cluster
   - Serves Talos kernel and initramfs with Tailscale extension included
   - Sets `talos.config` kernel argument pointing to the cloud machine config endpoint

4. **Talos Configuration** (Cloud):
   - Edge node fetches machine config from the authenticated cloud endpoint
   - Machine config contains Tailscale configuration and cluster join parameters
   - Node joins the existing Talos cluster over the Tailscale overlay network

### Security

- All iPXE communication is encrypted and authenticated
- `talos.config` kernel argument endpoint requires authenticated requests
- Machine config is served over encrypted channels

## Edge Node Preconfiguration

The following infrastructure must be prepared at the edge site:

1. **Management Network**:
   - L2 network with connection to the Internet (may be NATed)

2. **DHCP Server**:
   - Must be in the same L2 domain as the edge node (or use DHCP Relay)
   - Preconfigured options for iPXE server endpoint pointing to the cloud
   - Security parameters for secure communication with the cloud iPXE server

## Cloud Preconfiguration

The following components must be available in the cloud:

1. **Existing Talos Cluster**:
   - Running cluster where the edge node will join
   - Tailscale extension installed and configured to join the same Tailscale network as the edge node

2. **iPXE Server**:
   - Internet-reachable endpoint
   - Correlates iPXE requests to the correct cluster
   - Prepares boot images and kernel arguments per node
   - Creates and serves machine config endpoint via `talos.config` kernel argument

3. **Machine Config Server**:
   - Serves Talos machine configuration referenced by the `talos.config` kernel argument
   - Includes Tailscale join configuration and cluster membership parameters

4. **Authentication & Encryption**:
   - All iPXE and Talos machine config communication must be authenticated and encrypted

## Prerequisites

- Existing Talos cluster (cloud side)
- Tailscale network and auth keys
- iPXE server with internet-reachable endpoint
- Machine config HTTP server
- TLS certificates for iPXE and machine config endpoints
- Edge site:
  - Bare-metal or QEMU host with PXE boot support
  - DHCP server with iPXE boot options configured

## Files

- `README.md` - Documentation
- `CONSIDERATIONS.md` - Implementation considerations, design decisions, and open questions

---

## Deployment Guide: Tailscale Mesh Cluster

This section documents the concrete steps to deploy the current implementation: a Talos Kubernetes cluster spanning GCP cloud nodes and a local KVM edge node, connected via a Tailscale overlay network.

### Design Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Overlay network | Tailscale (WireGuard) | Zero-config cross-network connectivity; works through NAT |
| Kubelet node IP | Tailscale IP (`100.64.0.0/10`) | All nodes (cloud + edge) must be reachable by the same IP family |
| Cluster API endpoint | Master's Tailscale IP | API server must be reachable from edge nodes; Talos auto-adds Tailscale IPs to cert SANs |
| Pod networking | Flannel VXLAN over `tailscale0` | Pod-to-pod traffic tunneled through Tailscale, not local network |
| Talos extensions | `tailscale` (all nodes), `gcp-guest-agent` (cloud only) | Embedded in custom Talos images from Image Factory |

### Prerequisites

- `talosctl` installed
- `terraform` >= 1.5.0 installed
- `kubectl` installed
- GCP project with Compute Engine API enabled and credentials configured (`gcloud auth application-default login`)
- Tailscale account with a generated reusable auth key
- SOPS + Age key configured (secrets are encrypted at rest)
- For edge node: KVM/libvirt host with OpenVSwitch and Docker installed

---

### Phase 1: Build Talos Images with Tailscale Extension

Images are built via [Talos Image Factory](https://factory.talos.dev). The schematics used in this setup:

| Node type | Extension | Schematic ID |
|-----------|-----------|--------------|
| Cloud (GCP) | `tailscale` + `gcp-guest-agent` | `4a0d65c669d46663f377e7161e50cfd570c401f26fd9e7bda34a0216b6f1922b` |
| Edge (metal) | `tailscale` | `7d4c31cbd96db9f90c874990697c523482b2bae27fb4631d5583dcd9c281b1ff` |

For GCP, import the image into your project:

```bash
# Download the GCP image tarball
curl -L -o talos-gcp.tar.gz \
  "https://factory.talos.dev/image/4a0d65c669d46663f377e7161e50cfd570c401f26fd9e7bda34a0216b6f1922b/v1.12.4/gcp-amd64.raw.tar.gz"

# Upload to GCS
gsutil cp talos-gcp.tar.gz gs://<your-bucket>/

# Create GCP image
gcloud compute images create talos-v1-12-4 \
  --source-uri=gs://<your-bucket>/talos-gcp.tar.gz \
  --guest-os-features=VIRTIO_SCSI_MULTIQUEUE
```

For edge, download the metal ISO with the correct schematic from Image Factory:
```
https://factory.talos.dev/image/7d4c31cbd96db9f90c874990697c523482b2bae27fb4631d5583dcd9c281b1ff/v1.12.4/metal-amd64.iso
```

Place the ISO at `/var/lib/libvirt/images/talos-edge-tailscale.iso` on the KVM host.

---

### Phase 2: Cloud Infrastructure (Terraform)

```bash
cd 02-setup/terraform

# Decrypt tfvars (SOPS-encrypted)
sops -d terraform.tfvars.enc > terraform.tfvars  # or however you decrypt

terraform init
terraform plan
terraform apply
```

This provisions:
- VPC `setup02-cluster-vpc` with subnet `10.1.0.0/24`
- Firewall rules: TCP 50000 (Talos API), TCP 6443 (Kubernetes API), all-internal
- 2 GCE instances with static external IPs:
  - `setup02-cluster-master-1` — e2-standard-4, 50 GB
  - `setup02-cluster-worker-1` — e2-standard-8, 50 GB

After apply, note the external IPs of both instances (used to apply the initial Talos config before Tailscale is up):

```bash
terraform output master_external_ip
terraform output worker_external_ip
```

---

### Phase 3: Generate Talos Machine Configs

The `talos/patches/` directory contains configuration patches applied to all generated configs:

| Patch file | Purpose |
|------------|---------|
| `base.yaml` | Forces kubelet to register with Tailscale IP (`100.64.0.0/10`) on all nodes |
| `cloud-nodes.yaml` | Sets GCP installer image (with gcp-guest-agent extension) |
| `edge-nodes.yaml` | Sets metal installer image |
| `tailscale.yaml` | Injects Tailscale auth key via `ExtensionServiceConfig` (**encrypted**) |
| `edge-worker-1-node.yaml` | Sets install disk (`/dev/vda`) for the edge VM |

Before generating configs, decrypt the encrypted patches:

```bash
# Decrypt secrets and tailscale patch (handle with care — contain sensitive keys)
sops -d talos/secrets.yaml > talos/secrets.dec.yaml
sops -d talos/patches/tailscale.yaml > talos/patches/tailscale.dec.yaml
```

Generate all configs:

```bash
cd 02-setup/talos

# Edit Makefile if needed:
#   CLUSTER_ENDPOINT — must be master's Tailscale IP (set after first boot)
#   SECRETS_FILE    — point to decrypted secrets file

make gen-config
```

Configs are written to `02-setup/_out/talos/configs/`:
- `cloud-master-1.yaml` — controlplane config
- `cloud-worker-1.yaml` — cloud worker config
- `edge-worker-1.yaml` — edge node config
- `talosconfig` — talosctl client config

> **Note on cluster endpoint**: The endpoint `https://100.118.101.20:6443` is the master's Tailscale IP. Talos automatically adds Tailscale IPs to the API server's TLS certificate SANs when the Tailscale extension is active, so this is safe to use from the first apply.

---

### Phase 4: Bootstrap the Cloud Cluster

Use the GCP external IPs for initial config apply (Tailscale is not yet up on fresh nodes):

```bash
cd 02-setup/_out/talos/configs

export TALOSCONFIG=./talosconfig
MASTER_EXT_IP=<master-external-ip>
WORKER_EXT_IP=<worker-external-ip>

# Apply configs
talosctl apply-config --insecure --nodes $MASTER_EXT_IP --file cloud-master-1.yaml
talosctl apply-config --insecure --nodes $WORKER_EXT_IP --file cloud-worker-1.yaml
```

After the nodes reboot and Tailscale connects (~60–90 seconds), bootstrap etcd on the master:

```bash
# Use Tailscale IP once the node is reachable via Tailscale
talosctl bootstrap --nodes 100.118.101.20

# Wait for cluster to be healthy (run against master node only)
talosctl health --nodes 100.118.101.20

# Retrieve kubeconfig
talosctl kubeconfig ./kubeconfig --nodes 100.118.101.20

# Verify nodes
kubectl --kubeconfig=./kubeconfig get nodes -o wide
```

Both cloud nodes should appear as `Ready` with Tailscale IPs in the `INTERNAL-IP` column.

---

### Phase 5: Edge Node Infrastructure (Local KVM)

The edge site uses an OVS bridge for the edge VM network with a dnsmasq DHCP server.

#### 5.1 Prepare LVM storage

If the edge VM disk does not exist yet, create it from a free partition:

```bash
# Create LVM physical volume, volume group, and logical volume
sudo pvcreate /dev/sda7
sudo vgcreate vg-talos-setup02 /dev/sda7
sudo lvcreate -l 100%FREE -n talos-setup02-edge1 vg-talos-setup02
```

#### 5.2 Start the edge network service

```bash
# Install and start the systemd service (creates OVS bridge + dnsmasq)
sudo cp 02-setup/infra/02-setup-edge-net.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now 02-setup-edge-net.service

# Verify
sudo systemctl status 02-setup-edge-net.service
sudo ovs-vsctl show
```

The service creates:
- OVS bridge `setup02-edge` at `10.0.20.1/24`
- dnsmasq container at `10.0.20.2/24` serving DHCP on `10.0.20.10–200`
- NAT (masquerade) for internet access from the edge network

#### 5.3 Define the libvirt network and VM

```bash
# Define OVS-backed libvirt network
virsh net-define 02-setup/infra/libvirt/qemu/networks/02-setup-edge-net.xml
virsh net-start setup02-edge
virsh net-autostart setup02-edge

# Define the edge VM
virsh define 02-setup/infra/libvirt/qemu/talos-setup02-edge-1.xml
```

The VM (`talos-setup02-edge-1`) is configured with:
- 4 vCPU, 8 GB RAM
- Boot order: ISO first (`/var/lib/libvirt/images/talos-edge-tailscale.iso`), then disk
- LVM disk: `/dev/vg-talos-setup02/talos-setup02-edge1`
- MAC address: `52:54:00:00:02:01` → static DHCP lease `10.0.20.10` (hostname `talos-edge-1`)
- Network: `setup02-edge` (OVS bridge)

---

### Phase 6: Install Talos on the Edge Node

```bash
# Start the VM — it will PXE/ISO boot into the Talos installer
virsh start talos-setup02-edge-1

# Apply the edge node config (while Talos is running from ISO, before install)
talosctl apply-config --insecure \
  --nodes 10.0.20.10 \
  --file 02-setup/_out/talos/configs/edge-worker-1.yaml \
  --talosconfig 02-setup/_out/talos/configs/talosconfig
```

Talos will install to `/dev/vda`, reboot, and automatically:
1. Connect to the Tailscale network using the auth key from the machine config
2. Join the cluster via the master's Tailscale IP (`100.118.101.20:6443`)

After a few minutes, verify the edge node has joined:

```bash
kubectl --kubeconfig=02-setup/_out/talos/configs/kubeconfig get nodes -o wide
```

The edge node (`talos-edge-1`) should appear as `Ready` with its Tailscale IP in `INTERNAL-IP`.

> **Note**: The edge node hostname is set by the dnsmasq DHCP static lease (`talos-edge-1`). Setting `machine.network.hostname` in the Talos patch is not supported alongside `v1alpha1` config and will cause a validation error.

---

### Phase 7: Configure Flannel to Use the Tailscale Interface

By default, Flannel picks the first non-loopback interface for its VXLAN VTEP, which is the local network IP (e.g., `10.1.0.x` for cloud, `10.0.20.x` for edge). This breaks cross-network pod-to-pod traffic because those IPs are not routable between sites.

Patch the Flannel DaemonSet to use `tailscale0`:

```bash
kubectl --kubeconfig=02-setup/_out/talos/configs/kubeconfig \
  patch daemonset kube-flannel -n kube-system \
  --type=json \
  -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": ["--ip-masq", "--kube-subnet-mgr", "--iface=tailscale0"]}]'

# Wait for rollout
kubectl --kubeconfig=02-setup/_out/talos/configs/kubeconfig \
  rollout status daemonset/kube-flannel -n kube-system
```

> **Note**: This patch is applied live and will be lost if nodes are fully reset and Talos re-deploys Flannel. Plan to migrate to kube-OVN or another CNI that supports interface selection natively.

Verify VTEP IPs are Tailscale addresses after the rollout:

```bash
kubectl --kubeconfig=02-setup/_out/talos/configs/kubeconfig get nodes \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip}{"\n"}{end}'
```

All nodes should show `100.x.x.x` Tailscale IPs.

---

### Verification

Run the connectivity test suite from `02-setup/tests/`:

```bash
export KC=02-setup/_out/talos/configs/kubeconfig

# Deploy busybox DaemonSet on all nodes (including master — tolerations: Exists)
kubectl --kubeconfig=$KC apply -f 02-setup/tests/busybox-connectivity.yaml

# Wait for pods
kubectl --kubeconfig=$KC get pods -o wide

# Create a test file in each pod
for pod in $(kubectl --kubeconfig=$KC get pods -l app=busybox-test -o name); do
  node=$(kubectl --kubeconfig=$KC get $pod -o jsonpath='{.spec.nodeName}')
  kubectl --kubeconfig=$KC exec ${pod#pod/} -- sh -c "echo 'hello from $node' > /tmp/test.txt"
done

SVC_IP=$(kubectl --kubeconfig=$KC get svc busybox-test -o jsonpath='{.spec.clusterIP}')

# Test pod-to-pod (ping)
kubectl --kubeconfig=$KC exec <edge-pod> -- ping -c3 <cloud-worker-pod-ip>
kubectl --kubeconfig=$KC exec <edge-pod> -- ping -c3 <master-pod-ip>

# Test pod-to-service (ClusterIP)
kubectl --kubeconfig=$KC exec <edge-pod> -- wget -qO- http://$SVC_IP:8080/test.txt

# Test pod-to-service (DNS)
kubectl --kubeconfig=$KC exec <edge-pod> -- wget -qO- http://busybox-test.default.svc.cluster.local:8080/test.txt

# Test external egress from pods
kubectl --kubeconfig=$KC exec <edge-pod> -- wget -qO- http://example.com
kubectl --kubeconfig=$KC exec <edge-pod> -- nslookup google.com
```

Expected results:
- Pod-to-pod ping: 0% packet loss, RTT reflects Tailscale latency (~5–20 ms for cloud-to-cloud, ~20–50 ms for cloud-to-edge)
- Pod-to-service: returns content from one of the 3 backend pods (kube-proxy load-balances)
- DNS: resolves both in-cluster (`*.svc.cluster.local`) and external names
- Egress: edge and cloud pods can reach the internet through their respective NAT gateways
