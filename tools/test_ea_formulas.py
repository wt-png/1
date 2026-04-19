"""
Unit tests for MSPB EA core formulas (Python reference implementation).
Tests lot-sizing, SL/TP computation, and volume normalisation logic
mirroring the MQL5 CalcRiskLotsEx / ComputeSL / ComputeTP functions.
"""
import math
import pytest


# ---------------------------------------------------------------------------
# Reference implementations (mirrors MQL5 logic)
# ---------------------------------------------------------------------------

def pip_size(digits: int) -> float:
    """5-digit and 3-digit quotes -> 0.00001/0.001 pip."""
    if digits in (5, 3):
        return 10 ** -(digits - 1)
    return 10 ** -digits


def normalize_volume_floor(vol: float, min_v: float, max_v: float, step: float) -> float:
    """Floor-normalize like NormalizeVolumeFloor in MQL5."""
    if vol < min_v - 1e-12:
        return 0.0
    vol = min(vol, max_v)
    steps = math.floor((vol - min_v) / step + 1e-9)
    out = min_v + steps * step
    if out > vol + 1e-12:
        out -= step
    if out < min_v - 1e-12:
        return 0.0
    return min(out, max_v)


def position_risk_money(entry: float, sl: float, vol: float,
                        tick_val: float, tick_size: float) -> float:
    """Mirror PositionRiskMoney."""
    if tick_val <= 0 or tick_size <= 0:
        return 0.0
    dist = abs(entry - sl)
    if dist <= 0:
        return 0.0
    vpu = tick_val / tick_size
    return dist * vpu * vol


def calc_risk_lots_ex(equity: float, risk_pct: float, risk_mult: float,
                      entry: float, sl: float,
                      tick_val: float, tick_size: float,
                      min_v: float, max_v: float, step: float) -> tuple:
    """Mirror CalcRiskLotsEx (risk-% mode). Returns (lots, risk_money)."""
    risk_budget = equity * (risk_pct / 100.0) * risk_mult
    risk_per_lot = position_risk_money(entry, sl, 1.0, tick_val, tick_size)
    if risk_per_lot <= 0:
        return 0.0, 0.0
    raw_lots = risk_budget / risk_per_lot
    lots = normalize_volume_floor(raw_lots, min_v, max_v, step)
    if lots <= 0:
        return 0.0, 0.0
    risk_money = position_risk_money(entry, sl, lots, tick_val, tick_size)
    return lots, risk_money


def compute_sl(entry: float, is_buy: bool, atr_pips: float,
               sl_atr_mult: float, pip: float) -> float:
    sl_dist = atr_pips * sl_atr_mult * pip
    return (entry - sl_dist) if is_buy else (entry + sl_dist)


def compute_tp(entry: float, sl: float, is_buy: bool, rr: float) -> float:
    dist = abs(entry - sl)
    return (entry + dist * rr) if is_buy else (entry - dist * rr)


# ---------------------------------------------------------------------------
# Tests: normalize_volume_floor
# ---------------------------------------------------------------------------

class TestNormalizeVolumeFloor:
    def test_exact_multiple(self):
        assert normalize_volume_floor(0.10, 0.01, 100.0, 0.01) == pytest.approx(0.10)

    def test_rounds_down(self):
        assert normalize_volume_floor(0.109, 0.01, 100.0, 0.01) == pytest.approx(0.10)

    def test_below_min_returns_zero(self):
        assert normalize_volume_floor(0.005, 0.01, 100.0, 0.01) == 0.0

    def test_clamps_to_max(self):
        assert normalize_volume_floor(200.0, 0.01, 100.0, 0.01) == pytest.approx(100.0)

    def test_micro_lot_step(self):
        # 0.001 step brokers
        assert normalize_volume_floor(0.0037, 0.001, 100.0, 0.001) == pytest.approx(0.003)


# ---------------------------------------------------------------------------
# Tests: position_risk_money
# ---------------------------------------------------------------------------

class TestPositionRiskMoney:
    def test_eurusd_basic(self):
        # 10 pip SL, 1 lot, 1-pip tick_val=10, tick_size=0.00001 -> vpu=1_000_000
        # Actually let's use standard EURUSD: tick_val=1 USD per 0.00001, vol=1 -> vpu=100000
        # dist=0.0010 (10 pips of 0.0001), vpu=100000 -> 100 USD
        risk = position_risk_money(1.1000, 1.0990, 1.0, 1.0, 0.00001)
        assert risk == pytest.approx(100.0, rel=1e-6)  # 0.001 * 100000 * 1 lot = 100 USD

    def test_zero_sl_returns_zero(self):
        assert position_risk_money(1.10, 1.10, 1.0, 1.0, 0.00001) == 0.0

    def test_zero_tickval_returns_zero(self):
        assert position_risk_money(1.10, 1.09, 1.0, 0.0, 0.00001) == 0.0


# ---------------------------------------------------------------------------
# Tests: calc_risk_lots_ex
# ---------------------------------------------------------------------------

class TestCalcRiskLotsEx:
    # Standard EURUSD params
    _tv, _ts = 1.0, 0.00001  # tick_val, tick_size -> vpu = 100000

    def test_basic_sizing(self):
        # equity=10000, risk=1%, 10-pip SL -> budget=100, riskPerLot=100 -> 1.0 lot
        lots, risk = calc_risk_lots_ex(
            equity=10000, risk_pct=1.0, risk_mult=1.0,
            entry=1.1000, sl=1.0990,
            tick_val=self._tv, tick_size=self._ts,
            min_v=0.01, max_v=100.0, step=0.01)
        assert lots == pytest.approx(1.0)
        assert risk == pytest.approx(100.0, rel=1e-4)  # budget = 10000 * 1% = 100 USD

    def test_risk_mult_scales_down(self):
        # EQ_CAUTION: risk_mult=0.7 -> 0.7x lots
        lots, _ = calc_risk_lots_ex(
            equity=10000, risk_pct=1.0, risk_mult=0.7,
            entry=1.1000, sl=1.0990,
            tick_val=self._tv, tick_size=self._ts,
            min_v=0.01, max_v=100.0, step=0.01)
        assert lots == pytest.approx(0.70)

    def test_never_exceeds_risk_budget(self):
        lots, risk = calc_risk_lots_ex(
            equity=5000, risk_pct=2.0, risk_mult=1.0,
            entry=1.1000, sl=1.0990,
            tick_val=self._tv, tick_size=self._ts,
            min_v=0.01, max_v=100.0, step=0.01)
        budget = 5000 * 0.02
        assert risk <= budget + 1e-6

    def test_zero_risk_mult_returns_zero(self):
        lots, risk = calc_risk_lots_ex(
            equity=10000, risk_pct=1.0, risk_mult=0.0,
            entry=1.1000, sl=1.0990,
            tick_val=self._tv, tick_size=self._ts,
            min_v=0.01, max_v=100.0, step=0.01)
        assert lots == 0.0

    def test_small_account_floors_to_min_lot(self):
        # very small equity: budget < min lot risk -> 0 lots
        lots, _ = calc_risk_lots_ex(
            equity=100, risk_pct=0.5, risk_mult=1.0,
            entry=1.1000, sl=1.0990,
            tick_val=self._tv, tick_size=self._ts,
            min_v=0.01, max_v=100.0, step=0.01)
        # budget=0.5 USD, riskPerLot=100 -> rawLots=0.005 < 0.01 -> 0
        assert lots == 0.0


# ---------------------------------------------------------------------------
# Tests: ComputeSL / ComputeTP
# ---------------------------------------------------------------------------

class TestComputeSLTP:
    def test_buy_sl_below_entry(self):
        # entry=1.1, ATR=10 pips, mult=1.5, pip=0.0001
        sl = compute_sl(1.10000, True, 10.0, 1.5, 0.0001)
        assert sl == pytest.approx(1.10000 - 10.0 * 1.5 * 0.0001)
        assert sl < 1.10000

    def test_sell_sl_above_entry(self):
        sl = compute_sl(1.10000, False, 10.0, 1.5, 0.0001)
        assert sl > 1.10000

    def test_tp_rr_ratio(self):
        entry, sl = 1.10000, 1.09850  # 15-pip SL
        tp = compute_tp(entry, sl, True, 2.0)
        sl_dist = abs(entry - sl)
        tp_dist = abs(tp - entry)
        assert tp_dist == pytest.approx(2.0 * sl_dist, rel=1e-9)

    def test_sell_tp_below_entry(self):
        entry, sl = 1.10000, 1.10150
        tp = compute_tp(entry, sl, False, 1.5)
        assert tp < entry

    def test_symmetric_roundtrip(self):
        # buy SL -> TP: tp - entry == rr * (entry - sl)
        entry = 1.25000
        atr_pips = 12.0
        pip = 0.0001
        sl = compute_sl(entry, True, atr_pips, 1.2, pip)
        tp = compute_tp(entry, sl, True, 2.0)
        expected_tp = entry + 2.0 * atr_pips * 1.2 * pip
        assert tp == pytest.approx(expected_tp)
