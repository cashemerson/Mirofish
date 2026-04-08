# Poseidon OS v1 (Multi-Agent Control Plane)

This implementation adds a practical orchestration layer on top of the existing Mirofish API pipeline:

1. `/api/graph/ontology/generate`
2. `/api/graph/build`
3. `/api/simulation/create`
4. `/api/simulation/start`
5. `/api/simulation/stop`
6. `/api/report/generate`
7. `/api/report/chat`

## v1 scope and first target use-case

- Scope: enforce stage gates, risk controls, observability, and feedback loops around the existing endpoints.
- Locked first use-case: `sports_prediction_market_intelligence`.

## Agent roles and boundaries

Poseidon writes role contracts for every run in:

- `deploy/always-on/poseidon/runs/<run-id>/handoff-contracts.md`

Roles:

- Commander Agent: objective owner and high-risk approval authority.
- Research Agent: prepares requirement context.
- Simulation Ops Agent: executes pipeline stages.
- Risk Agent: enforces confidence/risk policy.
- Report Agent: owns report generation and report-chat outputs.

## Phased autonomy rollout

- `copilot`: advisory mode (`call` requires `--dry-run`).
- `assisted`: execution enabled, high-risk still requires explicit approval.
- `guardrailed`: execution enabled with strict confidence/risk gates.

## Quick start (copy/paste)

```bash
cd /home/runner/work/Mirofish/Mirofish/deploy/always-on
bash scripts/poseidon-os.sh init-run --name poseidon-v1
```

Set phase:

```bash
cd /home/runner/work/Mirofish/Mirofish/deploy/always-on
bash scripts/poseidon-os.sh set-phase --run-id <RUN_ID> --phase assisted
```

Advisory gate check (copilot mode):

```bash
cd /home/runner/work/Mirofish/Mirofish/deploy/always-on
bash scripts/poseidon-os.sh call --run-id <RUN_ID> --endpoint /api/graph/ontology/generate --risk medium --confidence 0.82 --dry-run
```

Execute stage-gated call:

```bash
cd /home/runner/work/Mirofish/Mirofish/deploy/always-on
bash scripts/poseidon-os.sh call --run-id <RUN_ID> --endpoint /api/graph/ontology/generate --form 'simulation_requirement=Find +EV opportunities' --form 'files=@/absolute/path/to/input.pdf' --risk high --confidence 0.90 --approve-high-risk
```

Record outcomes for memory/feedback loop:

```bash
cd /home/runner/work/Mirofish/Mirofish/deploy/always-on
bash scripts/poseidon-os.sh record-feedback --run-id <RUN_ID> --outcome success --quality-score 0.88 --business-kpi-delta 0.05 --notes 'Model produced actionable signals'
```

Generate observability dashboard and scorecard:

```bash
cd /home/runner/work/Mirofish/Mirofish/deploy/always-on
bash scripts/poseidon-os.sh dashboard --run-id <RUN_ID>
bash scripts/poseidon-os.sh evaluate --run-id <RUN_ID>
```

## Reliability safeguards included

- stage-gated transitions to prevent invalid order
- timeout controls (`--timeout`)
- retries + progressive backoff (`--retries`, `--retry-backoff`)
- API base fallback list (`--fallback-api-bases` on init)
- circuit breaker based on consecutive failures

## Deployment hardening gate

Run release gate before each production release:

```bash
cd /home/runner/work/Mirofish/Mirofish/deploy/always-on
bash scripts/release-gate.sh --app https://your-domain --portal https://portal.your-domain --api https://your-domain/api/simulation/history?limit=1
```

This enforces preflight checks, optional smoke checks, and generates rollback-readiness instructions.
