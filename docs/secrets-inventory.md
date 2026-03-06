# Secrets Inventory

All secrets required by the 4 in-scope apps.

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

## Other apps

- **lab-home** — No secrets required.
- **wordle-duel** — No secrets required.
- **wordle-duel-service-redis** — No secrets required.
