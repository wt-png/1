"""
Unit tests for MSPB EA Entry.mqh reference formulas.

Covers:
  - ComputeSL_SessionAware  (session-aware ATR-multiple stop-loss)
  - FindSwingTP / ComputeTP_Smart  (N-bar swing S/R TP finder)
  - Body-to-range ratio filter  (doji/pinbar rejection)
  - RSI divergence detection logic

All implementations are Python mirrors of the MQL5 logic in MSPB_EA_Entry.mqh.
"""
import math
import pytest

# ---------------------------------------------------------------------------
# Reference helpers
# ---------------------------------------------------------------------------

def pip_size(digits: int) -> float:
    if digits in (5, 3):
        return 10 ** -(digits - 1)
    return 10 ** -digits


def session_sl_atr_mult(hour: int,
                        london_start: int = 8,
                        ny_start: int = 13,
                        ny_end: int = 22,
                        mult_london: float = 1.2,
                        mult_ny: float = 1.2,
                        mult_asia: float = 0.85) -> float:
    """Mirror of session-aware SL ATR multiplier logic in ComputeSL."""
    if london_start <= hour < ny_start:
        return mult_london
    if ny_start <= hour < ny_end:
        return mult_ny
    return mult_asia  # Asia / off-session


def compute_sl_session_aware(entry: float,
                             is_buy: bool,
                             atr_pips: float,
                             hour: int,
                             pip: float,
                             london_start: int = 8,
                             ny_start: int = 13,
                             ny_end: int = 22,
                             mult_london: float = 1.2,
                             mult_ny: float = 1.2,
                             mult_asia: float = 0.85) -> float:
    """Session-aware ComputeSL mirror."""
    mult = session_sl_atr_mult(hour, london_start, ny_start, ny_end,
                               mult_london, mult_ny, mult_asia)
    dist = atr_pips * mult * pip
    return (entry - dist) if is_buy else (entry + dist)


# ---------------------------------------------------------------------------
# Swing TP finder (N-bar swing high/low)
# ---------------------------------------------------------------------------

def find_swing_tp(bars_high: list,
                  bars_low: list,
                  entry: float,
                  is_buy: bool,
                  swing_bars: int = 1,
                  min_rr: float = 1.5,
                  sl: float = 0.0,
                  min_dist_pips: float = 5.0,
                  pip: float = 0.0001) -> float:
    """
    Python mirror of FindSwingTP: scans left-to-right for the nearest
    swing high (for buy) or swing low (for sell) that satisfies min_rr
    and min_dist_pips requirements.

    bars_high / bars_low are ordered oldest-first (bar[0] = oldest).
    Bars at the right end (newest) are excluded from swing detection to
    avoid intra-bar noise — we need at least `swing_bars` bars after the
    candidate to confirm the swing.

    Returns 0.0 if no qualifying level is found.
    """
    n = len(bars_high)
    best_tp = 0.0
    sl_dist = abs(entry - sl)

    for i in range(swing_bars, n - swing_bars):
        if is_buy:
            # swing high: bars_high[i] > all neighbours within swing_bars
            is_swing = all(bars_high[i] > bars_high[i - j] and
                           bars_high[i] > bars_high[i + j]
                           for j in range(1, swing_bars + 1))
            level = bars_high[i]
            if not is_swing: continue
            if level <= entry: continue
            dist_pips = (level - entry) / pip
        else:
            # swing low
            is_swing = all(bars_low[i] < bars_low[i - j] and
                           bars_low[i] < bars_low[i + j]
                           for j in range(1, swing_bars + 1))
            level = bars_low[i]
            if not is_swing: continue
            if level >= entry: continue
            dist_pips = (entry - level) / pip

        if dist_pips < min_dist_pips: continue

        # RR check
        if sl_dist > 0.0:
            rr = dist_pips * pip / sl_dist
            if rr < min_rr: continue

        # Prefer nearest level (smallest distance from entry)
        cur_dist = abs(level - entry)
        if best_tp == 0.0 or cur_dist < abs(best_tp - entry):
            best_tp = level

    return best_tp


def compute_tp_smart(entry: float,
                     sl: float,
                     is_buy: bool,
                     rr: float,
                     bars_high: list,
                     bars_low: list,
                     swing_bars: int = 1,
                     min_rr: float = 1.5,
                     min_dist_pips: float = 5.0,
                     pip: float = 0.0001) -> float:
    """ComputeTP_Smart: try swing S/R, fall back to fixed-RR TP."""
    swing_tp = find_swing_tp(bars_high, bars_low, entry, is_buy,
                             swing_bars, min_rr, sl, min_dist_pips, pip)
    if swing_tp != 0.0:
        return swing_tp
    dist = abs(entry - sl)
    return (entry + dist * rr) if is_buy else (entry - dist * rr)


# ---------------------------------------------------------------------------
# Body-to-range ratio (pinbar/doji filter)
# ---------------------------------------------------------------------------

def body_ratio(open_: float, close_: float,
               high: float, low: float) -> float:
    body  = abs(close_ - open_)
    range_ = high - low
    if range_ <= 0:
        return 0.0
    return body / range_


def body_ratio_allows(open_: float, close_: float,
                      high: float, low: float,
                      min_ratio: float) -> bool:
    return body_ratio(open_, close_, high, low) >= min_ratio


# ---------------------------------------------------------------------------
# RSI divergence detection
# ---------------------------------------------------------------------------

def rsi_divergence_present(is_buy: bool,
                            price_cur: float, price_prev: float,
                            rsi_cur: float, rsi_prev: float,
                            use_high_low: bool = True) -> bool:
    """
    Bullish divergence (buy signal):
      price makes lower low  AND  RSI makes higher low.
    Bearish divergence (sell signal):
      price makes higher high  AND  RSI makes lower high.
    """
    if is_buy:
        price_lower = price_cur < price_prev
        rsi_higher  = rsi_cur > rsi_prev
        return price_lower and rsi_higher
    else:
        price_higher = price_cur > price_prev
        rsi_lower    = rsi_cur < rsi_prev
        return price_higher and rsi_lower


# ===========================================================================
# Tests: ComputeSL_SessionAware
# ===========================================================================

class TestComputeSLSessionAware:
    PIP = 0.0001
    ENTRY = 1.10000
    ATR_PIPS = 12.0

    def test_london_hour_buy(self):
        sl = compute_sl_session_aware(self.ENTRY, True, self.ATR_PIPS, hour=9, pip=self.PIP)
        expected = self.ENTRY - self.ATR_PIPS * 1.2 * self.PIP
        assert sl == pytest.approx(expected)

    def test_ny_hour_sell(self):
        sl = compute_sl_session_aware(self.ENTRY, False, self.ATR_PIPS, hour=14, pip=self.PIP)
        expected = self.ENTRY + self.ATR_PIPS * 1.2 * self.PIP
        assert sl == pytest.approx(expected)

    def test_asia_buy_tighter(self):
        """Asia multiplier 0.85 produces a tighter SL than London 1.2."""
        sl_asia   = compute_sl_session_aware(self.ENTRY, True, self.ATR_PIPS, hour=3, pip=self.PIP)
        sl_london = compute_sl_session_aware(self.ENTRY, True, self.ATR_PIPS, hour=9, pip=self.PIP)
        assert (self.ENTRY - sl_asia) < (self.ENTRY - sl_london)

    def test_sl_always_below_entry_for_buy(self):
        for h in [1, 9, 14, 20]:
            sl = compute_sl_session_aware(self.ENTRY, True, self.ATR_PIPS, hour=h, pip=self.PIP)
            assert sl < self.ENTRY

    def test_sl_always_above_entry_for_sell(self):
        for h in [1, 9, 14, 20]:
            sl = compute_sl_session_aware(self.ENTRY, False, self.ATR_PIPS, hour=h, pip=self.PIP)
            assert sl > self.ENTRY

    def test_boundary_london_start(self):
        sl = compute_sl_session_aware(self.ENTRY, True, self.ATR_PIPS, hour=8, pip=self.PIP)
        expected = self.ENTRY - self.ATR_PIPS * 1.2 * self.PIP
        assert sl == pytest.approx(expected)

    def test_boundary_just_before_london(self):
        sl = compute_sl_session_aware(self.ENTRY, True, self.ATR_PIPS, hour=7, pip=self.PIP)
        expected = self.ENTRY - self.ATR_PIPS * 0.85 * self.PIP
        assert sl == pytest.approx(expected)


# ===========================================================================
# Tests: FindSwingTP / ComputeTP_Smart
# ===========================================================================

class TestFindSwingTP:
    PIP = 0.0001

    def _make_flat_bars(self, n=30, base_high=1.1020, base_low=1.0980):
        highs = [base_high] * n
        lows  = [base_low]  * n
        return highs, lows

    def _inject_swing_high(self, highs, lows, idx, level):
        highs = list(highs)
        highs[idx] = level
        return highs, lows

    def _inject_swing_low(self, highs, lows, idx, level):
        lows = list(lows)
        lows[idx] = level
        return highs, lows

    def test_buy_finds_swing_high_above_entry(self):
        highs, lows = self._make_flat_bars(30)
        highs, lows = self._inject_swing_high(highs, lows, idx=15, level=1.1050)
        entry = 1.1000; sl = 1.0985
        tp = find_swing_tp(highs, lows, entry, is_buy=True, swing_bars=1,
                           min_rr=1.5, sl=sl, min_dist_pips=5.0, pip=self.PIP)
        assert tp == pytest.approx(1.1050)

    def test_sell_finds_swing_low_below_entry(self):
        highs, lows = self._make_flat_bars(30)
        highs, lows = self._inject_swing_low(highs, lows, idx=15, level=1.0950)
        entry = 1.1000; sl = 1.1015
        tp = find_swing_tp(highs, lows, entry, is_buy=False, swing_bars=1,
                           min_rr=1.5, sl=sl, min_dist_pips=5.0, pip=self.PIP)
        assert tp == pytest.approx(1.0950)

    def test_no_qualifying_swing_returns_zero(self):
        highs, lows = self._make_flat_bars(30, base_high=1.1005, base_low=1.0995)
        entry = 1.1000; sl = 1.0985
        tp = find_swing_tp(highs, lows, entry, is_buy=True, swing_bars=1,
                           min_rr=1.5, sl=sl, min_dist_pips=5.0, pip=self.PIP)
        # All swing highs are too close / don't satisfy min_rr
        assert tp == 0.0

    def test_prefers_nearest_qualifying_swing(self):
        highs, lows = self._make_flat_bars(30)
        # Two swing highs: nearer at idx=10, farther at idx=20
        highs[10] = 1.1030
        highs[20] = 1.1060
        entry = 1.1000; sl = 1.0985
        tp = find_swing_tp(highs, lows, entry, is_buy=True, swing_bars=1,
                           min_rr=1.5, sl=sl, min_dist_pips=5.0, pip=self.PIP)
        assert tp == pytest.approx(1.1030)

    def test_min_rr_filters_too_close_swing(self):
        highs, lows = self._make_flat_bars(30)
        highs[10] = 1.1003  # only 3 pips from entry — below min_dist=5 and min_rr=1.5
        entry = 1.1000; sl = 1.0990  # 10-pip SL
        tp = find_swing_tp(highs, lows, entry, is_buy=True, swing_bars=1,
                           min_rr=1.5, sl=sl, min_dist_pips=5.0, pip=self.PIP)
        assert tp == 0.0

    def test_compute_tp_smart_fallback_to_fixed_rr(self):
        highs, lows = self._make_flat_bars(10, base_high=1.1001, base_low=1.0999)
        entry = 1.1000; sl = 1.0985  # 15-pip SL
        tp = compute_tp_smart(entry, sl, True, rr=2.0,
                              bars_high=highs, bars_low=lows,
                              swing_bars=1, min_rr=1.5, min_dist_pips=5.0,
                              pip=self.PIP)
        expected = entry + abs(entry - sl) * 2.0
        assert tp == pytest.approx(expected)

    def test_compute_tp_smart_uses_swing_when_available(self):
        highs, lows = self._make_flat_bars(30)
        highs[15] = 1.1035
        entry = 1.1000; sl = 1.0985  # 15-pip SL  => swing TP RR = 35/15 ≈ 2.33 > 1.5
        tp = compute_tp_smart(entry, sl, True, rr=2.0,
                              bars_high=highs, bars_low=lows,
                              swing_bars=1, min_rr=1.5, min_dist_pips=5.0,
                              pip=self.PIP)
        assert tp == pytest.approx(1.1035)


# ===========================================================================
# Tests: body-to-range ratio filter
# ===========================================================================

class TestBodyRatioFilter:
    def test_normal_candle_passes(self):
        # Body = 8 pips, range = 10 pips => ratio = 0.8
        assert body_ratio_allows(1.1000, 1.1008, high=1.1010, low=1.0999, min_ratio=0.3)

    def test_doji_rejected(self):
        # Body ~ 0, range = 10 pips => ratio ≈ 0 < 0.3
        assert not body_ratio_allows(1.1005, 1.1005, high=1.1010, low=1.1000, min_ratio=0.3)

    def test_pinbar_rejected(self):
        # Body = 1 pip, range = 20 pips => ratio = 0.05 < 0.3
        assert not body_ratio_allows(1.1000, 1.1001, high=1.1020, low=1.1000, min_ratio=0.3)

    def test_full_body_candle_passes(self):
        # Body = range => ratio = 1.0
        assert body_ratio_allows(1.1000, 1.1010, high=1.1010, low=1.1000, min_ratio=0.3)

    def test_exact_threshold_boundary(self):
        # Body = 3 pips, range = 10 pips => ratio = 0.3 (exactly at threshold)
        assert body_ratio_allows(1.1000, 1.1003, high=1.1010, low=1.1000, min_ratio=0.3)

    def test_below_threshold(self):
        # Body = 2 pips, range = 10 pips => ratio = 0.2 < 0.3
        assert not body_ratio_allows(1.1000, 1.1002, high=1.1010, low=1.1000, min_ratio=0.3)

    def test_zero_range_returns_zero_ratio(self):
        assert body_ratio(1.1000, 1.1005, high=1.1000, low=1.1000) == 0.0

    def test_ratio_computed_correctly(self):
        r = body_ratio(1.1000, 1.1006, high=1.1010, low=1.1000)
        assert r == pytest.approx(0.6, rel=1e-9)


# ===========================================================================
# Tests: RSI divergence detection
# ===========================================================================

class TestRSIDivergence:
    def test_bullish_div_price_lower_rsi_higher(self):
        # Classic bullish: price makes lower low, RSI makes higher low
        assert rsi_divergence_present(
            is_buy=True,
            price_cur=1.0990, price_prev=1.1000,  # lower low
            rsi_cur=35.0, rsi_prev=30.0             # higher low
        )

    def test_bearish_div_price_higher_rsi_lower(self):
        # Classic bearish: price makes higher high, RSI makes lower high
        assert rsi_divergence_present(
            is_buy=False,
            price_cur=1.1050, price_prev=1.1000,  # higher high
            rsi_cur=65.0, rsi_prev=70.0            # lower high
        )

    def test_no_bullish_div_price_lower_but_rsi_also_lower(self):
        # Price lower but RSI also lower => NOT bullish divergence
        assert not rsi_divergence_present(
            is_buy=True,
            price_cur=1.0990, price_prev=1.1000,
            rsi_cur=28.0, rsi_prev=30.0  # lower RSI low too
        )

    def test_no_bullish_div_price_same(self):
        assert not rsi_divergence_present(
            is_buy=True,
            price_cur=1.1000, price_prev=1.1000,
            rsi_cur=35.0, rsi_prev=30.0
        )

    def test_no_bearish_div_price_higher_rsi_also_higher(self):
        assert not rsi_divergence_present(
            is_buy=False,
            price_cur=1.1050, price_prev=1.1000,
            rsi_cur=72.0, rsi_prev=70.0  # RSI also higher => no bearish div
        )

    def test_no_bearish_div_price_same(self):
        assert not rsi_divergence_present(
            is_buy=False,
            price_cur=1.1000, price_prev=1.1000,
            rsi_cur=65.0, rsi_prev=70.0
        )

    def test_bullish_div_near_oversold(self):
        assert rsi_divergence_present(
            is_buy=True,
            price_cur=1.0800, price_prev=1.0850,
            rsi_cur=22.0, rsi_prev=20.0
        )

    def test_bearish_div_near_overbought(self):
        assert rsi_divergence_present(
            is_buy=False,
            price_cur=1.2100, price_prev=1.2050,
            rsi_cur=75.0, rsi_prev=80.0
        )
