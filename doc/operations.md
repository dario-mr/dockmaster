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

## Longhorn UI Tunnel

Create a temporary tunnel to access the Longhorn frontend:

```bash
# run on the VPS
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80

# run on your machine
ssh -L 8080:localhost:8080 dariolab
```
