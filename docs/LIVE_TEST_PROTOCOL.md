# MSPB Expert Advisor — Live Forward-Test Protocol

> Version: 17.1 | Last updated: 2026-04-19

This document defines the minimum live-test requirements before the EA can be considered **commercially ready**. All forward tests must be run on a **real account** (not demo) with real broker execution, even at micro-lot size.

---

## Overview

| Phase | Duration | Account | Goal |
|---|---|---|---|
| Phase 0 — Smoke | 3 days | Real micro (€100–500) | Confirm broker connectivity, no duplicate trades, Telegram works |
| Phase 1 — Shadow | 1 week | Real micro | `InpExecQual_Mode=1` (Monitor); accumulate execution-quality data |
| Phase 2 — Forward | 3 weeks | Real small (€1 000+) | `InpExecQual_Mode=2` (Enforce); measure live performance |
| Phase 3 — Review | 3 days | — | Analyse results; go/no-go decision |

**Total minimum duration: 4 weeks + 6 days**

---

## Phase 0 — Smoke Test (3 days)

### Setup

1. Follow the full [INSTALLATION.md](INSTALLATION.md) guide.
2. Set `InpRiskPercent=0.10` (minimum risk).
3. Set `InpExecQual_Mode=1` (Monitor, not Enforce).
4. Set `InpDailyLossLimit_Enable=true`, `InpDailyLossLimitPct=1.0` (extra conservative).

### Pass Criteria (all must be green)

- [ ] EA starts cleanly, no errors in MT5 Journal
- [ ] Telegram startup message received
- [ ] At least 1 trade opened and closed correctly
- [ ] SL and TP levels match expected values (verify manually from Journal)
- [ ] No duplicate trades (check by `InpMagic` in account history)
- [ ] `MSPB_ExecQual_State.csv` and `MSPB_RuntimeState.csv` created correctly
- [ ] EA survives MT5 restart (state files re-loaded, no phantom positions)
- [ ] Broker disconnect simulated (disable network for 30 s) → Telegram reconnect alert received
- [ ] Daily Telegram report received (midnight server time)

### Fail Criteria (any → stop, fix, restart Phase 0)

- Any error in MT5 Journal related to `OrderSend`
- Any trade with wrong lot size or no SL
- Duplicate trades on same symbol/magic

---

## Phase 1 — Shadow Mode (1 week)

### Setup

1. Keep `InpExecQual_Mode=1`.
2. Restore `InpRiskPercent=0.20`.
3. Ensure `InpExecQual_Persist=true` and `InpExecQual_PersistFile=MSPB_ExecQual_State.csv`.

### Goals

- Accumulate ≥ 30 fills per session bucket (London, NY, Asia) for exec-quality baseline.
- Identify any broker-specific slippage patterns.
- Verify per-symbol spread behaviour matches expectations.

### Weekly Review Checklist

- [ ] `MSPB_ExecQual_State.csv` contains data for all active session buckets
- [ ] Average slippage per session (check `ml_export_v2.csv` `slip` column) is within acceptable range:
  - London: < 0.8 pips
  - NY: < 1.0 pips
  - Asia: < 1.5 pips
- [ ] Bad-fill rate < 35 % across all sessions
- [ ] No risk guard trips (equity DD, daily loss, consecutive loss)
- [ ] Run: `python tools/walk_forward.py --csv ml_export_v2.csv --windows 1`  
  OOS Sharpe > 0.5 or trade count too low → continue collecting data

---

## Phase 2 — Forward Test (3 weeks)

### Setup

1. Switch `InpExecQual_Mode=2` (Enforce).
2. Set `InpRiskPercent=0.30` (production default).
3. Confirm `.set` file integrity: `python tools/sign_config.py verify MSPB_Expert_Advisor.set --key-env MSPB_SIGNING_KEY`.

### Weekly Review Meetings

Hold a **weekly review** at the end of each forward-test week. Record outcomes in the table below.

#### Week 1

| Metric | Target | Actual | Pass/Fail |
|---|---|---|---|
| Total trades | ≥ 15 | | |
| Win rate | ≥ 40 % | | |
| Profit factor | ≥ 1.0 | | |
| Max daily DD | < 2 % | | |
| ExecQual blocks | < 3 | | |
| Telegram availability | 100 % | | |

#### Week 2

| Metric | Target | Actual | Pass/Fail |
|---|---|---|---|
| Total trades (cumulative) | ≥ 35 | | |
| Win rate (rolling 2w) | ≥ 40 % | | |
| Profit factor (rolling 2w) | ≥ 1.0 | | |
| Walk-forward OOS Sharpe | ≥ 0.5 | | |
| Walk-forward OOS efficiency | ≥ 0.50 | | |
| Any FailSafe trips | 0 | | |

#### Week 3

| Metric | Target | Actual | Pass/Fail |
|---|---|---|---|
| Total trades (cumulative) | ≥ 55 | | |
| Net P&L | > 0 | | |
| Max drawdown (period) | < 5 % | | |
| Walk-forward OOS Sharpe (3w) | ≥ 0.5 | | |
| Calmar ratio | ≥ 0.3 | | |
| Config signature intact | verified | | |

### How to Run Walk-Forward Analysis

```bash
python tools/walk_forward.py \
  --csv ml_export_v2.csv \
  --windows 3 \
  --is-fraction 0.70 \
  --warn 0.50
```

Save the output to `docs/forward_test_results/wX_wf_analysis.txt` (replace X with week number).

---

## Phase 3 — Review & Go/No-Go Decision (3 days)

### Aggregate Analysis

Run the full walk-forward analysis on all collected data:

```bash
python tools/walk_forward.py --csv ml_export_v2.csv --windows 5 --is-fraction 0.70
python tools/monte_carlo_analysis.py --csv ml_export_v2.csv --simulations 5000
```

Save outputs to `docs/forward_test_results/final_wf.txt` and `docs/forward_test_results/final_mc.txt`.

### Go Criteria (all must pass)

- [ ] ≥ 55 total trades
- [ ] Walk-forward OOS Sharpe ≥ 0.5 in ≥ 3 of 5 windows
- [ ] Walk-forward OOS efficiency ≥ 0.50 (average across windows)
- [ ] Monte Carlo 5th-percentile drawdown < 15 % (at production risk)
- [ ] Monte Carlo 95th-percentile Sharpe > 0 (strategy is net positive in almost all scenarios)
- [ ] Zero FailSafe trips during Phase 2
- [ ] Zero trade execution errors (all `OrderSend` calls returned `TRADE_RETCODE_DONE`)
- [ ] Config signature verified on production `.set` file
- [ ] Telegram connectivity: 100 % uptime during test period

### No-Go Criteria (any → restart from Phase 1 after code fix)

- Walk-forward OOS Sharpe < 0 in majority of windows (strategy not robust out-of-sample)
- Max drawdown > 8 % in any rolling 2-week period
- Any duplicate or orphan positions detected
- FailSafe tripped (indicates serious logic error)
- Config signature mismatch detected

---

## Review Cycle Template

Use this template for each weekly review meeting:

```
## MSPB EA Weekly Review — Week [N] — [DATE]

Participants: [names]

### Metrics
- Trades this week: 
- Win rate: 
- Profit factor: 
- Max daily DD: 
- ExecQual blocks: 
- Walk-forward OOS Sharpe (if available): 

### Issues Encountered
- [list any anomalies, errors, or unexpected behaviour]

### Parameter Changes Made
- [list any .set file changes; sign and commit new .set]

### Decision
- [ ] Continue to next phase
- [ ] Restart phase (reason: )
- [ ] Escalate (reason: )

### Action Items
| Item | Owner | Due |
|---|---|---|
| | | |
```

---

## File Storage Convention

Store all test artefacts in `docs/forward_test_results/` (gitignored by default — add manually if you want version-controlled evidence):

```
docs/forward_test_results/
├── phase0_smoke_YYYYMMDD.txt
├── phase1_shadow_wf.txt
├── week1_review.md
├── week2_review.md
├── week3_review.md
├── final_wf.txt
├── final_mc.txt
└── go_nogo_decision.md
```

---

## Escalation Policy

| Severity | Trigger | Action |
|---|---|---|
| **Critical** | FailSafe tripped, wrong lot size, orphan positions | Stop EA immediately, notify all stakeholders, fix before any restart |
| **High** | Drawdown > 5 % in any single day | Pause EA, review manually, restart only after root-cause fix |
| **Medium** | ExecQual blocks > 5 in one day | Review broker execution, consider adjusting `InpExecQual_BadSlipPips` |
| **Low** | Walk-forward efficiency < 0.50 in one window | Continue but note in weekly review; investigate if recurring |
