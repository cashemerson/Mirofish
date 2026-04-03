#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${DEPLOY_DIR}/.env"
APP_DOMAIN_DEFAULT="app.cesimulation.it.com"
ROOT_DOMAIN_DEFAULT="cesimulation.it.com"
PORTAL_DOMAIN_DEFAULT="portal.cesimulation.it.com"
ACME_EMAIL_DEFAULT="you@example.com"
APP_DOMAIN=""
ROOT_DOMAIN=""
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
    printf "%s=%s
" "${key}" "${value}" >> "${ENV_FILE}"
  fi
}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/repair-deploy.sh [options]

Options:
  --app-domain <domain>      App host (default: app.cesimulation.it.com)
  --root-domain <domain>     Root/apex host routed to app (default: cesimulation.it.com)
  --portal-domain <domain>   Portal host (default: portal.cesimulation.it.com)
  --acme-email <email>       ACME email for TLS
  -h, --help                 Show help
EOF
}

main() {
  require_tool docker
  require_tool curl
  require_file "${DEPLOY_DIR}/docker-compose.yml"
  require_file "${DEPLOY_DIR}/Caddyfile.template"
  require_file "${DEPLOY_DIR}/portal-nginx.conf"

  mkdir -p "${DEPLOY_DIR}/portal" "${DEPLOY_DIR}/uploads"

  while [ "${#}" -gt 0 ]; do
    case "${1}" in
      --app-domain)
        shift
        [ "${#}" -gt 0 ] || fail "Missing value for --app-domain"
        APP_DOMAIN="${1}"
        ;;
      --root-domain)
        shift
        [ "${#}" -gt 0 ] || fail "Missing value for --root-domain"
        ROOT_DOMAIN="${1}"
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
  ROOT_DOMAIN="${ROOT_DOMAIN:-$ROOT_DOMAIN_DEFAULT}"
  PORTAL_DOMAIN="${PORTAL_DOMAIN:-$PORTAL_DOMAIN_DEFAULT}"
  ACME_EMAIL="${ACME_EMAIL:-$ACME_EMAIL_DEFAULT}"

  if [ ! -f "${ENV_FILE}" ]; then
    [ -f "${DEPLOY_DIR}/.env.example" ] || fail ".env missing and .env.example not found"
    cp "${DEPLOY_DIR}/.env.example" "${ENV_FILE}"
  fi

  ensure_env_var "MIROFISH_DOMAIN" "${APP_DOMAIN},${ROOT_DOMAIN}"
  ensure_env_var "PORTAL_DOMAIN" "${PORTAL_DOMAIN}"
  ensure_env_var "ACME_EMAIL" "${ACME_EMAIL}"
  ensure_env_var "API_MAX_UPLOAD_SIZE" "64MB"
  ensure_env_var "API_RESPONSE_HEADER_TIMEOUT" "600s"
  ensure_env_var "API_READ_TIMEOUT" "600s"
  ensure_env_var "API_WRITE_TIMEOUT" "600s"

  cat > "${DEPLOY_DIR}/docker-compose.yml" <<EOF
services:
  portal:
    image: nginx:1.27-alpine
    container_name: mirofish-portal
    restart: unless-stopped
    depends_on:
      mirofish:
        condition: service_healthy
    volumes:
      - ./portal:/usr/share/nginx/html:ro
      - ./portal-nginx.conf:/etc/nginx/conf.d/default.conf:ro
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8080/ || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 8
      start_period: 20s

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
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:5001/api/simulation/history?limit=1 || exit 1"]
      interval: 20s
      timeout: 8s
      retries: 10
      start_period: 45s

  caddy:
    image: caddy:2.8-alpine
    container_name: mirofish-caddy
    restart: unless-stopped
    depends_on:
      portal:
        condition: service_healthy
      mirofish:
        condition: service_healthy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    command: ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:2019/config/ || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 8
      start_period: 20s

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
${APP_DOMAIN}, ${ROOT_DOMAIN} {
  encode zstd gzip
  tls ${ACME_EMAIL}
  @api path /api/*
  handle @api {
    request_body {
      max_size ${API_MAX_UPLOAD_SIZE:-64MB}
    }
    reverse_proxy mirofish:5001 {
      header_up Host localhost
      flush_interval -1
      transport http {
        dial_timeout 10s
        response_header_timeout ${API_RESPONSE_HEADER_TIMEOUT:-600s}
        read_timeout ${API_READ_TIMEOUT:-600s}
        write_timeout ${API_WRITE_TIMEOUT:-600s}
      }
    }
  }
  reverse_proxy mirofish:3000 {
    header_up Host localhost
    transport http {
      dial_timeout 10s
      response_header_timeout 120s
    }
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
    APP_URL="https://${ROOT_DOMAIN}" PORTAL_URL="https://${PORTAL_DOMAIN}"       "${DEPLOY_DIR}/scripts/smoke-check.sh" || true
  fi
}

main "$@"
