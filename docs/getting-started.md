# Getting Started

This guide covers first-cluster bootstrap and adding extra nodes afterward.

## Environment Variables

These are the main environment variables used by the bootstrap and join scripts.

| Variable | Used by | Required | Purpose |
|----------|---------|----------|---------|
| `GITHUB_TOKEN` | `scripts/bootstrap.sh` | Yes | GitHub token used by `flux bootstrap github`. |
| `K8S_API_ALLOW_CIDR` | `scripts/bootstrap.sh`, `scripts/join-node.sh` | No | Opens TCP `6443` in UFW only for the given CIDR. |
| `DOCKMASTER_K3S_VERSION` | `scripts/bootstrap.sh`, `scripts/join-node.sh` | No | Overrides the pinned k3s version. |
| `DOCKMASTER_K3S_INSTALL_SCRIPT_SHA256` | `scripts/bootstrap.sh`, `scripts/join-node.sh` | No | Overrides the expected SHA256 for the pinned k3s installer script. |
| `DOCKMASTER_FLUX_VERSION` | `scripts/bootstrap.sh` | No | Overrides the pinned Flux CLI version. |
| `K3S_SERVER_URL` | `scripts/join-node.sh` | No | Alternative to `--server-url` for the server or agent join target. |
| `K3S_TOKEN` | `scripts/join-node.sh` | No | Alternative to `--token` for the join token. |
| `K3S_NODE_NAME` | `scripts/bootstrap.sh`, `scripts/join-node.sh` | No | Overrides the node name used when waiting for local node registration. |

## Quick Start

1. **Clone the repo on the first server:**
   ```bash
   git clone https://github.com/dario-mr/dockmaster.git
   cd dockmaster
   ```

2. **Prepare secrets:**
   ```bash
   cp secrets/wordle-duel-service-secrets.template.yaml secrets/wordle-duel-service-secrets.yaml
   cp secrets/observability-secrets.template.yaml secrets/observability-secrets.yaml
   cp secrets/crowdsec-secrets.template.yaml secrets/crowdsec-secrets.yaml
   cp secrets/geoipupdate-secret.template.yaml secrets/geoipupdate-secret.yaml
   # Edit secrets with real values
   ```
   For `wordle-duel-service`, set `WORDLE_JWT_PRIVATE_KEY_PEM` and `WORDLE_JWT_PUBLIC_KEY_PEM`
   to the PEM contents themselves.

3. **Set your domain:**
   Update `DOMAIN` in [kustomization.yaml](../clusters/production/kustomization.yaml) so it matches
   the DNS record you created.

4. **Bootstrap the first server:**
   ```bash
   export GITHUB_TOKEN=ghp_your_token_here
   sudo -E bash scripts/bootstrap.sh
   ```

5. **Apply secrets:**
   ```bash
   sudo bash scripts/apply-secrets.sh
   ```

6. **Resume observability and apps:**
   ```bash
   sudo bash scripts/reconcile-apps.sh
   ```

7. **Verify:**
   ```bash
   sudo bash scripts/verify.sh
   flux get kustomizations
   kubectl get pods -A
   ```

## Join Additional Nodes

Use [join-node.sh](../scripts/join-node.sh) after the first server is up.

- **Join an additional server node**
  ```bash
  sudo -E bash scripts/join-node.sh \
    --server-url https://<first-server>:6443 \
    --token <node-token>
  ```
- **Join an agent node**
  ```bash
  sudo -E bash scripts/join-node.sh \
    --agent \
    --server-url https://<first-server>:6443 \
    --token <node-token>
  ```

Server vs. agent:

- A **server** joins the control plane and, once the cluster is on embedded etcd, contributes to
  control-plane resilience.
- An **agent** joins only as a worker and adds workload capacity without improving control-plane
  availability.

## Related Docs

- [Secrets inventory](../docs/secrets-inventory.md)
- [Crowdsec operations](../docs/crowdsec.md)
- [Operations guide](./operations.md)
