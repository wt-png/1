"""
stress_test.py
==============
Out-of-sample stress testing for the MSPB EA.

Replays the closed-trade history under worsened market conditions to check
whether the strategy survives realistic adverse scenarios.

Stress dimensions:
  - Spread multiplier   : multiply each trade's spread cost
  - Slippage add (pts)  : add fixed slippage to every losing trade's entry

Gates (from docs/KPI_TARGETS.md Section 4):
  Normal (1.0×, 0 pts)  → PF ≥ 1.30
  Moderate (1.4×, 2 pts) → PF ≥ 1.10
  High (2.0×, 5 pts)     → PF ≥ 0.90 (no blow-up)

Usage
-----
    python tools/stress_test.py [trades.csv] [options]

    --multipliers   Spread multipliers to test, e.g. 1.0 1.4 2.0
    --slippage      Slippage additions (points) matching --multipliers
    --out           Output JSON path
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

_DIR = os.path.dirname(__file__)
sys.path.insert(0, _DIR)
from baseline_report import compute_kpis, load_trades_from_csv  # noqa: E402


# ── stress application ────────────────────────────────────────────────────────

# Gates from KPI_TARGETS.md Section 4
_GATES: Dict[str, float] = {
    "normal":   1.30,
    "moderate": 1.10,
    "high":     0.90,
}

_SCENARIO_NAMES = ["normal", "moderate", "high"]


def _label(mult: float) -> str:
    if mult <= 1.05:
        return "normal"
    if mult <= 1.6:
        return "moderate"
    return "high"


def apply_stress(
    trades: List[Dict[str, Any]],
    spread_mult: float,
    slip_add_pts: float,
    pip_value_usd: float = 10.0,
    point_size: float = 0.0001,
) -> List[Dict[str, Any]]:
    """
    Return a new list of trades with stressed P&L values.

    spread_mult   : multiply spread_pips cost by this factor
    slip_add_pts  : add extra slippage (in points) to every losing-entry trade
    pip_value_usd : USD value per pip per lot (approximate; 10 for 6-decimal pairs)
    point_size    : size of 1 point in price terms (0.0001 for most FX)
    """
    stressed: List[Dict[str, Any]] = []
    for t in trades:
        copy = dict(t)
        profit = float(t.get("profit", 0.0))
        lots = float(t.get("lots", 0.01) or 0.01)
        spread_pips = float(t.get("spread_pips", 0.0) or 0.0)

        # Extra spread cost: (spread_mult - 1) * spread_pips * lots * pip_value_usd
        extra_spread = (spread_mult - 1.0) * spread_pips * lots * pip_value_usd
        copy["profit"] = profit - extra_spread

        # Slippage: penalises entries (makes losing trades worse; point in price → USD)
        if slip_add_pts > 0 and profit < 0:
            slip_cost = slip_add_pts * point_size * lots * pip_value_usd * 10.0
            copy["profit"] = copy["profit"] - slip_cost

        stressed.append(copy)
    return stressed


def run_stress_test(
    trades: List[Dict[str, Any]],
    scenarios: List[Tuple[float, float]],
    initial_balance: float = 10_000.0,
) -> Dict[str, Any]:
    """
    Run all stress scenarios and return a results dict with pass/fail per gate.
    """
    real_kpis = compute_kpis(trades, initial_balance)
    scenario_results: List[Dict[str, Any]] = []
    all_pass = True

    for spread_mult, slip_pts in scenarios:
        label = _label(spread_mult)
        gate = _GATES.get(label, 0.90)

        stressed_trades = apply_stress(trades, spread_mult, slip_pts)
        kpis = compute_kpis(stressed_trades, initial_balance)

        pf = kpis.get("profit_factor", 0.0) or 0.0
        passed = pf >= gate

        if not passed:
            all_pass = False

        scenario_results.append({
            "label": label,
            "spread_mult": spread_mult,
            "slippage_add_pts": slip_pts,
            "profit_factor": round(pf, 3),
            "net_expectancy_R": kpis.get("net_expectancy_R"),
            "max_equity_dd_pct": kpis.get("max_equity_dd_pct"),
            "net_profit_usd": kpis.get("net_profit_usd"),
            "win_rate_pct": kpis.get("win_rate_pct"),
            "pf_gate": gate,
            "passed": passed,
        })

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "total_trades": len(trades),
        "real_kpis": real_kpis,
        "scenarios": scenario_results,
        "all_passed": all_pass,
        "verdict": "PASS" if all_pass else "FAIL",
    }


# ── CLI ───────────────────────────────────────────────────────────────────────

def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="MSPB stress test")
    parser.add_argument("csv", nargs="?", default="ml_export_v2.csv")
    parser.add_argument("--multipliers", nargs="+", type=float, default=[1.0, 1.4, 2.0])
    parser.add_argument("--slippage", nargs="+", type=float, default=[0.0, 2.0, 5.0])
    parser.add_argument("--out", default="tools/stress_results/stress_latest.json")
    parser.add_argument("--balance", type=float, default=10_000.0)
    args = parser.parse_args(argv)

    if len(args.multipliers) != len(args.slippage):
        print("[ERROR] --multipliers and --slippage must have the same number of values.", file=sys.stderr)
        return 1

    if not os.path.isfile(args.csv):
        print(f"[ERROR] CSV not found: {args.csv}", file=sys.stderr)
        return 1

    trades = load_trades_from_csv(args.csv)
    scenarios = list(zip(args.multipliers, args.slippage))

    print(f"Loaded {len(trades)} trades. Running {len(scenarios)} stress scenarios…\n")
    results = run_stress_test(trades, scenarios, args.balance)

    print(f"{'Scenario':<12} {'Spread×':<9} {'Slip pts':<10} {'PF':<8} {'PF gate':<10} {'Pass?'}")
    print("-" * 60)
    for s in results["scenarios"]:
        tick = "✓" if s["passed"] else "✗"
        print(f"{s['label']:<12} {s['spread_mult']:<9.1f} {s['slippage_add_pts']:<10.1f} "
              f"{s['profit_factor']:<8.3f} {s['pf_gate']:<10.2f} {tick}")

    print(f"\nOverall verdict: {results['verdict']}")

    os.makedirs(os.path.dirname(args.out) if os.path.dirname(args.out) else ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(results, fh, indent=2, default=str)
    print(f"Results written to '{args.out}'.")
    return 0 if results["all_passed"] else 2


if __name__ == "__main__":
    sys.exit(main())
