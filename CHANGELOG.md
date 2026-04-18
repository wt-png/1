# Changelog

All notable changes to **MSPB Expert Advisor** are documented in this file.  
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).  
Versioning follows [Semantic Versioning](https://semver.org/).

---

## [15.1] — 2026-04-18

### Changed
- `OnTick` entry loop (when `InpUseTimerForEntries = false`): replaced the unconditional `g_symCount`-wide loop with a `SymIndexByName(_Symbol)` route — only the symbol whose tick fired gets `ProcessSymbol` called on that tick. A full-loop fallback is retained for utility-chart attachments where the chart symbol is not in the trading list. This eliminates redundant entry-logic runs for every non-chart symbol on every incoming tick.

---

## [15.0] — 2026-04-18

### Added
- `EA_VERSION "15.0"` compile-time constant; logged on every `OnInit` together with build date/time.
- `#property version "15.0"` so MetaTrader's Expert list shows the version without opening the source.
- `MSPB_EA_ExecQual.mqh` — execution-quality gate extracted from the monolithic main file.  
  Covers all `ExecQual_*` functions, constants, and global state variables.
- `MSPB_EA_JSON.mqh` — lightweight JSON helpers (`JsonGetLong`, `JsonGetString`, `JsonHasKey`, `JsonGetLongEnd`) for robust Telegram API response parsing.
- Replay-attack guard in `TG_PollCommands`: messages older than `TG_MAX_MSG_AGE_SEC` (120 s) are silently discarded.
- Security warning in `TG_Config_Load`: emits a `[SECURITY WARNING]` `Print` when `InpTGConfigFile` resides in a shared/common folder.
- `.github/workflows/lint.yml` CI workflow: runs on every push/PR and checks include guards, `#property strict`, missing include files, debug markers, `CHANGELOG.md`/`CONTRIBUTING.md` presence, and main-file line-count guard.
- `CONTRIBUTING.md` — module map, symbol-config guide, architecture constants reference, and test instructions.

### Changed
- `ExecQual_AdaptThresholds`: pre-allocates `spreadArr`/`slipArr` to `MAX_SYMBOLS * w` before the sample-collection loop, eliminating the O(n²) `ArrayResize` calls inside the inner loop.
- `TG_PollCommands` now uses `JsonGetLong` / `JsonGetString` from `MSPB_EA_JSON.mqh` instead of inline raw `StringFind` chains.
- `OnInit` Telegram startup message now includes the EA version string.

---

## [14.0] — 2026-04-17

### Added
- `MAX_SYMBOLS 64`, `MAX_POSITION_TRACK 256`, `DEAL_QUEUE_MAX 4096` constants replacing all inline magic numbers.
- `InpMaxRiskMultiplier` — unified upper bound for `/risk` Telegram command and dashboard ± buttons.
- `InpRuntimeStatePersistFile` + `RuntimeState_Save/Load` — persists trading-pause flag, risk multiplier, daily-loss-tripped flag and consecutive-loss counter across EA/MT5 restarts.
- `g_execQual_dirty` flag gates the ExecQual periodic save so the file is only rewritten when state has actually changed.
- `MSPB_EA_Dashboard.mqh` — dashboard code extracted from the main file (~180 lines).

### Changed
- Per-symbol magic numbers (`InpMagicPerSymbol`).
- Configurable equity-regime DD thresholds (`InpEqDD_*`).
- Daily loss limit (`InpDailyLossLimit_*`) and consecutive-loss guard (`InpConsecLoss_*`).
- Partial TP (`InpTP_Partial_*`).
- Configurable session-bucket hour boundaries (`InpExecQual_*EndH`).
- Per-symbol `riskWeight` as column 12 in `SymbolOverrides` CSV.
- ML export extended with 5 new context columns.

---

## [13.0] — earlier

Initial multi-session, multi-symbol, multi-TF EA with execution-quality gate, equity-regime filter, Telegram integration and walk-forward robustness scoring.
