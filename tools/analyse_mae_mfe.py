#!/usr/bin/env python3
"""
MSPB EA — MAE/MFE Analysis Tool
=================================
Reads ml_export_v2.csv and analyses the Maximum Adverse Excursion (MAE) and
Maximum Favourable Excursion (MFE) distributions per symbol, then recommends
optimal ATR-based SL/TP multipliers.

MAE estimation:  loss trades → |profit_pips| / atr_pips  (normalised to ATR)
MFE estimation:  winning trades → profit_pips / atr_pips

The tool pairs each ENTRY row with its matching EXIT row (via pos_id) and
computes per-symbol distributions.

Usage
-----
  python tools/analyse_mae_mfe.py \\
      --csv ml_export_v2.csv \\
      [--output mae_mfe_report.txt] \\
      [--sl-pct 90]   # use 90th-pct of MAE as recommended SL distance
      [--tp-pct 60]   # use 60th-pct of MFE as recommended TP distance
"""

from __future__ import annotations

import argparse
import csv
import math
import sys
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Optional, Tuple


_MISSING = {"", "nan", "null", "n/a", "na", "-"}


def _flt(v: str, default: float = float("nan")) -> float:
    s = v.strip().lower()
    return float(v) if s not in _MISSING else default


def load_csv(path: str) -> List[Dict[str, str]]:
    rows: List[Dict[str, str]] = []
    with open(path, newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh, delimiter=";")
        for r in reader:
            rows.append(r)
    return rows


def _percentile(data: List[float], pct: float) -> float:
    if not data:
        return float("nan")
    s = sorted(data)
    idx = (pct / 100.0) * (len(s) - 1)
    lo = int(idx)
    hi = lo + 1
    if hi >= len(s):
        return s[-1]
    return s[lo] + (idx - lo) * (s[hi] - s[lo])


def _mean(data: List[float]) -> float:
    return sum(data) / len(data) if data else float("nan")


def _stdev(data: List[float]) -> float:
    if len(data) < 2:
        return float("nan")
    m = _mean(data)
    return math.sqrt(sum((x - m) ** 2 for x in data) / (len(data) - 1))


def pair_trades(rows: List[Dict[str, str]]) -> List[Dict]:
    """Match ENTRY and EXIT rows by pos_id, return matched trade dicts."""
    entries: Dict[str, Dict[str, str]] = {}
    exits:   Dict[str, Dict[str, str]] = {}

    for r in rows:
        ev = r.get("event", "").strip().upper()
        pid = r.get("pos_id", "").strip()
        if not pid or pid == "0":
            continue
        if ev == "ENTRY":
            if pid not in entries:
                entries[pid] = r
        elif ev == "EXIT":
            if pid not in exits:
                exits[pid] = r

    trades = []
    for pid, entry in entries.items():
        if pid not in exits:
            continue
        exit_row = exits[pid]

        sym        = entry.get("sym", "")
        entry_px   = _flt(entry.get("entry", ""))
        sl_px      = _flt(entry.get("sl", ""))
        tp_px      = _flt(entry.get("tp", ""))
        atr_pips   = _flt(entry.get("atr_pips", ""))
        direction  = entry.get("dir", "BUY").strip().upper()

        profit_pips  = _flt(exit_row.get("profit_pips", ""))
        profit_money = _flt(exit_row.get("profit_money", ""))

        if any(math.isnan(v) for v in [entry_px, atr_pips]):
            continue
        if atr_pips <= 0:
            continue

        is_buy = (direction != "SELL")

        # Estimate initial SL distance in pips
        sl_dist_pips = float("nan")
        if not math.isnan(sl_px) and sl_px > 0 and entry_px > 0:
            sl_dist_pips = abs(entry_px - sl_px) / (atr_pips * 1e-4
                            if atr_pips < 0.01 else 1.0)
            # If entry/sl look like price quotes, compute pips differently
            # Rough: if sl_dist_pips is way too large, estimate from atr ratio
            raw_dist = abs(entry_px - sl_px)
            # For FX (5-digit): pip ~ 0.0001; dist in price / pip_est
            pip_est = entry_px * 1e-4 if entry_px > 50 else 1e-4
            sl_dist_pips = raw_dist / pip_est

        is_win = (not math.isnan(profit_money) and profit_money > 0) or \
                 (math.isnan(profit_money) and not math.isnan(profit_pips)
                  and profit_pips > 0)

        # MAE (in ATR units): for a loss, the full extent before it hit SL
        # We use |profit_pips| / atr_pips as a lower-bound MAE estimate for losers
        mae_r: Optional[float] = None
        mfe_r: Optional[float] = None

        if not math.isnan(profit_pips):
            if is_win:
                mfe_r = profit_pips / atr_pips   # winner captured MFE (lower bound)
            else:
                mae_r = abs(profit_pips) / atr_pips  # how far it went against us

        trades.append({
            "sym":           sym,
            "pos_id":        pid,
            "direction":     direction,
            "atr_pips":      atr_pips,
            "sl_dist_pips":  sl_dist_pips,
            "profit_pips":   profit_pips,
            "profit_money":  profit_money,
            "is_win":        is_win,
            "mae_r":         mae_r,
            "mfe_r":         mfe_r,
        })

    return trades


def compute_sl_mult_from_atr_entry(
    entry_px: float, sl_px: float, atr_pips: float, pip_size: float = 1e-4
) -> float:
    if entry_px <= 0 or sl_px <= 0 or atr_pips <= 0:
        return float("nan")
    raw_dist = abs(entry_px - sl_px)
    dist_pips = raw_dist / pip_size
    return dist_pips / atr_pips


def analyse(trades: List[Dict], sl_pct: float, tp_pct: float) -> Dict[str, Dict]:
    # Group by symbol
    by_sym: Dict[str, List[Dict]] = defaultdict(list)
    for t in trades:
        by_sym[t["sym"]].append(t)

    results: Dict[str, Dict] = {}

    for sym, ts in sorted(by_sym.items()):
        wins   = [t for t in ts if t["is_win"]]
        losses = [t for t in ts if not t["is_win"]]

        # MAE distribution (from losers)
        mae_vals = [t["mae_r"] for t in losses if t["mae_r"] is not None]
        # MFE distribution (from winners)
        mfe_vals = [t["mfe_r"] for t in wins  if t["mfe_r"] is not None]

        win_rate = len(wins) / len(ts) if ts else float("nan")

        rec_sl_mult = _percentile(mae_vals, sl_pct) if mae_vals else float("nan")
        rec_tp_mult = _percentile(mfe_vals, tp_pct) if mfe_vals else float("nan")

        results[sym] = {
            "trades":        len(ts),
            "wins":          len(wins),
            "losses":        len(losses),
            "win_rate":      round(win_rate, 3),
            "mae_mean":      round(_mean(mae_vals), 3) if mae_vals else float("nan"),
            "mae_stdev":     round(_stdev(mae_vals), 3) if mae_vals else float("nan"),
            f"mae_p{int(sl_pct)}":   round(_percentile(mae_vals, sl_pct), 3) if mae_vals else float("nan"),
            "mfe_mean":      round(_mean(mfe_vals), 3) if mfe_vals else float("nan"),
            "mfe_stdev":     round(_stdev(mfe_vals), 3) if mfe_vals else float("nan"),
            f"mfe_p{int(tp_pct)}":   round(_percentile(mfe_vals, tp_pct), 3) if mfe_vals else float("nan"),
            "rec_sl_atr_mult": round(rec_sl_mult, 2) if not math.isnan(rec_sl_mult) else None,
            "rec_tp_atr_mult": round(rec_tp_mult, 2) if not math.isnan(rec_tp_mult) else None,
        }

    return results


def format_report(results: Dict[str, Dict], sl_pct: float, tp_pct: float) -> str:
    lines = [
        "# MSPB EA — MAE/MFE Analysis Report",
        f"# SL recommendation: {int(sl_pct)}th-percentile of MAE distribution (in ATR units)",
        f"# TP recommendation: {int(tp_pct)}th-percentile of MFE distribution (in ATR units)",
        "",
    ]

    hdr = f"{'Symbol':<12} {'Trades':>6} {'WinRate':>8} "
    hdr += f"{'MAE_mean':>9} {'MAE_p'+str(int(sl_pct)):>9} "
    hdr += f"{'MFE_mean':>9} {'MFE_p'+str(int(tp_pct)):>9} "
    hdr += f"{'RecSL_mult':>11} {'RecTP_mult':>11}"
    lines.append(hdr)
    lines.append("-" * len(hdr))

    for sym, r in results.items():
        sl_m = f"{r['rec_sl_atr_mult']:.2f}" if r["rec_sl_atr_mult"] is not None else "N/A"
        tp_m = f"{r['rec_tp_atr_mult']:.2f}" if r["rec_tp_atr_mult"] is not None else "N/A"

        mae_p_key = f"mae_p{int(sl_pct)}"
        mfe_p_key = f"mfe_p{int(tp_pct)}"

        def fmt(v):
            if isinstance(v, float) and math.isnan(v):
                return "   N/A"
            return f"{v:9.3f}"

        lines.append(
            f"{sym:<12} {r['trades']:>6} {r['win_rate']:>8.3f} "
            f"{fmt(r['mae_mean'])} {fmt(r.get(mae_p_key, float('nan')))} "
            f"{fmt(r['mfe_mean'])} {fmt(r.get(mfe_p_key, float('nan')))} "
            f"{sl_m:>11} {tp_m:>11}"
        )

    lines += [
        "",
        "Notes:",
        "  RecSL_mult → suggested InpSL_ATR_Mult override per symbol",
        "  RecTP_mult → use InpTP_RR = RecTP_mult / RecSL_mult for balanced R:R",
        "  Review against at least 50 trades per symbol before applying.",
    ]
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description="MSPB MAE/MFE Analysis")
    parser.add_argument("--csv",      required=True, help="Path to ml_export_v2.csv")
    parser.add_argument("--output",   default="mae_mfe_report.txt")
    parser.add_argument("--sl-pct",   type=float, default=90.0,
                        help="MAE percentile for SL recommendation (default 90)")
    parser.add_argument("--tp-pct",   type=float, default=60.0,
                        help="MFE percentile for TP recommendation (default 60)")
    args = parser.parse_args()

    print(f"Loading {args.csv} …")
    rows = load_csv(args.csv)
    print(f"  {len(rows)} rows loaded")

    trades = pair_trades(rows)
    print(f"  {len(trades)} matched ENTRY+EXIT pairs")

    if not trades:
        print("No matched trade pairs found. Ensure ml_export_v2.csv contains both ENTRY and EXIT rows.")
        sys.exit(0)

    results = analyse(trades, args.sl_pct, args.tp_pct)
    report  = format_report(results, args.sl_pct, args.tp_pct)

    print("\n" + report)

    Path(args.output).write_text(report + "\n", encoding="utf-8")
    print(f"\nReport written to {args.output}")


if __name__ == "__main__":
    main()
