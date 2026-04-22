# MSPB EA — Baseline Measurement

> **Purpose**: Fix a reproducible nulmeting (zero-measurement) for every KPI before starting
> optimisation work. Update this file each time you establish a new baseline.

---

## How to record a baseline

1. Run the Strategy Tester (MT5) with the parameters listed in **Section 2**.
2. Export the XML report and place it in `tools/` as `baseline_report.xml`.
3. Run `python tools/baseline_report.py` — it prints the KPI table and writes
   `tools/baseline_kpis.json`.
4. Paste the resulting JSON values into **Section 3** below and commit.

---

## Baseline configuration (locked settings)

These settings must not be changed while a baseline is active.

| Parameter | Value |
|-----------|-------|
| Symbols | EURUSD, GBPUSD |
| Timeframe | M5 |
| Period | 2022-01-01 → 2024-12-31 (3 years in-sample) |
| Spread | Real ticks (or fixed 1.5 pip) |
| Slippage | 3 points |
| Initial deposit | 10 000 USD |
| Risk per trade | 0.25 % equity |
| Max positions total | 3 |
| InpSpreadStressMult | 1.0 (no stress) |

---

## Section 3 — Last recorded baseline KPIs

> **Replace the placeholder values below after running `baseline_report.py`.**

```json
{
  "baseline_date": "YYYY-MM-DD",
  "ea_version": "v14.8",
  "period": "2022-01-01 / 2024-12-31",
  "symbols": ["EURUSD", "GBPUSD"],
  "net_profit_usd": null,
  "net_expectancy_R": null,
  "win_rate_pct": null,
  "profit_factor": null,
  "max_equity_dd_pct": null,
  "sharpe_ratio": null,
  "calmar_ratio": null,
  "total_trades": null,
  "avg_hold_min": null,
  "avg_slippage_pts": null,
  "recovery_factor": null
}
```

---

## Comparison table (filled after each sprint)

| Sprint | Date | EA ver | Net Expectancy | Win% | PF | Max DD% | Sharpe | Notes |
|--------|------|--------|----------------|------|----|---------|--------|-------|
| Baseline | — | v14.8 | TBD | TBD | TBD | TBD | TBD | Initial nulmeting |

---

## Notes on reproducibility

- Always use **identical** tick data source (download once, reuse).
- `InpSpreadStressMult = 1.0` for baseline; use `1.4` / `2.0` for stress.
- ML export must be **disabled** (`InpEnableMLExport=false`) during tester runs
  unless you are specifically measuring ML gate impact.
- Document broker suffix if symbols differ (e.g. `EURUSDm`).
