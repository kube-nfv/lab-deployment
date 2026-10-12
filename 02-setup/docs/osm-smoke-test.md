# OSM registration and smoke tests

How to connect a freshly built cluster to OSM and prove it works end to end: a VM on the
management network, and SR-IOV traffic through a VNF. Run the `osm` client from its
container with the variables in `../../osm/env`; packages are in `../../osm/`.

## Register the cluster

OSM needs three things: a VIM account for kube-vim, the Kubernetes cluster for KNFs, and the
VM images.

```sh
osm vim-create --name kubevim --account_type kubevim \
  --auth_url http://kube-vim-gateway.kube-vim.svc.cluster.local:8080 \
  --user unused --password unused --tenant unused \
  --config '{management_network_name: osm-mgmt}'

osm k8scluster-add <cluster-name> --creds <kubeconfig> --vim kubevim \
  --k8s-nets '{net1: osm-mgmt}' --version <kubernetes-version> \
  --namespace kube-system --skip-jujubundle
```

- The URL is the kube-vim REST gateway as RO sees it from inside the cluster.
- The kubevim plugin ignores user, password and tenant, but OSM requires them.
- `management_network_name` maps every VLD marked `mgmt-network: true` onto the management
  network that kube-vim provisions, which RO is attached to.
- The kubeconfig's server must be reachable from the LCM pod; the Tailscale address is.

VM images are imported through kube-vim's admin gRPC API, which the REST gateway does not
expose. The server has reflection enabled, so `grpcurl` needs no proto files:

```sh
grpcurl -plaintext -d '{
  "metadata": {"name": "focal-server-cloudimg-amd64"},
  "source": {"type": "HTTP", "http": {"url": "https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"}}
}' <kube-vim-grpc-host>:50051 admin.kubevim.kubenfv.api.pb.admin/DownloadImage
```

The name must equal the `image` of the VNFD's `vim-type: kubevim` `sw-image-desc`. CDI
imports it into a DataVolume; it is usable when the DataVolume reaches `Succeeded`.

## Management network test - hackfest_basic

One VM with a single interface on the management network.

```sh
osm vnfpkg-create hackfest_basic_vnf.tar.gz
osm nspkg-create  hackfest_basic_ns.tar.gz
osm ns-create --ns_name smoke-hackfest --nsd_name hackfest_basic-ns --vim_account kubevim --wait
osm vnf-list --ns smoke-hackfest      # mgmt address in the management subnet
osm ns-delete smoke-hackfest --wait
```

Pass: the NS reaches `READY`, the VM runs, and the NS deletes cleanly.

## SR-IOV traffic test - sriov_router

A router VM with a management NIC and two SR-IOV VFs, one per PF. cloud-init gives the first
VF `10.10.0.1/24` and the second `10.20.0.1/24` and enables forwarding. The dataplane is pure
L2 between the traffic generator and the PFs; the generator's port 0 sits in `10.10.0.0/24`
with the router as gateway, its port 1 in `10.20.0.0/24`.

```
generator port 0 ──► PF0 ──► VF (10.10.0.1) ─┐
                                              router VM
generator port 1 ◄── PF1 ◄── VF (10.20.0.1) ─┘
```

OSM ignores `provider-network` in the NSD, so the VF pools are given at instantiation:

```sh
osm vnfpkg-create sriov_router_vnf.tar.gz
osm nspkg-create  sriov_router_ns.tar.gz
osm ns-create --ns_name smoke-router --nsd_name sriov-router-ns --vim_account kubevim --wait \
  --config '{vld: [
    {name: upstream,   provider-network: {physical-network: <pf0-vfio-pool>, network-type: sriov}},
    {name: downstream, provider-network: {physical-network: <pf1-vfio-pool>, network-type: sriov}}]}'
```

Use the `vfio` pools: KubeVirt passes the VF to the guest with VFIO, and the guest's `mlx5`
driver binds it.

Then send UDP from port 0 to an address behind port 1, with the router's upstream VF MAC as
next hop. Two things the generator must get right:

- Port 1 must answer ARP for its own address, or the router never resolves its next hop and
  drops everything. In T-Rex that means service mode on port 1 for the duration of the test.
- The reference run sent 1 Gbps of 512-byte UDP for 60 seconds. Linux forwarding in a 2-vCPU
  guest is the bottleneck well before the platform is, so treat the rate as a path test, not
  a benchmark.

Pass: received packets on port 1 within 1% of transmitted packets on port 0. The reference
run lost 0.046%.

Terminate with `osm ns-delete smoke-router --wait`, and wait until the VM and its NADs are gone
before instantiating again.

## When it does not work

Work outwards from the VM, using the checks in [pitfalls.md](pitfalls.md#networking):

1. The VM stays `Scheduling`: the boot disk is still cloning (DataVolume `CloneInProgress`),
   or the virt-launcher pod cannot get its networks - read its events.
2. The VM is `Running` but silent: read the serial console (`guest-console-log` container) and
   wait for cloud-init to finish.
3. No ARP reply at the generator: capture on the VF representor and the PF uplink on the edge
   node (`tcpdump` from the `ovs-ovn` pod). If the reply leaves the PF, the problem is
   between the PF and the generator.
4. Traffic in, nothing out: capture ARP on the downstream PF. Repeated `who-has` from the
   router means the generator's receiving port is not answering ARP.
