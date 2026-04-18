#!/usr/bin/env python3
"""
Monte Carlo simulation for MSPB EA trade sequence analysis.
Usage: python3 monte_carlo_analysis.py <trades_csv_file> [--iterations 10000]
                                       [--confidence 95] [--risk-pct 1.0]
                                       [--starting-equity 10000] [--ruin-threshold 0.5]

Input CSV format (from EA ml_export_v2.csv or a custom trades file):
  time,symbol,direction,profit_r (profit in R-multiples)
  
Output:
  - Distribution of final equity curves
  - Max drawdown distribution (5th/50th/95th percentile)
  - Probability of ruin (equity < 50% of start)
  - Recommended position sizing adjustment
"""

import argparse
import csv
import random
import statistics
import sys
from pathlib import Path


def load_trades(filepath: str) -> list[float]:
    """Load trade results as R-multiples from CSV."""
    trades = []
    with open(filepath, newline='') as f:
        reader = csv.DictReader(f)
        for row in reader:
            # Try 'profit_r' column first, then 'profit', then 'pnl'
            for col in ('profit_r', 'profit', 'pnl', 'PnL', 'Profit'):
                if col in row:
                    try:
                        trades.append(float(row[col]))
                    except ValueError:
                        pass
                    break
    return trades


def max_drawdown(equity_curve: list[float]) -> float:
    """Compute maximum drawdown as a fraction."""
    peak = equity_curve[0]
    max_dd = 0.0
    for v in equity_curve:
        if v > peak:
            peak = v
        dd = (peak - v) / peak if peak > 0 else 0.0
        if dd > max_dd:
            max_dd = dd
    return max_dd


def sharpe_ratio(equity_curve: list[float], risk_free_rate: float = 0.0) -> float:
    """Compute annualised Sharpe ratio from an equity curve.

    Each step is treated as one trade (not calendar time), so the result is a
    trade-by-trade Sharpe rather than a time-series Sharpe.  The annualisation
    factor assumes 250 trades per year.
    """
    if len(equity_curve) < 2:
        return 0.0
    returns = []
    for i in range(1, len(equity_curve)):
        prev = equity_curve[i - 1]
        ret = (equity_curve[i] - prev) / prev if prev != 0 else 0.0
        returns.append(ret)
    if not returns:
        return 0.0
    mean_r = statistics.mean(returns)
    try:
        std_r = statistics.stdev(returns)
    except statistics.StatisticsError:
        return 0.0
    if std_r == 0:
        return 0.0
    # Annualise assuming ~250 trade-returns per year
    annualisation = 250 ** 0.5
    return (mean_r - risk_free_rate) / std_r * annualisation


def calmar_ratio(equity_curve: list[float]) -> float:
    """Compute Calmar ratio: annualised return divided by max drawdown.

    Returns 0 if max drawdown is zero (no losses) to avoid division by zero.
    The annualisation factor assumes 250 trades per year.
    """
    if len(equity_curve) < 2:
        return 0.0
    start = equity_curve[0]
    end = equity_curve[-1]
    if start == 0:
        return 0.0
    total_return = (end - start) / start
    n_trades = len(equity_curve) - 1
    annual_return = total_return * (250 / max(n_trades, 1))
    mdd = max_drawdown(equity_curve)
    if mdd == 0:
        return 0.0
    return annual_return / mdd


def run_simulation(
    trades: list[float],
    starting_equity: float = 10000.0,
    iterations: int = 10000,
    confidence: float = 95.0,
    ruin_threshold: float = 0.5,
    risk_pct: float = 1.0,
) -> dict:
    """Run Monte Carlo by reshuffling the trade sequence.

    Args:
        trades: List of trade results expressed as R-multiples.
        starting_equity: Starting account balance for each simulation path.
        iterations: Number of Monte Carlo paths to simulate.
        confidence: Confidence level for percentile reporting (0-100).
        ruin_threshold: Fraction of starting equity below which a path is
            considered a ruin event (default 0.5 = 50% drawdown).
        risk_pct: Percentage of starting equity risked per trade (default 1.0).
    """
    final_equities = []
    max_drawdowns = []
    sharpe_ratios = []
    calmar_ratios = []
    ruin_count = 0
    n = len(trades)

    for _ in range(iterations):
        shuffled = random.sample(trades, n)
        eq = [starting_equity]
        for r in shuffled:
            eq.append(eq[-1] + r * (starting_equity * risk_pct / 100.0))
        final_equities.append(eq[-1])
        dd = max_drawdown(eq)
        max_drawdowns.append(dd)
        sharpe_ratios.append(sharpe_ratio(eq))
        calmar_ratios.append(calmar_ratio(eq))
        if eq[-1] < starting_equity * ruin_threshold:
            ruin_count += 1

    final_equities.sort()
    max_drawdowns.sort()
    sharpe_ratios.sort()
    calmar_ratios.sort()

    lo = int((1 - confidence / 100) / 2 * iterations)
    hi = int((1 + confidence / 100) / 2 * iterations)
    mid = iterations // 2

    return {
        'n_trades': n,
        'iterations': iterations,
        'starting_equity': starting_equity,
        'mean_final': statistics.mean(final_equities),
        'median_final': final_equities[mid],
        f'p{int((100-confidence)//2)}_final': final_equities[lo],
        f'p{int((100+confidence)//2)}_final': final_equities[hi],
        'mean_max_dd': statistics.mean(max_drawdowns),
        'median_max_dd': max_drawdowns[mid],
        f'p{int((100+confidence)//2)}_max_dd': max_drawdowns[hi],
        'prob_ruin_pct': ruin_count / iterations * 100,
        'win_rate': sum(1 for t in trades if t > 0) / n * 100 if n > 0 else 0,
        'avg_r': statistics.mean(trades) if trades else 0,
        'expectancy_per_trade': statistics.mean(trades) if trades else 0,
        'median_sharpe': sharpe_ratios[mid],
        f'p{int((100-confidence)//2)}_sharpe': sharpe_ratios[lo],
        'median_calmar': calmar_ratios[mid],
        f'p{int((100-confidence)//2)}_calmar': calmar_ratios[lo],
    }


def print_report(result: dict) -> None:
    print("=" * 60)
    print("  MSPB EA — Monte Carlo Analysis Report")
    print("=" * 60)
    print(f"  Trades loaded       : {result['n_trades']}")
    print(f"  Simulations         : {result['iterations']}")
    print(f"  Starting equity     : ${result['starting_equity']:,.2f}")
    print(f"  Win rate            : {result['win_rate']:.1f}%")
    print(f"  Avg R per trade     : {result['avg_r']:.3f}R")
    print()
    print("  --- Final Equity ---")
    print(f"  Median              : ${result['median_final']:,.2f}")
    print(f"  Mean                : ${result['mean_final']:,.2f}")
    for k, v in result.items():
        if k.startswith('p') and 'final' in k:
            print(f"  {k.upper()} percentile : ${v:,.2f}")
    print()
    print("  --- Max Drawdown ---")
    print(f"  Median              : {result['median_max_dd']*100:.1f}%")
    print(f"  Mean                : {result['mean_max_dd']*100:.1f}%")
    for k, v in result.items():
        if k.startswith('p') and 'max_dd' in k:
            print(f"  {k.upper()} percentile : {v*100:.1f}%")
    print()
    print(f"  --- Probability of Ruin (<50% equity) ---")
    print(f"  P(ruin)             : {result['prob_ruin_pct']:.2f}%")
    print()
    print("  --- Risk-Adjusted Return ---")
    print(f"  Median Sharpe       : {result['median_sharpe']:.2f}  (annualised, trade-by-trade)")
    for k, v in result.items():
        if k.startswith('p') and 'sharpe' in k:
            print(f"  {k.upper()} Sharpe    : {v:.2f}")
    print(f"  Median Calmar       : {result['median_calmar']:.2f}  (ann. return / max DD)")
    for k, v in result.items():
        if k.startswith('p') and 'calmar' in k:
            print(f"  {k.upper()} Calmar    : {v:.2f}")
    print("=" * 60)
    if result['prob_ruin_pct'] > 5:
        print("  ⚠️  WARNING: Ruin probability > 5%. Consider reducing risk.")
    elif result['median_max_dd'] > 0.20:
        print("  ⚠️  WARNING: Median max drawdown > 20%. Monitor closely.")
    elif result['median_sharpe'] < 0.5:
        print("  ⚠️  WARNING: Median Sharpe ratio < 0.5. Edge may be marginal.")
    else:
        print("  ✅  Risk profile looks acceptable.")
    print("=" * 60)


def main():
    parser = argparse.ArgumentParser(description="Monte Carlo analysis for MSPB EA")
    parser.add_argument("trades_file", help="CSV file with trade results")
    parser.add_argument("--iterations", type=int, default=10000)
    parser.add_argument("--confidence", type=float, default=95.0)
    parser.add_argument("--starting-equity", type=float, default=10000.0)
    parser.add_argument("--ruin-threshold", type=float, default=0.5)
    parser.add_argument("--risk-pct", type=float, default=1.0,
                        help="Percentage of starting equity risked per trade (default: 1.0)")
    parser.add_argument("--seed", type=int, default=None)
    args = parser.parse_args()

    if args.seed is not None:
        random.seed(args.seed)

    if not Path(args.trades_file).exists():
        print(f"Error: file not found: {args.trades_file}", file=sys.stderr)
        sys.exit(1)

    trades = load_trades(args.trades_file)
    if len(trades) < 10:
        print(f"Error: need at least 10 trades, got {len(trades)}", file=sys.stderr)
        sys.exit(1)

    result = run_simulation(
        trades,
        starting_equity=args.starting_equity,
        iterations=args.iterations,
        confidence=args.confidence,
        ruin_threshold=args.ruin_threshold,
        risk_pct=args.risk_pct,
    )
    print_report(result)


if __name__ == "__main__":
    main()
