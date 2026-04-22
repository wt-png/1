"""
test_tools.py — pytest tests for session_analysis, wfo_pipeline, monte_carlo_analysis.

Run:
    python -m pytest tools/test_tools.py -v
"""

import json
import sys
from io import StringIO
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

# Ensure tools/ is importable when run from repo root
sys.path.insert(0, str(Path(__file__).parent))

from session_analysis import (
    assign_session,
    assign_vol_regime,
    compute_segment_stats,
    top_loss_contributors,
    run_analysis as sa_run_analysis,
)
from wfo_pipeline import (
    compute_score,
    run_fold,
    run_wfo,
)
from monte_carlo_analysis import (
    max_drawdown_pct,
    profit_factor,
    run_simulations,
    go_no_go,
    run_analysis as mc_run_analysis,
)


# ── Fixtures ──────────────────────────────────────────────────────────────────

def _make_trades_df(n: int = 120, seed: int = 0,
                    positive_expectancy: bool = True) -> pd.DataFrame:
    """Synthetic trades covering ~1 year."""
    rng = np.random.default_rng(seed)
    times = pd.date_range("2023-01-01", periods=n, freq="3D", tz="UTC")
    if positive_expectancy:
        pnl = rng.choice([-0.5, 1.0, 2.0, -0.3, 1.5], size=n,
                         p=[0.2, 0.3, 0.2, 0.15, 0.15])
    else:
        pnl = rng.choice([-1.5, 0.5, -1.0, 0.3], size=n, p=[0.35, 0.3, 0.25, 0.1])
    atr = rng.uniform(5, 30, size=n)
    adx = rng.uniform(10, 50, size=n)
    return pd.DataFrame({
        "time":   times,
        "pnl":    pnl,
        "atr":    atr,
        "adx":    adx,
        "symbol": rng.choice(["EURUSD", "GBPUSD"], size=n),
    })


@pytest.fixture
def trades_csv(tmp_path):
    df = _make_trades_df(n=120)
    path = tmp_path / "trades.csv"
    df.to_csv(path, index=False)
    return str(path)


@pytest.fixture
def positive_trades_csv(tmp_path):
    df = _make_trades_df(n=200, positive_expectancy=True)
    path = tmp_path / "trades_pos.csv"
    df.to_csv(path, index=False)
    return str(path)


# ── session_analysis tests ────────────────────────────────────────────────────

class TestSessionAnalysis:
    def test_assign_session_covers_all_hours(self):
        """Every hour 0-23 maps to a known session."""
        valid = {"Asia", "London", "NY", "Late"}
        for h in range(24):
            assert assign_session(h) in valid

    def test_assign_session_boundaries(self):
        assert assign_session(0)  == "Asia"
        assert assign_session(6)  == "Asia"
        assert assign_session(7)  == "London"
        assert assign_session(11) == "London"
        assert assign_session(12) == "NY"
        assert assign_session(16) == "NY"
        assert assign_session(17) == "Late"
        assert assign_session(23) == "Late"

    def test_compute_segment_stats_empty(self):
        df = pd.DataFrame({"pnl": []})
        stats = compute_segment_stats(df)
        assert stats["trades"] == 0
        assert stats["net_pnl"] == 0.0

    def test_compute_segment_stats_basic(self):
        df = pd.DataFrame({"pnl": [1.0, -0.5, 2.0, -1.0, 0.5]})
        stats = compute_segment_stats(df)
        assert stats["trades"] == 5
        assert stats["wins"] == 3
        assert stats["losses"] == 2
        assert abs(stats["net_pnl"] - 2.0) < 1e-9
        assert stats["profit_factor"] == pytest.approx(3.5 / 1.5, rel=1e-3)

    def test_vol_regime_assignment(self):
        df = _make_trades_df(n=90)
        df = assign_vol_regime(df)
        assert "vol_regime" in df.columns
        assert set(df["vol_regime"].dropna().unique()).issubset({"Low", "Mid", "High"})

    def test_top_loss_contributors_count(self):
        df = _make_trades_df(n=50)
        top = top_loss_contributors(df, n=5)
        # All returned entries must be losses
        assert all(t["pnl"] <= 0 for t in top)
        assert len(top) <= 5

    def test_run_analysis_full(self, trades_csv):
        report = sa_run_analysis(trades_csv)
        assert "by_session" in report
        assert "by_vol_regime" in report
        assert "top5_loss_contributors" in report
        assert report["total_trades"] > 0
        for sess in ("Asia", "London", "NY", "Late"):
            assert sess in report["by_session"]


# ── wfo_pipeline tests ────────────────────────────────────────────────────────

class TestWfoPipeline:
    def test_compute_score_positive_expectancy(self):
        pnl = pd.Series([1.0, 2.0, 1.5, -0.5, -0.3] * 20)
        score = compute_score(pnl)
        assert score > 0

    def test_compute_score_empty(self):
        score = compute_score(pd.Series([], dtype=float))
        assert score == -float("inf")

    def test_compute_score_all_losses(self):
        pnl = pd.Series([-1.0, -2.0, -0.5])
        score = compute_score(pnl)
        assert score <= 0

    def test_run_fold_returns_required_keys(self):
        df = _make_trades_df(n=120)
        midpoint = len(df) // 2
        is_df  = df.iloc[:midpoint]
        oos_df = df.iloc[midpoint:]
        result = run_fold(is_df, oos_df, fold_idx=1)
        for key in ("fold", "best_min_adx", "is_score", "oos_score",
                    "degradation_ratio", "oos_trades", "grid"):
            assert key in result

    def test_run_wfo_produces_folds(self, trades_csv):
        from wfo_pipeline import load_trades
        df = load_trades(trades_csv)
        folds = run_wfo(df)
        # With 120 trades over ~1 year, should produce at least 1 fold
        assert len(folds) >= 1

    def test_degradation_ratio_is_numeric(self, trades_csv):
        from wfo_pipeline import load_trades
        df = load_trades(trades_csv)
        folds = run_wfo(df)
        for fold in folds:
            dr = fold["degradation_ratio"]
            assert dr is None or isinstance(dr, float)


# ── monte_carlo_analysis tests ────────────────────────────────────────────────

class TestMonteCarlo:
    def test_max_drawdown_zero_for_monotone_up(self):
        pnl = np.array([1.0, 1.0, 1.0, 1.0])
        assert max_drawdown_pct(pnl) == pytest.approx(0.0)

    def test_max_drawdown_positive_for_losing_streak(self):
        pnl = np.array([2.0, -1.0, -1.5, 1.0])
        dd = max_drawdown_pct(pnl)
        assert dd > 0

    def test_profit_factor_all_wins(self):
        pnl = np.array([1.0, 2.0, 0.5])
        assert profit_factor(pnl) == float("inf")

    def test_profit_factor_mixed(self):
        pnl = np.array([2.0, -1.0, 3.0, -1.0])
        pf = profit_factor(pnl)
        assert pf == pytest.approx(5.0 / 2.0, rel=1e-3)

    def test_go_verdict_positive_expectancy(self):
        stats = {
            "net_profit_p5":      0.5,
            "max_dd_p95_pct":     8.0,
            "pf_p5":              1.5,
            "pct_sims_profitable": 90.0,
        }
        verdict, issues = go_no_go(stats)
        assert verdict == "GO"
        assert issues == []

    def test_no_go_verdict_high_dd(self):
        stats = {
            "net_profit_p5":      0.5,
            "max_dd_p95_pct":     20.0,  # exceeds 12%
            "pf_p5":              1.5,
            "pct_sims_profitable": 90.0,
        }
        verdict, issues = go_no_go(stats)
        assert verdict == "NO-GO"
        assert any("DD" in i for i in issues)

    def test_run_analysis_full(self, positive_trades_csv):
        report = mc_run_analysis(positive_trades_csv, n_sims=200)
        assert "baseline_mc" in report
        assert "stressed_mc" in report
        assert "verdict_baseline" in report
        assert "verdict_stressed" in report
        assert report["n_trades"] > 0
        # Positive expectancy trades should be GO on baseline
        assert report["verdict_baseline"]["decision"] == "GO"

    def test_run_simulations_shape(self):
        rng = np.random.default_rng(0)
        pnl = np.array([1.0, -0.5, 2.0, -0.3, 1.5] * 40)
        stats = run_simulations(pnl, n_sims=100, spread_costs=None,
                                spread_pct=0.0, slippage=0.0, rng=rng)
        for key in ("net_profit_median", "net_profit_p5", "net_profit_p95",
                    "max_dd_median_pct", "max_dd_p95_pct", "pf_median",
                    "pct_sims_profitable"):
            assert key in stats
            assert isinstance(stats[key], float)
