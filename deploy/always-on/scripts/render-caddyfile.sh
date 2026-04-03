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

read_env_value_default() {
  local key="$1"
  local default_value="$2"
  local line value
  line="$(grep -E "^${key}=" "${ENV_FILE}" | tail -n 1 || true)"
  if [ -z "${line}" ]; then
    printf "%s" "${default_value}"
    return 0
  fi
  value="${line#*=}"
  if [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf "%s" "${value}"
}

join_domains_for_caddy_site() {
  local value="$1"
  value="${value//,/ }"
  value="$(echo "${value}" | tr -s ' ' | sed -E 's/^ +| +$//g')"
  printf "%s" "${value}"
}

main() {
  require_file "${ENV_FILE}"
  require_file "${TEMPLATE_FILE}"

  local app_hosts_raw portal_hosts_raw app_hosts portal_hosts acme_email
  local api_max_upload_size api_response_header_timeout api_read_timeout api_write_timeout
  app_hosts_raw="$(read_env_value "MIROFISH_DOMAIN")"
  portal_hosts_raw="$(read_env_value "PORTAL_DOMAIN")"
  app_hosts="$(join_domains_for_caddy_site "${app_hosts_raw}")"
  portal_hosts="$(join_domains_for_caddy_site "${portal_hosts_raw}")"
  acme_email="$(read_env_value "ACME_EMAIL")"
  api_max_upload_size="$(read_env_value_default "API_MAX_UPLOAD_SIZE" "100MB")"
  api_response_header_timeout="$(read_env_value_default "API_RESPONSE_HEADER_TIMEOUT" "600s")"
  api_read_timeout="$(read_env_value_default "API_READ_TIMEOUT" "600s")"
  api_write_timeout="$(read_env_value_default "API_WRITE_TIMEOUT" "600s")"

  [ -n "${app_hosts}" ] || fail "MIROFISH_DOMAIN resolved to empty host list"
  [ -n "${portal_hosts}" ] || fail "PORTAL_DOMAIN resolved to empty host list"

  awk -v app_hosts="${app_hosts}" \
      -v portal_hosts="${portal_hosts}" \
      -v acme_email="${acme_email}" '
      {
        gsub(/__APP_HOSTS__/, app_hosts)
        gsub(/__PORTAL_HOSTS__/, portal_hosts)
        gsub(/__ACME_EMAIL__/, acme_email)
        gsub(/__API_MAX_UPLOAD_SIZE__/, "'"${api_max_upload_size}"'")
        gsub(/__API_RESPONSE_HEADER_TIMEOUT__/, "'"${api_response_header_timeout}"'")
        gsub(/__API_READ_TIMEOUT__/, "'"${api_read_timeout}"'")
        gsub(/__API_WRITE_TIMEOUT__/, "'"${api_write_timeout}"'")
        print
      }
    ' "${TEMPLATE_FILE}" > "${TARGET_FILE}"

  echo "Rendered ${TARGET_FILE} from ${TEMPLATE_FILE}."
}

main "$@"
