#!/usr/bin/env python3
"""
MSPB EA — Walk-Forward Optimisation Pipeline
=============================================
Reads the ML export CSV and evaluates how stable the EA's performance
is across rolling time windows (in-sample fit + out-of-sample score).

This does NOT run MetaTrader directly.  It uses the closed-trade data
already exported by the EA to do a *statistical* walk-forward test:
  - Splits the trade history into IS/OOS windows
  - For each window, computes Sharpe, Calmar, win-rate, profit factor
  - Flags parameter instability when OOS significantly under-performs IS

Usage:
    python tools/wfo_pipeline.py --csv path/to/ml_export_v2.csv [--windows 6] [--oos-ratio 0.3]
"""

# Constants
TRADING_DAYS_PER_YEAR = 252
WEEKS_PER_YEAR = 52
import argparse
import csv
import math
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Dict, Tuple, Optional


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def load_trades(path: str) -> List[Dict[str, str]]:
    trades = []
    with open(path, newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh, delimiter=";")
        for r in reader:
            ev = r.get("event", "")
            if ev in ("EXIT", "ENTRY"):
                trades.append(r)
    return trades


def parse_pnl(r: Dict[str, str]) -> Optional[float]:
    for col in ("pnl_gross", "pnl", "profit"):
        v = r.get(col, "")
        try:
            return float(v)
        except (ValueError, TypeError):
            pass
    return None


def parse_time(r: Dict[str, str]) -> Optional[datetime]:
    for col in ("close_time", "open_time", "time", "timestamp"):
        v = r.get(col, "")
        if not v:
            continue
        for fmt in ("%Y.%m.%d %H:%M:%S", "%Y-%m-%d %H:%M:%S", "%Y/%m/%d %H:%M:%S"):
            try:
                return datetime.strptime(v, fmt).replace(tzinfo=timezone.utc)
            except ValueError:
                pass
    return None


# ---------------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------------

def sharpe(returns: List[float], annualise: bool = True) -> float:
    if len(returns) < 2:
        return 0.0
    n = len(returns)
    mean = sum(returns) / n
    var  = sum((x - mean) ** 2 for x in returns) / (n - 1)
    std  = math.sqrt(var) if var > 0 else 0.0
    if std == 0:
        return 0.0
    sr = mean / std
    return sr * math.sqrt(TRADING_DAYS_PER_YEAR) if annualise else sr  # raw Sharpe ratio (mean/std)


def max_drawdown(equity_curve: List[float]) -> float:
    peak = equity_curve[0]
    mdd  = 0.0
    for v in equity_curve:
        if v > peak:
            peak = v
        dd = (peak - v) / peak if peak > 0 else 0.0
        mdd = max(mdd, dd)
    return mdd


def calmar(total_return: float, mdd: float, years: float = 1.0) -> float:
    if mdd <= 0 or years <= 0:
        return 0.0
    annual_ret = total_return / years
    return annual_ret / mdd


def profit_factor(pnls: List[float]) -> float:
    gross_win  = sum(p for p in pnls if p > 0)
    gross_loss = sum(abs(p) for p in pnls if p < 0)
    return (gross_win / gross_loss) if gross_loss > 0 else float("inf")


def win_rate(pnls: List[float]) -> float:
    if not pnls:
        return 0.0
    return sum(1 for p in pnls if p > 0) / len(pnls)


def score_window(pnls: List[float]) -> Dict[str, float]:
    if not pnls:
        return {"n": 0, "sharpe": 0, "calmar": 0, "pf": 0, "wr": 0, "net": 0}
    equity = [0.0]
    for p in pnls:
        equity.append(equity[-1] + p)
    net = equity[-1]
    mdd = max_drawdown(equity)
    years = max(len(pnls) / TRADING_DAYS_PER_YEAR, 1 / WEEKS_PER_YEAR)  # approximate
    returns = [pnls[i] / max(abs(equity[i]), 1.0) for i in range(len(pnls))]
    return {
        "n":      len(pnls),
        "sharpe": round(sharpe(returns), 3),
        "calmar": round(calmar(net / max(equity[0] or 1, 1), mdd, years), 3),
        "pf":     round(profit_factor(pnls), 3),
        "wr":     round(win_rate(pnls) * 100, 1),
        "net":    round(net, 2),
    }


# ---------------------------------------------------------------------------
# Walk-forward split
# ---------------------------------------------------------------------------

def walk_forward(
    pnls_times: List[Tuple[datetime, float]],
    n_windows: int,
    oos_ratio: float,
) -> List[Dict]:
    if len(pnls_times) < 10:
        return []

    pnls_times_sorted = sorted(pnls_times, key=lambda t: t[0])
    n = len(pnls_times_sorted)
    window_size = n // n_windows
    if window_size < 5:
        print(f"Warning: too few trades ({n}) for {n_windows} windows; reducing to 3.")
        n_windows = 3
        window_size = n // n_windows

    results = []
    for i in range(n_windows):
        start = i * window_size
        end   = start + window_size if i < n_windows - 1 else n
        chunk = pnls_times_sorted[start:end]
        oos_size = max(1, int(len(chunk) * oos_ratio))
        is_chunk  = chunk[:len(chunk) - oos_size]
        oos_chunk = chunk[len(chunk) - oos_size:]

        is_pnl  = [p for _, p in is_chunk]
        oos_pnl = [p for _, p in oos_chunk]

        results.append({
            "window": i + 1,
            "is_start":  is_chunk[0][0].strftime("%Y-%m-%d")  if is_chunk  else "",
            "is_end":    is_chunk[-1][0].strftime("%Y-%m-%d") if is_chunk  else "",
            "oos_start": oos_chunk[0][0].strftime("%Y-%m-%d") if oos_chunk else "",
            "oos_end":   oos_chunk[-1][0].strftime("%Y-%m-%d") if oos_chunk else "",
            "is":        score_window(is_pnl),
            "oos":       score_window(oos_pnl),
        })
    return results


def print_results(results: List[Dict]) -> None:
    hdr = f"{'Win':>3}  {'IS n':>5} {'IS SR':>7} {'IS PF':>7} {'IS WR':>6}  "
    hdr += f"{'OOS n':>5} {'OOS SR':>7} {'OOS PF':>7} {'OOS WR':>6}  {'Stable':>7}"
    print("\n=== Walk-Forward Results ===")
    print(hdr)
    print("-" * len(hdr))
    for r in results:
        is_  = r["is"]
        oos_ = r["oos"]
        # "stable" heuristic: OOS Sharpe >= 50% of IS Sharpe and OOS PF >= 1.0
        sr_ratio = (oos_["sharpe"] / is_["sharpe"]) if is_["sharpe"] > 0.1 else 1.0
        stable = "YES" if (sr_ratio >= 0.5 and oos_["pf"] >= 1.0) else "NO"
        print(
            f" {r['window']:>3}  "
            f"{is_['n']:>5} {is_['sharpe']:>7.2f} {is_['pf']:>7.2f} {is_['wr']:>5.1f}%  "
            f"{oos_['n']:>5} {oos_['sharpe']:>7.2f} {oos_['pf']:>7.2f} {oos_['wr']:>5.1f}%  "
            f"{stable:>7}"
        )
    stable_count = sum(1 for r in results if
                       ((r["oos"]["sharpe"] / r["is"]["sharpe"]) if r["is"]["sharpe"] > 0.1 else 1.0) >= 0.5
                       and r["oos"]["pf"] >= 1.0)
    print(f"\nStable windows: {stable_count}/{len(results)}")
    if stable_count < len(results) * 0.6:
        print("⚠  WARNING: Less than 60% of OOS windows are stable — possible overfit or regime change.")
    else:
        print("✓  Strategy appears robust across walk-forward windows.")


def main() -> None:
    parser = argparse.ArgumentParser(description="MSPB Walk-Forward Optimisation Pipeline")
    parser.add_argument("--csv",       required=True,      help="Path to ml_export_v2.csv")
    parser.add_argument("--windows",   type=int, default=6, help="Number of WF windows (default 6)")
    parser.add_argument("--oos-ratio", type=float, default=0.3, help="OOS fraction per window (default 0.3)")
    parser.add_argument("--output",    default="",         help="Optional JSON output file for results")
    args = parser.parse_args()
    if not (0.05 <= args.oos_ratio <= 0.95):
        parser.error("--oos-ratio must be between 0.05 and 0.95")
    rows = load_trades(args.csv)
    print(f"  {len(rows)} trade rows")

    pnls_times = []
    for r in rows:
        pnl = parse_pnl(r)
        t   = parse_time(r)
        if pnl is not None and t is not None:
            pnls_times.append((t, pnl))

    print(f"  {len(pnls_times)} rows with valid P&L + timestamp")
    if len(pnls_times) < 10:
        print("Not enough data for walk-forward analysis. Need at least 10 trades.")
        sys.exit(0)

    overall = score_window([p for _, p in pnls_times])
    print(f"\n=== Overall Stats (all {overall['n']} trades) ===")
    print(f"  Net P&L:       {overall['net']:.2f}")
    print(f"  Sharpe:        {overall['sharpe']:.3f}")
    print(f"  Profit Factor: {overall['pf']:.3f}")
    print(f"  Win Rate:      {overall['wr']:.1f}%")

    results = walk_forward(pnls_times, args.windows, args.oos_ratio)
    if results:
        print_results(results)
    else:
        print("Not enough data for walk-forward split.")

    # Write JSON output if requested (used by E12 CI cron)
    if args.output:
        import json
        from datetime import timezone as _tz
        wfo_json = {
            "generated_at": datetime.now(_tz.utc).isoformat(timespec="seconds"),
            "overall": overall,
            "windows": [
                {
                    "window": r["window"],
                    "is_sharpe":  r["is"]["sharpe"],
                    "oos_sharpe": r["oos"]["sharpe"],
                    "is_pf":      r["is"]["pf"],
                    "oos_pf":     r["oos"]["pf"],
                    "stable":     r["is"]["sharpe"] > 0 and r["oos"]["sharpe"] > 0,
                }
                for r in results
            ] if results else [],
        }
        Path(args.output).write_text(json.dumps(wfo_json, indent=2), encoding="utf-8")
        print(f"\nWFO results written to {args.output}")


if __name__ == "__main__":
    main()
