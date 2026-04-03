#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
CADDY_TEMPLATE="${ROOT_DIR}/Caddyfile.template"
BASE_COMPOSE="${ROOT_DIR}/docker-compose.yml"
TLS_COMPOSE="${ROOT_DIR}/docker-compose.tls.yml"
RENDER_SCRIPT="${ROOT_DIR}/scripts/render-caddyfile.sh"
MODE="all"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./scripts/validate-deploy.sh [--mode base|tls|all]

Modes:
  base  Validate base compose stack only (no TLS overlay requirements)
  tls   Validate TLS overlay requirements and Caddyfile rendering
  all   Same as tls (default)
EOF
}

while [ "${#}" -gt 0 ]; do
  case "${1}" in
    --mode)
      shift
      [ "${#}" -gt 0 ] || fail "Missing value for --mode"
      MODE="${1}"
      ;;
    base|tls|all)
      MODE="${1}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument '${1}'. Use --help for usage."
      ;;
  esac
  shift
done

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
  require_file "${BASE_COMPOSE}"

  require_var "LLM_API_KEY"
  require_var "ZEP_API_KEY"

  if ! command -v docker >/dev/null 2>&1; then
    fail "docker is not installed"
  fi

  if ! docker compose version >/dev/null 2>&1; then
    fail "docker compose plugin is not available"
  fi

  case "${MODE}" in
    base)
      (
        cd "${ROOT_DIR}"
        docker compose -f docker-compose.yml config >/dev/null
      ) || fail "docker compose config failed (base mode)"

      echo "Deploy preflight checks passed (base mode)."
      echo "  Base compose syntax: OK"
      ;;
    tls|all)
      require_file "${CADDY_TEMPLATE}"
      require_file "${TLS_COMPOSE}"
      require_file "${RENDER_SCRIPT}"
      require_var "MIROFISH_DOMAIN"
      require_var "PORTAL_DOMAIN"
      require_var "ACME_EMAIL"
      local app_domain portal_domain acme_email
      app_domain="$(read_var "MIROFISH_DOMAIN")"
      portal_domain="$(read_var "PORTAL_DOMAIN")"
      acme_email="$(read_var "ACME_EMAIL")"

      validate_domain "MIROFISH_DOMAIN" "${app_domain}"
      validate_domain "PORTAL_DOMAIN" "${portal_domain}"

      (
        cd "${ROOT_DIR}"
        docker compose -f docker-compose.yml -f docker-compose.tls.yml config >/dev/null
      ) || fail "docker compose config failed (tls mode)"

      (
        cd "${ROOT_DIR}"
        bash "${RENDER_SCRIPT}" >/dev/null
      ) || fail "Caddyfile render failed"

      echo "Deploy preflight checks passed (${MODE} mode)."
      echo "  App domain:    ${app_domain}"
      echo "  Portal domain: ${portal_domain}"
      echo "  ACME email:    ${acme_email}"
      ;;
    *)
      fail "Unknown mode '${MODE}'. Use one of: base, tls, all"
      ;;
  esac
}

main "$@"
