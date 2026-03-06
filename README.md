# Dockmaster

GitOps-managed k3s cluster for self-hosted applications, powered by [Flux](https://fluxcd.io/).

## Structure

```
clusters/production/   Flux Kustomizations (entry point)
infrastructure/        Namespaces, Traefik config, middlewares
apps/                  Application manifests (deployments, services, ingress)
scripts/               Bootstrap and operational scripts
secrets/               Secret manifests (git-ignored, templates only in repo)
docs/                  Documentation
```

## Prerequisites

- VPS with ports 80 and 443 open
- DNS A record for `dariolab.com` pointing to VPS IP
- GitHub Personal Access Token with repo permissions

## Quick Start

1. **Clone the repo on the VPS:**
   ```bash
   git clone https://github.com/dario-mr/dockmaster.git
   cd dockmaster
   ```

2. **Prepare secrets:**
   ```bash
   cp secrets/wordle-duel-service-secrets.template.yaml secrets/wordle-duel-service-secrets.yaml
   cp secrets/observability-secrets.template.yaml secrets/observability-secrets.yaml
   # Edit secrets with real values
   ```

3. **Run bootstrap:**
   ```bash
   export GITHUB_TOKEN=ghp_your_token_here
   sudo -E bash scripts/bootstrap.sh
   ```

4. **Apply secrets:**
   ```bash
   sudo bash scripts/apply-secrets.sh
   ```

5. **Verify:**
   ```bash
   kubectl get pods -n apps
   flux get kustomizations
   flux get kustomizations --watch
   ```

See [docs/secrets-inventory.md](docs/secrets-inventory.md) for all required secret values.
