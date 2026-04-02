#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
CADDY_TEMPLATE="${ROOT_DIR}/Caddyfile.template"
BASE_COMPOSE="${ROOT_DIR}/docker-compose.yml"
TLS_COMPOSE="${ROOT_DIR}/docker-compose.tls.yml"
RENDER_SCRIPT="${ROOT_DIR}/scripts/render-caddyfile.sh"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

require_file() {
  local file="$1"
  [ -f "${file}" ] || fail "Missing required file: ${file}"
}

require_var() {
  local name="$1"
  if ! grep -Eq "^${name}=" "${ENV_FILE}"; then
    fail "Missing ${name} in ${ENV_FILE}"
  fi
}

read_var() {
  local name="$1"
  grep -E "^${name}=" "${ENV_FILE}" | tail -n 1 | sed -E "s/^${name}=//"
}

strip_outer_single_quotes() {
  local value="$1"
  if [[ "${value}" == \'*\' ]]; then
    value="${value:1}"
  fi
  if [[ "${value}" == *\' ]]; then
    value="${value::-1}"
  fi
  printf "%s" "${value}"
}

validate_domain() {
  local name="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    fail "${name} cannot be empty"
  fi
  if [[ "${value}" == *" "* ]]; then
    fail "${name} contains spaces: ${value}"
  fi
}

main() {
  require_file "${ENV_FILE}"
  require_file "${CADDY_TEMPLATE}"
  require_file "${BASE_COMPOSE}"
  require_file "${TLS_COMPOSE}"
  require_file "${RENDER_SCRIPT}"

  require_var "LLM_API_KEY"
  require_var "ZEP_API_KEY"
  require_var "MIROFISH_DOMAIN"
  require_var "PORTAL_DOMAIN"
  require_var "ACME_EMAIL"
  require_var "PORTAL_BASIC_AUTH_USER"
  require_var "PORTAL_BASIC_AUTH_HASH"

  local app_domain portal_domain acme_email auth_user auth_hash_raw auth_hash
  app_domain="$(read_var "MIROFISH_DOMAIN")"
  portal_domain="$(read_var "PORTAL_DOMAIN")"
  acme_email="$(read_var "ACME_EMAIL")"
  auth_user="$(read_var "PORTAL_BASIC_AUTH_USER")"
  auth_hash_raw="$(read_var "PORTAL_BASIC_AUTH_HASH")"
  auth_hash="$(strip_outer_single_quotes "${auth_hash_raw}")"

  validate_domain "MIROFISH_DOMAIN" "${app_domain}"
  validate_domain "PORTAL_DOMAIN" "${portal_domain}"

  if [[ "${auth_hash}" != \$2a\$* && "${auth_hash}" != \$2b\$* && "${auth_hash}" != \$2y\$* ]]; then
    fail "PORTAL_BASIC_AUTH_HASH does not look like a bcrypt hash."
  fi

  if [[ "${auth_hash_raw}" != *'$'* ]]; then
    warn "PORTAL_BASIC_AUTH_HASH does not contain '$'; ensure this is an actual bcrypt value."
  fi

  if ! command -v docker >/dev/null 2>&1; then
    fail "docker is not installed"
  fi

  if ! docker compose version >/dev/null 2>&1; then
    fail "docker compose plugin is not available"
  fi

  (
    cd "${ROOT_DIR}"
    docker compose -f docker-compose.yml -f docker-compose.tls.yml config >/dev/null
  ) || fail "docker compose config failed"

  (
    cd "${ROOT_DIR}"
    bash "${RENDER_SCRIPT}" >/dev/null
  ) || fail "Caddyfile render failed"

  echo "Deploy preflight checks passed."
  echo "  App domain:    ${app_domain}"
  echo "  Portal domain: ${portal_domain}"
  echo "  ACME email:    ${acme_email}"
  echo "  Auth user:     ${auth_user}"
}

main "$@"
