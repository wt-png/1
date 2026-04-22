# Reproducible Baseline — MSPB Expert Advisor v21.0

This document records the exact setup required to reproduce the v21.0 baseline backtest results.
Any deviation from these settings invalidates the baseline comparison.

---

## Environment

| Item | Value |
|------|-------|
| EA Version | v21.0 |
| MetaTrader Version | MetaTrader 5 (Build ≥ 3815) |
| Broker Type | ECN / STP — raw spread account |
| Max Spread FX | 3 pips (InpMaxSpreadPips_FX = 3.0) |
| Max Spread XAU | 30 pips (InpMaxSpreadPips_XAU = 30.0) |

---

## Backtest Parameters

| Item | Value |
|------|-------|
| Test period (in-sample) | 2023-01-01 to 2023-12-31 |
| Out-of-sample period | 2024-01-01 to 2024-06-30 |
| Symbols | EURUSD, GBPUSD |
| Entry Timeframe | M1 |
| Confirmation Timeframe | M5 |
| Bias Timeframe | H1 |
| Initial Balance | 10 000 EUR |
| Leverage | 1:30 (regulatory maximum) |
| Modelling | Every tick based on real ticks |
| Data quality | Tick data with real spread (variable) |

---

## Top 20 Baseline Input Values

| # | Input | Baseline Value | Notes |
|---|-------|---------------|-------|
| 1 | InpRiskPctPerTrade | 0.25 | 0.25% of balance per trade |
| 2 | InpMaxPositionsTotal | 3 | Max 3 open positions at once |
| 3 | InpMaxPositionsPerSymbol | 1 | Max 1 position per symbol |
| 4 | InpMaxEntriesPerSymbolPerDay | 6 | Anti-overtrading daily cap |
| 5 | InpMaxEntriesTotalPerDay | 12 | Global daily entry cap |
| 6 | InpMaxSpreadPips_FX | 3.0 | FX spread gate (pips) |
| 7 | InpMaxSpreadPips_XAU | 30.0 | Gold spread gate (pips) |
| 8 | InpMinMinutesBetweenEntries | 15 | Anti-overtrading spacing |
| 9 | InpLossStreakBlockAfter | 3 | Loss-streak block threshold |
| 10 | InpLossStreakBlockMinutes | 180 | Block duration (minutes) |
| 11 | InpDailyLoss_Enable | true | Daily loss circuit breaker on |
| 12 | InpDailyLoss_PctBalance | 2.0 | Daily loss threshold (% balance) |
| 13 | InpEquityCB_Enable | true | Equity CB on |
| 14 | InpEquityCB_Pct | 5.0 | Equity DD% from session start |
| 15 | InpUseSessions | true | Session filter active |
| 16 | InpLondonStartHour | 7 | London open (UTC) |
| 17 | InpLondonEndHour | 12 | London close (UTC) |
| 18 | InpNYStartHour | 12 | NY open (UTC) |
| 19 | InpNYEndHour | 17 | NY close (UTC) |
| 20 | InpNews_BlockEntries | true | Block entries around high-impact news |

---

## Baseline Results (fill in after running)

> **Note:** Replace placeholders with actual backtest results after running the baseline.

| Metric | In-Sample (2023) | Out-of-Sample (H1 2024) |
|--------|-----------------|------------------------|
| Net Profit (EUR) | _TBD_ | _TBD_ |
| Max Drawdown (%) | _TBD_ | _TBD_ |
| Profit Factor | _TBD_ | _TBD_ |
| Total Trades | _TBD_ | _TBD_ |
| Win Rate (%) | _TBD_ | _TBD_ |
| Avg R-multiple | _TBD_ | _TBD_ |
| Sharpe Proxy | _TBD_ | _TBD_ |
| Monte Carlo verdict (baseline) | _TBD_ | _TBD_ |
| Monte Carlo verdict (stressed) | _TBD_ | _TBD_ |

---

## How to Reproduce

1. Open MetaEditor and compile `MSPB_Expert_Advisor.mq5`.
2. In MetaTrader Strategy Tester:
   - Select Expert Advisor: `MSPB_Expert_Advisor`
   - Symbol: `EURUSD` (run separately for `GBPUSD`)
   - Period: `M1`
   - Model: `Every tick based on real ticks`
   - Date range: `2023-01-01` to `2023-12-31`
   - Deposit: `10000 EUR`
3. Load inputs from the table above.
4. Run backtest and export trades to `ml_export_v2.csv`.
5. Run analysis tools:
   ```bash
   python tools/session_analysis.py --file ml_export_v2.csv --output session_report.json
   python tools/monte_carlo_analysis.py --file ml_export_v2.csv --output mc_report.json
   python tools/wfo_pipeline.py --file ml_export_v2.csv --output wfo_results.json
   ```
6. Record results in the Baseline Results table above.
