# 01-Setup Network Infrastructure

This setup creates an isolated network environment using Open vSwitch (OVS) and DNSMasq for testing and development.

## Network Architecture

```
                    Internet
                       |
                   [NAT/Masquerade]
                       |
              ┌────────┴────────┐
              │  01-setup-net   │  (OVS Bridge)
              │  10.0.10.1/24   │  (Gateway)
              └────────┬────────┘
                       |
         ┌─────────────┼─────────────┬─────────────┬─────────────┐
         |             |             |             |             |
    [DNSMasq]     [Matchbox]    [Master-1]    [Worker-1]    [Worker-2]
   10.0.10.2     10.0.10.3      10.0.10.x     10.0.10.x     10.0.10.x
  (DNS/DHCP)     (PXE/HTTP)   (4CPU/4GB)   (8CPU/16GB)   (8CPU/16GB)
                                            +drbd-1       +drbd-2
```

## Network Configuration

- **Network**: 10.0.10.0/24
- **Gateway**: 10.0.10.1 (OVS bridge, NAT enabled)
- **DNS/DHCP**: 10.0.10.2 (DNSMasq container)
- **PXE Server**: 10.0.10.3 (Matchbox container) - matchbox.setup01.local
- **DHCP Range**: 10.0.10.10 - 10.0.10.200
- **Domain**: setup01.local

## Storage Configuration

The setup uses LVM thin provisioning for efficient disk space management of Talos node disks, plus DRBD volumes for worker nodes.

**LVM Thin Provisioning (Primary Disks):**
- **Physical Volume**: `/dev/sdb6` (150 GiB)
- **Volume Group**: `vg-talos-setup01`
- **Thin Pool**: `thinpool` (145 GiB)

**Thin Logical Volumes (50 GiB each):**
- `/dev/vg-talos-setup01/talos-setup01-node1` - Master node
- `/dev/vg-talos-setup01/talos-setup01-node2` - Worker 1
- `/dev/vg-talos-setup01/talos-setup01-node3` - Worker 2

**DRBD Volumes (Secondary Disks for Workers, 200 GB each):**
- `/dev/drbd-vg/drbd-1` - Worker 1 secondary storage
- `/dev/drbd-vg/drbd-2` - Worker 2 secondary storage

**Benefits:**
- Thin provisioning: Only actual data usage consumes space
- Snapshot capability for quick VM backups/rollback
- Direct block device access (no filesystem overhead)
- 150 GiB virtual capacity from 145 GiB pool (overcommit supported)
- DRBD volumes available for distributed storage testing

**Setup Commands:**
```bash
# Create partition on /dev/sdb (150 GiB, type Linux LVM)
sudo fdisk /dev/sdb
# Commands: n, 6, <Enter>, +150G, t, 6, 30, w
sudo partprobe /dev/sdb

# Create LVM thin pool
sudo pvcreate /dev/sdb6
sudo vgcreate vg-talos-setup01 /dev/sdb6
sudo lvcreate -L 145GiB -T vg-talos-setup01/thinpool

# Create thin logical volumes for nodes
sudo lvcreate -V 50GiB -T vg-talos-setup01/thinpool -n talos-setup01-node1
sudo lvcreate -V 50GiB -T vg-talos-setup01/thinpool -n talos-setup01-node2
sudo lvcreate -V 50GiB -T vg-talos-setup01/thinpool -n talos-setup01-node3

# Verify setup
sudo vgdisplay vg-talos-setup01
sudo lvs vg-talos-setup01
```

## Libvirt VM Definitions

The setup includes 3 Talos Linux VMs for PXE boot deployment.

**Network Definition:**
- `infra/libvirt/qemu/networks/01-setup-net.xml` - OVS bridge network

**VM Definitions:**

| VM Name | Role | CPUs | RAM | Primary Disk | Secondary Disk |
|---------|------|------|-----|--------------|----------------|
| talos-setup01-master-1 | Master | 4 | 4 GiB | `/dev/vg-talos-setup01/talos-setup01-node1` (50 GiB) | - |
| talos-setup01-worker-1 | Worker | 8 | 16 GiB | `/dev/vg-talos-setup01/talos-setup01-node2` (50 GiB) | `/dev/drbd-vg/drbd-1` |
| talos-setup01-worker-2 | Worker | 8 | 16 GiB | `/dev/vg-talos-setup01/talos-setup01-node3` (50 GiB) | `/dev/drbd-vg/drbd-2` |

**VM Configuration:**
- Boot order: PXE (network) → Hard disk
- Network: Connected to `01-setup-net` OVS bridge
- Disk I/O: Direct block device access (raw, no cache, native I/O)
- CPU: Host passthrough for optimal performance
- Console: SPICE graphics available

**Deploy VMs:**
```bash
# Define network (one time)
sudo virsh net-define infra/libvirt/qemu/networks/01-setup-net.xml
sudo virsh net-start 01-setup-net
sudo virsh net-autostart 01-setup-net

# Define and start VMs
sudo virsh define infra/libvirt/qemu/talos-setup01-master-1.xml
sudo virsh define infra/libvirt/qemu/talos-setup01-worker-1.xml
sudo virsh define infra/libvirt/qemu/talos-setup01-worker-2.xml

# Start VMs (they will PXE boot)
sudo virsh start talos-setup01-master-1
sudo virsh start talos-setup01-worker-1
sudo virsh start talos-setup01-worker-2

# Access console
sudo virsh console talos-setup01-master-1
```

## PXE Boot Flow

The setup uses a two-stage boot process:

1. **DHCP/PXE Stage** (DNSMasq):
   - Client requests IP via DHCP
   - DNSMasq detects client architecture (BIOS/UEFI)
   - Serves appropriate iPXE bootloader via TFTP (`undionly.kpxe` for BIOS, `ipxe.efi` for UEFI)

2. **iPXE/HTTP Stage** (Matchbox):
   - iPXE client identifies itself to DNSMasq
   - DNSMasq chainloads to Matchbox: `http://matchbox.setup01.local:8080/boot.ipxe`
   - Matchbox serves boot profile with Talos kernel and initramfs
   - Node boots Talos with configured kernel parameters

The `quay.io/poseidon/dnsmasq` container includes all necessary iPXE bootloaders, so no manual TFTP setup is required.

## Prerequisites

- Open vSwitch
- Docker
- Libvirt/KVM
- `ovs-docker` utility
- Container images:
  - `quay.io/poseidon/dnsmasq` (includes iPXE bootloaders)
  - `quay.io/poseidon/matchbox`

## Setup

```bash
cd ~/dev/github.com/kube-nfv/lab-deployments/01-setup/infra

# Create complete setup
make setup

# Or create individual components
make bridge    # OVS bridge
make dnsmasq   # DNSMasq container
make matchbox  # Matchbox PXE server
```

## Verification

```bash
cd ~/dev/github.com/kube-nfv/lab-deployments/01-setup/infra

# Verify setup
make verify
```

## Cleanup

```bash
cd ~/dev/github.com/kube-nfv/lab-deployments/01-setup/infra

# Clean all components
make clean

# Or clean individual components
make clean-matchbox  # Remove Matchbox
make clean-dnsmasq   # Remove DNSMasq
make clean-bridge    # Remove OVS bridge
```

## Troubleshooting

```bash
# Check DNSMasq logs
docker logs dnsmasq-01-setup

# Check NAT rules
sudo iptables -t nat -L -n -v | grep 10.0.10.0

# Check IP forwarding
sysctl net.ipv4.ip_forward
```

## Files

- `infra/Makefile` - Infrastructure automation
- `infra/dnsmasq.conf` - DNSMasq configuration
- `infra/matchbox-data/` - Matchbox data directory (gitignored)
- `infra/libvirt/qemu/networks/` - Libvirt network definitions
- `infra/libvirt/qemu/*.xml` - Libvirt VM definitions
- `tls/` - TLS certificates (Root CA + server certs)
- `talos/` - Talos ISO builder
- `README.md` - Documentation
