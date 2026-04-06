#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/configure-llm-provider.sh --provider ollama|vllm [options]

Required:
  --provider ollama|vllm

Optional:
  --base-url URL      Override LLM_BASE_URL
  --model MODEL       Override LLM_MODEL_NAME
  --api-key KEY       Override LLM_API_KEY (use "none" for local no-key setups)
  --env-file PATH     Use a custom env file path (default: ./deploy/always-on/.env)

Examples:
  # vLLM on same docker network (recommended for production)
  ./scripts/configure-llm-provider.sh --provider vllm --base-url http://vllm:8000/v1 --model Qwen/Qwen2.5-7B-Instruct

  # Ollama via host gateway
  ./scripts/configure-llm-provider.sh --provider ollama --base-url http://host.docker.internal:11434/v1 --model llama3.1:8b
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

set_env_var() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  if [ -f "${ENV_FILE}" ]; then
    grep -v "^${key}=" "${ENV_FILE}" > "${tmp}" || true
  fi
  printf "%s=%s\n" "${key}" "${value}" >> "${tmp}"
  mv "${tmp}" "${ENV_FILE}"
}

PROVIDER=""
BASE_URL=""
MODEL=""
API_KEY=""

while [ "${#}" -gt 0 ]; do
  case "${1}" in
    --provider)
      shift
      [ "${#}" -gt 0 ] || fail "Missing value for --provider"
      PROVIDER="${1}"
      ;;
    --base-url)
      shift
      [ "${#}" -gt 0 ] || fail "Missing value for --base-url"
      BASE_URL="${1}"
      ;;
    --model)
      shift
      [ "${#}" -gt 0 ] || fail "Missing value for --model"
      MODEL="${1}"
      ;;
    --api-key)
      shift
      [ "${#}" -gt 0 ] || fail "Missing value for --api-key"
      API_KEY="${1}"
      ;;
    --env-file)
      shift
      [ "${#}" -gt 0 ] || fail "Missing value for --env-file"
      ENV_FILE="${1}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: ${1}"
      ;;
  esac
  shift
done

[ -n "${PROVIDER}" ] || fail "--provider is required"
[ -f "${ENV_FILE}" ] || fail "Env file not found: ${ENV_FILE}"

case "${PROVIDER}" in
  vllm)
    [ -n "${BASE_URL}" ] || BASE_URL="http://vllm:8000/v1"
    [ -n "${MODEL}" ] || MODEL="Qwen/Qwen2.5-7B-Instruct"
    [ -n "${API_KEY}" ] || API_KEY="none"
    ;;
  ollama)
    [ -n "${BASE_URL}" ] || BASE_URL="http://host.docker.internal:11434/v1"
    [ -n "${MODEL}" ] || MODEL="llama3.1:8b"
    [ -n "${API_KEY}" ] || API_KEY="none"
    ;;
  *)
    fail "--provider must be one of: ollama, vllm"
    ;;
esac

set_env_var "LLM_BASE_URL" "${BASE_URL}"
set_env_var "LLM_MODEL_NAME" "${MODEL}"
set_env_var "LLM_API_KEY" "${API_KEY}"

echo "Updated ${ENV_FILE}:"
echo "  provider      = ${PROVIDER}"
echo "  LLM_BASE_URL  = ${BASE_URL}"
echo "  LLM_MODEL_NAME= ${MODEL}"
echo "  LLM_API_KEY   = ${API_KEY}"
