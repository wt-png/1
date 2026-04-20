# Session Template — MSPB EA

Gebruik dit template vóór elke Copilot-agent sessie (punt 1 & 2 van het verbeterplan).

---

## 🎯 Sessiedoel

> _Één zin. Concreet en meetbaar._

**Doel:** <!-- bijv. "Fix image display in user attachments" -->

---

## ✅ Acceptatiecriteria

Minimaal 2–4 concrete checks. De sessie is klaar als **alle** items aangevinkt zijn.

- [ ] <!-- bijv. "Screenshot-bijlagen renderen correct in de GitHub UI" -->
- [ ] <!-- bijv. "Geen regressions in bestaande tests (pytest groen)" -->
- [ ] <!-- bijv. "Code review feedback verwerkt" -->
- [ ] <!-- bijv. "CHANGELOG bijgewerkt" -->

---

## 📦 Verwachte output

| Type | Beschrijving |
|------|-------------|
| Bestanden gewijzigd | <!-- bijv. MSPB_Expert_Advisor.mq5, tools/test_*.py --> |
| Tests | <!-- bijv. alle 66 pytest-tests groen --> |
| Documentatie | <!-- bijv. docs/PARAMETERS.md bijgewerkt --> |
| PR | <!-- bijv. PR #XX aangemaakt/bijgewerkt --> |

---

## 🔪 Taakverdeling (analyse → implementatie → validatie)

Splits de sessie in maximaal 3 sub-taken voor de agent. Dit maakt voortgang en foutopsporing sneller.

| # | Sub-taak | Type | Status |
|---|----------|------|--------|
| 1 | | analyse | ⬜ |
| 2 | | implementatie | ⬜ |
| 3 | | validatie | ⬜ |

---

## 🔗 Context

- **Branch:** `copilot/...`
- **EA versie:** v<!-- XX.X -->
- **Gerelateerde issues/PRs:** #
- **Vorige sessie:** <!-- link of beschrijving -->

---

## 📝 Notities

<!-- Alles wat de agent moet weten: bekende randgevallen, afhankelijkheden, etc. -->
