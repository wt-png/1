# Benchmark Standards — MSPB EA MT5 Backtests

Gebruik deze standaard voor **elke** backtest-vergelijking (punt 5 van het verbeterplan).  
Gebruik altijd dezelfde parameters zodat resultaten onderling vergelijkbaar zijn.

---

## 📅 Standaard backtest-configuratie

| Parameter | Waarde |
|-----------|--------|
| **Periode** | 2022-01-01 → 2024-12-31 (3 jaar) |
| **Model** | Every tick based on real ticks |
| **Initieel kapitaal** | 10.000 EUR |
| **Leverage** | 1:30 |
| **Spread** | Actueel (variabel, niet vast) |
| **Commissie** | Per broker-setting (zie `InpCommission`) |
| **Slippage** | 3 punten (tenzij anders aangegeven) |

---

## 🔣 Standaard symbolen

Run altijd op dezelfde 6 symbolen:

| # | Symbool | Sessie |
|---|---------|--------|
| 1 | EURUSD | London/NY |
| 2 | GBPUSD | London/NY |
| 3 | USDJPY | Tokyo/London |
| 4 | AUDUSD | Sydney/London |
| 5 | USDCHF | London/NY |
| 6 | USDCAD | NY |

---

## 📊 Vaste KPI's — vergelijkingstabel

Vul in bij elke backtest-run:

| KPI | Baseline | Vorige run | Huidige run | Δ vs baseline |
|-----|----------|------------|-------------|---------------|
| Netto winst (€) | | | | |
| Profit Factor | | | | |
| Winrate (%) | | | | |
| Gemiddelde winst (€) | | | | |
| Gemiddelde verlies (€) | | | | |
| Expectancy (€/trade) | | | | |
| Max Drawdown (€) | | | | |
| Max Drawdown (%) | | | | |
| Relatieve Drawdown (%) | | | | |
| Sharpe Ratio | | | | |
| Calmar Ratio | | | | |
| Totaal trades | | | | |
| Aantal long trades | | | | |
| Aantal short trades | | | | |
| Gem. trade duur (bars) | | | | |

---

## 🚦 Go / No-Go drempelwaarden

Een wijziging is **acceptabel** als aan alle onderstaande criteria wordt voldaan:

| KPI | Minimum | Maximum |
|-----|---------|---------|
| Profit Factor | ≥ 1.30 | — |
| Winrate | ≥ 45% | — |
| Max Drawdown (%) | — | ≤ 15% |
| Relatieve Drawdown (%) | — | ≤ 20% |
| Sharpe Ratio | ≥ 0.80 | — |
| Netto winst vs. baseline | ≥ -5% | — |

Als een KPI buiten de grens valt: **niet mergen**, eerst analyseren met `tools/analyse_mae_mfe.py`.

---

## 📁 Opslag backtest-resultaten

Sla backtest-rapporten op als:

```
docs/backtests/YYYY-MM-DD_vXX.X_SYMBOL.html
docs/backtests/YYYY-MM-DD_vXX.X_summary.md
```

Gebruik de `tools/analyse_mae_mfe.py` voor MAE/MFE-analyse na elke run.

---

## 🔄 Walk-Forward Optimalisatie (WFO)

Voor grotere wijzigingen (nieuwe entry-logica, nieuwe filters):

```bash
python tools/wfo_pipeline.py --symbol EURUSD --start 2022-01-01 --end 2024-12-31
```

- IS-periode: 18 maanden
- OOS-periode: 6 maanden
- Minimale OOS Profit Factor: 1.20

---

## 📝 Opmerkingen bij de run

```
EA versie    : v
Datum run    : 
Gewijzigd    : 
Bijzonderheden:
```
