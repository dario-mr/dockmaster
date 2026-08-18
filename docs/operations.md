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
