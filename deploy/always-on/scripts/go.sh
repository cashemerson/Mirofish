#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${DEPLOY_DIR}"

require_file() {
  local path="$1"
  [ -f "${path}" ] || {
    echo "FATAL: Missing required file: ${path}"
    echo "This deploy directory looks incomplete/corrupted."
    echo "Recover using: ${DEPLOY_DIR}/scripts/bootstrap-server.sh (or re-clone /root/mirofish-deploy)."
    exit 1
  }
}

echo "[0/8] Verifying deploy directory integrity..."
require_file "docker-compose.yml"
require_file "docker-compose.tls.yml"
require_file "Caddyfile.template"
require_file "scripts/validate-deploy.sh"
require_file "scripts/render-caddyfile.sh"
require_file "scripts/bootstrap-server.sh"
require_file "scripts/repair-deploy.sh"
require_file "scripts/diagnose-network-error.sh"
require_file "scripts/triage-ontology-404.sh"
require_file "scripts/configure-llm-provider.sh"
echo "  OK"
echo ""

echo "========================================"
echo "  MiroFish Deployment — cesimulation.it.com"
echo "========================================"
echo ""

echo "[1/8] Validating .env..."
if [ ! -f .env ]; then
  echo "FATAL: .env not found. Run: cp .env.example .env && vi .env"
  exit 1
fi

set_env_var() {
  local key="$1"
  local value="$2"
  local tmp_file
  tmp_file="$(mktemp)"
  awk -v key="${key}" -v value="${value}" '
    BEGIN { replaced = 0 }
    $0 ~ "^" key "=" {
      print key "=" value
      replaced = 1
      next
    }
    { print }
    END {
      if (!replaced) {
        print key "=" value
      }
    }
  ' .env > "${tmp_file}"
  mv "${tmp_file}" .env
}

# Allow operators to pass keys via environment without manually editing .env first.
if [ -z "${LLM_API_KEY:-}" ] && [ -n "${OPENAI_API_KEY:-}" ]; then
  LLM_API_KEY="${OPENAI_API_KEY}"
fi
if [ -n "${LLM_API_KEY:-}" ]; then
  set_env_var "LLM_API_KEY" "${LLM_API_KEY}"
  echo "  Synced LLM_API_KEY from environment into .env"
fi
if [ -n "${ZEP_API_KEY:-}" ]; then
  set_env_var "ZEP_API_KEY" "${ZEP_API_KEY}"
  echo "  Synced ZEP_API_KEY from environment into .env"
fi

LLM_KEY="$(grep '^LLM_API_KEY=' .env | cut -d= -f2-)"
ZEP_KEY="$(grep '^ZEP_API_KEY=' .env | cut -d= -f2-)"
LLM_KEY_LOWER="$(printf '%s' "${LLM_KEY}" | tr '[:upper:]' '[:lower:]')"
ZEP_KEY_LOWER="$(printf '%s' "${ZEP_KEY}" | tr '[:upper:]' '[:lower:]')"
if [ -z "${LLM_KEY}" ] || [ "${LLM_KEY}" = "replace_with_openai_or_compatible_key" ] || [[ "${LLM_KEY_LOWER}" == sk-your-* ]] || [[ "${LLM_KEY_LOWER}" == sk-replace-* ]] || [[ "${LLM_KEY_LOWER}" == "sk-proj-" ]]; then
  echo "FATAL: LLM_API_KEY missing or still using a sample value in .env"
  echo "Set it in .env or export LLM_API_KEY (or OPENAI_API_KEY) before running go.sh."
  exit 1
fi
if [ -z "${ZEP_KEY}" ] || [ "${ZEP_KEY}" = "replace_with_zep_key" ] || [ "${ZEP_KEY_LOWER}" = "your-zep-key" ]; then
  echo "FATAL: ZEP_API_KEY missing or still using a sample value in .env"
  echo "Set it in .env or export ZEP_API_KEY before running go.sh."
  exit 1
fi
echo "  LLM_API_KEY: set (${#LLM_KEY} chars)"
echo "  ZEP_API_KEY: set (${#ZEP_KEY} chars)"
echo "  OK"
echo ""

echo "[2/8] Creating directories..."
mkdir -p uploads portal
echo "  OK"
echo ""

echo "[3/8] Rendering Caddyfile..."
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

echo "[4/8] Validating compose config..."
docker compose -f docker-compose.yml -f docker-compose.tls.yml config > /dev/null
echo "  OK"
echo ""

echo "[5/8] Verifying mirofish image availability..."
MIROFISH_IMAGE="$(
  docker compose -f docker-compose.yml -f docker-compose.tls.yml config | \
    sed -n '/^  mirofish:$/,/^  [^ ]/s/^    image: //p' | head -n 1
)"
if [ -z "${MIROFISH_IMAGE}" ]; then
  echo "FATAL: Could not resolve mirofish image from compose config."
  exit 1
fi
PULL_LOG="$(mktemp)"
if ! docker pull "${MIROFISH_IMAGE}" >"${PULL_LOG}" 2>&1; then
  echo "FATAL: Unable to pull ${MIROFISH_IMAGE}."
  if grep -qi "manifest unknown" "${PULL_LOG}"; then
    echo "Cause: image tag is unavailable (manifest unknown)."
    echo "Fix: publish this tag (e.g., latest) or switch docker-compose.yml to a valid pullable tag."
  elif grep -qiE "denied|unauthorized|authentication required|forbidden" "${PULL_LOG}"; then
    echo "Cause: image is inaccessible with current registry credentials/package permissions."
    echo "Fix: authenticate to GHCR and confirm package access for this server/user."
  fi
  echo "---- docker pull output ----"
  cat "${PULL_LOG}"
  echo "----------------------------"
  rm -f "${PULL_LOG}"
  exit 1
fi
rm -f "${PULL_LOG}"
echo "  OK: ${MIROFISH_IMAGE} is pullable"
echo ""

echo "[6/8] Pulling images..."
docker compose -f docker-compose.yml -f docker-compose.tls.yml pull
echo ""

echo "[7/8] Starting stack..."
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d --force-recreate --remove-orphans
echo ""

echo "[8/8] Waiting for health (up to 3 min)..."
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

check_url_code() {
  local url="$1"
  local label="${2:-$1}"
  local code_file
  code_file="$(mktemp)"
  {
    code="$(curl -sk -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null || echo 'ERR')"
    printf '%s\n' "${code}" > "${code_file}"
  } &
  echo "$!|${label}|${code_file}"
}

echo "Endpoint checks:"
CHECKS=(
  "$(check_url_code 'https://cesimulation.it.com/' 'https://cesimulation.it.com/')"
  "$(check_url_code 'https://app.cesimulation.it.com/' 'https://app.cesimulation.it.com/')"
  "$(check_url_code 'https://portal.cesimulation.it.com/' 'https://portal.cesimulation.it.com/')"
  "$(check_url_code 'https://cesimulation.it.com/api/simulation/history?limit=1' 'API /simulation/history')"
  "$(check_url_code 'https://cesimulation.it.com/health' 'Backend /health')"
)
for CHECK in "${CHECKS[@]}"; do
  IFS='|' read -r PID LABEL CODE_FILE <<<"${CHECK}"
  wait "${PID}" || true
  CODE="$(cat "${CODE_FILE}" 2>/dev/null || echo 'ERR')"
  rm -f "${CODE_FILE}"
  echo "  ${LABEL} -> HTTP ${CODE}"
done
echo ""

echo "========================================"
echo "  Deployment complete!"
echo ""
echo "  App:    https://cesimulation.it.com"
echo "  App:    https://app.cesimulation.it.com"
echo "  Portal: https://portal.cesimulation.it.com"
echo "  API:    https://cesimulation.it.com/api/simulation/history?limit=1"
echo "========================================"
