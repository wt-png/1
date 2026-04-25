"""
rank_symbols.py
===============
Per-symbol performance ranking for the MSPB EA.

Loads a trade CSV and computes KPIs for every symbol independently, then
ranks them from best to worst.  Symbols are tagged with an actionable
recommendation:

  KEEP          — profit_factor >= 1.30 and win_rate >= 45 %
  REDUCE_RISK   — profit_factor >= 1.00 (profitable but not strong)
  BLACKLIST     — profit_factor <  1.00 (losing — remove from InpSymbols)

Usage
-----
    python tools/rank_symbols.py [trades.csv] [options]

    --min-trades  Minimum number of trades to include a symbol (default 5)
    --out         Output JSON path (default: tools/wfo_results/symbol_rank.json)
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

_DIR = os.path.dirname(__file__)
sys.path.insert(0, _DIR)
from baseline_report import compute_kpis, load_trades_from_csv, _safe_div  # noqa: E402


# ── recommendation thresholds (mirrors session_analysis.py) ──────────────────

_PF_KEEP         = 1.30
_PF_REDUCE       = 1.00
_WIN_RATE_KEEP   = 45.0


def _recommend(pf: float, win_rate: float) -> str:
    if pf >= _PF_KEEP and win_rate >= _WIN_RATE_KEEP:
        return "KEEP"
    if pf >= _PF_REDUCE:
        return "REDUCE_RISK"
    return "BLACKLIST"


# ── core ranking ──────────────────────────────────────────────────────────────

def rank_symbols(
    trades: List[Dict[str, Any]],
    min_trades: int = 5,
    initial_balance: float = 10_000.0,
) -> Dict[str, Any]:
    """
    Compute per-symbol KPIs and return a ranked list.

    Returns a dict with:
        generated_at   — ISO timestamp
        total_trades   — total trade count across all symbols
        symbols        — list of per-symbol dicts, best PF first
        blacklist      — symbols recommended for removal
        reduce_risk    — symbols recommended for lower position size
        keep           — symbols recommended to keep as-is
    """
    if not trades:
        return {"error": "no trades provided"}

    # Group trades by symbol
    grouped: Dict[str, List[Dict[str, Any]]] = {}
    for t in trades:
        sym = str(t.get("symbol", "UNKNOWN")).strip() or "UNKNOWN"
        grouped.setdefault(sym, []).append(t)

    symbol_rows: List[Dict[str, Any]] = []
    for sym, sym_trades in grouped.items():
        if len(sym_trades) < min_trades:
            symbol_rows.append({
                "symbol":        sym,
                "trades":        len(sym_trades),
                "win_rate_pct":  None,
                "profit_factor": None,
                "net_expectancy_R": None,
                "net_profit_usd":   None,
                "max_equity_dd_pct": None,
                "recommendation": "INSUFFICIENT_DATA",
                "skipped":        True,
            })
            continue

        kpis = compute_kpis(sym_trades, initial_balance)
        pf   = kpis.get("profit_factor", 0.0) or 0.0
        wr   = kpis.get("win_rate_pct",  0.0) or 0.0
        rec  = _recommend(pf, wr)

        symbol_rows.append({
            "symbol":            sym,
            "trades":            len(sym_trades),
            "win_rate_pct":      kpis.get("win_rate_pct"),
            "profit_factor":     kpis.get("profit_factor"),
            "net_expectancy_R":  kpis.get("net_expectancy_R"),
            "net_profit_usd":    kpis.get("net_profit_usd"),
            "max_equity_dd_pct": kpis.get("max_equity_dd_pct"),
            "recommendation":    rec,
            "skipped":           False,
        })

    # Rank: KEEP first (highest PF), then REDUCE_RISK, then BLACKLIST
    def _sort_key(row: Dict[str, Any]) -> float:
        if row.get("skipped"):
            return -999.0
        return float(row.get("profit_factor") or 0.0)

    symbol_rows.sort(key=_sort_key, reverse=True)

    blacklist    = [r["symbol"] for r in symbol_rows if r["recommendation"] == "BLACKLIST"]
    reduce_risk  = [r["symbol"] for r in symbol_rows if r["recommendation"] == "REDUCE_RISK"]
    keep         = [r["symbol"] for r in symbol_rows if r["recommendation"] == "KEEP"]

    return {
        "generated_at":  datetime.now(timezone.utc).isoformat(),
        "total_trades":  len(trades),
        "min_trades":    min_trades,
        "symbols":       symbol_rows,
        "keep":          keep,
        "reduce_risk":   reduce_risk,
        "blacklist":     blacklist,
    }


# ── CLI ───────────────────────────────────────────────────────────────────────

def _print_table(rows: List[Dict[str, Any]]) -> None:
    print(f"\n{'─'*80}")
    print("  Symbol Performance Ranking")
    print(f"{'─'*80}")
    print(f"  {'Symbol':<14} {'N':>5} {'WR%':>7} {'PF':>7} {'ExpR':>8} {'Net$':>9}  {'Rec'}")
    print(f"  {'─'*76}")
    for r in rows:
        if r.get("skipped"):
            print(f"  {r['symbol']:<14} {r['trades']:>5}  (insufficient data)")
            continue
        print(
            f"  {r['symbol']:<14} {r['trades']:>5} "
            f"{str(r['win_rate_pct'] or '')+'%':>7} "
            f"{str(r['profit_factor'] or ''):>7} "
            f"{str(r['net_expectancy_R'] or ''):>8} "
            f"{str(r['net_profit_usd'] or ''):>9}  "
            f"{r['recommendation']}"
        )
    print(f"{'─'*80}\n")


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="MSPB symbol performance ranking")
    parser.add_argument("csv", nargs="?", default="ml_export_v2.csv")
    parser.add_argument("--min-trades", type=int, default=5,
                        help="Minimum trades required to rank a symbol (default 5)")
    parser.add_argument("--out", default="tools/wfo_results/symbol_rank.json")
    parser.add_argument("--balance", type=float, default=10_000.0)
    args = parser.parse_args(argv)

    if not os.path.isfile(args.csv):
        print(f"[ERROR] CSV not found: {args.csv}", file=sys.stderr)
        return 1

    trades = load_trades_from_csv(args.csv)
    print(f"Loaded {len(trades)} trades from '{args.csv}'.")

    results = rank_symbols(trades, min_trades=args.min_trades,
                           initial_balance=args.balance)

    _print_table(results.get("symbols", []))

    if results.get("blacklist"):
        print(f"⛔  BLACKLIST (remove from EA): {', '.join(results['blacklist'])}")
    if results.get("reduce_risk"):
        print(f"⚠   REDUCE RISK              : {', '.join(results['reduce_risk'])}")
    if results.get("keep"):
        print(f"✓   KEEP                     : {', '.join(results['keep'])}")

    os.makedirs(os.path.dirname(args.out) if os.path.dirname(args.out) else ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(results, fh, indent=2, default=str)
    print(f"\nResults written to '{args.out}'.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
