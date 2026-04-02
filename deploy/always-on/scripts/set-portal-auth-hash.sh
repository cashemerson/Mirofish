#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${DEPLOY_DIR}/.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "Missing ${ENV_FILE}. Create it from .env.example first." >&2
  exit 1
fi

if [ "${#}" -ge 1 ] && [ -n "${1:-}" ]; then
  PASSWORD="${1}"
else
  echo "No password argument supplied; prompting securely." >&2
  read -r -s -p "Portal basic-auth password: " PASSWORD
  echo
fi

if [ -z "${PASSWORD}" ]; then
  echo "Password cannot be empty." >&2
  exit 1
fi

HASH="$(docker run --rm caddy:2.8-alpine caddy hash-password --plaintext "${PASSWORD}")"

# Wrap in single quotes so Docker Compose reads "$" literally.
LINE="PORTAL_BASIC_AUTH_HASH='${HASH}'"

if grep -q '^PORTAL_BASIC_AUTH_HASH=' "${ENV_FILE}"; then
  sed -i "s|^PORTAL_BASIC_AUTH_HASH=.*|${LINE}|" "${ENV_FILE}"
else
  printf "\n%s\n" "${LINE}" >> "${ENV_FILE}"
fi

echo "Wrote PORTAL_BASIC_AUTH_HASH to ${ENV_FILE}."
echo "Next: run ./scripts/validate-deploy.sh --mode tls and ./scripts/render-caddyfile.sh."
