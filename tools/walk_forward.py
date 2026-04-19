#!/usr/bin/env python3
"""
walk_forward.py — Walk-Forward IS/OOS validation for MSPB EA backtest results.

Usage:
    python tools/walk_forward.py --csv <deals_export.csv> [options]

The CSV is expected to have columns: time, symbol, direction, entry, sl, tp,
lots, profit, setup (as exported by the EA's ML export, InpEnableMLExport=true).

Outputs per-window IS/OOS Sharpe, Calmar, profit factor and a summary table.
"""
import argparse
import csv
import math
import sys
from dataclasses import dataclass, field
from typing import List, Optional, Tuple
from datetime import datetime, timezone


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class Deal:
    time: datetime
    symbol: str
    direction: str          # BUY / SELL
    entry: float
    sl: float
    profit: float
    lots: float
    setup: str = ""


@dataclass
class WindowResult:
    window_id: int
    is_start: datetime
    is_end: datetime
    oos_start: datetime
    oos_end: datetime
    is_trades: int
    oos_trades: int
    is_sharpe: float
    oos_sharpe: float
    is_calmar: float
    oos_calmar: float
    is_pf: float            # profit factor
    oos_pf: float
    oos_efficiency: float   # oos_sharpe / is_sharpe  (robustness metric)


# ---------------------------------------------------------------------------
# Statistics helpers
# ---------------------------------------------------------------------------

def _sharpe(returns: List[float], annualise: float = 252.0) -> float:
    """Annualised Sharpe ratio (daily returns assumed)."""
    n = len(returns)
    if n < 2:
        return 0.0
    mean = sum(returns) / n
    var = sum((r - mean) ** 2 for r in returns) / (n - 1)
    if var < 1e-12:
        return 0.0
    return (mean / math.sqrt(var)) * math.sqrt(annualise)


def _calmar(profits: List[float]) -> float:
    """Calmar ratio = total_profit / max_drawdown (absolute)."""
    if not profits:
        return 0.0
    total = sum(profits)
    equity = 0.0
    peak = 0.0
    max_dd = 0.0
    for p in profits:
        equity += p
        if equity > peak:
            peak = equity
        dd = peak - equity
        if dd > max_dd:
            max_dd = dd
    if max_dd < 1e-8:
        return 0.0 if total <= 0.0 else float("inf")
    if total <= 0.0:
        return 0.0
    return total / max_dd


def _profit_factor(profits: List[float]) -> float:
    gross_win = sum(p for p in profits if p > 0.0)
    gross_loss = abs(sum(p for p in profits if p < 0.0))
    if gross_loss < 1e-8:
        return float("inf") if gross_win > 0.0 else 1.0
    return gross_win / gross_loss


def _deal_returns(deals: List[Deal]) -> List[float]:
    """Return per-trade normalised return (profit / (lots * 100_000)) as proxy."""
    out = []
    for d in deals:
        if d.lots > 0.0:
            out.append(d.profit / (d.lots * 100_000.0))
    return out


def _analyse(deals: List[Deal]) -> Tuple[float, float, float]:
    """Return (sharpe, calmar, profit_factor)."""
    profits = [d.profit for d in deals]
    returns = _deal_returns(deals)
    return _sharpe(returns), _calmar(profits), _profit_factor(profits)


# ---------------------------------------------------------------------------
# Walk-forward engine
# ---------------------------------------------------------------------------

def run_walk_forward(
    deals: List[Deal],
    is_fraction: float = 0.70,
    n_windows: int = 5,
    anchored: bool = False,
) -> List[WindowResult]:
    """
    Split the deal history into n_windows walk-forward folds.

    anchored=False  →  rolling window (IS window shifts forward each fold)
    anchored=True   →  expanding IS (IS always starts from first deal)
    """
    if not deals:
        return []

    deals = sorted(deals, key=lambda d: d.time)
    first = deals[0].time.timestamp()
    last  = deals[-1].time.timestamp()
    total_span = last - first
    if total_span <= 0.0:
        return []

    window_span = total_span / n_windows
    results: List[WindowResult] = []

    for w in range(n_windows):
        win_start_ts = first + w * window_span
        win_end_ts   = win_start_ts + window_span

        is_end_ts  = win_start_ts + window_span * is_fraction
        oos_start_ts = is_end_ts

        if anchored:
            is_start_ts = first
        else:
            is_start_ts = win_start_ts

        is_deals  = [d for d in deals if is_start_ts  <= d.time.timestamp() < is_end_ts]
        oos_deals = [d for d in deals if oos_start_ts <= d.time.timestamp() < win_end_ts]

        if not is_deals and not oos_deals:
            continue

        is_sharpe,  is_calmar,  is_pf  = _analyse(is_deals)
        oos_sharpe, oos_calmar, oos_pf = _analyse(oos_deals)

        eff = (oos_sharpe / is_sharpe) if abs(is_sharpe) > 1e-6 else 0.0

        def _ts(ts: float) -> datetime:
            return datetime.fromtimestamp(ts, tz=timezone.utc)

        results.append(WindowResult(
            window_id=w + 1,
            is_start=_ts(is_start_ts),
            is_end=_ts(is_end_ts),
            oos_start=_ts(oos_start_ts),
            oos_end=_ts(win_end_ts),
            is_trades=len(is_deals),
            oos_trades=len(oos_deals),
            is_sharpe=is_sharpe,
            oos_sharpe=oos_sharpe,
            is_calmar=is_calmar,
            oos_calmar=oos_calmar,
            is_pf=is_pf,
            oos_pf=oos_pf,
            oos_efficiency=eff,
        ))

    return results


# ---------------------------------------------------------------------------
# CSV loading
# ---------------------------------------------------------------------------

REQUIRED_COLS = {"time", "profit", "lots"}


def _parse_dt(s: str) -> Optional[datetime]:
    for fmt in ("%Y.%m.%d %H:%M:%S", "%Y-%m-%d %H:%M:%S", "%Y.%m.%d %H:%M",
                "%Y-%m-%d %H:%M", "%Y.%m.%d", "%Y-%m-%d"):
        try:
            return datetime.strptime(s.strip(), fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def load_csv(path: str) -> List[Deal]:
    deals: List[Deal] = []
    with open(path, newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        if reader.fieldnames is None:
            raise ValueError("CSV has no header row")
        lower_fields = {f.strip().lower(): f for f in reader.fieldnames}
        missing = REQUIRED_COLS - set(lower_fields.keys())
        if missing:
            raise ValueError(f"CSV missing required columns: {missing}")

        for row in reader:
            # Normalise keys to lowercase
            r = {k.strip().lower(): v.strip() for k, v in row.items() if v is not None}
            t = _parse_dt(r.get("time", ""))
            if t is None:
                continue
            # Skip non-exit rows (type column may say "exit")
            ev = r.get("event", r.get("type", "exit")).lower()
            if "entry" in ev and "exit" not in ev:
                continue
            try:
                profit = float(r.get("profit", "0") or "0")
                lots   = float(r.get("lots", "0.01") or "0.01")
            except ValueError:
                continue
            deals.append(Deal(
                time=t,
                symbol=r.get("symbol", ""),
                direction=r.get("direction", r.get("dir", "")),
                entry=float(r.get("entry", "0") or "0"),
                sl=float(r.get("sl", "0") or "0"),
                profit=profit,
                lots=lots,
                setup=r.get("setup", ""),
            ))
    return deals


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def _fmt(v: float, width: int = 7) -> str:
    if v == float("inf"):
        return f"{'∞':>{width}}"
    return f"{v:{width}.3f}"


def print_report(results: List[WindowResult], warn_threshold: float = 0.5) -> None:
    if not results:
        print("No walk-forward windows to report.")
        return

    hdr = (
        f"{'Win':>4}  {'IS_trades':>9}  {'OOS_trades':>10}  "
        f"{'IS_Sharpe':>9}  {'OOS_Sharpe':>10}  "
        f"{'IS_Calmar':>9}  {'OOS_Calmar':>10}  "
        f"{'IS_PF':>6}  {'OOS_PF':>6}  {'OOS/IS':>7}"
    )
    print("=" * len(hdr))
    print("Walk-Forward IS/OOS Analysis")
    print("=" * len(hdr))
    print(hdr)
    print("-" * len(hdr))

    warnings = []
    for r in results:
        flag = ""
        if r.is_trades > 0 and r.oos_trades > 0:
            if r.oos_efficiency < warn_threshold and r.is_sharpe > 0.0:
                flag = " ⚠"
                warnings.append(
                    f"  Window {r.window_id}: OOS efficiency {r.oos_efficiency:.2f} < {warn_threshold} "
                    f"(IS_Sharpe={r.is_sharpe:.3f}, OOS_Sharpe={r.oos_sharpe:.3f})"
                )
        print(
            f"{r.window_id:>4}  {r.is_trades:>9}  {r.oos_trades:>10}  "
            f"{_fmt(r.is_sharpe)}  {_fmt(r.oos_sharpe)}  "
            f"{_fmt(r.is_calmar)}  {_fmt(r.oos_calmar)}  "
            f"{_fmt(r.is_pf, 6)}  {_fmt(r.oos_pf, 6)}  {_fmt(r.oos_efficiency)}"
            f"{flag}"
        )

    print("-" * len(hdr))

    # Aggregate
    valid = [r for r in results if r.is_trades > 0 and r.oos_trades > 0]
    if valid:
        avg_oos_eff = sum(r.oos_efficiency for r in valid) / len(valid)
        avg_oos_sh  = sum(r.oos_sharpe for r in valid) / len(valid)
        avg_oos_pf  = sum(r.oos_pf for r in valid if r.oos_pf != float("inf")) / max(1, sum(1 for r in valid if r.oos_pf != float("inf")))
        print(f"{'AVG':>4}  {'':>9}  {'':>10}  {'':>9}  {_fmt(avg_oos_sh)}  "
              f"{'':>9}  {'':>10}  {'':>6}  {_fmt(avg_oos_pf, 6)}  {_fmt(avg_oos_eff)}")

    if warnings:
        print("\nWarnings:")
        for w in warnings:
            print(w)
    print("=" * len(hdr))


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", required=True, help="Path to the deals CSV export")
    parser.add_argument("--is-fraction", type=float, default=0.70,
                        help="Fraction of each window used as IS (default: 0.70)")
    parser.add_argument("--windows", type=int, default=5,
                        help="Number of walk-forward windows (default: 5)")
    parser.add_argument("--anchored", action="store_true",
                        help="Use anchored (expanding IS) instead of rolling walk-forward")
    parser.add_argument("--warn", type=float, default=0.50,
                        help="OOS/IS efficiency threshold below which a warning is shown (default: 0.50)")
    args = parser.parse_args(argv)

    try:
        deals = load_csv(args.csv)
    except (OSError, ValueError) as exc:
        print(f"ERROR loading CSV: {exc}", file=sys.stderr)
        return 1

    if not deals:
        print("No exit deals found in CSV.", file=sys.stderr)
        return 1

    print(f"Loaded {len(deals)} exit deal(s) from '{args.csv}'")
    results = run_walk_forward(
        deals,
        is_fraction=args.is_fraction,
        n_windows=args.windows,
        anchored=args.anchored,
    )
    print_report(results, warn_threshold=args.warn)
    return 0


if __name__ == "__main__":
    sys.exit(main())
