# Debug Template — MSPB EA

Gebruik dit template voor elk bug-rapport of probleemanalyse waarbij een screenshot betrokken is (punt 3 van het verbeterplan).

---

## 🐛 Probleem (één zin)

<!-- bijv. "Image-attachment toont niet in GitHub Copilot agent-sessie" -->

---

## 📸 Screenshot / visueel bewijs

<!-- Plak screenshot hier, of voeg URL toe -->
<!-- bijv. https://github.com/user-attachments/assets/... -->

**Wat is zichtbaar in de screenshot?**
<!-- Beschrijf kort wat je ziet -->

---

## 🌍 Context

| Veld | Waarde |
|------|--------|
| EA versie | v<!-- XX.X --> |
| MT5 build | <!-- bijv. 4112 --> |
| OS | <!-- bijv. Windows 11 --> |
| Branch | `copilot/...` |
| Datum/tijd | <!-- YYYY-MM-DD HH:MM UTC --> |

---

## 🔁 Reproduceerstappen

1. <!-- Open MT5 → attach EA → ... -->
2. 
3. 

---

## ✅ Verwacht gedrag

<!-- Wat zou er moeten gebeuren? -->

## ❌ Werkelijk gedrag

<!-- Wat gebeurt er in werkelijkheid? -->

---

## 📋 Logs / build-output

```
<!-- Plak hier relevante log-regels, compile-errors, of pytest-output -->
```

**Relevante EA-variabelen of parameters:**

```
<!-- bijv. InpUseMLEntryGate=true, InpEntryDelay_Ms=200 -->
```

---

## 🔍 Mogelijke oorzaken

- [ ] <!-- bijv. Verkeerde bestandslocatie voor ml_thresholds.json -->
- [ ] <!-- bijv. Race-condition in OnTradeTransaction -->
- [ ] <!-- bijv. Spread-filter te restrictief -->

---

## 🛠️ Oplossingsrichting

<!-- Welke aanpak ga je proberen? Welke bestanden? -->

---

## ✔️ Verificatie na fix

- [ ] Probleem is niet meer reproduceerbaar
- [ ] Alle bestaande tests groen (`pytest tools/ -v`)
- [ ] Geen nieuwe CodeQL/security waarschuwingen
- [ ] Screenshot van werkende situatie toegevoegd
