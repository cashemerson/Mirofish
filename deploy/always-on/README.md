# Always-On Deployment (Option B)

This folder contains a hardened, repeatable deployment for running MiroFish continuously on a VM/VPS with Docker Compose.

## What this setup includes

- `docker-compose.yml`: base stack (`mirofish` + launcher `portal`)
- `docker-compose.tls.yml`: HTTPS reverse proxy via Caddy (Let's Encrypt)
- `Caddyfile.template`: Caddy routes for app, API, and portal
- `scripts/validate-deploy.sh`: preflight validation to catch common config errors
- `scripts/render-caddyfile.sh`: renders concrete `Caddyfile` from `.env`
- `scripts/repair-deploy.sh`: one-command recovery for drifted deployments
- `scripts/diagnose-network-error.sh`: targeted checks for frontend "Network Error" paths
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

## Option 2: custom domains + HTTPS (recommended)

### 1) DNS

Point all names to your server IP:
- `your-domain` (apex/root)
- `app.your-domain`
- `portal.your-domain`

### 2) Prepare `.env`

```bash
cd deploy/always-on
cp .env.example .env
```

Edit `.env` and set:
- `LLM_API_KEY`, `ZEP_API_KEY`
- `MIROFISH_DOMAIN=app.your-domain,your-domain`
- `PORTAL_DOMAIN=portal.your-domain`
- `ACME_EMAIL=you@example.com`
- optional but recommended for large ontology/doc uploads:
  - `API_MAX_UPLOAD_SIZE=200MB`
  - `API_RESPONSE_HEADER_TIMEOUT=600s`
  - `API_READ_TIMEOUT=600s`
  - `API_WRITE_TIMEOUT=600s`

### 3) Validate and start

```bash
./scripts/validate-deploy.sh --mode tls
./scripts/render-caddyfile.sh
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d
docker compose -f docker-compose.yml -f docker-compose.tls.yml ps
```

`docker-compose.yml` injects `__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS` from domain values to prevent Vite host-allowlist 403 errors on custom domains.

### 4) Verify externally

```bash
curl -I https://your-domain
curl -I https://app.your-domain
curl -I https://portal.your-domain
curl "https://your-domain/api/simulation/history?limit=1"
```

Or run the built-in smoke check:

```bash
./scripts/smoke-check.sh \
  --app https://your-domain \
  --portal https://portal.your-domain \
  --api https://your-domain/api/simulation/history?limit=1
```

If the UI shows `Network Error` during file upload or ontology generation, run:

```bash
./scripts/diagnose-network-error.sh \
  --app https://your-domain \
  --portal https://portal.your-domain \
  --api-path /api/graph/ontology/generate
```

This script verifies DNS, TLS reachability, container health, and endpoint responses, then prints the most relevant logs from `caddy` and `mirofish`.

If your deployment has drifted due to copy/paste issues, run one-command repair:

```bash
./scripts/repair-deploy.sh \
  --app-domain app.your-domain \
  --root-domain your-domain \
  --portal-domain portal.your-domain \
  --acme-email you@example.com
```

This script:
- validates `.env` contains required keys
- rewrites `docker-compose.yml` to a known-good config
- rewrites `portal-nginx.conf` to a known-good config
- updates Vite allowed hosts for custom domains
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
- missing required env keys
- Caddyfile template rendering issues
- broken Compose syntax

---

## Security notes

- Never commit real API keys.
- Rotate keys immediately if they were exposed in shell history, logs, or screenshots.
- Prefer secret managers / protected env vars in production.
