# KPI Targets & Go/No-Go Criteria

**EA Version:** MSPB Expert Advisor v21.0  
**Applies to:** In-sample validation, OOS evaluation, live monitoring

---

## Primary KPIs

| KPI | Description | Minimum | Target | Hard Cap |
|-----|-------------|---------|--------|----------|
| Net Profit | Total realised P&L over evaluation period | > 0 | > 15% initial balance | — |
| Max Drawdown | Peak-to-trough equity DD | < 12% | < 8% | 15% (stop trading) |
| Profit Factor | Gross profit / Gross loss | > 1.30 | > 1.60 | — |
| Win Rate | % of trades closed in profit | > 40% | > 50% | — |
| Avg R-multiple | Average P&L per trade (in R units) | > 0.10 R | > 0.20 R | — |
| Sharpe Proxy | (Avg monthly return) / (Std monthly return) × √12 | > 0.80 | > 1.20 | — |

---

## Risk-Frame KPIs

| Risk Frame | Parameter | Limit | Action on Breach |
|------------|-----------|-------|-----------------|
| Daily loss limit | InpDailyLoss_PctBalance | 2% of balance | Halt all new entries for the day |
| Equity circuit breaker | InpEquityCB_Pct | 5% from session start | Halt entries for session |
| EqRegime CAUTION | EqRegime drawdown | 2–5% from equity peak | Risk multiplier → 0.7× |
| EqRegime DEFENSIVE | EqRegime drawdown | > 5% from equity peak | Risk multiplier → 0.4× |
| Max concurrent positions | InpMaxPositionsTotal | 3 | No new entries opened |
| Max per symbol | InpMaxPositionsPerSymbol | 1 | No new entries on that symbol |
| Loss streak block | InpLossStreakBlockAfter | 3 consecutive losses | Symbol blocked for 180 min |

---

## Go/No-Go Decision Table

| Metric | Minimum Threshold | Target | Hard Cap (Stop Trading) |
|--------|-------------------|--------|------------------------|
| Net Profit | > 0 | > 15% balance | — |
| Max Drawdown | < 12% | < 8% | ≥ 15% |
| Profit Factor | > 1.30 | > 1.60 | < 1.00 for 30 days |
| Win Rate | > 40% | > 50% | < 30% for 30 days |
| Daily loss breach | ≤ 2 days/month | 0 | > 5 days/month |
| CB Equity triggered | ≤ 1/week | 0 | > 3/week |
| Avg Spread (FX) | ≤ 3 pips | ≤ 2 pips | > 4 pips consistently |

---

## Evaluation Conditions

1. **Minimum trade count:** 200 trades per evaluation period.
2. **Minimum period:** 6 months of continuous trading (or backtest data).
3. **Data type:** Evaluated on **out-of-sample (OOS)** data — never on the in-sample optimisation window.
4. **Benchmark spreads:** ECN spreads, real tick data with variable spread.
5. **Cost stress:** All results must pass with +20% spread stress and +0.0002 slippage per trade.

---

## Session-Level KPIs

| Session | Trading Hours (UTC) | Min PF | Min Win Rate | Notes |
|---------|---------------------|--------|-------------|-------|
| Asia | 00:00–07:00 | 1.20 | 38% | Lower liquidity; expect wider spreads |
| London | 07:00–12:00 | 1.40 | 45% | Primary session; highest trade density |
| NY | 12:00–17:00 | 1.35 | 45% | High volume; increased volatility |
| Late | 17:00–24:00 | 1.15 | 35% | Low liquidity; entries restricted by default |

---

## Monte Carlo Acceptance Criteria

Evaluated using `tools/monte_carlo_analysis.py` (N=1 000 simulations, resampling with replacement):

| Metric | Threshold |
|--------|-----------|
| 5th-pct Net Profit | > 0 |
| 95th-pct Max Drawdown | < 12% |
| 5th-pct Profit Factor | ≥ 1.30 |
| % profitable simulations | ≥ 75% |

A **GO** verdict is required on both the baseline simulation **and** the cost-stressed simulation before advancing to live deployment.
