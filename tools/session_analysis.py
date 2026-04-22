"""
session_analysis.py — Trade segmentation by session & volatility regime.

Usage:
    python tools/session_analysis.py --file trades.csv [--output report.json]

Expected CSV columns (flexible):
    - time / open_time / datetime  : trade open time (UTC)
    - pnl / profit                 : trade P&L
    - atr / atr_pips               : ATR at entry (optional, for vol regime)
    - symbol                       : instrument (optional)
"""

import argparse
import json
import sys
from pathlib import Path

import pandas as pd


# ── Session definitions (UTC hours) ─────────────────────────────────────────
SESSIONS = {
    "Asia":   (0,  7),
    "London": (7,  12),
    "NY":     (12, 17),
    "Late":   (17, 24),
}

KPI_PF_MIN = 1.3
KPI_DD_MAX = 12.0


def _resolve_column(df: pd.DataFrame, candidates: list[str]) -> str | None:
    for c in candidates:
        if c in df.columns:
            return c
    # case-insensitive fallback
    lower = {col.lower(): col for col in df.columns}
    for c in candidates:
        if c.lower() in lower:
            return lower[c.lower()]
    return None


def load_trades(path: str) -> pd.DataFrame:
    df = pd.read_csv(path)
    df.columns = [c.strip() for c in df.columns]

    time_col = _resolve_column(df, ["time", "open_time", "datetime", "Date", "date"])
    pnl_col  = _resolve_column(df, ["pnl", "profit", "Profit", "PnL", "pl"])
    atr_col  = _resolve_column(df, ["atr", "atr_pips", "ATR"])

    if time_col is None:
        raise ValueError("No time column found. Expected one of: time, open_time, datetime, Date.")
    if pnl_col is None:
        raise ValueError("No P&L column found. Expected one of: pnl, profit, Profit, PnL.")

    df = df.rename(columns={time_col: "time", pnl_col: "pnl"})
    if atr_col:
        df = df.rename(columns={atr_col: "atr"})

    df["time"] = pd.to_datetime(df["time"], utc=True, errors="coerce")
    df = df.dropna(subset=["time", "pnl"])
    df["pnl"] = pd.to_numeric(df["pnl"], errors="coerce")
    df = df.dropna(subset=["pnl"])
    df["hour_utc"] = df["time"].dt.hour
    return df


def assign_session(hour: int) -> str:
    for name, (start, end) in SESSIONS.items():
        if start <= hour < end:
            return name
    return "Late"


def assign_vol_regime(df: pd.DataFrame) -> pd.DataFrame:
    if "atr" not in df.columns:
        df["vol_regime"] = "N/A"
        return df
    atr = pd.to_numeric(df["atr"], errors="coerce")
    lo = atr.quantile(0.33)
    hi = atr.quantile(0.67)
    df["vol_regime"] = pd.cut(atr, bins=[-float("inf"), lo, hi, float("inf")],
                               labels=["Low", "Mid", "High"])
    return df


def compute_segment_stats(group: pd.DataFrame) -> dict:
    pnl = group["pnl"]
    wins  = pnl[pnl > 0]
    losses = pnl[pnl < 0]
    gross_profit = wins.sum() if len(wins) else 0.0
    gross_loss   = abs(losses.sum()) if len(losses) else 0.0
    pf = (gross_profit / gross_loss) if gross_loss > 0 else float("inf")
    avg_r = pnl.mean()
    win_rate = len(wins) / len(pnl) * 100 if len(pnl) else 0.0
    return {
        "trades":      int(len(pnl)),
        "wins":        int(len(wins)),
        "losses":      int(len(losses)),
        "win_rate_pct": round(win_rate, 1),
        "net_pnl":     round(float(pnl.sum()), 2),
        "profit_factor": round(pf, 3) if pf != float("inf") else None,
        "avg_r":       round(float(avg_r), 4),
    }


def top_loss_contributors(df: pd.DataFrame, n: int = 5) -> list[dict]:
    losses = df[df["pnl"] < 0].copy()
    losses = losses.sort_values("pnl").head(n)
    result = []
    for _, row in losses.iterrows():
        entry = {
            "time":   str(row["time"]),
            "pnl":    round(float(row["pnl"]), 2),
            "session": row.get("session", ""),
        }
        if "symbol" in df.columns:
            entry["symbol"] = str(row.get("symbol", ""))
        result.append(entry)
    return result


def run_analysis(path: str) -> dict:
    df = load_trades(path)
    df["session"] = df["hour_utc"].apply(assign_session)
    df = assign_vol_regime(df)

    report: dict = {
        "file": path,
        "total_trades": len(df),
        "overall": compute_segment_stats(df),
        "by_session": {},
        "by_vol_regime": {},
        "top5_loss_contributors": top_loss_contributors(df),
    }

    for session in SESSIONS:
        grp = df[df["session"] == session]
        report["by_session"][session] = compute_segment_stats(grp) if len(grp) else {}

    if "atr" in df.columns:
        for regime in ["Low", "Mid", "High"]:
            grp = df[df["vol_regime"] == regime]
            report["by_vol_regime"][regime] = compute_segment_stats(grp) if len(grp) else {}
    else:
        report["by_vol_regime"] = {"note": "No ATR column — vol regime skipped."}

    return report


def print_report(report: dict) -> None:
    sep = "=" * 60
    print(sep)
    print(f"SESSION ANALYSIS REPORT — {report['file']}")
    print(f"Total trades: {report['total_trades']}")
    print(sep)

    overall = report["overall"]
    print(f"\nOVERALL")
    print(f"  Trades: {overall['trades']}  |  Win rate: {overall['win_rate_pct']}%")
    pf_str = f"{overall['profit_factor']:.3f}" if overall['profit_factor'] is not None else "∞"
    print(f"  Net P&L: {overall['net_pnl']:.2f}  |  PF: {pf_str}  |  Avg R: {overall['avg_r']:.4f}")

    print(f"\nBY SESSION")
    for sess, stats in report["by_session"].items():
        if not stats:
            print(f"  {sess:8s}: no trades")
            continue
        pf_str = f"{stats['profit_factor']:.3f}" if stats['profit_factor'] is not None else "∞"
        print(f"  {sess:8s}: {stats['trades']:4d} trades  WR={stats['win_rate_pct']:5.1f}%"
              f"  Net={stats['net_pnl']:9.2f}  PF={pf_str}  AvgR={stats['avg_r']:.4f}")

    print(f"\nBY VOL REGIME")
    bvr = report["by_vol_regime"]
    if isinstance(bvr, dict) and "note" in bvr:
        print(f"  {bvr['note']}")
    else:
        for regime, stats in bvr.items():
            if not stats:
                print(f"  {regime:5s}: no trades")
                continue
            pf_str = f"{stats['profit_factor']:.3f}" if stats['profit_factor'] is not None else "∞"
            print(f"  {regime:5s}: {stats['trades']:4d} trades  WR={stats['win_rate_pct']:5.1f}%"
                  f"  Net={stats['net_pnl']:9.2f}  PF={pf_str}  AvgR={stats['avg_r']:.4f}")

    print(f"\nTOP-5 LOSS CONTRIBUTORS")
    for i, item in enumerate(report["top5_loss_contributors"], 1):
        sym = f"  [{item.get('symbol', '')}]" if "symbol" in item else ""
        print(f"  {i}. {item['time']}  P&L={item['pnl']:.2f}  Session={item['session']}{sym}")

    print(sep)


def main() -> None:
    parser = argparse.ArgumentParser(description="Trade segmentation by session & volatility regime.")
    parser.add_argument("--file",   required=True, help="Path to trades CSV")
    parser.add_argument("--output", default=None,  help="Optional JSON output path")
    args = parser.parse_args()

    if not Path(args.file).exists():
        print(f"ERROR: file not found: {args.file}", file=sys.stderr)
        sys.exit(1)

    report = run_analysis(args.file)
    print_report(report)

    if args.output:
        with open(args.output, "w") as fh:
            json.dump(report, fh, indent=2, default=str)
        print(f"\nJSON report saved to: {args.output}")


if __name__ == "__main__":
    main()
