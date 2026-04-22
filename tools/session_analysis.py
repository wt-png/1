"""
session_analysis.py
===================
Session-level execution quality analysis for the MSPB EA.

Splits closed trades by broker session (Asia / London / New York) and computes
per-session KPIs to identify which sessions deliver value and which should have
entries blocked or risk reduced.

Usage
-----
    python tools/session_analysis.py [trades.csv] [options]

    --gmt-offset   Broker server GMT offset in hours (default: 2)
    --out          Output JSON path
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone, timedelta
from typing import Any, Dict, List, Optional, Tuple

_DIR = os.path.dirname(__file__)
sys.path.insert(0, _DIR)
from baseline_report import compute_kpis, load_trades_from_csv, _parse_dt  # noqa: E402


# ── session definitions (local broker time) ───────────────────────────────────
# Hours are inclusive lower-bound, exclusive upper-bound.
SESSIONS: List[Tuple[str, int, int]] = [
    ("Asia",     0,  8),   # 00:00 – 07:59
    ("London",   8, 13),   # 08:00 – 12:59
    ("Overlap",  13, 16),  # 13:00 – 15:59  (London/NY overlap)
    ("NewYork",  16, 20),  # 16:00 – 19:59
    ("LateNY",   20, 24),  # 20:00 – 23:59
]


def _session_name(hour: int) -> str:
    for name, start, end in SESSIONS:
        if start <= hour < end:
            return name
    return "Unknown"


def _weekday_name(dt: datetime) -> str:
    names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    return names[dt.weekday()]


# ── classification ────────────────────────────────────────────────────────────

def classify_trades(
    trades: List[Dict[str, Any]],
    gmt_offset_hours: int = 2,
) -> Dict[str, List[Dict[str, Any]]]:
    """Group trades by session based on their entry_time."""
    tz_offset = timedelta(hours=gmt_offset_hours)
    grouped: Dict[str, List[Dict[str, Any]]] = {s[0]: [] for s in SESSIONS}
    grouped["Unknown"] = []

    for t in trades:
        entry_raw = t.get("entry_time")
        if not entry_raw:
            grouped["Unknown"].append(t)
            continue
        dt = _parse_dt(entry_raw)
        if dt is None:
            grouped["Unknown"].append(t)
            continue
        local_dt = dt + tz_offset
        session = _session_name(local_dt.hour)
        grouped[session].append(t)

    return grouped


def classify_by_weekday(
    trades: List[Dict[str, Any]],
    gmt_offset_hours: int = 2,
) -> Dict[str, List[Dict[str, Any]]]:
    """Group trades by weekday based on entry_time."""
    tz_offset = timedelta(hours=gmt_offset_hours)
    grouped: Dict[str, List] = {}

    for t in trades:
        entry_raw = t.get("entry_time")
        if not entry_raw:
            continue
        dt = _parse_dt(entry_raw)
        if dt is None:
            continue
        local_dt = dt + tz_offset
        day = _weekday_name(local_dt)
        grouped.setdefault(day, []).append(t)

    return grouped


# ── analysis ──────────────────────────────────────────────────────────────────

def _session_summary(
    name: str,
    session_trades: List[Dict[str, Any]],
    initial_balance: float,
) -> Dict[str, Any]:
    if not session_trades:
        return {
            "session": name,
            "trade_count": 0,
            "profit_factor": None,
            "win_rate_pct": None,
            "net_expectancy_R": None,
            "net_profit_usd": None,
            "avg_slippage_pts": None,
            "recommendation": "NO_DATA",
        }

    kpis = compute_kpis(session_trades, initial_balance)
    pf = kpis.get("profit_factor") or 0.0

    if pf >= 1.30 and (kpis.get("win_rate_pct") or 0) >= 45:
        rec = "KEEP"
    elif pf >= 1.0:
        rec = "REDUCE_RISK"
    else:
        rec = "BLOCK_ENTRIES"

    return {
        "session": name,
        "trade_count": len(session_trades),
        "profit_factor": kpis.get("profit_factor"),
        "win_rate_pct": kpis.get("win_rate_pct"),
        "net_expectancy_R": kpis.get("net_expectancy_R"),
        "net_profit_usd": kpis.get("net_profit_usd"),
        "avg_slippage_pts": kpis.get("avg_slippage_pts"),
        "recommendation": rec,
    }


def run_session_analysis(
    trades: List[Dict[str, Any]],
    gmt_offset_hours: int = 2,
    initial_balance: float = 10_000.0,
) -> Dict[str, Any]:
    """
    Compute per-session and per-weekday KPI breakdowns.
    """
    session_groups = classify_trades(trades, gmt_offset_hours)
    weekday_groups = classify_by_weekday(trades, gmt_offset_hours)

    session_results = [
        _session_summary(name, session_groups.get(name, []), initial_balance)
        for name, _, _ in SESSIONS
    ]

    weekday_order = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]
    weekday_results = []
    for day in weekday_order:
        day_trades = weekday_groups.get(day, [])
        summary = _session_summary(day, day_trades, initial_balance)
        weekday_results.append(summary)

    # Execution quality signals
    all_slippages = [t.get("slippage_pts", 0.0) for t in trades if "slippage_pts" in t]
    avg_slip = sum(all_slippages) / len(all_slippages) if all_slippages else 0.0

    spread_costs = [
        float(t.get("spread_pips", 0.0) or 0) * float(t.get("lots", 0.01) or 0.01) * 10.0
        for t in trades
    ]
    total_spread_cost = sum(spread_costs)
    gross_profit = sum(t.get("profit", 0.0) for t in trades if t.get("profit", 0.0) > 0)
    spread_cost_pct = (total_spread_cost / gross_profit * 100.0) if gross_profit > 0 else 0.0

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "total_trades": len(trades),
        "gmt_offset_hours": gmt_offset_hours,
        "sessions": session_results,
        "weekdays": weekday_results,
        "execution_quality": {
            "avg_slippage_pts": round(avg_slip, 2),
            "total_spread_cost_usd": round(total_spread_cost, 2),
            "spread_cost_pct_of_gross": round(spread_cost_pct, 1),
            "spread_flag": "HIGH" if spread_cost_pct > 20 else "OK",
        },
        "blocked_sessions": [s["session"] for s in session_results if s["recommendation"] == "BLOCK_ENTRIES"],
        "reduce_risk_sessions": [s["session"] for s in session_results if s["recommendation"] == "REDUCE_RISK"],
    }


# ── CLI ───────────────────────────────────────────────────────────────────────

def _print_table(rows: List[Dict[str, Any]], title: str) -> None:
    print(f"\n{'─'*70}")
    print(f"  {title}")
    print(f"{'─'*70}")
    print(f"{'Name':<12} {'Trades':>7} {'WinRate':>8} {'PF':>7} {'ExpR':>8} {'Rec':<15}")
    print(f"{'─'*70}")
    for r in rows:
        print(
            f"{r['session']:<12} "
            f"{(r['trade_count'] or 0):>7} "
            f"{str(r['win_rate_pct'] or '')+'%':>8} "
            f"{str(r['profit_factor'] or ''):>7} "
            f"{str(r['net_expectancy_R'] or ''):>8} "
            f"{r['recommendation']:<15}"
        )


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="MSPB session analysis")
    parser.add_argument("csv", nargs="?", default="ml_export_v2.csv")
    parser.add_argument("--gmt-offset", type=int, default=2)
    parser.add_argument("--out", default="tools/wfo_results/session_latest.json")
    parser.add_argument("--balance", type=float, default=10_000.0)
    args = parser.parse_args(argv)

    if not os.path.isfile(args.csv):
        print(f"[ERROR] CSV not found: {args.csv}", file=sys.stderr)
        return 1

    trades = load_trades_from_csv(args.csv)
    print(f"Loaded {len(trades)} trades (broker GMT+{args.gmt_offset}).")

    results = run_session_analysis(trades, args.gmt_offset, args.balance)

    _print_table(results["sessions"], "Session breakdown")
    _print_table(results["weekdays"], "Weekday breakdown")

    eq = results["execution_quality"]
    print(f"\nExecution quality:")
    print(f"  Avg slippage      : {eq['avg_slippage_pts']} pts")
    print(f"  Spread cost       : ${eq['total_spread_cost_usd']} ({eq['spread_cost_pct_of_gross']}% of gross profit)")
    print(f"  Spread flag       : {eq['spread_flag']}")

    if results["blocked_sessions"]:
        print(f"\n⚠  Recommend BLOCKING entries in: {', '.join(results['blocked_sessions'])}")
    if results["reduce_risk_sessions"]:
        print(f"⚠  Recommend REDUCING risk in: {', '.join(results['reduce_risk_sessions'])}")

    os.makedirs(os.path.dirname(args.out) if os.path.dirname(args.out) else ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(results, fh, indent=2, default=str)
    print(f"\nResults written to '{args.out}'.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
