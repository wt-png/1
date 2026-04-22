"""
wfo_pipeline.py — Walk-forward optimization helper.

Reads a trades CSV and runs an expanding-window walk-forward analysis:
  IS window : 6 months
  OOS window: 2 months
  Optimized param: min_adx (grid search)
  IS score  : NetProfit * PF * (1 - DD_pct / 100)

Usage:
    python tools/wfo_pipeline.py --file trades.csv [--output wfo_results.json]

Expected CSV columns:
    - time / open_time / datetime  : trade open time (UTC)
    - pnl / profit                 : trade P&L
    - adx                          : ADX value at entry (optional; synthetic if absent)
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd


IS_MONTHS  = 6
OOS_MONTHS = 2
ADX_GRID   = list(range(10, 45, 5))   # [10, 15, 20, 25, 30, 35, 40]


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

    time_col = _resolve_column(df, ["time", "open_time", "datetime", "Date", "date"])
    pnl_col  = _resolve_column(df, ["pnl", "profit", "Profit", "PnL", "pl"])
    adx_col  = _resolve_column(df, ["adx", "ADX"])

    if time_col is None:
        raise ValueError("No time column found.")
    if pnl_col is None:
        raise ValueError("No P&L column found.")

    df = df.rename(columns={time_col: "time", pnl_col: "pnl"})
    if adx_col:
        df = df.rename(columns={adx_col: "adx"})

    df["time"] = pd.to_datetime(df["time"], utc=True, errors="coerce")
    df = df.dropna(subset=["time", "pnl"])
    df["pnl"] = pd.to_numeric(df["pnl"], errors="coerce")
    df = df.dropna(subset=["pnl"])

    if "adx" not in df.columns:
        rng = np.random.default_rng(42)
        df["adx"] = rng.uniform(10, 50, size=len(df))

    df = df.sort_values("time").reset_index(drop=True)
    return df


def compute_score(pnl: pd.Series) -> float:
    """Custom IS score: NetProfit * PF * (1 - DD_pct/100)."""
    if len(pnl) == 0:
        return -float("inf")
    net = float(pnl.sum())
    gross_profit = float(pnl[pnl > 0].sum())
    gross_loss   = float(abs(pnl[pnl < 0].sum()))
    pf = gross_profit / gross_loss if gross_loss > 0 else (1.0 if gross_profit > 0 else 0.0)
    # max drawdown
    cumsum = pnl.cumsum()
    peak   = cumsum.cummax()
    dd     = (peak - cumsum).max()
    peak_val = peak.max()
    dd_pct = (dd / peak_val * 100.0) if peak_val > 0 else 0.0
    score = net * pf * (1.0 - dd_pct / 100.0)
    return score


def apply_min_adx(df: pd.DataFrame, min_adx: float) -> pd.DataFrame:
    return df[df["adx"] >= min_adx]


def run_fold(is_df: pd.DataFrame, oos_df: pd.DataFrame, fold_idx: int) -> dict:
    # Optimize on IS: grid search over min_adx
    best_param  = ADX_GRID[0]
    best_score  = -float("inf")
    grid_results = []

    for adx_val in ADX_GRID:
        subset = apply_min_adx(is_df, adx_val)
        score  = compute_score(subset["pnl"])
        grid_results.append({"min_adx": adx_val, "score": round(score, 4),
                              "trades": len(subset)})
        if score > best_score:
            best_score = score
            best_param = adx_val

    # Apply best param to OOS
    oos_subset = apply_min_adx(oos_df, best_param)
    oos_score  = compute_score(oos_subset["pnl"])

    degradation = (oos_score / best_score) if best_score not in (0, -float("inf")) else None

    return {
        "fold":        fold_idx,
        "is_start":    str(is_df["time"].min()),
        "is_end":      str(is_df["time"].max()),
        "oos_start":   str(oos_df["time"].min()),
        "oos_end":     str(oos_df["time"].max()),
        "best_min_adx": best_param,
        "is_score":    round(best_score, 4),
        "oos_score":   round(oos_score, 4),
        "degradation_ratio": round(degradation, 4) if degradation is not None else None,
        "oos_trades":  len(oos_subset),
        "grid":        grid_results,
    }


def run_wfo(df: pd.DataFrame) -> list[dict]:
    results = []
    start   = df["time"].min()
    end     = df["time"].max()

    fold_idx    = 1
    is_start    = start
    is_end      = is_start + pd.DateOffset(months=IS_MONTHS)
    oos_end     = is_end   + pd.DateOffset(months=OOS_MONTHS)

    while oos_end <= end + pd.DateOffset(days=1):
        is_df  = df[(df["time"] >= is_start) & (df["time"] < is_end)]
        oos_df = df[(df["time"] >= is_end)   & (df["time"] < oos_end)]

        if len(is_df) < 10 or len(oos_df) < 2:
            break

        fold_result = run_fold(is_df, oos_df, fold_idx)
        results.append(fold_result)

        # Expanding window: keep same is_start, advance oos
        is_end  = oos_end
        oos_end = is_end + pd.DateOffset(months=OOS_MONTHS)
        fold_idx += 1

    return results


def print_results(results: list[dict]) -> None:
    sep = "=" * 70
    print(sep)
    print("WALK-FORWARD OPTIMIZATION RESULTS")
    print(f"IS={IS_MONTHS}m  OOS={OOS_MONTHS}m  Param: min_adx  Grid: {ADX_GRID}")
    print(sep)
    if not results:
        print("  No folds produced — not enough data.")
        return

    for fold in results:
        dr = fold["degradation_ratio"]
        dr_str = f"{dr:.4f}" if dr is not None else "N/A"
        print(f"  Fold {fold['fold']}: IS={fold['is_start'][:10]}–{fold['is_end'][:10]}"
              f"  OOS={fold['oos_start'][:10]}–{fold['oos_end'][:10]}")
        print(f"           best_min_adx={fold['best_min_adx']}  "
              f"IS_score={fold['is_score']:.4f}  "
              f"OOS_score={fold['oos_score']:.4f}  "
              f"Degradation={dr_str}  OOS_trades={fold['oos_trades']}")

    ratios = [f["degradation_ratio"] for f in results if f["degradation_ratio"] is not None]
    if ratios:
        avg_deg = sum(ratios) / len(ratios)
        print(f"\n  Avg IS→OOS degradation ratio: {avg_deg:.4f}")
        if avg_deg < 0.5:
            print("  WARNING: High degradation — possible overfitting on IS.")
    print(sep)


def main() -> None:
    parser = argparse.ArgumentParser(description="Walk-forward optimization pipeline.")
    parser.add_argument("--file",   required=True, help="Path to trades CSV")
    parser.add_argument("--output", default=None,  help="Optional JSON output path")
    args = parser.parse_args()

    if not Path(args.file).exists():
        print(f"ERROR: file not found: {args.file}", file=sys.stderr)
        sys.exit(1)

    df = load_trades(args.file)
    print(f"Loaded {len(df)} trades from {df['time'].min()} to {df['time'].max()}")

    results = run_wfo(df)
    print_results(results)

    output = {
        "config": {"is_months": IS_MONTHS, "oos_months": OOS_MONTHS,
                   "param": "min_adx", "grid": ADX_GRID},
        "folds":  results,
    }

    if args.output:
        with open(args.output, "w") as fh:
            json.dump(output, fh, indent=2, default=str)
        print(f"JSON results saved to: {args.output}")


if __name__ == "__main__":
    main()
