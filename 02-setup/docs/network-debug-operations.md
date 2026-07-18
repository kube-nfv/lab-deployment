# Network Debug & Operations Guide

Operational runbook for **debugging, tracing and monitoring** the dataplane on
this lab. Written to be usable by a human operator or an AI agent with no prior
context. Companion to:

- `sriov-dataplane-bridges.md` — architecture & invariants of the `br-mx5p*` bridges.
- `sriov-operator-talos.md` — why switchdev/udev is wired the way it is on Talos.
- `~/Dev/github.com/kube-nfv/kube-vim/docs/sriov-networks.md` — how kube-vim renders VLDs into NADs.
- `~/Dev/github.com/kube-nfv/kube-vim/docs/management-network.md` — the shared OVN mgmt network.

> Runtime values in this doc (PCI addresses, representor indices, MACs, pod
> names, port numbers, `phys_switch_id`) are **examples from one allocation** —
> re-query them, never assume. See [§10 worked example](#10-worked-example-from-a-live-allocation).

---

## 0. Mental model (read first)

Every VM on this cluster has interfaces in **two disjoint network worlds** that
are never wired together. You must know which world an interface lives in before
you pick a debug tool.

| World | Bridge | Datapath | Carries | Debug approach |
|---|---|---|---|---|
| **Overlay** (kube-OVN) | `br-int` | software, geneve tunnels, OVN pipeline | VM `default` NIC (`ovn-default`, masquerade) + `osm-mgmt` mgmt NIC (bridge binding) | host-side `tcpdump`/counters work normally; OVN tooling (`ovn-nbctl`, `ovn-trace`) |
| **SR-IOV dataplane** | `br-mx5p0` (PF0 `ens9f0np0`), `br-mx5p1` (PF1 `ens9f1np1`) | **hardware-offloaded** (switchdev / TC-flower) | VNF dataplane VFs (VFIO passthrough to guest) | host `tcpdump` is **blind** (see §6); use HW counters + guest-side capture |

Everything dataplane lives on **one node**: `setup02-x11spl-f-worker-1` (the
mlx5 switchdev NIC). The other nodes are overlay-only.

---

## 1. Access methods

### 1a. Primary: the `ovs-ovn` DaemonSet pod (use this by default)

The kube-OVN `ovs-ovn-*` pod on the dataplane node is already a complete network
debug toolbox and needs **no extra deployment**. Verified present:
`ovs-vsctl ovs-ofctl ovs-appctl ovs-dpctl tcpdump ip tc ethtool bridge conntrack ping`.
It runs `hostNetwork: true` + `hostPID: true`, sees **every** host netdev
(PF, all VF representors `ens9fXnpX_N`, netdev VFs `ens9fXvNN`, `br-*`, geneve),
and can read `/sys`. OVS state lives in the `openvswitch` container.

Set this once per shell:

```bash
export KUBECONFIG=~/Dev/github.com/kube-nfv/lab-deployment/02-setup/_out/talos/configs/kubeconfig

# The ovs-ovn pod on the dataplane node:
OVS=$(kubectl get pod -n kube-system -l app=ovs -o wide \
      --field-selector spec.nodeName=setup02-x11spl-f-worker-1 \
      -o jsonpath='{.items[0].metadata.name}')
echo "$OVS"

# Helper: run a command in the OVS container
ovs() { kubectl exec -n kube-system "$OVS" -c openvswitch -- "$@"; }

ovs ovs-vsctl show          # smoke test
```

All `ovs ...` examples below assume this helper.

### 1b. Fallback: a turnkey privileged debug pod

Use only if you need a clean toolbox without touching the CNI DaemonSet, or tools
the OVS pod lacks. It pins to the dataplane node, shares host net/pid, and mounts
`/sys` + the OVS runtime socket so `ovs-*`/`tcpdump`/`ethtool` all work.

```yaml
# netdebug.yaml — kubectl apply -f netdebug.yaml ; kubectl exec -it -n kube-system netdebug -- bash
apiVersion: v1
kind: Pod
metadata:
  name: netdebug
  namespace: kube-system          # kube-system tolerates privileged PSA on this cluster
spec:
  nodeName: setup02-x11spl-f-worker-1
  hostNetwork: true
  hostPID: true
  hostIPC: true
  restartPolicy: Never
  tolerations:
    - operator: Exists            # tolerate any node taints
  containers:
    - name: netdebug
      image: nicolaka/netshoot:latest   # ip, tc, ethtool, tcpdump, bridge, conntrack, iperf3, nmap...
      command: ["sleep", "infinity"]
      securityContext:
        privileged: true
      volumeMounts:
        - { name: sys,   mountPath: /sys }
        - { name: ovsrun, mountPath: /run/openvswitch }   # ovs-vsctl/ofctl talk to the db socket here
  volumes:
    - { name: sys,   hostPath: { path: /sys } }
    - { name: ovsrun, hostPath: { path: /run/openvswitch } }
```

Notes:
- `ovs-vsctl`/`ovs-ofctl` in this pod control the **same** OVS (shared socket).
- On Talos there is no host package manager; everything must be in the image.
  `netshoot` covers the common set. Delete the pod when done.
- For guest/VM-internal debugging use the **`kubevirt-vm-access` skill** instead
  (see §8) — this pod cannot enter the guest (VF is VFIO-passthrough, not a host netdev).

### 1c. VM guest access

Use the **`kubevirt-vm-access` skill** (`virtctl ssh` / console / virt-launcher
exec). Covered in §8.

---

## 2. The correlation problem (KubeVirt port ⇄ PCI ⇄ representor ⇄ bridge)

This is the crux. A VM interface is named one way in the KubeVirt spec, another
way by Multus, and maps to a *different kind of host object* depending on its
binding. Here is the full chain and how to walk it in both directions.

### 2a. Layer map

```
OSM VLD  ──kube-vim──►  NetworkAttachmentDefinition (kube-vim ns)
                           │
   KubeVirt VMI .spec.domain.devices.interfaces[].name
   + .spec.networks[].multus.networkName ──► which NAD
                           │
   Multus writes pod annotation:
   k8s.v1.cni.cncf.io/network-status  ──► per-interface realized detail
                           │
        ┌──────────────────┴───────────────────────────┐
   binding = bridge/masquerade                    binding = sriov
   (overlay: default + mgmt)                      (dataplane VLs)
        │                                               │
   network-status .interface = podXXXX            network-status .device-info.pci.pci-address
   (a netdev INSIDE virt-launcher,                (a VF; NOT in the pod — VFIO-passthrough
    veth peer <hash>_h on br-int)                  straight to QEMU/guest)
        │                                               │
   correlate via br-int external_ids              correlate via /sys: PCI→PF→virtfn→representor
   (§2c)                                           (§2d)
```

Key consequence: **SR-IOV VFs do not appear as netdevs inside the virt-launcher
pod.** Only the overlay/mgmt interfaces do. Confirmed: a dataplane VM's
`compute` container shows only `k6t-eth0/tap0` (default) and
`k6t-<id>/tap<id>/pod<id>` (mgmt). The VLs are in the guest, reached via the VF
PCI, not the pod netns.

### 2b. Start here — dump one VM's realized interfaces

```bash
VM=vcpe-demo-router-vcpe-router-vm-0
POD=$(kubectl get pod -n kube-vim -l vm.kubevirt.io/name=$VM -o jsonpath='{.items[0].metadata.name}')

# Realized interfaces: name, in-pod iface, MAC, and VF PCI (null for overlay NICs)
kubectl get pod -n kube-vim "$POD" \
  -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' \
  | jq -c '.[] | {net:.name, iface:.interface, mac:.mac, pci:.["device-info"].pci."pci-address"}'
```

- Entries with `pci: null` → overlay/mgmt (bridge/masquerade binding) → §2c.
- Entries with a `pci` value → SR-IOV VL → §2d.

Map the KubeVirt interface *name* to its NAD:

```bash
kubectl get vmi -n kube-vim "$VM" -o json \
  | jq -r '.spec.networks[] | "\(.name) -> \(.multus.networkName // "pod-network")"'
```

### 2c. Overlay interface ⇄ pod (via OVS `external_ids`)

kube-OVN stamps every `br-int` port with the pod identity. **Forward** (port →
who owns it):

```bash
ovs ovs-vsctl --columns=external_ids,mac_in_use list interface <portname>
# e.g. external_ids : {iface-id=<vm>.kube-vim.osm-mgmt-subnet-0-netattach.kube-vim.ovn,
#                      ip="10.240.0.27", pod_name=<vm>, pod_namespace=kube-vim, ...}
```

**Reverse** (VM → its br-int ports, with IPs):

```bash
ovs ovs-vsctl --columns=name,external_ids find interface \
  external_ids:pod_name=vcpe-demo-router-vcpe-router-vm-0
```

The `iface-id` suffix tells you which network the port is (`...osm-mgmt...` = mgmt,
the bare `<vm>.kube-vim` = default `ovn-default`).

### 2d. SR-IOV VL ⇄ representor ⇄ bridge (via `/sys`)

Given a VF PCI from §2b (e.g. `0000:b3:00.4`), walk `/sys` inside the OVS/debug pod:

```bash
VF=0000:b3:00.4

# 1) VF -> PF
PF=$(basename $(ovs readlink /sys/bus/pci/devices/$VF/physfn))   # e.g. 0000:b3:00.0
ovs ls /sys/bus/pci/devices/$PF/net                              # PF netdev, e.g. ens9f0np0

# 2) VF -> VF index (which virtfnN of the PF points at this VF)
ovs sh -c "ls -l /sys/bus/pci/devices/$PF/virtfn* | grep ${VF#0000:}"
#   .../virtfn2 -> ../0000:b3:00.4     => VF index 2

# 3) VF index -> representor netdev (phys_port_name = pf<P>vf<index>)
ovs sh -c 'grep -H . /sys/class/net/ens9f0np0_*/phys_port_name | grep ":pf0vf2$"'
#   /sys/class/net/ens9f0np0_2/phys_port_name:pf0vf2   => representor ens9f0np0_2

# 4) representor -> bridge
ovs ovs-vsctl port-to-br ens9f0np0_2                             # => br-mx5p0
```

Invariant that makes this reliable on this NIC: **representor index == VF index
== `virtfnN` == `pf<P>vf<N>`** (mlx5 + the Talos udev rename rule). So
`0000:b3:00.4` (virtfn2 of PF0) is always `ens9f0np0_2` on `br-mx5p0`.

**Reverse** (representor → which VM/VL): a representor `ens9f0np0_2` → VF index 2
→ `PF/virtfn2` → VF PCI → find it in a VM's `network-status`:

```bash
REP=ens9f0np0_2
PF=ens9f0np0; IDX=${REP##*_}
VFPCI=$(basename $(ovs readlink /sys/class/net/$PF/device/virtfn$IDX))
# then search VMs for that PCI:
for p in $(kubectl get pod -n kube-vim -o name | grep virt-launcher); do
  kubectl get $p -n kube-vim -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' \
    | jq -e --arg pci "$VFPCI" '.[] | select(.["device-info"].pci."pci-address"==$pci)' >/dev/null \
    && echo "$p owns $VFPCI ($REP)"
done
```

The MAC on the representor's OVS flows also identifies the VL: kube-vim renders a
deterministic MAC per VL (e.g. `02:<VL>0:00:00:00:<host>`), so
`ovs-appctl dpctl/dump-flows -m | grep <rep>` shows the src/dst MACs of the segment.

---

## 3. OVS topology & health cheatsheet

```bash
# --- what bridges/ports exist ---
ovs ovs-vsctl show                                   # full picture
ovs ovs-vsctl list-br                                # br-int, br-mx5p0, br-mx5p1
ovs ovs-vsctl list-ports br-mx5p0                    # uplink + representors on PF0

# --- provider wiring / offload global switch ---
ovs ovs-vsctl get Open_vSwitch . external_ids:ovn-bridge-mappings   # "mx5p0:br-mx5p0,mx5p1:br-mx5p1"
ovs ovs-vsctl get Open_vSwitch . other_config:hw-offload            # must be "true"

# --- forwarding logic on a dataplane bridge ---
ovs ovs-ofctl dump-flows br-mx5p0                    # expect exactly: priority=0 actions=NORMAL
ovs ovs-ofctl show br-mx5p0                          # OpenFlow port numbers <-> names

# --- MAC learning table (who has the switch learned, on which port) ---
ovs ovs-appctl fdb/show br-mx5p0
```

A healthy `br-mx5p*` has **one** flow: `priority=0 actions=NORMAL` (pure L2 MAC
learning, standalone bridge, no controller, no `fail_mode`). Anything else on
these bridges is either an intentional custom flow or a red flag — see
`sriov-dataplane-bridges.md §5-6`.

### Resolving FDB `port` numbers to interfaces

`ovs-appctl fdb/show <br>` prints the learned port as an **OpenFlow port number**,
not a name. Resolve it:

```bash
ovs ovs-ofctl show br-mx5p1 | grep -oE '[0-9]+\([^)]*\)'   # 17(ens9f1np1_3), 1(ens9f1np1) ...
ovs ovs-vsctl find interface ofport=17                      # number -> interface row
ovs ovs-vsctl get interface ens9f1np1_3 ofport             # name   -> number
```

Worked example — an FDB line and what it resolves to:

```
port  VLAN  MAC                Age
  17     0  02:10:00:00:00:01   8        # ofport 17 = ens9f1np1_3 = fw client VF
   1     0  b8:3f:d2:28:2a:a2   1        # ofport 1  = ens9f1np1   = PF1 uplink (the wire)
```

To go one hop further (representor → VF/VM) feed the resolved name into the §2d
`/sys` chain.

Two numbering gotchas:

- This is OVS's **OpenFlow** port space. `ovs-appctl dpctl/dump-flows` (without
  `-m`) prints `in_port(N)` in a **different** (datapath) numbering — resolve
  those with `ovs-appctl dpctl/show` (`port N: <name>`). `dpctl/dump-flows -m`
  prints names directly, so prefer `-m`.
- This is **not** kernel `bridge fdb show`. That command is keyed by device name
  (no port numbers) and, because these representors are OVS ports rather than
  linux-bridge slaves, it does not reflect OVS's forwarding table — always use
  `ovs-appctl fdb/show` here.

---

## 4. "Is traffic actually running?" — counters

Because the dataplane is HW-offloaded, **packet counters are the source of
truth**, not `tcpdump` (§6). Three independent counter views:

```bash
# (A) OVS OpenFlow per-port counters — reads HW counters, includes offloaded traffic
ovs ovs-ofctl dump-ports br-mx5p0                    # rx/tx pkts+bytes per OF port
ovs ovs-ofctl dump-ports br-mx5p0 ens9f0np0_2        # one port (map name->OFport via `dump-flows`/`show`)

# (B) NIC hardware vport counters on a representor — the authoritative VF-side count.
#     vport_* = packets through the eSwitch (offloaded). Non-vport rx/tx = host slowpath only.
ovs sh -c 'ethtool -S ens9f0np0_2 | grep -E "vport_(rx|tx)_(packets|bytes)"'

# (C) uplink PF throughput to the wire
ovs sh -c 'ethtool -S ens9f0np0 | grep -E "^ *(rx|tx)_packets_phy|_bytes_phy"'
```

Watch a counter move (traffic live vs idle):

```bash
ovs sh -c 'for i in 1 2 3; do ethtool -S ens9f0np0_2 | grep vport_rx_packets; sleep 1; done'
```

Interpreting: on a busy VF you will see `vport_rx_packets` in the millions and
climbing while the plain `rx_packets` (host slowpath) stays near-zero — that is
**normal and proves offload is working** (host CPU never touches the packets).

---

## 5. Datapath & offload verification

```bash
# Full datapath flow table WITH offload annotation — the -m flag is REQUIRED.
ovs ovs-appctl dpctl/dump-flows -m | grep -E 'offloaded:|dp:'

# Filter to one representor / VF segment:
ovs sh -c 'ovs-appctl dpctl/dump-flows -m | grep ens9f0np0_2'
```

**Gotcha (important):** the `offloaded:yes, dp:tc` annotation only appears with
`dpctl/dump-flows **-m**`. `ovs-appctl dpctl/dump-flows type=offloaded` (without
`-m`) and plain `dump-flows` print the flows but **omit** the `offloaded:` field,
so a naive `grep offloaded:yes` returns 0 and looks like "offload is broken" when
it isn't. Always use `-m`.

A correctly offloaded dataplane flow looks like:

```
in_port(ens9f1np1_6),eth(src=02:20:..:01,dst=02:20:..:02),eth_type(0x0800),ipv4(...),
   packets:12208412, bytes:5728441284, used:0.470s, offloaded:yes, dp:tc, actions:ens9f1np1_2
```

`offloaded:yes` + `dp:tc` + a moving `packets:` counter + small `used:` = hardware
fast path, actively forwarding. If you instead see `dp:ovs` / no `offloaded:yes`
on a `br-mx5p*` flow, it fell back to software — check `hw-offload=true` and that
the PF is in switchdev (`ovs sh -c 'devlink dev eswitch show pci/<PF-pci>'` or the
sriov node state).

---

## 6. Capturing packets (tcpdump) — and the switchdev blind spot

**Overlay interfaces (`br-int`, `ovn0`, veth `*_h`, geneve):** normal software
datapath — `tcpdump` works as expected.

```bash
ovs sh -c 'tcpdump -ni br-int -c 20'                 # overlay traffic
ovs sh -c 'tcpdump -ni genev_sys_6081 -c 20'         # inter-node tunnel traffic
ovs sh -c 'tcpdump -ni 0df74_6215455_h -c 20'        # one VM's mgmt/overlay veth
```

**SR-IOV dataplane (`ens9fXnpX_N` representors and the PF uplink):** `tcpdump` is
**largely blind by design**. Offloaded packets are switched inside the NIC
eSwitch (TC-flower) and never traverse the host netdev, so `tcpdump` on a
representor or on the PF uplink sees only the tiny slow-path fraction (first
packet of a flow, ARP misses), not the bulk traffic. Do **not** conclude "no
traffic" from an empty `tcpdump` here — use §4 counters instead.

To actually see dataplane packet payloads, capture at a point the traffic is
forced through software:

1. **Inside the guest VM** (best — always sees its own traffic): §8.
2. On the **first packet / control traffic** only: `tcpdump -ni ens9f0np0_2`
   (you'll catch ARP and flow-setup, enough to confirm reachability).
3. Temporary, invasive, **non-prod only**: disabling offload for a NIC forces all
   packets to software so `tcpdump` on the representor sees everything —
   `ethtool -K ens9f0np0 hw-tc-offload off` — but this tanks throughput and
   changes behaviour; re-enable immediately with `... on`. Avoid on shared/live VNFs.

---

## 7. Overlay (kube-OVN / OVN) debug quick reference

```bash
# Logical topology
kubectl exec -n kube-system deploy/ovn-central -- ovn-nbctl show
kubectl exec -n kube-system deploy/ovn-central -- ovn-nbctl lsp-list <logical-switch>

# Is a VM's LSP up / what port-security / addresses
kubectl exec -n kube-system deploy/ovn-central -- ovn-nbctl list Logical_Switch_Port <iface-id>

# Trace a packet through the OVN pipeline (L2/L3 reachability without sending traffic)
kubectl exec -n kube-system deploy/ovn-central -- \
  ovn-trace <ls> 'inport=="<lsp>" && eth.src==<mac> && ip4.dst==<dst>'

# kube-OVN convenience (subnets, IPs, cross-node ping matrix)
kubectl ko nbctl show          # if the `kubectl ko` plugin is installed
kubectl get subnet,vpc
```

Cross-node overlay traffic rides geneve (`genev_sys_6081`, tunnels visible in
`ovs-vsctl show` on `br-int`). Cross-node **dataplane** traffic does NOT — it
rides the physical wire between PFs (ToR/VLAN trunk), so debug it on the wire /
uplink counters, not on tunnels.

---

## 8. VM guest-level debugging

The guest is the **truthful vantage point** for the dataplane: inside the VM the
VF is a real `mlx5_core` netdev (VFIO passthrough), so guest counters and
`tcpdump` see 100% of the traffic — none of the host-side offload blindness of
§6 applies here.

### Getting in

Use the **`kubevirt-vm-access` skill** (`virtctl ssh` / console / `virt-launcher`
exec). On this lab the VNF user is `ubuntu` and the key is
`lab-deployment/osm/.ssh/osm-vm-access` (`chmod 600`). VMs get recreated often, so
their host key changes — bypass the stale-key failure with:

```bash
KEY=~/Dev/github.com/kube-nfv/lab-deployment/osm/.ssh/osm-vm-access
virtctl ssh --namespace kube-vim --identity-file "$KEY" \
  --local-ssh-opts="-o StrictHostKeyChecking=no" \
  --local-ssh-opts="-o UserKnownHostsFile=/dev/null" \
  ubuntu@vmi/<vmi-name> --command '<cmd>'
```

### What's installed (Ubuntu 26.04 VNF images)

Present: `ip ss ethtool tcpdump nc ping mtr nstat sar`.
**Not** present: `iperf3`/`iperf`, `socat`, `iftop`, `nload`, `dstat`, `hping3`.
(For throughput either install iperf3 or use the `nc` method below.)

### Identify the interface

Guest NICs are **renamed to the VL** by cloud-init (e.g. `transit0`, `wan0`), with
the overlay/mgmt NICs as `enp1s0` (default/`ovn-default`) and `enp2s0` (mgmt,
`10.240.0.0/24`). Driver tells VF from overlay:

```bash
ip -br addr                      # names + IPs at a glance (transit0 10.20.0.2, wan0 10.30.0.1, ...)
ethtool -i transit0             # driver: mlx5_core  => SR-IOV dataplane VF
ethtool -i enp1s0               # driver: virtio_net => overlay/mgmt NIC
ip link show transit0           # link/ether 02:20:00:00:00:02 -> match to the VL's MAC (§2b)
ethtool transit0 | grep -E 'Speed|Link detected'
```

### Is traffic flowing? (counters — source of truth)

```bash
ip -s link show transit0                        # RX/TX packets, bytes, errors, dropped
ethtool -S transit0 | grep -E 'rx_packets|tx_packets|rx_bytes|tx_bytes|dropped|discard'
nstat -az                                       # kernel-wide since boot (retrans, drops)
```

### Measure the rate (live pps / throughput)

```bash
sar -n DEV 1                     # per-iface rxpck/s txpck/s rxkB/s txkB/s, every 1s
sar -n EDEV 1                    # per-iface error/drop rate
watch -n1 'ethtool -S transit0 | grep -E "rx_packets|tx_packets"'   # rate = delta/sec
```

### Reachability & path across the chain

```bash
ping -I transit0 -c3 10.20.0.1   # ping over a specific VF to the next hop (RTT confirms the path)
mtr -n -I transit0 10.30.0.5     # per-hop loss/latency
ip neigh show dev transit0       # ARP table = who this VM resolved on the segment
ip route get 10.30.0.5           # which NIC / next-hop the kernel picks
```

### Capture / inspect (guest is not offload-blind)

```bash
tcpdump -ni transit0 -c 20                       # real dataplane packets — works fully here
tcpdump -eni transit0 'arp or icmp'              # -e shows src/dst MAC (L2 isolation check, below)
ss -tunap                                        # active sockets/connections
```

To confirm an L2 segment is (not) isolated — the untagged-VLAN caveat from
`sriov-networks.md` — run `tcpdump -eni transit0` and watch source MACs: on an
untagged shared bridge you'll see broadcast/ARP from *other* VLs on the same PF.

### Active throughput test (no iperf3 installed)

```bash
# Option A — install it (VMs have full internet egress via ovn-default masquerade):
sudo apt-get update && sudo apt-get install -y iperf3
#   server VM:  iperf3 -s -B 10.20.0.2
#   client VM:  iperf3 -c 10.20.0.2 -t 10

# Option B — zero-install bulk transfer, measure rate with sar:
#   receiver:   nc -l 5555 > /dev/null
#   sender:     dd if=/dev/zero bs=1M count=2000 | nc <peer-ip> 5555
#   on either:  sar -n DEV 1        # read rxkB/s / txkB/s on the VF
```

---

## 9. Common failure playbook

| Symptom | Most likely cause | First check |
|---|---|---|
| VM pod `Pending` | No free VFs in the pool | `kubectl describe pod <virt-launcher>` → `Insufficient openshift.io/mlx_vf_pf*` |
| Guest missing the dataplane NIC | KubeVirt `SRIOV` feature gate off, or NAD `resourceName` wrong | `kubectl get kubevirt -n kubevirt -o yaml`  ·  §2b shows `pci:null` where a VF was expected |
| VF present, no traffic | representor not on a bridge, or PF not a bridge port (ovs-cni auto-discovery failed) | `ovs ovs-vsctl port-to-br <rep>`  ·  `ovs ovs-vsctl list-ports br-mx5p0` shows the uplink |
| Traffic flows but `tcpdump` on rep is empty | **normal** — offloaded, host-blind | §4 counters (`ethtool -S ... vport_*`), not tcpdump |
| Traffic works but not offloaded | PF not switchdev, or `hw-offload` off | `ovs ovs-vsctl get Open_vSwitch . other_config:hw-offload`  ·  `dpctl/dump-flows -m` shows `dp:ovs` |
| "offload broken" but counters climbing | you grepped `offloaded:yes` **without** `-m` | re-run `dpctl/dump-flows -m` (§5 gotcha) |
| Two VLs on same PF can reach each other unexpectedly | both `segmentationId:0` (untagged) → shared L2 domain | `ovs sh -c 'ovs-vsctl get port <rep> tag'` (empty = untagged); give each VL a distinct VLAN |
| VM mgmt IP unreachable from RO/EE | mgmt NIC not on shared `osm-mgmt` subnet | §2c `find interface external_ids:pod_name=<vm>` → check `...osm-mgmt...` iface-id + IP in `10.240.0.0/24` |
| Overlay works, dataplane doesn't cross nodes | expecting geneve for dataplane | dataplane is on the physical wire, not tunnels — check uplink/ToR, not `genev_sys_6081` |

---

## 10. Worked example (from a live allocation)

The running vCPE chain, as a concrete reference for the correlation walk. **All
values are ephemeral** — reproduce with the commands above, don't trust the
literals.

Service chain: `client ── [fw VM] ──transit── [router VM] ──wan── wire`

| VM | VL (NAD) | rendered MAC | VF PCI | PF / bridge | representor |
|---|---|---|---|---|---|
| fw | `vcpe-demo-client-vl` | `02:10:00:00:00:01` | `0000:b3:02.7` | PF1 / `br-mx5p1` | `ens9f1np1_3` |
| fw | `vcpe-demo-transit-vl` | `02:20:00:00:00:01` | `0000:b3:03.2` | PF1 / `br-mx5p1` | `ens9f1np1_6` |
| router | `vcpe-demo-transit-vl` | `02:20:00:00:00:02` | `0000:b3:02.6` | PF1 / `br-mx5p1` | `ens9f1np1_2` |
| router | `vcpe-demo-wan-vl` | `02:30:00:00:00:01` | `0000:b3:00.4` | PF0 / `br-mx5p0` | `ens9f0np0_2` |

Plus every VM carries `default` (`ovn-default`, masquerade) and
`osm-mgmt-subnet-0` (`10.240.0.0/24`, bridge binding) on `br-int`.

The offloaded transit flow (`fw → router`) proves the fast path:
`in_port(ens9f1np1_6) eth(src=02:20:..:01,dst=02:20:..:02) ... offloaded:yes, dp:tc, actions:ens9f1np1_2`.

> Note (topology, not a bug per se): in this allocation `client-vl`, `transit-vl`
> and the unrelated `test-demo` VF are all `segmentationId:0` (untagged) on
> `br-mx5p1` — i.e. one shared L2 broadcast domain, NOT VLAN-isolated. Unicast
> still works via MAC learning; isolation relies on L3 hops. Assign distinct
> `segmentationId`s per VL if L2 isolation is required (see `sriov-networks.md`).

---

## 11. Copy-paste bootstrap

```bash
export KUBECONFIG=~/Dev/github.com/kube-nfv/lab-deployment/02-setup/_out/talos/configs/kubeconfig
OVS=$(kubectl get pod -n kube-system -l app=ovs \
      --field-selector spec.nodeName=setup02-x11spl-f-worker-1 \
      -o jsonpath='{.items[0].metadata.name}')
ovs() { kubectl exec -n kube-system "$OVS" -c openvswitch -- "$@"; }

ovs ovs-vsctl show
ovs ovs-vsctl get Open_vSwitch . other_config:hw-offload
ovs ovs-appctl dpctl/dump-flows -m | grep -E 'offloaded:|dp:' | head
```
