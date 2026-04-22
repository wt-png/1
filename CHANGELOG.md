# MSPB Expert Advisor — Changelog

All notable changes to this project are documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

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
