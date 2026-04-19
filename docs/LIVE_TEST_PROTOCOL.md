# MSPB EA — Live Test Protocol

Version: v19.0 | Updated: 2026-04-19

This document defines the 4-phase forward-test protocol used to validate a new EA
version before full-capital live deployment.

---

## Overview

| Phase | Duration | Account | Capital | Go / No-Go |
|-------|----------|---------|---------|-----------|
| 1 — Demo validation | 2 weeks | Demo | Full virtual | Phase 2 gate |
| 2 — Micro live | 4 weeks | Live | 1–5% real capital | Phase 3 gate |
| 3 — Partial live | 8 weeks | Live | 25% real capital | Phase 4 gate |
| 4 — Full live | Ongoing | Live | 100% real capital | Monthly review |

---

## Phase 1 — Demo Validation (2 weeks)

**Objective**: Verify the EA runs stably, produces entries, and handles all
session/risk-guard scenarios without errors.

### Setup

- Attach EA to a demo account mirroring the live broker's spread/commission profile.
- Set `InpRiskPct = 1.0`, `InpMaxPositionsTotal = 3`, all symbols enabled.
- Enable full logging: `InpEnableAuditLog = true`, `InpEnableMLExport = true`.

### Go criteria

| Metric | Minimum |
|--------|---------|
| Trades executed | ≥ 30 |
| Journal errors (INIT_FAILED, INVALID_HANDLE, etc.) | 0 |
| Max daily drawdown | ≤ configured `InpDailyLossLimit_Pct` |
| Slippage vs backtest | within 2× backtest average |
| Telegram messages delivered | 100% (if enabled) |

### No-Go triggers (abort phase 1)

- Any `FAILSAFE_TRIP` or unhandled exception in Journal.
- Positions opened outside configured session hours.
- 3 or more consecutive `DEALQ_OVERFLOW` messages.

---

## Phase 2 — Micro Live (4 weeks)

**Objective**: Confirm live execution quality and real-money risk management
under live spread/slippage conditions.

### Setup

- Live account; allocate ≤ 5% of intended full capital.
- `InpRiskPct = 0.5` (half the intended live risk).
- `InpWeeklyLossLimit_Pct = 5.0` (strict weekly guard).
- `InpBlockMonday = true`, `InpBlockFriday = true` for first 2 weeks.

### Go criteria

| Metric | Minimum |
|--------|---------|
| Profit factor (gross) | ≥ 1.10 |
| Win rate | ≥ 40% |
| Max daily drawdown | ≤ 2% |
| Max weekly drawdown | ≤ 5% |
| Sharpe (weekly returns) | ≥ 0.5 |
| No-spread-filter trades | 0 |

### No-Go triggers

- Weekly equity drawdown > `InpWeeklyLossLimit_Pct` in any single week.
- Profit factor < 0.90 after 30 trades.
- Any `FailSafe_Trip` event.
- Average slippage > 2× backtest expectation.

---

## Phase 3 — Partial Live (8 weeks)

**Objective**: Scale up to 25% of intended capital and verify performance
stability under increased position sizing.

### Setup

- Increase allocation to 25% of full target capital.
- `InpRiskPct` at full intended value.
- Remove `InpBlockMonday`/`InpBlockFriday` if Phase 2 showed no Monday/Friday issues.
- Enable walk-forward review using `tools/wfo_pipeline.py` weekly.

### Go criteria (after 8 weeks)

| Metric | Minimum |
|--------|---------|
| Profit factor | ≥ 1.20 |
| Sharpe (8-week) | ≥ 0.8 |
| Max drawdown | ≤ 8% |
| WFO stable windows | ≥ 60% |
| Weekly loss limit hits | ≤ 2 in 8 weeks |

### No-Go triggers

- 3 consecutive losing weeks.
- WFO stable ratio < 40% in the `wfo_pipeline.py` output.
- Max drawdown > 12%.

---

## Phase 4 — Full Live (Ongoing)

**Objective**: Operate at full capital with monthly performance reviews.

### Monthly review checklist

- [ ] Run `tools/wfo_pipeline.py` on last 3 months of data.
- [ ] Run `tools/ml_feedback.py` and review feature importance shifts.
- [ ] Run `tools/optimize_params.py` if any parameter looks stale.
- [ ] Check ML export for degrading `adx_trend` / `atr_pips` distributions.
- [ ] Review slippage trend — investigate if average slippage increases > 20%.
- [ ] Confirm `EA_VERSION` in Journal matches the deployed build.
- [ ] Verify Telegram `/status` response is correct.

### Automatic circuit-breakers (always active)

| Guard | Trigger |
|-------|---------|
| Daily loss limit | `InpDailyLossLimit_Pct` |
| Weekly loss limit | `InpWeeklyLossLimit_Pct` |
| Portfolio risk cap | `InpMaxPortfolioRiskPct` |
| Equity regime scaling | EQ_CAUTION → 0.7×; EQ_DEFENSIVE → 0.4× lot size |
| Fail-safe stop | `FailSafe_Trip` sets `g_failSafeStopEntries = true` |
| Telegram /pause | Remote pause without MT5 access |

---

## Emergency Stop Procedures

### Via MetaTrader 5

1. Right-click the EA on the chart → *Remove*.
2. Close all positions manually in the *Trade* tab, or use the EA's close-all button.

### Via Telegram (v19.0+)

```
/closeall
/pause
```

### Via MT5 terminal kill

If MT5 is unresponsive: terminate the process; all pending orders remain on the
broker server. Log in from a second device to manage open positions.

---

## Data Retention

| File | Location | Retention |
|------|----------|-----------|
| ML export | `MQL5/Files/ml_export_v2.csv` | Keep all history; rotate annually |
| Audit log | `MQL5/Files/mspb_audit.log` | Keep 12 months rolling |
| Runtime state | `MQL5/Files/<InpRuntimeStatePersistFile>` | Auto-managed by EA |
| Telegram config | `MQL5/Files/<InpTGConfigFile>` | Never commit to git |
