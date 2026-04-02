#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/workspace/MiroFish"
REPO_URL="https://github.com/666ghj/MiroFish.git"

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "Cannot run privileged command (sudo not available): $*" >&2
    return 1
  fi
}

ensure_python_312() {
  if command -v python3.12 >/dev/null 2>&1; then
    return
  fi

  echo "python3.12 not found; attempting apt install..."
  run_as_root apt-get update -y
  run_as_root apt-get install -y python3.12 python3.12-venv python3-pip
}

ensure_node_18_plus() {
  local major=0
  if command -v node >/dev/null 2>&1; then
    major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  fi

  if [ "${major}" -ge 18 ]; then
    return
  fi

  echo "Node.js >=18 not found; installing Node 20 via nvm..."
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [ ! -s "${NVM_DIR}/nvm.sh" ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
  fi

  # shellcheck disable=SC1090
  . "${NVM_DIR}/nvm.sh"
  nvm install 20
  nvm alias default 20
  nvm use default
}

ensure_uv() {
  export PATH="$HOME/.local/bin:$PATH"
  if command -v uv >/dev/null 2>&1; then
    return
  fi

  local py_bin="python3"
  if command -v python3.12 >/dev/null 2>&1; then
    py_bin="python3.12"
  fi

  "${py_bin}" -m pip install --user --upgrade pip
  "${py_bin}" -m pip install --user uv
}

clone_or_refresh_repo() {
  if [ ! -d "${REPO_DIR}/.git" ]; then
    git clone "${REPO_URL}" "${REPO_DIR}"
    return
  fi

  git -C "${REPO_DIR}" remote set-url origin "${REPO_URL}" || true
}

prewarm_dependencies() {
  cd "${REPO_DIR}"
  cp --update=none .env.example .env || true
  export PATH="$HOME/.local/bin:$PATH"
  npm run setup:all
}

main() {
  ensure_python_312
  ensure_node_18_plus
  ensure_uv
  clone_or_refresh_repo
  prewarm_dependencies

  cd "${REPO_DIR}"
  export PATH="$HOME/.local/bin:$PATH"
  echo "Environment ready:"
  node -v
  npm -v
  python3 --version
  uv --version
}

main "$@"
