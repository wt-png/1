# MSPB Expert Advisor — v21.0

MultiSymbol Pullback Scalper voor MetaTrader 5.

## Quick start
1. Compileer `MSPB_Expert_Advisor.mq5` in MetaEditor (MT5)
2. Voeg toe aan EURUSD M1-grafiek
3. Stel parameters in conform `docs/BASELINE.md`
4. Volg het uitrolprotocol in `docs/DEPLOYMENT.md`

## KPI-drempelwaarden
Zie `docs/KPI_TARGETS.md` voor go/no-go criteria.

## Analyse tools (Python ≥ 3.9)
```bash
pip install pandas numpy pytest
python tools/session_analysis.py --file ml_export_v2.csv
python tools/monte_carlo_analysis.py --file ml_export_v2.csv
python -m pytest tools/test_tools.py -v
```

## Versie-overzicht
Zie `CHANGELOG.md`.
