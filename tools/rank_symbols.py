#!/usr/bin/env python3
"""
MSPB EA — Symbol Ranking by Rolling Sharpe Ratio
=================================================
Reads ml_export_v2.csv (or a compatible semicolon-delimited file) and computes
a rolling Sharpe ratio per symbol over a configurable lookback window. Outputs
a ranked CSV that the EA reads on Monday open to enable only the top-N symbols.

Output CSV format (semicolon-delimited)
---------------------------------------
  symbol;rank;sharpe;trades;win_rate;enabled
  EURUSD;1;1.42;87;0.61;1
  GBPUSD;2;0.98;64;0.57;1
  CUCUSD;3;0.31;45;0.51;0

The EA reads the "enabled" column to decide which symbols to trade that week.

Usage
-----
  python tools/rank_symbols.py \\
      --csv ml_export_v2.csv \\
      --output ml_symbol_rank.csv \\
      [--top-n 3] \\
      [--lookback-days 30]
"""

from __future__ import annotations

import argparse
import csv
import math
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple


_MISSING = {"", "nan", "null", "n/a", "na", "-"}


def _flt(v: str, default: float = float("nan")) -> float:
    s = v.strip().lower()
    return float(v) if s not in _MISSING else default


def _parse_ts(s: str) -> Optional[datetime]:
    """Parse broker timestamp formats: '2026.04.19 13:00' or ISO."""
    s = s.strip()
    for fmt in ("%Y.%m.%d %H:%M", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S",
                "%Y.%m.%d %H:%M:%S"):
        try:
            return datetime.strptime(s, fmt)
        except ValueError:
            pass
    return None


def load_csv(path: str) -> List[Dict[str, str]]:
    rows: List[Dict[str, str]] = []
    with open(path, newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh, delimiter=";")
        for r in reader:
            rows.append(r)
    return rows


def pair_trades(rows: List[Dict[str, str]],
                lookback_days: int) -> List[Dict]:
    """Match ENTRY and EXIT rows by pos_id, filter by lookback window."""
    entries: Dict[str, Dict[str, str]] = {}
    exits:   Dict[str, Dict[str, str]] = {}

    for r in rows:
        ev = r.get("event", "").strip().upper()
        pid = r.get("pos_id", "").strip()
        if not pid or pid == "0":
            continue
        if ev == "ENTRY" and pid not in entries:
            entries[pid] = r
        elif ev == "EXIT" and pid not in exits:
            exits[pid] = r

    now = datetime.now(timezone.utc).replace(tzinfo=None)
    cutoff_days = lookback_days

    trades = []
    for pid, entry in entries.items():
        if pid not in exits:
            continue
        exit_row = exits[pid]

        ts_str = exit_row.get("ts") or entry.get("ts") or ""
        ts = _parse_ts(ts_str)

        if ts is not None and cutoff_days > 0:
            age_days = (now - ts).total_seconds() / 86400.0
            if age_days > cutoff_days:
                continue

        sym          = entry.get("sym", "").strip()
        profit_money = _flt(exit_row.get("profit_money", ""))
        profit_pips  = _flt(exit_row.get("profit_pips", ""))

        if not sym:
            continue

        trades.append({
            "sym":          sym,
            "pos_id":       pid,
            "profit_money": profit_money,
            "profit_pips":  profit_pips,
            "ts":           ts,
        })

    return trades


def compute_sharpe(profits: List[float]) -> float:
    """Annualised Sharpe (simplified: mean/std of per-trade P&L, no risk-free)."""
    if len(profits) < 2:
        return 0.0
    mean = sum(profits) / len(profits)
    var  = sum((p - mean) ** 2 for p in profits) / (len(profits) - 1)
    std  = math.sqrt(var) if var > 0 else 0.0
    if std <= 0:
        return 0.0
    # Scale to approximate annualised: assume ~250 trades per year
    return round(mean / std * math.sqrt(250), 4)


def rank_symbols(trades: List[Dict], top_n: int) -> List[Dict]:
    by_sym: Dict[str, List[float]] = defaultdict(list)
    wins:   Dict[str, int] = defaultdict(int)

    for t in trades:
        sym = t["sym"]
        p   = t["profit_money"]
        if math.isnan(p):
            p = t["profit_pips"]
        if math.isnan(p):
            continue
        by_sym[sym].append(p)
        if p > 0:
            wins[sym] += 1

    rankings: List[Dict] = []
    for sym, profits in by_sym.items():
        n = len(profits)
        win_rate = wins[sym] / n if n > 0 else 0.0
        sharpe   = compute_sharpe(profits)
        rankings.append({
            "symbol":   sym,
            "sharpe":   sharpe,
            "trades":   n,
            "win_rate": round(win_rate, 4),
        })

    rankings.sort(key=lambda r: -r["sharpe"])

    for i, r in enumerate(rankings):
        r["rank"]    = i + 1
        r["enabled"] = 1 if (top_n <= 0 or i < top_n) else 0

    return rankings


def write_ranking(rankings: List[Dict], output_path: str) -> None:
    with open(output_path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(
            fh,
            fieldnames=["symbol", "rank", "sharpe", "trades", "win_rate", "enabled"],
            delimiter=";",
            extrasaction="ignore",
        )
        writer.writeheader()
        for r in rankings:
            writer.writerow({
                "symbol":   r["symbol"],
                "rank":     r["rank"],
                "sharpe":   f"{r['sharpe']:.4f}",
                "trades":   r["trades"],
                "win_rate": f"{r['win_rate']:.4f}",
                "enabled":  r["enabled"],
            })


def print_rankings(rankings: List[Dict]) -> None:
    hdr = f"{'Symbol':<14} {'Rank':>5} {'Sharpe':>8} {'Trades':>7} {'WinRate':>9} {'Enabled':>8}"
    print("\n=== Symbol Rankings ===")
    print(hdr)
    print("-" * len(hdr))
    for r in rankings:
        en_str = "✓" if r["enabled"] else "✗"
        print(
            f"{r['symbol']:<14} {r['rank']:>5} {r['sharpe']:>8.4f} "
            f"{r['trades']:>7} {r['win_rate']:>9.4f} {en_str:>8}"
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="MSPB Symbol Ranking by Sharpe Ratio")
    parser.add_argument("--csv",            required=True, help="Path to ml_export_v2.csv")
    parser.add_argument("--output",         default="ml_symbol_rank.csv",
                        help="Output ranking CSV (default: ml_symbol_rank.csv)")
    parser.add_argument("--top-n",          type=int, default=3,
                        help="Number of top symbols to enable (0 = all; default 3)")
    parser.add_argument("--lookback-days",  type=int, default=30,
                        help="Rolling window in days (0 = all history; default 30)")
    args = parser.parse_args()

    print(f"Loading {args.csv} …")
    rows = load_csv(args.csv)
    print(f"  {len(rows)} rows")

    trades = pair_trades(rows, args.lookback_days)
    print(f"  {len(trades)} matched EXIT trades in last {args.lookback_days} days")

    if not trades:
        print("No trades found. Ensure ml_export_v2.csv contains EXIT rows.")
        sys.exit(0)

    rankings = rank_symbols(trades, args.top_n)
    print_rankings(rankings)

    write_ranking(rankings, args.output)
    print(f"\nRanking written to {args.output}")
    print(f"Top-{args.top_n} enabled: "
          f"{[r['symbol'] for r in rankings if r['enabled']]}")


if __name__ == "__main__":
    main()
