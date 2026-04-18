# Contributing to MSPB Expert Advisor

## Repository layout

| File | Purpose |
|---|---|
| `MSPB_Expert_Advisor.mq5` | Main EA — `OnInit`, `OnTick`, `OnTimer`, `OnDeinit`, entry logic, position management, risk calculations |
| `MSPB_EA_ExecQual.mqh` | Execution-quality gate — spread/slippage tracking, session-bucket gate, adaptive threshold learning |
| `MSPB_EA_Dashboard.mqh` | On-chart dashboard — object creation/deletion, button handlers, display update |
| `MSPB_EA_Telegram.mqh` | Telegram Bot API — config loading, outgoing messages, rate limiting, incoming command polling |
| `MSPB_EA_JSON.mqh` | Lightweight JSON read helpers used by the Telegram module |
| `MSPB_EA_ML.mqh` | Machine-learning CSV export (`ML_WriteRowV2`) |
| `MSPB_EA_News.mqh` | News-filter integration (economic calendar guard) |
| `MSPB_EA_UnitTests.mq5` | Standalone unit-test script — compile and run in MetaTrader Strategy Tester |
| `.github/workflows/lint.yml` | CI workflow — runs on every push/PR (see below) |
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
- [ ] Push to a feature branch; wait for the CI lint workflow to go green.
- [ ] Open a pull request and request review.
- [ ] Merge to `main` and tag the commit with `vx.y` (e.g. `git tag v15.0`).
