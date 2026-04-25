"""
analyse_mae_mfe.py
==================
MAE/MFE entry-quality analysis for the MSPB EA.

Maximum Adverse Excursion (MAE) measures how far a trade went against the
entry before closing.  Maximum Favourable Excursion (MFE) measures how far
the trade moved in our favour before closing.

Since MT5 ML-export CSVs do not include intra-trade tick extremes, we use
risk-adjusted proxies that are fully derivable from the standard export:

  MAE_proxy  = sl_pips          (the distance to the stop — worst-case risk)
  MFE_proxy  = |profit_pips|    (pips captured when trade closed)
               where profit_pips = profit / (lots * pip_value_usd)

Key insight
-----------
If the average MFE_proxy of *all* trades is systematically lower than the
average MAE_proxy, entries are structurally wrong-side — the market is
moving against us before reversing (if at all).

Bucket analysis
---------------
Every closed trade falls into one of four categories:

  WINNER_CLEAN   — profit > 0  and  MFE_proxy >= 0.5 × sl_pips   (good capture)
  WINNER_MARGINAL— profit > 0  and  MFE_proxy <  0.5 × sl_pips   (barely won)
  LOSER_MARGINAL — profit < 0  and  |profit_pips| < 0.5 × sl_pips (stopped early)
  LOSER_RUNAWAY  — profit < 0  and  |profit_pips| >= 0.5 × sl_pips (full stop)

Usage
-----
    python tools/analyse_mae_mfe.py [trades.csv] [options]

    --pip-value    USD value per pip per lot (default 10.0 for 5-decimal FX)
    --out          Output JSON path
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
from baseline_report import load_trades_from_csv, _safe_div  # noqa: E402


# ── bucket constants ──────────────────────────────────────────────────────────

WINNER_CLEAN    = "WINNER_CLEAN"
WINNER_MARGINAL = "WINNER_MARGINAL"
LOSER_MARGINAL  = "LOSER_MARGINAL"
LOSER_RUNAWAY   = "LOSER_RUNAWAY"


# ── core analysis ─────────────────────────────────────────────────────────────

def _profit_pips(trade: Dict[str, Any], pip_value_usd: float) -> float:
    """Convert profit USD → pips using lots and pip_value_usd."""
    profit = float(trade.get("profit", 0.0))
    lots   = float(trade.get("lots", 0.01) or 0.01)
    denom  = lots * pip_value_usd
    return _safe_div(profit, denom)


def _sl_pips(trade: Dict[str, Any]) -> float:
    """Return the stop-loss distance in pips (MAE proxy)."""
    # Try multiple common column names exported by the EA
    for col in ("sl_pips", "sl_dist_pips", "sl_distance_pips", "stop_pips"):
        val = trade.get(col)
        if val is not None and str(val).strip() != "":
            try:
                return abs(float(val))
            except (ValueError, TypeError):
                pass
    return 0.0


def classify_trade(trade: Dict[str, Any], pip_value_usd: float) -> str:
    """Assign a trade to one of the four MAE/MFE quality buckets."""
    profit = float(trade.get("profit", 0.0))
    sl     = _sl_pips(trade)
    mfe    = abs(_profit_pips(trade, pip_value_usd))

    threshold = 0.5 * sl if sl > 0 else 0.0

    if profit > 0:
        return WINNER_CLEAN if mfe >= threshold else WINNER_MARGINAL
    else:
        return LOSER_RUNAWAY if mfe >= threshold else LOSER_MARGINAL


def run_mae_mfe_analysis(
    trades: List[Dict[str, Any]],
    pip_value_usd: float = 10.0,
) -> Dict[str, Any]:
    """
    Compute MAE/MFE quality metrics from a list of trade records.

    Returns a dict with bucket counts, ratios, average excursions, and an
    ``action`` field that maps directly to EA parameter changes.
    """
    if not trades:
        return {"error": "no trades provided"}

    # Per-trade metrics
    buckets: Dict[str, int] = {
        WINNER_CLEAN: 0, WINNER_MARGINAL: 0,
        LOSER_MARGINAL: 0, LOSER_RUNAWAY: 0,
    }
    mfe_values:  List[float] = []
    mae_proxies: List[float] = []
    capture_ratios: List[float] = []

    for t in trades:
        bucket = classify_trade(t, pip_value_usd)
        buckets[bucket] += 1

        mfe = abs(_profit_pips(t, pip_value_usd))
        sl  = _sl_pips(t)
        mfe_values.append(mfe)
        mae_proxies.append(sl)

        if sl > 0:
            capture_ratios.append(mfe / sl)

    total = len(trades)
    avg_mfe        = _safe_div(sum(mfe_values),    len(mfe_values))
    avg_mae_proxy  = _safe_div(sum(mae_proxies),   len(mae_proxies))
    avg_capture    = _safe_div(sum(capture_ratios), len(capture_ratios))

    # Structural wrong-side flag: avg MFE < 30 % of avg MAE proxy
    wrong_side = avg_mae_proxy > 0 and avg_mfe < 0.30 * avg_mae_proxy

    # Runaway loser ratio (entries that went straight to stop)
    runaway_ratio = _safe_div(buckets[LOSER_RUNAWAY], total) * 100.0

    # Diagnosis
    if wrong_side and runaway_ratio > 40:
        action = "STRENGTHEN_HTF_BIAS"
        explanation = (
            "Most trades move against the entry immediately. "
            "Strengthen the HTF-bias filter and tighten the pullback-origin check."
        )
    elif avg_capture < 0.30 and not wrong_side:
        action = "WIDEN_TP_OR_TRAIL"
        explanation = (
            "Trades reach a favourable excursion but exit too early. "
            "Consider widening TP targets or enabling the TP ladder/trailing stop."
        )
    elif runaway_ratio > 50:
        action = "TIGHTEN_ENTRY_FILTERS"
        explanation = (
            "High ratio of full stop-outs. "
            "Raise ADX/ATR entry thresholds or add a body/wick quality filter."
        )
    else:
        action = "MONITOR"
        explanation = "No critical entry-quality issue detected. Continue monitoring."

    # Per-symbol breakdown (if symbol column present)
    symbols: Dict[str, Dict[str, Any]] = {}
    for t in trades:
        sym = str(t.get("symbol", "UNKNOWN")).strip() or "UNKNOWN"
        if sym not in symbols:
            symbols[sym] = {
                "trades": 0,
                "mfe_sum": 0.0,
                "mae_sum": 0.0,
                "wins": 0,
                "losses": 0,
            }
        d = symbols[sym]
        d["trades"] += 1
        d["mfe_sum"]  += abs(_profit_pips(t, pip_value_usd))
        d["mae_sum"]  += _sl_pips(t)
        if float(t.get("profit", 0.0)) > 0:
            d["wins"] += 1
        else:
            d["losses"] += 1

    per_symbol = []
    for sym, d in sorted(symbols.items()):
        n = d["trades"]
        avg_sym_mfe = _safe_div(d["mfe_sum"], n)
        avg_sym_mae = _safe_div(d["mae_sum"], n)
        sym_cap     = _safe_div(avg_sym_mfe, avg_sym_mae) if avg_sym_mae > 0 else 0.0
        per_symbol.append({
            "symbol":          sym,
            "trades":          n,
            "wins":            d["wins"],
            "losses":          d["losses"],
            "avg_mfe_pips":    round(avg_sym_mfe, 2),
            "avg_mae_pips":    round(avg_sym_mae, 2),
            "avg_capture_ratio": round(sym_cap, 3),
        })

    return {
        "generated_at":      datetime.now(timezone.utc).isoformat(),
        "total_trades":      total,
        "pip_value_usd":     pip_value_usd,
        "avg_mfe_pips":      round(avg_mfe, 2),
        "avg_mae_proxy_pips": round(avg_mae_proxy, 2),
        "avg_capture_ratio": round(avg_capture, 3),
        "wrong_side_flag":   wrong_side,
        "runaway_loser_pct": round(runaway_ratio, 1),
        "buckets":           buckets,
        "action":            action,
        "explanation":       explanation,
        "per_symbol":        per_symbol,
    }


# ── CLI ───────────────────────────────────────────────────────────────────────

def _print_results(r: Dict[str, Any]) -> None:
    print("\n" + "=" * 60)
    print("  MAE / MFE Entry-Quality Analysis")
    print("=" * 60)
    print(f"  Trades analysed     : {r['total_trades']}")
    print(f"  Avg MFE (pips)      : {r['avg_mfe_pips']}")
    print(f"  Avg MAE proxy (pips): {r['avg_mae_proxy_pips']}")
    print(f"  Avg capture ratio   : {r['avg_capture_ratio'] * 100:.1f}%")
    print(f"  Wrong-side flag     : {'⚠ YES' if r['wrong_side_flag'] else 'OK'}")
    print(f"  Runaway losers      : {r['runaway_loser_pct']} %")
    print()
    print("  Buckets:")
    for bucket, count in r["buckets"].items():
        pct = count / r["total_trades"] * 100 if r["total_trades"] else 0
        print(f"    {bucket:<20} {count:>5}  ({pct:5.1f} %)")
    print()
    print(f"  ► Action  : {r['action']}")
    print(f"    {r['explanation']}")
    if r.get("per_symbol"):
        print(f"\n  {'Symbol':<12} {'N':>5} {'MFE':>8} {'MAE':>8} {'Capture':>9}")
        print("  " + "-" * 46)
        for s in r["per_symbol"]:
            print(
                f"  {s['symbol']:<12} {s['trades']:>5} "
                f"{s['avg_mfe_pips']:>8.2f} {s['avg_mae_pips']:>8.2f} "
                f"{s['avg_capture_ratio']:>9.3f}"
            )
    print("=" * 60 + "\n")


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="MSPB MAE/MFE entry-quality analysis")
    parser.add_argument("csv", nargs="?", default="ml_export_v2.csv")
    parser.add_argument("--pip-value", type=float, default=10.0,
                        help="USD value per pip per lot (default 10.0)")
    parser.add_argument("--out", default="tools/wfo_results/mae_mfe_latest.json")
    args = parser.parse_args(argv)

    if not os.path.isfile(args.csv):
        print(f"[ERROR] CSV not found: {args.csv}", file=sys.stderr)
        return 1

    trades = load_trades_from_csv(args.csv)
    print(f"Loaded {len(trades)} trades from '{args.csv}'.")

    results = run_mae_mfe_analysis(trades, pip_value_usd=args.pip_value)
    _print_results(results)

    os.makedirs(os.path.dirname(args.out) if os.path.dirname(args.out) else ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(results, fh, indent=2, default=str)
    print(f"Results written to '{args.out}'.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
