#!/usr/bin/env bash
set -euo pipefail

APP_URL="${APP_URL:-https://app.cesimulation.it.com}"
PORTAL_URL="${PORTAL_URL:-https://portal.cesimulation.it.com}"
API_PATH="${API_PATH:-/api/simulation/history?limit=1}"
ADMIN_USER="${ADMIN_USER:-admin}"

usage() {
  cat <<'EOF'
Usage: ./scripts/smoke-check.sh [--app URL] [--portal URL] [--api URL_OR_PATH] [--user USER]

Examples:
  ./scripts/smoke-check.sh \
    --app https://app.example.com \
    --portal https://portal.example.com \
    --api /api/simulation/history?limit=1 \
    --user admin

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
    --user)
      shift
      ADMIN_USER="${1:-}"
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
[ -n "${ADMIN_USER}" ] || { echo "ADMIN_USER cannot be empty"; exit 1; }

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
APP_STATUS="$(curl -sk -o /dev/null -w "%{http_code}" "${APP_URL}/")"
PORTAL_STATUS_NOAUTH="$(curl -sk -o /dev/null -w "%{http_code}" "${PORTAL_URL}/")"
API_STATUS="$(curl -sk -o /dev/null -w "%{http_code}" "${API_URL}")"

echo "App status: ${APP_STATUS} (expected 200/301/302/307/308)"
echo "Portal status without auth: ${PORTAL_STATUS_NOAUTH} (expected 401)"
echo "API status: ${API_STATUS} (expected 200/4xx JSON, but not 5xx)"
echo

read -r -s -p "Portal password for ${ADMIN_USER}: " ADMIN_PASS
echo

PORTAL_STATUS_AUTH="$(curl -sk -o /dev/null -w "%{http_code}" -u "${ADMIN_USER}:${ADMIN_PASS}" "${PORTAL_URL}/")"
echo "Portal status with auth: ${PORTAL_STATUS_AUTH} (expected 200)"
echo

FAIL=0

case "${APP_STATUS}" in
  200|301|302|307|308) ;;
  *) echo "FAIL: app status ${APP_STATUS}"; FAIL=1 ;;
esac

if [ "${PORTAL_STATUS_NOAUTH}" != "401" ]; then
  echo "FAIL: portal without auth should be 401, got ${PORTAL_STATUS_NOAUTH}"
  FAIL=1
fi

if [ "${PORTAL_STATUS_AUTH}" != "200" ]; then
  echo "FAIL: portal with auth should be 200, got ${PORTAL_STATUS_AUTH}"
  FAIL=1
fi

case "${API_STATUS}" in
  500|502|503|504)
    echo "FAIL: API returned server error ${API_STATUS}"
    FAIL=1
    ;;
esac

if [ "${FAIL}" -ne 0 ]; then
  echo
  echo "Smoke check failed. Last 120 log lines:"
  echo "--- caddy ---"
  docker compose logs --tail=120 caddy || true
  echo "--- mirofish ---"
  docker compose logs --tail=120 mirofish || true
  exit 1
fi

echo "Smoke check passed."
