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
- `scripts/bootstrap-server.sh`: full from-scratch server bootstrap (nuke + reclone + configure + start)
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

## Ollama vs vLLM (for cesimulation.it.com)

Short answer:
- **Use vLLM for production** (better throughput, batching, and GPU utilization under concurrent traffic).
- **Use Ollama for simplicity/local testing** (easier setup, lower operational complexity).

For `cesimulation.it.com`, prefer **vLLM** as the default self-hosted inference backend.

### Configure provider in `.env` automatically

Use:

```bash
cd deploy/always-on
chmod +x scripts/configure-llm-provider.sh
```

Configure **vLLM** (recommended):

```bash
./scripts/configure-llm-provider.sh \
  --provider vllm \
  --base-url http://vllm:8000/v1 \
  --model Qwen/Qwen2.5-7B-Instruct \
  --api-key none
```

Configure **Ollama** (alternative):

```bash
./scripts/configure-llm-provider.sh \
  --provider ollama \
  --base-url http://host.docker.internal:11434/v1 \
  --model llama3.1:8b \
  --api-key none
```

Then continue with standard preflight + startup:

```bash
./scripts/validate-deploy.sh --mode tls
./scripts/render-caddyfile.sh
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d
```

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
- use real values only (no placeholders like `replace_with_*` / `example.com`)
- `ACME_EMAIL` must be a valid email format (`name@domain.tld`)
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

If Docker reports `open .../docker-compose.yml: no such file or directory`, you're using the wrong filesystem path for that host.
Use the server-local repo directory (for example `cd /root/mirofish-deploy/deploy/always-on`) and run compose with repo-local files (`-f docker-compose.yml -f docker-compose.tls.yml`).
Do not copy GitHub runner paths like `/home/runner/work/...` into VPS commands.
The helper `scripts/go.sh` now resolves its deploy directory relative to its own location, so it can be run from any clone path.

`docker-compose.yml` injects `__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS` from domain values to prevent Vite host-allowlist 403 errors on custom domains.

### 4) Verify externally

```bash
curl -I https://your-domain
curl -I https://app.your-domain
curl -I https://portal.your-domain
curl "https://your-domain/api/simulation/history?limit=1"
curl -X POST "https://your-domain/api/graph/ontology/generate" -i
```

`/api/graph/ontology/generate` is a **POST** endpoint.  
If you use `GET`, `405 Method Not Allowed` is expected and confirms routing reached backend.

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

If the app UI shows `Request failed with status code 404` during ontology generation, make sure app env includes:

```env
VITE_API_BASE_URL=/api
```

`docker-compose.yml` now defaults this automatically to `/api` when unset.

API base URL resolution used by portal pages:
- `?api=https://your-domain` query parameter (highest priority)
- saved browser config key `mirofish_portal_config_v1.apiUrl` (if present)
- auto-derive from hostname (`portal.<domain>` -> `https://<domain>`)

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
- placeholder env values left from `.env.example`
- invalid ACME email format
- Caddyfile template rendering issues
- broken Compose syntax

---

## Emergency recovery (broken repo / empty scripts)

If git commands fail with "not a git repository" or `scripts/` is empty, the deploy directory is corrupted. Use the bootstrap script to nuke and rebuild:

```bash
export LLM_API_KEY="sk-your-openai-key"
export ZEP_API_KEY="your-zep-key"
export ACME_EMAIL="your-email@example.com"
bash <(curl -fsSL https://raw.githubusercontent.com/cashemerson/Mirofish/cursor/mirofish-deployment-recovery-2ae4/deploy/always-on/scripts/bootstrap-server.sh)
```

Or manually:

```bash
cd /root
rm -rf /root/mirofish-deploy
git clone --branch cursor/mirofish-deployment-recovery-2ae4 --single-branch --depth 1 https://github.com/cashemerson/Mirofish.git /root/mirofish-deploy
cd /root/mirofish-deploy/deploy/always-on
chmod +x scripts/*.sh
cp .env.example .env
# edit .env with your real API keys and domains
bash scripts/validate-deploy.sh --mode tls
bash scripts/render-caddyfile.sh
docker compose -f docker-compose.yml -f docker-compose.tls.yml pull
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d --force-recreate
docker compose -f docker-compose.yml -f docker-compose.tls.yml ps
```

Note: those compose files are looked up on the current server filesystem.
If your clone path is different, replace `/root/mirofish-deploy` accordingly.

---

## Security notes

- Never commit real API keys.
- Rotate keys immediately if they were exposed in shell history, logs, or screenshots.
- Prefer secret managers / protected env vars in production.
