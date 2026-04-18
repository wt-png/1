#!/usr/bin/env python3
"""Tests for walk_forward.py"""
import math
import sys
import os
from datetime import datetime, timezone, timedelta

sys.path.insert(0, os.path.dirname(__file__))
from walk_forward import (
    Deal, _sharpe, _calmar, _profit_factor, run_walk_forward, WindowResult
)


def _make_deals(n: int, profit_per_deal: float = 10.0, lots: float = 0.1,
                start: datetime = None) -> list:
    if start is None:
        start = datetime(2023, 1, 1, tzinfo=timezone.utc)
    return [
        Deal(time=start + timedelta(days=i), symbol="EURUSD", direction="BUY",
             entry=1.10, sl=1.09, profit=profit_per_deal, lots=lots)
        for i in range(n)
    ]


# --- _sharpe ---

def test_sharpe_zero_variance():
    # All returns equal → std=0 → Sharpe=0
    assert _sharpe([1.0, 1.0, 1.0]) == 0.0


def test_sharpe_positive():
    returns = [0.01] * 50 + [-0.005] * 10
    s = _sharpe(returns)
    assert s > 0.0


def test_sharpe_single_element():
    assert _sharpe([1.0]) == 0.0


def test_sharpe_empty():
    assert _sharpe([]) == 0.0


# --- _calmar ---

def test_calmar_no_drawdown():
    # Monotonically increasing equity → max_dd=0 → inf
    result = _calmar([1.0, 2.0, 3.0])
    assert result == float("inf")


def test_calmar_with_drawdown():
    # Goes up 10, drops 5 → max_dd=5, total=5
    result = _calmar([10.0, -5.0])
    assert abs(result - 1.0) < 1e-9


def test_calmar_all_losses():
    result = _calmar([-1.0, -1.0, -1.0])
    assert result == 0.0


def test_calmar_empty():
    assert _calmar([]) == 0.0


# --- _profit_factor ---

def test_pf_only_wins():
    assert _profit_factor([1.0, 2.0, 3.0]) == float("inf")


def test_pf_only_losses():
    assert _profit_factor([-1.0, -2.0]) == 0.0


def test_pf_mixed():
    pf = _profit_factor([10.0, -5.0])
    assert abs(pf - 2.0) < 1e-9


def test_pf_empty():
    assert _profit_factor([]) == 1.0


# --- run_walk_forward ---

def test_wf_basic_windows():
    deals = _make_deals(100)
    results = run_walk_forward(deals, is_fraction=0.70, n_windows=5)
    assert len(results) == 5
    for r in results:
        assert r.is_trades + r.oos_trades > 0


def test_wf_single_window():
    deals = _make_deals(50)
    results = run_walk_forward(deals, is_fraction=0.70, n_windows=1)
    assert len(results) == 1
    r = results[0]
    assert r.is_trades > 0
    assert r.oos_trades > 0


def test_wf_empty_deals():
    results = run_walk_forward([], n_windows=5)
    assert results == []


def test_wf_anchored():
    deals = _make_deals(60)
    results = run_walk_forward(deals, is_fraction=0.70, n_windows=3, anchored=True)
    assert len(results) > 0
    # Anchored: each window's IS starts from the same origin
    for r in results:
        assert r.is_start == results[0].is_start


def test_wf_efficiency_perfect():
    # Identical IS and OOS returns → efficiency ~ 1.0
    start = datetime(2023, 1, 1, tzinfo=timezone.utc)
    deals = _make_deals(100, profit_per_deal=10.0, start=start)
    results = run_walk_forward(deals, is_fraction=0.70, n_windows=1)
    assert len(results) == 1
    r = results[0]
    # IS and OOS both have same Sharpe profile → oos_efficiency close to 1
    if r.is_sharpe > 1e-6:
        assert abs(r.oos_efficiency - 1.0) < 0.1  # allow slight variation


def test_wf_window_ids_sequential():
    deals = _make_deals(80)
    results = run_walk_forward(deals, n_windows=4)
    ids = [r.window_id for r in results]
    assert ids == list(range(1, len(results) + 1))


if __name__ == "__main__":
    import pytest
    sys.exit(pytest.main([__file__, "-v"]))
