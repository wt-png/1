"""
monte_carlo_analysis.py
=======================
Monte Carlo simulation for the MSPB EA trade history.

Randomly reshuffles the closed-trade P&L sequence N times to estimate
the distribution of key metrics (max drawdown, profit factor, Sharpe).
Used to detect overfitting: if real results are in the top 5 % of the
random distribution, the strategy is likely curve-fitted.

Usage
-----
    python tools/monte_carlo_analysis.py [trades.csv] [options]

    --iterations   Number of Monte Carlo runs (default 2000)
    --out          Output JSON path (default: tools/stress_results/mc_latest.json)
"""
from __future__ import annotations

import argparse
import json
import os
import random
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

_DIR = os.path.dirname(__file__)
sys.path.insert(0, _DIR)
from baseline_report import compute_kpis, load_trades_from_csv, _safe_div  # noqa: E402


# ── Monte Carlo core ──────────────────────────────────────────────────────────

def _percentile(data: List[float], pct: float) -> float:
    """Compute percentile without numpy dependency."""
    if not data:
        return 0.0
    sorted_data = sorted(data)
    idx = (pct / 100.0) * (len(sorted_data) - 1)
    lo = int(idx)
    hi = min(lo + 1, len(sorted_data) - 1)
    frac = idx - lo
    return sorted_data[lo] * (1 - frac) + sorted_data[hi] * frac


def _reshuffle(trades: List[Dict[str, Any]], seed: int) -> List[Dict[str, Any]]:
    """Return a copy of trades with profits randomly reshuffled."""
    rng = random.Random(seed)
    profits = [t.get("profit", 0.0) for t in trades]
    rng.shuffle(profits)
    shuffled = []
    for t, p in zip(trades, profits):
        copy = dict(t)
        copy["profit"] = p
        shuffled.append(copy)
    return shuffled


def run_monte_carlo(
    trades: List[Dict[str, Any]],
    iterations: int = 2000,
    initial_balance: float = 10_000.0,
    seed: int = 42,
) -> Dict[str, Any]:
    """
    Run Monte Carlo reshuffling and return distribution statistics.

    Returns a dict with:
        real_kpis         — KPIs from the original trade sequence
        mc_pf_dist        — (p5, p25, p50, p75, p95) of profit factor
        mc_dd_dist        — (p5, p25, p50, p75, p95) of max drawdown %
        mc_exp_dist       — (p5, p25, p50, p75, p95) of expectancy R
        real_pf_percentile — where real PF falls in MC distribution (0-100)
        real_dd_percentile — where real DD falls in MC distribution (0-100)
        overfitting_flag  — True when real PF is in top 5 % of MC dist
    """
    real_kpis = compute_kpis(trades, initial_balance)
    real_pf = real_kpis.get("profit_factor", 0.0) or 0.0
    real_dd = real_kpis.get("max_equity_dd_pct", 0.0) or 0.0
    real_exp = real_kpis.get("net_expectancy_R", 0.0) or 0.0

    mc_pfs: List[float] = []
    mc_dds: List[float] = []
    mc_exps: List[float] = []

    rng = random.Random(seed)
    for i in range(iterations):
        shuffled = _reshuffle(trades, rng.randint(0, 2**31))
        kpis = compute_kpis(shuffled, initial_balance)
        mc_pfs.append(kpis.get("profit_factor", 0.0) or 0.0)
        mc_dds.append(kpis.get("max_equity_dd_pct", 0.0) or 0.0)
        mc_exps.append(kpis.get("net_expectancy_R", 0.0) or 0.0)

    def _dist(data: List[float]) -> Dict[str, float]:
        return {
            "p5":  round(_percentile(data, 5), 4),
            "p25": round(_percentile(data, 25), 4),
            "p50": round(_percentile(data, 50), 4),
            "p75": round(_percentile(data, 75), 4),
            "p95": round(_percentile(data, 95), 4),
        }

    # Where does the real value sit in the MC distribution?
    def _rank_pct(real: float, dist: List[float]) -> float:
        if not dist:
            return 50.0
        below = sum(1 for x in dist if x <= real)
        return round(below / len(dist) * 100.0, 1)

    real_pf_pct = _rank_pct(real_pf, mc_pfs)
    real_dd_pct = _rank_pct(real_dd, mc_dds)

    # Overfitting flag: real PF is suspiciously in the top 5 % of random reshuffles
    overfitting_flag = real_pf_pct >= 95.0

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "total_trades": len(trades),
        "iterations": iterations,
        "real_kpis": real_kpis,
        "mc_pf_distribution": _dist(mc_pfs),
        "mc_dd_distribution": _dist(mc_dds),
        "mc_exp_distribution": _dist(mc_exps),
        "real_pf_percentile": real_pf_pct,
        "real_dd_percentile": real_dd_pct,
        "overfitting_flag": overfitting_flag,
        "verdict": (
            "OVERFIT_RISK" if overfitting_flag else
            "MARGINAL" if real_pf < 1.10 else
            "ROBUST"
        ),
        "interpretation": (
            "Real PF is in the top 5% of reshuffled distributions — possible curve fitting."
            if overfitting_flag else
            "Real PF is within the expected range — no strong overfitting signal."
        ),
    }


# ── CLI ───────────────────────────────────────────────────────────────────────

def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="MSPB Monte Carlo analysis")
    parser.add_argument("csv", nargs="?", default="ml_export_v2.csv")
    parser.add_argument("--iterations", type=int, default=2000)
    parser.add_argument("--out", default="tools/stress_results/mc_latest.json")
    parser.add_argument("--balance", type=float, default=10_000.0)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args(argv)

    if not os.path.isfile(args.csv):
        print(f"[ERROR] CSV not found: {args.csv}", file=sys.stderr)
        return 1

    trades = load_trades_from_csv(args.csv)
    print(f"Loaded {len(trades)} trades. Running {args.iterations} Monte Carlo iterations…")

    results = run_monte_carlo(trades, args.iterations, args.balance, args.seed)

    print(f"\nVerdict            : {results['verdict']}")
    print(f"Real PF            : {results['real_kpis'].get('profit_factor')}")
    print(f"Real PF percentile : {results['real_pf_percentile']} % (vs MC distribution)")
    print(f"MC PF p50          : {results['mc_pf_distribution']['p50']}")
    print(f"MC PF p95          : {results['mc_pf_distribution']['p95']}")
    print(f"Overfitting flag   : {results['overfitting_flag']}")
    print(f"\n{results['interpretation']}")

    os.makedirs(os.path.dirname(args.out) if os.path.dirname(args.out) else ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(results, fh, indent=2, default=str)
    print(f"\nResults written to '{args.out}'.")
    return 0 if results["verdict"] != "OVERFIT_RISK" else 2


if __name__ == "__main__":
    sys.exit(main())
