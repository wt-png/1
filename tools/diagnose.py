"""
diagnose.py
===========
Unified one-command diagnostics runner for the MSPB Expert Advisor.

Executes all six diagnostic steps in sequence and prints a prioritised
action list at the end.  Designed to answer "wat gaat er mis?" without
guessing.

Steps executed
--------------
  1. Baseline KPIs        — overall equity / drawdown / Sharpe
  2. Symbol ranking       — which pairs lose money
  3. Session analysis     — which sessions (Asia/London/NY) lose money
  4. MAE/MFE analysis     — are entries structurally wrong-side?
  5. Walk-Forward (WFO)   — is the edge real out-of-sample?
  6. Monte Carlo          — is the edge robust or lucky?
  7. Stress test          — does the strategy survive adverse conditions?

Usage
-----
    python tools/diagnose.py [trades.csv] [options]

    --balance      Initial account balance (default 10 000)
    --gmt-offset   Broker GMT offset in hours (default 2)
    --mc-iter      Monte Carlo iterations (default 1000, use 2000 for production)
    --pip-value    USD per pip per lot (default 10.0)
    --skip-wfo     Skip WFO step (fast mode)
    --skip-mc      Skip Monte Carlo step (fast mode)
    --out-dir      Directory for JSON artefacts (default tools/diag_results)
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

from baseline_report import compute_kpis, load_trades_from_csv  # noqa: E402
from rank_symbols import rank_symbols                            # noqa: E402
from session_analysis import run_session_analysis               # noqa: E402
from analyse_mae_mfe import run_mae_mfe_analysis                # noqa: E402
from wfo_pipeline import run_wfo                                # noqa: E402
from monte_carlo_analysis import run_monte_carlo                # noqa: E402
from stress_test import run_stress_test                         # noqa: E402


# ── section printing ──────────────────────────────────────────────────────────

def _header(title: str) -> None:
    bar = "═" * 62
    print(f"\n{bar}")
    print(f"  {title}")
    print(bar)


def _ok(msg: str) -> None:
    print(f"  ✓  {msg}")


def _warn(msg: str) -> None:
    print(f"  ⚠  {msg}")


def _crit(msg: str) -> None:
    print(f"  ⛔  {msg}")


# ── action accumulator ────────────────────────────────────────────────────────

class _Actions:
    """Collects prioritised actions during the diagnostic run."""

    def __init__(self) -> None:
        self._items: List[Dict[str, str]] = []

    def add(self, priority: str, action: str, reason: str) -> None:
        """
        priority: "CRITICAL" | "HIGH" | "MEDIUM" | "LOW"
        """
        self._items.append({"priority": priority, "action": action, "reason": reason})

    def print_summary(self) -> None:
        order = ["CRITICAL", "HIGH", "MEDIUM", "LOW"]
        _header("Prioritised Action List")
        if not self._items:
            _ok("No critical issues found. Continue monitoring.")
            return
        for level in order:
            items = [i for i in self._items if i["priority"] == level]
            for item in items:
                tag = {"CRITICAL": "⛔", "HIGH": "⚠", "MEDIUM": "→", "LOW": "·"}[level]
                print(f"  {tag} [{level}] {item['action']}")
                print(f"         {item['reason']}")

    def as_list(self) -> List[Dict[str, str]]:
        return list(self._items)


# ── step runners ──────────────────────────────────────────────────────────────

def _step1_baseline(
    trades: List[Dict[str, Any]],
    balance: float,
    actions: _Actions,
) -> Dict[str, Any]:
    _header("Step 1 — Baseline KPIs")
    kpis = compute_kpis(trades, initial_balance=balance)

    pf  = kpis.get("profit_factor", 0.0) or 0.0
    wr  = kpis.get("win_rate_pct", 0.0) or 0.0
    dd  = kpis.get("max_equity_dd_pct", 0.0) or 0.0
    exp = kpis.get("net_expectancy_R", 0.0) or 0.0
    sh  = kpis.get("sharpe_ratio", 0.0) or 0.0

    for k, v in kpis.items():
        print(f"  {k:<26} {v}")

    if pf < 1.0:
        actions.add("CRITICAL", "EA is losing money overall",
                    f"Profit factor {pf:.3f} < 1.0 — every dimension must be investigated.")
    elif pf < 1.30:
        actions.add("HIGH", "Profit factor below target (1.30)",
                    f"Current PF {pf:.3f} — marginal edge, risk of ruin in live trading.")

    if dd > 20:
        actions.add("CRITICAL", "Max drawdown exceeds 20%",
                    f"Current DD {dd:.1f}% — reduce position size immediately.")
    elif dd > 15:
        actions.add("HIGH", "Max drawdown above 15% target",
                    f"Current DD {dd:.1f}% — enable InpEquityCB_Enable and InpDailyLoss_Enable.")

    if exp < 0:
        actions.add("CRITICAL", "Negative expectancy",
                    "Average trade costs more than it earns — entry/exit logic must be fixed.")

    if sh < 0.5:
        actions.add("MEDIUM", "Low Sharpe ratio",
                    f"Sharpe {sh:.3f} — returns are not consistent enough for live trading.")

    return kpis


def _step2_symbols(
    trades: List[Dict[str, Any]],
    balance: float,
    actions: _Actions,
) -> Dict[str, Any]:
    _header("Step 2 — Symbol Ranking")
    results = rank_symbols(trades, initial_balance=balance)

    rows = results.get("symbols", [])
    print(f"  {'Symbol':<14} {'N':>5} {'WR%':>7} {'PF':>7}  {'Rec'}")
    print(f"  {'─'*52}")
    for r in rows:
        if r.get("skipped"):
            print(f"  {r['symbol']:<14} {r['trades']:>5}  (insufficient data)")
            continue
        print(
            f"  {r['symbol']:<14} {r['trades']:>5} "
            f"{str(r['win_rate_pct'] or '')+'%':>7} "
            f"{str(r['profit_factor'] or ''):>7}  "
            f"{r['recommendation']}"
        )

    bl = results.get("blacklist", [])
    if bl:
        actions.add("HIGH", f"Remove losing symbols: {', '.join(bl)}",
                    "These symbols have PF < 1.0 and drag the overall performance down.")

    rr = results.get("reduce_risk", [])
    if rr:
        actions.add("MEDIUM", f"Reduce risk on marginal symbols: {', '.join(rr)}",
                    "PF 1.0–1.30; keep trading but halve position size until edge is proven.")

    return results


def _step3_sessions(
    trades: List[Dict[str, Any]],
    gmt_offset: int,
    balance: float,
    actions: _Actions,
) -> Dict[str, Any]:
    _header("Step 3 — Session Analysis")
    results = run_session_analysis(trades, gmt_offset_hours=gmt_offset,
                                   initial_balance=balance)

    print(f"  {'Session':<12} {'N':>5} {'WR%':>7} {'PF':>7}  {'Rec'}")
    print(f"  {'─'*50}")
    for s in results.get("sessions", []):
        print(
            f"  {s['session']:<12} {s.get('trade_count', 0):>5} "
            f"{str(s.get('win_rate_pct') or '')+'%':>7} "
            f"{str(s.get('profit_factor') or ''):>7}  "
            f"{s.get('recommendation', '')}"
        )

    blocked = results.get("blocked_sessions", [])
    if blocked:
        actions.add("HIGH", f"Block entries in sessions: {', '.join(blocked)}",
                    "Set InpUseSessions=true and disable these sessions in the EA config.")

    eq = results.get("execution_quality", {})
    if eq.get("spread_flag") == "HIGH":
        actions.add("MEDIUM", "High spread cost relative to gross profit",
                    f"Spread is eating {eq.get('spread_cost_pct_of_gross', 0):.0f}% of gross "
                    "profit — lower InpMaxSpread or switch to tighter-spread broker.")

    return results


def _step4_mae_mfe(
    trades: List[Dict[str, Any]],
    pip_value: float,
    actions: _Actions,
) -> Dict[str, Any]:
    _header("Step 4 — MAE / MFE Entry Quality")
    results = run_mae_mfe_analysis(trades, pip_value_usd=pip_value)

    print(f"  Avg MFE captured   : {results.get('avg_mfe_pips', 0):.2f} pips")
    print(f"  Avg MAE proxy      : {results.get('avg_mae_proxy_pips', 0):.2f} pips")
    print(f"  Avg capture ratio  : {results.get('avg_capture_ratio', 0):.1%}")
    print(f"  Wrong-side flag    : {'⚠ YES' if results.get('wrong_side_flag') else 'NO'}")
    print(f"  Runaway losers     : {results.get('runaway_loser_pct', 0):.1f}%")
    print(f"  Action             : {results.get('action', '')}")
    print(f"  {results.get('explanation', '')}")

    action_code = results.get("action", "MONITOR")
    if action_code == "STRENGTHEN_HTF_BIAS":
        actions.add("CRITICAL", "Entries are structurally wrong-side",
                    "Enable InpUseHTFBias=true, tighten InpEntryRequirePullbackOrigin, "
                    "raise InpEntryMinBodyATRFrac.")
    elif action_code == "WIDEN_TP_OR_TRAIL":
        actions.add("MEDIUM", "Trades exit too early — widen TP or enable trailing stop",
                    "Enable InpTP_Ladder_Enable=true or InpUseChandelierExit=true.")
    elif action_code == "TIGHTEN_ENTRY_FILTERS":
        actions.add("HIGH", "High stop-out rate — tighten entry filters",
                    "Raise InpMinADX / InpMinATR, add InpEntryUseWickFilter=true.")

    return results


def _step5_wfo(
    trades: List[Dict[str, Any]],
    balance: float,
    actions: _Actions,
) -> Dict[str, Any]:
    _header("Step 5 — Walk-Forward Optimisation")
    results = run_wfo(trades, n_windows=5, oos_ratio=0.30,
                      initial_balance=balance)

    oos_pf = results.get("oos_profit_factor", 0.0) or 0.0
    oos_wr = results.get("oos_win_rate_pct", 0.0) or 0.0
    verdict = results.get("verdict", "")

    print(f"  OOS profit factor  : {oos_pf:.3f}")
    print(f"  OOS win rate       : {oos_wr:.1f}%")
    print(f"  Verdict            : {verdict}")

    if verdict == "FAIL" or oos_pf < 1.0:
        actions.add("CRITICAL", "Strategy fails out-of-sample (WFO FAIL)",
                    "The edge does not generalise — do NOT trade live. Re-optimise with WFO.")
    elif oos_pf < 1.20:
        actions.add("HIGH", "Weak OOS profit factor",
                    f"OOS PF {oos_pf:.3f} < 1.20 — edge is fragile. Paper-trade only.")

    return results


def _step6_monte_carlo(
    trades: List[Dict[str, Any]],
    balance: float,
    iterations: int,
    actions: _Actions,
) -> Dict[str, Any]:
    _header(f"Step 6 — Monte Carlo ({iterations} iterations)")
    results = run_monte_carlo(trades, iterations=iterations,
                              initial_balance=balance, seed=42)

    verdict   = results.get("verdict", "")
    pf_pct    = results.get("real_pf_percentile", 50.0)
    mc_pf_p50 = (results.get("mc_pf_distribution") or {}).get("p50", 0.0)

    print(f"  Verdict            : {verdict}")
    print(f"  Real PF percentile : {pf_pct} % (vs reshuffled)")
    print(f"  MC PF p50          : {mc_pf_p50}")
    print(f"  {results.get('interpretation', '')}")

    if verdict == "OVERFIT_RISK":
        actions.add("HIGH", "Possible curve-fitting detected (Monte Carlo)",
                    "Real PF is in the top 5% of reshuffled sequences — "
                    "results may be luck. Use WFO to validate robustly.")
    elif verdict == "MARGINAL":
        actions.add("MEDIUM", "Marginal Monte Carlo result",
                    "Edge is present but thin — maintain strict risk limits.")

    return results


def _step7_stress(
    trades: List[Dict[str, Any]],
    balance: float,
    actions: _Actions,
) -> Dict[str, Any]:
    _header("Step 7 — Stress Test")
    scenarios = [(1.0, 0.0), (1.4, 2.0), (2.0, 5.0)]
    results = run_stress_test(trades, scenarios=scenarios,
                              initial_balance=balance)

    print(f"  {'Scenario':<12} {'Spread×':<9} {'Slip pts':<10} {'PF':<8} {'Gate':<8} {'Pass?'}")
    print("  " + "-" * 55)
    for s in results.get("scenarios", []):
        tick = "✓" if s["passed"] else "✗"
        print(
            f"  {s['label']:<12} {s['spread_mult']:<9.1f} {s['slippage_add_pts']:<10.1f}"
            f" {s['profit_factor']:<8.3f} {s['pf_gate']:<8.2f} {tick}"
        )
    print(f"\n  Overall verdict    : {results.get('verdict', '')}")

    if results.get("verdict") == "FAIL":
        actions.add("HIGH", "Strategy fails stress test",
                    "Cannot survive wider spreads or extra slippage — "
                    "tighten InpMaxSpread, reduce lot size, or improve entry quality.")

    return results


# ── main orchestration ────────────────────────────────────────────────────────

def run_diagnostics(
    trades: List[Dict[str, Any]],
    *,
    balance: float = 10_000.0,
    gmt_offset: int = 2,
    pip_value: float = 10.0,
    mc_iterations: int = 1000,
    skip_wfo: bool = False,
    skip_mc: bool = False,
) -> Dict[str, Any]:
    """Run the full diagnostic pipeline and return all results."""
    actions = _Actions()
    report: Dict[str, Any] = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "total_trades": len(trades),
    }

    report["baseline"]    = _step1_baseline(trades, balance, actions)
    report["symbols"]     = _step2_symbols(trades, balance, actions)
    report["sessions"]    = _step3_sessions(trades, gmt_offset, balance, actions)
    report["mae_mfe"]     = _step4_mae_mfe(trades, pip_value, actions)

    if not skip_wfo:
        report["wfo"] = _step5_wfo(trades, balance, actions)
    else:
        _header("Step 5 — Walk-Forward Optimisation")
        print("  (skipped — use --skip-wfo=false to enable)")

    if not skip_mc:
        report["monte_carlo"] = _step6_monte_carlo(trades, balance, mc_iterations, actions)
    else:
        _header("Step 6 — Monte Carlo")
        print("  (skipped — use --skip-mc=false to enable)")

    report["stress"]      = _step7_stress(trades, balance, actions)
    report["actions"]     = actions.as_list()

    actions.print_summary()

    return report


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="MSPB EA — unified diagnostics runner"
    )
    parser.add_argument("csv", nargs="?", default="ml_export_v2.csv",
                        help="Trade export CSV (default: ml_export_v2.csv)")
    parser.add_argument("--balance",    type=float, default=10_000.0)
    parser.add_argument("--gmt-offset", type=int,   default=2)
    parser.add_argument("--mc-iter",    type=int,   default=1000)
    parser.add_argument("--pip-value",  type=float, default=10.0)
    parser.add_argument("--skip-wfo",   action="store_true")
    parser.add_argument("--skip-mc",    action="store_true")
    parser.add_argument("--out-dir",    default="tools/diag_results")
    args = parser.parse_args(argv)

    print(f"\nMSPB Diagnostics Runner — {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}")
    print(f"CSV: {args.csv}  |  Balance: {args.balance}  |  GMT+{args.gmt_offset}")

    if not os.path.isfile(args.csv):
        print(f"\n[ERROR] CSV not found: {args.csv}", file=sys.stderr)
        print("  → Run the EA with InpEnableMLExport=true, then export History as CSV.",
              file=sys.stderr)
        return 1

    trades = load_trades_from_csv(args.csv)
    print(f"Loaded {len(trades)} trades.\n")

    if len(trades) < 10:
        print("[WARN] Fewer than 10 trades — results will not be statistically meaningful.",
              file=sys.stderr)

    results = run_diagnostics(
        trades,
        balance=args.balance,
        gmt_offset=args.gmt_offset,
        pip_value=args.pip_value,
        mc_iterations=args.mc_iter,
        skip_wfo=args.skip_wfo,
        skip_mc=args.skip_mc,
    )

    os.makedirs(args.out_dir, exist_ok=True)
    out_path = os.path.join(args.out_dir, "diag_latest.json")
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(results, fh, indent=2, default=str)
    print(f"\nFull report written to '{out_path}'.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
