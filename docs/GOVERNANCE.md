# MSPB EA — Optimisation Governance

> **Purpose**: Define the recurring process that keeps the EA improving systematically
> without introducing drift, overfitting, or uncontrolled live risk.

---

## Weekly optimisation cycle

```
Monday     → Data review          (15 min)
Tuesday    → Hypothesis formation (30 min)
Wednesday  → Backtest / WFO       (60 min, automated via CI)
Thursday   → Stress test          (30 min)
Friday     → Decision & PR        (30 min)
Weekend    → Forward-test monitor (automated alerts)
```

### Monday — Data review

1. Pull the latest `ml_export_v2.csv` from the live account's `MQL5/Files/` folder.
2. Run `python tools/session_analysis.py ml_export_v2.csv` — check session-level KPIs.
3. Check `MSPB_AppliedSettings.csv` for any auto-tune changes.
4. Note any anomalies: excessive slippage, spread spikes, fill-rate drops.

### Tuesday — Hypothesis formation

- Formulate **one** specific hypothesis (e.g. "tightening InpMinADXForEntry to 25 will
  reduce false signals in London open without reducing trade count by more than 10 %").
- Define the **acceptance gate** upfront (which KPIs must improve, by how much).
- Record the hypothesis in a GitHub Issue tagged `optimisation`.

### Wednesday — Backtest / WFO (automated)

- CI runs `tools/wfo_pipeline.py` each Wednesday via cron.
- The pipeline produces a JSON report in `tools/wfo_results/`.
- If you have a specific hypothesis, trigger manually:
  ```
  python tools/wfo_pipeline.py --regimes trend range volatile --oos-ratio 0.3
  ```

### Thursday — Stress test

- Run `python tools/stress_test.py --multipliers 1.0 1.4 2.0 --slippage 0 2 5`
- All stress scenarios must pass the gates in `docs/KPI_TARGETS.md Section 4`.

### Friday — Decision & PR

- If all gates pass: open PR, link to WFO + stress-test artefacts, merge after review.
- If gates fail: close the GitHub Issue with a note explaining why.
- Never merge more than one optimisation cycle's changes per week.

---

## CI cadence

| Job | Trigger | Tool |
|-----|---------|------|
| Lint + tests | Every push / PR | `pytest tools/test_tools.py` |
| WFO pipeline | Weekly (Wednesday 02:00 UTC) | `tools/wfo_pipeline.py` |
| Monte Carlo | Weekly (Wednesday 02:30 UTC) | `tools/monte_carlo_analysis.py` |
| Baseline report | On-demand (PR label `baseline`) | `tools/baseline_report.py` |

---

## Decision authority

| Decision | Authority |
|----------|-----------|
| Change input parameter ≤ 10 % | Developer alone (after CI green) |
| Change input parameter > 10 % | Developer + 1 reviewer |
| Disable a filter flag live | Developer + 1 reviewer + forward-test gate |
| Change risk parameters | Developer + 2 reviewers |
| Major EA code refactor | Full team review + 4-week forward test |

---

## Anti-overfitting rules

1. **Never optimise on the same data used to generate the hypothesis.**
2. **Always hold out ≥ 30 % of the data as out-of-sample** (WFO enforces this).
3. **Vary the optimisation window** — a parameter must be robust across multiple windows.
4. **Max 5 free parameters per optimisation run** — more parameters → more overfitting risk.
5. **Test on at least 3 symbols** — if it only works on 1 symbol, reject it.
6. **Stress-test every accepted parameter set** before considering live deployment.

---

## Documentation standards

- All optimisation results are committed to `tools/wfo_results/` as JSON.
- All stress-test results are committed to `tools/stress_results/` as JSON.
- `CHANGELOG.md` is updated with every accepted change.
- `docs/BASELINE.md` comparison table is updated after every sprint.
