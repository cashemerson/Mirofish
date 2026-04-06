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

patch_vite_allowed_hosts() {
  local vite_config="${REPO_DIR}/frontend/vite.config.js"
  if [ ! -f "${vite_config}" ]; then
    return
  fi

  python3 - "${vite_config}" <<'PY'
import pathlib
import re
import sys

cfg_path = pathlib.Path(sys.argv[1])
text = cfg_path.read_text(encoding="utf-8")
required_hosts = [
    ".cursorvm.com",
    ".agent.cvm.dev",
    "localhost",
    "127.0.0.1",
]

if "server:" not in text:
    sys.exit(0)

def insert_allowed_hosts_block(src: str) -> str:
    block = (
        "    allowedHosts: [\n"
        "      '.cursorvm.com',\n"
        "      '.agent.cvm.dev',\n"
        "      'localhost',\n"
        "      '127.0.0.1'\n"
        "    ],\n"
    )

    if "open: true," in src:
        return src.replace("open: true,\n", "open: true,\n" + block, 1)
    if "port: 3000," in src:
        return src.replace("port: 3000,\n", "port: 3000,\n" + block, 1)
    if "server: {" in src:
        return src.replace("server: {\n", "server: {\n" + block, 1)
    return src

allowed_match = re.search(r"allowedHosts:\s*\[(?P<body>.*?)\]", text, flags=re.S)
updated = text

if allowed_match:
    body = allowed_match.group("body")
    missing = [h for h in required_hosts if f"'{h}'" not in body and f'"{h}"' not in body]
    if missing:
        existing_lines = [ln.rstrip() for ln in body.splitlines() if ln.strip()]
        for host in missing:
            existing_lines.append(f"      '{host}',")
        new_body = "\n" + "\n".join(existing_lines) + "\n    "
        updated = (
            text[:allowed_match.start("body")]
            + new_body
            + text[allowed_match.end("body"):]
        )
else:
    updated = insert_allowed_hosts_block(text)

if updated != text:
    cfg_path.write_text(updated, encoding="utf-8")
PY
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
  patch_vite_allowed_hosts
  cp --update=none .env.example .env || true
  if [ -f "${REPO_DIR}/.cursor/configure-local-llm-provider.sh" ]; then
    chmod +x "${REPO_DIR}/.cursor/configure-local-llm-provider.sh" || true
    "${REPO_DIR}/.cursor/configure-local-llm-provider.sh" --provider ollama --env-file "${REPO_DIR}/.env" >/dev/null || true
  fi
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
