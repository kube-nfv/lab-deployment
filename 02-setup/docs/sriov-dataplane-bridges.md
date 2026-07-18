# SR-IOV Dataplane Bridges — Architecture & Working Notes

## Purpose

Reference/context document for working with the **SR-IOV hardware-offloaded OVS
bridges** in this lab (the `br-mx5p*` bridges), as opposed to the kube-OVN
overlay (`br-int`). Intended as grounding context for future debugging work on
these bridges. It records the *architecture and invariants*; specific runtime
values (PCI addresses, representor indices, pod names) are **examples only** and
change per allocation — see [Stable vs ephemeral](#stable-vs-ephemeral-facts).

## Cluster access

```
export KUBECONFIG=~/Dev/github.com/kube-nfv/lab-deployment/02-setup/_out/talos/configs/kubeconfig
```

The Mellanox (mlx5, switchdev) NIC lives on the worker node
`setup02-x11spl-f-worker-1`. OVS runs in the `ovs-ovn-*` DaemonSet pods in
`kube-system` (container `openvswitch`); OVN northbound is `ovn-central`.

---

## 1. Two-tier network design

This node deliberately runs **two separate OVS worlds** that are NOT wired
together:

| Tier | Bridge(s) | Datapath | Role |
|---|---|---|---|
| Overlay | `br-int` | software (geneve tunnels), OVN pipeline, `fail_mode=secure` | kube-OVN primary CNI: pod/default + VM mgmt/bridge NICs. HW offload not used here by design. |
| SR-IOV dataplane | `br-mx5p0`, `br-mx5p1` (one per PF) | hardware-offloaded (switchdev / TC-flower), `actions=NORMAL` (MAC learning) | VNF dataplane VFs. Line-rate, offloaded. |

Rationale: keep default/control traffic on OVN (features, no offload cost),
keep VNF dataplane on offloaded bridges (throughput, no OVN pipeline overhead).
See also `~/Dev/github.com/kube-nfv/kube-vim/docs/sriov-networks.md`.

---

## 2. The dataplane bridges

Stable facts (per PF):

- One OVS bridge per PF: `br-mx5p0` <-> PF `ens9f0np0`, `br-mx5p1` <-> PF `ens9f1np1`.
- Each bridge holds: the **PF uplink** port + one **VF representor** port per
  attached VF + the internal bridge port.
- Single forwarding rule: `table=0, priority=0, actions=NORMAL` (pure L2 MAC
  learning). No OpenFlow controller, no `fail_mode` -> standalone bridges.
- OVS global `other_config:hw-offload="true"`.

Enumerate:
```
kubectl exec -n kube-system <ovs-ovn-pod> -c openvswitch -- ovs-vsctl show
kubectl exec -n kube-system <ovs-ovn-pod> -c openvswitch -- ovs-ofctl dump-flows br-mx5p0
```

---

## 3. Dataplane path (per SR-IOV VF)

```
guest (real mlx5 VF driver)
  └─ VF (PCI passthrough)  --->  NIC eSwitch  --->  [TC-flower offloaded]  --->  VF representor (e.g. ens9f0np0_4)
                                                                                    |
                                                                     br-mx5p0: actions=NORMAL (MAC learning)
                                                                                    |
                                                                              PF uplink ens9f0np0  --->  wire
```

Key point: the representor is the host-side handle for a VF's eSwitch port. A VF
only forwards if its representor is a port on an OVS bridge — OVS installs
datapath flows, the NIC offloads them via TC-flower. Traffic goes **through**
OVS/the eSwitch; it does **not** bypass the vSwitch.

---

## 4. Control path — who wires what

Four independent actors, keyed off one identifier: the **VF PCI address**.

1. **sriov-network-operator** — puts PFs in `switchdev` (`eSwitchMode: switchdev`),
   creates VFs, binds them to `vfio-pci` (or `netdevice`), and its device plugin
   advertises them as k8s extended resources.
   - Policies here: `mlx-pf0-netdev`, `mlx-pf0-vfio`, `mlx-pf1-netdev`, `mlx-pf1-vfio`.
   - Resources: `openshift.io/mlx_vf_pf0_vfio`, `openshift.io/mlx_vf_pf1_vfio`
     (+ netdev variants). Verify actual names:
     `kubectl get node <node> -o json | jq '.status.allocatable | with_entries(select(.key|test("mlx")))'`
   - Talos specifics: see `sriov-operator-talos.md` in this dir.

2. **kube-OVN ProviderNetwork** — creates the per-PF bridge, moves the PF uplink
   onto it, enables `hw-offload`, and registers an OVS **bridge mapping**.
   - CRs: `providernetwork.kubeovn.io/mx5p0` (uplink `ens9f0np0`),
     `.../mx5p1` (uplink `ens9f1np1`).
   - `ovs-vsctl get Open_vSwitch . external_ids:ovn-bridge-mappings`
     -> `"mx5p0:br-mx5p0,mx5p1:br-mx5p1"`.
   - **This is what provisions the bridges.** ovs-cni never creates them.

3. **ovs-cni** (`~/Dev/github.com/kube-nfv/ovs-cni`, fork) — attaches the VF
   representor to the correct bridge. For `vfio-pci` VFs it runs in *userspace
   mode*: it does NOT move a netdev into the VM; it only resolves the
   representor, sets the VF MAC via PF netlink, and adds the representor as an
   OVS port (with the access VLAN / trunk). Resolution chain, all from the VF
   PCI:
   ```
   VF PCI --GetUplinkRepresentor--> PF (physfn)
          --GetVfIndexByPciAddress-> VF index
          --GetVfRepresentor------> representor netdev  (added to bridge)
   VF PCI --GetUplinkRepresentor--> PF --FindBridgeByInterface--> bridge name
   ```
   The NAD carries **no bridge name** — the fork auto-discovers it from the PF
   (upstream ovs-cni requires an explicit bridge; this fork adds
   `GetBridgeUplinkNameByDeviceID` + bond-member fallback). Requires the PF to
   already be a bridge port (guaranteed by the ProviderNetwork above).

4. **KubeVirt** — the VMI uses the `sriov` interface binding. virt-launcher
   requests the VF resource; KubeVirt reads the VF PCI from the Multus
   `network-status` `device-info` and passes the VFIO device through to QEMU.
   The guest binds the real mlx5 VF.

5. **kube-vim** (the VIM) — renders each OSM VLD into a Multus NAD
   (`type: ovs`, `resourceName: <pool>`, `vlan: <segmentationId>`) in the
   `kube-vim` namespace and emits the KubeVirt `interface.sriov` binding. This
   is where per-VLD **VLAN context** is expressed — not via any SDN controller.

---

## 5. Isolation model (IMPORTANT)

The dataplane bridges are **isolated from the OVN overlay**, but the isolation
is **convention-enforced, not a hard barrier**. Understand this before touching
kube-OVN VLAN/subnet objects.

- kube-OVN *knows* these bridges (they are ProviderNetworks, present in
  `ovn-bridge-mappings`). **Knowing is not connecting.**
- Isolation holds **as long as no OVN logical switch has a localnet port on
  these providers** — i.e. no kube-OVN `Vlan` + provider-bound `Subnet`
  references `mx5p0`/`mx5p1`. Currently: no `Vlan` CRs, no such subnets, no
  localnet ports, no patch ports. Verify:
  ```
  kubectl get vlan.kubeovn.io
  kubectl get subnet -o custom-columns=NAME:.metadata.name,PROVIDER:.spec.provider,VLAN:.spec.vlan
  kubectl exec -n kube-system deploy/ovn-central -- ovn-nbctl find Logical_Switch_Port type=localnet
  kubectl exec -n kube-system <ovs-ovn-pod> -c openvswitch -- ovs-vsctl --columns=name,type find interface type=patch
  ```
  All should be empty / show no link into `br-mx5p*`.
- **Failure mode:** creating a kube-OVN `Vlan` + `Subnet` bound to `mx5p0`/`mx5p1`
  makes OVN add a **localnet patch** between `br-int` and the provider bridge.
  That merges the SR-IOV L2 domain into the overlay **and** pushes the OVN
  pipeline onto the offloaded bridge (much of which won't offload, so it silently
  falls back to software). **Do not do this on the SR-IOV providers.**
- The only intended attachments on these bridges are: the PF uplink + VF
  representors. Worth guarding in CI/policy.

Cross-node dataplane connectivity rides the **physical wire between PFs** (the
upstream ToR / VLAN trunk), not OVN tunnels. VLAN segmentation between VLDs is
by access VLAN on the representor port (`segmentationId`).

---

## 6. Adding custom flows (beyond MAC learning)

First question: **must the flow stay hardware-offloaded?** Only what OVS can
lower to TC-flower runs in HW.

- Offloadable: L2/L3/VLAN match + `output`/`drop`/`redirect`/`mirror`/
  `vlan push,pop,mod`/mac-rewrite; VXLAN/Geneve encap-decap.
- Conditional: conntrack/stateful/NAT only on ConnectX-6 Dx+ and constrained —
  verify on the actual NIC.
- Not offloadable: complex stateful/L4/LB. These do NOT belong on these bridges
  (put them in the VNF or on `br-int`/OVN instead).

Two mechanisms:

- **Bridge-wide forwarding logic** -> explicit OpenFlow flows with a `NORMAL`
  fallback on the standalone bridge:
  ```
  ovs-ofctl add-flow br-mx5p0 "priority=100,<match>,actions=<offloadable>"
  ovs-ofctl add-flow br-mx5p0 "priority=0,actions=NORMAL"
  ```
- **Per-VF policy (ACL/drop/steer one VF)** -> `tc filter` directly on the
  representor (the native offload interface OVS itself uses):
  ```
  tc filter add dev ens9f0np0_4 ingress protocol ip flower <match> action drop
  ```

Always verify offload:
```
ovs-appctl dpctl/dump-flows type=offloaded | grep offloaded:yes
```

### Management constraints (do-nots)

- **Flows are not persistent** — OVS flows vanish on `ovs-vswitchd` restart; tc
  rules vanish on VF/pod recreation. Use an **idempotent reconciler**
  (DaemonSet, or a chained CNI plugin after ovs-cni for per-VF tc rules).
- **Never** point an external OpenFlow controller at `br-mx5p*` or set
  `fail_mode=secure` — that removes the `NORMAL` base the dataplane relies on and
  conflicts with kube-OVN's ownership of the bridge. *Add* flows; do not take the
  bridge over.
- If the behavior should be per-VLD/OSM-driven, render it from VIM intent
  (kube-vim), same pattern as the VLAN rendering — not as ad-hoc scripts.

---

## 7. Debug command reference

```
# --- bridges & ports ---
ovs-vsctl show
ovs-vsctl list-ports br-mx5p0
ovs-ofctl dump-flows br-mx5p0                       # expect priority=0 actions=NORMAL

# --- offload status ---
ovs-vsctl get Open_vSwitch . other_config:hw-offload      # "true"
ovs-appctl dpctl/dump-flows type=offloaded | grep -c offloaded:yes
ovs-appctl dpctl/dump-flows -m | grep <rep-or-pf>

# --- provider network / mappings / isolation ---
kubectl get provider-network,vlan.kubeovn.io
ovs-vsctl get Open_vSwitch . external_ids:ovn-bridge-mappings
kubectl exec -n kube-system deploy/ovn-central -- ovn-nbctl find Logical_Switch_Port type=localnet

# --- VF / representor mapping (on the node) ---
cat /sys/class/net/<pf>/phys_switch_id
# VF PCI -> PF: /sys/bus/pci/devices/<vf-pci>/physfn

# --- a VM's realized VFs ---
kubectl get pod -n kube-vim <virt-launcher-pod> \
  -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' | jq
kubectl get vmi -n kube-vim <vm> -o jsonpath='{.spec.domain.devices.interfaces}' | jq
```

---

## 8. Stable vs ephemeral facts

**Stable** (safe to rely on as context):

- Two-tier design; `br-int` = OVN overlay, `br-mx5p0/1` = offloaded SR-IOV.
- One bridge per PF; PFs `ens9f0np0` / `ens9f1np1`; providers `mx5p0` / `mx5p1`;
  bridge-mappings `mx5p0:br-mx5p0,mx5p1:br-mx5p1`.
- Bridges are standalone (`NORMAL`, no controller); `hw-offload=true`.
- Provisioned by kube-OVN ProviderNetwork; representors attached by ovs-cni;
  VFs from sriov-network-operator; passthrough by KubeVirt `sriov` binding.
- Isolation is convention-enforced (no `Vlan`/provider-`Subnet` on these providers).
- Resource pool naming pattern `openshift.io/mlx_vf_pf{0,1}_{vfio,netdev}`.

**Ephemeral** (examples in this doc — re-query, never assume):

- VF PCI addresses (e.g. `0000:b3:00.6`), representor indices (`ens9f0np0_4`,
  `_7`), MAC addresses, pod/VM names, packet counters, `network-status` output.

---

## Invariants (quick checklist for any change)

1. `br-mx5p*` stay standalone `NORMAL` bridges — no controller, no `fail_mode=secure`.
2. No kube-OVN `Vlan`/`Subnet` bound to `mx5p0`/`mx5p1` (would break isolation + offload).
3. Every added flow/tc rule is TC-flower-offloadable and verified `offloaded:yes`.
4. Custom flows applied by an idempotent reconciler, not hand-added.
5. PF uplink must remain a port on its bridge (ovs-cni auto-discovery depends on it).
