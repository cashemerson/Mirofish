#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/cashemerson/Mirofish.git"
BRANCH="cursor/mirofish-deployment-recovery-2ae4"
SERVER_DIR="/root/mirofish-deploy"
DEPLOY_DIR="${SERVER_DIR}/deploy/always-on"

APP_DOMAIN="${APP_DOMAIN:-app.cesimulation.it.com}"
ROOT_DOMAIN="${ROOT_DOMAIN:-cesimulation.it.com}"
PORTAL_DOMAIN="${PORTAL_DOMAIN:-portal.cesimulation.it.com}"
ACME_EMAIL="${ACME_EMAIL:-you@example.com}"

LLM_API_KEY="${LLM_API_KEY:-}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
ZEP_API_KEY="${ZEP_API_KEY:-}"
LLM_BASE_URL="${LLM_BASE_URL:-https://api.openai.com/v1}"
LLM_MODEL_NAME="${LLM_MODEL_NAME:-gpt-4o-mini}"

if [ -z "${LLM_API_KEY}" ] && [ -n "${OPENAI_API_KEY}" ]; then
  LLM_API_KEY="${OPENAI_API_KEY}"
fi

fail() {
  echo "FATAL: $*" >&2
  exit 1
}

step() {
  echo ""
  echo "===> $*"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "Required tool not found: $1"
}

step "Checking prerequisites"
require_tool git
require_tool docker
require_tool curl
docker compose version >/dev/null 2>&1 || fail "docker compose plugin not available"
echo "  git, docker, docker compose, curl: OK"

step "Stopping any existing containers"
if [ -f "${DEPLOY_DIR}/docker-compose.yml" ]; then
  (cd "${DEPLOY_DIR}" && docker compose down --remove-orphans 2>/dev/null) || true
fi
if [ -f "${DEPLOY_DIR}/docker-compose.tls.yml" ]; then
  (cd "${DEPLOY_DIR}" && docker compose -f docker-compose.yml -f docker-compose.tls.yml down --remove-orphans 2>/dev/null) || true
fi

step "Backing up existing .env (if any)"
ENV_BACKUP=""
if [ -f "${DEPLOY_DIR}/.env" ]; then
  ENV_BACKUP="$(mktemp /tmp/mirofish-env-backup.XXXXXX)"
  cp "${DEPLOY_DIR}/.env" "${ENV_BACKUP}"
  echo "  Saved existing .env to ${ENV_BACKUP}"
fi

step "Removing broken deploy directory"
if [ -d "${SERVER_DIR}" ]; then
  rm -rf "${SERVER_DIR}"
  echo "  Removed ${SERVER_DIR}"
fi

step "Cloning repo from branch ${BRANCH}"
git clone --branch "${BRANCH}" --single-branch --depth 1 "${REPO_URL}" "${SERVER_DIR}"
echo "  Cloned to ${SERVER_DIR}"

step "Verifying repo integrity"
(cd "${SERVER_DIR}" && git status >/dev/null 2>&1) || fail "Clone appears broken"
[ -d "${DEPLOY_DIR}/scripts" ] || fail "scripts/ directory missing after clone"
[ -f "${DEPLOY_DIR}/scripts/validate-deploy.sh" ] || fail "validate-deploy.sh missing"
echo "  Repo OK, scripts/ populated"

step "Setting script permissions"
chmod +x "${DEPLOY_DIR}/scripts/"*.sh
echo "  All scripts executable"

step "Creating .env"
if [ -n "${ENV_BACKUP}" ] && [ -f "${ENV_BACKUP}" ]; then
  cp "${ENV_BACKUP}" "${DEPLOY_DIR}/.env"
  echo "  Restored .env from backup"
else
  cp "${DEPLOY_DIR}/.env.example" "${DEPLOY_DIR}/.env"
  echo "  Created .env from .env.example"
fi

set_env_var() {
  local key="$1"
  local value="$2"
  local env_file="${DEPLOY_DIR}/.env"
  local tmp
  tmp="$(mktemp)"
  if [ -f "${env_file}" ]; then
    grep -v "^${key}=" "${env_file}" > "${tmp}" || true
  fi
  printf "%s=%s\n" "${key}" "${value}" >> "${tmp}"
  mv "${tmp}" "${env_file}"
}

set_env_var "MIROFISH_DOMAIN" "${APP_DOMAIN},${ROOT_DOMAIN}"
set_env_var "PORTAL_DOMAIN"   "${PORTAL_DOMAIN}"
set_env_var "ACME_EMAIL"      "${ACME_EMAIL}"
set_env_var "LLM_BASE_URL"    "${LLM_BASE_URL}"
set_env_var "LLM_MODEL_NAME"  "${LLM_MODEL_NAME}"
set_env_var "API_MAX_UPLOAD_SIZE" "100MB"
set_env_var "API_RESPONSE_HEADER_TIMEOUT" "600s"
set_env_var "API_READ_TIMEOUT"  "600s"
set_env_var "API_WRITE_TIMEOUT" "600s"

if [ -n "${LLM_API_KEY}" ]; then
  set_env_var "LLM_API_KEY" "${LLM_API_KEY}"
fi
if [ -n "${ZEP_API_KEY}" ]; then
  set_env_var "ZEP_API_KEY" "${ZEP_API_KEY}"
fi

LLM_KEY_CHECK="$(grep '^LLM_API_KEY=' "${DEPLOY_DIR}/.env" | cut -d= -f2-)"
ZEP_KEY_CHECK="$(grep '^ZEP_API_KEY=' "${DEPLOY_DIR}/.env" | cut -d= -f2-)"
LLM_KEY_CHECK_LOWER="$(printf '%s' "${LLM_KEY_CHECK}" | tr '[:upper:]' '[:lower:]')"
ZEP_KEY_CHECK_LOWER="$(printf '%s' "${ZEP_KEY_CHECK}" | tr '[:upper:]' '[:lower:]')"
if [ -z "${LLM_KEY_CHECK}" ] || [ "${LLM_KEY_CHECK}" = "replace_with_openai_or_compatible_key" ] || [[ "${LLM_KEY_CHECK_LOWER}" == sk-your-* ]] || [[ "${LLM_KEY_CHECK_LOWER}" == sk-replace-* ]] || [[ "${LLM_KEY_CHECK_LOWER}" == "sk-proj-" ]]; then
  echo ""
  echo "  WARNING: LLM_API_KEY is not set. Edit ${DEPLOY_DIR}/.env before starting."
fi
if [ -z "${ZEP_KEY_CHECK}" ] || [ "${ZEP_KEY_CHECK}" = "replace_with_zep_key" ] || [ "${ZEP_KEY_CHECK_LOWER}" = "your-zep-key" ]; then
  echo ""
  echo "  WARNING: ZEP_API_KEY is not set. Edit ${DEPLOY_DIR}/.env before starting."
fi

echo "  .env written to ${DEPLOY_DIR}/.env"

step "Creating required directories"
mkdir -p "${DEPLOY_DIR}/uploads"
echo "  uploads/ ready"

step "Running validate-deploy (TLS mode)"
cd "${DEPLOY_DIR}"
bash scripts/validate-deploy.sh --mode tls
echo "  Validation passed"

step "Rendering Caddyfile from template"
bash scripts/render-caddyfile.sh
echo "  Caddyfile rendered"

step "Pulling latest images"
docker compose -f docker-compose.yml -f docker-compose.tls.yml pull
echo "  Images pulled"

step "Starting stack"
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d --force-recreate
echo "  Containers started"

step "Waiting for health checks (up to 120s)"
TIMEOUT=120
ELAPSED=0
INTERVAL=10
while [ "${ELAPSED}" -lt "${TIMEOUT}" ]; do
  HEALTHY="$(docker compose -f docker-compose.yml -f docker-compose.tls.yml ps --format json 2>/dev/null | grep -c '"healthy"' || true)"
  TOTAL="$(docker compose -f docker-compose.yml -f docker-compose.tls.yml ps --format json 2>/dev/null | wc -l || true)"
  echo "  ${ELAPSED}s: ${HEALTHY}/${TOTAL} containers healthy"
  if [ "${HEALTHY}" -ge 3 ] 2>/dev/null; then
    echo "  All containers healthy!"
    break
  fi
  sleep "${INTERVAL}"
  ELAPSED=$((ELAPSED + INTERVAL))
done

step "Container status"
docker compose -f docker-compose.yml -f docker-compose.tls.yml ps

step "Running smoke check"
bash scripts/smoke-check.sh \
  --app "https://${ROOT_DOMAIN}" \
  --portal "https://${PORTAL_DOMAIN}" \
  --api "https://${ROOT_DOMAIN}/api/simulation/history?limit=1" || true

echo ""
echo "==========================================="
echo "  Bootstrap complete."
echo "  Deploy dir: ${DEPLOY_DIR}"
echo "  App:        https://${APP_DOMAIN}"
echo "  Root:       https://${ROOT_DOMAIN}"
echo "  Portal:     https://${PORTAL_DOMAIN}"
echo "==========================================="
