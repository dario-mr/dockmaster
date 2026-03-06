# Secrets Inventory

All secrets required by the cluster.

## wordle-duel-service

**Secret name:** `wordle-duel-service-secrets` (namespace: `apps`)

| Key                           | Description                    | Source               |
|-------------------------------|--------------------------------|----------------------|
| `DB_USER`                     | Supabase PostgreSQL user       | Supabase dashboard   |
| `DB_PORT`                     | Supabase PostgreSQL port       | Supabase dashboard   |
| `DB_PASSWORD`                 | Supabase PostgreSQL password   | Supabase dashboard   |
| `WORDLE_GOOGLE_CLIENT_ID`     | Google OAuth 2.0 client ID     | Google Cloud Console |
| `WORDLE_GOOGLE_CLIENT_SECRET` | Google OAuth 2.0 client secret | Google Cloud Console |
| `WORDLE_JWT_SECRET`           | JWT signing secret             | Self-generated       |

**Template:** `secrets/wordle-duel-service-secrets.template.yaml`

## Observability

**Secret name:** `grafana-admin-secret` (namespace: `observability`)

| Key              | Description            | Source         |
|------------------|------------------------|----------------|
| `admin-user`     | Grafana admin username | Static: admin  |
| `admin-password` | Grafana admin password | Self-generated |

**Template:** `secrets/observability-secrets.template.yaml`

## Headlamp

**Secret name:** `dashboard-basic-auth` (namespace: `kubernetes-dashboard`)

| Key     | Description                                          | Source         |
|---------|------------------------------------------------------|----------------|
| `users` | htpasswd entry (e.g. `admin:$2y$...`), bcrypt hashed | Self-generated |

Generate with: `htpasswd -nbB admin YOUR_PASSWORD`

**Template:** `secrets/dashboard-secrets.template.yaml`

## Other apps

- **lab-home** — No secrets required.
- **wordle-duel** — No secrets required.
- **wordle-duel-service-redis** — No secrets required.
