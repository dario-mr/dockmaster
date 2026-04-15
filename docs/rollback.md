# Roll Back an Auto-Deployed App Version

This repository uses Flux image automation to keep selected app image tags in `apps/` aligned with
the latest matching stable semver tag published to Docker Hub.

If a newly auto-deployed version is broken, a manual rollback needs two actions:

1. Suspend Flux image updates so the bad tag is not immediately re-applied.
2. Revert the app image in Git to the last known-good version.

## When To Use This

Use this runbook when:

- Flux has already deployed a newer image tag from Docker Hub
- the deployment is unhealthy or functionally broken
- you want to return production to the previous known-good image

## Step 1: Suspend Image Automation

Pause the image updater before making any Git changes:

```bash
flux suspend image update apps -n flux-system
```

Verify it is suspended:

```bash
flux get image update -A
```

The `apps` automation should show `SUSPENDED=True`.

## Step 2: Roll Back in Git

Revert the commit with the bad version or edit the version manually. Example revert:

```bash
git revert <commit-sha>
git push
```

## Step 3: Reconcile Flux

After the rollback commit is pushed:

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization apps -n flux-system --with-source
```

## Step 4: Verify the Rollback

Check that the application rolled back successfully:

```bash
kubectl -n apps get deploy
kubectl -n apps rollout status deployment/<app-name>
kubectl -n apps get pods -o wide
```

Confirm the running image:

```bash
kubectl -n apps get deployment <app-name> -o jsonpath='{.spec.template.spec.containers[*].image}'
echo
```

## Step 5: Resume Automation After the Fix

Once the broken image is removed, replaced, or superseded by a good newer tag, resume image
automation:

```bash
flux resume image update apps -n flux-system
```

Verify:

```bash
flux get image update -A
```
