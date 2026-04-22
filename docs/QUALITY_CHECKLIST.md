# Quality Checklist — MSPB EA

Doorloop deze checklist **vóór elke PR-afronding** (punt 4 van het verbeterplan).  
Alle items moeten groen zijn voordat een PR gemerged wordt.

---

## 1. Tests

- [ ] `pytest tools/ -v` — alle tests groen (huidig aantal: zie CHANGELOG)
- [ ] Geen tests verwijderd of uitgeschakeld zonder motivatie
- [ ] Nieuwe logica heeft minstens één test

```bash
# Voer uit vanuit de repo-root:
pytest tools/ -v --tb=short
```

---

## 2. Lint / codestijl

- [ ] Python-bestanden: `flake8 tools/ --max-line-length=120`
- [ ] MQL5-bestanden: handmatig gecompileerd in MetaEditor (0 errors, 0 warnings)

```bash
flake8 tools/ --max-line-length=120
```

---

## 3. Security scan

- [ ] CodeQL-scan uitgevoerd via `parallel_validation` (geen nieuwe high/critical findings)
- [ ] Geen secrets of credentials hardcoded
- [ ] `InpTGConfigFile` / `InpMLThresholdFile` paden niet hard-coded in code

---

## 4. Regressiecheck gerelateerde onderdelen

Vink aan welke modules geraakt zijn door de wijziging en test ze expliciet:

| Module | Bestand | Getest? |
|--------|---------|---------|
| Entry logic | `MSPB_EA_Entry.mqh` | ⬜ |
| Risk | `MSPB_EA_Risk.mqh` | ⬜ |
| Telegram | `MSPB_EA_Telegram.mqh` | ⬜ |
| Dashboard | `MSPB_EA_Dashboard.mqh` | ⬜ |
| Order Exec | `MSPB_EA_OrderExec.mqh` | ⬜ |
| ML gate | `tools/online_retrain.py` | ⬜ |
| WFO pipeline | `tools/wfo_pipeline.py` | ⬜ |
| Symbol ranking | `tools/rank_symbols.py` | ⬜ |

---

## 5. Documentatie

- [ ] `CHANGELOG.md` bijgewerkt met versienummer en beschrijving
- [ ] `docs/PARAMETERS.md` bijgewerkt als nieuwe `Inp*` parameters zijn toegevoegd
- [ ] `EA_VERSION` constante in `MSPB_Expert_Advisor.mq5` verhoogd

---

## 6. PR-beschrijving

- [ ] PR-titel beschrijft de wijziging duidelijk
- [ ] PR-beschrijving bevat: doel, wat gewijzigd, hoe getest
- [ ] Screenshot of backtest-resultaat toegevoegd indien van toepassing

---

## Snelle referentie

```bash
# Alle checks in één keer:
pytest tools/ -v --tb=short && flake8 tools/ --max-line-length=120
```
