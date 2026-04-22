"""
baseline_report.py
==================
Parse an MSPB EA ML-export CSV (ml_export_v2.csv) and compute the baseline
KPI snapshot defined in docs/KPI_TARGETS.md.

Usage
-----
    python tools/baseline_report.py [ml_export.csv] [--out baseline_kpis.json]

The input CSV uses semicolons as delimiter and must contain at minimum:
    symbol, profit, lots, sl_dist_pips, entry_time, exit_time

Output
------
Prints a KPI table and writes a JSON file that can be pasted into docs/BASELINE.md.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

# ── optional dependencies ──────────────────────────────────────────────────────
try:
    import numpy as np
    import pandas as pd
    _HAS_PANDAS = True
except ImportError:  # pragma: no cover
    _HAS_PANDAS = False


# ── helpers ───────────────────────────────────────────────────────────────────

def _safe_div(a: float, b: float, default: float = 0.0) -> float:
    return a / b if b != 0.0 else default


def _profit_factor(gross_profit: float, gross_loss: float) -> float:
    """Profit factor; returns gross_profit when gross_loss is 0 (all-winner case)."""
    if gross_loss == 0.0:
        return gross_profit if gross_profit > 0.0 else 0.0
    return gross_profit / gross_loss


def _sharpe(daily_returns: List[float]) -> float:
    """Annualised Sharpe ratio from daily P&L series."""
    if len(daily_returns) < 2:
        return 0.0
    mean = sum(daily_returns) / len(daily_returns)
    variance = sum((r - mean) ** 2 for r in daily_returns) / (len(daily_returns) - 1)
    std = math.sqrt(variance) if variance > 0 else 0.0
    return _safe_div(mean, std) * math.sqrt(252)


def _max_dd_pct(equity_curve: List[float]) -> float:
    """Peak-to-trough max drawdown percentage."""
    peak = equity_curve[0] if equity_curve else 0.0
    max_dd = 0.0
    for eq in equity_curve:
        if eq > peak:
            peak = eq
        if peak > 0:
            dd = (peak - eq) / peak * 100.0
            if dd > max_dd:
                max_dd = dd
    return max_dd


def _calmar(cagr_pct: float, max_dd_pct_val: float) -> float:
    return _safe_div(cagr_pct, max_dd_pct_val)


def _cagr(start: float, end: float, years: float) -> float:
    if start <= 0 or end <= 0 or years <= 0:
        return 0.0
    return ((end / start) ** (1.0 / years) - 1.0) * 100.0


# ── core computation ──────────────────────────────────────────────────────────

def compute_kpis(trades: List[Dict[str, Any]], initial_balance: float = 10_000.0) -> Dict[str, Any]:
    """
    Compute KPIs from a list of trade dicts.

    Each dict must have:
        profit (float)  — net P&L in account currency
        r_risk  (float) — risk in account currency (lots * pip_value * sl_pips)

    Optional fields: entry_time, exit_time, slippage_pts, spread_pips.
    """
    if not trades:
        return {"error": "no trades provided"}

    profits = [t.get("profit", 0.0) for t in trades]
    r_risks = [t.get("r_risk", 0.0) for t in trades]

    wins = [p for p in profits if p > 0]
    losses = [p for p in profits if p < 0]

    total = len(profits)
    win_rate = len(wins) / total * 100.0 if total else 0.0
    gross_profit = sum(wins)
    gross_loss = abs(sum(losses))
    profit_factor = _profit_factor(gross_profit, gross_loss)
    net_profit = sum(profits)

    # Expectancy in R units
    valid_r = [(p, r) for p, r in zip(profits, r_risks) if r > 0]
    if valid_r:
        expectancy_r = sum(p / r for p, r in valid_r) / len(valid_r)
    else:
        expectancy_r = 0.0

    # Equity curve
    equity = initial_balance
    equity_curve = [equity]
    for p in profits:
        equity += p
        equity_curve.append(equity)

    max_dd = _max_dd_pct(equity_curve)

    # Daily returns for Sharpe
    daily_pnl: Dict[str, float] = {}
    for t in trades:
        day_key = str(t.get("exit_time", ""))[:10]
        if day_key:
            daily_pnl[day_key] = daily_pnl.get(day_key, 0.0) + t.get("profit", 0.0)

    daily_returns = list(daily_pnl.values())
    sharpe = _sharpe(daily_returns)

    # Duration stats
    durations: List[float] = []
    for t in trades:
        entry_raw = t.get("entry_time")
        exit_raw = t.get("exit_time")
        if entry_raw and exit_raw:
            try:
                entry_dt = _parse_dt(entry_raw)
                exit_dt = _parse_dt(exit_raw)
                if entry_dt and exit_dt and exit_dt > entry_dt:
                    durations.append((exit_dt - entry_dt).total_seconds() / 60.0)
            except Exception:
                pass

    avg_hold_min = sum(durations) / len(durations) if durations else 0.0

    # Slippage
    slippages = [t.get("slippage_pts", 0.0) for t in trades if "slippage_pts" in t]
    avg_slippage_pts = sum(slippages) / len(slippages) if slippages else 0.0

    # CAGR & Calmar
    if durations:
        all_exits = [t.get("exit_time") for t in trades if t.get("exit_time")]
        all_exits_dt = sorted([_parse_dt(d) for d in all_exits if _parse_dt(d)])  # type: ignore
        if len(all_exits_dt) >= 2:
            years = max((all_exits_dt[-1] - all_exits_dt[0]).days / 365.25, 0.01)
        else:
            years = 1.0
    else:
        years = 1.0

    cagr = _cagr(initial_balance, equity_curve[-1], years)
    calmar = _calmar(cagr, max_dd)
    recovery = _safe_div(net_profit, equity_curve[0] * max_dd / 100.0)

    return {
        "total_trades": total,
        "win_rate_pct": round(win_rate, 2),
        "profit_factor": round(profit_factor, 3),
        "net_profit_usd": round(net_profit, 2),
        "net_expectancy_R": round(expectancy_r, 4),
        "max_equity_dd_pct": round(max_dd, 2),
        "sharpe_ratio": round(sharpe, 3),
        "calmar_ratio": round(calmar, 3),
        "cagr_pct": round(cagr, 2),
        "avg_hold_min": round(avg_hold_min, 1),
        "avg_slippage_pts": round(avg_slippage_pts, 2),
        "recovery_factor": round(recovery, 2),
    }


def _parse_dt(value: Any) -> Optional[datetime]:
    if isinstance(value, datetime):
        return value
    if not isinstance(value, str):
        return None
    for fmt in ("%Y.%m.%d %H:%M:%S", "%Y.%m.%d %H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"):
        try:
            return datetime.strptime(value.strip(), fmt)
        except ValueError:
            continue
    return None


# ── CSV loading ───────────────────────────────────────────────────────────────

REQUIRED_COLS = {"profit"}
OPTIONAL_COLS = {
    "symbol", "lots", "sl_pips", "entry_time", "exit_time",
    "slippage_pts", "spread_pips", "r_risk",
}


def load_trades_from_csv(path: str) -> List[Dict[str, Any]]:
    """Load trade records from the ML-export CSV (semicolon-delimited)."""
    if _HAS_PANDAS:
        return _load_pandas(path)
    return _load_builtin(path)


def _load_pandas(path: str) -> List[Dict[str, Any]]:
    df = pd.read_csv(path, sep=";", encoding="utf-8-sig", low_memory=False)
    df.columns = [c.strip().lower() for c in df.columns]

    if "profit" not in df.columns:
        raise ValueError(f"CSV '{path}' has no 'profit' column. Found: {list(df.columns)}")

    # Derive r_risk when missing
    if "r_risk" not in df.columns:
        if "lots" in df.columns and "sl_pips" in df.columns:
            df["r_risk"] = (df["lots"].astype(float) * df["sl_pips"].astype(float) * 10.0).abs()
        else:
            df["r_risk"] = 0.0

    df["profit"] = pd.to_numeric(df["profit"], errors="coerce").fillna(0.0)
    df["r_risk"] = pd.to_numeric(df["r_risk"], errors="coerce").fillna(0.0)

    return df.to_dict(orient="records")


def _load_builtin(path: str) -> List[Dict[str, Any]]:
    trades: List[Dict[str, Any]] = []
    with open(path, encoding="utf-8-sig") as fh:
        header = fh.readline().strip().split(";")
        header = [h.strip().lower() for h in header]
        for line in fh:
            parts = line.strip().split(";")
            if len(parts) != len(header):
                continue
            row = dict(zip(header, parts))
            try:
                row["profit"] = float(row.get("profit", 0) or 0)
                row["r_risk"] = float(row.get("r_risk", 0) or 0)
            except ValueError:
                continue
            trades.append(row)
    return trades


# ── CLI ───────────────────────────────────────────────────────────────────────

def _print_kpis(kpis: Dict[str, Any]) -> None:
    print("\n" + "=" * 55)
    print("  MSPB Baseline KPI Snapshot")
    print("=" * 55)
    for k, v in kpis.items():
        print(f"  {k:<26} {v}")
    print("=" * 55 + "\n")


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="MSPB baseline KPI report")
    parser.add_argument("csv", nargs="?", default="ml_export_v2.csv",
                        help="Path to ML-export CSV (default: ml_export_v2.csv)")
    parser.add_argument("--out", default="tools/baseline_kpis.json",
                        help="Output JSON path")
    parser.add_argument("--balance", type=float, default=10_000.0,
                        help="Initial account balance in USD")
    args = parser.parse_args(argv)

    if not os.path.isfile(args.csv):
        print(f"[ERROR] CSV not found: {args.csv}", file=sys.stderr)
        print("  → Run the EA with InpEnableMLExport=true to generate it.", file=sys.stderr)
        return 1

    trades = load_trades_from_csv(args.csv)
    print(f"Loaded {len(trades)} trade records from '{args.csv}'.")

    kpis = compute_kpis(trades, initial_balance=args.balance)
    _print_kpis(kpis)

    os.makedirs(os.path.dirname(args.out) if os.path.dirname(args.out) else ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(kpis, fh, indent=2, default=str)
    print(f"KPIs written to '{args.out}'.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
