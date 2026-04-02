#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${DEPLOY_DIR}/.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "Missing ${ENV_FILE}. Create it from .env.example first." >&2
  exit 1
fi

if [ "${#}" -lt 1 ]; then
  echo "Usage: $0 '<portal-password>'" >&2
  exit 1
fi

PASSWORD="${1}"
HASH="$(docker run --rm caddy:2.8-alpine caddy hash-password --plaintext "${PASSWORD}")"

# Wrap in single quotes so Docker Compose reads "$" literally.
LINE="PORTAL_BASIC_AUTH_HASH='${HASH}'"

if grep -q '^PORTAL_BASIC_AUTH_HASH=' "${ENV_FILE}"; then
  sed -i "s|^PORTAL_BASIC_AUTH_HASH=.*|${LINE}|" "${ENV_FILE}"
else
  printf "\n%s\n" "${LINE}" >> "${ENV_FILE}"
fi

echo "Wrote PORTAL_BASIC_AUTH_HASH to ${ENV_FILE}."
echo "Next: run ./scripts/validate-deploy.sh then docker compose up."
