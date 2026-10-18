# Network boot test path

Edge nodes in this setup are provisioned from an Image Factory ISO (README Phase 5). This
document covers the alternative under development: a node network-boots Talos through iPXE
from a script server, over mutual TLS. Everything here runs locally in Docker, on macOS or
Linux, so the boot chain can be exercised without hardware.

## Boot flow

```
 VM (UEFI)          dnsmasq                      script server
    │  DHCP  ───────►  │  bootfile <arch>/ipxe.efi
    │  TFTP  ───────►  │  ipxe.efi (CA + client cert built in)
    │
 iPXE
    │  DHCP  ───────►  │  bootfile https://ipxe.setup02.local/boot.ipxe
    │  HTTPS, mTLS  ─────────────────────────────►  │  boot.ipxe
    │  HTTPS, mTLS  ─────────────────────────────►  │  Talos kernel + initramfs
    ▼
 Talos (maintenance mode until a machine config is supplied)
```

dnsmasq tells the two DHCP rounds apart by the `iPXE` user class: UEFI firmware gets the
iPXE binary, iPXE itself gets the script URL.

## Trust model

| Stage | Authentication |
|---|---|
| iPXE script and boot assets | Mutual TLS. The server certificate and a client certificate shared by all nodes of one edge site are issued by the Boot CA |
| Machine config (`talos.config=`) | Not built yet. Planned: Talos machine config OAuth2 device flow, so an operator approves each node |

The client certificate only shows that the request comes from a genuine iPXE binary for
that site. Anyone who can download the binary from the site's TFTP server can extract it,
so it is not a node identity. The boot script and Talos assets carry nothing secret; the
machine config does, which is why per-node approval belongs at that stage.

The lab has one private root CA with two intermediates: the Boot CA for network boot and
the Cluster CA, which cert-manager holds to issue certificates inside the cluster. The
root and Boot CA keys never enter the cluster. iPXE trusts the Boot CA, not the root, so
a leaked Cluster CA key cannot impersonate the script server.

iPXE trusts only fingerprints compiled into the binary (`TRUST=`), so the Boot CA and the
client certificate cannot be delivered over DHCP. A node's serial number, UUID and MAC
(`${serial}`, `${uuid}`, `${net0/mac}` in iPXE) can be sent to the script server to
select what to boot, but the node reports them about itself, so they identify a node
without authenticating it.

## Components

| Path | Contents |
|---|---|
| `tls/` | Root CA, Boot CA, Cluster CA, iPXE script server certificate, iPXE client certificate. Keys are SOPS-encrypted in place. `make ca`, `make boot-ca`, `make cluster-ca`, `make ipxe-server`, `make ipxe-client`, `make verify` |
| `ipxe/` | Builds `_out/ipxe/<arch>/ipxe.efi` in Docker with `TRUST=boot-ca.crt` and the client certificate and key embedded. `make build`, `ARCH=arm64` (default) or `x86_64` |
| `infra/pxe/` | Docker network, dnsmasq, a network-booting arm64 QEMU VM, and an nginx stand-in for the script server |

The built `ipxe.efi` contains the client private key unencrypted. It lives under `_out/`,
which is gitignored; treat it as a secret.

Leaf certificates are valid for one year. Re-issue the client certificate before it
expires and rebuild `ipxe.efi`, or nodes stop booting.

## Test path

The Docker network `setup02-pxe` uses `10.0.20.0/24`:

| Address | Role |
|---|---|
| `.1` | Gateway, NAT to the internet |
| `.2` | dnsmasq: DHCP pool `.100`-`.200`, DNS for `setup02.local`, TFTP for `ipxe.efi` |
| `.3` | Script server, `ipxe.setup02.local` |
| `.4` | Container hosting the VM; the VM itself takes a DHCP address |

Docker allocates only from `.0/28`, so fixed addresses and the DHCP pool do not collide.

Run it end to end with the nginx stand-in, which serves Talos assets downloaded from
Image Factory:

```sh
make -C ipxe build
cd infra/pxe
make setup          # network + dnsmasq
make test-assets    # Talos kernel, initramfs and boot.ipxe into _out/pxe-test
make test-server    # nginx at .3, requires a client certificate signed by the CA
make vm             # network-booting VM
make console        # serial console, detach with Ctrl-P Ctrl-Q
make clean          # remove everything, including the VM disk
```

A successful run ends with Talos in maintenance mode, printing a
`talosctl apply-config --insecure` hint, and the nginx log showing every request with the
client certificate's subject and `verify=SUCCESS`. Docker on Apple silicon has no KVM, so
the VM runs emulated: expect several minutes from power-on to maintenance mode.

The test assets use the vanilla Image Factory schematic. The edge schematic in
`talos/schematics/edge.yaml` includes `intel-ucode`, which has no arm64 build.

## Script server requirements

A real script server replaces the nginx stand-in at `.3`:

```sh
docker run --network setup02-pxe --ip 10.0.20.3 ...
```

It must:

- serve HTTPS on port 443 for `ipxe.setup02.local`, with the `ipxe-server` certificate;
- send the Boot CA certificate after the leaf. iPXE holds only the Boot CA fingerprint,
  and without it in the chain iPXE tries to fetch a cross-signed certificate from
  `ca.ipxe.org` and stalls at `[XCRT ...]`;
- require a client certificate, verify it against `tls/boot-ca.crt` plus `tls/ca.crt`, and
  accept only clients issued by the Boot CA, since the root also signs the Cluster CA;
- serve the kernel and initramfs itself, or from another host whose certificate is issued
  by the Boot CA. iPXE trusts nothing else, so Image Factory URLs cannot be used directly.

Relative URLs in `boot.ipxe` resolve against the script's own URL.

## Pitfalls

- The VM container bridges its `eth0` and a tap device. Docker's bridge sends the VM's
  broadcasts back into `eth0`, so the in-container bridge learns the VM's MAC on the wrong
  port and drops every unicast frame to the VM: DHCP succeeds, TFTP times out.
  `vm-entrypoint.sh` pins the MAC to the tap with a static, sticky FDB entry.
- QEMU's virtio-net needs `romfile=` on arm64; otherwise it looks for an x86 option ROM
  and fails to start.
- Only iPXE 2.0.0 has been tested. TLS handshakes in an emulated VM take seconds, not
  milliseconds.
