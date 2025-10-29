# Storage Testing Manifests

This directory contains Kubernetes manifests for testing the LINSTOR storage configuration.

## Test Resources

### Local Storage Tests
- `test-pvc-local.yaml` - PVC using the `local` storage class (non-replicated, node-local)
- `test-pod-local.yaml` - Test pod that uses the local PVC

### Replicated Storage Tests
- `test-pvc-replicated.yaml` - PVC using the `replicated` storage class (3-way DRBD replication)
- `test-pod-replicated.yaml` - Test pod that uses the replicated PVC

## Usage

### Test Local Storage

```bash
# Create PVC and Pod
kubectl apply -f test-pvc-local.yaml
kubectl apply -f test-pod-local.yaml

# Check PVC status
kubectl get pvc test-pvc-local

# Check PV was created
kubectl get pv

# Check pod status
kubectl get pod test-pod-local

# View pod logs
kubectl logs test-pod-local

# Check which node the pod is running on
kubectl get pod test-pod-local -o wide

# Verify the data written
kubectl exec test-pod-local -- cat /data/test.txt

# Cleanup
kubectl delete -f test-pod-local.yaml
kubectl delete -f test-pvc-local.yaml
```

### Test Replicated Storage

```bash
# Create PVC and Pod
kubectl apply -f test-pvc-replicated.yaml
kubectl apply -f test-pod-replicated.yaml

# Check PVC status
kubectl get pvc test-pvc-replicated

# Check PV was created
kubectl get pv

# Check pod status
kubectl get pod test-pod-replicated

# View pod logs
kubectl logs test-pod-replicated

# Check replication status via LINSTOR
kubectl exec -n piraeus-operator linstor-controller-5974f94fd7-6zs2p -- linstor resource list

# Verify the data written
kubectl exec test-pod-replicated -- cat /data/test.txt

# Cleanup
kubectl delete -f test-pod-replicated.yaml
kubectl delete -f test-pvc-replicated.yaml
```

## Testing Scenarios

### 1. Basic Provisioning
Verify that PVCs are bound and PVs are created successfully.

### 2. Data Persistence
Write data to the volume, delete the pod, recreate it with the same PVC, and verify data persists.

### 3. Volume Expansion
Try expanding a PVC (both storage classes have `allowVolumeExpansion: true`):
```bash
kubectl patch pvc test-pvc-local -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
```

### 4. Replication Testing (replicated storage only)
- Create a replicated volume
- Check DRBD status and verify replicas exist
- Simulate node failure scenarios

### 5. Performance Testing
Use tools like `fio` to benchmark storage performance.

## Notes

- **Local storage class**: Uses `WaitForFirstConsumer` binding mode, so PV is only created when a pod using the PVC is scheduled
- **Replicated storage class**: Uses `Immediate` binding mode, so PV is created as soon as PVC is created
- Both storage classes support volume expansion
