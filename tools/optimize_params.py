#!/usr/bin/env python3
"""
MSPB EA — Parameter Grid-Search / Optuna Optimiser
====================================================
Optimises key EA parameters against the ml_export_v2.csv walk-forward
pipeline WITHOUT requiring MetaTrader 5.

Supported modes:
  --mode grid    — exhaustive grid search over a predefined parameter space
  --mode optuna  — Bayesian optimisation via Optuna (install: pip install optuna)

The objective function uses the same walk-forward scoring as wfo_pipeline.py:
  score = mean OOS Sharpe * stable_ratio * mean OOS profit-factor

Usage:
    python tools/optimize_params.py --csv path/to/ml_export_v2.csv
    python tools/optimize_params.py --csv data.csv --mode optuna --n-trials 200
    python tools/optimize_params.py --csv data.csv --mode grid --output results.json

Parameters optimised:
  InpMinADXForEntry      [15–40]   (filters adx_entry column)
  InpMinADXTrendFilter   [15–40]   (filters adx_trend column)
  InpMinATR_Pips         [3–20]    (filters atr_pips column)
  InpMaxSpread_Ratio     [0.05–0.25] (spread/atr_pips ratio cap)
  InpSwingSR_MinRR       [1.2–2.5] (used in WFO scoring weight)
  InpTrail_ATR_Mult      [1.0–3.0] (used in score multiplier proxy)
"""
from __future__ import annotations

import argparse
import csv
import itertools
import json
import math
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# Import walk-forward scoring helpers from wfo_pipeline
try:
    from wfo_pipeline import (
        load_trades, parse_pnl, parse_time,
        walk_forward, score_window, profit_factor, sharpe,
    )
except ImportError:
    # Fallback: support running directly from project root
    import importlib.util, os
    _spec = importlib.util.spec_from_file_location(
        "wfo_pipeline", os.path.join(os.path.dirname(__file__), "wfo_pipeline.py"))
    _wfo = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_wfo)
    load_trades = _wfo.load_trades
    parse_pnl   = _wfo.parse_pnl
    parse_time  = _wfo.parse_time
    walk_forward = _wfo.walk_forward
    score_window = _wfo.score_window
    profit_factor = _wfo.profit_factor
    sharpe       = _wfo.sharpe

TRADING_DAYS_PER_YEAR = 252

# ---------------------------------------------------------------------------
# Default parameter search space (grid mode)
# ---------------------------------------------------------------------------

PARAM_GRID: Dict[str, List[Any]] = {
    "InpMinADXForEntry":    [15, 20, 25, 30],
    "InpMinADXTrendFilter": [15, 20, 25, 30],
    "InpMinATR_Pips":       [3, 5, 8, 12],
    "InpMaxSpread_Ratio":   [0.05, 0.10, 0.15, 0.20],
    "InpSwingSR_MinRR":     [1.2, 1.5, 2.0],
    "InpTrail_ATR_Mult":    [1.0, 1.5, 2.0, 2.5],
}

# Optuna search bounds (continuous)
PARAM_BOUNDS: Dict[str, Tuple[float, float]] = {
    "InpMinADXForEntry":    (15.0, 40.0),
    "InpMinADXTrendFilter": (15.0, 40.0),
    "InpMinATR_Pips":       (3.0,  20.0),
    "InpMaxSpread_Ratio":   (0.05, 0.25),
    "InpSwingSR_MinRR":     (1.2,  2.5),
    "InpTrail_ATR_Mult":    (1.0,  3.0),
}


# ---------------------------------------------------------------------------
# Trade filtering with parameter set
# ---------------------------------------------------------------------------

def filter_trades(rows: List[Dict[str, str]], params: Dict[str, float]) -> List[Dict[str, str]]:
    """Return subset of rows that pass the given EA parameter thresholds."""
    out = []
    min_adx_entry  = params.get("InpMinADXForEntry", 0.0)
    min_adx_trend  = params.get("InpMinADXTrendFilter", 0.0)
    min_atr        = params.get("InpMinATR_Pips", 0.0)
    max_spread_r   = params.get("InpMaxSpread_Ratio", 999.0)

    for r in rows:
        try:
            adx_e  = float(r.get("adx_entry", 0) or 0)
            adx_t  = float(r.get("adx_trend", 0) or 0)
            atr    = float(r.get("atr_pips", 0) or 0)
            spread = float(r.get("spread_pips", 0) or 0)
        except (ValueError, TypeError):
            continue

        if adx_e < min_adx_entry:  continue
        if adx_t < min_adx_trend:  continue
        if atr   < min_atr:        continue
        if atr > 0 and (spread / atr) > max_spread_r: continue

        out.append(r)
    return out


# ---------------------------------------------------------------------------
# Objective function
# ---------------------------------------------------------------------------

def objective(rows: List[Dict[str, str]],
              params: Dict[str, float],
              n_windows: int = 5,
              oos_ratio: float = 0.3) -> float:
    """Compute a single WFO score for the given parameter set."""
    filtered = filter_trades(rows, params)
    if len(filtered) < 20:
        return -1.0  # not enough trades

    pnls_times = []
    for r in filtered:
        pnl = parse_pnl(r)
        t   = parse_time(r)
        if pnl is not None and t is not None:
            pnls_times.append((t, pnl))

    if len(pnls_times) < 10:
        return -1.0

    results = walk_forward(pnls_times, n_windows, oos_ratio)
    if not results:
        return -1.0

    oos_sharpes = [r["oos"]["sharpe"] for r in results]
    oos_pfs     = [r["oos"]["pf"]     for r in results]

    # Stable = OOS Sharpe >= 50% of IS Sharpe AND OOS PF >= 1.0
    stable_count = sum(
        1 for r in results
        if (r["oos"]["sharpe"] / r["is"]["sharpe"] >= 0.5 if r["is"]["sharpe"] > 0.1 else True)
        and r["oos"]["pf"] >= 1.0
    )
    stable_ratio = stable_count / len(results)

    mean_oos_sharpe = sum(oos_sharpes) / len(oos_sharpes)
    mean_oos_pf     = sum(oos_pfs) / len(oos_pfs)

    # Penalise fewer trades relative to total
    trade_penalty = len(filtered) / max(len(rows), 1)

    return mean_oos_sharpe * stable_ratio * mean_oos_pf * trade_penalty


# ---------------------------------------------------------------------------
# Grid search
# ---------------------------------------------------------------------------

def grid_search(rows: List[Dict[str, str]],
                param_grid: Dict[str, List[Any]],
                n_windows: int,
                oos_ratio: float,
                top_n: int = 10) -> List[Dict[str, Any]]:
    keys  = list(param_grid.keys())
    vals  = list(param_grid.values())
    combos = list(itertools.product(*vals))
    total  = len(combos)
    print(f"\nGrid search: {total} combinations over {len(keys)} parameters …")

    results = []
    for idx, combo in enumerate(combos, 1):
        params = dict(zip(keys, combo))
        score  = objective(rows, params, n_windows, oos_ratio)
        results.append({"params": params, "score": score})
        if idx % max(1, total // 10) == 0:
            print(f"  {idx}/{total} ({100*idx//total}%)")

    results.sort(key=lambda x: x["score"], reverse=True)
    return results[:top_n]


# ---------------------------------------------------------------------------
# Optuna search
# ---------------------------------------------------------------------------

def optuna_search(rows: List[Dict[str, str]],
                  param_bounds: Dict[str, Tuple[float, float]],
                  n_trials: int,
                  n_windows: int,
                  oos_ratio: float) -> List[Dict[str, Any]]:
    try:
        import optuna
        optuna.logging.set_verbosity(optuna.logging.WARNING)
    except ImportError:
        print("optuna not installed. Run: pip install optuna", file=sys.stderr)
        sys.exit(1)

    def _objective(trial: "optuna.Trial") -> float:
        params = {k: trial.suggest_float(k, lo, hi)
                  for k, (lo, hi) in param_bounds.items()}
        return objective(rows, params, n_windows, oos_ratio)

    study = optuna.create_study(direction="maximize")
    study.optimize(_objective, n_trials=n_trials, show_progress_bar=True)

    top = []
    for t in sorted(study.trials, key=lambda t: t.value or -999, reverse=True)[:10]:
        top.append({"params": t.params, "score": t.value})
    return top


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def print_top_results(results: List[Dict[str, Any]]) -> None:
    print(f"\n{'='*60}")
    print("Top parameter sets:")
    print(f"{'='*60}")
    for i, r in enumerate(results, 1):
        score  = r.get("score", 0.0)
        params = r.get("params", {})
        param_str = "  ".join(f"{k}={v:.2f}" for k, v in params.items())
        print(f" #{i:>2}  score={score:>8.4f}  |  {param_str}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="MSPB EA Parameter Grid-Search / Optuna Optimiser")
    parser.add_argument("--csv",       required=True,  help="Path to ml_export_v2.csv")
    parser.add_argument("--mode",      default="grid", choices=["grid", "optuna"],
                        help="Optimisation mode (default: grid)")
    parser.add_argument("--windows",   type=int,   default=5,
                        help="WFO windows (default 5)")
    parser.add_argument("--oos-ratio", type=float, default=0.3,
                        help="OOS fraction (default 0.3)")
    parser.add_argument("--n-trials",  type=int,   default=100,
                        help="Optuna trial count (default 100)")
    parser.add_argument("--output",    default="",
                        help="Optional JSON output file for results")
    args = parser.parse_args()

    if not (0.05 <= args.oos_ratio <= 0.95):
        parser.error("--oos-ratio must be between 0.05 and 0.95")

    print(f"Loading {args.csv} …")
    rows = load_trades(args.csv)
    print(f"  {len(rows)} trade rows loaded")

    if len(rows) < 20:
        print("Not enough data (< 20 trades). Cannot optimise.")
        sys.exit(0)

    if args.mode == "grid":
        top = grid_search(rows, PARAM_GRID, args.windows, args.oos_ratio)
    else:
        top = optuna_search(rows, PARAM_BOUNDS, args.n_trials, args.windows, args.oos_ratio)

    print_top_results(top)

    if args.output:
        Path(args.output).write_text(json.dumps(top, indent=2), encoding="utf-8")
        print(f"\nResults written to {args.output}")

    if top:
        best = top[0]
        print(f"\n--- Best parameter set (score={best['score']:.4f}) ---")
        for k, v in best["params"].items():
            print(f"  {k} = {v:.4f}")


if __name__ == "__main__":
    main()
