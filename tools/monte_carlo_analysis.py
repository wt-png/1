"""
monte_carlo_analysis.py — Monte Carlo stress test for trade sequences.

Usage:
    python tools/monte_carlo_analysis.py --file trades.csv [--output mc_results.json]
    python tools/monte_carlo_analysis.py --file trades.csv --n-sims 2000 --cost-spread-pct 20

Expected CSV columns:
    - pnl / profit  : trade P&L (required)
    - spread / cost : spread cost (optional; used for stress testing)
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd


N_SIMS_DEFAULT       = 1000
COST_SPREAD_PCT      = 20.0    # add 20% to spread/cost
SLIPPAGE_PER_TRADE   = 0.0002  # fixed slippage per trade (in same units as pnl)
KPI_PF_MIN           = 1.3
KPI_DD_MAX_PCT       = 12.0


def _resolve_column(df: pd.DataFrame, candidates: list[str]) -> str | None:
    lower = {col.lower(): col for col in df.columns}
    for c in candidates:
        if c in df.columns:
            return c
        if c.lower() in lower:
            return lower[c.lower()]
    return None


def load_trades(path: str) -> pd.DataFrame:
    df = pd.read_csv(path)
    df.columns = [c.strip() for c in df.columns]

    pnl_col    = _resolve_column(df, ["pnl", "profit", "Profit", "PnL", "pl"])
    spread_col = _resolve_column(df, ["spread", "cost", "commission"])

    if pnl_col is None:
        raise ValueError("No P&L column found. Expected: pnl, profit, Profit, PnL.")

    df = df.rename(columns={pnl_col: "pnl"})
    if spread_col:
        df = df.rename(columns={spread_col: "spread"})

    df["pnl"] = pd.to_numeric(df["pnl"], errors="coerce")
    df = df.dropna(subset=["pnl"])
    return df


def apply_cost_stress(pnl: np.ndarray, spread_costs: np.ndarray | None,
                      spread_pct: float, slippage: float) -> np.ndarray:
    """Reduce PnL by additional spread cost + slippage."""
    stressed = pnl.copy().astype(float)
    if spread_costs is not None and len(spread_costs) == len(stressed):
        stressed -= spread_costs * (spread_pct / 100.0)
    stressed -= slippage
    return stressed


def max_drawdown_pct(pnl_seq: np.ndarray) -> float:
    cumsum = np.cumsum(pnl_seq)
    peak   = np.maximum.accumulate(cumsum)
    dd     = peak - cumsum
    peak_max = peak.max()
    if peak_max <= 0:
        return 0.0
    return float(dd.max() / peak_max * 100.0)


def profit_factor(pnl_seq: np.ndarray) -> float:
    wins   = pnl_seq[pnl_seq > 0].sum()
    losses = abs(pnl_seq[pnl_seq < 0].sum())
    if losses == 0:
        return float("inf") if wins > 0 else 1.0
    return float(wins / losses)


def run_simulations(pnl: np.ndarray, n_sims: int,
                    spread_costs: np.ndarray | None,
                    spread_pct: float, slippage: float,
                    rng: np.random.Generator) -> dict:
    net_profits = np.zeros(n_sims)
    max_dds     = np.zeros(n_sims)
    pfs         = np.zeros(n_sims)

    for i in range(n_sims):
        idx    = rng.integers(0, len(pnl), size=len(pnl))
        sample = pnl[idx]
        sc     = spread_costs[idx] if spread_costs is not None else None
        sample = apply_cost_stress(sample, sc, spread_pct, slippage)
        net_profits[i] = sample.sum()
        max_dds[i]     = max_drawdown_pct(sample)
        pfs[i]         = profit_factor(sample)

    return {
        "net_profit_median":    float(np.median(net_profits)),
        "net_profit_p5":        float(np.percentile(net_profits, 5)),
        "net_profit_p95":       float(np.percentile(net_profits, 95)),
        "max_dd_median_pct":    float(np.median(max_dds)),
        "max_dd_p95_pct":       float(np.percentile(max_dds, 95)),
        "pf_median":            float(np.median(pfs)),
        "pf_p5":                float(np.percentile(pfs, 5)),
        "pct_sims_profitable":  float(np.mean(net_profits > 0) * 100),
        "pct_sims_dd_ok":       float(np.mean(max_dds < KPI_DD_MAX_PCT) * 100),
        "pct_sims_pf_ok":       float(np.mean(pfs >= KPI_PF_MIN) * 100),
    }


def go_no_go(stats: dict) -> tuple[str, list[str]]:
    issues = []
    if stats["net_profit_p5"] <= 0:
        issues.append(f"5th-pct net profit = {stats['net_profit_p5']:.2f} ≤ 0")
    if stats["max_dd_p95_pct"] >= KPI_DD_MAX_PCT:
        issues.append(f"95th-pct max DD = {stats['max_dd_p95_pct']:.1f}% ≥ {KPI_DD_MAX_PCT}%")
    if stats["pf_p5"] < KPI_PF_MIN:
        issues.append(f"5th-pct PF = {stats['pf_p5']:.3f} < {KPI_PF_MIN}")
    if stats["pct_sims_profitable"] < 75.0:
        issues.append(f"Only {stats['pct_sims_profitable']:.1f}% of sims profitable (< 75%)")
    verdict = "GO" if not issues else "NO-GO"
    return verdict, issues


def run_analysis(path: str, n_sims: int = N_SIMS_DEFAULT,
                 spread_pct: float = COST_SPREAD_PCT,
                 slippage: float = SLIPPAGE_PER_TRADE) -> dict:
    df = load_trades(path)
    pnl = df["pnl"].to_numpy(dtype=float)
    spread_costs = df["spread"].to_numpy(dtype=float) if "spread" in df.columns else None

    rng = np.random.default_rng(42)

    # Baseline (no stress)
    baseline = run_simulations(pnl, n_sims, None, 0.0, 0.0, rng)
    # Stressed
    rng2 = np.random.default_rng(42)
    stressed = run_simulations(pnl, n_sims, spread_costs, spread_pct, slippage, rng2)

    verdict_base, issues_base     = go_no_go(baseline)
    verdict_stress, issues_stress = go_no_go(stressed)

    actual_pf  = profit_factor(pnl)
    actual_dd  = max_drawdown_pct(pnl)

    return {
        "file":          path,
        "n_trades":      int(len(pnl)),
        "n_sims":        n_sims,
        "cost_stress":   {"spread_pct": spread_pct, "slippage_per_trade": slippage},
        "actual": {
            "net_pnl":       round(float(pnl.sum()), 4),
            "profit_factor": round(actual_pf, 4) if actual_pf != float("inf") else None,
            "max_dd_pct":    round(actual_dd, 4),
        },
        "baseline_mc":    {k: round(v, 4) for k, v in baseline.items()},
        "stressed_mc":    {k: round(v, 4) for k, v in stressed.items()},
        "verdict_baseline": {"decision": verdict_base,  "issues": issues_base},
        "verdict_stressed": {"decision": verdict_stress, "issues": issues_stress},
        "kpi_thresholds": {"pf_min": KPI_PF_MIN, "max_dd_pct": KPI_DD_MAX_PCT},
    }


def print_report(report: dict) -> None:
    sep = "=" * 60
    print(sep)
    print(f"MONTE CARLO STRESS TEST — {report['file']}")
    print(f"Trades: {report['n_trades']}  |  Simulations: {report['n_sims']}")
    print(f"Cost stress: +{report['cost_stress']['spread_pct']}% spread  "
          f"+{report['cost_stress']['slippage_per_trade']} slippage/trade")
    print(sep)

    actual = report["actual"]
    pf_str = f"{actual['profit_factor']:.3f}" if actual["profit_factor"] is not None else "∞"
    print(f"\nACTUAL (historic sequence)")
    print(f"  Net P&L={actual['net_pnl']:.4f}  PF={pf_str}  Max DD={actual['max_dd_pct']:.2f}%")

    for label, key in [("BASELINE MC", "baseline_mc"), ("STRESSED MC", "stressed_mc")]:
        s = report[key]
        print(f"\n{label} (n={report['n_sims']})")
        print(f"  Net P&L : median={s['net_profit_median']:.4f}  "
              f"p5={s['net_profit_p5']:.4f}  p95={s['net_profit_p95']:.4f}")
        print(f"  Max DD%  : median={s['max_dd_median_pct']:.2f}%  p95={s['max_dd_p95_pct']:.2f}%")
        print(f"  PF       : median={s['pf_median']:.3f}  p5={s['pf_p5']:.3f}")
        print(f"  Profitable sims: {s['pct_sims_profitable']:.1f}%  "
              f"DD-OK: {s['pct_sims_dd_ok']:.1f}%  "
              f"PF-OK: {s['pct_sims_pf_ok']:.1f}%")

    for label, vkey in [("BASELINE VERDICT", "verdict_baseline"),
                         ("STRESSED VERDICT", "verdict_stressed")]:
        v = report[vkey]
        status = "✓ GO" if v["decision"] == "GO" else "✗ NO-GO"
        print(f"\n{label}: {status}")
        for issue in v["issues"]:
            print(f"  ⚠  {issue}")

    print(sep)


def main() -> None:
    parser = argparse.ArgumentParser(description="Monte Carlo stress test for trade sequences.")
    parser.add_argument("--file",            required=True,               help="Path to trades CSV")
    parser.add_argument("--n-sims",          type=int,  default=N_SIMS_DEFAULT, help="Number of simulations")
    parser.add_argument("--cost-spread-pct", type=float, default=COST_SPREAD_PCT,
                        help="Additional spread cost %% for stress test")
    parser.add_argument("--output",          default=None, help="Optional JSON output path")
    args = parser.parse_args()

    if not Path(args.file).exists():
        print(f"ERROR: file not found: {args.file}", file=sys.stderr)
        sys.exit(1)

    report = run_analysis(args.file, n_sims=args.n_sims, spread_pct=args.cost_spread_pct)
    print_report(report)

    if args.output:
        with open(args.output, "w") as fh:
            json.dump(report, fh, indent=2, default=str)
        print(f"\nJSON report saved to: {args.output}")


if __name__ == "__main__":
    main()
