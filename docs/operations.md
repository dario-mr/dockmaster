# Operations

## Verification

```bash
# Full post-bootstrap verification
sudo bash scripts/verify.sh
```

## Flux Status

```bash
flux get kustomizations
flux get image repository -A
flux get image policy -A
flux get image update -A
```

## Reconciliation

```bash
# Force reconcile a layer
flux reconcile kustomization infrastructure
flux reconcile kustomization observability
flux reconcile kustomization apps
```

## Workload Maintenance

```bash
# Restart a workload after ConfigMap changes
kubectl rollout restart daemonset/alloy -n observability

# Check Helm release versions
flux get helmreleases -n observability
```

## Logs

```bash
kubectl logs -n observability -l app.kubernetes.io/name=alloy -c alloy --tail=20
kubectl logs -n observability -l app.kubernetes.io/name=grafana -c grafana --tail=20
```

## Version Checks

```bash
bash scripts/check-outdated-apps.sh
```

## K3s Upgrade

K3s is pinned to the latest stable release in `scripts/lib/common.sh`. Commit
and push that pin, then update the server's checkout. The upgrade script uses
the tracked pin by default, but accepts the existing version and checksum
environment overrides for one-off intermediate steps:

```bash
sudo env DOCKMASTER_K3S_VERSION='v1.34.12+k3s1' DOCKMASTER_K3S_INSTALL_SCRIPT_SHA256='40b487f0d8ef4f5d1bf422e7bb6228cc7789c40ecc66c5ab067d396bbee9816e' bash scripts/upgrade-k3s.sh
sudo env DOCKMASTER_K3S_VERSION='v1.35.9+k3s1' DOCKMASTER_K3S_INSTALL_SCRIPT_SHA256='8598e002e61d658fed7b7542fc6d2c66d8da6eae69e088830105d2ee1ffb6d91' bash scripts/upgrade-k3s.sh
sudo env DOCKMASTER_K3S_VERSION='v1.36.5+k3s1' DOCKMASTER_K3S_INSTALL_SCRIPT_SHA256='46177d4c99440b4c0311b67233823a8e8a2fc09693f6c89af1a7161e152fbfad' bash scripts/upgrade-k3s.sh
sudo bash scripts/upgrade-k3s.sh
```

Follow the [K3s manual upgrade guidance](https://docs.k3s.io/upgrades/manual) and
upgrade one Kubernetes minor version at a time. The script checks the running
version and node readiness, saves an embedded-etcd snapshot, verifies the
current service has only the supported `server` command, installs the pinned
release with the verified installer, and waits for the node to become Ready.
The install restarts K3s, so the Kubernetes API will be briefly unavailable;
running workloads generally continue. Verify afterward with `k3s --version`,
`kubectl get nodes`, and `flux get kustomizations`.

For this server's current `v1.34.5+k3s1`, run those commands in order and verify
each hop before continuing. The final command uses the tracked latest pin
`v1.37.1+k3s1`. The intermediate release checksums are pinned above; the latest
release pin and checksum remain the defaults for bootstrap, join, and upgrade.

| Stage | `DOCKMASTER_K3S_VERSION` | Installer SHA256                                                   |
|-------|--------------------------|--------------------------------------------------------------------|
| 1     | `v1.34.12+k3s1`          | `40b487f0d8ef4f5d1bf422e7bb6228cc7789c40ecc66c5ab067d396bbee9816e` |
| 2     | `v1.35.9+k3s1`           | `8598e002e61d658fed7b7542fc6d2c66d8da6eae69e088830105d2ee1ffb6d91` |
| 3     | `v1.36.5+k3s1`           | `46177d4c99440b4c0311b67233823a8e8a2fc09693f6c89af1a7161e152fbfad` |
| 4     | `v1.37.1+k3s1`           | `ed01f89fd977bf20ac1516bbebf8370bf3ddbaa55dac8aba610956a4c78cc00b` |

Do not skip a minor version or add nodes during the staged upgrade. If an
upgrade fails, use the snapshot with the
[K3s rollback procedure](https://docs.k3s.io/upgrades/roll-back).

## Free Space Maintenance

Run this on a k3s node. The default is a dry run: it reports disk usage and
prints the cleanup commands without changing anything.

```bash
bash scripts/disk-space-cleanup.sh --dry-run
```

After reviewing the plan, run the real cleanup explicitly as root:

```bash
sudo bash scripts/disk-space-cleanup.sh --cleanup
```

The cleanup vacuums journald to `500M`, prunes unused k3s images, and cleans
the apt cache when those tools are installed. Override the journal limit when
needed:

```bash
sudo env JOURNAL_MAX_SIZE=1G bash scripts/disk-space-cleanup.sh --cleanup
```
