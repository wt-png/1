"""
wfo_pipeline.py
===============
Walk-Forward Optimisation (WFO) pipeline for the MSPB Expert Advisor.

The pipeline:
1. Splits the trade history into rolling in-sample / out-of-sample windows.
2. Detects the market regime (trend / range / volatile) for each window.
3. Computes per-regime KPIs and selects parameter sets that are robust across regimes.
4. Writes a JSON results file suitable for CI artefact upload.

Usage
-----
    python tools/wfo_pipeline.py [trades.csv] [options]

    --windows      Number of WFO folds (default 5)
    --oos-ratio    Fraction of each window reserved for out-of-sample (default 0.30)
    --regimes      Space-separated regime names to evaluate (default: trend range volatile)
    --out          Output JSON path (default: tools/wfo_results/latest.json)
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

# local helper shared with baseline_report
_DIR = os.path.dirname(__file__)
sys.path.insert(0, _DIR)
from baseline_report import (  # noqa: E402
    compute_kpis,
    load_trades_from_csv,
    _parse_dt,
    _safe_div,
)


# ── regime detection ──────────────────────────────────────────────────────────

def detect_regime(trades: List[Dict[str, Any]]) -> str:
    """
    Heuristic regime detection from a window of trades.

    Uses the spread between mean profit of winning and losing trades as a
    proxy for trend strength, and trade-count volatility as a proxy for
    volatile markets.

    Returns: "trend" | "range" | "volatile"
    """
    if len(trades) < 5:
        return "range"

    profits = [t.get("profit", 0.0) for t in trades]
    wins = [p for p in profits if p > 0]
    losses = [p for p in profits if p < 0]

    if not wins or not losses:
        return "range"

    avg_win = sum(wins) / len(wins)
    avg_loss = abs(sum(losses) / len(losses))
    win_rate = len(wins) / len(profits)

    # Strong trend: high win rate + large avg-win relative to avg-loss
    if win_rate >= 0.55 and avg_win >= 1.5 * avg_loss:
        return "trend"

    # Volatile: negative expectancy but with high variance
    mean_p = sum(profits) / len(profits)
    variance = sum((p - mean_p) ** 2 for p in profits) / len(profits)
    std_p = math.sqrt(variance)
    if std_p > 3.0 * abs(mean_p) and win_rate < 0.45:
        return "volatile"

    return "range"


# ── WFO core ──────────────────────────────────────────────────────────────────

def split_windows(
    trades: List[Dict[str, Any]],
    n_windows: int,
    oos_ratio: float,
) -> List[Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]]:
    """
    Split sorted trades into (in-sample, out-of-sample) window pairs.
    Windows are anchored at the start and expand by one fold each step.
    """
    n = len(trades)
    if n < 2 * n_windows:
        # Not enough data — use a single 70/30 split
        split = int(n * (1.0 - oos_ratio))
        return [(trades[:split], trades[split:])]

    window_size = n // n_windows
    splits: List[Tuple[List, List]] = []
    for i in range(1, n_windows + 1):
        end_is = i * window_size
        oos_size = max(1, int(end_is * oos_ratio))
        is_size = end_is - oos_size
        if is_size < 1:
            continue
        is_trades = trades[:is_size]
        oos_trades = trades[is_size:end_is]
        if oos_trades:
            splits.append((is_trades, oos_trades))

    return splits if splits else [(trades[:int(n * (1 - oos_ratio))], trades[int(n * (1 - oos_ratio)):])]


def run_wfo(
    trades: List[Dict[str, Any]],
    n_windows: int = 5,
    oos_ratio: float = 0.30,
    target_regimes: Optional[List[str]] = None,
    initial_balance: float = 10_000.0,
) -> Dict[str, Any]:
    """
    Run WFO and return a results dict.

    Returns summary with per-fold IS/OOS KPIs and regime labels,
    plus an overall robustness score.
    """
    if target_regimes is None:
        target_regimes = ["trend", "range", "volatile"]

    # Sort trades by exit_time
    def sort_key(t: Dict[str, Any]) -> datetime:
        dt = _parse_dt(t.get("exit_time", ""))
        return dt if dt else datetime.min

    sorted_trades = sorted(trades, key=sort_key)
    windows = split_windows(sorted_trades, n_windows, oos_ratio)

    folds: List[Dict[str, Any]] = []
    oos_pfs: List[float] = []
    oos_expectancies: List[float] = []

    for fold_idx, (is_trades, oos_trades) in enumerate(windows):
        is_kpis = compute_kpis(is_trades, initial_balance)
        oos_kpis = compute_kpis(oos_trades, initial_balance)
        regime = detect_regime(is_trades)

        fold = {
            "fold": fold_idx + 1,
            "is_trades": len(is_trades),
            "oos_trades": len(oos_trades),
            "regime": regime,
            "in_sample": {k: is_kpis.get(k) for k in ("profit_factor", "net_expectancy_R", "win_rate_pct", "max_equity_dd_pct")},
            "out_of_sample": {k: oos_kpis.get(k) for k in ("profit_factor", "net_expectancy_R", "win_rate_pct", "max_equity_dd_pct")},
        }
        folds.append(fold)

        pf = oos_kpis.get("profit_factor", 0.0) or 0.0
        exp = oos_kpis.get("net_expectancy_R", 0.0) or 0.0
        oos_pfs.append(pf)
        oos_expectancies.append(exp)

    # Robustness: fraction of OOS folds with PF >= 1.0
    robust_folds = sum(1 for pf in oos_pfs if pf >= 1.0)
    robustness_score = robust_folds / len(oos_pfs) if oos_pfs else 0.0

    avg_oos_pf = sum(oos_pfs) / len(oos_pfs) if oos_pfs else 0.0
    avg_oos_exp = sum(oos_expectancies) / len(oos_expectancies) if oos_expectancies else 0.0

    # Per-regime summary
    regime_summary: Dict[str, Dict[str, Any]] = {}
    for regime in target_regimes:
        regime_folds = [f for f in folds if f["regime"] == regime]
        if not regime_folds:
            regime_summary[regime] = {"folds": 0, "avg_oos_pf": None, "avg_oos_exp_r": None}
            continue
        r_pfs = [f["out_of_sample"]["profit_factor"] or 0.0 for f in regime_folds]
        r_exp = [f["out_of_sample"]["net_expectancy_R"] or 0.0 for f in regime_folds]
        regime_summary[regime] = {
            "folds": len(regime_folds),
            "avg_oos_pf": round(sum(r_pfs) / len(r_pfs), 3),
            "avg_oos_exp_r": round(sum(r_exp) / len(r_exp), 4),
        }

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "total_trades": len(trades),
        "n_windows": n_windows,
        "oos_ratio": oos_ratio,
        "folds": folds,
        "overall": {
            "robustness_score": round(robustness_score, 3),
            "avg_oos_profit_factor": round(avg_oos_pf, 3),
            "avg_oos_expectancy_R": round(avg_oos_exp, 4),
            "recommendation": "ACCEPT" if robustness_score >= 0.6 and avg_oos_pf >= 1.10 else "REJECT",
        },
        "regime_summary": regime_summary,
    }


# ── CLI ───────────────────────────────────────────────────────────────────────

def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="MSPB WFO pipeline")
    parser.add_argument("csv", nargs="?", default="ml_export_v2.csv")
    parser.add_argument("--windows", type=int, default=5)
    parser.add_argument("--oos-ratio", type=float, default=0.30)
    parser.add_argument("--regimes", nargs="+", default=["trend", "range", "volatile"])
    parser.add_argument("--out", default="tools/wfo_results/latest.json")
    parser.add_argument("--balance", type=float, default=10_000.0)
    args = parser.parse_args(argv)

    if not os.path.isfile(args.csv):
        print(f"[ERROR] CSV not found: {args.csv}", file=sys.stderr)
        return 1

    trades = load_trades_from_csv(args.csv)
    print(f"Loaded {len(trades)} trades. Running WFO ({args.windows} folds, {args.oos_ratio:.0%} OOS)…")

    results = run_wfo(
        trades,
        n_windows=args.windows,
        oos_ratio=args.oos_ratio,
        target_regimes=args.regimes,
        initial_balance=args.balance,
    )

    overall = results["overall"]
    print(f"\nRobustness score : {overall['robustness_score']:.1%}")
    print(f"Avg OOS PF       : {overall['avg_oos_profit_factor']:.3f}")
    print(f"Avg OOS Exp (R)  : {overall['avg_oos_expectancy_R']:.4f}")
    print(f"Recommendation   : {overall['recommendation']}")

    print("\nPer-regime summary:")
    for reg, info in results["regime_summary"].items():
        print(f"  {reg:<10} folds={info['folds']}  avg_oos_pf={info['avg_oos_pf']}  avg_oos_exp_R={info['avg_oos_exp_r']}")

    os.makedirs(os.path.dirname(args.out) if os.path.dirname(args.out) else ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(results, fh, indent=2, default=str)
    print(f"\nResults written to '{args.out}'.")
    return 0 if overall["recommendation"] == "ACCEPT" else 2


if __name__ == "__main__":
    sys.exit(main())
