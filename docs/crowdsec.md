# Crowdsec

Intrusion detection and prevention using [Crowdsec](https://www.crowdsec.net/) with
the [Traefik bouncer plugin](https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin).

## Architecture

```
Internet --> Traefik (bouncer plugin) --query--> Crowdsec LAPI
                                                     ^
                                          Crowdsec Agent (reads /var/log/traefik/access.log)
```

- **Crowdsec Engine** (LAPI + Agent) runs in the `crowdsec` namespace
- **Agent** reads Traefik access logs from hostPath `/var/log/traefik` (shared with Alloy)
- **Bouncer plugin** runs inside Traefik in **stream mode** — polls LAPI every 15s, maintains a
  local cache of banned IPs. No per-request latency added.
- **LAPI endpoint**: `crowdsec-service.crowdsec.svc.cluster.local:8080`

## Installed Collections

| Collection                          | What it covers                                                           |
|-------------------------------------|--------------------------------------------------------------------------|
| `crowdsecurity/traefik`             | Traefik log parser + basic scenarios                                     |
| `crowdsecurity/http-cve`            | Known exploit paths (`.env`, `wp-login.php`, `phpmyadmin`, `.git`, etc.) |
| `crowdsecurity/base-http-scenarios` | HTTP abuse (path scanning, 4xx floods, aggressive crawling)              |

## Health Checks

```bash
# Pods running
kubectl -n crowdsec get pods

# Agent is parsing Traefik logs
kubectl -n crowdsec exec deploy/crowdsec-agent -- cscli metrics

# Bouncer is registered
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli bouncers list

# Traefik loaded the plugin
kubectl -n kube-system logs deploy/traefik | grep -i plugin

# List installed scenarios
kubectl -n crowdsec exec deploy/crowdsec-agent -- cscli scenarios list

# List installed parsers
kubectl -n crowdsec exec deploy/crowdsec-agent -- cscli parsers list
```

## Monitoring Bans

```bash
# List all active bans
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions list

# List recent alerts (what triggered bans)
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli alerts list

# Detailed alert info
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli alerts inspect <ALERT_ID>

# Agent metrics (lines parsed, scenarios triggered)
kubectl -n crowdsec exec deploy/crowdsec-agent -- cscli metrics
```

If enrolled via `enroll-key`, the [Crowdsec Console](https://app.crowdsec.net) provides a web
dashboard with all decisions, alerts, and machine stats.

## Manual Ban/Unban

```bash
# Ban an IP for 5 minutes
kubectl -n crowdsec exec deploy/crowdsec-lapi -- \
  cscli decisions add --ip 1.2.3.4 --reason "test ban" --type ban --duration 5m

# Unban a specific IP
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions delete --ip 1.2.3.4

# Remove ALL active bans
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions delete --all
```

Changes take effect within ~15 seconds (the bouncer's stream poll interval).

## Unbanning Yourself

`kubectl` access is **not affected** by the bouncer — it goes directly to the k3s API server, not
through Traefik. You can always run these commands even if your IP is banned:

```bash
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions delete --ip YOUR.PUBLIC.IP
```

### Emergency: remove bouncer middleware

If completely locked out of web UIs but still have SSH + kubectl:

```bash
# Option 1: delete the ban
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions delete --ip YOUR.PUBLIC.IP

# Option 2: push a commit removing crowdsec-bouncer from IngressRoutes, then force reconcile
flux reconcile kustomization infrastructure --with-source
flux reconcile kustomization apps --with-source
```

## Testing

### Trigger a ban via bad path

From a test machine or VPN (**not** your real IP):

```bash
curl -v https://dariolab.com/.env
curl -v https://dariolab.com/wp-login.php
curl -v https://dariolab.com/phpmyadmin/

# Wait ~30s for agent to process + bouncer to poll, then check:
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions list
```

### Verify bouncer enforcement

```bash
# Normal access (unbanned IP)
curl -o /dev/null -s -w "%{http_code}" https://dariolab.com/
# Expected: 200

# After banning a test IP, same request should return 403
```

## Whitelisting

To permanently whitelist an IP, create a whitelist ConfigMap and mount it into the LAPI. Add to
`helmrelease.yaml` values under `lapi`:

```yaml
lapi:
  extraVolumes:
    - name: whitelist
      configMap:
        name: crowdsec-whitelist
  extraVolumeMounts:
    - name: whitelist
      mountPath: /etc/crowdsec/parsers/s02-enrich/my-whitelist.yaml
      subPath: my-whitelist.yaml
```

Then create `infrastructure/crowdsec/whitelist.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: crowdsec-whitelist
  namespace: crowdsec
data:
  my-whitelist.yaml: |
    name: my-whitelist
    description: "Admin IP whitelist"
    whitelist:
      reason: "admin"
      ip:
        - "YOUR.PUBLIC.IP"
```

## Secrets

Two secrets are required (values must match):

| Secret                 | Namespace     | Keys                        |
|------------------------|---------------|-----------------------------|
| `crowdsec-secrets`     | `crowdsec`    | `bouncer-key`, `enroll-key` |
| `crowdsec-bouncer-key` | `kube-system` | `bouncer-key`               |

The bouncer key must be identical in both secrets. Generate with `openssl rand -hex 32`.

Template: `secrets/crowdsec-secrets.template.yaml`

## Risks and Notes

- **Traefik restart**: Adding or updating the bouncer plugin declaration triggers a Traefik
  restart (seconds of downtime). Deploy off-peak.
- **Plugin version compatibility**: Verify the bouncer plugin version works with the k3s-bundled
  Traefik version before deploying.
- **False positives**: `base-http-scenarios` can be aggressive. Monitor alerts for the first week.
  Tune via `cscli scenarios list` and profile overrides.
- **Self-lockout**: Always whitelist your IP before testing. kubectl always works regardless of
  bans.
