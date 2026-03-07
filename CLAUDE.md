# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this
repository.

## What This Is

GitOps-managed **k3s single-node cluster** for self-hosted applications at `dariolab.com`. All
cluster state is declared in YAML and reconciled by Flux CD from the `main` branch.

## Architecture

Three-tier Flux dependency chain: **infrastructure → observability → apps**. Each tier is a Flux
Kustomization defined in `clusters/production/`.

**Global domain variable:** `${DOMAIN}` (value: `dariolab.com`) is injected via
`postBuild.substitute` in `clusters/production/kustomization.yaml` and substituted across all
IngressRoutes, Grafana config, and Alloy config.

**Key integrations:**

- **Traefik** is k3s-bundled (not a Helm chart we manage), configured via `HelmChartConfig`. Writes
  JSON access logs to `/var/log/traefik/` (hostPath shared with Crowdsec and Alloy).
- **Crowdsec** agent reads Traefik access logs; its bouncer runs as a Traefik plugin (stream mode,
  15s poll). Bouncer key must match in both `crowdsec` and `kube-system` namespaces.
- **Alloy** (DaemonSet) collects Traefik access logs + filtered pod logs, enriches with GeoIP data,
  ships to Loki.
- **Prometheus** scrapes apps via pod annotations (`prometheus.io/scrape: "true"`).

## Common Operations

```bash
# Check Flux reconciliation status
flux get kustomizations

# Force reconcile a specific layer
flux reconcile kustomization infrastructure
flux reconcile kustomization observability
flux reconcile kustomization apps

# Check Helm releases
flux get helmreleases -A

# Apply secrets after editing templates
sudo bash scripts/apply-secrets.sh

# Full cluster bootstrap (on VPS)
export GITHUB_TOKEN=ghp_...
sudo -E bash scripts/bootstrap.sh
```

## Conventions

- **Kustomize, not Helm, for apps:** Apps use plain Kubernetes manifests composed via
  `kustomization.yaml`. Helm is used only for third-party charts (Crowdsec, Loki,
  kube-prometheus-stack, Alloy, Headlamp).
- **One resource per file:** Each Kubernetes resource gets its own YAML file, listed explicitly in
  the layer's `kustomization.yaml`.
- **Secrets are git-ignored:** Real secrets live in `secrets/*.yaml` (git-ignored). Only
  `secrets/*.template.yaml` files are committed. Apply secrets manually via
  `scripts/apply-secrets.sh`.
- **IngressRoutes use Traefik CRDs** (not standard Ingress). All routes apply `crowdsec-bouncer` +
  `default-headers` middlewares. Apps get `rate-limit-app` (10 req/s), global gets
  `rate-limit-global` (20 req/s).
- **Single-node constraints:** Uses `local-path` storage (ReadWriteOnce), hostPort/hostPath for
  Traefik, SQLite k3s datastore. See `docs/single-to-multi-node.md` for migration considerations.

## File Layout

```
clusters/production/    Flux entry point: kustomization.yaml patches in ${DOMAIN}, three tier yamls
infrastructure/         Traefik config, Crowdsec, Headlamp, GeoIP cronjob, namespaces, middlewares
observability/          kube-prometheus-stack, Loki, Alloy (with GeoIP enrichment), Grafana dashboards
apps/                   lab-home, wordle-duel, wordle-duel-service, redis
scripts/                bootstrap.sh (k3s + Flux init), apply-secrets.sh
secrets/                Templates committed, real values git-ignored
docs/                   secrets-inventory.md, crowdsec.md, single-to-multi-node.md
```
