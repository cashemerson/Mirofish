#!/usr/bin/env bash
set -euo pipefail

APP_URL="${APP_URL:-https://cesimulation.it.com}"
PORTAL_URL="${PORTAL_URL:-}"
API_GENERATE_PATH="${API_GENERATE_PATH:-/api/graph/ontology/generate}"
API_URL_OVERRIDE="${API_URL_OVERRIDE:-}"
COMPOSE_BASE="${COMPOSE_BASE:-docker-compose.yml}"
COMPOSE_TLS="${COMPOSE_TLS:-docker-compose.tls.yml}"
WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"

usage() {
  cat <<'EOF'
Usage: ./scripts/diagnose-network-error.sh [--app URL] [--portal URL] [--api-path PATH] [--api URL]

Examples:
  ./scripts/diagnose-network-error.sh --app https://cesimulation.it.com
  ./scripts/diagnose-network-error.sh --app https://app.example.com --api-path /api/graph/ontology/generate
  ./scripts/diagnose-network-error.sh --app https://app.example.com --portal https://portal.example.com --api https://app.example.com/api/graph/ontology/generate
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
    --api-path)
      shift
      API_GENERATE_PATH="${1:-}"
      ;;
    --api)
      shift
      API_URL_OVERRIDE="${1:-}"
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
[ -n "${API_GENERATE_PATH}" ] || { echo "API_GENERATE_PATH cannot be empty"; exit 1; }

if [[ "${API_GENERATE_PATH}" != /* ]] && [ -z "${API_URL_OVERRIDE}" ]; then
  echo "API path must start with '/' unless --api is provided." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found" >&2
  exit 1
fi

cd "${WORK_DIR}"

compose_cmd=(docker compose -f "${COMPOSE_BASE}")
if [ -f "${COMPOSE_TLS}" ]; then
  compose_cmd+=( -f "${COMPOSE_TLS}" )
fi

if [ -n "${API_URL_OVERRIDE}" ]; then
  API_URL="${API_URL_OVERRIDE}"
else
  API_URL="${APP_URL}${API_GENERATE_PATH}"
fi

echo "== Container status =="
"${compose_cmd[@]}" ps || true
echo

echo "== Health checks from host =="
echo "App root:"
curl -skS -o /dev/null -w "HTTP %{http_code}\n" "${APP_URL}/" || true

if [ -n "${PORTAL_URL}" ]; then
  echo "Portal root:"
  curl -skS -o /dev/null -w "HTTP %{http_code}\n" "${PORTAL_URL}/" || true
fi

echo "API generate endpoint (GET should be non-5xx even if method not allowed):"
curl -skS -o /dev/null -w "HTTP %{http_code}\n" "${API_URL}" || true
echo "API generate endpoint (POST should be non-404/non-5xx):"
POST_STATUS="$(curl -skS -o /dev/null -w "%{http_code}" -X POST -d '' "${API_URL}" || true)"
echo "HTTP ${POST_STATUS}"
if [ "${POST_STATUS}" = "404" ]; then
  echo "WARNING: POST ${API_URL} returned 404 (frontend/backend or proxy route mismatch likely)."
elif [[ "${POST_STATUS}" =~ ^5 ]]; then
  echo "WARNING: POST ${API_URL} returned ${POST_STATUS} (backend/proxy runtime error)."
fi
echo

echo "== In-container connectivity tests =="
echo "caddy -> mirofish:5001 (/api/simulation/history?limit=1)"
"${compose_cmd[@]}" exec -T caddy sh -lc \
  "wget -q -S -O /dev/null 'http://mirofish:5001/api/simulation/history?limit=1' 2>&1 | sed -n '1,12p'" || true
echo

echo "== Recent logs (tail 120) =="
echo "--- caddy ---"
"${compose_cmd[@]}" logs --tail=120 caddy || true
echo
echo "--- mirofish ---"
"${compose_cmd[@]}" logs --tail=120 mirofish || true
echo

echo "Diagnosis complete."
echo "If you see upstream timeout errors in caddy logs, the new proxy timeout settings are required."
