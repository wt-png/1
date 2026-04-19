# Contributing to MSPB Expert Advisor

## Repository layout

| File | Purpose |
|---|---|
| `MSPB_Expert_Advisor.mq5` | Main EA — `OnInit`, `OnTick`, `OnTimer`, `OnDeinit`, entry logic, position management |
| `MSPB_EA_Risk.mqh` | Risk module — equity regime filter, daily loss limit, consecutive-loss guard, partial-TP tracking |
| `MSPB_EA_ExecQual.mqh` | Execution-quality gate — spread/slippage tracking, session-bucket gate, adaptive threshold learning |
| `MSPB_EA_Dashboard.mqh` | On-chart dashboard — object creation/deletion, button handlers, display update |
| `MSPB_EA_Telegram.mqh` | Telegram Bot API — config loading, outgoing messages, rate limiting, circuit-breaker, incoming command polling |
| `MSPB_EA_JSON.mqh` | Lightweight JSON read helpers used by the Telegram module |
| `MSPB_EA_ML.mqh` | Machine-learning CSV export (`ML_WriteRowV2`) |
| `MSPB_EA_News.mqh` | News-filter integration (economic calendar guard) |
| `MSPB_EA_OrderExec.mqh` | Order execution helpers — `IsTransientRetcode`, `SendSLTPModifyByTicket`, `ModifySL_Safe`, `ClosePositionByTicketSafe` |
| `MSPB_EA_PositionManager.mqh` | Position manager — deal-queue ring-buffer, position closure tracker, `ProcessDealQueue` |
| `MSPB_EA_SymbolConfig.mqh` | Symbol overrides — `SymbolOverrides` struct, CSV load/hot-reload, convenience getters |
| `MSPB_EA_UnitTests.mq5` | Standalone unit-test script — compile and run in MetaTrader Strategy Tester |
| `.github/workflows/lint.yml` | CI workflow — MQL5 lint + Python tests on every push/PR (see below) |
| `tools/monte_carlo_analysis.py` | Monte Carlo simulation for trade-sequence analysis (max DD, Sharpe, Calmar) |
| `tools/test_monte_carlo.py` | pytest unit tests for the Monte Carlo tool |
| `tools/walk_forward.py` | Walk-forward IS/OOS validator — reads ML export CSV, computes per-window Sharpe/Calmar/PF |
| `tools/test_walk_forward.py` | pytest unit tests for the walk-forward tool |
| `tools/sign_config.py` | HMAC-SHA256 signing and verification of `.set` config files |
| `tools/test_sign_config.py` | pytest unit tests for sign_config (30 tests) |
| `docs/INSTALLATION.md` | Full deployment and installation guide |
| `docs/LIVE_TEST_PROTOCOL.md` | 4-phase live forward-test protocol, go/no-go criteria, review cycle template |
| `CHANGELOG.md` | Version history (Keep a Changelog format) |

---

## Architecture constants

These constants are defined at the top of `MSPB_Expert_Advisor.mq5`.  
**Do not change them at runtime** — they control fixed-size static arrays.

| Constant | Default | Meaning |
|---|---|---|
| `MAX_SYMBOLS` | `64` | Maximum number of concurrently tracked instruments.  Raise if you need more than 64 symbols; all dependent array sizes scale automatically. |
| `MAX_POSITION_TRACK` | `256` | Capacity of the position-tracking ring buffer.  Increase if you run many simultaneous positions. |
| `DEAL_QUEUE_MAX` | `4096` | Capacity of the deal-capture ring buffer.  Increase only if `DEALQ_OVERFLOW` messages appear in the log. |
| `EXEC_QUAL_MAX_WINDOW` | `256` | Rolling-window depth per (symbol, session-bucket).  Stored in static memory; raising it increases RAM usage by `MAX_SYMBOLS × EXEC_QUAL_BUCKETS × value × 2 × 8` bytes. |
| `EA_VERSION` | `"15.0"` | Semantic version string.  Update this and `#property version` together whenever a release is tagged. |

---

## Adding a new instrument

1. Append the symbol name to `InpSymbols` (comma-separated, e.g. `"EURUSD,GBPUSD,USDJPY"`).
2. Optionally add a row to the `SymbolOverrides` CSV file to set per-symbol risk weight, spread limit, ADX/ATR thresholds, etc.  
   Column order (all optional, use `0` or empty to inherit global defaults):
   ```
   sym, maxSpreadPips, minATR, minADXTrend, minADXEntry, minBodyPips,
   slATRMult, tpATRMult, riskPct, maxRiskMoney, allowPartialTP,
   slipLimitPips, riskWeight
   ```
3. Increase `MAX_SYMBOLS` if you exceed 64 symbols and recompile.

---

## How to add a new symbol override column

The `SymbolOverrides` struct and its CSV parser live in `MSPB_Expert_Advisor.mq5`.  
Follow these steps to add a new per-symbol parameter (e.g. `minVolume`):

1. **Add the field to the struct** (`SymbolOverrides` in `MSPB_Expert_Advisor.mq5`):
   ```
   double minVolume;  // <=0 => use global default
   ```

2. **Initialise the field in `LoadSymbolOverrides()`** — increment the CSV column index
   so your field maps to the correct column (currently column 13 would be the next one):
   ```
   o.minVolume = (n > 13 ? ParseDbl(cols[13], 0) : 0);
   ```

3. **Add an accessor function** following the same pattern as the existing `Sym_*` helpers
   (around line 661 in the main EA file):
   ```
   double Sym_MinVolume(const string sym)
   {
      int k = FindOverrideIndex(sym);
      if(k >= 0 && g_ovr[k].minVolume > 0.0) return g_ovr[k].minVolume;
      return InpMinVolume;  // global default input
   }
   ```

4. **Update the debug print** in `LoadSymbolOverrides()` to include the new field so
   it appears in the Experts log when `InpSymbolOverrides_PrintOnLoad = true`.

5. **Add a column heading comment** to `MSPB_SymbolOverrides.csv` (the example/template
   file, if you maintain one) so users know what column 13 means.

6. **Update this file** — add the new column to the column-order table in
   "Adding a new instrument" above.

7. **Bump `EA_VERSION`** and add a CHANGELOG entry (see Release checklist below).

---

## Running the unit tests

The unit tests are in `MSPB_EA_UnitTests.mq5`.  They are designed to run as a MetaTrader 5 script:

1. Open MetaTrader 5.
2. Press **Ctrl+O** (Options) → Expert Advisors → allow WebRequest for `https://api.telegram.org` (not required for tests but avoids compile errors).
3. In the Navigator panel, expand **Scripts** and double-click `MSPB_EA_UnitTests`.
4. The results are printed in the **Experts** tab of the Terminal.  
   A line ending with `PASS` means the assertion succeeded; `FAIL` indicates a regression.

**Automated CI**: the lint workflow does not currently execute the MQL5 tests automatically  (MetaTrader requires a running terminal).  When all checks in `.github/workflows/lint.yml` pass, the structural and integration tests should be run manually before tagging a release.

---

## Code style

- **Indentation**: 3 spaces (consistent with the existing code).
- **Naming**: `g_` prefix for globals, `Inp` prefix for inputs, `CamelCase` for functions.
- **Include guards**: every `.mqh` file must have `#ifndef MSPB_EA_<NAME>_MQH` / `#define` / `#endif` guards.
- **`#property strict`**: required in every `.mq5` file.
- **Comments**: add a comment when the intent is not immediately obvious; avoid commenting the obvious.
- **No debug markers**: do not commit `Print("[DEBUG]…")` or `Print("[TEST]…")` calls — the CI workflow will reject them.

---

## Release checklist

- [ ] Update `EA_VERSION` in `MSPB_Expert_Advisor.mq5` (`#define` and `#property version`).
- [ ] Add an entry to `CHANGELOG.md` under a new `## [x.y] — YYYY-MM-DD` heading.
- [ ] Run the unit tests manually in MetaTrader and confirm all pass.
- [ ] Run `pytest tools/ --cov=tools --cov-fail-under=70` and confirm all Python tests pass.
- [ ] Push to a feature branch; wait for the CI lint workflow to go green.
- [ ] Open a pull request and request review.
- [ ] Merge to `main` and tag the commit with `vx.y` (e.g. `git tag v16.0`).

---

## Architecture Decision Records (ADR)

ADRs capture *why* significant design choices were made.  Add a new entry when you introduce
a substantial architectural change.

### ADR-001: Ring buffer for deal capture queue

**Decision**: Use a fixed-size ring buffer (`DEAL_QUEUE_MAX = 4096`) for the deal capture queue
instead of a dynamically-growing array.

**Context**: MT5 `OnTradeTransaction` fires on every deal event including broker fills and
server updates.  Dynamic arrays require `ArrayResize` which can trigger O(n) memory allocation
inside a tick handler and cause non-deterministic latency spikes.

**Consequences**: Memory footprint is bounded and deterministic.  Overflow produces a log
warning (`DEALQ_OVERFLOW`) rather than a silent data loss.  In practice 4096 slots cover many
weeks of continuous operation on a 64-symbol portfolio before the ring catches up.

---

### ADR-002: Module extraction over monolithic file

**Decision**: Extract logical subsystems (risk, execqual, dashboard, telegram, ML) into
separate `.mqh` header files included by the main `.mq5`.

**Context**: MQL5 compiles all `#include`d files into a single translation unit, so there is
no linking overhead.  The main `.mq5` was growing toward 10 000 lines, making navigation and
code review difficult.

**Consequences**: Each module is independently readable and testable via the unit-test script.
The CI line-count guard (`MAX_EA_LINES`) enforces that logic does not drift back into the
monolithic file.

---

### ADR-003: Telegram circuit-breaker

**Decision**: Add a fail-streak counter and a timed mute window (`g_tg_disabled`,
`g_tg_reEnableAt`) inside `MSPB_EA_Telegram.mqh` rather than propagating error return codes
to every call site.

**Context**: When the VPS loses internet connectivity `TelegramSendMessage` is called dozens of
times per minute (on every tick for risk alerts).  Without throttling, the EA wastes CPU on
failed WebRequest calls.

**Consequences**: After `TG_CB_FAIL_THRESHOLD` (3) consecutive failures the circuit trips and
all outgoing messages are suppressed for `TG_CB_MUTE_MINUTES` (10 minutes).  The circuit
auto-resets on the next call after the mute window, meaning recovery is automatic when
connectivity is restored.
