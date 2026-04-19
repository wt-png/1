# MSPB Expert Advisor — Installation & Deployment Guide

> Version: 17.1 | Last updated: 2026-04-19

---

## Table of Contents

1. [Requirements](#1-requirements)
2. [MT5 Folder Layout](#2-mt5-folder-layout)
3. [Broker Setup](#3-broker-setup)
4. [Installing the EA Files](#4-installing-the-ea-files)
5. [Telegram Configuration](#5-telegram-configuration)
6. [Symbol Overrides CSV](#6-symbol-overrides-csv)
7. [Loading the .set File](#7-loading-the-set-file)
8. [First-Run Checklist](#8-first-run-checklist)
9. [Key Parameters Reference](#9-key-parameters-reference)
10. [Verifying Config Integrity](#10-verifying-config-integrity)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Requirements

| Requirement | Details |
|---|---|
| MetaTrader 5 | Build 3800+ (64-bit) |
| Account type | Hedging or Netting; ECN/STP recommended |
| Minimum balance | €/$1 000 (demo) / €/$5 000 (live) at `InpRiskPercent=0.30` |
| Internet | WebRequest must be allowed (needed for Telegram) |
| Python (optional) | 3.9+ for `tools/sign_config.py`, `tools/walk_forward.py` |

---

## 2. MT5 Folder Layout

After installation, your `MQL5` directory should look like this:

```
MT5 Data Folder\
└── MQL5\
    ├── Experts\
    │   └── MSPB\
    │       ├── MSPB_Expert_Advisor.mq5        ← main EA (compile this)
    │       ├── MSPB_EA_Dashboard.mqh
    │       ├── MSPB_EA_ExecQual.mqh
    │       ├── MSPB_EA_JSON.mqh
    │       ├── MSPB_EA_ML.mqh
    │       ├── MSPB_EA_News.mqh
    │       ├── MSPB_EA_OrderExec.mqh
    │       ├── MSPB_EA_PositionManager.mqh
    │       ├── MSPB_EA_Risk.mqh
    │       ├── MSPB_EA_SymbolConfig.mqh
    │       └── MSPB_EA_Telegram.mqh
    └── Files\
        ├── MSPB_Telegram.cfg              ← Telegram credentials (NOT committed to git)
        ├── MSPB_SymbolOverrides.csv       ← per-symbol parameter overrides
        ├── MSPB_ExecQual_State.csv        ← auto-created; exec-quality persistence
        ├── MSPB_RuntimeState.csv          ← auto-created; pause/override persistence
        └── ml_export_v2.csv               ← auto-created; ML trade export
```

> **Finding the MT5 Data Folder:** In MetaTrader 5 → top menu → *File → Open Data Folder*.

---

## 3. Broker Setup

### 3.1 Allow WebRequests

MetaTrader 5 → *Tools → Options → Expert Advisors*:

- ☑ Allow WebRequest for listed URL
- Add: `https://api.telegram.org`

### 3.2 Allow Automated Trading

- ☑ Allow automated trading (global switch in toolbar)
- ☑ Allow DLL imports (not required by this EA, but some brokers need it for data feeds)

### 3.3 Recommended Broker Settings

| Setting | Recommended |
|---|---|
| Execution | Market execution (ECN) |
| Minimum lot step | 0.01 |
| Spread (EURUSD) | < 1.2 pips on average |
| Hedging | Enabled preferred (netting also works) |
| Swap | Aware — check swap-free options for multi-day holds |

### 3.4 VPS / Latency

- Recommended: VPS within the same datacenter as your broker's execution server
- Target latency: < 20 ms round-trip
- Minimum uptime: 99.9 % (EA must be running continuously during market hours)

---

## 4. Installing the EA Files

1. **Copy all `.mq5` / `.mqh` files** to `MQL5\Experts\MSPB\` (create the folder if it does not exist).
2. **Open MetaEditor** (`F4` in MT5) and open `MSPB_Expert_Advisor.mq5`.
3. **Compile** (`F7`). Verify: *0 errors, 0 warnings* in the Errors tab.
4. The compiled `MSPB_Expert_Advisor.ex5` will appear automatically in the same folder.

---

## 5. Telegram Configuration

Create the file `MQL5\Files\MSPB_Telegram.cfg` with **exactly** these two lines:

```
token=<YOUR_BOT_TOKEN>
chat_id=<YOUR_CHAT_ID>
```

**How to get a bot token:**
1. Open Telegram → search for `@BotFather`
2. Send `/newbot` → follow prompts → copy the token

**How to get your chat ID:**
1. Send any message to your bot
2. Visit `https://api.telegram.org/bot<TOKEN>/getUpdates`
3. Copy the `"id"` value from `"chat"` in the JSON response

> ⚠️  **Security:** Never commit `MSPB_Telegram.cfg` to version control.  
> Add it to `.gitignore`: `MQL5/Files/MSPB_Telegram.cfg`

**EA parameters (already set in `.set` file):**

| Parameter | Default | Notes |
|---|---|---|
| `InpTGConfigFile` | `MSPB_Telegram.cfg` | Path relative to `MQL5\Files\` |
| `InpTGConfig_UseCommonFolder` | `false` | Set `true` to use the MT5 Common folder |
| `InpTGTestOnInit` | `true` | Sends a startup ping — verify this arrives |
| `InpTGDailyReport` | `true` | Daily P&L summary at midnight server time |

---

## 6. Symbol Overrides CSV

Create `MQL5\Files\MSPB_SymbolOverrides.csv` to customise per-symbol parameters.

**Header line** (copy exactly):

```
symbol,entryTF,confirmTF,slMult,tpRR,riskPct,minATR,minADXTrend,minADXEntry,maxSpread,magicOffset,riskWeight
```

**Example rows:**

```csv
symbol,entryTF,confirmTF,slMult,tpRR,riskPct,minATR,minADXTrend,minADXEntry,maxSpread,magicOffset,riskWeight
EURUSD,1,5,1.2,1.5,0.30,10,20,18,1.5,0,1.0
XAUUSD,1,15,1.5,2.0,0.20,30,22,20,3.0,10,0.8
```

**Column notes:**

| Column | Effect | Leave blank / 0 to use global default |
|---|---|---|
| `slMult` | ATR multiplier for SL | `0` = use `InpSL_ATR_Mult` |
| `tpRR` | Risk-reward ratio | `0` = use `InpTP_RR` |
| `riskPct` | Per-trade risk % | `0` = use `InpRiskPercent` |
| `riskWeight` | Scale position size (e.g. 0.5 = half size) | `0` = weight 1.0 |

The file is hot-reloaded every `InpSymbolOverrides_ReloadSec` seconds (default 60) — no EA restart needed.

---

## 7. Loading the .set File

1. Attach the EA to a chart of any of your traded symbols (e.g. EURUSD M1).
2. In the EA property dialog: click **Load** → navigate to `MSPB_Expert_Advisor.set`.
3. Review the critical safety parameters before clicking OK:

   | Parameter | Production default | Why |
   |---|---|---|
   | `InpRiskPercent` | `0.30` | 0.3 % risk per trade |
   | `InpDailyLossLimit_Enable` | `true` | Hard stop after 2 % daily loss |
   | `InpConsecLoss_Enable` | `true` | Pause after 5 consecutive losses |
   | `InpExecQual_Mode` | `2` (Enforce) | Block entries if execution quality is poor |
   | `InpSymbols` | `EURUSD,GBPUSD,USDJPY,XAUUSD` | Change to match your account symbols |

4. Confirm the EA is running: the dashboard should appear on the chart within a few seconds.

> **Multi-chart setup:** Attach the EA to **one** chart only. The EA manages all symbols in `InpSymbols` internally. Running on multiple charts with the same `InpMagic` will cause duplicate trades.

---

## 8. First-Run Checklist

Work through this list after attaching the EA for the first time:

- [ ] Telegram startup message received (`MSPB EA v17.0 Online`)
- [ ] Dashboard visible on chart (press `D` to toggle)
- [ ] Symbol list in dashboard matches `InpSymbols`
- [ ] No errors in MT5 Journal tab
- [ ] `MSPB_ExecQual_State.csv` created in `MQL5\Files\` (may take one timer cycle)
- [ ] `MSPB_RuntimeState.csv` created in `MQL5\Files\`
- [ ] `InpExecQual_Mode=1` (Monitor only) during **first week** — switch to `2` (Enforce) after shadow data accumulates
- [ ] Review ML export after first 10 trades (`ml_export_v2.csv`)
- [ ] Run `tools/walk_forward.py --csv ml_export_v2.csv` after ≥ 50 trades

---

## 9. Key Parameters Reference

### Risk

| Parameter | Default | Description |
|---|---|---|
| `InpRiskPercent` | `0.30` | % of account balance risked per trade |
| `InpMaxPortfolioRiskPct` | `2.0` | Max total open risk across all positions |
| `InpDailyLossLimitPct` | `2.0` | EA pauses trading after this daily loss |
| `InpConsecLoss_MaxN` | `5` | Max consecutive losses before cooldown |
| `InpConsecLoss_CooldownMin` | `60` | Minutes to pause after consecutive-loss trigger |
| `InpEqDD_Defensive_Pct` | `5.0` | Equity DD % that activates defensive mode (40 % risk) |

### Execution Quality

| Parameter | Default | Description |
|---|---|---|
| `InpExecQual_Mode` | `2` | `0`=Off, `1`=Monitor, `2`=Enforce |
| `InpExecQual_BadSlipPips` | `1.2` | Slippage threshold (pips) for a "bad fill" |
| `InpExecQual_MaxBadFillRate` | `0.35` | Block entries if bad-fill rate exceeds 35 % |
| `InpExecQual_BlockCooldownSec` | `120` | Cooldown after an execution block |

### Sessions

| Parameter | Default | Description |
|---|---|---|
| `InpAllowAsiaEntries` | `false` | Allow entries during Asian session |
| `InpExecQual_LondonStartH` | *(see .set)* | London session start hour (server time) |
| `InpExecQual_NYEndH` | *(see .set)* | New York session end hour |

---

## 10. Verifying Config Integrity

To ensure a `.set` file has not been tampered with, sign it before distribution and verify before loading:

```bash
# Sign (creates MSPB_Expert_Advisor.set.sig)
python tools/sign_config.py sign MSPB_Expert_Advisor.set --key-env MSPB_SIGNING_KEY

# Verify before loading
python tools/sign_config.py verify MSPB_Expert_Advisor.set --key-env MSPB_SIGNING_KEY
# → OK: signature valid (sha256-hmac)

# Show embedded metadata
python tools/sign_config.py info MSPB_Expert_Advisor.set
```

Set the signing key as an environment variable (`MSPB_SIGNING_KEY`) or pass it directly with `--key`. See `tools/sign_config.py --help` for full usage.

---

## 11. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `No WebRequest permission` in Journal | Telegram URL not whitelisted | Add `https://api.telegram.org` in MT5 Options → Expert Advisors |
| Dashboard not visible | Wrong chart TF or EA not attached | Check Experts tab → confirm EA is running |
| No trades after 3 days | `InpExecQual_Mode=2` with no shadow data | Set `InpExecQual_Mode=1` for one week first |
| `SymbolNotFound` for e.g. `XAUUSD` | Broker uses `GOLD` instead | Set `InpAutoResolveSymbols=true` or use exact name in `InpSymbols` |
| Telegram messages not received | Wrong token or chat ID | Check `MSPB_Telegram.cfg`; test with `/getUpdates` URL |
| EA opens duplicate trades | Two instances with same magic | Use `InpMagicPerSymbol=true` or ensure only one EA instance |
| `BROKER DISCONNECTED` Telegram alert | VPS connectivity issue | Check VPS uptime; consider automatic reconnect script |
