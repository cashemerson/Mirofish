#!/usr/bin/env bash
set -euo pipefail

echo "Portal basic auth has been removed from this deployment profile."
echo "No hash is required. Use ./scripts/validate-deploy.sh --mode tls and ./scripts/render-caddyfile.sh."

