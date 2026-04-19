# MSPB Expert Advisor — Installation Guide

Version: v19.0 | Updated: 2026-04-19

---

## Table of Contents

1. [Requirements](#requirements)
2. [Broker & Account Setup](#broker--account-setup)
3. [MetaTrader 5 Layout](#metatrader-5-layout)
4. [Copying EA Files](#copying-ea-files)
5. [Configuring the EA](#configuring-the-ea)
6. [Telegram Integration](#telegram-integration)
7. [First Run Checklist](#first-run-checklist)
8. [Python Tooling Setup](#python-tooling-setup)
9. [Troubleshooting](#troubleshooting)

---

## Requirements

| Component | Version |
|-----------|---------|
| MetaTrader 5 | Build 3660 or newer (64-bit) |
| Broker feed | Supports EURUSD, GBPUSD (or custom symbols) with M1/M5/M15 history |
| Python (optional) | 3.10 + for `tools/` scripts |

---

## Broker & Account Setup

1. **Account type**: ECN or Raw Spread preferred (tight spreads matter for scalping).
2. **Leverage**: 1:30 minimum (1:100+ recommended for correct lot sizing).
3. **Symbols**: Subscribe to all symbols listed in `InpSymbols` in the EA inputs. Right-click in *Market Watch → Show All* and select the required pairs.
4. **History depth**: Ensure at least 12 months of tick/M1 data is downloaded. Use *File → Open Data Folder → bases → <broker>* and verify `.hcc` files exist.
5. **GMT offset**: Note your broker's GMT offset (visible in the terminal status bar). Set `InpBrokerGMTOffset` accordingly.

---

## MetaTrader 5 Layout

Recommended workspace for multi-symbol scalping:

1. Open a **Utility Chart** (e.g. EURUSD M1) — the EA is attached here and manages all symbols.
2. Keep **Market Watch** visible to monitor spreads.
3. Open the **Journal** tab to see EA log output.
4. Use *Terminal → Trade* tab to monitor open positions.

---

## Copying EA Files

Copy the following files to your MT5 installation:

| Source file | Destination |
|-------------|-------------|
| `MSPB_Expert_Advisor.mq5` | `MQL5/Experts/MSPB/` |
| `MSPB_EA_Risk.mqh` | `MQL5/Include/MSPB/` |
| `MSPB_EA_Entry.mqh` | `MQL5/Include/MSPB/` |
| `MSPB_EA_ExecQual.mqh` | `MQL5/Include/MSPB/` |
| `MSPB_EA_Dashboard.mqh` | `MQL5/Include/MSPB/` |
| `MSPB_EA_Telegram.mqh` | `MQL5/Include/MSPB/` |
| `MSPB_EA_OrderExec.mqh` | `MQL5/Include/MSPB/` |

Then open **MetaEditor** (`F4`), navigate to the `.mq5` file and press **Compile** (`F7`). There should be 0 errors.

> **Note**: The `.mqh` files use relative `#include` paths — they must be in the same directory as the `.mq5` or in `MQL5/Include/`. If you receive "file not found" compile errors, adjust the `#include` paths accordingly.

---

## Configuring the EA

### Minimum required inputs

| Input | Suggested default | Notes |
|-------|------------------|-------|
| `InpMagic` | `202600` | Unique magic number — change if running multiple EAs |
| `InpSymbols` | `EURUSD,GBPUSD` | Comma-separated; no spaces |
| `InpRiskPct` | `0.5` | Risk per trade as % of equity |
| `InpMaxPositionsTotal` | `3` | Hard cap on concurrent positions |
| `InpEntryTF` | `PERIOD_M5` | Entry timeframe |
| `InpConfirmTF` | `PERIOD_M15` | ADX confirmation timeframe |

### Risk management inputs (critical)

| Input | Purpose |
|-------|---------|
| `InpDailyLossLimit_Pct` | Hard stop after X% daily equity loss |
| `InpWeeklyLossLimit_Pct` | Block entries after X% weekly equity drawdown |
| `InpMaxPortfolioRiskPct` | Max total open risk across all positions |
| `InpBlockMonday` | Skip Monday entries (optional) |
| `InpBlockFriday` | Skip Friday afternoon entries |

See `docs/PARAMETERS.md` for the full parameter reference.

### Allowing WebRequests (Telegram)

To enable Telegram notifications:

1. In MT5: *Tools → Options → Expert Advisors*
2. Enable **Allow WebRequest for listed URL**
3. Add: `https://api.telegram.org`
4. Set `InpEnableTelegram = true` and provide `InpTGConfigFile`

---

## Telegram Integration

### Config file format

Create a plain-text file (e.g. `tg_config.txt`) in the MT5 data folder:

```
BOT_TOKEN=123456789:ABCdefGHIjklMNOpqrSTUvwxYZ
CHAT_ID=-1001234567890
ALLOWED_USER_ID=987654321
```

Set `InpTGConfigFile = tg_config.txt`.

### Inbound commands (v19.0+)

Enable with `InpTGEnableIncoming = true`. Supported commands:

| Command | Effect |
|---------|--------|
| `/pause` | Blocks all new entry signals |
| `/resume` | Re-enables entries |
| `/status` | Reports equity, balance, open positions |
| `/closeall` | Closes all EA-managed positions |

> Only the user matching `ALLOWED_USER_ID` can issue commands.

---

## First Run Checklist

- [ ] EA compiled without errors in MetaEditor
- [ ] All symbols visible in Market Watch with sufficient history
- [ ] `InpMagic` is unique (no other EA uses the same number)
- [ ] `InpRiskPct` set conservatively (≤ 1% for live, ≤ 0.5% for first week)
- [ ] Daily and weekly loss limits configured
- [ ] Telegram test message received (set `InpTGTestOnInit = true`)
- [ ] Journal shows `EA gestart | magic=… | symbols=…` startup message
- [ ] Strategy Tester backtest runs at least 100 trades over 6 months

---

## Python Tooling Setup

```bash
cd /path/to/repo
pip install -r requirements.txt
```

### Walk-forward analysis

```bash
python tools/wfo_pipeline.py --csv /path/to/ml_export_v2.csv --windows 6
```

### ML feedback (XGBoost)

```bash
python tools/ml_feedback.py --csv /path/to/ml_export_v2.csv --output suggestions.txt
```

### Parameter optimisation

```bash
python tools/optimize_params.py --csv /path/to/ml_export_v2.csv --mode grid
python tools/optimize_params.py --csv /path/to/ml_export_v2.csv --mode optuna --n-trials 200
```

---

## Troubleshooting

### EA not opening trades

1. Check Journal for `REJ_*` rejection messages.
2. Verify `InpEntryTF` history is loaded (right-click the chart → Timeframes).
3. Check `SessionAllows()` — the EA only trades inside configured session hours.
4. Ensure spread is below `InpMaxSpreadPips_FX`.

### Indicator init failed

After a reconnect, indicator handles may become invalid. v19.0+ automatically reinitialises handles on each `OnTimer` cycle. If the message persists, verify the symbol name matches the broker's feed exactly (including suffix, e.g. `EURUSDm`).

### Deal queue backoff

If you see `DEALQ_BACKOFF` in the Journal, the EA is waiting for trade history to become available after a reconnect. This is normal — the queue retries automatically with exponential back-off.

### Telegram 429 errors

Reduce message frequency via `InpTGRateLimitMs` or enable `InpTGUseQueue = true` (default) to smooth out burst sends.
