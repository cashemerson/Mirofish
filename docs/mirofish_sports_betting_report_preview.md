# Mirofish Sports Betting Intelligence Report

## Version
- Version: 1.0
- Date: 2026-04-02
- Audience: Mirofish prediction and execution pipeline

## Objective
Build a probability-first sports/event trading system for US professional sports and event contracts (including Kalshi) that optimizes long-run risk-adjusted returns.

---

## 1) Core Principles

1. Price over opinion.
2. Probabilities over narratives.
3. Always remove vig/fees before comparing edge.
4. Execution quality (timing, limits, slippage) is part of edge.
5. Risk controls are mandatory, not optional.
6. CLV (closing line value) is a key process KPI.

---

## 2) Market Landscape (US)

### Common books (state-dependent)
- FanDuel
- DraftKings
- BetMGM
- Caesars
- ESPN BET
- Fanatics
- BetRivers
- bet365 (state availability varies)
- Hard Rock Bet (state availability varies)

### Exchange-style venue
- Kalshi (binary YES/NO event contracts, CFTC-regulated model)

---

## 3) Kalshi Modeling Notes

### Binary mechanics
- Contract settles at exactly $1 (true) or $0 (false).
- If YES contract price is `c`, implied probability is approximately `c` before fees.
- YES + NO prices are approximately 1.00, with spread/fees friction.

### EV framework
- `EV_yes = p_model - c - fee_per_contract`
- `EV_no = (1 - p_model) - (1 - c) - fee_per_contract`
- Bet/enter only when EV exceeds threshold after fees + expected slippage.

---

## 4) Sportsbook Math Standards

### Convert American odds to implied probability
- Positive odds `+A`: `p = 100 / (A + 100)`
- Negative odds `-A`: `p = A / (A + 100)` where `A = abs(odds)`

### Remove vig (two-way market)
- `p1_fair = p1_raw / (p1_raw + p2_raw)`
- `p2_fair = p2_raw / (p1_raw + p2_raw)`

### EV formula
- For decimal odds `d` and model probability `p`:
- `EV_per_$1 = p * (d - 1) - (1 - p)`

---

## 5) Professional Trading Mindset

### As an elite bettor
- Demand quantified edge on every entry.
- Pass when edge is unclear.
- Prefer repeatable small edges over high-variance swings.
- Track expected value and realized value separately.

### As a Vegas risk manager
- Monitor liability concentration by side/game/league/day.
- Manage correlation risk (same team, same game, derivative chains).
- Adapt limits based on confidence, liquidity, and market stability.
- Reprice aggressively during information shocks (injuries, starters, weather).

### As an exchange microstructure trader
- Use depth, spread, and queue position in decision logic.
- Prefer limit-style behavior when practical.
- Include fill probability in expected return.

---

## 6) MLB Modern History and Current Baseline

### Era summary
1. Late 1990s-2000s: offense-heavy period.
2. Moneyball era: valuation efficiency and OBP optimization.
3. Statcast era: EV/launch angle/pitch design.
4. 2023 rule changes (clock, bases, shift constraints): pace + basepath impact.
5. 2024-2025: run environment stabilized relative to 2023 spike.

### 2025 MLB League Averages (per team game)
- Runs/Game: 4.45
- BA: .245
- OBP: .315
- SLG: .404
- OPS: .719
- HR/Game: 1.16
- BB/Game: 3.16
- SO/Game: 8.36
- SB/Game: 0.71

### 2025 League Pitching Baseline
- ERA: 4.16
- FIP: 4.16
- WHIP: 1.289
- K/9: 8.5
- BB/9: 3.2
- HR/9: 1.2

### MLB implications for Mirofish
- Model starting pitcher quality and bullpen fatigue explicitly.
- Use park + weather adjustments for totals and derivatives.
- Reprice on lineup confirmation and pitcher scratches in real time.

---

## 7) Required System Components

### Data ingestion
- Multi-book odds snapshots
- Kalshi book depth and top-of-book
- Injuries, lineups, starters/goalies
- Weather and venue factors
- Closing lines for CLV

### Feature engineering
- No-vig fair probabilities
- Cross-book dispersion
- News-shock deltas
- Time-to-event decay
- Liquidity/slippage proxies

### Model and calibration
- Separate models by market type (moneyline, spread, total, props, binary events)
- Probability calibration (isotonic or Platt)
- Ensemble with market prior where appropriate

### Decision and sizing
- Thresholded EV with uncertainty adjustment
- Fractional Kelly (recommended 0.25x-0.50x)
- Hard caps per bet, game, day, and league

---

## 8) Risk Policy

- Max stake per position (bankroll %)
- Max correlated exposure (same game/team cluster)
- Max daily drawdown circuit breaker
- Stale-data guardrails
- Slippage and liquidity abort logic

---

## 9) Performance KPIs

Primary:
- CLV
- ROI by market type
- Risk-adjusted return
- Max drawdown

Calibration:
- Brier score
- Log loss
- Reliability curve drift

Execution:
- Fill rate
- Average slippage
- Rejection rate by venue/book

---

## 10) Direct Mirofish Directive

For each candidate market:
1. Output model probability with confidence interval.
2. Output market implied probability (vig/fee adjusted).
3. Output EV after costs.
4. Output stake recommendation (fractional Kelly with hard caps).
5. Output correlation impact on existing positions.
6. Abort if freshness, slippage, or risk rules fail.

Optimize for long-run risk-adjusted growth, not short-run win rate.

