# SR-IOV Network Operator on Talos Linux

## Overview

This document explains the problem with running the upstream `sriov-network-operator` on Talos Linux, the solution implemented in the [kube-nfv/sriov-network-operator](https://github.com/kube-nfv/sriov-network-operator) fork, and the Talos-specific configuration required in this repository.

---

## The Problem: Hardcoded `/etc` Paths

The `sriov-network-config-daemon` writes runtime state and configuration to paths under `/etc/`:

| Path | Purpose |
|---|---|
| `/etc/sriov-operator/` | Operator runtime config (applied PF state, switchdev config) |
| `/etc/udev/rules.d/` | Udev rules for NIC management (NM unmanaged, VF representor naming) |
| `/etc/udev/disable-nm-sriov.sh` | Helper script referenced by udev NM rule |
| `/etc/udev/switchdev-vf-link-name.sh` | Helper script referenced by udev switchdev rule |
| `/etc/systemd/system/` | Systemd units (systemd config mode only) |

On Talos Linux, `/etc` is a read-only squashfs filesystem. All writable state lives under `/var`. The writable equivalent of `/etc` on Talos is `/var/etc`, with selected paths bind-mounted back to `/etc` by the OS at boot.

Attempting to run the upstream daemon on Talos results in immediate write failures.

---

## Solution

The fork introduces a configurable `hostEtcPath` (and `hostUdevPath`) that propagates from the Helm chart through the operator down to the daemon, replacing the assumption that the host's `/etc` is writable.

The approach uses a **volume mount shadow**: a `hostPath` volume mounted at `/host/etc` inside the daemon container, pointing to `hostEtcPath` on the actual host. All existing daemon write paths (`/host/etc/...`) remain unchanged in code — the volume mount transparently redirects them to the correct writable location.

### Why not change every hardcoded path in the daemon?

The daemon code has dozens of `/etc/...` write targets spread across multiple packages. Changing them all would require a large invasive refactor with high regression risk. The volume mount approach isolates the change to the DaemonSet manifest and operator controller — a single, reviewable, reversible change.

---

## Changes in the Fork

### 1. Helm Chart — `deployment/sriov-network-operator-chart/`

**`values.yaml`** — two new values with sane defaults:
```yaml
operator:
  hostEtcPath: "/etc"
  hostUdevPath: "/etc/udev"
```

**`templates/operator.yaml`** — passed as env vars to the operator Deployment:
```yaml
- name: SRIOV_HOST_ETC_PATH
  value: {{ .Values.operator.hostEtcPath }}
- name: SRIOV_HOST_UDEV_PATH
  value: {{ .Values.operator.hostUdevPath }}
```

### 2. Operator Controller — `controllers/sriovoperatorconfig_controller.go`

`syncConfigDaemonSet()` reads the env vars and injects them into the DaemonSet template render context:
```go
envHostEtcPath := os.Getenv("SRIOV_HOST_ETC_PATH")
data.Data["HostEtcPath"] = envHostEtcPath  // defaults to "/etc"

envHostUdevPath := os.Getenv("SRIOV_HOST_UDEV_PATH")
data.Data["HostUdevPath"] = envHostUdevPath  // defaults to "/etc/udev"
```

### 3. DaemonSet Manifest — `bindata/manifests/daemon/daemonset.yaml`

Two additions:

**Env vars** — so the daemon process itself knows its configured paths (used for udev rule content):
```yaml
- name: SRIOV_HOST_ETC_PATH
  value: "{{.HostEtcPath}}"
- name: SRIOV_HOST_UDEV_PATH
  value: "{{.HostUdevPath}}"
```

**Volume mount shadow** — the key mechanism. Mounts `hostEtcPath` from the host at `/host/etc` inside the container, shadowing the parent `/host` volume for that subtree:
```yaml
volumeMounts:
  - name: host-etc
    mountPath: /host/etc
volumes:
  - name: host-etc
    hostPath:
      path: {{.HostEtcPath}}
```

On Talos with `hostEtcPath=/var/etc`: the daemon writes to `/host/etc/sriov-operator/...` which resolves to host path `/var/etc/sriov-operator/...` — writable.

### 4. Udev Rule Strings — `pkg/consts/constants.go`

`NMUdevRule` and `SwitchdevUdevRule` were `const` strings with hardcoded `/etc/udev/...` script paths embedded in the udev rule syntax. Since a `const` cannot be built from a runtime value, they were converted to `var` initialized in `init()`:

```go
var NMUdevRule string
var SwitchdevUdevRule string

func init() {
    udevPath := os.Getenv("SRIOV_HOST_UDEV_PATH")  // e.g. "/var/etc/udev"
    NMUdevRule = `... IMPORT{program}="` + udevPath + `/disable-nm-sriov.sh ..."`
    SwitchdevUdevRule = `... IMPORT{program}="` + udevPath + `/switchdev-vf-link-name.sh ..."`
}
```

The udev rules written by the daemon embed the path to helper scripts. If the path is wrong, the kernel cannot execute the script when a network device event fires.

### 5. Udev Directory Creation

Two places needed `mkdir -p` guards because the udev directory may not exist when the daemon initializes for the first time:

- **`pkg/host/internal/udev/udev.go`** — `PrepareVFRepUdevRule()` adds `os.MkdirAll` before copying the script.
- **`bindata/scripts/udev-find-sriov-pf.sh`** — script uses `SRIOV_HOST_UDEV_PATH` and creates the directory before writing `disable-nm-sriov.sh`.

---

## Talos-Specific Configuration

### Helm Values Override — `02-setup/k8s/sriov-network-operator/values.yaml`

```yaml
operator:
  hostEtcPath: "/var/etc"
  hostUdevPath: "/var/etc/udev"
```

This is the only value change required for Talos. Everything else (the volume mount, the env var propagation, the udev rule paths) follows automatically.

### Udev Rules for Switchdev VF Representor Naming — `02-setup/talos/patches/x11spl-f-worker-1-node.yaml`

```yaml
machine:
  files:
    - path: /var/etc/udev/switchdev-vf-link-name.sh
      permissions: 0755
      op: create
      content: |
        #!/bin/bash
        PORT="$1"
        echo "NUMBER=${PORT##pf*vf}"
  udev:
    rules:
      - 'SUBSYSTEM=="net", ACTION=="add|move", ATTRS{phys_switch_id}=="984bf30003ebc008", ATTR{phys_port_name}=="pf0vf*", IMPORT{program}="/var/etc/udev/switchdev-vf-link-name.sh $attr{phys_port_name}", NAME="ens9f0np0_$env{NUMBER}"'
      - 'SUBSYSTEM=="net", ACTION=="add|move", ATTRS{phys_switch_id}=="984bf30003ebc008", ATTR{phys_port_name}=="pf1vf*", IMPORT{program}="/var/etc/udev/switchdev-vf-link-name.sh $attr{phys_port_name}", NAME="ens9f1np1_$env{NUMBER}"'
```

#### Why these rules are needed

When switchdev/eSwitch mode is enabled on a Mellanox ConnectX NIC, the kernel creates VF representor netdevs with unstable kernel-assigned names. These udev rules rename them to predictable names (`ens9f0np0_0`, `ens9f0np0_1`, ...) based on the VF index.

#### Why static Talos rules and not daemon-written rules

The daemon dynamically writes an equivalent `SwitchdevUdevRule` to `/var/etc/udev/rules.d/` when a `SriovNetworkNodePolicy` with switchdev mode is applied. However, udev on Talos reads rules only from `/etc/udev/rules.d/` and `/usr/lib/udev/rules.d/` — **not** from `/var/etc/udev/rules.d/`. The daemon's written rules are therefore silently ignored by udev on Talos.

Talos machine config udev rules are written to `/usr/lib/udev/rules.d/99-talos.rules`, which udev does read. Static rules also activate at boot before any operator policy exists.

#### phys_switch_id

`984bf30003ebc008` is the hardware-stable switch identifier for the Mellanox ConnectX card in `setup02-x11spl-f-worker-1`. Both ports (`ens9f0np0` on PF0, `ens9f1np1` on PF1) share the same `phys_switch_id` — it identifies the card, not the port. The `phys_port_name` attribute (`pf0vf*` / `pf1vf*`) distinguishes between ports.

---

## Runtime Behavior Summary

| Component | Default (non-Talos) | Talos |
|---|---|---|
| Daemon writes sriov config | `/host/etc/sriov-operator/` | `/host/etc/sriov-operator/` → host `/var/etc/sriov-operator/` |
| Daemon writes udev rules | `/host/etc/udev/rules.d/` → host `/etc/udev/rules.d/` (read by udev) | `/host/etc/udev/rules.d/` → host `/var/etc/udev/rules.d/` (ignored by udev) |
| VF representor naming | Daemon-written `SwitchdevUdevRule` | Static Talos machine config rule in `/usr/lib/udev/rules.d/99-talos.rules` |
| NM unmanaged rule | `disable-nm-sriov.sh` script + rule | Rule written but irrelevant (no NetworkManager on Talos) |
