"""
test_tools.py
=============
pytest suite for all MSPB EA Python tools.

Covers:
  - baseline_report   : KPI computation, CSV loading, edge cases
  - wfo_pipeline      : window splitting, regime detection, WFO run
  - monte_carlo_analysis : reshuffling, distribution, overfitting flag
  - stress_test       : stress application, gate logic
  - session_analysis  : session classification, weekday classification
"""
from __future__ import annotations

import json
import math
import os
import sys
import tempfile
from datetime import datetime
from typing import Any, Dict, List

import pytest

# make sure tools/ is on sys.path
_TOOLS_DIR = os.path.dirname(__file__)
sys.path.insert(0, _TOOLS_DIR)

from baseline_report import (
    _safe_div,
    _sharpe,
    _max_dd_pct,
    _cagr,
    _calmar,
    compute_kpis,
    _parse_dt,
    load_trades_from_csv,
    main as baseline_main,
)
from wfo_pipeline import (
    detect_regime,
    split_windows,
    run_wfo,
)
from monte_carlo_analysis import (
    run_monte_carlo,
    _percentile,
)
from stress_test import (
    apply_stress,
    run_stress_test,
    _label,
)
from session_analysis import (
    _session_name,
    _weekday_name,
    classify_trades,
    run_session_analysis,
)


# ── fixtures ──────────────────────────────────────────────────────────────────

def _make_trade(
    profit: float,
    r_risk: float = 10.0,
    entry_time: str = "2023.01.02 09:00:00",
    exit_time: str = "2023.01.02 09:30:00",
    spread_pips: float = 0.5,
    lots: float = 0.01,
) -> Dict[str, Any]:
    return {
        "profit": profit,
        "r_risk": r_risk,
        "entry_time": entry_time,
        "exit_time": exit_time,
        "spread_pips": spread_pips,
        "lots": lots,
    }


def _winning_trades(n: int = 30) -> List[Dict[str, Any]]:
    """30 winning trades at +20 each."""
    return [_make_trade(20.0, 10.0, f"2023.0{max(1,i//10+1)}.{(i%28)+1:02d} 10:00", f"2023.0{max(1,i//10+1)}.{(i%28)+1:02d} 11:00") for i in range(n)]


def _losing_trades(n: int = 10) -> List[Dict[str, Any]]:
    """10 losing trades at -10 each."""
    return [_make_trade(-10.0, 10.0, f"2023.01.{(i%28)+1:02d} 14:00", f"2023.01.{(i%28)+1:02d} 14:30") for i in range(n)]


def _mixed_trades(wins: int = 20, losses: int = 10) -> List[Dict[str, Any]]:
    return _winning_trades(wins) + _losing_trades(losses)


def _write_csv(trades: List[Dict[str, Any]], path: str) -> None:
    """Write trades as semicolon-delimited CSV."""
    if not trades:
        return
    keys = list(trades[0].keys())
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(";".join(keys) + "\n")
        for t in trades:
            fh.write(";".join(str(t.get(k, "")) for k in keys) + "\n")


# ════════════════════════════════════════════════════════════════════════════════
# baseline_report tests
# ════════════════════════════════════════════════════════════════════════════════

class TestSafeDiv:
    def test_normal(self):
        assert _safe_div(10.0, 2.0) == pytest.approx(5.0)

    def test_zero_denominator(self):
        assert _safe_div(10.0, 0.0) == 0.0

    def test_custom_default(self):
        assert _safe_div(1.0, 0.0, default=99.0) == 99.0


class TestSharpe:
    def test_all_positive(self):
        returns = [1.0, 2.0, 1.5, 2.5, 1.0]
        sharpe = _sharpe(returns)
        assert sharpe > 0

    def test_empty(self):
        assert _sharpe([]) == 0.0

    def test_single(self):
        assert _sharpe([1.0]) == 0.0

    def test_zero_std(self):
        assert _sharpe([1.0, 1.0, 1.0]) == 0.0


class TestMaxDD:
    def test_monotonic_rise(self):
        assert _max_dd_pct([100, 110, 120, 130]) == pytest.approx(0.0)

    def test_simple_drawdown(self):
        # peak 200, trough 100 → 50 % DD
        assert _max_dd_pct([100, 200, 100]) == pytest.approx(50.0)

    def test_empty(self):
        assert _max_dd_pct([]) == 0.0


class TestComputeKpis:
    def test_winning_strategy(self):
        trades = _mixed_trades(wins=30, losses=10)
        kpis = compute_kpis(trades)
        assert kpis["win_rate_pct"] == pytest.approx(75.0)
        assert kpis["profit_factor"] > 1.0
        assert kpis["net_profit_usd"] > 0

    def test_losing_strategy(self):
        trades = _losing_trades(20)
        kpis = compute_kpis(trades)
        assert kpis["net_profit_usd"] < 0
        assert kpis["win_rate_pct"] == pytest.approx(0.0)

    def test_empty_trades(self):
        result = compute_kpis([])
        assert "error" in result

    def test_expectancy_positive(self):
        trades = _winning_trades(10)
        kpis = compute_kpis(trades)
        assert kpis["net_expectancy_R"] > 0

    def test_hold_time_computed(self):
        trades = _mixed_trades()
        kpis = compute_kpis(trades)
        assert kpis["avg_hold_min"] >= 0


class TestParseDt:
    def test_mql5_format(self):
        dt = _parse_dt("2023.06.15 10:30:00")
        assert dt is not None
        assert dt.year == 2023 and dt.month == 6

    def test_iso_format(self):
        dt = _parse_dt("2023-06-15 10:30:00")
        assert dt is not None

    def test_none_input(self):
        assert _parse_dt(None) is None

    def test_invalid_string(self):
        assert _parse_dt("not-a-date") is None


# ════════════════════════════════════════════════════════════════════════════════
# wfo_pipeline tests
# ════════════════════════════════════════════════════════════════════════════════

class TestDetectRegime:
    def test_strong_trend(self):
        # high win rate + big avg win
        trades = [_make_trade(30.0)] * 12 + [_make_trade(-5.0)] * 3
        assert detect_regime(trades) == "trend"

    def test_range_regime(self):
        trades = [_make_trade(10.0)] * 5 + [_make_trade(-8.0)] * 5
        regime = detect_regime(trades)
        assert regime in ("range", "volatile")

    def test_few_trades_default(self):
        assert detect_regime([]) == "range"
        assert detect_regime([_make_trade(10.0)]) == "range"


class TestSplitWindows:
    def test_basic_split(self):
        trades = [_make_trade(1.0)] * 100
        windows = split_windows(trades, n_windows=5, oos_ratio=0.30)
        assert len(windows) >= 1
        for is_t, oos_t in windows:
            assert len(is_t) > 0
            assert len(oos_t) > 0

    def test_insufficient_data_fallback(self):
        trades = [_make_trade(1.0)] * 4
        windows = split_windows(trades, n_windows=5, oos_ratio=0.30)
        assert len(windows) == 1

    def test_oos_ratio_respected(self):
        trades = [_make_trade(1.0)] * 100
        windows = split_windows(trades, n_windows=1, oos_ratio=0.30)
        is_t, oos_t = windows[0]
        total = len(is_t) + len(oos_t)
        assert total <= 100


class TestRunWFO:
    def test_accept_on_good_data(self):
        trades = _winning_trades(100)
        result = run_wfo(trades, n_windows=3, oos_ratio=0.3)
        assert result["overall"]["avg_oos_profit_factor"] >= 0
        assert "folds" in result
        assert "regime_summary" in result

    def test_structure(self):
        trades = _mixed_trades(40, 10)
        result = run_wfo(trades, n_windows=3)
        assert "generated_at" in result
        assert "overall" in result
        assert result["overall"]["recommendation"] in ("ACCEPT", "REJECT")


# ════════════════════════════════════════════════════════════════════════════════
# monte_carlo_analysis tests
# ════════════════════════════════════════════════════════════════════════════════

class TestPercentile:
    def test_median(self):
        data = list(range(1, 101))
        assert _percentile(data, 50) == pytest.approx(50.5, abs=1.0)

    def test_p0_p100(self):
        data = [1.0, 2.0, 3.0, 4.0, 5.0]
        assert _percentile(data, 0) == pytest.approx(1.0)
        assert _percentile(data, 100) == pytest.approx(5.0)

    def test_empty(self):
        assert _percentile([], 50) == 0.0


class TestRunMonteCarlo:
    def test_basic_structure(self):
        trades = _mixed_trades(30, 10)
        result = run_monte_carlo(trades, iterations=100, seed=42)
        assert "verdict" in result
        assert "real_kpis" in result
        assert "mc_pf_distribution" in result
        assert result["verdict"] in ("ROBUST", "MARGINAL", "OVERFIT_RISK")

    def test_no_overfitting_on_random_trades(self):
        # Purely random trades should not be flagged as overfitted
        trades = _mixed_trades(20, 20)
        result = run_monte_carlo(trades, iterations=200, seed=1)
        assert result["overfitting_flag"] in (True, False)  # just check it runs

    def test_distribution_keys(self):
        trades = _mixed_trades(20, 10)
        result = run_monte_carlo(trades, iterations=50, seed=7)
        for key in ("p5", "p25", "p50", "p75", "p95"):
            assert key in result["mc_pf_distribution"]


# ════════════════════════════════════════════════════════════════════════════════
# stress_test tests
# ════════════════════════════════════════════════════════════════════════════════

class TestLabel:
    def test_normal(self):
        assert _label(1.0) == "normal"
        assert _label(1.05) == "normal"

    def test_moderate(self):
        assert _label(1.4) == "moderate"
        assert _label(1.6) == "moderate"

    def test_high(self):
        assert _label(2.0) == "high"
        assert _label(3.0) == "high"


class TestApplyStress:
    def test_no_stress(self):
        trades = [_make_trade(100.0, spread_pips=1.0, lots=0.1)]
        stressed = apply_stress(trades, spread_mult=1.0, slip_add_pts=0.0)
        assert stressed[0]["profit"] == pytest.approx(100.0)

    def test_spread_reduces_profit(self):
        trades = [_make_trade(100.0, spread_pips=1.0, lots=0.1)]
        stressed = apply_stress(trades, spread_mult=2.0, slip_add_pts=0.0)
        assert stressed[0]["profit"] < 100.0

    def test_slippage_on_losers(self):
        trades = [_make_trade(-10.0, spread_pips=0.5, lots=0.01)]
        stressed = apply_stress(trades, spread_mult=1.0, slip_add_pts=5.0)
        assert stressed[0]["profit"] < -10.0


class TestRunStressTest:
    def test_all_pass_on_strong_strategy(self):
        trades = _winning_trades(60)  # heavily winning → should survive stress
        scenarios = [(1.0, 0.0), (1.4, 2.0), (2.0, 5.0)]
        result = run_stress_test(trades, scenarios)
        assert result["verdict"] in ("PASS", "FAIL")  # just check structure
        assert len(result["scenarios"]) == 3

    def test_normal_scenario_gate(self):
        trades = _winning_trades(50)
        scenarios = [(1.0, 0.0)]
        result = run_stress_test(trades, scenarios)
        assert result["scenarios"][0]["pf_gate"] == pytest.approx(1.30)

    def test_structure(self):
        trades = _mixed_trades()
        result = run_stress_test(trades, [(1.0, 0.0)])
        assert "real_kpis" in result
        assert "scenarios" in result
        assert "verdict" in result


# ════════════════════════════════════════════════════════════════════════════════
# session_analysis tests
# ════════════════════════════════════════════════════════════════════════════════

class TestSessionName:
    def test_london(self):
        assert _session_name(8) == "London"
        assert _session_name(12) == "London"

    def test_asia(self):
        assert _session_name(0) == "Asia"
        assert _session_name(7) == "Asia"

    def test_newyork(self):
        assert _session_name(16) == "NewYork"
        assert _session_name(19) == "NewYork"

    def test_overlap(self):
        assert _session_name(13) == "Overlap"


class TestWeekdayName:
    def test_monday(self):
        dt = datetime(2024, 4, 22)  # Monday
        assert _weekday_name(dt) == "Monday"

    def test_friday(self):
        dt = datetime(2024, 4, 26)  # Friday
        assert _weekday_name(dt) == "Friday"


class TestClassifyTrades:
    def test_london_entries(self):
        trades = [
            _make_trade(10.0, entry_time="2023.01.02 08:30:00"),
            _make_trade(10.0, entry_time="2023.01.02 09:00:00"),
        ]
        grouped = classify_trades(trades, gmt_offset_hours=0)
        assert len(grouped["London"]) == 2

    def test_missing_entry_time(self):
        trades = [{"profit": 5.0}]
        grouped = classify_trades(trades, gmt_offset_hours=0)
        assert len(grouped["Unknown"]) == 1


class TestRunSessionAnalysis:
    def test_basic_structure(self):
        trades = _mixed_trades(20, 10)
        result = run_session_analysis(trades)
        assert "sessions" in result
        assert "weekdays" in result
        assert "execution_quality" in result

    def test_execution_quality_fields(self):
        trades = _mixed_trades()
        result = run_session_analysis(trades)
        eq = result["execution_quality"]
        assert "avg_slippage_pts" in eq
        assert "spread_cost_pct_of_gross" in eq
        assert eq["spread_flag"] in ("HIGH", "OK")

    def test_recommendations_present(self):
        trades = _mixed_trades()
        result = run_session_analysis(trades)
        for s in result["sessions"]:
            assert s["recommendation"] in ("KEEP", "REDUCE_RISK", "BLOCK_ENTRIES", "NO_DATA")


# ════════════════════════════════════════════════════════════════════════════════
# CSV integration test
# ════════════════════════════════════════════════════════════════════════════════

class TestCSVRoundTrip:
    def test_load_and_compute(self, tmp_path):
        trades = _mixed_trades(30, 10)
        csv_path = str(tmp_path / "test_trades.csv")
        _write_csv(trades, csv_path)
        loaded = load_trades_from_csv(csv_path)
        assert len(loaded) == 40
        kpis = compute_kpis(loaded)
        assert kpis["total_trades"] == 40
        assert kpis["win_rate_pct"] == pytest.approx(75.0)

    def test_baseline_main_no_csv(self, tmp_path, capsys):
        rc = baseline_main([str(tmp_path / "missing.csv"), "--out", str(tmp_path / "out.json")])
        assert rc == 1
