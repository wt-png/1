# Changelog

All notable changes to MSPB Expert Advisor are documented here.
Format: [Semantic Versioning](https://semver.org/).

---

## [19.0] — 2026-04-19

### Priority 1 — Robustness & Reliability

- **P1-1 OnTradeTransaction primary deal-processor**: `OnTradeTransaction` now calls
  `HistorySelectByPosition(trans.position)` immediately on `DEAL_ADD`, setting a
  freshness flag (`g_dealQHistoryFresh`). `ProcessDealQueue` skips the throttled
  `HistorySelect` call when the flag is valid (< 5 s old), reducing deal-processing
  latency after disconnects.
- **P1-2 Indicator handle revalidation (`Handles_CheckAndReinit`)**: Called from
  `OnTimer` every cycle; detects any `INVALID_HANDLE` per symbol (possible after
  broker reconnect) and reinitialises ATR, ADX, EMA, RSI, and ultra-HTF handles.
- **P1-3 ProcessDealQueue deduplication + wider history window**: `DealSeen_Add`
  ring-buffer prevents a deal from being processed twice. Default lookback expanded
  from 5→7 days (14 on back-off).

### Priority 2 — Entry Quality

- **P2-4 RSI divergence filter (`InpUseDivergenceFilter`, `InpRSI_Period`)**: In
  `EntrySignal_Setup1`, checks for bullish divergence (buy: price lower low + RSI
  higher low) or bearish divergence (sell: price higher high + RSI lower high) on the
  last two closed bars of `entryTF`.
- **P2-5 Dynamic spread/ATR filter (`InpUseDynamicSpreadFilter`, `InpDynSpread_ATRRatio`)**:
  Blocks all setups (Setup1 and Setup2) when `spread / atrPips > InpDynSpread_ATRRatio`.
  Complements the static `InpMaxSpreadPips_FX` check.
- **P2-6 Body-to-range ratio pinbar filter (`InpUseBodyRatioFilter`, `InpMinBodyRatio`)**:
  Rejects doji/pinbar candles in `EntrySignal_Setup1` when `body/range < InpMinBodyRatio`
  (default 0.30). One check on the last closed `entryTF` candle.
- **P2-7 Ultra-HTF bias / three-TF alignment (`InpUseUltraHTFBias`, `InpUltraBiasTF`,
  `InpUltraBiasEMAFast`, `InpUltraBiasEMASlow`)**: Adds a third timeframe EMA cross
  check in `ProcessSymbol`. Requires `ultraFast > ultraSlow` for buys (and vice versa
  for sells) on `InpUltraBiasTF` (default H4). New handles initialised in `OnInit`,
  released in `OnDeinit`, and revalidated in `Handles_CheckAndReinit`.

### Priority 3 — Risk Management

- **P3-8 Weekday filter (`InpBlockMonday`, `InpBlockFriday`, `InpBlockFridayFromHour`)**:
  `WeekdayAllows()` blocks entries on Monday before `InpLondonStartHour` (optional) and
  on Friday from `InpBlockFridayFromHour` onward (optional).
- **P3-9 Weekly loss limit (`InpWeeklyLossLimit_Enable`, `InpWeeklyLossLimit_Pct`)**:
  `WeeklyLoss_UpdateIfNewWeek()` seeds `g_weekEqStart` each Monday; `WeeklyLossAllows()`
  blocks new entries for the remainder of the week when equity drawdown exceeds the
  configured threshold.
- **P3-10 Post-SL bar-based cooldown (`InpPostSL_CooldownBars_Enable`, `InpPostSL_CooldownBars`)**:
  `PostSL_CooldownBars_Trigger()` is called from `Cooldown_Apply` unconditionally on
  SL-exits, recording the bar open-time and a bar countdown. `ProcessSymbol` checks
  `PostSL_CooldownBars_IsActive()` in addition to the existing minute-based cooldown.

### Priority 4 — Tooling & Workflow

- **P4-11 `tools/test_entry_logic.py`**: 28 pytest tests covering `ComputeSL_SessionAware`,
  `FindSwingTP`, body-to-range ratio filter, and RSI divergence detection — all as Python
  reference mirrors of the MQL5 logic.
- **P4-12 `tools/optimize_params.py`**: Grid-search and Optuna-based parameter optimiser;
  evaluates `InpMinADXForEntry`, `InpMinADXTrendFilter`, `InpMinATR_Pips`,
  `InpMaxSpread_Ratio`, `InpSwingSR_MinRR`, `InpTrail_ATR_Mult` against the WFO pipeline.
- **P4-13 `.github/workflows/ci.yml`**: GitHub Actions CI — runs `pytest tools/` on every
  push/PR and verifies `EA_VERSION` in `.mq5` matches the latest `## [X.Y]` section in
  `CHANGELOG.md`.
- **P4-14 Documentation restored**: `docs/INSTALLATION.md` (broker setup, MT5 layout, first-run
  checklist, Telegram integration) and `docs/LIVE_TEST_PROTOCOL.md` (4-phase protocol,
  go/no-go criteria, emergency stop procedures).

### Priority 5 — Advanced

- **P5-15 Adaptive ATR lookback (`InpAdaptiveATR_Enable`, `InpATR_Period_Fast`,
  `InpATR_Period_Mid`)**: `GetCurrentATRPeriod()` returns `InpATR_Period_Fast` in
  `EQ_DEFENSIVE`, `InpATR_Period_Mid` in `EQ_CAUTION`, and `InpATR_Period` in
  `EQ_NEUTRAL`. Applied in `OnInit` and `Handles_CheckAndReinit`.
- **P5-16 Slippage penalty in `OnTester` score (`InpTester_SlippagePenalty`,
  `InpTester_SlippagePenalty_Mult`)**: BUY and SELL slippage pips are accumulated in
  `g_totalSlippagePips` / `g_slippageCount`; `OnTester` deducts
  `mult * avg_slip_pips` from the score.
- **P5-17 Telegram inbound commands (`TG_PollCommands`)**: `OnTimer` calls
  `TG_PollCommands()` which polls `getUpdates` (offset-tracked, non-blocking `timeout=0`).
  Supported: `/pause` (sets `g_tgPaused`), `/resume`, `/status`, `/closeall`. Respects
  `ALLOWED_USER_ID` from the config file.

---



### Fixed
- **`tools/ml_feedback.py`**: Syntax error — `NUMERIC_FEATURES` list was accidentally placed
  inside `_parse_float()` as unreachable code. Moved to module level (before the function).
- **`tools/wfo_pipeline.py`**: Missing `import argparse` caused `NameError` at startup.
- **`MSPB_EA_Entry.mqh` — `GetCurrentSession()`**: Session boundaries were hardcoded to
  hours 0/7/12/17/21. They now read `InpLondonStartHour`, `InpNYStartHour`, and
  `InpNYEndHour` so user-configurable broker offsets are respected.

### Added
- **`InpSwingSR_SwingBars`** (default `2`): Configures how many bars on each side must be
  lower/higher for a candle to qualify as a swing point. Previously hardcoded to 1 (3-bar
  window). Setting `2` gives a 5-bar window, `3` a 7-bar window, etc.
- **`requirements.txt`**: Lists Python dependencies (`xgboost`, `numpy`, `pytest`) for the
  tooling in the `tools/` directory.
- **`CHANGELOG.md`** (this file): Documents version history.
- **`docs/PARAMETERS.md`**: Full reference for all v18.x EA input parameters.

---

## [18.0] — 2026-04-18

### Added — Phase A: Modularisation
- Extracted cohesive logic into dedicated `.mqh` includes (globals remain in `.mq5`):
  - **`MSPB_EA_Risk.mqh`** — `NormalizeVolume*`, `PositionRiskMoney`, `CalcRiskLotsEx`,
    `RiskCap_*`, `PortfolioRiskAllows`, `EqRegime_Update`
  - **`MSPB_EA_ExecQual.mqh`** — `Sanity_*` execution-quality gate functions
  - **`MSPB_EA_Entry.mqh`** — `EntrySignal_Setup1/2`, `BreakPrevHighLow`, session-aware
    `ComputeSL`, `ComputeTP_Smart`, `FindSwingTP`
- **`tools/test_ea_formulas.py`** — 18 pytest tests: lot-sizing, volume floor-normalisation,
  SL/TP math.

### Added — Phase B: Smarter Entry Logic
- **Session-aware SL ATR multiplier**: `InpLondon_SL_ATR_Mult` / `InpAsia_SL_ATR_Mult` scale
  the ATR-based SL distance per session. Asia defaults to `0.85×` (tighter range).
- **Swing S/R TP** (`InpUseSwingSR_TP`): `ComputeTP_Smart()` scans `InpSwingSR_Lookback`
  closed bars on `confirmTF` for the nearest qualifying swing level. Falls back to fixed RR
  if no level is found or `RR < InpSwingSR_MinRR`.
- **`InpSwingSR_MinDistPips`**: Minimum pip distance between entry and S/R TP level.
- **Volatility percentile filter** (`InpVolPctFilter_*`): Blocks entries when current ATR
  ranks below the Nth percentile of the base lookback window.

### Added — Phase C: Python Tooling
- **`tools/ml_feedback.py`**: Reads `ml_export_v2.csv`, trains XGBoost binary classifier
  (win/loss), prints feature importances, and emits EA parameter hints.
- **`tools/wfo_pipeline.py`**: Statistical walk-forward analysis over rolling IS/OOS windows;
  reports Sharpe, PF, win-rate per window; flags instability when OOS Sharpe < 50% of IS.

### Added — Phase D: Execution Quality
- **Partial fill detection**: Compares `ResultVolume()` to requested lots post-fill;
  mismatches logged via `Audit_Log("PARTIAL_FILL", …)`.
- **Slippage tracking**: `SLIPPAGE` ML-export row with `slip_pips` and session tag
  (`Asia`/`London`/`NY`) per trade.
- **Smart order routing** (`InpSmartOrderRoute`): `SmartOrderRoute_IsLiquid()` gates entries
  on `spread / ATR ≤ InpSOR_SpreadATRRatio`.

---

## [17.2] — prior

- Extracted `MSPB_EA_Telegram.mqh`, `MSPB_EA_OrderExec.mqh`, `MSPB_EA_Dashboard.mqh`.
- `EA_VERSION` macro defined; `__TIME__` compatibility guard added.

## [17.1] — prior

- `docs/INSTALLATION.md`: broker-setup + MT5 layout guide.
- `tools/sign_config.py`: HMAC-SHA256 `.set` file signing (30 tests).
- `docs/LIVE_TEST_PROTOCOL.md`: 4-phase forward-test protocol with go/no-go criteria.

## [16.0] — prior

- `MSPB_EA_Risk.mqh` extracted (EqRegime, DailyLoss, ConsecLoss, PartialTP, Sym_RiskWeight).
- Telegram circuit-breaker (`TG_CB_FAIL_THRESHOLD=3`, `TG_CB_MUTE_MINUTES=10`).
- Transactional `RuntimeState_Save` (write-to-tmp + atomic rename).
- Sharpe/Calmar in Monte Carlo; 18 pytest tests; CI version-check + coverage job.

## [15.1] — prior

- `OnTick` symbol-filter: `SymIndexByName(_Symbol)` routes ticks to the correct symbol only.

## [15.0] — prior

- `MSPB_EA_ExecQual.mqh` extracted; `MSPB_EA_JSON.mqh` JSON helpers.
- Telegram replay guard (120 s); `ArrayResize` O(n²) fix.
- `EA_VERSION` macro; CI in `.github/workflows/lint.yml`; `CHANGELOG.md`; `CONTRIBUTING.md`.
