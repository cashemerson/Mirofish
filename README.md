# Mirofish

AI-powered ontology generation and simulation platform.

## Deployment Recovery

This repository contains a complete, tested deployment stack for MiroFish. It fixes the broken state where `/root/mirofish-deploy` was not a git repo and `scripts/` was empty.

### Root cause

The previous deploy directory was corrupted: `git` commands failed ("not a git repository"), and `ls -la scripts` showed only `.` and `..`. The fix is a clean re-clone from this repository.

### Domains

| Purpose | Domain |
|---------|--------|
| App | `app.cesimulation.it.com` |
| Root | `cesimulation.it.com` |
| Portal | `portal.cesimulation.it.com` |

---

## Recovery: Step-by-Step

All commands below are copy-paste-safe. Run them on the server as root.

### Step 1 — Nuke the broken directory and re-clone

```
cd /root
docker compose -f /root/mirofish-deploy/deploy/always-on/docker-compose.yml -f /root/mirofish-deploy/deploy/always-on/docker-compose.tls.yml down --remove-orphans 2>/dev/null || true
rm -rf /root/mirofish-deploy
git clone --depth 1 https://github.com/cashemerson/Mirofish.git /root/mirofish-deploy
cd /root/mirofish-deploy/deploy/always-on
chmod +x scripts/*.sh
ls -la scripts/
```

Expected output: nine `.sh` files in `scripts/`.

### Step 2 — Create .env from template

```
cd /root/mirofish-deploy/deploy/always-on
cp .env.example .env
```

Then edit `.env` and set these required values:

```
LLM_API_KEY=sk-your-openai-key-here
ZEP_API_KEY=your-zep-key-here
MIROFISH_DOMAIN=app.cesimulation.it.com,cesimulation.it.com
PORTAL_DOMAIN=portal.cesimulation.it.com
ACME_EMAIL=your-email@example.com
```

You can use `sed` for non-interactive editing:

```
cd /root/mirofish-deploy/deploy/always-on
sed -i 's|^LLM_API_KEY=.*|LLM_API_KEY=sk-REPLACE-ME|' .env
sed -i 's|^ZEP_API_KEY=.*|ZEP_API_KEY=REPLACE-ME|' .env
sed -i 's|^MIROFISH_DOMAIN=.*|MIROFISH_DOMAIN=app.cesimulation.it.com,cesimulation.it.com|' .env
sed -i 's|^PORTAL_DOMAIN=.*|PORTAL_DOMAIN=portal.cesimulation.it.com|' .env
sed -i 's|^ACME_EMAIL=.*|ACME_EMAIL=your-email@example.com|' .env
```

### Step 3 — Validate configuration

```
cd /root/mirofish-deploy/deploy/always-on
bash scripts/validate-deploy.sh --mode tls
```

Expected output: `Deploy preflight checks passed (tls mode).`

### Step 4 — Render Caddyfile from template

```
cd /root/mirofish-deploy/deploy/always-on
bash scripts/render-caddyfile.sh
```

Expected output: `Rendered ./Caddyfile from ./Caddyfile.template.`

### Step 5 — Pull images and start the stack

```
cd /root/mirofish-deploy/deploy/always-on
docker compose -f docker-compose.yml -f docker-compose.tls.yml pull
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d --force-recreate
```

### Step 6 — Wait and check container health

```
cd /root/mirofish-deploy/deploy/always-on
sleep 30
docker compose -f docker-compose.yml -f docker-compose.tls.yml ps
```

All three containers (`mirofish`, `mirofish-portal`, `mirofish-caddy`) should show `Up` with `(healthy)`.

### Step 7 — Run smoke checks

```
cd /root/mirofish-deploy/deploy/always-on
bash scripts/smoke-check.sh --app https://cesimulation.it.com --portal https://portal.cesimulation.it.com --api https://cesimulation.it.com/api/simulation/history?limit=1
```

### Step 8 — Test endpoints manually

```
curl -skI https://cesimulation.it.com/
curl -skI https://app.cesimulation.it.com/
curl -skI https://portal.cesimulation.it.com/
curl -sk https://cesimulation.it.com/api/simulation/history?limit=1
```

---

## One-command bootstrap (alternative)

If you prefer a single command that does steps 1-7 automatically, set your API keys as environment variables and run the bootstrap script:

```
export LLM_API_KEY="sk-your-openai-key"
export ZEP_API_KEY="your-zep-key"
export ACME_EMAIL="your-email@example.com"
curl -fsSL https://raw.githubusercontent.com/cashemerson/Mirofish/main/deploy/always-on/scripts/bootstrap-server.sh | bash
```

Or after cloning:

```
cd /root/mirofish-deploy/deploy/always-on
LLM_API_KEY="sk-your-key" ZEP_API_KEY="your-zep-key" ACME_EMAIL="you@example.com" bash scripts/bootstrap-server.sh
```

---

## Troubleshooting

### Container not healthy

```
cd /root/mirofish-deploy/deploy/always-on
docker compose -f docker-compose.yml -f docker-compose.tls.yml ps
docker compose -f docker-compose.yml -f docker-compose.tls.yml logs --tail=150 caddy
docker compose -f docker-compose.yml -f docker-compose.tls.yml logs --tail=150 mirofish
docker compose -f docker-compose.yml -f docker-compose.tls.yml logs --tail=150 portal
```

### Network Error during ontology generation

```
cd /root/mirofish-deploy/deploy/always-on
bash scripts/diagnose-network-error.sh --app https://cesimulation.it.com --portal https://portal.cesimulation.it.com --api-path /api/graph/ontology/generate
```

### Full repair (rewrites compose, nginx, Caddyfile, restarts)

```
cd /root/mirofish-deploy/deploy/always-on
bash scripts/repair-deploy.sh --app-domain app.cesimulation.it.com --root-domain cesimulation.it.com --portal-domain portal.cesimulation.it.com --acme-email your-email@example.com
```

### Restart stack

```
cd /root/mirofish-deploy/deploy/always-on
docker compose -f docker-compose.yml -f docker-compose.tls.yml down
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d
docker compose -f docker-compose.yml -f docker-compose.tls.yml ps
```

### Re-validate after edits

```
cd /root/mirofish-deploy/deploy/always-on
bash scripts/validate-deploy.sh --mode tls
bash scripts/render-caddyfile.sh
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d --force-recreate
```

---

## File inventory

| Path | Purpose |
|------|---------|
| `deploy/always-on/docker-compose.yml` | Base stack: mirofish + portal |
| `deploy/always-on/docker-compose.tls.yml` | TLS overlay: Caddy reverse proxy |
| `deploy/always-on/Caddyfile.template` | Template for Caddy config |
| `deploy/always-on/.env.example` | Template for environment variables |
| `deploy/always-on/portal-nginx.conf` | Nginx config for portal container |
| `deploy/always-on/scripts/bootstrap-server.sh` | Full bootstrap from scratch |
| `deploy/always-on/scripts/validate-deploy.sh` | Preflight validation |
| `deploy/always-on/scripts/render-caddyfile.sh` | Renders Caddyfile from .env |
| `deploy/always-on/scripts/smoke-check.sh` | HTTP smoke tests |
| `deploy/always-on/scripts/repair-deploy.sh` | One-command repair |
| `deploy/always-on/scripts/diagnose-network-error.sh` | Network error diagnostics |
| `portal/index.html` | Portal launcher page |
