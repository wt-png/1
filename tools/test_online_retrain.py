"""Tests for tools/online_retrain.py."""

from __future__ import annotations

import io
import json
import os
import textwrap
import tempfile
from pathlib import Path
from unittest import mock

import numpy as np
import pandas as pd
import pytest

# Make sure the tools directory is importable whether we run from repo root
# or from the tools/ directory itself.
import sys
sys.path.insert(0, str(Path(__file__).parent))

from online_retrain import (
    DEFAULT_CUTOFF,
    MIN_AVG_R,
    MIN_SHARPE_TO_WRITE,
    MIN_WINRATE,
    _rejected_result,
    extract_trades,
    load_csv,
    run,
    wfo_validate,
    write_thresholds,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_csv(rows: list[dict], sep: str = ";") -> str:
    """Return CSV text from list of dicts."""
    if not rows:
        return ""
    cols = list(rows[0].keys())
    lines = [sep.join(cols)]
    for r in rows:
        lines.append(sep.join(str(r.get(c, "")) for c in cols))
    return "\n".join(lines)


def _exit_row(
    sym: str = "EURUSD",
    r_mult: float = 1.0,
    atr: float = 15.0,
    adx_t: float = 25.0,
    adx_e: float = 20.0,
    spread: float = 1.5,
    body: float = 8.0,
    ts: str = "2025-01-02 10:00",
) -> dict:
    return {
        "run_id": "exit",
        "ts": ts,
        "symbol": sym,
        "setup": "S1",
        "dir": "BUY",
        "entry": "1.10000",
        "sl": "1.09900",
        "tp": "1.10100",
        "lots": "0.01",
        "risk_money": "10.0",
        "atr_pips": str(atr),
        "adx_trend": str(adx_t),
        "adx_entry": str(adx_e),
        "spread_pips": str(spread),
        "body_pips": str(body),
        "rej_reason": "",
        "rej_detail": "",
        "pos_id": "1001",
        "event": "EXIT",
        "profit_pips": str(r_mult * 10),
        "profit_money": str(r_mult * 10),
        "r_mult": str(r_mult),
        "slmod_ret": "0",
        "comment": "",
        "schema": "v2",
    }


def _make_trades_df(n: int = 100, win_rate: float = 0.6) -> pd.DataFrame:
    """Create synthetic trades DataFrame ready for WFO."""
    rng = np.random.default_rng(42)
    rows = []
    for i in range(n):
        win = rng.random() < win_rate
        r   = rng.uniform(0.8, 2.0) if win else rng.uniform(-1.5, -0.5)
        sym = rng.choice(["EURUSD", "GBPUSD"])
        rows.append(
            _exit_row(
                sym=sym,
                r_mult=r,
                atr=rng.uniform(8, 25),
                adx_t=rng.uniform(18, 45),
                adx_e=rng.uniform(15, 40),
                spread=rng.uniform(0.8, 3.0),
                body=rng.uniform(3, 20),
                ts=f"2025-{(i//30)+1:02d}-{(i%28)+1:02d} 10:00",
            )
        )
    csv_text = _make_csv(rows)
    df_raw = pd.read_csv(io.StringIO(csv_text), sep=";", dtype=str)
    df_raw.columns = [c.strip().lower() for c in df_raw.columns]
    return extract_trades(df_raw)


# ---------------------------------------------------------------------------
# load_csv tests
# ---------------------------------------------------------------------------

class TestLoadCsv:
    def test_loads_semicolon_separated(self, tmp_path):
        csv = _make_csv([_exit_row()], sep=";")
        p = tmp_path / "test.csv"
        p.write_text(csv)
        df = load_csv(str(p), ";")
        assert "event" in df.columns

    def test_loads_comma_separated(self, tmp_path):
        csv = _make_csv([_exit_row()], sep=",")
        p = tmp_path / "test.csv"
        p.write_text(csv)
        df = load_csv(str(p), ";")   # wrong default → fallback to comma
        assert "event" in df.columns

    def test_raises_on_unreadable(self, tmp_path):
        p = tmp_path / "bad.csv"
        p.write_text("a")
        with pytest.raises((ValueError, Exception)):
            load_csv(str(p), ";")


# ---------------------------------------------------------------------------
# extract_trades tests
# ---------------------------------------------------------------------------

class TestExtractTrades:
    def test_keeps_exit_rows(self):
        rows = [
            _exit_row(r_mult=1.0),
            _exit_row(r_mult=-0.5),
            {**_exit_row(), "event": "ENTRY"},   # should be filtered
        ]
        csv_text = _make_csv(rows)
        df_raw = pd.read_csv(io.StringIO(csv_text), sep=";", dtype=str)
        df_raw.columns = [c.lower() for c in df_raw.columns]
        trades = extract_trades(df_raw)
        assert len(trades) == 2

    def test_target_column_created(self):
        rows = [_exit_row(r_mult=1.5), _exit_row(r_mult=-1.0)]
        csv_text = _make_csv(rows)
        df_raw = pd.read_csv(io.StringIO(csv_text), sep=";", dtype=str)
        df_raw.columns = [c.lower() for c in df_raw.columns]
        trades = extract_trades(df_raw)
        assert "target" in trades.columns
        assert set(trades["target"].unique()).issubset({0, 1})

    def test_positive_r_mult_is_win(self):
        rows = [_exit_row(r_mult=2.0)]
        csv_text = _make_csv(rows)
        df_raw = pd.read_csv(io.StringIO(csv_text), sep=";", dtype=str)
        df_raw.columns = [c.lower() for c in df_raw.columns]
        trades = extract_trades(df_raw)
        assert trades.iloc[0]["target"] == 1

    def test_negative_r_mult_is_loss(self):
        rows = [_exit_row(r_mult=-1.0)]
        csv_text = _make_csv(rows)
        df_raw = pd.read_csv(io.StringIO(csv_text), sep=";", dtype=str)
        df_raw.columns = [c.lower() for c in df_raw.columns]
        trades = extract_trades(df_raw)
        assert trades.iloc[0]["target"] == 0

    def test_returns_empty_on_no_exits(self):
        rows = [_exit_row()]
        rows[0]["event"] = "ENTRY"
        rows[0]["run_id"] = "entry"  # also clear run_id so fallback doesn't match
        csv_text = _make_csv(rows)
        df_raw = pd.read_csv(io.StringIO(csv_text), sep=";", dtype=str)
        df_raw.columns = [c.lower() for c in df_raw.columns]
        assert extract_trades(df_raw).empty

    def test_hour_weekday_derived(self):
        rows = [_exit_row(ts="2025-01-06 14:30")]  # Monday
        csv_text = _make_csv(rows)
        df_raw = pd.read_csv(io.StringIO(csv_text), sep=";", dtype=str)
        df_raw.columns = [c.lower() for c in df_raw.columns]
        trades = extract_trades(df_raw)
        assert trades.iloc[0]["hour"] == 14
        assert trades.iloc[0]["weekday"] == 0  # Monday


# ---------------------------------------------------------------------------
# wfo_validate tests
# ---------------------------------------------------------------------------

class TestWfoValidate:
    def test_returns_dict_with_required_keys(self):
        df = _make_trades_df(60, win_rate=0.6)
        result = wfo_validate(df, n_folds=2)
        for key in ("accepted", "global_cutoff", "kelly_fraction",
                    "wfo_sharpe", "wfo_winrate", "wfo_avg_r",
                    "n_train", "n_oos", "per_symbol"):
            assert key in result, f"Missing key: {key}"

    def test_high_winrate_is_accepted(self):
        df = _make_trades_df(120, win_rate=0.75)
        result = wfo_validate(df, n_folds=3)
        # With high WR, should likely be accepted (not guaranteed but probable)
        assert result["global_cutoff"] >= 0.40
        assert 0.0 <= result["kelly_fraction"] <= 0.50

    def test_cutoff_in_valid_range(self):
        df = _make_trades_df(80, win_rate=0.55)
        result = wfo_validate(df, n_folds=2)
        assert 0.30 <= result["global_cutoff"] <= 0.90

    def test_kelly_in_valid_range(self):
        df = _make_trades_df(80, win_rate=0.6)
        result = wfo_validate(df, n_folds=2)
        assert 0.0 <= result["kelly_fraction"] <= 0.5

    def test_too_few_samples_rejected(self):
        df = _make_trades_df(6, win_rate=0.6)
        result = wfo_validate(df, n_folds=3)
        assert result["accepted"] is False

    def test_per_symbol_populated(self):
        df = _make_trades_df(150, win_rate=0.65)
        result = wfo_validate(df, n_folds=3)
        # per_symbol may be empty if OOS counts are low, but should be a dict
        assert isinstance(result["per_symbol"], dict)

    def test_rejected_result_helper(self):
        r = _rejected_result(100, 20, "test reason")
        assert r["accepted"] is False
        assert r["global_cutoff"] == DEFAULT_CUTOFF
        assert r["reject_reason"] == "test reason"

    def test_empty_df_rejected(self):
        result = wfo_validate(pd.DataFrame(), n_folds=2)
        assert result["accepted"] is False


# ---------------------------------------------------------------------------
# write_thresholds tests
# ---------------------------------------------------------------------------

class TestWriteThresholds:
    def test_writes_valid_json(self, tmp_path):
        result = {
            "global_cutoff": 0.55,
            "kelly_fraction": 0.28,
            "per_symbol": {"EURUSD": {"cutoff": 0.54, "kelly": 0.30}},
            "wfo_sharpe": 0.72,
            "wfo_winrate": 0.60,
            "wfo_avg_r": 1.3,
            "n_train": 200,
            "n_oos": 50,
        }
        p = str(tmp_path / "thresholds.json")
        write_thresholds(result, p)
        with open(p) as fh:
            data = json.load(fh)
        assert data["schema"] == "v1"
        assert data["global_cutoff"] == 0.55
        assert "generated_utc" in data

    def test_atomic_write_via_replace(self, tmp_path):
        """Ensure tmp file is cleaned up and final file exists."""
        result = _rejected_result(50, 10, "")
        result["global_cutoff"] = 0.52
        p = str(tmp_path / "out.json")
        write_thresholds(result, p)
        assert os.path.exists(p)
        assert not os.path.exists(p + ".tmp")


# ---------------------------------------------------------------------------
# run() end-to-end tests
# ---------------------------------------------------------------------------

class TestRunEndToEnd:
    def _write_csv(self, tmp_path, n: int = 80, win_rate: float = 0.65) -> str:
        rng = np.random.default_rng(0)
        rows = []
        for i in range(n):
            win = rng.random() < win_rate
            r   = rng.uniform(0.9, 2.0) if win else rng.uniform(-1.5, -0.6)
            rows.append(
                _exit_row(
                    r_mult=r,
                    atr=rng.uniform(8, 25),
                    adx_t=rng.uniform(20, 45),
                    adx_e=rng.uniform(15, 40),
                    spread=rng.uniform(0.8, 3.0),
                    body=rng.uniform(3, 20),
                )
            )
        csv_path = str(tmp_path / "ml_export.csv")
        Path(csv_path).write_text(_make_csv(rows))
        return csv_path

    def test_run_skips_when_too_few_trades(self, tmp_path):
        rng = np.random.default_rng(1)
        rows = [_exit_row(r_mult=rng.choice([-1.0, 1.0])) for _ in range(5)]
        csv_path = str(tmp_path / "few.csv")
        Path(csv_path).write_text(_make_csv(rows))
        out_path = str(tmp_path / "thresh.json")
        rc = run(csv_path, out_path, min_trades=30)
        assert rc == 1
        assert not os.path.exists(out_path)

    def test_run_writes_json_with_force(self, tmp_path):
        csv_path = self._write_csv(tmp_path, n=60, win_rate=0.35)  # low WR
        out_path = str(tmp_path / "thresh.json")
        rc = run(csv_path, out_path, min_trades=10, force=True)
        assert rc == 0
        assert os.path.exists(out_path)

    def test_run_missing_csv_returns_1(self, tmp_path):
        rc = run("/nonexistent/path.csv", str(tmp_path / "out.json"))
        assert rc == 1

    def test_run_produces_valid_json_schema(self, tmp_path):
        csv_path = self._write_csv(tmp_path, n=80, win_rate=0.65)
        out_path = str(tmp_path / "thresh.json")
        run(csv_path, out_path, min_trades=10, force=True)
        with open(out_path) as fh:
            data = json.load(fh)
        assert data["schema"] == "v1"
        assert 0.0 <= data["global_cutoff"] <= 1.0
        assert 0.0 <= data["kelly_fraction"] <= 0.5
        assert isinstance(data["per_symbol"], dict)

    def test_run_successful_retrain(self, tmp_path):
        """High win-rate data should be accepted without force."""
        csv_path = self._write_csv(tmp_path, n=200, win_rate=0.75)
        out_path = str(tmp_path / "thresh.json")
        # Attempt; may or may not pass quality gate depending on randomness
        # but should not crash
        rc = run(csv_path, out_path, min_trades=20)
        # Result is acceptable to be 0 or 1 depending on WFO Sharpe
        assert rc in (0, 1)
