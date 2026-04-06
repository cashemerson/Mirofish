#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/workspace/MiroFish"

cd "${REPO_DIR}"
export PATH="$HOME/.local/bin:$PATH"
export __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS="${__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS:-.agent.cvm.dev,.cursorvm.com}"
if [ -f "${REPO_DIR}/.env" ] && [ -f "${REPO_DIR}/.cursor/configure-local-llm-provider.sh" ] && [ "${MIROFISH_LOCAL_LLM_PROVIDER:-}" = "ollama" ]; then
  "${REPO_DIR}/.cursor/configure-local-llm-provider.sh" --provider ollama --env-file "${REPO_DIR}/.env" >/dev/null || true
fi

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
