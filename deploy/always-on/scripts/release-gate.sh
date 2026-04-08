#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
APP_URL=""
PORTAL_URL=""
API_URL=""
ROLLBACK_FILE="${ROOT_DIR}/ROLLBACK_READINESS.md"

usage() {
  cat <<'USAGE'
Usage: ./scripts/release-gate.sh [--app URL --portal URL --api URL] [--rollback-file PATH]

Runs deployment release gates:
1) base preflight
2) tls preflight
3) Caddyfile render
4) optional smoke check (if app+portal+api are provided)
5) writes rollback-readiness checklist
USAGE
}

while [ "${#}" -gt 0 ]; do
  case "${1}" in
    --app) shift; APP_URL="${1:-}" ;;
    --portal) shift; PORTAL_URL="${1:-}" ;;
    --api) shift; API_URL="${1:-}" ;;
    --rollback-file) shift; ROLLBACK_FILE="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: ${1}" >&2; usage; exit 1 ;;
  esac
  shift
done

cd "${ROOT_DIR}"

echo "[1/5] validate-deploy base"
bash ./scripts/validate-deploy.sh --mode base

echo "[2/5] validate-deploy tls"
bash ./scripts/validate-deploy.sh --mode tls

echo "[3/5] render Caddyfile"
bash ./scripts/render-caddyfile.sh

if [ -n "${APP_URL}" ] && [ -n "${PORTAL_URL}" ] && [ -n "${API_URL}" ]; then
  echo "[4/5] smoke check"
  bash ./scripts/smoke-check.sh --app "${APP_URL}" --portal "${PORTAL_URL}" --api "${API_URL}"
else
  echo "[4/5] smoke check skipped (pass --app --portal --api to enable)"
fi

CURRENT_REF="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"

cat > "${ROLLBACK_FILE}" <<DOC
# Rollback Readiness Checklist

- Generated at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Branch: ${CURRENT_BRANCH}
- Commit: ${CURRENT_REF}

## Pre-rollback checks

- [ ] Confirm latest successful image digest is known.
- [ ] Confirm previous working Caddyfile is archived.
- [ ] Confirm previous working .env is backed up.

## Rollback commands

\`\`\`bash
cd ${ROOT_DIR}
docker compose -f docker-compose.yml -f docker-compose.tls.yml down
git --no-pager log --oneline -10
git checkout <KNOWN_GOOD_COMMIT>
bash scripts/validate-deploy.sh --mode tls
bash scripts/render-caddyfile.sh
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d --force-recreate
docker compose -f docker-compose.yml -f docker-compose.tls.yml ps
\`\`\`
DOC

echo "[5/5] rollback readiness written to ${ROLLBACK_FILE}"
echo "Release gate passed."
