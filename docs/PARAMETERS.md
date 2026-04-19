# MSPB Expert Advisor — Parameter Reference

Full reference for all input parameters introduced or updated in v18.x.
Parameters are grouped by functional area.

---

## Smart Order Routing (v18.0)

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpSmartOrderRoute` | bool | `false` | When enabled, market orders are only placed when `spread / ATR ≤ InpSOR_SpreadATRRatio`. Reduces fills during wide-spread conditions. |
| `InpSOR_SpreadATRRatio` | double | `0.15` | Maximum allowed spread-to-ATR ratio. A value of `0.15` means spread must be ≤ 15% of the current ATR. |

---

## Volatility Percentile Filter (v18.0)

Blocks entry signals when the market is in an abnormally low-volatility regime.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpVolPctFilter_Enable` | bool | `false` | Enable the volatility percentile filter. |
| `InpVolPctFilter_Period` | int | `20` | Short ATR period used as the "current volatility" measurement. |
| `InpVolPctFilter_Base` | int | `100` | Longer ATR period used as the baseline for percentile ranking. |
| `InpVolPctFilter_Threshold` | double | `30.0` | Entry is blocked when `ATR(Period)` ranks below this percentile of `ATR(Base)`. Range: 0–100. |

**Tuning guidance**: A threshold of 30 blocks entries in the bottom 30% of historical volatility. Raise to 40–50 during very choppy markets; lower to 10–20 on instruments with more consistent volatility.

---

## Session Filter & Session-Aware SL (v18.0)

Controls which trading sessions are active and adjusts SL width per session.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpUseSessions` | bool | `false` | Enable session filtering. When `false`, the EA trades 24/5. |
| `InpLondonStartHour` | int | `7` | London session open (broker server time, 0-23). Also defines where Asia session ends. |
| `InpLondonEndHour` | int | `17` | London session close (broker server time). |
| `InpNYStartHour` | int | `12` | New York session open (broker server time). Also marks start of London/NY overlap. |
| `InpNYEndHour` | int | `21` | New York session close (broker server time). |
| `InpLondon_SL_ATR_Mult` | double | `1.0` | Multiplier applied to the base ATR SL during London session. `1.0` = unchanged. |
| `InpAsia_SL_ATR_Mult` | double | `0.85` | Multiplier applied to the base ATR SL during Asia session. `0.85` = 15% tighter SL, reflecting lower average volatility. |

**Important**: `GetCurrentSession()` uses `InpLondonStartHour`, `InpNYStartHour`, and `InpNYEndHour`. Adjust these for your broker's GMT offset. For a broker on GMT+2 (EET), London typically opens at 09:00 server time → set `InpLondonStartHour = 9`.

Session mapping:
- `Asia` — midnight to `InpLondonStartHour`
- `London` — `InpLondonStartHour` to `InpNYStartHour`
- `NY` (incl. London/NY overlap) — `InpNYStartHour` to `InpNYEndHour`
- `Off-session` — `InpNYEndHour` to midnight

---

## Swing S/R Take-Profit (v18.0 / v18.1)

Uses nearest swing high or swing low on the confirmation timeframe as the TP target.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpUseSwingSR_TP` | bool | `false` | Enable swing S/R TP mode. When disabled, fixed-RR TP (`InpTP_RR`) is used. |
| `InpSwingSR_Lookback` | int | `30` | Number of closed bars on `confirmTF` to scan for swing points. |
| `InpSwingSR_MinRR` | double | `1.2` | Minimum risk:reward required to accept an S/R level as TP. If the found level gives `RR < 1.2`, falls back to fixed-RR TP. |
| `InpSwingSR_MinDistPips` | double | `3.0` | Minimum distance in pips between the entry price and the S/R TP level. Prevents targeting a level that is too close to entry. |
| `InpSwingSR_SwingBars` | int | `2` | *(v18.1)* Number of bars on each side that must be lower (for swing high) or higher (for swing low). `1` = 3-bar window, `2` = 5-bar window, `3` = 7-bar window. Higher values find only major swings. |

**Tuning guidance for `InpSwingSR_SwingBars`**:
- `1` — sensitive, picks up minor pivots (noisy on lower timeframes)
- `2` — balanced default; good for H1–H4 confirmation timeframes
- `3` or more — major swing points only; fewer TP targets found but higher quality

---

## Python Tooling

### `tools/ml_feedback.py`

Trains an XGBoost classifier on the EA's `ml_export_v2.csv` to identify which features most predict win/loss, and outputs parameter hints.

**Usage**:
```bash
pip install -r requirements.txt
python tools/ml_feedback.py --csv path/to/ml_export_v2.csv [--output suggestions.txt]
```

**Output**: Feature importance ranking + suggested EA parameter adjustments printed to console and written to `--output` file.

**Minimum data**: 30 labelled trades. Re-run periodically as trade history grows.

---

### `tools/wfo_pipeline.py`

Statistical walk-forward analysis over rolling IS/OOS windows. Does not require MetaTrader; uses the closed-trade CSV exported by the EA.

**Usage**:
```bash
python tools/wfo_pipeline.py --csv path/to/ml_export_v2.csv [--windows 6] [--oos-ratio 0.3]
```

**Options**:

| Flag | Default | Description |
|---|---|---|
| `--windows` | `6` | Number of walk-forward windows to split the history into. |
| `--oos-ratio` | `0.3` | Fraction of each window reserved for out-of-sample evaluation. |

**Stability criterion**: A window is "stable" when OOS Sharpe ≥ 50% of IS Sharpe **and** OOS profit factor ≥ 1.0. If fewer than 60% of windows pass, the strategy is flagged as potentially overfit or regime-sensitive.
