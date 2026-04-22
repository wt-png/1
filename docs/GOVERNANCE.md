# Change Management & Governance — MSPB Expert Advisor

---

## Changelog Process

Every change to EA source code, parameters, or tooling must be documented in `CHANGELOG.md`.

### Required fields per entry

| Field | Description |
|-------|-------------|
| Version | Semantic version (vMAJOR.MINOR) |
| Date | ISO 8601 (YYYY-MM-DD) |
| Author | Developer name / handle |
| Reason | Why this change was made (trading result, bug fix, optimisation) |
| Impact | Expected effect on KPIs (quantified if possible) |
| Parameters changed | List each input and old → new value |
| Rollback plan | How to revert: previous binary + parameter file location |
| OOS validation | Did the change pass OOS / Monte Carlo before deployment? |

### Changelog entry template

```markdown
## vXX.Y — YYYY-MM-DD
**Author:** [name]  
**Reason:** [why]  
**Impact:** [expected KPI effect]  
**Rollback:** [previous version tag / file]  
**OOS validated:** YES / NO  
### Added
- ...
### Changed
- [InputName]: old_value → new_value — [reason]
### Fixed
- ...
```

---

## Monthly Optimisation Window

- **Schedule:** 2nd Saturday of each month, 08:00–16:00 UTC.
- **Process:**
  1. Run `tools/wfo_pipeline.py` on the latest 6 months of trade data.
  2. If WFO suggests a parameter change, evaluate on OOS data.
  3. Apply a **single parameter change** (see below).
  4. Run `tools/monte_carlo_analysis.py` — must return GO before deployment.
  5. Record in `CHANGELOG.md` before deploying.
- **No changes outside the optimisation window** unless triggered by a Rollback Criterion.

---

## Parameter Change Approval Process

1. **One change at a time.** Never adjust two parameters simultaneously.
2. **Document expected impact** before making the change (e.g., "reducing InpDailyLoss_PctBalance from 2.0 to 1.5 is expected to reduce the number of high-drawdown days by ~30%, at the cost of ~5% fewer trades").
3. **OOS validation:** Run the changed parameter on held-out OOS data before deploying live.
4. **Monte Carlo acceptance:** Must pass both baseline and stressed MC verdict (GO) before going live.
5. **Monitor for 2 weeks** after any parameter change before considering further changes.

---

## Stop Criteria (Suspend Live Trading)

Trading is suspended immediately (EA set to manual mode or removed) if:

| Criterion | Threshold |
|-----------|-----------|
| Account drawdown | ≥ 15% from account peak |
| Rolling 30-trade PF | < 1.00 for two consecutive weeks |
| Daily loss CB | > 5 triggered days in a calendar month |
| Equity CB | > 3 triggers per week for 2 consecutive weeks |
| EA FAILSAFE | Any FAILSAFE trip not explained by data interruption |
| Broker spread degradation | Observed spread > 2× InpMaxSpreadPips_FX for > 3 sessions |

After suspension: conduct root-cause analysis, fix, validate on demo for 2 weeks, then resume from Phase 2 of the deployment protocol.

---

## Version Naming Convention

- **vMAJOR.MINOR** — e.g., `v21.0`, `v21.1`, `v22.0`
- **MAJOR** increments for: new circuit breakers, fundamental logic changes, strategy changes.
- **MINOR** increments for: parameter tuning, bug fixes, minor filter additions.
- Version string is set in `#property description` on line 2 of `MSPB_Expert_Advisor.mq5`.
- Version must be updated in **both** `MSPB_Expert_Advisor.mq5` and `CHANGELOG.md` simultaneously.
- Git tag format: `vXX.Y` — create a tag at the commit that bumps the version.

---

## Audit Trail

- All parameter files (`.set` files from MetaTrader) are version-controlled alongside the EA source.
- Backtest reports (`.htm`) for each version are stored in `backtest_results/vXX.Y/`.
- Monte Carlo and WFO JSON outputs are stored alongside backtest reports.
