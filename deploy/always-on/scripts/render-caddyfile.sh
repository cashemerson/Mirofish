#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
TEMPLATE_FILE="${ROOT_DIR}/Caddyfile.template"
TARGET_FILE="${ROOT_DIR}/Caddyfile"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_file() {
  local file="$1"
  [ -f "${file}" ] || fail "Missing required file: ${file}"
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

main() {
  require_file "${ENV_FILE}"
  require_file "${TEMPLATE_FILE}"

  local mirofish_domain portal_domain acme_email
  mirofish_domain="$(read_env_value "MIROFISH_DOMAIN")"
  portal_domain="$(read_env_value "PORTAL_DOMAIN")"
  acme_email="$(read_env_value "ACME_EMAIL")"

  awk -v mirofish_domain="${mirofish_domain}" \
      -v portal_domain="${portal_domain}" \
      -v acme_email="${acme_email}" '
      {
        gsub(/\{\$MIROFISH_DOMAIN\}/, mirofish_domain)
        gsub(/\{\$PORTAL_DOMAIN\}/, portal_domain)
        gsub(/\{\$ACME_EMAIL\}/, acme_email)
        print
      }
    ' "${TEMPLATE_FILE}" > "${TARGET_FILE}"

  echo "Rendered ${TARGET_FILE} from ${TEMPLATE_FILE}."
}

main "$@"
