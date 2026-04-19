# Changelog

All notable changes to MSPB Expert Advisor are documented here.
Format: [Semantic Versioning](https://semver.org/).

---

## [18.1] — 2026-04-19

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
