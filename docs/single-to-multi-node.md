# Single-Node Architecture & Multi-Node Migration

## Current State

The dockmaster cluster runs on a **single k3s server node** with all workloads co-located. This is a
GitOps-managed stack using Flux CD, with a three-tier dependency chain:

```
infrastructure --> observability --> apps
```

### Component Overview

| Layer          | Component             | Type        | Replicas | Storage         |
|----------------|-----------------------|-------------|----------|-----------------|
| Infrastructure | Traefik (k3s-bundled) | Deployment  | 1        | local-path PVC  |
| Infrastructure | Crowdsec LAPI         | Deployment  | 1        | 1Gi + 100Mi PVC |
| Infrastructure | Crowdsec Agent        | Deployment  | 1        | -               |
| Infrastructure | Headlamp              | Deployment  | 1        | -               |
| Observability  | Prometheus            | StatefulSet | 1        | 10Gi PVC        |
| Observability  | Grafana               | Deployment  | 1        | 2Gi PVC         |
| Observability  | Loki (SingleBinary)   | StatefulSet | 1        | 10Gi PVC        |
| Observability  | Alloy                 | DaemonSet   | 1*       | -               |
| Apps           | lab-home              | Deployment  | 1        | -               |
| Apps           | wordle-duel           | Deployment  | 1        | -               |
| Apps           | wordle-duel-service   | Deployment  | 1        | -               |
| Apps           | Redis                 | Deployment  | 1        | 1Gi PVC         |

\* Alloy is a DaemonSet — currently 1 pod because there is only 1 node.

### What Makes It Single-Node

Three architectural choices tie this cluster to a single node:

**1. local-path storage**

All PVCs use the k3s default `local-path` provisioner with `ReadWriteOnce` access mode. Data lives
on the node's local disk with no replication. If a pod gets rescheduled to a different node, it
cannot follow its data.

**2. hostPath + hostPort networking**

Traefik binds directly to the node's ports 80 and 443 via `hostPort`, with `service.type: ClusterIP`
(disabling the k3s klipper load balancer). This preserves real client source IPs, which Crowdsec
needs to function. Three components share the hostPath `/var/log/traefik`:

```
Traefik  -- writes -->  /var/log/traefik/access.log
Crowdsec Agent  -- reads -->  /var/log/traefik/access.log
Alloy  -- reads -->  /var/log/traefik/access.log
```

This only works when all three run on the same node.

**3. k3s with embedded SQLite**

The default k3s datastore is SQLite, which supports exactly one server node.

### What Already Works Multi-Node

- **Flux CD** — GitOps reconciliation is cluster-wide, not node-specific
- **All Deployments** — no nodeSelector, affinity, or tolerations are set; pods can schedule
  anywhere
- **Alloy** — already a DaemonSet, will automatically run on new nodes
- **Services** — all use ClusterIP; internal routing works across nodes
- **IngressRoutes** — Traefik CRDs are cluster-scoped resources
- **Secrets and ConfigMaps** — namespace-scoped, available to any node

---

## What Multi-Node Requires

### 1. Switch k3s datastore to embedded etcd

SQLite supports only a single server. Embedded etcd supports multiple server (control-plane) nodes
with built-in leader election and data replication.

```bash
# First server (converts from SQLite to etcd)
curl -sfL https://get.k3s.io | sh -s - server --cluster-init

# Additional server nodes
curl -sfL https://get.k3s.io | K3S_URL=https://<first-server>:6443 \
  K3S_TOKEN=<node-token> sh -s - server

# Agent (worker-only) nodes
curl -sfL https://get.k3s.io | K3S_URL=https://<server>:6443 \
  K3S_TOKEN=<node-token> sh -s -
```

Minimum 3 server nodes recommended for etcd quorum. A 2-server setup has no fault tolerance
advantage over 1.

**Impact:** bootstrap.sh must be updated to support both init and join flows.

### 2. Replace local-path with Longhorn

[Longhorn](https://longhorn.io/) is a distributed block storage system that integrates natively with
k3s. It replicates volumes across nodes, so pods can be rescheduled freely.

| What changes         | From          | To                          |
|----------------------|---------------|-----------------------------|
| Default StorageClass | local-path    | longhorn                    |
| Volume replication   | None          | 2-3 replicas across nodes   |
| PVC access mode      | ReadWriteOnce | ReadWriteOnce (still works) |
| Volume scheduling    | Node-bound    | Any node with a replica     |

**Affected PVCs:**

- Prometheus (10Gi)
- Grafana (2Gi)
- Loki (10Gi)
- Crowdsec LAPI data (1Gi) + config (100Mi)
- Redis (1Gi)
- Traefik acme.json (TLS certificates)

Migration path: install Longhorn, set it as default StorageClass, then recreate PVCs (backup data
first). Alternatively, use Longhorn's built-in backup/restore.

### 3. Replace klipper with MetalLB

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

- MetalLB HelmRelease + IPAddressPool (a range of IPs on the local network, or a single VIP)
- Remove `hostPort` from Traefik HelmChartConfig
- Change Traefik service type to LoadBalancer
- DNS A record points to the MetalLB VIP instead of a specific node IP
- Disable klipper: `--disable=servicelb` in k3s server flags

### 4. Centralize or distribute Traefik access logs

The hostPath `/var/log/traefik` sharing pattern breaks with multiple nodes. Each node's Traefik
instance writes to its own local filesystem. Options:

**Option A: Keep hostPath, adapt consumers (simplest)**

Traefik already runs one pod per node if configured as a DaemonSet (k3s default). Alloy is already a
DaemonSet. Convert Crowdsec Agent to a DaemonSet as well. Each node's agent reads its own node's
logs.

- Alloy: already works (DaemonSet reads local hostPath)
- Crowdsec Agent: change from Deployment to DaemonSet in HelmRelease
- Bootstrap: ensure `/var/log/traefik` exists with correct ownership on ALL nodes

**Option B: Ship logs to Loki, read from there**

Remove hostPath dependency entirely. Alloy already sends Traefik logs to Loki. Configure Crowdsec
to read from a centralized source instead of local files. More complex, but eliminates node-local
state.

**Recommendation:** Option A. It's the smallest change and keeps the proven log pipeline intact.

### 5. Update bootstrap script

The current `bootstrap.sh` assumes a single fresh node. For multi-node:

- Support `--cluster-init` for first server
- Support join token flow for additional servers and agents
- Create `/var/log/traefik` with `chown 65532:65532` on **every** node
- Install Longhorn prerequisites (open-iscsi) on every node
- Flux bootstrap only runs once (on the first server)

### 6. TLS certificate sharing

Traefik stores Let's Encrypt certificates in `acme.json` on a local-path PVC. With multiple Traefik
instances, each would try to issue its own certificate (hitting rate limits) or fail ACME
challenges.

Options:

- Use a Longhorn RWX (ReadWriteMany) volume shared across Traefik instances
- Use cert-manager as a separate certificate issuer, storing certs in Kubernetes Secrets (Traefik
  reads them natively) — this is the cleaner long-term solution
- Use a single Traefik instance for TLS termination (defeats the purpose of multi-node)

**Recommendation:** cert-manager. It's the standard Kubernetes approach, eliminates the acme.json
file entirely, and works naturally with any number of Traefik replicas.

---

## Migration Priority Order

| Step | Task                                   | Risk   | Downtime                      |
|------|----------------------------------------|--------|-------------------------------|
| 1    | Install Longhorn alongside local-path  | Low    | None                          |
| 2    | Migrate PVCs to Longhorn               | Medium | Per-service restart           |
| 3    | Switch k3s to embedded etcd            | High   | Cluster restart               |
| 4    | Join additional server nodes           | Low    | None                          |
| 5    | Install MetalLB, reconfigure Traefik   | Medium | Brief (DNS + Traefik restart) |
| 6    | Install cert-manager, remove acme.json | Medium | Brief (cert reissue)          |
| 7    | Convert Crowdsec Agent to DaemonSet    | Low    | None                          |
| 8    | Update bootstrap.sh for multi-node     | Low    | None                          |

Steps 1-2 can be done on the existing single node before adding more nodes. Step 3 is the point of
no return — after converting to etcd, the cluster is ready to accept new members.

---

## What Stays the Same

- All application Deployments and Services (no manifest changes needed)
- Flux CD Kustomization chain and GitRepository source
- IngressRoutes, middlewares, and TLS configuration (routes are Traefik CRDs, cluster-scoped)
- Crowdsec LAPI, bouncer plugin, and middleware (only the Agent deployment type changes)
- Grafana dashboards, Prometheus scrape configs, Loki retention settings
- All Secrets and ConfigMaps
- Alloy DaemonSet and its ConfigMap
