# Single-Node Architecture & Multi-Node Migration

## Current State

The dockmaster cluster runs on a **single k3s server node** with all workloads co-located. This is a
GitOps-managed stack using Flux CD, with a three-tier dependency chain:

```
infrastructure --> observability --> apps
```

Progress so far toward multi-node:

- Longhorn is installed and healthy via Flux in `longhorn-system`
- StorageClasses are now managed explicitly in Git
- Redis has already been migrated to a Longhorn-backed PVC
- Crowdsec LAPI data and config are now targeted to Longhorn-backed PVCs
- Grafana is now targeted to a Longhorn-backed PVC
- Loki is now targeted to a Longhorn-backed PVC
- Prometheus is now targeted to a Longhorn-backed PVC
- Traefik TLS is now backed by cert-manager and a shared default `TLSStore` certificate
- The live cluster has already been converted from SQLite to embedded etcd
- `bootstrap.sh` now always creates the first server with embedded etcd (`--cluster-init`)
- `join-node.sh` now handles additional node joins as either a server or an agent
- both scripts install Longhorn prerequisites (`open-iscsi`), raise inotify limits, and prepare
  `/var/log/traefik` on every node
- cert-manager is now introduced for Traefik TLS, with staging and production issuers plus a shared
  default `TLSStore` certificate prepared in `kube-system`

### Component Overview

| Layer          | Component             | Type        | Replicas | Storage                  |
|----------------|-----------------------|-------------|----------|--------------------------|
| Infrastructure | Traefik (k3s-bundled) | Deployment  | 1        | local-path PVC           |
| Infrastructure | Crowdsec LAPI         | Deployment  | 1        | 1Gi + 100Mi Longhorn PVC |
| Infrastructure | Crowdsec Agent        | Deployment  | 1        | -                        |
| Infrastructure | Headlamp              | Deployment  | 1        | -                        |
| Observability  | Prometheus            | StatefulSet | 1        | 10Gi Longhorn PVC        |
| Observability  | Grafana               | Deployment  | 1        | 2Gi Longhorn PVC         |
| Observability  | Loki (SingleBinary)   | StatefulSet | 1        | 5Gi Longhorn PVC         |
| Observability  | Alloy                 | DaemonSet   | 1*       | -                        |
| Apps           | lab-home              | Deployment  | 1        | -                        |
| Apps           | wordle-duel           | Deployment  | 1        | -                        |
| Apps           | wordle-duel-service   | Deployment  | 1        | -                        |
| Apps           | Redis                 | Deployment  | 1        | 1Gi Longhorn PVC         |

\* Alloy is a DaemonSet — currently 1 pod because there is only 1 node.

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
# First server
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

**Current status:** done. The live cluster is already running on embedded etcd, and the scripts now
cover both first-server setup and node joins for fresh nodes.

### 2. Finish replacing local-path with Longhorn

[Longhorn](https://longhorn.io/) is a distributed block storage system that integrates natively with
k3s. It replicates volumes across nodes, so pods can be rescheduled freely.

| What changes         | From               | To                          |
|----------------------|--------------------|-----------------------------|
| Default StorageClass | local-path         | longhorn                    |
| Volume replication   | None / single copy | 2-3 replicas across nodes   |
| PVC access mode      | ReadWriteOnce      | ReadWriteOnce (still works) |
| Volume scheduling    | Node-bound         | Any node with a replica     |

**PVC status:**

- Done: Redis (1Gi)
- Done: Crowdsec LAPI data (1Gi) + config (100Mi)
- Done: Grafana (2Gi)
- Done: Loki (5Gi)
- Done: Prometheus (10Gi)
- Remaining: no app or observability PVCs; Traefik `acme.json` is replaced by cert-manager

Migration path: Longhorn is already installed and all major app and observability PVCs are already
on Longhorn. The default StorageClass has already been switched to Longhorn, and Traefik TLS no
longer depends on `acme.json`. The only likely cleanup left is deleting the old retained Traefik
PVC from the live cluster if it still exists. Alternatively, use Longhorn's built-in backup/restore
where preserving data matters.

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

The current setup now uses two scripts:

- `bootstrap.sh` for the first server (always embedded etcd / `--cluster-init`)
- `join-node.sh` for additional nodes joining an existing cluster
- Create `/var/log/traefik` with `chown 65532:65532` on **every** node
- Install Longhorn prerequisites (open-iscsi) on every node
- Flux bootstrap only runs once (on the first server)

Current status: done. Together, the scripts now:

- bootstraps the first server directly on embedded etcd
- supports server joins with `join-node.sh --server-url` + `--token`
- supports agent joins with `join-node.sh --agent --server-url` + `--token`
- creates `/var/log/traefik` on every node
- installs Longhorn prerequisites and inotify tuning on every node
- bootstraps Flux only on the first server

The live cluster has already been converted in place from SQLite to embedded etcd. On a brand new
cluster, `bootstrap.sh` avoids that later conversion by using embedded etcd from the start.

**Server vs. agent joins:**

- A **server** node joins the control plane. Server nodes participate in etcd quorum and improve
  cluster control-plane resilience. Server nodes can also run regular workloads unless tainted.
- An **agent** node joins only as a worker. It increases scheduling capacity for workloads but does
  not improve control-plane availability.

Practical rule: add **server** nodes when you want HA for the cluster itself; add **agent** nodes
when you only want more room for workloads.

### 6. TLS certificate sharing

Traefik now uses cert-manager-issued certificates from Kubernetes Secrets instead of storing Let's
Encrypt state in `acme.json`.

Current status: done. cert-manager is installed with both staging and production issuers, the shared
Traefik `TLSStore` certificate is issued, and IngressRoutes no longer depend on Traefik's ACME
resolver. One implementation detail remains important for the future: global entrypoint-level
HTTP→HTTPS redirects in Traefik interfere with cert-manager HTTP-01 challenges, so that redirect
cannot live at the static entrypoint level while HTTP-01 issuance is in use.

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
| 7    | Convert Crowdsec Agent to DaemonSet    | Low    | None                          |
| 8    | Update bootstrap/join scripts          | Done   | None                          |

Steps 1, 2, 3, 6, and 8 are complete. The cluster is now ready to accept additional server or
agent nodes, and Traefik TLS no longer depends on node-local certificate storage. The remaining
major work is networking for multi-node ingress, plus converting Crowdsec Agent to a DaemonSet.

---

## What Stays the Same

- All application Deployments and Services (no manifest changes needed)
- Flux CD Kustomization chain and GitRepository source
- IngressRoutes, middlewares, and TLS configuration (routes are Traefik CRDs, cluster-scoped)
- Crowdsec LAPI, bouncer plugin, and middleware (only the Agent deployment type changes)
- Grafana dashboards, Prometheus scrape configs, Loki retention settings
- All Secrets and ConfigMaps
- Alloy DaemonSet and its ConfigMap
