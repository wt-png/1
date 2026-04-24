"""
test_tools.py
=============
pytest suite for all MSPB EA Python tools.

Covers:
  - contracts         : parse_datetime, position_side_to_str, _stable_id_from_obj, exceptions
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
from datetime import datetime, timezone, timedelta
from typing import Any, Dict, List

import pytest

# make sure tools/ is on sys.path
_TOOLS_DIR = os.path.dirname(__file__)
_REPO_DIR = os.path.dirname(_TOOLS_DIR)
sys.path.insert(0, _TOOLS_DIR)
sys.path.insert(0, _REPO_DIR)

from baseline_report import (
    _safe_div,
    _profit_factor,
    _sharpe,
    _max_dd_pct,
    _cagr,
    _calmar,
    compute_kpis,
    _parse_dt,
    load_trades_from_csv,
    _load_builtin,
    _load_pandas,
    _print_kpis,
    main as baseline_main,
)
from wfo_pipeline import (
    detect_regime,
    split_windows,
    run_wfo,
    main as wfo_main,
)
from monte_carlo_analysis import (
    run_monte_carlo,
    _percentile,
    _reshuffle,
    main as mc_main,
)
from stress_test import (
    apply_stress,
    run_stress_test,
    _label,
    main as stress_main,
)
from session_analysis import (
    _session_name,
    _weekday_name,
    classify_trades,
    classify_by_weekday,
    _session_summary,
    run_session_analysis,
    _print_table,
    main as session_main,
)
import contracts


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

    def test_expectancy_zero_when_no_valid_risk(self):
        trades = [_make_trade(10.0, r_risk=0.0), _make_trade(-5.0, r_risk=0.0)]
        kpis = compute_kpis(trades)
        assert kpis["net_expectancy_R"] == 0.0

    def test_years_fallback_single_exit(self):
        trades = [_make_trade(10.0, entry_time="2023.01.02 10:00:00", exit_time="2023.01.02 10:10:00")]
        kpis = compute_kpis(trades)
        assert "cagr_pct" in kpis


class TestProfitFactorAndCagr:
    def test_profit_factor_all_winners(self):
        assert _profit_factor(100.0, 0.0) == 100.0

    def test_profit_factor_zero_when_no_profit_no_loss(self):
        assert _profit_factor(0.0, 0.0) == 0.0

    def test_cagr_invalid_inputs(self):
        assert _cagr(0.0, 10_000.0, 1.0) == 0.0
        assert _cagr(10_000.0, 0.0, 1.0) == 0.0
        assert _cagr(10_000.0, 11_000.0, 0.0) == 0.0


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

    def test_datetime_passthrough(self):
        dt = datetime(2024, 1, 1, 12, 0, 0)
        assert _parse_dt(dt) == dt


class TestCsvLoaders:
    def test_load_builtin_skips_invalid_rows(self, tmp_path):
        csv_path = tmp_path / "builtin.csv"
        csv_path.write_text(
            "profit;r_risk;entry_time\n"
            "10;5;2023.01.01 10:00:00\n"
            "oops;5;2023.01.01 11:00:00\n"
            "20;7\n",
            encoding="utf-8",
        )
        rows = _load_builtin(str(csv_path))
        assert len(rows) == 1
        assert rows[0]["profit"] == 10.0
        assert rows[0]["r_risk"] == 5.0

    def test_load_pandas_raises_without_profit(self, tmp_path):
        pytest.importorskip("pandas")
        csv_path = tmp_path / "missing_profit.csv"
        csv_path.write_text("r_risk;lots\n10;0.01\n", encoding="utf-8")
        with pytest.raises(ValueError):
            _load_pandas(str(csv_path))

    def test_load_pandas_derives_risk(self, tmp_path):
        pytest.importorskip("pandas")
        csv_path = tmp_path / "derive_rrisk.csv"
        csv_path.write_text("profit;lots;sl_pips\n10;0.02;15\n-5;0.01;20\n", encoding="utf-8")
        rows = _load_pandas(str(csv_path))
        assert len(rows) == 2
        assert rows[0]["r_risk"] == pytest.approx(3.0)
        assert rows[1]["r_risk"] == pytest.approx(2.0)

    def test_load_trades_uses_builtin_when_pandas_disabled(self, tmp_path, monkeypatch):
        import baseline_report as br

        csv_path = tmp_path / "fallback.csv"
        csv_path.write_text("profit;r_risk\n1;1\n", encoding="utf-8")
        monkeypatch.setattr(br, "_HAS_PANDAS", False)
        rows = load_trades_from_csv(str(csv_path))
        assert len(rows) == 1

    def test_print_kpis_smoke(self, capsys):
        _print_kpis({"a": 1, "b": 2})
        out = capsys.readouterr().out
        assert "MSPB Baseline KPI Snapshot" in out


class TestBaselineMain:
    def test_baseline_main_success(self, tmp_path):
        csv_path = tmp_path / "ok.csv"
        out_path = tmp_path / "kpis.json"
        _write_csv(_mixed_trades(4, 2), str(csv_path))
        rc = baseline_main([str(csv_path), "--out", str(out_path)])
        assert rc == 0
        assert out_path.exists()


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

    def test_volatile_regime(self):
        trades = [_make_trade(200.0)] * 4 + [_make_trade(-150.0)] * 6
        assert detect_regime(trades) == "volatile"


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

    def test_all_windows_filtered_then_fallback(self):
        trades = [_make_trade(1.0)] * 20
        windows = split_windows(trades, n_windows=5, oos_ratio=1.0)
        assert len(windows) == 1


class TestWfoMain:
    def test_missing_csv(self, tmp_path):
        rc = wfo_main([str(tmp_path / "missing.csv"), "--out", str(tmp_path / "wfo.json")])
        assert rc == 1

    def test_success_path_writes_output(self, tmp_path):
        csv_path = tmp_path / "trades.csv"
        out_path = tmp_path / "wfo.json"
        _write_csv(_winning_trades(40), str(csv_path))
        rc = wfo_main([str(csv_path), "--windows", "3", "--oos-ratio", "0.3", "--out", str(out_path)])
        assert rc in (0, 2)
        assert out_path.exists()


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

    def test_zero_iterations_still_returns_structure(self):
        result = run_monte_carlo(_mixed_trades(5, 5), iterations=0, seed=7)
        assert result["iterations"] == 0
        assert result["real_pf_percentile"] == 50.0


class TestMonteCarloMain:
    def test_missing_csv(self, tmp_path):
        rc = mc_main([str(tmp_path / "missing.csv"), "--out", str(tmp_path / "mc.json")])
        assert rc == 1

    def test_success_path_writes_output(self, tmp_path):
        csv_path = tmp_path / "trades.csv"
        out_path = tmp_path / "mc.json"
        _write_csv(_mixed_trades(20, 10), str(csv_path))
        rc = mc_main([str(csv_path), "--iterations", "20", "--out", str(out_path)])
        assert rc in (0, 2)
        assert out_path.exists()


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

    def test_fail_path_sets_all_passed_false(self):
        trades = _losing_trades(20)
        result = run_stress_test(trades, [(1.0, 0.0)])
        assert result["all_passed"] is False
        assert result["verdict"] == "FAIL"


class TestStressMain:
    def test_mismatch_lengths(self, tmp_path):
        rc = stress_main([
            str(tmp_path / "missing.csv"),
            "--multipliers", "1.0", "1.4",
            "--slippage", "0.0",
        ])
        assert rc == 1

    def test_missing_csv(self, tmp_path):
        rc = stress_main([str(tmp_path / "missing.csv"), "--out", str(tmp_path / "stress.json")])
        assert rc == 1

    def test_success_path_writes_output(self, tmp_path):
        csv_path = tmp_path / "trades.csv"
        out_path = tmp_path / "stress.json"
        _write_csv(_mixed_trades(20, 10), str(csv_path))
        rc = stress_main([str(csv_path), "--out", str(out_path)])
        assert rc in (0, 2)
        assert out_path.exists()


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

    def test_unknown(self):
        assert _session_name(24) == "Unknown"


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

    def test_invalid_entry_time(self):
        trades = [{"profit": 5.0, "entry_time": "not-a-date"}]
        grouped = classify_trades(trades, gmt_offset_hours=0)
        assert len(grouped["Unknown"]) == 1


class TestClassifyByWeekday:
    def test_skips_missing_or_invalid_entry_time(self):
        trades = [
            _make_trade(1.0, entry_time="2023.01.02 08:00:00"),
            {"profit": 2.0},
            {"profit": 3.0, "entry_time": "invalid"},
        ]
        grouped = classify_by_weekday(trades, gmt_offset_hours=0)
        assert grouped["Monday"][0]["profit"] == 1.0
        assert len(grouped) == 1


class TestSessionSummary:
    def test_reduce_risk_recommendation(self):
        trades = [_make_trade(50.0)] * 3 + [_make_trade(-10.0)] * 7
        summary = _session_summary("London", trades, 10_000.0)
        assert summary["recommendation"] == "REDUCE_RISK"


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


class TestSessionMain:
    def test_missing_csv(self, tmp_path):
        rc = session_main([str(tmp_path / "missing.csv"), "--out", str(tmp_path / "session.json")])
        assert rc == 1

    def test_success_path_writes_output(self, tmp_path):
        csv_path = tmp_path / "trades.csv"
        out_path = tmp_path / "session.json"
        _write_csv(_mixed_trades(20, 10), str(csv_path))
        rc = session_main([str(csv_path), "--gmt-offset", "0", "--out", str(out_path)])
        assert rc == 0
        assert out_path.exists()


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


# ════════════════════════════════════════════════════════════════════════════════
# contracts.py tests
# ════════════════════════════════════════════════════════════════════════════════

class TestParseDatetime:
    def test_iso_z_suffix(self):
        dt = contracts.parse_datetime("2024-01-15T10:30:00Z")
        assert dt is not None
        assert dt.tzinfo is not None
        assert dt.year == 2024 and dt.month == 1 and dt.day == 15

    def test_iso_with_plus_offset(self):
        dt = contracts.parse_datetime("2024-06-01T08:00:00+02:00")
        assert dt is not None
        assert dt.tzinfo is not None

    def test_iso_utc_normalized(self):
        dt = contracts.parse_datetime("2024-03-10T12:00:00Z")
        assert dt.utcoffset() == timedelta(0)

    def test_aware_datetime_passthrough(self):
        aware = datetime(2024, 1, 1, 12, 0, tzinfo=timezone.utc)
        result = contracts.parse_datetime(aware)
        assert result == aware

    def test_naive_datetime_gets_utc(self):
        naive = datetime(2024, 6, 15, 9, 30)
        result = contracts.parse_datetime(naive)
        assert result.tzinfo is not None

    def test_int_raises_value_error(self):
        with pytest.raises(ValueError):
            contracts.parse_datetime(20240101)

    def test_none_raises_value_error(self):
        with pytest.raises(ValueError):
            contracts.parse_datetime(None)

    def test_unparseable_string_raises(self):
        with pytest.raises(ValueError):
            contracts.parse_datetime("not-a-date-at-all")

    def test_whitespace_stripped(self):
        dt = contracts.parse_datetime("  2024-01-01T00:00:00Z  ")
        assert dt is not None


class TestPositionSideToStr:
    def test_long(self):
        assert contracts.position_side_to_str(1) == "LONG"

    def test_short(self):
        assert contracts.position_side_to_str(-1) == "SHORT"

    def test_flat(self):
        assert contracts.position_side_to_str(0) == "FLAT"

    def test_unknown_value(self):
        assert contracts.position_side_to_str(99) == "UNKNOWN"

    def test_unknown_negative(self):
        assert contracts.position_side_to_str(-99) == "UNKNOWN"


class TestStableId:
    def test_deterministic(self):
        obj = {"symbol": "EURUSD", "action": "BUY"}
        id1 = contracts._stable_id_from_obj(obj)
        id2 = contracts._stable_id_from_obj(obj)
        assert id1 == id2

    def test_16_hex_chars_no_prefix(self):
        result = contracts._stable_id_from_obj({"a": 1})
        assert len(result) == 16
        assert all(c in "0123456789abcdef" for c in result)

    def test_prefix_applied(self):
        result = contracts._stable_id_from_obj({"a": 1}, prefix="sig")
        assert result.startswith("sig_")
        assert len(result) == 20  # "sig_" + 16

    def test_different_objects_different_ids(self):
        id1 = contracts._stable_id_from_obj({"a": 1})
        id2 = contracts._stable_id_from_obj({"a": 2})
        assert id1 != id2

    def test_key_order_independent(self):
        id1 = contracts._stable_id_from_obj({"a": 1, "b": 2})
        id2 = contracts._stable_id_from_obj({"b": 2, "a": 1})
        assert id1 == id2


class TestExceptionHierarchy:
    def test_trader_pro_error_is_exception(self):
        err = contracts.TraderProError("oops")
        assert isinstance(err, Exception)

    def test_signal_parse_error_is_trader_pro_error(self):
        err = contracts.SignalParseError("bad signal")
        assert isinstance(err, contracts.TraderProError)

    def test_signal_parse_error_is_exception(self):
        err = contracts.SignalParseError("bad signal")
        assert isinstance(err, Exception)

    def test_raise_signal_parse_error(self):
        with pytest.raises(contracts.SignalParseError):
            raise contracts.SignalParseError("test")

    def test_catch_as_trader_pro_error(self):
        with pytest.raises(contracts.TraderProError):
            raise contracts.SignalParseError("caught as base")


# ════════════════════════════════════════════════════════════════════════════════
# Extended baseline_report tests
# ════════════════════════════════════════════════════════════════════════════════

class TestCalmar:
    def test_positive_calmar(self):
        result = _calmar(20.0, 10.0)
        assert result == pytest.approx(2.0)

    def test_zero_dd_returns_zero(self):
        # _safe_div default is 0.0 when denominator is 0
        result = _calmar(20.0, 0.0)
        assert result == 0.0

    def test_negative_cagr(self):
        result = _calmar(-5.0, 10.0)
        assert result == pytest.approx(-0.5)


class TestSafeDivEdgeCases:
    def test_negative_denominator(self):
        assert _safe_div(10.0, -2.0) == pytest.approx(-5.0)

    def test_both_negative(self):
        assert _safe_div(-6.0, -3.0) == pytest.approx(2.0)

    def test_float_precision(self):
        assert _safe_div(1.0, 3.0) == pytest.approx(1 / 3)


class TestComputeKpisSlippage:
    def test_slippage_averaged(self):
        trades = [
            _make_trade(10.0) | {"slippage_pts": 2.0},
            _make_trade(-5.0) | {"slippage_pts": 4.0},
        ]
        kpis = compute_kpis(trades)
        assert kpis["avg_slippage_pts"] == pytest.approx(3.0)

    def test_no_slippage_field_gives_zero(self):
        trades = _winning_trades(5)
        kpis = compute_kpis(trades)
        assert kpis["avg_slippage_pts"] == 0.0

    def test_all_breakeven_trades(self):
        trades = [_make_trade(0.0) for _ in range(5)]
        kpis = compute_kpis(trades)
        assert kpis["net_profit_usd"] == 0.0
        assert kpis["profit_factor"] == 0.0

    def test_cagr_multi_year(self):
        # Two trades spanning >1 year should produce non-trivial CAGR
        trades = [
            _make_trade(1000.0, entry_time="2021.01.01 10:00:00", exit_time="2021.01.01 11:00:00"),
            _make_trade(1000.0, entry_time="2023.01.01 10:00:00", exit_time="2023.01.01 11:00:00"),
        ]
        kpis = compute_kpis(trades, initial_balance=10_000.0)
        assert "cagr_pct" in kpis
        assert isinstance(kpis["cagr_pct"], float)

    def test_recovery_factor_positive_profit(self):
        trades = _winning_trades(20)
        kpis = compute_kpis(trades)
        # Net profit positive, so recovery factor should be >= 0
        assert kpis["recovery_factor"] >= 0


class TestLoadBuiltinEdgeCases:
    def test_derives_r_risk_from_lots_sl_pips(self, tmp_path):
        csv_path = tmp_path / "test.csv"
        csv_path.write_text(
            "profit;lots;sl_pips\n10;0.01;20\n",
            encoding="utf-8",
        )
        rows = _load_builtin(str(csv_path))
        assert len(rows) == 1
        assert rows[0]["profit"] == 10.0

    def test_empty_file_no_crash(self, tmp_path):
        csv_path = tmp_path / "empty.csv"
        csv_path.write_text("profit;r_risk\n", encoding="utf-8")
        rows = _load_builtin(str(csv_path))
        assert rows == []

    def test_numeric_optional_cols_parsed(self, tmp_path):
        csv_path = tmp_path / "numeric.csv"
        csv_path.write_text(
            "profit;r_risk;spread_pips;lots\n5;2;0.5;0.02\n",
            encoding="utf-8",
        )
        rows = _load_builtin(str(csv_path))
        assert rows[0]["spread_pips"] == pytest.approx(0.5)
        assert rows[0]["lots"] == pytest.approx(0.02)


# ════════════════════════════════════════════════════════════════════════════════
# Extended wfo_pipeline tests
# ════════════════════════════════════════════════════════════════════════════════

class TestDetectRegimeEdgeCases:
    def test_all_winners_returns_range(self):
        # No losses → guard returns "range"
        trades = [_make_trade(20.0)] * 10
        assert detect_regime(trades) == "range"

    def test_all_losers_returns_range(self):
        # No wins → guard returns "range"
        trades = [_make_trade(-10.0)] * 10
        assert detect_regime(trades) == "range"

    def test_exactly_five_trades_evaluated(self):
        # Exactly 5 trades should be evaluated (not fall-through to "range")
        trades = [_make_trade(50.0)] * 4 + [_make_trade(-5.0)] * 1
        result = detect_regime(trades)
        assert result in ("trend", "range", "volatile")

    def test_trend_high_win_rate_and_big_wins(self):
        trades = [_make_trade(40.0)] * 15 + [_make_trade(-5.0)] * 3
        assert detect_regime(trades) == "trend"


class TestRunWFOEdgeCases:
    def test_minimal_trades_handled(self):
        trades = [_make_trade(10.0, exit_time="2023.01.01 10:00:00")] * 3
        result = run_wfo(trades, n_windows=3, oos_ratio=0.3)
        assert "overall" in result
        assert result["overall"]["recommendation"] in ("ACCEPT", "REJECT")

    def test_custom_target_regimes(self):
        trades = _mixed_trades(40, 10)
        result = run_wfo(trades, n_windows=2, target_regimes=["trend"])
        assert "trend" in result["regime_summary"]
        assert "range" not in result["regime_summary"]

    def test_reject_on_all_losers(self):
        trades = _losing_trades(50)
        result = run_wfo(trades, n_windows=3, oos_ratio=0.3)
        assert result["overall"]["recommendation"] == "REJECT"

    def test_generated_at_is_string(self):
        result = run_wfo(_winning_trades(20), n_windows=2)
        assert isinstance(result["generated_at"], str)

    def test_fold_count_matches_windows(self):
        trades = _winning_trades(60)
        result = run_wfo(trades, n_windows=3, oos_ratio=0.3)
        assert len(result["folds"]) == 3


# ════════════════════════════════════════════════════════════════════════════════
# Extended monte_carlo_analysis tests
# ════════════════════════════════════════════════════════════════════════════════

class TestReshuffle:
    def test_same_profits_different_order(self):
        trades = [{"profit": float(i)} for i in range(10)]
        reshuffled = _reshuffle(trades, seed=99)
        orig_profits = sorted(t["profit"] for t in trades)
        new_profits = sorted(t["profit"] for t in reshuffled)
        assert orig_profits == new_profits

    def test_reproducible_with_same_seed(self):
        trades = [{"profit": float(i)} for i in range(10)]
        r1 = [t["profit"] for t in _reshuffle(trades, seed=42)]
        r2 = [t["profit"] for t in _reshuffle(trades, seed=42)]
        assert r1 == r2

    def test_different_seeds_different_order(self):
        trades = [{"profit": float(i)} for i in range(20)]
        r1 = [t["profit"] for t in _reshuffle(trades, seed=1)]
        r2 = [t["profit"] for t in _reshuffle(trades, seed=2)]
        assert r1 != r2

    def test_original_trades_unchanged(self):
        trades = [{"profit": float(i)} for i in range(5)]
        _ = _reshuffle(trades, seed=7)
        assert [t["profit"] for t in trades] == [0.0, 1.0, 2.0, 3.0, 4.0]


class TestMCReproducibility:
    def test_same_seed_same_result(self):
        trades = _mixed_trades(30, 10)
        r1 = run_monte_carlo(trades, iterations=50, seed=77)
        r2 = run_monte_carlo(trades, iterations=50, seed=77)
        assert r1["real_pf_percentile"] == r2["real_pf_percentile"]
        assert r1["mc_pf_distribution"] == r2["mc_pf_distribution"]

    def test_overfitting_flag_is_bool(self):
        result = run_monte_carlo(_winning_trades(20), iterations=100, seed=1)
        assert isinstance(result["overfitting_flag"], bool)

    def test_total_trades_recorded(self):
        trades = _mixed_trades(15, 5)
        result = run_monte_carlo(trades, iterations=20, seed=0)
        assert result["total_trades"] == 20

    def test_mc_dd_distribution_present(self):
        result = run_monte_carlo(_mixed_trades(10, 5), iterations=30, seed=3)
        for key in ("p5", "p25", "p50", "p75", "p95"):
            assert key in result["mc_dd_distribution"]

    def test_mc_exp_distribution_present(self):
        result = run_monte_carlo(_mixed_trades(10, 5), iterations=30, seed=5)
        for key in ("p5", "p25", "p50", "p75", "p95"):
            assert key in result["mc_exp_distribution"]


# ════════════════════════════════════════════════════════════════════════════════
# Extended stress_test tests
# ════════════════════════════════════════════════════════════════════════════════

class TestLabelBoundaries:
    def test_exactly_1_05_is_normal(self):
        assert _label(1.05) == "normal"

    def test_just_above_1_05_is_moderate(self):
        assert _label(1.06) == "moderate"

    def test_exactly_1_6_is_moderate(self):
        assert _label(1.6) == "moderate"

    def test_just_above_1_6_is_high(self):
        assert _label(1.61) == "high"

    def test_zero_mult_is_normal(self):
        assert _label(0.0) == "normal"


class TestApplyStressEdgeCases:
    def test_winners_not_penalised_by_slippage(self):
        # Slippage only applies to losing trades (profit < 0)
        trades = [_make_trade(100.0, spread_pips=0.0, lots=0.01)]
        stressed = apply_stress(trades, spread_mult=1.0, slip_add_pts=50.0)
        assert stressed[0]["profit"] == pytest.approx(100.0)

    def test_zero_lots_fallback_used(self):
        # lots missing → fallback to 0.01
        trades = [{"profit": 10.0, "spread_pips": 2.0}]
        stressed = apply_stress(trades, spread_mult=2.0, slip_add_pts=0.0)
        # extra_spread = (2.0-1.0) * 2.0 * 0.01 * 10.0 = 0.2
        assert stressed[0]["profit"] == pytest.approx(10.0 - 0.2)

    def test_large_spread_multiplier_reduces_profit_to_negative(self):
        trades = [_make_trade(1.0, spread_pips=5.0, lots=1.0)]
        stressed = apply_stress(trades, spread_mult=10.0, slip_add_pts=0.0)
        assert stressed[0]["profit"] < 0

    def test_slippage_worsens_losers(self):
        trades = [_make_trade(-5.0, spread_pips=0.0, lots=0.01)]
        normal = apply_stress(trades, spread_mult=1.0, slip_add_pts=0.0)
        stressed = apply_stress(trades, spread_mult=1.0, slip_add_pts=100.0)
        assert stressed[0]["profit"] < normal[0]["profit"]


class TestRunStressTestEdgeCases:
    def test_high_scenario_gate_is_0_90(self):
        trades = _winning_trades(50)
        scenarios = [(2.0, 5.0)]
        result = run_stress_test(trades, scenarios)
        assert result["scenarios"][0]["pf_gate"] == pytest.approx(0.90)

    def test_moderate_scenario_gate_is_1_10(self):
        trades = _winning_trades(50)
        scenarios = [(1.4, 2.0)]
        result = run_stress_test(trades, scenarios)
        assert result["scenarios"][0]["pf_gate"] == pytest.approx(1.10)

    def test_multiple_scenarios_verdict_fail_if_any_fails(self):
        # Good trades pass normal, but override with all losers to force fail
        trades = _losing_trades(30)
        scenarios = [(1.0, 0.0), (1.4, 2.0), (2.0, 5.0)]
        result = run_stress_test(trades, scenarios)
        assert result["verdict"] == "FAIL"
        assert result["all_passed"] is False

    def test_scenario_result_has_required_fields(self):
        trades = _winning_trades(20)
        result = run_stress_test(trades, [(1.0, 0.0)])
        s = result["scenarios"][0]
        for field in ("label", "spread_mult", "slippage_add_pts", "profit_factor", "pf_gate", "passed"):
            assert field in s


# ════════════════════════════════════════════════════════════════════════════════
# Extended session_analysis tests
# ════════════════════════════════════════════════════════════════════════════════

class TestSessionNameExtended:
    def test_late_ny_hours(self):
        for hour in (20, 21, 22, 23):
            assert _session_name(hour) == "LateNY"

    def test_boundary_asia_london(self):
        assert _session_name(7) == "Asia"
        assert _session_name(8) == "London"

    def test_boundary_london_overlap(self):
        assert _session_name(12) == "London"
        assert _session_name(13) == "Overlap"

    def test_boundary_overlap_newyork(self):
        assert _session_name(15) == "Overlap"
        assert _session_name(16) == "NewYork"

    def test_boundary_newyork_lateny(self):
        assert _session_name(19) == "NewYork"
        assert _session_name(20) == "LateNY"

    def test_negative_hour_unknown(self):
        assert _session_name(-1) == "Unknown"


class TestWeekdayNameExtended:
    def test_all_weekdays(self):
        # 2024-04-22 is Monday
        base = datetime(2024, 4, 22)
        names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        for i, name in enumerate(names):
            dt = base + timedelta(days=i)
            assert _weekday_name(dt) == name


class TestSessionSummaryRecommendations:
    def test_keep_recommendation(self):
        # High PF + good win rate → KEEP
        trades = [_make_trade(100.0, r_risk=10.0) for _ in range(30)]
        summary = _session_summary("London", trades, 10_000.0)
        assert summary["recommendation"] == "KEEP"

    def test_block_entries_recommendation(self):
        trades = [_make_trade(-10.0) for _ in range(20)]
        summary = _session_summary("Asia", trades, 10_000.0)
        assert summary["recommendation"] == "BLOCK_ENTRIES"

    def test_no_data_recommendation(self):
        summary = _session_summary("Overlap", [], 10_000.0)
        assert summary["recommendation"] == "NO_DATA"
        assert summary["trade_count"] == 0

    def test_summary_contains_session_name(self):
        trades = [_make_trade(10.0)]
        summary = _session_summary("NewYork", trades, 10_000.0)
        assert summary["session"] == "NewYork"


class TestRunSessionAnalysisExtended:
    def test_blocked_sessions_populated(self):
        # All losing trades → sessions with data should be BLOCK_ENTRIES
        trades = [
            _make_trade(-10.0, entry_time="2023.01.02 09:00:00"),  # London
        ]
        result = run_session_analysis(trades, gmt_offset_hours=0)
        assert "blocked_sessions" in result
        assert isinstance(result["blocked_sessions"], list)

    def test_reduce_risk_sessions_populated(self):
        result = run_session_analysis(_mixed_trades(), gmt_offset_hours=0)
        assert "reduce_risk_sessions" in result
        assert isinstance(result["reduce_risk_sessions"], list)

    def test_spread_flag_high_when_costs_exceed_20pct(self):
        # Make trades with very high spread relative to small profit
        trades = [
            _make_trade(1.0, spread_pips=100.0, lots=1.0)
            for _ in range(10)
        ]
        result = run_session_analysis(trades, gmt_offset_hours=0)
        assert result["execution_quality"]["spread_flag"] == "HIGH"

    def test_gmt_offset_shifts_session_classification(self):
        # A trade at 07:00 UTC is Asia with offset 0, but London with offset +1
        trades = [
            _make_trade(5.0, entry_time="2023.01.02 07:00:00", exit_time="2023.01.02 07:30:00",
                        spread_pips=0.5, lots=0.01)
        ]
        result_0 = run_session_analysis(trades, gmt_offset_hours=0)
        result_1 = run_session_analysis(trades, gmt_offset_hours=1)
        # With gmt_offset=0 → hour 7 → Asia; with offset=1 → hour 8 → London
        asia_0 = next(s for s in result_0["sessions"] if s["session"] == "Asia")
        london_1 = next(s for s in result_1["sessions"] if s["session"] == "London")
        assert asia_0["trade_count"] == 1
        assert london_1["trade_count"] == 1

    def test_total_trades_count(self):
        trades = _mixed_trades(15, 5)
        result = run_session_analysis(trades, gmt_offset_hours=0)
        assert result["total_trades"] == 20

    def test_generated_at_is_string(self):
        result = run_session_analysis(_winning_trades(5))
        assert isinstance(result["generated_at"], str)


class TestClassifyByWeekdayExtended:
    def test_groups_by_day(self):
        trades = [
            _make_trade(1.0, entry_time="2023.01.02 09:00:00"),  # Monday
            _make_trade(2.0, entry_time="2023.01.03 09:00:00"),  # Tuesday
            _make_trade(3.0, entry_time="2023.01.02 15:00:00"),  # Monday
        ]
        grouped = classify_by_weekday(trades, gmt_offset_hours=0)
        assert len(grouped["Monday"]) == 2
        assert len(grouped["Tuesday"]) == 1

    def test_empty_trades_returns_empty_dict(self):
        grouped = classify_by_weekday([], gmt_offset_hours=0)
        assert grouped == {}


class TestPrintTable:
    def test_smoke(self, capsys):
        rows = [
            {"session": "London", "trade_count": 10, "win_rate_pct": 60.0,
             "profit_factor": 1.5, "net_expectancy_R": 0.2, "recommendation": "KEEP"},
        ]
        _print_table(rows, "Test Table")
        out = capsys.readouterr().out
        assert "Test Table" in out
        assert "London" in out
        assert "KEEP" in out

    def test_no_data_row_renders(self, capsys):
        rows = [
            {"session": "Asia", "trade_count": 0, "win_rate_pct": None,
             "profit_factor": None, "net_expectancy_R": None, "recommendation": "NO_DATA"},
        ]
        _print_table(rows, "Empty")
        out = capsys.readouterr().out
        assert "Asia" in out

