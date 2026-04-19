"""
Unit tests for v20.0 Python tools:
  - tools/export_model_thresholds.py  (ML entry-gate)
  - tools/analyse_mae_mfe.py          (MAE/MFE analysis)
  - tools/rank_symbols.py             (symbol ranking)
"""
import csv
import io
import json
import math
import tempfile
from pathlib import Path
import pytest

# ---------------------------------------------------------------------------
# Helpers — shared across all three test modules
# ---------------------------------------------------------------------------

ML_HEADER = [
    "run_id", "ts", "sym", "setup", "dir",
    "entry", "sl", "tp", "lots", "risk_money",
    "atr_pips", "adx_trend", "adx_entry", "spread_pips", "body_pips",
    "rej_reason", "rej_detail", "pos_id", "event",
    "profit_pips", "profit_money", "r_mult", "slmod_ret", "comment", "schema",
]


def _write_csv(rows, path):
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=ML_HEADER, delimiter=";",
                           extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow(r)


def _entry(sym="EURUSD", pid="1", direction="BUY",
           atr=15.0, adx_t=25.0, adx_e=22.0, spread=1.5, body=4.0,
           entry=1.1000, sl=1.0985, tp=1.1022):
    return {
        "run_id": "entry", "ts": "2026.04.01 10:00", "sym": sym,
        "setup": "S1", "dir": direction,
        "entry": str(entry), "sl": str(sl), "tp": str(tp),
        "lots": "0.01", "risk_money": "30",
        "atr_pips": str(atr), "adx_trend": str(adx_t),
        "adx_entry": str(adx_e), "spread_pips": str(spread),
        "body_pips": str(body),
        "rej_reason": "", "rej_detail": "",
        "pos_id": pid, "event": "ENTRY",
        "profit_pips": "", "profit_money": "", "r_mult": "1.0",
        "slmod_ret": "0", "comment": "", "schema": "v2",
    }


def _exit(sym="EURUSD", pid="1", profit_pips=12.0, profit_money=30.0):
    return {
        "run_id": "exit", "ts": "2026.04.01 11:00", "sym": sym,
        "setup": "", "dir": "",
        "entry": "", "sl": "", "tp": "",
        "lots": "", "risk_money": "",
        "atr_pips": "", "adx_trend": "", "adx_entry": "",
        "spread_pips": "", "body_pips": "",
        "rej_reason": "", "rej_detail": "",
        "pos_id": pid, "event": "EXIT",
        "profit_pips": str(profit_pips),
        "profit_money": str(profit_money),
        "r_mult": "", "slmod_ret": "0", "comment": "", "schema": "v2",
    }


# ===========================================================================
# export_model_thresholds.py
# ===========================================================================

from tools.export_model_thresholds import (
    build_dataset,
    compute_stats,
    sigmoid,
    score_sample,
    calibrate_threshold,
    precision_recall_at,
    load_csv as emt_load_csv,
)


class TestExportModelThresholds:

    def _make_rows_labelled(self, n_win=30, n_loss=20):
        rows = []
        for i in range(n_win):
            rows.append(_entry(pid=str(i), atr=20, adx_t=30, adx_e=28, spread=1.0, body=5))
            # We need profit_money to label; hack: use ENTRY event and profit_money populated
            rows[-1]["profit_money"] = "50.0"
        for i in range(n_loss):
            pid = str(n_win + i)
            rows.append(_entry(pid=pid, atr=10, adx_t=15, adx_e=12, spread=3.0, body=1))
            rows[-1]["profit_money"] = "-30.0"
        return rows

    def test_build_dataset_filters_event_entry(self):
        rows = self._make_rows_labelled(10, 5)
        # Add non-ENTRY rows that should be ignored
        rows.append({**_exit(pid="999"), "profit_money": "10"})
        X, y, fnames = build_dataset(rows)
        assert len(X) == 15
        assert sum(y) == 10  # 10 wins

    def test_compute_stats_shape(self):
        rows = self._make_rows_labelled(20, 10)
        X, y, fnames = build_dataset(rows)
        stats = compute_stats(X, fnames)
        assert set(fnames) == set(stats.keys())
        for f, s in stats.items():
            assert "mean" in s and "std" in s
            assert s["std"] > 0

    def test_sigmoid_bounds(self):
        assert sigmoid(0) == pytest.approx(0.5)
        assert sigmoid(100) > 0.999
        assert sigmoid(-100) < 0.001

    def test_score_sample_unit_weight(self):
        weights = {"atr_pips": 1.0, "adx_trend": 0.0, "adx_entry": 0.0,
                   "spread_pips": 0.0, "body_pips": 0.0, "r_mult": 0.0}
        stats = {"atr_pips": {"mean": 15.0, "std": 5.0},
                 "adx_trend": {"mean": 25.0, "std": 5.0},
                 "adx_entry": {"mean": 20.0, "std": 5.0},
                 "spread_pips": {"mean": 1.5, "std": 0.5},
                 "body_pips": {"mean": 3.0, "std": 1.0},
                 "r_mult": {"mean": 1.0, "std": 0.3}}
        feat_names = list(weights.keys())
        feats = [15.0, 25.0, 20.0, 1.5, 3.0, 1.0]  # all at mean
        sc = score_sample(feats, weights, stats, feat_names)
        assert sc == pytest.approx(0.5, abs=1e-4)

    def test_calibrate_threshold_trivial(self):
        # 10 wins (score 0.9), 10 losses (score 0.1)
        scores = [0.9] * 10 + [0.1] * 10
        labels = [1] * 10 + [0] * 10
        t = calibrate_threshold(scores, labels, target_recall=0.80)
        assert 0.1 <= t <= 1.0

    def test_precision_recall_at(self):
        scores = [0.9, 0.8, 0.7, 0.4, 0.3]
        labels = [1, 1, 0, 0, 1]
        prec, rec = precision_recall_at(scores, labels, threshold=0.75)
        # Predicted positive: 0.9, 0.8 → tp=2, fp=0; fn=1 (score 0.3 below thresh)
        assert prec == pytest.approx(1.0)
        assert rec == pytest.approx(2 / 3, abs=1e-4)

    def test_full_pipeline_csv(self, tmp_path):
        rows = self._make_rows_labelled(40, 25)
        csv_path = tmp_path / "ml.csv"
        _write_csv(rows, str(csv_path))
        loaded = emt_load_csv(str(csv_path))
        X, y, _ = build_dataset(loaded)
        assert len(X) == 65


# ===========================================================================
# analyse_mae_mfe.py
# ===========================================================================

from tools.analyse_mae_mfe import (
    pair_trades,
    analyse,
    _percentile,
    _mean,
    _stdev,
    load_csv as amm_load_csv,
)


class TestAnalyseMaeMfe:

    def _csv_with_trades(self, tmp_path, trade_list):
        """trade_list: list of (sym, pid, profit_pips, profit_money, atr_pips)"""
        rows = []
        for sym, pid, pp, pm, atr in trade_list:
            rows.append(_entry(sym=sym, pid=pid, atr=atr, entry=1.1000, sl=1.0985))
            rows.append(_exit(sym=sym, pid=pid, profit_pips=pp, profit_money=pm))
        p = tmp_path / "ml.csv"
        _write_csv(rows, str(p))
        return str(p)

    def test_pair_trades_basic(self, tmp_path):
        trades_in = [
            ("EURUSD", "1", 12.0, 40.0, 15.0),
            ("EURUSD", "2", -8.0, -25.0, 15.0),
            ("GBPUSD", "3", 20.0, 60.0, 20.0),
        ]
        path = self._csv_with_trades(tmp_path, trades_in)
        rows = amm_load_csv(path)
        trades = pair_trades(rows)
        assert len(trades) == 3
        assert trades[0]["is_win"] is True
        assert trades[1]["is_win"] is False

    def test_pair_trades_unmatched(self, tmp_path):
        rows = [_entry(sym="EURUSD", pid="10")]
        p = tmp_path / "ml.csv"
        _write_csv(rows, str(p))
        loaded = amm_load_csv(str(p))
        trades = pair_trades(loaded)
        assert len(trades) == 0

    def test_percentile_basics(self):
        data = [1.0, 2.0, 3.0, 4.0, 5.0]
        assert _percentile(data, 0)   == pytest.approx(1.0)
        assert _percentile(data, 100) == pytest.approx(5.0)
        assert _percentile(data, 50)  == pytest.approx(3.0)

    def test_mean_stdev(self):
        data = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]
        assert _mean(data)  == pytest.approx(5.0)
        # Sample stdev (n-1 denominator): sqrt(32/7) ≈ 2.138
        assert _stdev(data) == pytest.approx(math.sqrt(32 / 7), abs=1e-4)

    def test_analyse_gives_recs(self, tmp_path):
        trades_in = []
        # Start pids at 1 (pid "0" is filtered by pair_trades)
        for i in range(1, 11):
            trades_in.append(("EURUSD", str(i), 15.0 + i, 40.0 + i, 12.0))
        for i in range(11, 16):
            trades_in.append(("EURUSD", str(i), -8.0, -25.0, 12.0))
        path = self._csv_with_trades(tmp_path, trades_in)
        rows = amm_load_csv(path)
        trades = pair_trades(rows)
        results = analyse(trades, sl_pct=90, tp_pct=60)
        assert "EURUSD" in results
        r = results["EURUSD"]
        assert r["trades"] == 15
        assert r["wins"] == 10
        assert r["losses"] == 5
        assert r["rec_tp_atr_mult"] is not None
        assert r["rec_sl_atr_mult"] is not None


# ===========================================================================
# rank_symbols.py
# ===========================================================================

from tools.rank_symbols import (
    pair_trades as rank_pair_trades,
    compute_sharpe,
    rank_symbols,
    load_csv as rs_load_csv,
)


class TestRankSymbols:

    def _csv(self, tmp_path, trade_list):
        """trade_list: list of (sym, pid, profit_money, atr_pips)"""
        rows = []
        for sym, pid, pm, atr in trade_list:
            rows.append(_entry(sym=sym, pid=pid, atr=atr))
            rows.append(_exit(sym=sym, pid=pid, profit_pips=pm * 0.5, profit_money=pm))
        p = tmp_path / "ml.csv"
        _write_csv(rows, str(p))
        return str(p)

    def test_compute_sharpe_positive_skew(self):
        profits = [10.0, 12.0, 11.0, 9.0, 13.0]  # consistent winners
        assert compute_sharpe(profits) > 0

    def test_compute_sharpe_negative_skew(self):
        profits = [-5.0, -8.0, -3.0, -10.0]
        assert compute_sharpe(profits) < 0

    def test_compute_sharpe_single(self):
        # need >= 2 samples
        assert compute_sharpe([10.0]) == 0.0

    def test_rank_symbols_basic(self, tmp_path):
        trades = (
            [("EURUSD", str(i), 15.0, 12.0) for i in range(10)] +
            [("GBPUSD", str(100+i), 5.0, 12.0) for i in range(10)] +
            [("CUCUSD", str(200+i), -3.0, 12.0) for i in range(10)]
        )
        path = self._csv(tmp_path, trades)
        rows = rs_load_csv(path)
        paired = rank_pair_trades(rows, lookback_days=0)
        rankings = rank_symbols(paired, top_n=2)
        # EURUSD should be rank 1 (highest Sharpe from consistent wins)
        assert rankings[0]["symbol"] == "EURUSD"
        assert rankings[0]["rank"] == 1
        # top-2 enabled, rest not
        enabled = [r for r in rankings if r["enabled"] == 1]
        disabled = [r for r in rankings if r["enabled"] == 0]
        assert len(enabled) == 2
        assert len(disabled) == 1

    def test_rank_symbols_top_n_zero_enables_all(self, tmp_path):
        trades = (
            [("EURUSD", str(i), 10.0, 12.0) for i in range(5)] +
            [("GBPUSD", str(100+i), 8.0, 12.0) for i in range(5)]
        )
        path = self._csv(tmp_path, trades)
        rows = rs_load_csv(path)
        paired = rank_pair_trades(rows, lookback_days=0)
        rankings = rank_symbols(paired, top_n=0)
        assert all(r["enabled"] == 1 for r in rankings)

    def test_rank_symbols_lookback_filter(self, tmp_path):
        """Trades older than lookback_days should be excluded."""
        rows = []
        # 5 recent trades for EURUSD
        for i in range(5):
            e = _entry(sym="EURUSD", pid=str(i))
            e["ts"] = "2026.04.18 10:00"
            x = _exit(sym="EURUSD", pid=str(i), profit_money=10.0)
            x["ts"] = "2026.04.18 11:00"
            rows.extend([e, x])
        # 5 old trades for GBPUSD (far in the past)
        for i in range(5):
            e = _entry(sym="GBPUSD", pid=str(100+i))
            e["ts"] = "2020.01.01 10:00"
            x = _exit(sym="GBPUSD", pid=str(100+i), profit_money=20.0)
            x["ts"] = "2020.01.01 11:00"
            rows.extend([e, x])
        p = tmp_path / "ml.csv"
        _write_csv(rows, str(p))
        loaded = rs_load_csv(str(p))
        paired = rank_pair_trades(loaded, lookback_days=10)
        syms = {t["sym"] for t in paired}
        assert "EURUSD" in syms
        assert "GBPUSD" not in syms
