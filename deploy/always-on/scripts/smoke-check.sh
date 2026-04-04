#!/usr/bin/env bash
set -euo pipefail

APP_URL="${APP_URL:-https://app.cesimulation.it.com}"
PORTAL_URL="${PORTAL_URL:-https://portal.cesimulation.it.com}"
API_PATH="${API_PATH:-/api/simulation/history?limit=1}"

usage() {
  cat <<'EOF'
Usage: ./scripts/smoke-check.sh [--app URL] [--portal URL] [--api URL_OR_PATH]

Examples:
  ./scripts/smoke-check.sh \
    --app https://app.example.com \
    --portal https://portal.example.com \
    --api /api/simulation/history?limit=1

  ./scripts/smoke-check.sh \
    --app https://app.example.com \
    --portal https://portal.example.com \
    --api https://app.example.com/api/simulation/history?limit=1
EOF
}

while [ "${#}" -gt 0 ]; do
  case "${1}" in
    --app)
      shift
      APP_URL="${1:-}"
      ;;
    --portal)
      shift
      PORTAL_URL="${1:-}"
      ;;
    --api)
      shift
      API_PATH="${1:-}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: ${1}" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

[ -n "${APP_URL}" ] || { echo "APP_URL cannot be empty"; exit 1; }
[ -n "${PORTAL_URL}" ] || { echo "PORTAL_URL cannot be empty"; exit 1; }

if [[ "${API_PATH}" == http://* || "${API_PATH}" == https://* ]]; then
  API_URL="${API_PATH}"
else
  API_URL="${APP_URL}${API_PATH}"
fi

echo "Running smoke checks..."
echo "  APP_URL=${APP_URL}"
echo "  PORTAL_URL=${PORTAL_URL}"
echo

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found in PATH" >&2
  exit 1
fi

if ! docker compose ps >/dev/null 2>&1; then
  echo "ERROR: docker compose stack is not accessible from this directory" >&2
  exit 1
fi

echo "== Container status =="
docker compose ps
echo

echo "== Public endpoint checks =="
fetch_http_status() {
  local url="$1"
  local status
  status="$(curl -skL --connect-timeout 5 --max-time 15 -o /dev/null -w "%{http_code}" "${url}" || true)"
  if [ -z "${status}" ]; then
    status="000"
  fi
  printf "%s" "${status}"
}

check_with_retry() {
  local label="$1"
  local url="$2"
  local attempts="${3:-6}"
  local delay_secs="${4:-5}"
  local status="000"
  local i

  for i in $(seq 1 "${attempts}"); do
    status="$(fetch_http_status "${url}")"
    echo "${label} attempt ${i}/${attempts}: HTTP ${status} (${url})" >&2
    if [ "${status}" != "000" ]; then
      break
    fi
    if [ "${i}" -lt "${attempts}" ]; then
      sleep "${delay_secs}"
    fi
  done

  printf "%s" "${status}"
}

APP_STATUS="$(check_with_retry "App" "${APP_URL}/")"
PORTAL_STATUS_NOAUTH="$(check_with_retry "Portal" "${PORTAL_URL}/")"
API_STATUS="$(check_with_retry "API" "${API_URL}")"

echo "App status: ${APP_STATUS} (expected 200/301/302/307/308)"
echo "Portal status: ${PORTAL_STATUS_NOAUTH} (expected 200)"
echo "API status: ${API_STATUS} (expected 200/4xx JSON, but not 5xx)"
echo

FAIL=0

case "${APP_STATUS}" in
  200|301|302|307|308) ;;
  *) echo "FAIL: app status ${APP_STATUS}"; FAIL=1 ;;
esac

if [ "${PORTAL_STATUS_NOAUTH}" != "200" ]; then
  echo "FAIL: portal should be 200, got ${PORTAL_STATUS_NOAUTH}"
  FAIL=1
fi

case "${API_STATUS}" in
  000)
    echo "FAIL: API endpoint was unreachable after retries"
    FAIL=1
    ;;
  500|502|503|504)
    echo "FAIL: API returned server error ${API_STATUS}"
    FAIL=1
    ;;
esac

if [ "${FAIL}" -ne 0 ]; then
  echo
  echo "Smoke check failed. Last 120 log lines:"
  service_exists() {
    docker compose ps --services 2>/dev/null | grep -Fxq "$1"
  }
  if [ "${APP_STATUS}" = "000" ] || [ "${PORTAL_STATUS_NOAUTH}" = "000" ] || [ "${API_STATUS}" = "000" ]; then
    echo "Hint: one or more endpoints were unreachable (HTTP 000). Check DNS records, TLS issuance, and caddy startup state."
  fi
  for svc in caddy mirofish portal; do
    if service_exists "${svc}"; then
      echo "--- ${svc} ---"
      docker compose logs --tail=120 "${svc}" || true
    fi
  done
  exit 1
fi

echo "Smoke check passed."
