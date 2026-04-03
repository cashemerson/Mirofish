#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${DEPLOY_DIR}/.env"
APP_DOMAIN_DEFAULT="app.cesimulation.it.com"
PORTAL_DOMAIN_DEFAULT="portal.cesimulation.it.com"
ACME_EMAIL_DEFAULT="you@example.com"
APP_DOMAIN=""
PORTAL_DOMAIN=""
ACME_EMAIL=""

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_tool() {
  local tool="$1"
  command -v "${tool}" >/dev/null 2>&1 || fail "Required command not found: ${tool}"
}

require_file() {
  local path="$1"
  [ -f "${path}" ] || fail "Missing required file: ${path}"
}

ensure_env_var() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
  else
    printf "%s=%s\n" "${key}" "${value}" >> "${ENV_FILE}"
  fi
}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/repair-deploy.sh [options]

Options:
  --app-domain <domain>      App host (default: app.cesimulation.it.com)
  --portal-domain <domain>   Portal host (default: portal.cesimulation.it.com)
  --acme-email <email>       ACME email for TLS
  -h, --help                 Show help
EOF
}

read_env_value() {
  local key="$1"
  local line value
  line="$(grep -E "^${key}=" "${ENV_FILE}" | tail -n 1 || true)"
  [ -n "${line}" ] || fail "Missing ${key} in ${ENV_FILE}"
  value="${line#*=}"
  if [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf "%s" "${value}"
}

prompt_if_empty() {
  local var_name="$1"
  local prompt="$2"
  local is_secret="${3:-false}"
  local current="${!var_name:-}"
  if [ -n "${current}" ]; then
    return
  fi
  if [ "${is_secret}" = "true" ]; then
    read -r -s -p "${prompt}: " current
    echo
  else
    read -r -p "${prompt}: " current
  fi
  [ -n "${current}" ] || fail "${var_name} cannot be empty"
  printf -v "${var_name}" "%s" "${current}"
}

main() {
  require_tool docker
  require_tool curl
  require_tool awk
  require_file "${DEPLOY_DIR}/docker-compose.yml"
  require_file "${DEPLOY_DIR}/Caddyfile.template"
  require_file "${DEPLOY_DIR}/portal-nginx.conf"
  require_file "${DEPLOY_DIR}/scripts/render-caddyfile.sh"
  require_file "${DEPLOY_DIR}/scripts/validate-deploy.sh"

  mkdir -p "${DEPLOY_DIR}/portal" "${DEPLOY_DIR}/uploads"

  while [ "${#}" -gt 0 ]; do
    case "${1}" in
      --app-domain)
        shift
        [ "${#}" -gt 0 ] || fail "Missing value for --app-domain"
        APP_DOMAIN="${1}"
        ;;
      --portal-domain)
        shift
        [ "${#}" -gt 0 ] || fail "Missing value for --portal-domain"
        PORTAL_DOMAIN="${1}"
        ;;
      --acme-email)
        shift
        [ "${#}" -gt 0 ] || fail "Missing value for --acme-email"
        ACME_EMAIL="${1}"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: ${1}"
        ;;
    esac
    shift
  done

  APP_DOMAIN="${APP_DOMAIN:-$APP_DOMAIN_DEFAULT}"
  PORTAL_DOMAIN="${PORTAL_DOMAIN:-$PORTAL_DOMAIN_DEFAULT}"
  ACME_EMAIL="${ACME_EMAIL:-$ACME_EMAIL_DEFAULT}"
  if [ ! -f "${ENV_FILE}" ]; then
    [ -f "${DEPLOY_DIR}/.env.example" ] || fail ".env missing and .env.example not found"
    cp "${DEPLOY_DIR}/.env.example" "${ENV_FILE}"
  fi

  # Keep existing provider keys from .env; only normalize deployment vars.
  ensure_env_var "MIROFISH_DOMAIN" "${APP_DOMAIN}"
  ensure_env_var "PORTAL_DOMAIN" "${PORTAL_DOMAIN}"
  ensure_env_var "ACME_EMAIL" "${ACME_EMAIL}"

  # Replace service definition with hardened compose baseline.
  cat > "${DEPLOY_DIR}/docker-compose.yml" <<EOF
services:
  portal:
    image: nginx:1.27-alpine
    container_name: mirofish-portal
    restart: unless-stopped
    depends_on:
      - mirofish
    volumes:
      - ./portal:/usr/share/nginx/html:ro
      - ./portal-nginx.conf:/etc/nginx/conf.d/default.conf:ro

  mirofish:
    image: ghcr.io/666ghj/mirofish:latest
    container_name: mirofish
    restart: unless-stopped
    env_file:
      - .env
    environment:
      - __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=\${MIROFISH_DOMAIN:-localhost},\${PORTAL_DOMAIN:-localhost},localhost,127.0.0.1
    volumes:
      - ./uploads:/app/backend/uploads
 
  caddy:
    image: caddy:2.8-alpine
    container_name: mirofish-caddy
    restart: unless-stopped
    depends_on:
      - portal
      - mirofish
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    command: ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]

volumes:
  caddy_data:
  caddy_config:
EOF

  cat > "${DEPLOY_DIR}/portal-nginx.conf" <<'EOF'
server {
  listen 8080;
  server_name _;
  root /usr/share/nginx/html;
  index index.html;
  location / {
    try_files $uri /index.html;
  }
}
EOF

  if [ ! -f "${DEPLOY_DIR}/portal/index.html" ]; then
    if ! curl -fsSL "https://raw.githubusercontent.com/cashemerson/Mirofish/refs/heads/cursor/mirofish-next-step-abb5/portal/index.html" -o "${DEPLOY_DIR}/portal/index.html"; then
      cat > "${DEPLOY_DIR}/portal/index.html" <<'EOF'
<!doctype html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>MiroFish Portal</title></head><body><h1>MiroFish Portal</h1><p>Portal page is missing. Restore portal/index.html from repository.</p></body></html>
EOF
    fi
  fi

  cat > "${DEPLOY_DIR}/Caddyfile" <<EOF
${APP_DOMAIN} {
  encode zstd gzip
  tls ${ACME_EMAIL}
  @api path /api/*
  handle @api {
    reverse_proxy mirofish:5001 {
      header_up Host localhost
    }
  }
  reverse_proxy mirofish:3000 {
    header_up Host localhost
  }
}

${PORTAL_DOMAIN} {
  encode zstd gzip
  tls ${ACME_EMAIL}
  reverse_proxy portal:8080
}
EOF

  docker compose -f "${DEPLOY_DIR}/docker-compose.yml" config >/dev/null
  docker compose -f "${DEPLOY_DIR}/docker-compose.yml" up -d --force-recreate
  docker compose -f "${DEPLOY_DIR}/docker-compose.yml" ps

  if [ -x "${DEPLOY_DIR}/scripts/smoke-check.sh" ]; then
    APP_URL="https://${APP_DOMAIN}" PORTAL_URL="https://${PORTAL_DOMAIN}" \
      "${DEPLOY_DIR}/scripts/smoke-check.sh" || true
  fi
}

main "$@"
