# Pitfalls

Problems met while building, re-provisioning and upgrading this setup, grouped by where they
show up. Each entry gives the symptom first, since that is what you will be searching for.

## Cloud infrastructure

**The firewall still allows the old range after narrowing `allowed_cidrs`.** An in-place
update of the Talos and Kubernetes API rules has been seen to add the new range without
removing `0.0.0.0/0`; a second `terraform apply` removed it. Check the result with
`gcloud compute firewall-rules list` rather than trusting the plan.

## Re-provisioning an edge node

A clean ISO boot into maintenance mode is the easy case. Reusing a machine that still has an
older Talos install on disk is not.

**Port 50000 refused while the host answers ping.** A worker's Talos API gets its server
certificate from trustd on the control plane, reached through the cluster endpoint - a
Tailscale address. If the applied config cannot bring Tailscale up (no valid auth key, or a
config for a cluster that no longer exists), apid never starts. The node is not hung; the
console shows it waiting for `ext-tailscale`.

**`talosctl reset` stalls and later reboot requests are ignored.** A reset that cannot stop a
service (for example the ZFS service while pool volumes are still in use) holds the sequence
lock, and Talos ignores further reboots. Power-cycle the machine, then choose "Reset Talos
installation" in the boot menu, which wipes STATE and EPHEMERAL and lands in maintenance mode.

**The maintenance-mode apply keeps the old Talos version.** If the disk already holds Talos,
`apply-config --insecure` does not run the installer from the config, and an older Talos
rejects documents it does not know (`"DiscoveryServiceConfig" "v1alpha1": not registered`).
Either boot the new ISO and wipe the system disk, or apply a minimal config generated with
`--talos-version <old-minor>` (including the Tailscale extension config, or the API never
comes up), run `talosctl upgrade` to the new installer, and then apply the full config.
Extension services also block boot if their prerequisites are missing; the ZFS service waits
for `/dev/zfs`, so the minimal config needs the `zfs` kernel module too.

**A raw volume fails with "not enough space".** EPHEMERAL created without its `VolumeConfig`
size cap fills the disk, leaving nothing for volumes meant to follow it. `talosctl reset
--system-labels-to-wipe EPHEMERAL --reboot` recreates it at the configured size. Tailscale
state lives on EPHEMERAL, so the node rejoins the tailnet as a new device with a new address;
remove the old device from the tailnet.

**The node has no location taint or labels.** Talos applies node taints only at registration;
afterwards Kubernetes' NodeRestriction admission rejects a node changing its own taints, and
the label update in the same request fails with it. Delete the Node object and restart
kubelet (`talosctl service kubelet restart`) so the node registers again.

**Device names change between boots.** Removing a USB stick turned the system disk from `sdb`
into `sda`. Refer to disks by selector (`disk.transport == "sata"`) and to partitions by label
(`/dev/disk/by-partlabel/...`), never by device name.

## Networking

**kube-proxy nftables mode.** Talos 1.14 runs kube-proxy in nftables mode by default, which
Kube-OVN does not support. `controlplane.yaml` sets `mode: iptables`.

**`provider ... is not bound to any subnet`.** Since Kube-OVN 1.16.3, a Subnet used through a
NetworkAttachmentDefinition must set `spec.provider` to that NAD's provider
(`<nad>.<namespace>.ovn`). Earlier releases accepted any provider ending in `.ovn`. Every
pod attached to a mismatched network fails sandbox creation.

**SR-IOV pods fail with `failed to get bridge name`.** ovs-cni received no `deviceID`, meaning
no VF was allocated to the pod. Two causes seen:

- KubeVirt enables Beta feature gates by default, including `ExternalNetResourceInjection`,
  which stops virt-controller from adding the VF resource request implied by the NAD's
  `resourceName` (it expects network-resources-injector to do it). The KubeVirt CR disables
  the gate. Check that a virt-launcher pod requests `openshift.io/<pool>`.
- The per-PF OVS bridges do not exist. ovs-cni only attaches representors to an existing
  bridge, found through the VF's PF; the Kube-OVN ProviderNetworks in `k8s/kube-ovn/k8s/`
  create them.

**Privileged pods rejected by PodSecurity.** Talos enforces `baseline` by default. Namespaces
with privileged pods (Linstor satellites, Tailscale LoadBalancer proxies, SR-IOV daemons, the
PD node plugin, monitoring exporters) need the `privileged` label; their overlays apply a
`namespace.yaml` before Helm runs. A namespace created by `helm --create-namespace` alone does
not get it.

## Talos-managed manifests

Talos creates its bootstrap manifests (kube-proxy, CoreDNS, RBAC) but does not update existing
objects. A config change such as the kube-proxy mode reaches the cluster only through
`talosctl upgrade-k8s`, which re-applies them.

**`upgrade-k8s` would delete the Helm-managed CoreDNS.** Talos keeps an inventory of the
manifests it applied. A cluster that started with the bundled CoreDNS still lists those
objects, and `upgrade-k8s` prunes entries it no longer renders - which now means deleting the
Helm release's Deployment, Service and ConfigMap of the same names. Always run
`upgrade-k8s --dry-run` first and look for `Pruned`; use `--manifests-no-prune`. Removing the
CoreDNS entries from the `talos-bootstrap-manifests-inventory` ConfigMap would end this for
good.

**`upgrade-k8s` fails with `node is not ready` before a CNI exists.** The kubelet step waits
for each node to become Ready. With `--upgrade-kubelet=false` only the manifests are synced.

## Components

**Helm cannot install a resource whose CRD is in the same release.** The Tailscale operator
chart installs the `ProxyClass` CRD from templates, so a `ProxyClass` in the same release fails
on a fresh install (`no matches for kind "ProxyClass"`). It is created in a post-install hook.

**A StatefulSet volume lands on the wrong StorageClass.** A chart value that does not pin a
StorageClass falls back to the cluster default, which may only exist at the other location
(Gitea's Valkey ended up on edge-only Linstor while pinned to cloud nodes). Pin it, and
uninstall and reinstall to change it, since volume claim templates are immutable.

**Two default StorageClasses.** Both `pd-standard` and Linstor's `local` carry the default
annotation; Kubernetes uses the newer one, so the install order decides.

**Version bumps that silently break patches.** Kustomize JSON patches that address list items
by index (`/containers/4/env/0`) hit the wrong item when upstream reorders the list. Patch by
name with strategic merges instead, and render before applying.

**Chart bumps that need a fork rebase.** The CDI controller and the SR-IOV operator run forked
images pinned to a specific upstream release. Bumping the upstream chart without rebasing the
fork mixes versions; keep them pinned until the fork is rebuilt.

## Orchestrator and workloads

**The guest is unconfigured for two minutes after the VM is Running.** The Ubuntu cloud image
waits in `systemd-networkd-wait-online` for interfaces that never get DHCP before cloud-init
runs its modules. Read the serial console from the virt-launcher pod's `guest-console-log`
container before concluding that networking is broken.

**Re-instantiating an NS fails with a 409 conflict.** `osm ns-delete --wait` returns before the
VIM has finished deleting the VM, and the VM name is deterministic. Wait for it to disappear.

**`osm ns-create --timeout` is rejected.** The client sends it as a string and the NBI wants
an integer. Leave it out.
