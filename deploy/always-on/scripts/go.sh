#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${DEPLOY_DIR}"

echo "========================================"
echo "  MiroFish Deployment — cesimulation.it.com"
echo "========================================"
echo ""

echo "[1/7] Validating .env..."
if [ ! -f .env ]; then
  echo "FATAL: .env not found. Run: cp .env.example .env && vi .env"
  exit 1
fi
LLM_KEY="$(grep '^LLM_API_KEY=' .env | cut -d= -f2-)"
ZEP_KEY="$(grep '^ZEP_API_KEY=' .env | cut -d= -f2-)"
if [ -z "${LLM_KEY}" ] || [ "${LLM_KEY}" = "replace_with_openai_or_compatible_key" ]; then
  echo "FATAL: LLM_API_KEY not set in .env"
  exit 1
fi
if [ -z "${ZEP_KEY}" ] || [ "${ZEP_KEY}" = "replace_with_zep_key" ]; then
  echo "FATAL: ZEP_API_KEY not set in .env"
  exit 1
fi
echo "  LLM_API_KEY: set (${#LLM_KEY} chars)"
echo "  ZEP_API_KEY: set (${#ZEP_KEY} chars)"
echo "  OK"
echo ""

echo "[2/7] Creating directories..."
mkdir -p uploads portal
echo "  OK"
echo ""

echo "[3/7] Rendering Caddyfile..."
if [ -f scripts/render-caddyfile.sh ]; then
  bash scripts/render-caddyfile.sh
else
  APP_HOSTS="$(grep '^MIROFISH_DOMAIN=' .env | cut -d= -f2- | tr ',' ' ')"
  PORTAL_HOST="$(grep '^PORTAL_DOMAIN=' .env | cut -d= -f2-)"
  ACME="$(grep '^ACME_EMAIL=' .env | cut -d= -f2-)"
  cat > Caddyfile <<CEOF
${APP_HOSTS} {
  encode zstd gzip
  tls ${ACME}
  @api path /api/*
  handle @api {
    request_body { max_size 100MB }
    reverse_proxy mirofish:5001 {
      header_up Host localhost
      flush_interval -1
      transport http {
        dial_timeout 10s
        response_header_timeout 600s
        read_timeout 600s
        write_timeout 600s
      }
    }
  }
  reverse_proxy mirofish:3000 {
    header_up Host localhost
    flush_interval -1
    transport http {
      dial_timeout 10s
      response_header_timeout 120s
      read_timeout 120s
      write_timeout 120s
    }
  }
}
${PORTAL_HOST} {
  encode zstd gzip
  tls ${ACME}
  reverse_proxy portal:8080
}
CEOF
  echo "  Caddyfile rendered (inline fallback)"
fi
echo ""

echo "[4/7] Validating compose config..."
docker compose -f docker-compose.yml -f docker-compose.tls.yml config > /dev/null
echo "  OK"
echo ""

echo "[5/7] Pulling images..."
docker compose -f docker-compose.yml -f docker-compose.tls.yml pull
echo ""

echo "[6/7] Starting stack..."
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d --force-recreate --remove-orphans
echo ""

echo "[7/7] Waiting for health (up to 3 min)..."
for i in $(seq 1 18); do
  sleep 10
  MIROFISH_HEALTH="$(docker inspect --format='{{.State.Health.Status}}' mirofish 2>/dev/null || echo 'starting')"
  PORTAL_HEALTH="$(docker inspect --format='{{.State.Health.Status}}' mirofish-portal 2>/dev/null || echo 'starting')"
  CADDY_HEALTH="$(docker inspect --format='{{.State.Health.Status}}' mirofish-caddy 2>/dev/null || echo 'starting')"
  echo "  ${i}0s — mirofish:${MIROFISH_HEALTH} portal:${PORTAL_HEALTH} caddy:${CADDY_HEALTH}"
  if [ "${MIROFISH_HEALTH}" = "healthy" ] && [ "${PORTAL_HEALTH}" = "healthy" ] && [ "${CADDY_HEALTH}" = "healthy" ]; then
    echo ""
    echo "  All containers healthy!"
    break
  fi
done
echo ""

echo "Container status:"
docker compose -f docker-compose.yml -f docker-compose.tls.yml ps
echo ""

echo "Endpoint checks:"
for URL in "https://cesimulation.it.com/" "https://app.cesimulation.it.com/" "https://portal.cesimulation.it.com/"; do
  CODE="$(curl -sk -o /dev/null -w '%{http_code}' "${URL}" 2>/dev/null || echo 'ERR')"
  echo "  ${URL} -> HTTP ${CODE}"
done
API_CODE="$(curl -sk -o /dev/null -w '%{http_code}' 'https://cesimulation.it.com/api/simulation/history?limit=1' 2>/dev/null || echo 'ERR')"
echo "  API /simulation/history -> HTTP ${API_CODE}"
HEALTH_CODE="$(curl -sk -o /dev/null -w '%{http_code}' 'https://cesimulation.it.com/health' 2>/dev/null || echo 'ERR')"
echo "  Backend /health -> HTTP ${HEALTH_CODE}"
echo ""

echo "========================================"
echo "  Deployment complete!"
echo ""
echo "  App:    https://cesimulation.it.com"
echo "  App:    https://app.cesimulation.it.com"
echo "  Portal: https://portal.cesimulation.it.com"
echo "  API:    https://cesimulation.it.com/api/simulation/history?limit=1"
echo "========================================"
