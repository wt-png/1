# MSPB Expert Advisor — Changelog

All notable changes to this project are documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [v22.1] — 2026-04-23

### Added — Anti-Loss Hardening

**1. Daily loss circuit breaker (`InpDailyLoss_Enable`, `InpDailyLoss_PctBalance=2%`, `InpDailyLoss_CloseAll`)**
- Records the account balance at the start of each trading day (`g_dailyLossStartBal`).
- If intraday P&L drops below –`InpDailyLoss_PctBalance`% of the day-start balance, all new
  entries are halted for the remainder of the day (`g_dailyLossBreached`).
- Optional nuclear mode (`InpDailyLoss_CloseAll=true`) closes all open positions on breach.
- Resets automatically at the start of the next trading day.
- Audit-logged on trigger.

**2. Equity drawdown circuit breaker (`InpEquityCB_Enable`, `InpEquityCB_Pct=5%`)**
- Integrated into `EqRegime_Update()`.
- Sets `g_equityCBBreached=true` when live equity DD from peak ≥ `InpEquityCB_Pct`.
- Auto-clears when equity recovers back above the threshold.
- Acts as a hard entry gate above the existing loss-streak and rate-limit guards.

**3. Dashboard CB indicators**
- Status line now shows `DAILY_LOSS_CB` or `EQUITY_CB` (red) when a circuit breaker is active.

### Changed — Anti-Overtrading Defaults

| Parameter | Old | New |
|-----------|-----|-----|
| `InpLossStreakBlockAfter` | 3 | **2** |
| `InpLossStreakBlockMinutes` | 180 | **240** |
| `InpMinMinutesBetweenEntries` | 15 | **30** |
| `InpMaxEntriesPerSymbolPerDay` | 6 | **4** |
| `InpMaxEntriesTotalPerDay` | 12 | **8** |

### Changed — Entry Filter Defaults

| Parameter | Old | New |
|-----------|-----|-----|
| `InpMaxSpreadPips_FX` | 3.0 | **2.0** |
| `InpMinATR_Pips` | 10.0 | **12.0** |
| `InpMinADXForEntry` | 20.0 | **22.0** |
| `InpMinADXEntryFilter` | 20.0 | **22.0** |
| `InpUseSessions` | false | **true** (London 07–17 + NY 12–21 UTC) |
| `InpVolHighRiskMult` | 0.50 | **0.25** |

### Context
The v22.0 backtest baseline showed:
- Net profit: **–300.98 USD** (GBPUSD M15, 283 trades), PF **0.68**, max equity DD **3.75 %**
- Root causes identified: overtrading in low-quality setups + no hard loss cap.

---

## [v22.0] — 2026-04-22

### Added — Optimisation Infrastructure

**1. KPI framework (`docs/KPI_TARGETS.md`)**
- Defined 6 primary KPIs: net expectancy (R), win rate, profit factor, max equity DD%,
  Sharpe ratio, Calmar ratio — each with a minimum-acceptable and target value.
- Added regime-specific sub-targets (trend / range / volatile).
- Added 3-tier stress-test gate table (normal 1.0×, moderate 1.4×, high 2.0× spread).
- Defined rollback trigger conditions.

**2. Baseline measurement system (`docs/BASELINE.md`, `tools/baseline_report.py`)**
- `baseline_report.py`: parses the EA's ML-export CSV and computes all KPIs.
- Outputs a machine-readable JSON snapshot (`tools/baseline_kpis.json`).
- `docs/BASELINE.md`: locked configuration table and sprint comparison table.

**3. Walk-Forward Optimisation pipeline (`tools/wfo_pipeline.py`)**
- Rolling IS/OOS window splits (configurable folds and OOS ratio).
- Heuristic market-regime detection (trend / range / volatile) per fold.
- Per-regime KPI summary and overall robustness score.
- Outputs ACCEPT / REJECT recommendation based on OOS PF and robustness.

**4. Monte Carlo overfitting detection (`tools/monte_carlo_analysis.py`)**
- 2000-iteration trade-sequence reshuffling by default.
- Computes PF / DD / Expectancy distributions (p5–p95).
- Raises OVERFIT_RISK flag when real PF is in the top 5% of random reshuffles.

**5. Stress testing (`tools/stress_test.py`)**
- Applies spread multipliers and fixed slippage additions to the trade history.
- Checks P&L survival against KPI-gate table (PF ≥ 1.30 / 1.10 / 0.90).
- PASS / FAIL verdict used as a hard gate before live deployment.

**6. Session-level execution analysis (`tools/session_analysis.py`)**
- Classifies each trade into Asia / London / Overlap / NewYork / LateNY sessions.
- Also breaks down KPIs per weekday (Mon–Fri).
- Generates KEEP / REDUCE_RISK / BLOCK_ENTRIES recommendations per session.
- Computes spread-cost % of gross profit as execution-quality signal.

**7. Automated test suite (`tools/test_tools.py`)**
- 55 pytest tests covering all five Python tools.
- Runs on every push/PR via GitHub Actions.

**8. CI pipeline (`.github/workflows/ci.yml`)**
- `test` job: lint + pytest on every push and PR.
- `wfo` job: weekly WFO + Monte Carlo run every Wednesday 02:00 UTC.
- Artefact upload of WFO and stress-test JSON results (30-day retention).

**9. Phased deployment guide (`docs/DEPLOYMENT.md`)**
- 4-phase rollout: Development → Backtest → Forward test → Full live.
- Complete feature-flag table with all EA `input bool` guards.
- Manual and automatic rollback procedures.

**10. Optimisation governance (`docs/GOVERNANCE.md`)**
- Weekly optimisation cycle (Mon–Fri + weekend monitoring).
- CI cadence table.
- Decision authority matrix by change risk level.
- Anti-overfitting rules (max 5 free params, ≥ 3 symbols, OOS ≥ 30 %).
- Documentation standards for WFO/stress result artefacts.

### Context
The backtest result that motivated this sprint showed:
- Net profit: **–300.98 USD** (GBPUSD M15, 283 trades)
- Profit factor: **0.68**
- Max equity DD: **3.75 %**
- Recommendation: tighten entry filters and validate all changes with the new WFO
  pipeline before any live parameter change.

---

## [v14.8] — baseline

- Initial version with full multi-symbol pullback-scalper logic, news engine,
  correlation guard, volatility regime, equity drawdown tracker, Telegram integration,
  ML export, auto-tune / rollback engine.
