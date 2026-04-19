# MSPB Expert Advisor — Parameter Reference

Full reference for all input parameters introduced or updated through v20.0.
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

## Candle Body Ratio Filter (v19.0)

Blocks entries where the candle body is too small relative to its total range (indecision / doji candles).

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpUseBodyRatioFilter` | bool | `false` | Enable the body ratio filter. |
| `InpMinBodyRatio` | double | `0.30` | Minimum required body fraction (body / total range). Range: 0.0–1.0. Entry is blocked if the signal candle's body is below this fraction. |

**Tuning guidance**: `0.30` blocks obvious dojis. Raise to `0.40–0.50` on M5 for higher-conviction signals; keep at `0.20–0.25` on H1+ where wicks are naturally larger.

---

## Dynamic Spread Filter (v19.0)

Blocks entries when the real-time spread is unusually wide relative to ATR, complementing the static `InpMaxSpreadPips_*` caps.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpUseDynamicSpreadFilter` | bool | `false` | Enable the dynamic spread filter. |
| `InpDynSpread_ATRRatio` | double | `0.15` | Maximum allowed `spread / ATR` ratio. Entry is blocked if `spread > ATR × ratio`. |

---

## RSI Divergence Filter (v19.0)

Requires RSI divergence confirmation before allowing a signal. Prevents entries that lack momentum backing.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpUseDivergenceFilter` | bool | `false` | Enable RSI divergence requirement. |
| `InpRSI_Period` | int | `14` | RSI lookback period used for divergence detection. |

---

## Ultra-HTF Bias (v19.0)

Adds a second, higher-timeframe bias layer above `InpBiasTF`. Both HTF and ultra-HTF must align for an entry to be allowed.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpUseUltraHTFBias` | bool | `false` | Enable ultra-HTF bias filter. |
| `InpUltraBiasTF` | ENUM_TIMEFRAMES | `PERIOD_H4` | Timeframe for the ultra-HTF EMA bias. Must be higher than `InpBiasTF`. |
| `InpUltraBiasEMAFast` | int | `50` | Fast EMA period on the ultra-HTF. |
| `InpUltraBiasEMASlow` | int | `200` | Slow EMA period on the ultra-HTF. Bias is bullish when Fast > Slow. |

---

## Weekday Filters (v19.0)

Blocks entries on specific days or day-parts that historically show poor performance.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpBlockMonday` | bool | `false` | Block all entries on Monday from midnight to `InpLondonStartHour` (Asia/pre-London open). |
| `InpBlockFriday` | bool | `false` | Block entries on Friday from `InpBlockFridayFromHour` onwards (avoids late-Friday illiquidity). |
| `InpBlockFridayFromHour` | int | `17` | Broker server hour (0-23) from which Friday entries are blocked when `InpBlockFriday = true`. |

---

## Weekly Loss Limit (v19.0)

Stops new entries for the remainder of the week once the account equity has drawn down by a configurable percentage from the Monday open.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpWeeklyLossLimit_Enable` | bool | `false` | Enable the weekly drawdown circuit-breaker. |
| `InpWeeklyLossLimit_Pct` | double | `5.0` | Percentage of Monday equity. If current equity falls below `mondayEquity × (1 − pct/100)`, new entries are blocked until the next Monday. |

---

## Post-SL Bar Cooldown (v19.0)

Adds a bar-count cooldown after a stop-loss hit, stacking on top of the existing minute-based cooldown.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpPostSL_CooldownBars_Enable` | bool | `false` | Enable bar-count cooldown after SL. |
| `InpPostSL_CooldownBars` | int | `3` | Number of closed bars on the entry timeframe to block entries after a SL hit. |

---

## Adaptive ATR Period (v19.0)

Shortens the ATR period automatically in high-risk equity regimes so that the EA reacts faster to changing volatility.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpAdaptiveATR_Enable` | bool | `false` | Enable adaptive ATR period switching. |
| `InpATR_Period_Fast` | int | `5` | ATR period used when equity is in `EQ_DEFENSIVE` regime (most reactive). |
| `InpATR_Period_Mid` | int | `10` | ATR period used when equity is in `EQ_CAUTION` regime. Normal regime uses `InpATR_Period`. |

---

## ML Entry Gate (v20.0 — A1)

Loads a score threshold from a JSON file generated by `tools/export_model_thresholds.py` and blocks entries when the current ML score falls below that threshold.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpUseMLEntryGate` | bool | `false` | Enable the ML entry gate. When `true`, entries are blocked unless the ML model scores the setup ≥ `InpML_MinScore`. |
| `InpMLGateFile` | string | `"ml_entry_threshold.json"` | Path to the JSON threshold file produced by `tools/export_model_thresholds.py`. |
| `InpML_MinScore` | double | `0.55` | Minimum ML score required to allow an entry (range 0–1). Typically 0.50–0.65. |
| `InpMLGate_UseCommonFolder` | bool | `false` | When `true`, the threshold file is read from the MT5 common files folder instead of the data folder. |

**Workflow**: Run `python tools/export_model_thresholds.py --csv ml_export_v2.csv` after each re-train. Copy `ml_entry_threshold.json` to the MT5 data or common folder. The EA hot-reloads the file without restart.

---

## TP Ladder — 3-Level Partial Close (v20.0 — A2)

Scales out of a position in three stages: two fixed-R partial closes followed by an ATR trailing stop on the remainder.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpTP_Ladder_Enable` | bool | `false` | Enable the 3-level TP ladder. When `false`, the EA uses fixed-RR TP (`InpTP_RR`). |
| `InpTP_R1_ClosePct` | double | `33.0` | Percentage of the position to close at the first TP level. |
| `InpTP_R1_R` | double | `1.0` | R-multiple at which the first partial close triggers (e.g. `1.0` = 1R profit). |
| `InpTP_R2_ClosePct` | double | `33.0` | Percentage of the position to close at the second TP level. |
| `InpTP_R2_R` | double | `2.0` | R-multiple at which the second partial close triggers. |
| `InpTP_R3_Trail_Mult` | double | `1.5` | ATR multiplier for the trailing stop on the remaining position after the second partial close. |

**Interaction**: The TP ladder replaces the single `InpTP_RR` target. Break-even and `InpUseATRTrailing` still apply to the remaining portion after R1.

---

## Chandelier Exit (v20.0 — A3)

Replaces the fixed ATR trailing stop with a Chandelier Exit, which trails from the highest high (long) or lowest low (short) of the lookback period.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpUseChandelierExit` | bool | `false` | Enable Chandelier Exit trailing. When `false`, the normal `InpTrail_ATR_Mult` trailing stop is used. |
| `InpChandelier_Period` | int | `22` | Lookback bars for the highest-high / lowest-low anchor. |
| `InpChandelier_Mult` | double | `3.0` | ATR multiplier for the chandelier distance. Stop = `HH − ATR × mult` for longs. |

---

## Pyramiding (v20.0 — A4)

Adds one additional lot to a winning position after the first partial TP is taken and break-even is locked.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpUsePyramiding` | bool | `false` | Enable pyramiding. Requires `InpTP_Ladder_Enable = true` (pyramid add triggers after R1 close + BE). |
| `InpPyramid_MaxAdds` | int | `1` | Maximum number of pyramid adds per original position chain. |
| `InpPyramid_RiskPct` | double | `0.5` | Risk percentage for each pyramid add, applied to current equity (should be lower than `InpRiskPercent`). |

---

## Auto-Disable on Negative Expectancy (v20.0 — B6)

Automatically disables a symbol for the current week when its recent trade expectancy turns negative, and re-enables it at the start of the next week.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpAutoDisable_Enable` | bool | `false` | Enable per-symbol automatic disabling. |
| `InpAutoDisable_Lookback` | int | `30` | Number of most-recent closed trades per symbol used to calculate expectancy. Minimum recommended: 20. |

---

## Kelly Position Sizing (v20.0 — B7)

Scales the lot size up or down using a half-Kelly fraction derived from recent win-rate and average win/loss ratio per symbol.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpUseKellyScaling` | bool | `false` | Enable Kelly lot scaling. The base lot size from risk-percent sizing is multiplied by the Kelly factor. |
| `InpKelly_Lookback` | int | `20` | Number of most-recent closed trades per symbol used to calculate win-rate and expectancy. |
| `InpKelly_Fraction` | double | `0.5` | Kelly fraction applied to the full Kelly result. `0.5` = half-Kelly (recommended for live trading). |
| `InpKelly_MinMult` | double | `0.25` | Minimum Kelly multiplier (floor). Prevents excessively small lots. |
| `InpKelly_MaxMult` | double | `2.0` | Maximum Kelly multiplier (cap). Prevents over-leveraging after a streak. |

**Safety note**: Use half-Kelly (`0.5`) or lower. Full Kelly requires perfect edge estimation and leads to large variance.

---

## Limit Order on Spread Block (v20.0 — C8)

When the spread is too wide to accept a market order, the EA places a pending limit order at the intended entry price instead of skipping the signal entirely.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpUseLimitOnSpreadBlock` | bool | `false` | Enable pending limit order fallback when spread blocks entry. |
| `InpLimitOrderTTL_Min` | int | `5` | Time-to-live in minutes before the pending limit order is cancelled if not filled. |

---

## Entry Delay (v20.0 — C9)

Adds a configurable pause between signal confirmation and order submission, allowing the spread to normalise after news spikes or fast-market conditions.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpEntryDelay_Ms` | int | `0` | Delay in milliseconds before placing the order after a signal is confirmed. `0` = disabled. Example: `1500` = 1.5 seconds. |

---

## Weekly Symbol Rank (v20.0 — D10)

Enables only the top-N symbols by recent Sharpe ratio each week, using a ranking file generated by `tools/rank_symbols.py`.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpUseWeeklySymbolRank` | bool | `false` | Enable weekly symbol ranking. Symbols ranked below `InpSymbolRank_TopN` will have entries blocked. |
| `InpSymbolRankFile` | string | `"ml_symbol_rank.csv"` | Path to the ranking CSV produced by `tools/rank_symbols.py`. |
| `InpSymbolRank_TopN` | int | `3` | Number of top-ranked symbols to keep active each week. |
| `InpSymbolRank_UseCommonFolder` | bool | `false` | When `true`, reads the rank file from the MT5 common folder. |

**Workflow**: Run `python tools/rank_symbols.py --csv ml_export_v2.csv` weekly (or via the CI cron job). Copy `ml_symbol_rank.csv` to the MT5 data folder.

---

## Correlation Spread Preference (v20.0 — D11)

Changes the behaviour of the correlation guard: instead of blocking the new entry outright when a correlated position already exists, the EA prefers the symbol with the lower current spread.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpCorrSpreadPrefer` | bool | `false` | When `true`, a signal is allowed on the lower-spread symbol in a correlated pair even if the other is already open. When `false` (original behaviour), the entry is blocked. |

---

## OrderSend Retry on Transient Errors (v20.1)

Retries the `OrderSend` call for position-close operations when a transient broker error is returned (requote, timeout, price off, connection issue), refreshing the price before each retry.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `InpOrderRetryTransient` | bool | `true` | Enable retry on transient retcodes for close orders. |
| `InpOrderRetryMaxRetries` | int | `2` | Maximum additional send attempts (total attempts = 1 + this value). |
| `InpOrderRetrySleepMS` | int | `500` | Delay in milliseconds between retry attempts. |

**Note**: This complements the existing `InpSLModRetryTransient` / `InpSLModMaxRetries` mechanism which applies only to SL/TP modifications.

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

---

### `tools/export_model_thresholds.py` (v20.0 — A1)

Exports the optimal ML entry-score threshold to a JSON file consumed by the EA's ML gate.

**Usage**:
```bash
python tools/export_model_thresholds.py --csv ml_export_v2.csv [--output ml_entry_threshold.json]
```

---

### `tools/analyse_mae_mfe.py` (v20.0 — B5)

Analyses Maximum Adverse Excursion (MAE) and Maximum Favourable Excursion (MFE) from the ML export CSV. Identifies whether SL is too tight (trades stopped out before reaching target) or TP is too conservative (trades reversed before reaching SL).

**Usage**:
```bash
python tools/analyse_mae_mfe.py --csv ml_export_v2.csv [--output mae_mfe_report.txt]
```

---

### `tools/rank_symbols.py` (v20.0 — D10)

Ranks symbols in the ML export by recent Sharpe ratio and outputs a ranking CSV for the EA's weekly symbol filter.

**Usage**:
```bash
python tools/rank_symbols.py --csv ml_export_v2.csv [--output ml_symbol_rank.csv] [--lookback-days 30]
```
