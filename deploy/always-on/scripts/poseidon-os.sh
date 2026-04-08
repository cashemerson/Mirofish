#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
POSEIDON_DIR="${ROOT_DIR}/poseidon"
RUNS_DIR="${POSEIDON_DIR}/runs"
DEFAULT_API_BASE_URL="${POSEIDON_API_BASE_URL:-http://127.0.0.1:5001}"

mkdir -p "${RUNS_DIR}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: ./scripts/poseidon-os.sh <command> [options]

Commands:
  init-run           Create a new Poseidon OS run state
  set-phase          Set autonomy phase (copilot|assisted|guardrailed)
  call               Execute a stage-gated API call with retries/fallbacks
  record-feedback    Record post-run outcome feedback
  dashboard          Generate a run dashboard HTML file
  evaluate           Generate scorecard from run metrics and feedback
  reset-circuit      Reset circuit-breaker consecutive failure counter

Examples:
  ./scripts/poseidon-os.sh init-run --name nba-props-v1
  ./scripts/poseidon-os.sh set-phase --run-id <RUN_ID> --phase assisted
  ./scripts/poseidon-os.sh call --run-id <RUN_ID> --endpoint /api/graph/ontology/generate --form 'simulation_requirement=Find +EV NBA props' --form 'files=@/root/input.pdf'
USAGE
}

csv_escape() {
  local input="${1:-}"
  input="${input//\"/\"\"}"
  printf '"%s"' "${input}"
}

ensure_run_id() {
  [ -n "${RUN_ID:-}" ] || fail "Missing --run-id"
  RUN_DIR="${RUNS_DIR}/${RUN_ID}"
  [ -d "${RUN_DIR}" ] || fail "Run not found: ${RUN_DIR}"
  RUN_ENV="${RUN_DIR}/run.env"
  [ -f "${RUN_ENV}" ] || fail "Missing run state: ${RUN_ENV}"
}

load_run_env() {
  # shellcheck disable=SC1090
  source "${RUN_ENV}"
}

save_run_env() {
  local tmp
  tmp="$(mktemp)"
  cat > "${tmp}" <<ENV
RUN_ID=${RUN_ID}
RUN_NAME=${RUN_NAME}
TARGET_USE_CASE=${TARGET_USE_CASE}
AUTONOMY_PHASE=${AUTONOMY_PHASE}
CONFIDENCE_THRESHOLD=${CONFIDENCE_THRESHOLD}
CIRCUIT_BREAKER_LIMIT=${CIRCUIT_BREAKER_LIMIT}
FALLBACK_API_BASE_URLS=${FALLBACK_API_BASE_URLS}
CURRENT_STAGE=${CURRENT_STAGE}
CONSECUTIVE_FAILURES=${CONSECUTIVE_FAILURES}
CREATED_AT=${CREATED_AT}
UPDATED_AT=${UPDATED_AT}
ENV
  mv "${tmp}" "${RUN_ENV}"
}

validate_phase() {
  case "${1}" in
    copilot|assisted|guardrailed) ;;
    *) fail "Invalid phase '${1}'. Use copilot|assisted|guardrailed" ;;
  esac
}

validate_risk() {
  case "${1}" in
    low|medium|high) ;;
    *) fail "Invalid risk '${1}'. Use low|medium|high" ;;
  esac
}

float_lt() {
  awk -v a="${1}" -v b="${2}" 'BEGIN { exit !(a < b) }'
}

allowed_transition() {
  local stage="$1"
  local endpoint="$2"
  case "${endpoint}" in
    /api/graph/ontology/generate)
      [ "${stage}" = "INIT" ]
      ;;
    /api/graph/build)
      [ "${stage}" = "ONTOLOGY_DONE" ]
      ;;
    /api/simulation/create)
      [ "${stage}" = "GRAPH_DONE" ]
      ;;
    /api/simulation/start)
      [ "${stage}" = "SIMULATION_CREATED" ]
      ;;
    /api/simulation/stop)
      [ "${stage}" = "SIMULATION_RUNNING" ]
      ;;
    /api/report/generate)
      [ "${stage}" = "SIMULATION_STOPPED" ]
      ;;
    /api/report/chat)
      [ "${stage}" = "REPORT_GENERATED" ]
      ;;
    *)
      return 1
      ;;
  esac
}

next_stage() {
  case "${1}" in
    /api/graph/ontology/generate) echo "ONTOLOGY_DONE" ;;
    /api/graph/build) echo "GRAPH_DONE" ;;
    /api/simulation/create) echo "SIMULATION_CREATED" ;;
    /api/simulation/start) echo "SIMULATION_RUNNING" ;;
    /api/simulation/stop) echo "SIMULATION_STOPPED" ;;
    /api/report/generate) echo "REPORT_GENERATED" ;;
    /api/report/chat) echo "REPORT_GENERATED" ;;
    *) fail "No next-stage mapping for endpoint ${1}" ;;
  esac
}

parse_path() {
  local endpoint="$1"
  if [[ "${endpoint}" == http://* || "${endpoint}" == https://* ]]; then
    local without_scheme="${endpoint#*://}"
    local path_part="/${without_scheme#*/}"
    echo "${path_part%%\?*}"
  else
    echo "${endpoint%%\?*}"
  fi
}

init_run() {
  local run_name="poseidon-run"
  local target_use_case="sports_prediction_market_intelligence"
  local phase="copilot"
  local threshold="0.70"
  local breaker_limit="3"
  local fallback_bases=""

  while [ "${#}" -gt 0 ]; do
    case "${1}" in
      --name)
        shift
        run_name="${1:-}"
        ;;
      --target-use-case)
        shift
        target_use_case="${1:-}"
        ;;
      --phase)
        shift
        phase="${1:-}"
        ;;
      --confidence-threshold)
        shift
        threshold="${1:-}"
        ;;
      --circuit-breaker-limit)
        shift
        breaker_limit="${1:-}"
        ;;
      --fallback-api-bases)
        shift
        fallback_bases="${1:-}"
        ;;
      *)
        fail "Unknown argument for init-run: ${1}"
        ;;
    esac
    shift
  done

  [ -n "${run_name}" ] || fail "--name cannot be empty"
  validate_phase "${phase}"

  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-${run_name//[^a-zA-Z0-9._-]/-}-$$-$RANDOM"
  RUN_DIR="${RUNS_DIR}/${RUN_ID}"
  mkdir -p "${RUN_DIR}"
  RUN_ENV="${RUN_DIR}/run.env"

  RUN_NAME="${run_name}"
  TARGET_USE_CASE="${target_use_case}"
  AUTONOMY_PHASE="${phase}"
  CONFIDENCE_THRESHOLD="${threshold}"
  CIRCUIT_BREAKER_LIMIT="${breaker_limit}"
  FALLBACK_API_BASE_URLS="${fallback_bases}"
  CURRENT_STAGE="INIT"
  CONSECUTIVE_FAILURES="0"
  CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  UPDATED_AT="${CREATED_AT}"

  save_run_env

  cat > "${RUN_DIR}/metrics.csv" <<'CSV'
timestamp,endpoint,status_code,latency_seconds,risk,confidence,retries,api_base,result
CSV

  cat > "${RUN_DIR}/feedback.tsv" <<'TSV'
timestamp	outcome	quality_score	business_kpi_delta	notes
TSV

  cat > "${RUN_DIR}/handoff-contracts.md" <<'DOC'
# Poseidon OS v1 Agent Handoff Contracts

- Commander Agent: approves objective, autonomy phase, and high-risk actions.
- Research Agent: prepares requirement context and evidence package.
- Simulation Ops Agent: executes ontology->graph->simulation stages in order.
- Risk Agent: enforces confidence threshold and risk gates before execution.
- Report Agent: generates and validates final report and response chat context.

Each stage requires explicit output artifacts before handoff:
1) Ontology package -> 2) Graph build confirmation -> 3) Simulation run telemetry -> 4) Report outputs.
DOC

  echo "Created Poseidon run: ${RUN_ID}"
  echo "Run directory: ${RUN_DIR}"
  echo "Current stage: INIT"
  echo "Autonomy phase: ${AUTONOMY_PHASE}"
}

set_phase() {
  local phase=""
  while [ "${#}" -gt 0 ]; do
    case "${1}" in
      --run-id)
        shift
        RUN_ID="${1:-}"
        ;;
      --phase)
        shift
        phase="${1:-}"
        ;;
      *) fail "Unknown argument for set-phase: ${1}" ;;
    esac
    shift
  done

  validate_phase "${phase}"
  ensure_run_id
  load_run_env

  AUTONOMY_PHASE="${phase}"
  UPDATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  save_run_env
  echo "Run ${RUN_ID} phase set to ${AUTONOMY_PHASE}"
}

call_stage_gated() {
  local endpoint=""
  local method="POST"
  local json_body=""
  local timeout_secs="120"
  local retries="2"
  local retry_backoff="2"
  local confidence="1.0"
  local risk="medium"
  local approve_high_risk="0"
  local dry_run="0"
  local api_base="${DEFAULT_API_BASE_URL}"
  local quality_score=""
  local cost_usd=""
  local token_usage=""
  local headers=()
  local forms=()

  while [ "${#}" -gt 0 ]; do
    case "${1}" in
      --run-id) shift; RUN_ID="${1:-}" ;;
      --endpoint) shift; endpoint="${1:-}" ;;
      --method) shift; method="${1:-}" ;;
      --json) shift; json_body="${1:-}" ;;
      --form) shift; forms+=("${1:-}") ;;
      --header) shift; headers+=("${1:-}") ;;
      --timeout) shift; timeout_secs="${1:-}" ;;
      --retries) shift; retries="${1:-}" ;;
      --retry-backoff) shift; retry_backoff="${1:-}" ;;
      --confidence) shift; confidence="${1:-}" ;;
      --risk) shift; risk="${1:-}" ;;
      --approve-high-risk) approve_high_risk="1" ;;
      --dry-run) dry_run="1" ;;
      --api-base) shift; api_base="${1:-}" ;;
      --quality-score) shift; quality_score="${1:-}" ;;
      --cost-usd) shift; cost_usd="${1:-}" ;;
      --token-usage) shift; token_usage="${1:-}" ;;
      *) fail "Unknown argument for call: ${1}" ;;
    esac
    shift
  done

  [ -n "${endpoint}" ] || fail "Missing --endpoint"
  validate_risk "${risk}"
  ensure_run_id
  load_run_env

  if [ "${AUTONOMY_PHASE}" = "copilot" ] && [ "${dry_run}" -ne 1 ]; then
    fail "Autonomy phase is 'copilot'. Use --dry-run for advisory mode or set phase to assisted/guardrailed."
  fi

  if [ "${risk}" = "high" ] && [ "${approve_high_risk}" -ne 1 ]; then
    fail "High-risk action blocked. Re-run with --approve-high-risk after human approval."
  fi

  if float_lt "${confidence}" "${CONFIDENCE_THRESHOLD}"; then
    fail "Confidence ${confidence} is below threshold ${CONFIDENCE_THRESHOLD}."
  fi

  if [ "${CONSECUTIVE_FAILURES}" -ge "${CIRCUIT_BREAKER_LIMIT}" ]; then
    fail "Circuit breaker open (${CONSECUTIVE_FAILURES} failures). Run reset-circuit first."
  fi

  local endpoint_path
  endpoint_path="$(parse_path "${endpoint}")"

  if ! allowed_transition "${CURRENT_STAGE}" "${endpoint_path}"; then
    fail "Invalid stage transition: current=${CURRENT_STAGE}, endpoint=${endpoint_path}"
  fi

  local full_url
  if [[ "${endpoint}" == http://* || "${endpoint}" == https://* ]]; then
    full_url="${endpoint}"
  else
    full_url="${api_base}${endpoint}"
  fi

  if [ "${dry_run}" -eq 1 ]; then
    echo "Dry run OK"
    echo "  run_id=${RUN_ID}"
    echo "  current_stage=${CURRENT_STAGE}"
    echo "  endpoint=${endpoint_path}"
    echo "  next_stage=$(next_stage "${endpoint_path}")"
    return 0
  fi

  local bases_csv="${api_base}"
  if [ -n "${FALLBACK_API_BASE_URLS}" ]; then
    bases_csv+=",${FALLBACK_API_BASE_URLS}"
  fi
  local IFS=','
  read -r -a base_candidates <<< "${bases_csv// /}"

  local attempt status latency result_base retries_used="0"
  local success="0"
  local response_file
  response_file="$(mktemp)"

  for result_base in "${base_candidates[@]}"; do
    [ -n "${result_base}" ] || continue

    local target_url="${full_url}"
    if [[ "${endpoint}" != http://* && "${endpoint}" != https://* ]]; then
      target_url="${result_base}${endpoint}"
    fi

    for attempt in $(seq 0 "${retries}"); do
      retries_used="${attempt}"
      local cmd=(curl -sS -X "${method}" -o "${response_file}" -w "%{http_code} %{time_total}" --max-time "${timeout_secs}")
      cmd+=("${target_url}")

      if [ -n "${json_body}" ]; then
        cmd+=(-H "Content-Type: application/json" --data "${json_body}")
      fi

      if [ "${#forms[@]}" -gt 0 ]; then
        local form_value
        for form_value in "${forms[@]}"; do
          cmd+=(-F "${form_value}")
        done
      fi

      if [ "${#headers[@]}" -gt 0 ]; then
        local header_value
        for header_value in "${headers[@]}"; do
          cmd+=(-H "${header_value}")
        done
      fi

      set +e
      local output
      output="$(${cmd[@]} 2>&1)"
      local curl_exit=$?
      set -e

      if [ "${curl_exit}" -eq 0 ]; then
        status="${output%% *}"
        latency="${output##* }"
      else
        status="000"
        latency="0"
      fi

      if [[ "${status}" =~ ^2[0-9][0-9]$ ]]; then
        success="1"
        break
      fi

      if [ "${attempt}" -lt "${retries}" ]; then
        sleep "$((retry_backoff * (attempt + 1)))"
      fi
    done

    [ "${success}" -eq 1 ] && break
  done

  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [ "${success}" -eq 1 ]; then
    CURRENT_STAGE="$(next_stage "${endpoint_path}")"
    CONSECUTIVE_FAILURES="0"
    UPDATED_AT="${timestamp}"
    save_run_env

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "${timestamp}" \
      "$(csv_escape "${endpoint_path}")" \
      "${status}" \
      "${latency}" \
      "${risk}" \
      "${confidence}" \
      "${retries_used}" \
      "$(csv_escape "${result_base:-${api_base}}")" \
      "$(csv_escape "success tokens=${token_usage:-na} cost=${cost_usd:-na} quality=${quality_score:-na}")" \
      >> "${RUN_DIR}/metrics.csv"

    echo "Stage call succeeded"
    echo "  endpoint=${endpoint_path}"
    echo "  status=${status}"
    echo "  latency=${latency}s"
    echo "  next_stage=${CURRENT_STAGE}"
    echo "  response:"
    cat "${response_file}"
  else
    CONSECUTIVE_FAILURES="$((CONSECUTIVE_FAILURES + 1))"
    UPDATED_AT="${timestamp}"
    save_run_env

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "${timestamp}" \
      "$(csv_escape "${endpoint_path}")" \
      "${status:-000}" \
      "${latency:-0}" \
      "${risk}" \
      "${confidence}" \
      "${retries_used}" \
      "$(csv_escape "${result_base:-${api_base}}")" \
      "$(csv_escape "failed")" \
      >> "${RUN_DIR}/metrics.csv"

    echo "Stage call failed"
    echo "  endpoint=${endpoint_path}"
    echo "  status=${status:-000}"
    echo "  consecutive_failures=${CONSECUTIVE_FAILURES}"
    [ -s "${response_file}" ] && cat "${response_file}" || true
    rm -f "${response_file}"
    exit 1
  fi

  rm -f "${response_file}"
}

record_feedback() {
  local outcome=""
  local quality_score=""
  local kpi_delta=""
  local notes=""

  while [ "${#}" -gt 0 ]; do
    case "${1}" in
      --run-id) shift; RUN_ID="${1:-}" ;;
      --outcome) shift; outcome="${1:-}" ;;
      --quality-score) shift; quality_score="${1:-}" ;;
      --business-kpi-delta) shift; kpi_delta="${1:-}" ;;
      --notes) shift; notes="${1:-}" ;;
      *) fail "Unknown argument for record-feedback: ${1}" ;;
    esac
    shift
  done

  [ -n "${outcome}" ] || fail "Missing --outcome"
  ensure_run_id

  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  notes="${notes//$'\t'/ }"
  notes="${notes//$'\n'/ }"
  notes="${notes//$'\r'/ }"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "${timestamp}" \
    "${outcome}" \
    "${quality_score:-}" \
    "${kpi_delta:-}" \
    "${notes}" \
    >> "${RUN_DIR}/feedback.tsv"

  echo "Feedback recorded for ${RUN_ID}"
}

generate_dashboard() {
  while [ "${#}" -gt 0 ]; do
    case "${1}" in
      --run-id) shift; RUN_ID="${1:-}" ;;
      *) fail "Unknown argument for dashboard: ${1}" ;;
    esac
    shift
  done

  ensure_run_id
  load_run_env

  local dashboard_path="${RUN_DIR}/dashboard.html"
  {
    echo '<!doctype html><html><head><meta charset="utf-8"><title>Poseidon OS Dashboard</title>'
    echo '<style>body{font-family:Arial,Helvetica,sans-serif;margin:20px}table{border-collapse:collapse;width:100%;margin-top:12px}th,td{border:1px solid #ddd;padding:8px;text-align:left}th{background:#f4f4f4}</style></head><body>'
    echo "<h1>Poseidon OS Run Dashboard</h1>"
    echo "<p><strong>Run ID:</strong> ${RUN_ID}<br><strong>Target use case:</strong> ${TARGET_USE_CASE}<br><strong>Phase:</strong> ${AUTONOMY_PHASE}<br><strong>Current stage:</strong> ${CURRENT_STAGE}</p>"
    echo '<h2>Execution metrics</h2><pre>'
    cat "${RUN_DIR}/metrics.csv"
    echo '</pre>'
    echo '<h2>Feedback loop</h2><pre>'
    cat "${RUN_DIR}/feedback.tsv"
    echo '</pre>'
    echo '</body></html>'
  } > "${dashboard_path}"

  echo "Dashboard generated: ${dashboard_path}"
}

generate_scorecard() {
  while [ "${#}" -gt 0 ]; do
    case "${1}" in
      --run-id) shift; RUN_ID="${1:-}" ;;
      *) fail "Unknown argument for evaluate: ${1}" ;;
    esac
    shift
  done

  ensure_run_id
  load_run_env

  local scorecard_path="${RUN_DIR}/scorecard.md"

  local total_calls success_calls avg_latency avg_quality avg_kpi
  total_calls="$(awk -F',' 'NR>1 {c++} END{print c+0}' "${RUN_DIR}/metrics.csv")"
  success_calls="$(awk -F',' 'NR>1 && $3 ~ /^2[0-9][0-9]$/ {c++} END{print c+0}' "${RUN_DIR}/metrics.csv")"
  avg_latency="$(awk -F',' 'NR>1 {sum+=$4;c++} END{if(c==0){print "0.00"} else {printf "%.2f", sum/c}}' "${RUN_DIR}/metrics.csv")"
  avg_quality="$(awk -F'\t' 'NR>1 && $3 != "" {sum+=$3;c++} END{if(c==0){print "0.00"} else {printf "%.2f", sum/c}}' "${RUN_DIR}/feedback.tsv")"
  avg_kpi="$(awk -F'\t' 'NR>1 && $4 != "" {sum+=$4;c++} END{if(c==0){print "0.00"} else {printf "%.2f", sum/c}}' "${RUN_DIR}/feedback.tsv")"

  {
    echo "# Poseidon OS Evaluation Scorecard"
    echo
    echo "- Run ID: ${RUN_ID}"
    echo "- Target use case: ${TARGET_USE_CASE}"
    echo "- Current stage: ${CURRENT_STAGE}"
    echo "- Total calls: ${total_calls}"
    echo "- Successful calls: ${success_calls}"
    echo "- Average latency (s): ${avg_latency}"
    echo "- Average quality score: ${avg_quality}"
    echo "- Average business KPI delta: ${avg_kpi}"
    echo
    echo "## Promotion gate"
    echo
    echo "Promote to next autonomy phase only if quality >= 0.75, success-rate >= 90%, and KPI delta is non-negative across core scenarios."
  } > "${scorecard_path}"

  echo "Scorecard generated: ${scorecard_path}"
}

reset_circuit() {
  while [ "${#}" -gt 0 ]; do
    case "${1}" in
      --run-id) shift; RUN_ID="${1:-}" ;;
      *) fail "Unknown argument for reset-circuit: ${1}" ;;
    esac
    shift
  done

  ensure_run_id
  load_run_env
  CONSECUTIVE_FAILURES="0"
  UPDATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  save_run_env
  echo "Circuit breaker reset for ${RUN_ID}"
}

main() {
  local command="${1:-}"
  [ -n "${command}" ] || {
    usage
    exit 1
  }
  shift || true

  case "${command}" in
    init-run) init_run "$@" ;;
    set-phase) set_phase "$@" ;;
    call) call_stage_gated "$@" ;;
    record-feedback) record_feedback "$@" ;;
    dashboard) generate_dashboard "$@" ;;
    evaluate) generate_scorecard "$@" ;;
    reset-circuit) reset_circuit "$@" ;;
    -h|--help|help) usage ;;
    *)
      fail "Unknown command: ${command}"
      ;;
  esac
}

main "$@"
