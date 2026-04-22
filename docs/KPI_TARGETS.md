# MSPB EA — KPI Targets & Definitions

> **Purpose**: Establish clear, measurable success criteria before each optimisation cycle.
> All metrics are computed from the Strategy Tester report and from the live ML-export CSV.

---

## 1. Primary KPIs (must improve or hold)

| KPI | Definition | Minimum acceptable | Target |
|-----|-----------|-------------------|--------|
| **Net Expectancy (R)** | Average profit per trade in units of initial risk (R). `E = avg_profit / avg_initial_risk_usd` | ≥ 0.10 R | ≥ 0.20 R |
| **Win Rate** | `wins / total_closed_trades` | ≥ 40 % | ≥ 50 % |
| **Profit Factor** | `gross_profit / gross_loss` | ≥ 1.20 | ≥ 1.50 |
| **Max Equity DD %** | Peak-to-trough equity drawdown | ≤ 15 % | ≤ 10 % |
| **Sharpe Ratio** | `mean_daily_return / std_daily_return * sqrt(252)` | ≥ 0.80 | ≥ 1.20 |
| **Calmar Ratio** | `CAGR % / Max DD %` | ≥ 0.50 | ≥ 1.00 |

## 2. Secondary KPIs (monitor, not hard gates)

| KPI | Definition | Watch level |
|-----|-----------|------------|
| **Avg Hold Time** | Average minutes per closed trade | 10 – 120 min |
| **Avg Slippage (pts)** | Mean entry slippage vs requested price | ≤ 3 pts |
| **Spread Cost %** | `total_spread_cost / gross_profit` | ≤ 20 % |
| **Execution Fill Rate** | `orders_filled / orders_sent` | ≥ 95 % |
| **Consecutive Loss Max** | Longest losing streak | ≤ 6 |
| **Recovery Factor** | `net_profit / max_DD_money` | ≥ 2.0 |
| **Trade Density** | Closed trades per symbol per 30 days | ≥ 30 |

## 3. Regime-specific sub-targets

| Market regime | Identified by | Extra constraint |
|---------------|---------------|-----------------|
| **Trend** | ADX ≥ 30 on H1 | Win rate ≥ 55 %, PF ≥ 1.60 |
| **Range** | ADX < 20 on H1 | Max DD ≤ 8 %, expectancy ≥ 0.05 R |
| **Volatile** | ATR > 80th percentile (200 bars) | Risk mult ≤ 0.5, skip if ATR > 150th pct |

## 4. Stress-test gates (must survive before live deploy)

| Stress scenario | Spread multiplier | Slippage add | Min PF |
|----------------|------------------|-------------|--------|
| Normal | 1.0× | 0 pts | 1.30 |
| Moderate stress | 1.4× | 2 pts | 1.10 |
| High stress | 2.0× | 5 pts | 0.90 (no meltdown) |

## 5. Improvement acceptance criteria

A change is **accepted** when:
1. All primary KPIs improve or stay within ±5 % of baseline.
2. The change **passes all stress scenarios** (PF ≥ gate above).
3. Backtest covers ≥ 3 years with walk-forward out-of-sample ratio ≥ 30 %.
4. Live forward test shows no KPI regression over ≥ 2 weeks and ≥ 50 trades.

## 6. Rollback trigger

Immediately rollback and re-enable previous settings when:
- Profit Factor drops > 10 % below baseline in last 50 live trades, **or**
- Equity DD exceeds 1.5× the baseline DD level, **or**
- Expectancy falls below minimum acceptable for 14 consecutive days.
