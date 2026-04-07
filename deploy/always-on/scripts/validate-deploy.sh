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

validate_domain_list() {
  local name="$1"
  local value="$2"
  [ -n "${value}" ] || fail "${name} cannot be empty"
  if [[ "${value}" == *" "* ]]; then
    fail "${name} contains spaces: ${value}"
  fi
}

validate_not_placeholder() {
  local name="$1"
  local value="$2"
  local lowered
  lowered="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${lowered}" == *"replace_with_"* || "${lowered}" == *"example.com"* ]]; then
    fail "${name} still contains placeholder values: ${value}"
  fi
}

validate_not_sample_key() {
  local name="$1"
  local value="$2"
  local lowered
  lowered="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"

  # Keep this list aligned with placeholder examples used in deployment docs/scripts.
  case "${lowered}" in
    sk-your-*|sk-replace-*|your-zep-key|replace_with_zep_key|replace_with_openai_or_compatible_key)
      fail "${name} is using a sample key value: ${value}"
      ;;
  esac
}

validate_email() {
  local name="$1"
  local value="$2"
  if ! [[ "${value}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    fail "${name} must be a valid email address (got: ${value})"
  fi
}

main() {
  require_file "${ENV_FILE}"
  require_file "${BASE_COMPOSE}"

  require_var "LLM_API_KEY"
  require_var "ZEP_API_KEY"
  local llm_api_key zep_api_key
  llm_api_key="$(read_var "LLM_API_KEY")"
  zep_api_key="$(read_var "ZEP_API_KEY")"
  validate_not_placeholder "LLM_API_KEY" "${llm_api_key}"
  validate_not_placeholder "ZEP_API_KEY" "${zep_api_key}"
  validate_not_sample_key "LLM_API_KEY" "${llm_api_key}"
  validate_not_sample_key "ZEP_API_KEY" "${zep_api_key}"

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
      local app_domains portal_domains acme_email
      app_domains="$(read_var "MIROFISH_DOMAIN")"
      portal_domains="$(read_var "PORTAL_DOMAIN")"
      acme_email="$(read_var "ACME_EMAIL")"

      validate_domain_list "MIROFISH_DOMAIN" "${app_domains}"
      validate_domain_list "PORTAL_DOMAIN" "${portal_domains}"
      validate_not_placeholder "MIROFISH_DOMAIN" "${app_domains}"
      validate_not_placeholder "PORTAL_DOMAIN" "${portal_domains}"
      validate_email "ACME_EMAIL" "${acme_email}"

      (
        cd "${ROOT_DIR}"
        docker compose -f docker-compose.yml -f docker-compose.tls.yml config >/dev/null
      ) || fail "docker compose config failed (tls mode)"

      (
        cd "${ROOT_DIR}"
        bash "${RENDER_SCRIPT}" >/dev/null
      ) || fail "Caddyfile render failed"

      echo "Deploy preflight checks passed (${MODE} mode)."
      echo "  App domains:    ${app_domains}"
      echo "  Portal domains: ${portal_domains}"
      echo "  ACME email:     ${acme_email}"
      ;;
    *)
      fail "Unknown mode '${MODE}'. Use one of: base, tls, all"
      ;;
  esac
}

main "$@"
