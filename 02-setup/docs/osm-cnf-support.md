# OSM CNF (KNF) support on kube-vim

## Purpose

Reference for how OSM deploys containerised network functions (CNFs) on this
kube-vim lab, what the descriptors let you express, what OSM does NOT do, and the
concrete gotchas that break a CNF instantiation. Written for future agents/users
onboarding a CNF. Pairs with [sriov-dataplane-bridges.md](./sriov-dataplane-bridges.md)
for the underlying SR-IOV/OVS dataplane.

Facts here are split into STABLE (ETSI/OSM architecture, verified against the
deployed code) and LAB (specific to this setup, may drift).

---

## 1. Terminology (ETSI)

A CNF in ETSI/OSM terms is a **KNF** (Kubernetes Network Function). Its deployable
unit is a **KDU** (Kubernetes Deployment Unit), declared inside a normal VNFD.
There is deliberately **no separate CNFD** - a CNF is a VNF "realized by OS
containers".

ETSI object model (GS NFV-IFA 040, mapping in SOL 018):

| ETSI object | Realized as | Maps into NFV IM |
|---|---|---|
| MCIO (Managed Container Infrastructure Object) | K8s Deployment/StatefulSet/DaemonSet/Job, Service | VNFC (compute) / CP (network) |
| MCIOP (MCIO Package) | **a Helm chart** | referenced from VNFD/VDU, shipped in VNF package |
| Namespace / quota | K8s Namespace / ResourceQuota | - |
| OS container image | OCI image | managed by CIR, distributed by NFVO |
| CISM (Container Infra Service Mgmt) | the Kubernetes API / Helm | peer of the VIM |
| CIR (Container Image Registry) | OCI registry | - |

Spec sources (local clones): `~/Dev/Specs/etsi/etsi_gs/nfv-ifa/040`,
`nfv-sol/018`, `nfv-ifa/011`; rationale report `etsi_gr/nfv-ifa/029`.

So: **OSM KDU == ETSI MCIOP == a Helm chart**. juju-bundle is an OSM-ism, not in
the ETSI mapping.

---

## 2. How OSM implements CNFs (STABLE, verified in deployed LCM)

CNFs are handled **entirely by LCM**, via the N2VC K8s connectors. They do NOT
touch RO or the VIM connector:

- `lcm/osm_lcm/ns.py: deploy_kdus -> _install_kdu -> k8scluster_map[type].install`
- connectors: `n2vc/k8s_helm3_conn.py` (helm-chart-v3), `n2vc/k8s_juju_conn.py`
- verbs: `install / upgrade / scale / rollback / uninstall / status_kdu / get_services / exec_primitive`

Verified: the RO fork (`kube-nfv/RO`) and kube-vim have **zero** CNF code. A CNF
is helm-installed straight onto the registered K8s cluster's kubeconfig.

Flow:
```
osmclient/NG-UI --REST--> NBI --Kafka--> LCM --(helm3 install)--> K8s cluster API
```

The registered k8scluster is bound to a `vim_account`; that binding is the only
link between the CNF world and the VIM. On this lab: cluster `_system-osm-k8s`
-> VIM `kubevim`, deployment method `helm-chart-v3` (juju disabled), namespace
default `kube-system`, no helm repos registered.

---

## 3. What the descriptor lets you express (and what it does NOT)

The KDU integration surface is thin. From the VNFD/instantiate config, LCM
consumes only:

| Field | Effect |
|---|---|
| `kdu[].helm-chart` (or `juju-bundle`) | which chart/bundle (`kdu_model`) |
| `additionalParamsForKdu[].additionalParams` | flat key-values -> Helm `-f values.yaml` (the only app/config channel) |
| `k8s-namespace` (ns-create `--config`) | target namespace (see gotcha #2) |
| `k8s-cluster.id` | which registered cluster |
| nodeSelector (post-renderer) | pin pods to nodes |
| day-2 `exec_primitive` / `scale` | helm upgrade / scale |

What OSM does **NOT** do (verified - no such code in `ns.py`):

- No CP -> Service creation, no VirtualCp handling.
- No VLD -> pod network mapping. **No NAD injection.** (SOL 018 defines
  descriptor -> `k8s.v1.cni.cncf.io/networks` NAD-id injection, but OSM does not
  implement it.)
- No IP/MAC/address assignment for the CNF.

Consequence: **all CNF networking beyond the primary CNI lives in the Helm chart**
(or is passed as chart values). You pre-create the NADs and reference them from
the chart; OSM only helm-installs.

The VNFD `k8s-cluster.nets` / `ext-cpd.k8s-cluster-net` / `mgmt-cp` fields are
accepted for IM validation but are NOT wired to anything by OSM. Keep them for
schema completeness only.

---

## 4. Networking a CNF onto the SR-IOV/OVS fabric

A CNF pod joins the offloaded fabric exactly like a VNF VM, with less machinery:

| | VNF (KubeVirt VM) | CNF (plain pod) |
|---|---|---|
| VF resource | `mlx_vf_pfN_vfio` (device plugin) | `mlx_vf_pfN_netdev` (kernel VF into pod) |
| Representor -> OVS bridge | ovs-cni | same ovs-cni |
| VF into workload | VFIO passthrough to QEMU | VF netdev in pod netns |

The chart requests the VF resource and carries the NAD annotation:

```yaml
# pod template
metadata:
  annotations:
    k8s.v1.cni.cncf.io/networks: '[{"name":"<nad>","namespace":"<ns>","interface":"pfN"}]'
spec:
  containers:
  - resources:
      requests: { openshift.io/mlx_vf_pfN_netdev: "1" }
      limits:   { openshift.io/mlx_vf_pfN_netdev: "1" }
```

NAD (ovs-cni, kernel/netdev pool; empty IPAM = address set by the workload):
```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  annotations: { k8s.v1.cni.cncf.io/resourceName: openshift.io/mlx_vf_pfN_netdev }
spec:
  config: '{ "cniVersion":"0.3.1", "type":"ovs", "socket_file":"unix:/var/run/openvswitch/db.sock" }'
```

Isolation notes (see the dataplane doc):
- All VFs on a PF share ONE flat MAC-learning bridge (`br-mx5pN`). Different VF
  pool (vfio vs netdev) does NOT isolate - same PF = same L2 broadcast domain.
- IP addresses on ovs-cni NADs are NOT managed (empty IPAM); the workload sets
  them. Two functions on the same PF with the same subnet WILL collide. Pick
  distinct subnets, or use a `vlan` tag in the NAD for real L2 separation.

---

## 5. Gotchas / hard requirements (LAB + STABLE, all hit and verified)

These are the things that break a CNF instantiation on this stack:

1. **Chart folder must be `helm-chart-v3s/`, not `helm-charts/`.**
   `ns.py` (~L3897) resolves a bundled KDU chart at
   `{pkg-dir}/{k8sclustertype}s/{chart}`, and for a `helm-chart:` KDU
   `k8sclustertype == "helm-chart-v3"`. So a bundled chart goes under
   `<vnf-pkg>/helm-chart-v3s/<chart>/`. (`helm-charts/` is only for
   execution-environment / VCA charts - a different code path, which is why the
   VM-EE `eechart` uses that name.)
   Symptom if wrong: `Error: INSTALLATION FAILED: non-absolute URLs should be in
   form of repo_name/path_to_chart, got: <chart>`.

2. **Pod Security Admission.** The default KDU namespace is the OSM project id,
   which has no PSA labels -> cluster-default `baseline` applies and forbids
   NET_ADMIN/NET_RAW/SYS_ADMIN/privileged. Network functions need these.
   Fix: pre-create a namespace labelled `pod-security.kubernetes.io/enforce=privileged`
   and steer the KDU into it with `ns-create --config '{k8s-namespace: <ns>}'`
   (NBI `_get_ns_k8s_namespace`).

3. **`/proc/sys` is read-only without privileged.** `NET_ADMIN` alone does not
   make `/proc/sys` writable, so `echo 1 > /proc/sys/net/ipv4/ip_forward` (and
   FRR's per-interface forwarding) fail. Use `securityContext.privileged: true`
   (allowed once the namespace is privileged-PSA).

4. **NSD must declare at least one `virtual-link-desc`.** LCM's RO/VIM stage runs
   unconditionally even for a pure-CNF NS and does `enumerate(db_nsr.get("vld"))`
   at `ns.py:870`. With no VLD, `db_nsr["vld"]` is None ->
   `'NoneType' object is not iterable` -> NS goes BROKEN (while the KDU pod runs
   fine, because the KDU install is a separate task). Add a minimal mgmt VLD plus
   the matching `virtual-link-connectivity` in the df vnf-profile (mirror the
   working VM `test-ns`). This is effectively an upstream LCM guard bug; the
   descriptor workaround is the practical fix.

5. **No helm repo registered** on the cluster (`repo-list` empty) -> the chart
   must be **bundled inside the VNF package** (under `helm-chart-v3s/`). To
   reference charts by name instead, register a repo (`osm repo-add`).

6. **Cross-namespace NADs work.** The KDU lands in its own namespace but can
   reference NADs in `default` / `kube-vim`; Multus resolves them. (The
   mgmt-overlay NAD lives in `kube-vim`; the SR-IOV NADs in `default`.)

7. **Maintained images.** FRR: use `quay.io/frrouting/frr` (10.x). Docker Hub
   `frrouting/frr` is frozen at 2022 (v8.4). No maintained upstream OVS image
   exists (`openvswitch/ovs` is 2019); the in-cluster `kubeovn/kube-ovn` image
   ships current OVS if needed.

---

## 6. Options: when to build what

For CNF support the design question is what layer to add. Guidance from this
work:

- **Chart-only (recommended default).** Pre-provision NADs, reference them from
  the chart / `additionalParams`. No OSM change, no CISM. Covers the
  shared-dataplane goal. This is what the working demo does.
- **New N2VC connector** (additive, not a fork) - only if you want the
  descriptor's networks MANO-modelled (SOL 018 NAD injection) rather than
  chart-owned. Register as a new deployment method; LCM keeps calling
  install/upgrade/scale.
- **Standalone CISM (proxy over kube-api)** - only justified if you need MCIOP
  lifecycle as first-class objects, namespace-quota enforcement, SOL-018 param
  mapping, MCIO status aggregation, or multi-cluster placement. For dataplane
  alone it is overkill and does not address networking (that is a CNI/Multus
  concern regardless).
- **Do NOT fork LCM core.** LCM is the one deployed component left upstream;
  extend via connectors, not by patching `ns.py`.

---

## 7. Working reference: the FRR CNF demo

Location: `~/Dev/github.com/retelith/demo/frr-cnf/`

```
frr-cnf/
├── Makefile                                  # nad-apply, onboard, ns-create, ...
├── frr-knf/                                   # VNF package (KNF)
│   ├── frr_knfd.yaml                          # VNFD: one KDU -> helm-chart frrcnf
│   ├── extras/                                # pre-created NADs (kernel netdev pool)
│   │   ├── sriov-pf0-netdev-nad.yaml
│   │   └── sriov-pf1-netdev-nad.yaml
│   └── helm-chart-v3s/frrcnf/                 # the MCIOP (Helm chart)
│       ├── Chart.yaml / values.yaml
│       └── templates/{configmap,deployment,_helpers}.yaml
└── frr-knf-ns/frr_knsd.yaml                   # NSD (includes the mandatory mgmt VLD)
```

The CNF: FRRouting router with 3 interfaces - `mgmt0` (kube-ovn overlay),
`pf0` (SR-IOV VF, br-mx5p0), `pf1` (SR-IOV VF, br-mx5p1). Privileged, pinned to
the NIC node (`node.kubernetes.io/location=edge`, tolerating its taint).
zebra+staticd+mgmtd on; bgpd/ospfd toggleable; static routes via `extraConfig`.

Deploy:
```
cd ~/Dev/github.com/retelith/demo/frr-cnf
make nad-apply     # create pf0/pf1 netdev NADs
make onboard       # vnfd-create + nsd-create
make ns-create     # instantiate on VIM 'kubevim', into privileged ns 'frr-cnf'
make ns-list
```

Verified result: NS `READY`, pod `1/1 Running`, interfaces up
(`pf0 10.40.0.1/24`, `pf1 10.50.0.1/24` - chosen distinct from vcpe-demo's
10.10/10.20 to avoid the shared-L2 collision), `ip_forward=1`, FRR forwarding
between the two dataplane segments.

---

## 8. Command reference

```bash
# OSM state
osm k8scluster-list ; osm k8scluster-show _system-osm-k8s
osm vim-list ; osm ns-list ; osm ns-show <name>

# KDU chart resolution / helm on the cluster (from LCM pod)
kubectl exec -n osm deploy/lcm -c lcm -- sh -c \
  'env KUBECONFIG=/app/storage/<cluster-uuid>/.kube/config helm3 list -A'

# stored package tree (confirm chart landed under helm-chart-v3s)
kubectl exec -n osm deploy/lcm -c lcm -- \
  find /app/storage/<vnfd-uuid>:<rev> -maxdepth 3

# CNF pod dataplane
kubectl get pods -n <kdu-ns> -o wide
kubectl exec -n <kdu-ns> <pod> -c <ctr> -- ip -br addr
kubectl exec -n <kdu-ns> <pod> -c <ctr> -- vtysh -c 'show interface description'   # FRR
```

Kubeconfig: `~/Dev/github.com/kube-nfv/lab-deployment/02-setup/_out/talos/configs/kubeconfig`.
OSM client env: `~/Dev/github.com/kube-nfv/lab-deployment/osm/env`
(runs `ghcr.io/kube-nfv/osm-client:latest` via docker).
