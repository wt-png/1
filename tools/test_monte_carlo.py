"""
Unit tests for tools/monte_carlo_analysis.py.
Run with: pytest tools/ -v
"""

import random
import sys
import os

# Ensure the tools directory is importable regardless of working directory.
sys.path.insert(0, os.path.dirname(__file__))

import monte_carlo_analysis as mc


# ---------------------------------------------------------------------------
# max_drawdown
# ---------------------------------------------------------------------------

def test_max_drawdown_no_loss():
    """Flat or rising equity should produce 0 drawdown."""
    assert mc.max_drawdown([1000, 1000, 1100, 1200]) == 0.0


def test_max_drawdown_full_loss():
    """Equity halved then recovers: DD should be 0.5."""
    curve = [1000, 500, 1000]
    dd = mc.max_drawdown(curve)
    assert abs(dd - 0.5) < 1e-9


def test_max_drawdown_single_element():
    """Single-element curve has no drawdown."""
    assert mc.max_drawdown([1000]) == 0.0


def test_max_drawdown_monotone_decline():
    """Monotonically declining curve: DD = (peak - end) / peak."""
    curve = [1000, 800, 600, 400]
    dd = mc.max_drawdown(curve)
    assert abs(dd - 0.6) < 1e-9


# ---------------------------------------------------------------------------
# sharpe_ratio
# ---------------------------------------------------------------------------

def test_sharpe_ratio_all_positive():
    """Monotonically rising equity with no variance → very high Sharpe."""
    curve = [1000 + i * 10 for i in range(50)]
    sr = mc.sharpe_ratio(curve)
    assert sr > 5.0  # near-perfect consistency


def test_sharpe_ratio_too_short():
    """Fewer than 2 points should return 0."""
    assert mc.sharpe_ratio([1000]) == 0.0
    assert mc.sharpe_ratio([]) == 0.0


def test_sharpe_ratio_zero_std():
    """Flat equity (no returns) → std=0 → Sharpe=0."""
    curve = [1000] * 20
    assert mc.sharpe_ratio(curve) == 0.0


def test_sharpe_ratio_sign():
    """Declining equity should yield a negative Sharpe."""
    curve = [1000 - i * 10 for i in range(20)]
    assert mc.sharpe_ratio(curve) < 0.0


# ---------------------------------------------------------------------------
# calmar_ratio
# ---------------------------------------------------------------------------

def test_calmar_ratio_no_drawdown():
    """No drawdown means Calmar returns 0 (guard against division by zero)."""
    curve = [1000, 1100, 1200, 1300]
    assert mc.calmar_ratio(curve) == 0.0


def test_calmar_ratio_declining():
    """Declining equity should produce a negative Calmar."""
    curve = [1000, 900, 800, 700]
    assert mc.calmar_ratio(curve) < 0.0


def test_calmar_ratio_too_short():
    assert mc.calmar_ratio([1000]) == 0.0
    assert mc.calmar_ratio([]) == 0.0


# ---------------------------------------------------------------------------
# load_trades
# ---------------------------------------------------------------------------

def test_load_trades_profit_r(tmp_path):
    """load_trades should read profit_r column."""
    csv = tmp_path / "trades.csv"
    csv.write_text("time,symbol,profit_r\n2024-01-01,EURUSD,1.5\n2024-01-02,EURUSD,-0.5\n")
    trades = mc.load_trades(str(csv))
    assert trades == [1.5, -0.5]


def test_load_trades_profit_fallback(tmp_path):
    """load_trades should fall back to 'profit' column when 'profit_r' absent."""
    csv = tmp_path / "trades.csv"
    csv.write_text("time,profit\n2024-01-01,2.0\n2024-01-02,-1.0\n")
    trades = mc.load_trades(str(csv))
    assert trades == [2.0, -1.0]


def test_load_trades_skips_invalid(tmp_path):
    """Non-numeric values should be skipped gracefully."""
    csv = tmp_path / "trades.csv"
    csv.write_text("profit_r\n1.0\nbad\n2.0\n")
    trades = mc.load_trades(str(csv))
    assert trades == [1.0, 2.0]


# ---------------------------------------------------------------------------
# run_simulation
# ---------------------------------------------------------------------------

def test_run_simulation_keys():
    """run_simulation should include Sharpe and Calmar keys."""
    random.seed(42)
    trades = [1.0, -0.5, 0.8, -0.3, 1.2] * 10
    result = mc.run_simulation(trades, iterations=100, confidence=95.0)
    assert "median_sharpe" in result
    assert "median_calmar" in result
    assert "prob_ruin_pct" in result


def test_run_simulation_ruin_never_with_all_wins():
    """All-winning trades should have 0% ruin probability."""
    random.seed(0)
    trades = [1.0] * 30
    result = mc.run_simulation(trades, iterations=200, ruin_threshold=0.5)
    assert result["prob_ruin_pct"] == 0.0


def test_run_simulation_high_ruin_with_all_losses():
    """All-losing trades should have 100% ruin probability."""
    random.seed(0)
    trades = [-1.0] * 30
    result = mc.run_simulation(trades, starting_equity=1000.0, iterations=50,
                               ruin_threshold=0.5, risk_pct=2.0)
    assert result["prob_ruin_pct"] == 100.0


def test_run_simulation_win_rate():
    """Win rate calculation should match the known proportion."""
    trades = [1.0] * 7 + [-1.0] * 3  # 70% win rate
    random.seed(1)
    result = mc.run_simulation(trades, iterations=100)
    assert abs(result["win_rate"] - 70.0) < 1e-9
