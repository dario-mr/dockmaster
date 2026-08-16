# Longhorn

[Longhorn](https://longhorn.io/) is a distributed block-storage system for Kubernetes. It implements
Kubernetes' Container Storage Interface (CSI), so workloads can request storage with a
PersistentVolumeClaim (PVC) and Longhorn provisions and attaches the corresponding volume to the
node running the workload.

Longhorn is designed to make persistent storage independent of a particular pod or node. It can also
provide volume replicas, snapshots, backups, and volume expansion. Those capabilities are available
in Longhorn, but the current configuration intentionally uses a single replica while the cluster has
only one node.

## How dockmaster installs and manages Longhorn

Longhorn is managed as part of the infrastructure layer and is reconciled by Flux:

1. `infrastructure/longhorn/namespace.yaml` creates the `longhorn-system` namespace.
2. `infrastructure/longhorn/helmrepository.yaml` points Flux at the Longhorn chart repository.
3. `infrastructure/longhorn/helmrelease.yaml` installs Longhorn chart version `1.12.0` and
   reconciles it every 30 minutes.
4. `infrastructure/longhorn/helmrelease.yaml` enables the chart-owned default `longhorn`
   StorageClass.
5. `infrastructure/kustomization.yaml` includes the Longhorn Helm resources in the infrastructure
   layer; the chart is the only declarative StorageClass owner.

The production Flux Kustomization applies `./infrastructure` before observability and apps. Both
layers depend on infrastructure, which ensures that the storage system and StorageClass exist before
workloads request their PVCs.

The node setup scripts install and enable `open-iscsi`/`iscsid`, which Longhorn needs for its block
volume attachments:

- `scripts/bootstrap.sh` prepares the first server.
- `scripts/join-node.sh` prepares additional server or agent nodes.

## StorageClass settings in this repository

The `longhorn` StorageClass is the cluster default and uses Longhorn's CSI provisioner,
`driver.longhorn.io`. Its relevant settings are:

| Setting                       | Repository value | Effect                                                        |
|-------------------------------|------------------|---------------------------------------------------------------|
| Default class                 | `true`           | PVCs without an explicit class use Longhorn.                  |
| Volume expansion              | Enabled          | PVC-backed volumes can be enlarged.                           |
| Access mode used by workloads | `ReadWriteOnce`  | A volume is mounted read/write by one node at a time.         |
| Reclaim policy                | `Delete`         | Deleting a PVC can delete its dynamically provisioned volume. |
| Binding mode                  | `Immediate`      | Provisioning starts when the PVC is created.                  |
| Replica count                 | `1`              | There is currently one Longhorn data replica per volume.      |

The k3s `local-path` StorageClass remains defined for compatibility, but it is explicitly not the
default. The important persistent workloads in this repository explicitly select `longhorn`.

## What uses Longhorn here

| Workload                        | PVC/storage                   | Manifest or configuration                                                                                    |
|---------------------------------|-------------------------------|--------------------------------------------------------------------------------------------------------------|
| CrowdSec LAPI                   | `1Gi` data and `100Mi` config | `infrastructure/crowdsec/pvc-*-longhorn.yaml`; consumed as existing claims by the CrowdSec HelmRelease.      |
| Prometheus                      | `10Gi`                        | `observability/kube-prometheus-stack/helmrelease.yaml`; its volume claim template uses `longhorn`.           |
| Grafana                         | `2Gi`                         | `observability/kube-prometheus-stack/helmrelease.yaml`.                                                      |
| Loki                            | `5Gi`                         | `observability/loki/helmrelease.yaml`; SingleBinary Loki stores data on a Longhorn-backed filesystem volume. |

The frontend and API deployments do not currently need persistent volumes. Traefik access logs,
CrowdSec agent input, and Alloy input also use the node-local `/var/log/traefik` `hostPath`; that
log path is separate from Longhorn storage.

## Benefits for this repository

Longhorn provides several practical benefits to dockmaster:

- **Data survives pod replacement.** CrowdSec state and observability data are stored outside the
  containers, so those workloads can be recreated without automatically losing their data. Redis is
  intentionally ephemeral because it only holds disposable sessions, locks, and Pub/Sub state.
- **Storage is declared with the workload.** PVCs and their storage policy live in Git and are
  applied through Flux, making storage reproducible along with the rest of the cluster.
- **Workloads are less tied to local disks.** With more than one node, a Longhorn volume can be
  attached to the node where its pod is scheduled instead of depending on a directory that exists
  only on the original node.
- **The cluster has a path to storage redundancy.** Longhorn can keep multiple replicas across
  nodes. Raising the configured replica count is a future multi-node step documented in
  `docs/single-to-multi-node.md`.
- **Capacity can be adjusted without replacing the volume.** The StorageClass allows volume
  expansion when a workload's PVC needs more space.

## Current limitations and important expectations

The cluster currently runs on one k3s server node. Longhorn is installed and all major application
and observability PVCs use it, but the configured replica count is `1` in:

- `infrastructure/longhorn/helmrelease.yaml`

The Longhorn chart is the sole declarative owner of the default StorageClass.

Therefore Longhorn currently provides persistent, CSI-managed storage, not protection from failure
of the only node or its disk. A second node and a higher replica count are required for node-level
storage redundancy. The replica change should be planned with enough disk capacity on each node and
validated against the workloads' `ReadWriteOnce` access pattern.

Longhorn also does not replace the repository's node-local log setup. Multi-node operation still
requires the `/var/log/traefik` hostPath readers and writers to be placed appropriately, as
described in `docs/single-to-multi-node.md`.

## Useful checks and access

Check the StorageClass and PVCs:

```bash
kubectl get storageclass longhorn
kubectl get pvc -A
```

Inspect Longhorn volumes and components:

```bash
kubectl -n longhorn-system get pods
kubectl -n longhorn-system get volumes.longhorn.io
```

The Longhorn web UI can be accessed through a temporary tunnel:

```bash
# on the VPS
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80

# on your machine
ssh -L 8080:localhost:8080 dariolab
```

Then open `http://localhost:8080`.
