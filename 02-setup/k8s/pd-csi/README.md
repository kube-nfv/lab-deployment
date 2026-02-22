# GCP PD CSI Driver

Provides persistent disk provisioning for workloads scheduled on GCP cloud nodes.

## Deployment

```bash
kubectl apply -k 02-setup/k8s/pd-csi/
```

This single command:
1. Creates the `gce-pd-csi-driver` namespace with `pod-security.kubernetes.io/enforce: privileged`
2. Deploys the upstream overlay from `kubernetes-sigs/gcp-compute-persistent-disk-csi-driver`
3. Applies kustomize patches (see below)
4. Creates the `pd-standard` StorageClass

## Kustomize patches applied

| Patch | File | Why |
|-------|------|-----|
| `csi-gce-pd-node` DaemonSet `nodeSelector: node.kubernetes.io/location: cloud` | `node-daemonset-patch.yaml` | Prevents the node DaemonSet from scheduling on the edge node |
| `csi-gce-pd-node` volume `udev-rules-etc`: `hostPath /etc/udev` → `emptyDir` | inline JSON patch in `kustomization.yaml` | `/etc/udev` does not exist on Talos Linux (immutable OS). The driver never reads or writes this path at runtime — `udevadm` contacts host udevd via `/run/udev` (socket), which does exist on Talos |
| `csi-gce-pd-controller` `nodeSelector: node.kubernetes.io/location: cloud` | `controller-deployment-patch.yaml` | Controller must run on a GCE node to reach the instance metadata service for auth |
| `csi-gce-pd-controller` removes `GOOGLE_APPLICATION_CREDENTIALS` env, `cloud-sa-volume` mount and volume | inline JSON patch in `kustomization.yaml` | SA key creation is blocked by org policy (`constraints/iam.disableServiceAccountKeyCreation`). The controller authenticates via Application Default Credentials (ADC), falling back to the GCE instance metadata service using the SA attached to the GCE VM |

## IAM requirements

The GCP service account (`setup02-cluster-pd-csi`) needs three IAM bindings (all managed in Terraform):

| Role | Purpose |
|------|---------|
| `roles/compute.storageAdmin` | Create, delete, get, list persistent disks |
| `roles/iam.serviceAccountUser` | Impersonate the SA for disk operations |
| Custom role `pdCsiNodeOps` (`compute.instances.{get,attachDisk,detachDisk}`) | Look up instances and attach/detach disks — not included in `storageAdmin` |

The GCE instances must also have the SA attached with `cloud-platform` scope (set in Terraform `service_account` block).

## Updating the upstream version

Edit the `?ref=` tag in `kustomization.yaml`:

```yaml
resources:
  - https://github.com/kubernetes-sigs/gcp-compute-persistent-disk-csi-driver/deploy/kubernetes/overlays/stable-master?ref=v1.23.3
```

After updating, re-verify the volume index of `udev-rules-etc` in the rendered manifest before applying:

```bash
kubectl kustomize 02-setup/k8s/pd-csi/ | python3 -c "
import sys, yaml
docs = list(yaml.safe_load_all(sys.stdin))
for doc in docs:
    if doc and doc.get('kind') == 'DaemonSet' and doc['metadata']['name'] == 'csi-gce-pd-node':
        for i, v in enumerate(doc['spec']['template']['spec']['volumes']):
            print(f'[{i}] {v[\"name\"]}:', v.get('hostPath', v.get('emptyDir', '?')))
        break
"
```

The `udev-rules-etc` volume must show `emptyDir`. If its index changed, update the JSON patch in `kustomization.yaml` accordingly.

## Notes

- `/lib/udev`, `/lib/modules`, `/run/udev`, `/sys`, `/dev` all exist on Talos and are used correctly by the driver
- `WaitForFirstConsumer` binding in the StorageClass ensures PVs are created in the same zone as the scheduled pod
- The `csi-gce-pd-node-win` DaemonSet (Windows) is deployed by the upstream overlay but schedules zero pods since there are no Windows nodes — it is harmless
