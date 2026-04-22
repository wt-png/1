# Changelog

## v21.0 — 2026-04-22
### Added
- Daily loss circuit breaker (InpDailyLoss_Enable, InpDailyLoss_PctBalance, InpDailyLoss_CloseAll) — halts new entries when daily P&L drops below the configured threshold
- Equity circuit breaker per session (InpEquityCB_Enable, InpEquityCB_Pct) — blocks entries when equity drawdown from session start exceeds the threshold
- `tools/session_analysis.py` — trade segmentation by session & volatility regime
- `tools/wfo_pipeline.py` — walk-forward optimization with IS/OOS scoring
- `tools/monte_carlo_analysis.py` — Monte Carlo stress-test with KPI go/no-go
- `tools/test_tools.py` — pytest test suite for all three tools
- `docs/KPI_TARGETS.md` — KPI definitions and go/no-go thresholds
- `docs/BASELINE.md` — reproducible baseline test setup
- `docs/DEPLOYMENT.md` — staged production rollout protocol
- `docs/GOVERNANCE.md` — change management and stop criteria

## v14.8 (previous)
- Tighter entry quality filters
- Structure-aware SL/TP
- Safer trailing/time-stop exits
- Strict fixed-lot risk cap
- Stronger anti-overtrading guards
