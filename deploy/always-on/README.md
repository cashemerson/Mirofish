# Always-On Deployment (Option B)

This folder contains a hardened, repeatable deployment for running MiroFish continuously on a VM/VPS with Docker Compose.

## What this setup includes

- `docker-compose.yml`: base stack (`mirofish` + launcher `portal`)
- `docker-compose.tls.yml`: HTTPS reverse proxy via Caddy (Let's Encrypt)
- `Caddyfile.template`: Caddy routes for app, API, and protected portal
- `scripts/set-portal-auth-hash.sh`: safely writes bcrypt hash into `.env`
- `scripts/validate-deploy.sh`: preflight validation to catch common config errors
- `scripts/render-caddyfile.sh`: renders concrete `Caddyfile` from `.env`
- bilingual portal UI (English/Chinese) with in-page language switch

## Prerequisites

1. Docker + Docker Compose plugin installed on your server.
2. DNS A records for your domains (if using TLS overlay).
3. API credentials:
   - `LLM_API_KEY`
   - `ZEP_API_KEY`

Recommended defaults:
- `LLM_BASE_URL=https://api.openai.com/v1`
- `LLM_MODEL_NAME=gpt-4o-mini`

---

## Option 1: local ports only (no TLS)

```bash
cd deploy/always-on
cp .env.example .env
# edit .env and set at least LLM_API_KEY + ZEP_API_KEY
./scripts/validate-deploy.sh --mode base
docker compose up -d
docker compose ps
```

Endpoints:
- Frontend: `http://<server-ip>:3000`
- API: `http://<server-ip>:5001`
- Portal: `http://<server-ip>:8080`

---

## Option 2: custom domains + HTTPS + portal auth (recommended)

### 1) DNS

Point both names to your server IP:
- `app.your-domain`
- `portal.your-domain`

### 2) Prepare `.env`

```bash
cd deploy/always-on
cp .env.example .env
```

Edit `.env` and set:
- `LLM_API_KEY`, `ZEP_API_KEY`
- `MIROFISH_DOMAIN=app.your-domain`
- `PORTAL_DOMAIN=portal.your-domain`
- `ACME_EMAIL=you@example.com`
- `PORTAL_BASIC_AUTH_USER=admin` (or your preferred username)

### 3) Set basic-auth password safely

Use the helper script so bcrypt `$` characters are written correctly:

```bash
./scripts/set-portal-auth-hash.sh "your-strong-password"
```

### 4) Validate and start

```bash
./scripts/validate-deploy.sh --mode tls
./scripts/render-caddyfile.sh
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d
docker compose -f docker-compose.yml -f docker-compose.tls.yml ps
```

`docker-compose.yml` already injects `__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS` from your domain values to prevent Vite host-allowlist 403 errors on custom domains.

### 5) Verify externally

```bash
curl -I https://app.your-domain
curl -I https://portal.your-domain
curl -u admin:your-strong-password "https://portal.your-domain"
curl "https://app.your-domain/api/simulation/history?limit=1"
```

Or run the built-in smoke check (prompts for portal password):

```bash
./scripts/smoke-check.sh \
  --app https://app.your-domain \
  --portal https://portal.your-domain \
  --api https://app.your-domain/api/simulation/history?limit=1 \
  --user admin
```

If your deployment has drifted due to copy/paste issues, run one-command repair:

```bash
APP_DOMAIN=app.your-domain \
PORTAL_DOMAIN=portal.your-domain \
ACME_EMAIL=you@example.com \
ADMIN_USER=admin \
./scripts/repair-deploy.sh
```

This script:
- validates `.env` contains required keys
- rewrites `docker-compose.yml` to a known-good config
- rewrites `portal-nginx.conf` to a known-good config
- updates Vite allowed hosts for custom domains
- optionally rotates portal password/hash safely
- renders a concrete `Caddyfile`
- validates compose and restarts the stack
- prints status and endpoint checks

---

## Troubleshooting restart loops quickly

If any container restarts:

```bash
docker compose -f docker-compose.yml -f docker-compose.tls.yml ps
docker compose -f docker-compose.yml -f docker-compose.tls.yml logs --tail=150 caddy
docker compose -f docker-compose.yml -f docker-compose.tls.yml logs --tail=150 mirofish
```

Run preflight and regenerate Caddyfile:

```bash
./scripts/validate-deploy.sh --mode tls
./scripts/render-caddyfile.sh
```

The validator catches:
- weak or malformed `PORTAL_BASIC_AUTH_HASH` values
- missing required env keys
- Caddyfile template rendering issues
- broken Compose syntax

### Why this avoids the `$2a$...` Docker Compose warning

- `PORTAL_BASIC_AUTH_HASH` is stored in `.env` with single quotes by `set-portal-auth-hash.sh`
- `render-caddyfile.sh` resolves variables before Caddy starts
- Caddy reads `./Caddyfile` directly, so runtime env interpolation is no longer involved

---

## Platform alternatives

- Render: `render.yaml`
- Railway: `railway.json`

These files are templates and may require environment-specific tweaks.

---

## Security notes

- Never commit real API keys.
- Rotate keys immediately if they were exposed in shell history, logs, or screenshots.
- Prefer secret managers / protected env vars in production.
