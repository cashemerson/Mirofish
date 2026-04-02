#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/workspace/MiroFish"

cd "${REPO_DIR}"
export PATH="$HOME/.local/bin:$PATH"
export __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS="${__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS:-.agent.cvm.dev,.cursorvm.com}"

# Ensure expected ports are free before starting the dev stack.
if command -v lsof >/dev/null 2>&1; then
  for port in 3000 5001; do
    pids="$(lsof -t -iTCP:${port} -sTCP:LISTEN 2>/dev/null || true)"
    if [ -n "${pids}" ]; then
      kill ${pids} || true
    fi
  done
fi

sleep 1
exec npm run dev
