# 02-Setup Implementation Considerations

This document captures design decisions, open questions, and implementation considerations for the cloud-edge automatic provisioning setup. Reference this during deployment planning and implementation.

## Table of Contents

- [Bootstrap Trust Problem](#bootstrap-trust-problem)
- [iPXE Crypto Limitations](#ipxe-crypto-limitations)
- [Tailscale Auth Key Lifecycle](#tailscale-auth-key-lifecycle)
- [Install to Disk vs Persistent PXE Boot](#install-to-disk-vs-persistent-pxe-boot)
- [Cluster Join Automation](#cluster-join-automation)
- [Network Considerations for NFV](#network-considerations-for-nfv)
- [Multi-Edge Site Handling](#multi-edge-site-handling)
- [Failure Modes](#failure-modes)
- [Component Implementation Status](#component-implementation-status)
- [Suggested Implementation Order](#suggested-implementation-order)

---

## Bootstrap Trust Problem

The core challenge is establishing trust with a brand new edge node that has no OS, no credentials, and limited iPXE crypto capabilities. The node must authenticate to the cloud iPXE server and receive sensitive material (cluster CA, bootstrap token, Tailscale auth key).

### Options

| Approach | Pros | Cons |
|----------|------|------|
| Pre-shared MAC/UUID mapping | Simple, no edge-side config beyond DHCP | Hardware IDs are spoofable; requires cloud-side inventory |
| Mutual TLS with embedded client certs | Strong authentication | iPXE TLS support is limited; embedding certs in edge DHCP config is fragile |
| One-time enrollment tokens | Short-lived, single-use; minimal edge config | Requires token generation workflow; token must be provisioned at edge DHCP before boot |
| DHCP option with pre-shared secret | Simple to configure | Secret is static and visible on the edge network |

### Decision Criteria

- How many edge sites? Manual token generation may be acceptable for a few sites but not at scale.
- Who controls the edge DHCP server? If it is a third-party managed device, embedding certs or tokens in DHCP options may be difficult.
- Threat model: Is the edge L2 network trusted? If not, MAC/UUID mapping alone is insufficient.

### Open Questions

- [ ] Which node identity mechanism to use?
- [ ] How to handle re-enrollment (node replacement, hardware change)?
- [ ] Should the cloud maintain a node inventory/allowlist?

---

## iPXE Crypto Limitations

iPXE has limited and build-dependent TLS support. This directly impacts the security of the boot chain.

### Key Constraints

- Not all iPXE builds support TLS. A custom iPXE binary may be needed with TLS and your CA certificate embedded at build time.
- Supported cipher suites vary by build. Modern ciphers (TLS 1.3) may not be available.
- Certificate chain validation can be unreliable. Embedding the root CA directly is more robust than relying on chain traversal.
- Client certificate authentication (mTLS) is supported but adds build and configuration complexity.

### Recommendations

- Build a custom iPXE binary with the cloud CA cert embedded (`TRUST=ca.crt`).
- Test the exact TLS version and cipher negotiation between your iPXE build and the cloud iPXE server.
- Consider an additional authentication layer on top of HTTPS (e.g., a one-time token in the iPXE request URL or HTTP header) rather than relying solely on iPXE TLS.
- The `quay.io/poseidon/dnsmasq` image used in 01-setup includes stock iPXE binaries. For 02-setup, a custom iPXE binary with your CA cert will likely be required.

### Open Questions

- [ ] Is a custom iPXE build acceptable, or must stock iPXE binaries be used?
- [ ] What is the minimum acceptable TLS version for the boot chain?

---

## Tailscale Auth Key Lifecycle

Tailscale pre-auth keys are required for the edge node to join the Tailscale network automatically. These keys have expiration and usage constraints.

### Key Constraints

- Default expiration: 90 days (configurable).
- Keys can be single-use or reusable. Reusable keys are convenient but a larger security risk if leaked.
- The auth key is embedded in the Talos machine config. If the key expires before the node boots, provisioning fails silently.
- Revoking a key does not disconnect already-joined nodes, but prevents new nodes from using it.

### Options

| Approach | Pros | Cons |
|----------|------|------|
| Static pre-auth key (reusable) | Simple; one key for all nodes | Security risk if leaked; expires eventually |
| Static pre-auth key (single-use) | Limits exposure per node | Must generate one per node; manual overhead |
| Dynamic key via Tailscale API | Keys generated at config-serve time; short-lived | Requires Tailscale OAuth client; adds cloud service dependency |
| Tailscale OAuth client + machine config server | Fully automated; keys generated on demand with minimal TTL | Most complex; requires Tailscale API integration in config server |

### Recommendations

- For initial development/testing: use a reusable pre-auth key with a reasonable expiration.
- For production: integrate Tailscale OAuth API into the machine config server to generate single-use, short-lived keys dynamically per node request.
- Monitor key expiration. Set up alerts before keys expire.

### Open Questions

- [ ] Which Tailscale plan is in use? (API access varies by plan)
- [ ] Is the machine config server the right place to generate Tailscale keys, or should it be a separate service?
- [ ] How to handle Tailscale key rotation for already-joined nodes?

---

## Install to Disk vs Persistent PXE Boot

Whether the edge node installs Talos to local disk or PXE boots every time has significant operational implications.

### Comparison

| Aspect | PXE-Only (No Install) | Install to Disk |
|--------|----------------------|-----------------|
| Cloud dependency on reboot | Yes - cannot restart without cloud | No - boots from local disk |
| Upgrade mechanism | Serve new image from iPXE server | Talos rolling upgrade via `talosctl` |
| Edge autonomy | None - fully dependent on cloud | High - survives cloud outages |
| Configuration drift | Impossible - always fresh from cloud | Possible - local state diverges |
| Boot time | Slower - downloads image every boot | Faster - local disk read |
| Disk requirement | None (or minimal for ephemeral state) | Requires local storage |

### Recommendations

- **Install to disk** is strongly recommended for edge deployments. Cloud dependency on every reboot is a critical reliability risk.
- Use the initial PXE boot to install Talos to the local disk, then subsequent boots are independent.
- Manage upgrades via `talosctl upgrade` over the Tailscale network.
- Consider a fallback PXE boot option for recovery scenarios (e.g., corrupted local disk).

### Open Questions

- [ ] Is local disk available on all target edge hardware?
- [ ] What is the upgrade strategy? (Talos rolling upgrade vs. re-PXE)
- [ ] Should the PXE server serve an installer image or a live boot image?

---

## Cluster Join Automation

Talos requires the control plane to approve new members joining the cluster. This must be automated for edge provisioning.

### Key Considerations

- Machine configs must contain the correct cluster secrets (CA, bootstrap token, cluster endpoint) for the node to join.
- The cloud machine config server must generate configs that match the target cluster.
- The control plane API server must be reachable from the edge node. With Tailscale, this means the API server must listen on or be accessible via the Tailscale interface.
- `talosctl` operations (upgrade, reset, etc.) will traverse Tailscale. Latency and reliability of the Tailscale connection directly affect cluster management.

### Recommendations

- Pre-generate machine configs with correct cluster secrets on the cloud config server.
- Ensure the Talos API and Kubernetes API server are accessible over Tailscale IP addresses.
- Test `talosctl` operations over Tailscale under realistic latency conditions.
- Consider timeout adjustments for etcd join operations if Tailscale latency is high.

### Open Questions

- [ ] Should the cloud control plane use Tailscale IP as the advertised endpoint, or a separate mechanism?
- [ ] How to handle etcd learner promotion over a high-latency link?
- [ ] What happens if the edge node joins but the Tailscale link is intermittent?

---

## Network Considerations for NFV

Since this is a kube-nfv deployment, network performance and architecture are critical.

### Tailscale Overhead

- WireGuard encapsulation adds ~60 bytes of overhead per packet, reducing effective MTU.
- Default MTU of 1500 becomes ~1440 effective. This can cause fragmentation or require path MTU discovery.
- For NFV workloads with high throughput requirements, this overhead may be significant.

### Separation of Control and Data Plane

- **Control plane over Tailscale**: Kubernetes API, kubelet, etcd, `talosctl` — acceptable latency and overhead.
- **Data plane at the edge**: NFV workloads should use local edge networking, not Tailscale. VNF traffic should not traverse the Tailscale tunnel.
- Consider using Multus or similar CNI to attach VNFs to local edge networks independently of the cluster overlay.

### CIDR Conflicts

- Cloud and edge pod/service CIDRs must not overlap if traffic is routed over Tailscale.
- Tailscale subnet routing can conflict with Kubernetes service CIDRs. Plan address spaces carefully.
- If Tailscale 4via6 or subnet routing is used, verify no overlap with Kubernetes internal ranges.

### Open Questions

- [ ] What MTU should be configured on the edge nodes?
- [ ] Should NFV data plane traffic be completely isolated from Tailscale?
- [ ] How to handle pod CIDR allocation across cloud and edge to avoid conflicts?

---

## Multi-Edge Site Handling

If multiple edge sites are planned, the provisioning system must handle site differentiation.

### Key Considerations

- **Node-to-site mapping**: The iPXE server must know which edge site a booting node belongs to. This could be based on source IP, DHCP relay agent info, or an identifier in the iPXE request.
- **Single cluster vs. multi-cluster**: All edge nodes could join one cluster (simpler management, harder networking) or separate clusters per site (isolated, more operational overhead).
- **Node labels and taints**: Edge nodes should be automatically labeled (e.g., `topology.kubernetes.io/zone=edge-site-1`) and tainted to control workload scheduling.
- **Config per site**: Each site may have different local network configurations, storage, or hardware. The machine config server must template these differences.

### Open Questions

- [ ] How many edge sites are planned?
- [ ] Single cluster or per-site clusters?
- [ ] How to identify edge site from the iPXE request?

---

## Failure Modes

### During Initial Provisioning

| Failure | Impact | Mitigation |
|---------|--------|------------|
| Cloud iPXE server unreachable | Node cannot boot | Retry loop in iPXE; alert on cloud-side |
| Machine config server unreachable | Node boots kernel but cannot configure | Talos retries config fetch; alert on cloud-side |
| Tailscale auth key expired | Node boots but cannot join Tailscale network | Monitor key expiry; dynamic key generation |
| Cluster secrets mismatch | Node cannot join cluster | Validate configs before serving; version control secrets |
| Edge DHCP server failure | Node gets no IP, no PXE | DHCP redundancy at edge site |

### During Operation

| Failure | Impact | Mitigation |
|---------|--------|------------|
| Tailscale link down | Edge node partitioned from cluster | Tailscale DERP relay fallback; local workloads continue if installed to disk |
| Cloud control plane down | No management of edge nodes | Edge workloads continue independently if installed to disk |
| Edge node disk failure | Node cannot reboot (if installed to disk) | Fallback to PXE re-provisioning |
| Tailscale DERP relay congestion | Degraded management performance | Direct WireGuard connections preferred; monitor DERP usage |

### Split-Brain Considerations

- If an edge node loses Tailscale connectivity after joining the cluster, Kubernetes will mark it as `NotReady` after the node lease timeout.
- Pods on the partitioned node will be evicted (if using deployment controllers) and rescheduled on cloud nodes.
- Stateful workloads on the edge node may cause data inconsistency if they continue running while partitioned.
- Consider `tolerations` and `nodeAffinity` rules to keep edge-specific workloads on edge nodes even during brief partitions.

---

## Component Implementation Status

| Component | Status | Notes |
|-----------|--------|-------|
| Talos image with Tailscale extension | Not built | Extend 01-setup imager with Tailscale system extension |
| Cloud iPXE server | Not built | Matchbox with auth proxy, or custom service |
| Machine config server | Not built | HTTP server generating per-node Talos configs |
| Tailscale key provisioning | Not addressed | Manual keys for dev; API automation for production |
| Edge DHCP config template | Not provided | dnsmasq config pointing to cloud iPXE endpoint |
| TLS PKI for cloud endpoints | Not addressed | CA + server certs for iPXE and config servers |
| Node identity/enrollment | Not decided | See [Bootstrap Trust Problem](#bootstrap-trust-problem) |
| Install-to-disk strategy | Not decided | See [Install to Disk vs Persistent PXE Boot](#install-to-disk-vs-persistent-pxe-boot) |
| Observability | Not addressed | Remote logging/metrics collection over Tailscale |

---

## Suggested Implementation Order

1. **Talos image with Tailscale extension** — Extend the 01-setup imager profiles to include the Tailscale system extension. Verify the image boots and Tailscale connects in a local QEMU test.

2. **Tailscale network setup** — Create the Tailscale network (tailnet), generate initial auth keys, test node-to-node connectivity between cloud and a test edge node.

3. **Cloud iPXE and machine config servers** — Deploy Matchbox (or equivalent) with authentication. Implement the machine config server that generates per-node Talos configs with embedded Tailscale keys and cluster join parameters.

4. **Edge DHCP configuration** — Create the dnsmasq config template for edge sites with iPXE options pointing to the cloud endpoint. Test with a local QEMU edge node.

5. **End-to-end PXE boot test** — Boot an edge QEMU node through the full flow: DHCP, iPXE, Talos boot, Tailscale connect, cluster join.

6. **Install-to-disk and upgrade path** — Configure the Talos installer to write to local disk on first boot. Test `talosctl upgrade` over Tailscale.

7. **Security hardening** — Implement chosen node identity mechanism, switch to dynamic Tailscale key generation, enforce mTLS where possible.

8. **Observability** — Set up remote logging and monitoring for edge nodes over Tailscale.
