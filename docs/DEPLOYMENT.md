# Staged Production Rollout Protocol — MSPB Expert Advisor

---

## Overview

Production deployment follows a four-phase staged rollout.
Each phase has exit criteria that must be met before advancing.
All KPI thresholds are defined in `docs/KPI_TARGETS.md`.

---

## Phase 1 — Demo Pilot

| Item | Detail |
|------|--------|
| Duration | 2 weeks minimum |
| Account type | Demo account (live-matching broker conditions) |
| Lot size | 0.01 lot (fixed, ignore InpRiskPctPerTrade) |
| Symbols | EURUSD only |
| Monitoring | All KPIs monitored daily |

**Exit criteria (advance to Phase 2):**
- No EA crashes or silent failures.
- Daily loss CB triggered ≤ 1 time total.
- PF ≥ 1.20 over demo period.
- Spread observed ≤ InpMaxSpreadPips_FX during active session.

---

## Phase 2 — Live Pilot

| Item | Detail |
|------|--------|
| Duration | 4 weeks minimum |
| Account type | Live account |
| Risk | 25% of target risk (InpRiskPctPerTrade × 0.25) |
| Symbols | EURUSD, GBPUSD |
| Monitoring | All KPIs monitored daily; weekly review (see checklist below) |

**Exit criteria (advance to Phase 3):**
- Net Profit > 0.
- Max Drawdown < 12%.
- Profit Factor ≥ 1.30.
- Daily loss CB not triggered more than 2 times total.
- No rollback criteria triggered (see Rollback Criteria below).

---

## Phase 3 — Scale-Up

| Item | Detail |
|------|--------|
| Duration | 4–8 weeks |
| Risk | 75% of target risk (InpRiskPctPerTrade × 0.75) |
| Symbols | EURUSD, GBPUSD (+ additional if Phase 2 data supports) |
| Monitoring | Weekly review; automated KPI alerting |

**Exit criteria (advance to Phase 4):**
- All Phase 2 KPIs maintained at 75% risk level.
- Sharpe proxy ≥ 0.80.
- Monte Carlo stressed verdict: GO.

---

## Phase 4 — Full Production

| Item | Detail |
|------|--------|
| Risk | 100% of target risk |
| Review cadence | Weekly |
| Parameter changes | Only via governance process (see `docs/GOVERNANCE.md`) |

---

## Weekly Review Checklist

Each week review the following before the Monday session opens:

- [ ] Net P&L vs KPI targets (daily, weekly, monthly)
- [ ] Max drawdown — within limits?
- [ ] Profit Factor (rolling 30-trade window)
- [ ] Daily loss CB triggered? How many times?
- [ ] Equity CB triggered? How many times?
- [ ] Loss-streak blocks triggered per symbol?
- [ ] Spread quality — are observed spreads within limits?
- [ ] Trade count — within InpMaxEntriesTotalPerDay × trading days?
- [ ] News events logged — any significant gaps in trading?
- [ ] EA log — any errors, warnings, FAILSAFE trips?
- [ ] Monte Carlo re-run if > 50 new trades since last run

---

## Rollback Criteria

Immediately roll back to the previous EA version (or halt trading) if ANY of the following occur:

| Trigger | Action |
|---------|--------|
| Max Drawdown ≥ 15% | Halt all trading immediately |
| PF < 1.00 over rolling 30 trades | Revert to previous version |
| Daily loss CB triggered > 5 days in a calendar month | Halt trading; review parameters |
| EA silent failure (no trades for > 5 consecutive trading days without session/news block explanation) | Halt and investigate |
| InpTune_Rollback_PF_Drop triggered | Auto-rollback per EA internal logic |
| InpTune_Rollback_DD_IncreasePct triggered | Auto-rollback per EA internal logic |

---

## Incident Log Template

Copy this template for each incident:

```
## Incident — [DATE]

**Severity:** [Critical / High / Medium / Low]  
**Description:** [What happened]  
**EA Version:** [version]  
**Phase:** [Demo / Live Pilot / Scale-Up / Full Production]  
**KPI at time of incident:**  
  - Net P&L: _  
  - Max DD: _  
  - PF: _  
**Root cause:** [analysis]  
**Action taken:** [immediate response]  
**Follow-up:** [parameter change / rollback / monitor]  
**Resolved:** [YES/NO] — [date resolved]  
```
