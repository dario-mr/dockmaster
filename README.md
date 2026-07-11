# Dockmaster

GitOps-managed k3s cluster for self-hosted applications.

## Architecture

```mermaid
%%{ init: { "flowchart": { "nodeSpacing": 50, "rankSpacing": 50 } } }%%
flowchart TD
    Internet["Internet"]
    GitHub["GitHub<br/>[source of truth]"]
    DockerHub["Docker Hub<br/>[app images]"]

    subgraph Cluster["k3s Cluster"]
        Flux["Flux<br/>[Reconciles declared<br/>resources from GitHub]"]

        subgraph Ingress["Ingress"]
            Traefik["Traefik<br/>[ingress controller]"]
        end

        Apps["Apps"]

        subgraph Observability["Observability"]
            Prometheus["Prometheus<br/>[metrics scraper & db]"]
            Alloy["Alloy<br/>[log agent]"]
            Loki["Loki<br/>[log db]"]
            Grafana["Grafana<br/>[dashboards]"]
        end

        subgraph Security["Security"]
            Crowdsec["Crowdsec<br/>[intrusion detection]"]
        end
    end

%% traffic
    Internet --> Traefik
    Traefik -->|routes to| Apps
%% security
    Crowdsec -->|bouncer middleware| Traefik
%% observability
    Alloy -->|tails access logs| Traefik
    Alloy -->|collects logs| Apps
    Alloy -->|ships logs| Loki
    Grafana -->|queries logs| Loki
%% metrics
    Prometheus -->|scrapes metrics| Apps
    Grafana -->|queries metrics| Prometheus
%% gitops
    GitHub -->|source for| Flux
    DockerHub -->|new semver tags| Flux
%% colors
    style Cluster fill: #f0f9ff, stroke: #bae6fd
    style Ingress fill: #fff7ed, stroke: #fed7aa
    style Observability fill: #e0f2fe, stroke: #93c5fd
    style Security fill: #e0f2fe, stroke: #93c5fd
%% normal nodes
    classDef obs fill: #bae6fd, stroke: #60a5fa, color: #0f172a
    class Prometheus,Alloy,Loki,Grafana obs
%% security nodes
    classDef sec fill: #bae6fd, stroke: #60a5fa, color: #0f172a
    class Crowdsec sec
%% main-flow nodes
    classDef mainFlow fill: #ffedd5, stroke: #fdba74, color: #7c2d12
    class Internet,Traefik,Apps mainFlow
%% gitops nodes
    classDef gitops fill: #bbf7d0, stroke: #86efac, color: #14532d
    class Flux,GitHub,DockerHub gitops
```

## Structure

```
clusters/production/       Flux Kustomizations (image automation + infrastructure → observability → apps)
clusters/production/image-automation/ Flux image repositories, policies, and update automation
infrastructure/            Namespaces, Traefik config (HelmChartConfig), middlewares, Crowdsec, Headlamp
observability/             Prometheus stack, Loki, Alloy, Grafana dashboards
apps/                      Application deployments (function-plotter, lab-home, wordle-duel, wordle-duel-service, redis)
scripts/                   Bootstrap and operational scripts
doc/                       Setup and operations guides
secrets/                   Secret templates (real values git-ignored)
docs/                      Deep-dive documentation (secrets inventory, Crowdsec, TLS, rollback)
```

## Stack

| Component                                                                    | Purpose                                                | Chart version |
|------------------------------------------------------------------------------|--------------------------------------------------------|---------------|
| [Flux](https://fluxcd.io/)                                                   | GitOps continuous delivery + image automation          | v2            |
| [Traefik](https://traefik.io/)                                               | Ingress controller (bundled with k3s)                  | k3s-managed   |
| [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts) | Prometheus, Grafana, node-exporter, kube-state-metrics | 87.12.5       |
| [Loki](https://grafana.com/oss/loki/)                                        | Log aggregation (SingleBinary, TSDB, 30d retention)    | 7.0.0         |
| [Alloy](https://grafana.com/oss/alloy/)                                      | Log collection (pod logs + Traefik access logs)        | 1.10.0        |
| [Crowdsec](https://www.crowdsec.net/)                                        | Intrusion detection + Traefik bouncer                  | 0.22.1        |
| [Headlamp](https://headlamp.dev/)                                            | Cluster web UI (token auth)                            | 0.43.0        |

## Applications

| App                 | Description              | URL                                      |
|---------------------|--------------------------|------------------------------------------|
| function-plotter    | Function plotting app    | `https://dariolab.com/function-plotter/` |
| lab-home            | Static landing page      | `https://dariolab.com/`                  |
| wordle-duel         | Wordle game frontend     | `https://dariolab.com/wordle-duel/`      |
| wordle-duel-service | Spring Boot API backend  | `https://dariolab.com/wordle-duel/api/`  |
| Grafana             | Observability dashboards | `https://dariolab.com/grafana/`          |
| Headlamp            | Cluster management UI    | `https://dariolab.com/dashboard`         |

App deployments under `apps/` are version-pinned in git and automatically bumped by Flux when a
new stable semver tag is published to Docker Hub for the tracked first-party images.

## Prerequisites

- `DNS A` record for your domain pointing to VPS IP
- GitHub Personal Access Token with write repo permissions for flux
- Ubuntu/Debian VPS with `sudo` access for the first server

## Guides

- [Getting started and node join](doc/getting-started.md)
- [Operations](doc/operations.md)
- [Secrets inventory](docs/secrets-inventory.md)
- [Crowdsec operations](docs/crowdsec.md)
