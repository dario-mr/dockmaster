# Single-Node Architecture & Multi-Node Migration

## Current State

The dockmaster cluster runs on a **single k3s server node** with all workloads co-located. This is a
GitOps-managed stack using Flux CD, with a three-tier dependency chain:

```
infrastructure --> observability --> apps
```

Progress so far toward multi-node:

- Longhorn is installed, Git-managed, and the default StorageClass
- Redis, Crowdsec LAPI, Grafana, Loki, and Prometheus now use Longhorn-backed PVCs
- Traefik TLS now comes from cert-manager and a shared default `TLSStore` certificate
- The live cluster has already been converted from SQLite to embedded etcd
- `bootstrap.sh` bootstraps the first server with embedded etcd, and `join-node.sh` adds server or
  agent nodes
- both scripts install Longhorn prerequisites, raise inotify limits, and prepare `/var/log/traefik`
  on every node

### Component Overview

| Layer          | Component             | Type        | Replicas | Storage                  |
|----------------|-----------------------|-------------|----------|--------------------------|
| Infrastructure | Traefik (k3s-bundled) | Deployment  | 1        | hostPath logs only       |
| Infrastructure | Crowdsec LAPI         | Deployment  | 1        | 1Gi + 100Mi Longhorn PVC |
| Infrastructure | Crowdsec Agent        | DaemonSet   | 1*       | -                        |
| Infrastructure | Headlamp              | Deployment  | 1        | -                        |
| Observability  | Prometheus            | StatefulSet | 1        | 10Gi Longhorn PVC        |
| Observability  | Grafana               | Deployment  | 1        | 2Gi Longhorn PVC         |
| Observability  | Loki (SingleBinary)   | StatefulSet | 1        | 5Gi Longhorn PVC         |
| Observability  | Alloy                 | DaemonSet   | 1*       | -                        |
| Apps           | lab-home              | Deployment  | 1        | -                        |
| Apps           | wordle-duel           | Deployment  | 1        | -                        |
| Apps           | wordle-duel-service   | Deployment  | 1        | -                        |
| Apps           | Redis                 | Deployment  | 1        | 1Gi Longhorn PVC         |

\* Alloy and Crowdsec Agent are DaemonSets — currently 1 pod each because there is only 1 node.

### What Makes It Single-Node

Two architectural choices still tie this cluster to a single node:

**1. hostPath + hostPort networking**

Traefik binds directly to the node's ports 80 and 443 via `hostPort`, with `service.type: ClusterIP`
(disabling the k3s klipper load balancer). This preserves real client source IPs, which Crowdsec
needs to function. Three components share the hostPath `/var/log/traefik`:

```
Traefik  -- writes -->  /var/log/traefik/access.log
Crowdsec Agent  -- reads -->  /var/log/traefik/access.log
Alloy  -- reads -->  /var/log/traefik/access.log
```

This only works when all three run on the same node.

**2. Single server count**

The cluster now runs on embedded etcd, so the datastore is ready for multiple server nodes. It is
still effectively single-node only because there is currently just one server in the cluster.

### What Already Works Multi-Node

- **Flux CD** — reconciliation is cluster-wide
- **Workloads and Services** — no node pinning is in place, and internal ClusterIP routing already
  works
- **Alloy and Crowdsec Agent** — already run as DaemonSets where needed
- **IngressRoutes, Secrets, and ConfigMaps** — already work cluster-wide

---

## What Multi-Node Requires

### Finish replacing local-path with Longhorn

[Longhorn](https://longhorn.io/) is already installed and all major app and observability PVCs are
already on Longhorn. The default StorageClass has also been switched to Longhorn. The remaining
future-facing task is not PVC migration anymore, but increasing Longhorn replica count once
multiple nodes exist.

### Replace klipper with MetalLB

klipper (k3s built-in LB) uses svclb DaemonSet pods that SNAT traffic, hiding real client IPs. The
current workaround (hostPort + ClusterIP) only works on a single node.

[MetalLB](https://metallb.universe.tf/) in L2 mode provides a proper LoadBalancer service that
preserves source IPs via `externalTrafficPolicy: Local`.

| What changes           | From                       | To                              |
|------------------------|----------------------------|---------------------------------|
| Traefik service type   | ClusterIP + hostPort       | LoadBalancer                    |
| Load balancer          | None (direct node binding) | MetalLB L2                      |
| Client IP preservation | hostPort (inherent)        | externalTrafficPolicy: Local    |
| Port binding           | Single node ports 80/443   | Virtual IP, any node can answer |

**Requires:**

- MetalLB HelmRelease + IPAddressPool
- Remove `hostPort` from Traefik HelmChartConfig
- Change Traefik service type to LoadBalancer
- Point DNS at the MetalLB VIP
- Disable klipper: `--disable=servicelb` in k3s server flags

### Centralize or distribute Traefik access logs

The hostPath `/var/log/traefik` sharing pattern breaks with multiple nodes. Each node's Traefik
instance writes to its own local filesystem.

**Option A: Keep hostPath, adapt consumers (simplest)**

Traefik already runs one pod per node if configured as a DaemonSet (k3s default). Alloy and
Crowdsec Agent already run in the right shape, so each node can read its own local logs.

- Alloy: already works (DaemonSet reads local hostPath)
- Crowdsec Agent: already runs as a DaemonSet
- Bootstrap: ensure `/var/log/traefik` exists with correct ownership on ALL nodes

**Option B: Ship logs to Loki, read from there**

Remove hostPath dependency entirely by having Crowdsec read from a centralized source instead of
local files. More complex, but eliminates node-local log state.

**Recommendation:** Option A. It's the smallest change and keeps the proven log pipeline intact.

Current status: prepared. Crowdsec Agent is already running as a DaemonSet, so future nodes will
each get their own local log reader automatically. This pattern has not been validated on multiple
nodes yet because the cluster still has only one node and still depends on the local
`/var/log/traefik` hostPath.

---

## Migration Priority Order

| Step | Task                                   | Risk   | Downtime                      |
|------|----------------------------------------|--------|-------------------------------|
| 1    | Install Longhorn alongside local-path  | Done   | None                          |
| 2    | Migrate remaining PVCs to Longhorn     | Done   | Per-service restart           |
| 3    | Switch k3s to embedded etcd            | Done   | Cluster restart               |
| 4    | Join additional server nodes           | Low    | None                          |
| 5    | Install MetalLB, reconfigure Traefik   | Medium | Brief (DNS + Traefik restart) |
| 6    | Install cert-manager, remove acme.json | Done   | Brief (cert reissue)          |
| 7    | Convert Crowdsec Agent to DaemonSet    | Done   | None                          |
| 8    | Update bootstrap/join scripts          | Done   | None                          |

Steps 1, 2, 3, 6, 7, and 8 are complete. The cluster is now ready to accept additional server or
agent nodes, and Traefik TLS no longer depends on node-local certificate storage. The remaining
major work is networking for multi-node ingress.
