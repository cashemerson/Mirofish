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

  local mirofish_domain portal_domain acme_email auth_user auth_hash
  mirofish_domain="$(read_env_value "MIROFISH_DOMAIN")"
  portal_domain="$(read_env_value "PORTAL_DOMAIN")"
  acme_email="$(read_env_value "ACME_EMAIL")"
  auth_user="$(read_env_value "PORTAL_BASIC_AUTH_USER")"
  auth_hash="$(read_env_value "PORTAL_BASIC_AUTH_HASH")"

  [ -n "${auth_hash}" ] || fail "PORTAL_BASIC_AUTH_HASH resolved to an empty value"

  awk -v mirofish_domain="${mirofish_domain}" \
      -v portal_domain="${portal_domain}" \
      -v acme_email="${acme_email}" \
      -v auth_user="${auth_user}" \
      -v auth_hash="${auth_hash}" '
      {
        gsub(/\{\$MIROFISH_DOMAIN\}/, mirofish_domain)
        gsub(/\{\$PORTAL_DOMAIN\}/, portal_domain)
        gsub(/\{\$ACME_EMAIL\}/, acme_email)
        gsub(/\{\$PORTAL_BASIC_AUTH_USER\}/, auth_user)
        gsub(/\{\$PORTAL_BASIC_AUTH_HASH\}/, auth_hash)
        print
      }
    ' "${TEMPLATE_FILE}" > "${TARGET_FILE}"

  echo "Rendered ${TARGET_FILE} from ${TEMPLATE_FILE}."
}

main "$@"
