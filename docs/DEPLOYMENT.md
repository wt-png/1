# MSPB EA — Phased Deployment Guide

> **Purpose**: Define the guardrails, feature flags, and rollback criteria for rolling out
> every optimisation change safely.

---

## Deployment phases

```
Phase 1: Development  →  Phase 2: Backtest  →  Phase 3: Forward-test  →  Phase 4: Live
```

### Phase 1 — Development (sandbox)

- All changes on a feature branch.
- CI must pass (lint, compile check, pytest).
- PR requires at least one review before merging.

### Phase 2 — Backtest validation

- Run ST over the baseline configuration (see `docs/BASELINE.md`).
- Run stress tests at 1.4× and 2.0× spread multipliers.
- Run walk-forward optimisation (`tools/wfo_pipeline.py`).
- **Gate**: All KPIs ≥ minimum acceptable (see `docs/KPI_TARGETS.md`).

### Phase 3 — Forward test (demo or small live)

- Deploy on demo account or with ≤ 10 % of live lot size.
- Minimum duration: **14 calendar days** and **≥ 50 closed trades** per symbol.
- Monitor daily via `tools/session_analysis.py` output.
- **Gate**: No KPI regression vs baseline; no unexpected equity spike.

### Phase 4 — Full live rollout

- Increase lot size to full allocation in two steps: 50 % → 100 % (7 days apart).
- Enable Telegram alerts for every entry and exit.
- Verify `InpTune_Rollback_AutoApply = true` is set.

---

## Feature-flag table

All experimental features are guarded by `input bool` flags.  
Set a flag to `false` to disable a feature without recompiling.

| Flag | Default | Description |
|------|---------|-------------|
| `InpUseATRFilter` | `true` | Block entries when ATR too low |
| `InpUseADXFilter` | `true` | ADX trend + entry quality filter |
| `InpUseHTFBias` | `true` | Higher-timeframe bias filter |
| `InpUseCorrelationGuard` | `true` | Block correlated symbols simultaneously |
| `InpUseVolRegime` | `true` | Volatility-regime position sizing |
| `InpUsePullbackEMA` | `false` | EMA pullback entry requirement |
| `InpEntryUseFollowThrough` | `true` | Require follow-through bar in signal direction |
| `InpEntryUseWickFilter` | `true` | Reject indecision candles |
| `InpEntryUseRangeATRFilter` | `true` | Require meaningful candle range vs ATR |
| `InpNews_Enable` | `false` | News-aware blocking |
| `InpEnableMLExport` | `false` | Export trade data for ML training |
| `InpTune_Enable` | `false` | Auto-tune + rollback engine |
| `InpTune_Rollback_AutoApply` | `true` | Auto-apply rollback on regression |
| `InpTester_UseCustomCriterion` | `false` | Custom OnTester() score for optimization |

---

## Rollback procedure

### Automatic (EA-internal)

The EA's `InpTune_Rollback_*` inputs handle automatic rollback when:
- Profit Factor drops > `InpTune_Rollback_PF_Drop` vs baseline.
- Equity DD > baseline DD × `(1 + InpTune_Rollback_DD_IncreasePct / 100)`.
- Avg expectancy R drops below baseline.

### Manual rollback

1. Open EA settings in MT5.
2. Load the previous `.set` file from `tools/applied_settings/` folder.
3. Telegram alert: send `/rollback` command (if `InpTGEnableIncoming=true`).
4. Document rollback in the comparison table in `docs/BASELINE.md`.

---

## Change log discipline

- Every deployed change must have a row in `CHANGELOG.md`.
- Include: version, date, feature flags changed, KPI delta vs baseline.
- Never change more than **3 input parameters** in a single live deploy.
