#!/usr/bin/env bash
set -euo pipefail

APP_URL="${APP_URL:-https://cesimulation.it.com}"
PORTAL_URL="${PORTAL_URL:-https://portal.cesimulation.it.com}"
ONTOLOGY_PATH="${ONTOLOGY_PATH:-/api/graph/ontology/generate}"
WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"

usage() {
  cat <<'EOF'
Usage: ./scripts/triage-ontology-404.sh [--app URL] [--portal URL] [--ontology PATH_OR_URL]

Examples:
  ./scripts/triage-ontology-404.sh --app https://cesimulation.it.com --portal https://portal.cesimulation.it.com
  ./scripts/triage-ontology-404.sh --app https://app.example.com --ontology /api/graph/ontology/generate
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
    --ontology)
      shift
      ONTOLOGY_PATH="${1:-}"
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
[ -n "${ONTOLOGY_PATH}" ] || { echo "ONTOLOGY_PATH cannot be empty"; exit 1; }

cd "${WORK_DIR}"

if [[ "${ONTOLOGY_PATH}" == http://* || "${ONTOLOGY_PATH}" == https://* ]]; then
  ONTOLOGY_URL="${ONTOLOGY_PATH}"
else
  ONTOLOGY_URL="${APP_URL}${ONTOLOGY_PATH}"
fi

echo "== Step 1: Portal/API target sanity =="
echo "Browser should resolve API in this order:"
echo "  1) ?api=... query param"
echo "  2) localStorage key: mirofish_portal_config_v1.apiUrl"
echo "  3) hostname fallback"
echo "Expected app origin: ${APP_URL}"
echo

echo "== Step 2: Fast endpoint status checks =="
echo "App root:"
curl -skS -o /dev/null -w "HTTP %{http_code}\n" "${APP_URL}/" || true
echo "Portal root:"
curl -skS -o /dev/null -w "HTTP %{http_code}\n" "${PORTAL_URL}/" || true
echo "Ontology GET:"
curl -skS -o /dev/null -w "HTTP %{http_code}\n" "${ONTOLOGY_URL}" || true
echo "Ontology POST:"
POST_STATUS="$(curl -skS -o /dev/null -w "%{http_code}" -X POST "${ONTOLOGY_URL}" || true)"
echo "HTTP ${POST_STATUS}"
if [ "${POST_STATUS}" = "404" ]; then
  echo "Signal: 404 on ontology POST indicates routing/deploy mismatch, not API quota."
fi
echo

if command -v docker >/dev/null 2>&1 && docker compose ps >/dev/null 2>&1; then
  echo "== Step 3: Running image/version checks =="
  docker compose images || true
  echo
  echo "Container image refs:"
  docker compose ps --format json | sed -n '1,200p' || true
  echo

  echo "== Step 4: Existing smoke + network diagnostics =="
  bash scripts/smoke-check.sh --app "${APP_URL}" --portal "${PORTAL_URL}" --api /api/simulation/history?limit=1 --ontology "${ONTOLOGY_PATH}" || true
  echo
  bash scripts/diagnose-network-error.sh --app "${APP_URL}" --portal "${PORTAL_URL}" --api "${ONTOLOGY_URL}" || true
else
  echo "Docker compose stack not available locally; skipped container-level checks."
fi

echo
echo "== Step 5: Next action =="
echo "If ontology POST is still 404, redeploy aligned versions of app/backend/proxy and re-run this script."
