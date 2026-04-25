# MSPB Expert Advisor — Changelog

All notable changes to this project are documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [v22.13] — 2026-04-25

### Changed — Alle filters uitgeschakeld; alleen ImprovedEntry actief

Alle externe guards en kwaliteitsfilters zijn op `false` / `0.0` gezet.
Alleen de kern van `EntrySignal_Improved` blijft actief:
EMA-touch op entry-TF + continuation candle + EMA-close bevestiging.

**Uitgeschakeld:**
- `InpUseATRFilter` false
- `InpUseADXFilter` false
- `InpEntryUseFollowThrough` false
- `InpEntryUseWickFilter` false
- `InpEntryUseRangeATRFilter` false
- `InpEntryMinBodyATRFrac` 0.0
- `InpEntryMinCloseInRangeFrac` 0.0
- `InpImprovedEntry_ATRMinPips` 0.0
- `InpEntryRequirePullbackOrigin` false
- `InpUseHTFBias` false
- `InpBias_FailClosed` false
- `InpBiasMinEMASepPips` 0.0
- `InpUseCorrelationGuard` false
- `InpUseSymbolCooldown` false
- `InpUseVolRegime` false
- `InpVolLowBlockEntries` false
- `InpUseSessions` false
- `InpUsePortfolioRiskGuard` false

**Actief (ongewijzigd):**
- `InpUseImprovedEntry` true — EMA-touch + continuation candle kern-logica

---



### Fixed — Alle filters correct gezet (win-rate 12.5% → verwacht beter)

Analyse van de backtest-resultaten na v22.11 (win-rate ~12.5%, 87.5% verliezers) identificeerde
drie filterproblemen die samen verantwoordelijk zijn voor het aanhoudende verlies.

#### Fix 1: InpBiasMinEMASepPips — H4 EMA-scheiding was effectief geen filter (nieuw)

**Probleem:** `EntrySignal_Improved` controleerde of de H4 EMA50/EMA200 minstens **1 pip** uit
elkaar lagen om een "trend" te vormen. Voor AUDCAD (pip = 0.0001) betekent dit dat een scheiding
van 0.0002 (2 pips) al als een geldige bullish of bearish bias werd geaccepteerd. In werkelijkheid
is een H4-scheiding van 2 pips zinloos — de twee lijnen zijn vrijwel identiek, de markt is flat.

**Fix:** Nieuw input `InpBiasMinEMASepPips = 5.0` — de H4 EMA50/200 moeten minstens 5 pips
gescheiden zijn voordat een trend als geldig wordt beschouwd. Dit blokkeert entries in rangy,
trendloze H4-marktfasen waar de bias-filter voorheen kleurloos was.

| Parameter | Oud | Nieuw | Doel |
|-----------|-----|-------|------|
| *(hardcoded)* | 1 pip | `InpBiasMinEMASepPips = 5.0` pips | Echte trendvereiste op H4 |

#### Fix 2: InpBias_FailClosed — bias-fout liet beide richtingen door (parameter)

**Probleem:** `InpBias_FailClosed = false` betekent: als de H4 biasdata niet beschikbaar is
(bijv. bij start of dataverlies), retourneert `GetBiasDirCached` richting = 0. In dat geval
blokkeren de checks `bdir>0 && !isBuy` en `bdir<0 && isBuy` NIET — zowel LONG als SHORT mogen
openen, terwijl er geen trendbevestiging is.

**Fix:** `InpBias_FailClosed = true` — blokkeert entries wanneer biasdata niet beschikbaar is
(retourneert bdir=99, gevolgd door directe `return` in ProcessSymbol).

| Parameter | Oud | Nieuw | Doel |
|-----------|-----|-------|------|
| `InpBias_FailClosed` | `false` | `true` | Geen entries zonder H4 trendbevestiging |

#### Fix 3: InpVolLowBlockEntries — lean-test instelling stond uit in productie (parameter)

**Probleem:** `InpVolLowBlockEntries = false` stond expliciet als "lean-test: UIT" in de code.
In productie moet dit `true` zijn: in een low-vol regime (ATR-percentiel ≤ 20%) wordt de
lot-grootte gehalveerd (0.5×). Zo neemt de EA nog wel deel aan valide setups, maar met
sterk verminderd risico in rustige/choppy marktomstandigheden.

**Fix:** `InpVolLowBlockEntries = true`

| Parameter | Oud | Nieuw | Doel |
|-----------|-----|-------|------|
| `InpVolLowBlockEntries` | `false` | `true` | 0.5× lot in low-vol regime |

#### Verwachte impact

| Metric | Verwachting |
|--------|-------------|
| Aantal entries | ⬇️ Minder (H4 flat-markt geblokkeerd door 5-pip EMA-eis) |
| Win-rate | ⬆️ Beter (entries alleen in echte H4-trends) |
| Risico in low-vol | ⬇️ Lager (0.5× lot in rustige markten) |
| Veiligheid bij dataverlies | ⬆️ Beter (geen entries zonder biasdata) |

---

## [v22.11] — 2026-04-24

### Added — Pullback-origin filter in EntrySignal_Improved

Analyse van de backtest-resultaten (PF ≈ 0.11, win-rate ~5%) na v22.10 toonde aan dat de EA
kans heeft om te vuren op EMA-oscillatie-setups: situaties waar de prijs al meerdere bars
rond de EMA zweeft en elke kleine aanraking als "pullback" wordt gecategoriseerd.  Dit zijn
geen echte pullbacks — er is geen duidelijke richting vanwaar de prijs de EMA nadert.

#### Probleem: EMA-oscillatie geeft nep-pullback-signalen

In `EntrySignal_Improved` controleerde Step 4 alleen of bar[1] de EMA raakte (low≤ema≤high).
Als de prijs al meerdere bars rond de EMA zweeft, voldoet elke bar aan die eis. Gevolg:
- De EA vuurt entries terwijl de markt sideways is op entry-TF.
- De HTF-bias (H4 EMA50>EMA200) is de enige trendbevestiging; op M5 is de prijs flat.
- Win-rate blijft laag: entries worden genomen in een kansloze context.

#### Fix: Step 4b — pullback-origin check (nieuw)

**Nieuw input:** `InpEntryRequirePullbackOrigin = true`

**Logica:** bar[2] (de bar vóór de signaalkandel) moet gesloten hebben op de juiste kant van
de EMA, als bewijs dat de prijs VANUIT die richting de EMA naderde:

| Richting | Vereiste bar[2] positie | Redenering |
|----------|------------------------|------------|
| BUY (uptrend) | close > ema2 (bar[2] EMA) | Prijs was boven EMA, zakte terug naar EMA in bar[1] |
| SELL (dntrend) | close < ema2 (bar[2] EMA) | Prijs was onder EMA, steeg terug naar EMA in bar[1] |

Als bar[2] op de VERKEERDE kant sloot (bijv. bar[2] al onder EMA bij een BUY-setup), is er
geen sprake van een klassieke pullback — de prijs was al door de EMA heen of zweefde eronder.

**Verschil met de verwijderde FollowThrough-check (v22.10):**

FollowThrough eiste dat bar[2] dezelfde CANDLE-RICHTING had als bar[1] (beide bullish bij BUY).
Dit blokkeerde het klassieke pullback-patroon waarbij bar[2] bearish is (de terugval omhoog in
uptrend) en bar[1] bullish is (de keercandle). Resultaat: 5.56% win-rate.

De nieuwe pullback-origin check gebruikt niet de candle-richting maar de **EMA-positie**:
- bar[2] bearish MÉT close boven EMA → **correct** (pullback in uptrend) → toegelaten
- bar[2] bearish MET close onder EMA → **fout** (prijs was al door EMA) → geblokkeerd
- Klassieke pullback bars blijven gewoon doorgelaten ✓

#### Verwachte impact

- Selecteert uitsluitend bars waar een duidelijke EMA-nadering vanuit de trendzijde plaatsvond
- Filtert EMA-oscillatie en post-doorbraak false entries
- Win-rate verwacht omhoog door hogere setup-kwaliteit



## [v22.10] — 2026-04-23

### Fixed — 3 logische bugs die verlies veroorzaakten

Analyse van backtest-resultaten (win-rate 5.56%, profit factor 0.07) identificeerde drie concrete
code-fouten die samen verantwoordelijk zijn voor het structurele verlies.

#### Bug 1: HTF-bias las huidige (intrabar) candle — repaint

In `EntrySignal_Improved` werd de HTF-trend (EMA-fast vs EMA-slow op `InpBiasTF`) berekend met
`CopyBuffer(..., count=1)`. Dat geeft bar[0] = de **nog lopende** candle op de bias-timeframe (bijv.
H4). De EMA-waarde van een lopende H4-candle wijzigt elke tick, waardoor de trend-richting intrabar
kan omklappen — dit is een **repaint-bug**.

**Fix:** gebruik `CopyLast(..., count=2)` en lees index `[1]` (= laatste gesloten bar).

#### Bug 2: GetBiasDirCached — zelfde repaint-bug in bias-cache

Dezelfde fout stond ook in `GetBiasDirCached` (de cache die `InpUseHTFBias` gebruikt):
`CopyBuffer(..., count=1, f)` → `fastOut = f[0]` = lopende bar.

**Fix:** count=2, gebruik `f[1]` / `s[1]` (SetAsSeries=true).

#### Bug 3: FollowThrough in ImprovedEntry blokkeerde de BESTE pullback-setups (hoofd-oorzaak)

In v22.8 werd de `InpEntryUseFollowThrough`-check toegevoegd aan `EntrySignal_Improved` om spike-
entries te voorkomen. Dit was een verkeerde toepassing van een Setup1-filter op de ImprovedEntry-
logica en veroorzaakte een **omgekeerde kwaliteitsselectie**:

- **Klassiek pullback-patroon (GOED):** bar[2] beweegt tégen de trend (de pullback omhoog),
  bar[1] keert terug mét de trend (het signal). → FollowThrough **blockt dit** (bar[2] ≠ richting
  bar[1]).
- **Slechte setup:** bar[2] én bar[1] beide in trend-richting, bar[1] raakt toevallig de EMA.
  → FollowThrough **laat dit door**.

Resultaat: de EA selecteerde alleen de slechtste entries en verwierp de beste → win-rate 5.56%.

De bestaande filters in ImprovedEntry (EMA-close-bevestiging Step 6, close-in-range Step 7, wick-
filter Step 7) zijn voldoende bescherming tegen spike-entries. De FollowThrough-check is hier
overbodig én schadelijk. In Setup1 blijft hij wél actief.

**Fix:** Step 5b (FollowThrough) verwijderd uit `EntrySignal_Improved`.

---

## [v22.9] — 2026-04-23

### Changed — Conservatief anti-loss settings-profiel aangescherpt

Omdat er nog te veel verlies was, zijn de standaardinstellingen verder verlaagd op risico en
tradefrequentie, en zijn de remmen op drawdown aangescherpt.

| Parameter | Oud | Nieuw | Doel |
|-----------|-----|-------|------|
| `InpMaxPositionsTotal` | 3 | 2 | Minder gelijktijdige exposure |
| `InpRiskPercent` | 0.25 | 0.20 | Lager basisrisico per trade |
| `InpMaxRiskPercentPerTrade` | 0.50 | 0.35 | Hardere risicolimiet per trade |
| `InpMaxPortfolioRiskPct` | 2.0 | 1.5 | Lager totaalrisico op portfolio |
| `InpMinATR_Pips` | 8.0 | 10.0 | Ruis-/lage-volatiliteit entries blokkeren |
| `InpMinADXForEntry` | 25.0 | 28.0 | Alleen sterkere trends toelaten |
| `InpMinADXEntryFilter` | 25.0 | 28.0 | Alleen sterkere trend op entry-TF |
| `InpImprovedEntry_ATRMinPips` | 2.0 | 6.0 | Extra kwaliteitsfilter op ImprovedEntry |
| `InpMinMinutesBetweenEntries` | 60 | 90 | Minder overtrading in zelfde context |
| `InpMaxEntriesPerSymbolPerDay` | 5 | 3 | Minder herhaalentries per symbool |
| `InpMaxEntriesTotalPerDay` | 10 | 6 | Lagere totale dagfrequentie |
| `InpLossStreakBlockAfter` | 3 | 2 | Sneller blokkeren na verliesreeks |
| `InpLossStreakBlockMinutes` | 120 | 240 | Langer herstellen na verliesreeks |
| `InpDailyLoss_PctBalance` | 2.0% | 1.5% | Eerder dagstop bij verlies |
| `InpDailyLoss_CloseAll` | false | true | Open posities sluiten bij dagstop |
| `InpEquityCB_Pct` | 5.0% | 4.0% | Eerdere equity drawdown-stop |

#### Verwachte impact

- Minder trades en minder simultane blootstelling
- Lagere drawdown en kleinere verliesclusters
- Betere kapitaalbescherming bij slechte marktfases

---

## [v22.8] — 2026-04-23

### Fixed — Oorzaken van geldverlies aangepakt

Analyse van de EA-logica identificeerde zes concrete oorzaken van verlies. Alle zes zijn opgelost.

#### Fix 1: FollowThrough-check toegevoegd aan EntrySignal_Improved (code fix)

`EntrySignal_Improved` miste de `InpEntryUseFollowThrough`-check die in `Setup1` wél aanwezig is.
Hierdoor werden eenmalige spike-candles als geldig signaal geaccepteerd. Nu vereist ImprovedEntry
ook dat de vorige candle dezelfde richting heeft als de signaalkandel.

- Bars-array vergroot van 2 → 3 (`CopyRatesLast(..., 3, r)`)
- Nieuwe Step 5b: `if(InpEntryUseFollowThrough) { prevBuy != isBuy → return false; }`

#### Fix 2–3: Break-Even te vroeg (BE_At_R en BE_LockPips)

| Parameter | Oud | Nieuw | Reden |
|-----------|-----|-------|-------|
| `InpBE_At_R` | 0.8 | 1.2 | BE op 0.8R triggerde tijdens normaal marktgeluid → positie sloot op ~nul |
| `InpBE_LockPips` | 1.0 | 3.0 | Te kleine buffer na BE; kleine dip sloeg BE-stop meteen |

#### Fix 4: TimeStop sloot geen diep verliezende trades

| Parameter | Oud | Nieuw | Reden |
|-----------|-----|-------|-------|
| `InpTimeStopMinAbsR` | 0.15 | 0.50 | Trades op –0.4R na 8 bars bleven open tot volledige SL-hit |

#### Fix 5: Minimum entryGap te kort

| Parameter | Oud | Nieuw | Reden |
|-----------|-----|-------|-------|
| `InpMinMinutesBetweenEntries` | 20 | 60 | Na slechte M5-entry kon EA 20min later opnieuw dezelfde verkeerde setup handelen |

#### Fix 6: TP_RR te laag t.o.v. BE-effect en spread

| Parameter | Oud | Nieuw | Reden |
|-----------|-----|-------|-------|
| `InpTP_RR` | 1.8 | 2.2 | Met BE op 1.2R en spread-aftrek was effectief RR te laag voor positieve verwachte waarde |

#### Verwachte impact

| Metric | Verwachting |
|--------|-------------|
| Aantal entries | ⬇️ Minder (FollowThrough filter + langere entryGap) |
| Win-rate | ⬆️ Beter (geen spike-entries meer) |
| Gemiddelde winst | ⬆️ Groter (BE geeft meer ruimte + hogere TP) |
| Gemiddeld verlies | ⬇️ Kleiner (TimeStop snijdt verliezers tijdig) |
| Profit Factor | ⬆️ Significant hoger |

---

## [v22.7] — 2026-04-23

### Fixed — ImprovedEntry kwaliteitsfilters toegevoegd

**Probleem**: `EntrySignal_Improved` miste de kwaliteitsfilters die `EntrySignal_Setup1` wél
heeft. Omdat ImprovedEntry Setup1 volledig vervangt, werden deze filters nooit uitgevoerd —
lage-kwaliteit entries kwamen door die in Setup1 geblokkeerd zouden zijn.

#### Stap 6: EMA-close bevestiging (nieuw)

| Richting | Vereiste | Reden |
|----------|----------|-------|
| BUY | `close >= EMA (InpEMA_Period)` | EMA moet als steun werken — als close onder EMA sluit, heeft de pullback de EMA doorbroken |
| SELL | `close <= EMA (InpEMA_Period)` | EMA moet als weerstand werken — als close boven EMA sluit, is de neerwaartse kracht afwezig |

#### Stap 7: Kwaliteitsfilters (hergebruikt bestaande inputs)

| Filter | Input | Waarde (live-safe) | Effect |
|--------|-------|--------------------|--------|
| Body / ATR fractie | `InpEntryMinBodyATRFrac` | 0.20 | Kleine doji-achtige bars geblokkeerd |
| Close in range | `InpEntryMinCloseInRangeFrac` | 0.60 | BUY moet in bovenste 40% sluiten; SELL in onderste 40% |
| Tegengestelde wick | `InpEntryUseWickFilter` + `InpEntryMaxOppWickBodyFrac=0.45` | aan | Bars met grote tegengestelde wick geblokkeerd |

Alle drie filters hergebruiken bestaande inputs — geen nieuwe parameters nodig.

#### Verwachte impact

| Metric | Verwachting |
|--------|-------------|
| Aantal entries | ⬇️ Minder entries (lagere kwaliteit gefilterd) |
| Win-rate | ⬆️ Beter (alleen hoge-kwaliteit setups door) |
| Verlies per trade | ⬇️ Minder entries aan de verkeerde kant van EMA |
| Profit Factor | ⬆️ Significant hoger |

---

## [v22.6] — 2026-04-23

### Fixed — Drie kritieke bugs gecorrigeerd

**Probleem**: backtests toonden 100% eén-richting trades (bijv. 78 SHORT / 0 LONG) met Profit Factor ~0.04.

#### Bug 1: Setup2 contrarian-lock bij ImprovedEntry (kritiek)

`EntrySignal_Setup2` geeft altijd de **tegengestelde** richting van de M5-candle (contrarian).
Wanneer `InpUseImprovedEntry=true` actief is én H4 in dalende trend zit:

| Situatie | ImprovedEntry | Setup2 standalone | Resultaat |
|----------|--------------|-------------------|-----------|
| M5 bearish bar | ✅ SELL | — | SELL |
| M5 bullish bar | ❌ faalt | contrarian van bullish → SELL | SELL |

→ **100% SELL in elke aanhoudende trend**, ongeacht de werkelijke marktrichting.

**Fix**: Setup2 standalone wordt **niet** uitgevoerd wanneer `InpUseImprovedEntry=true`.
Setup2 confluence-tag (`S1+S2`) wordt ook overgeslagen wanneer ImprovedEntry actief is.

#### Bug 2: ADX-filter werkte niet voor ImprovedEntry

Wanneer `InpUseImprovedEntry=true` bleven `adxTrend` en `adxEntry` op `999` (pass-through),
waardoor de ADX-filter nooit kon blokkeren — ook niet bij zwakke, ruis-achtige markten.

**Fix**: Na `EntrySignal_Improved` worden werkelijke ADX-waarden gelezen van
`g_adxHandle` en `g_adxEntryHandle` wanneer `InpUseADXFilter=true`.

#### Bug 3: Lean-test defaults niet teruggedraaid naar live-safe

Alle lean-test parameters zijn hersteld naar productie-veilige waarden:

| Parameter | Lean-test | v22.6 (live-safe) |
|-----------|-----------|-------------------|
| `InpMinATR_Pips` | 4.0 | **8.0** |
| `InpMinADXForEntry` | 15.0 | **25.0** |
| `InpMinADXEntryFilter` | 15.0 | **25.0** |
| `InpEntryMinBodyATRFrac` | 0.10 | **0.20** |
| `InpEntryUseFollowThrough` | false | **true** |
| `InpEntryUseWickFilter` | false | **true** |
| `InpEntryUseRangeATRFilter` | false | **true** |
| `InpEntryMinRangeATRFrac` | 0.20 | **0.35** |
| `InpEntryMinCloseInRangeFrac` | 0.45 | **0.60** |
| `InpUseHTFBias` | false | **true** |
| `InpUseCorrelationGuard` | false | **true** |
| `InpUseVolRegime` | false | **true** |
| `InpUseSetup2` | true | **false** |
| `InpUseSessions` | false | **true** |
| `InpMaxSpreadPips_FX` | 3.5 | **2.0** |
| `InpMinMinutesBetweenEntries` | 5 | **20** |
| `InpMaxEntriesPerSymbolPerDay` | 10 | **5** |
| `InpMaxEntriesTotalPerDay` | 25 | **10** |
| `InpLossStreakBlock_Enable` | false | **true** |
| `InpDailyLoss_PctBalance` | 5.0 % | **2.0 %** |
| `InpEquityCB_Pct` | 15.0 % | **5.0 %** |
| `InpEnableMLExport` | true | **false** |

### Niet gewijzigd (bewust behouden uit v22.4)
- `InpCorrUseWeightedExposure = false` — gewogen lot-som blokkeert te veel valide paren
- `InpVolLowBlockEntries = false` — ATR-min doet hetzelfde; gebruik VolHighRiskMult voor lot-scaling
- `InpSL_ATR_Mult = 1.5`, `InpTP_RR = 1.8` — v22.2 waarden blijven correct

---



### Added — EntrySignal_Improved: Trend + Pullback + Continuation edge

**Doel**: vervang de te-late breakout entry door een vroege pullback entry. Betere RR, meer trades, minder filters.

#### Nieuwe input parameters

| Parameter | Default | Beschrijving |
|-----------|---------|-------------|
| `InpUseImprovedEntry` | `true` | Schakelt verbeterde entry in; vervangt Setup1 als primair signaal |
| `InpImprovedEntry_ATRMinPips` | `2.0` | Minimale ATR (pips) voor improved entry — beschermt tegen dode markten |

#### Logica `EntrySignal_Improved`

```
1. Trend (HTF): EMA50 > EMA200 op InpBiasTF (standaard H4)
              → geeft alleen BUY setups in uptrend, alleen SELL setups in downtrend
              → vereist minimale EMA-scheiding (1 pip) om vlakke crossovers te vermijden

2. Pullback:   Laatste gesloten bar op InpEntryTF (standaard M5) raakt EMA50
              → bar.low <= EMA50 <= bar.high

3. Trigger:   Continuation candle na de EMA-aanraking
              → close > open → BUY
              → close < open → SELL
              → Doji (close == open) → overgeslagen
```

#### Integratie

- Vervangt Setup1 volledig als `InpUseImprovedEntry = true`
- BreakPrevHighLow en Setup2 worden **geskipt** (zijn redundant — pullback entry geeft al betere timing)
- Alle externe guards blijven actief: ATR-min, ADX-filter, portfolio cap, correlatie, circuit breakers
- Audit-log toont `setup="IMP"` voor improved entry trades
- Bias handles (`g_biasFastHandle`, `g_biasSlowHandle`) worden nu ook aangemaakt als `InpUseHTFBias=false` maar `InpUseImprovedEntry=true`

#### Verwachte impact

| Metric | Verwachting |
|--------|-------------|
| Handelsfrequentie | ⬆️ 2–4x meer trades |
| RR | ⬆️ Beter (entry dichter bij EMA = kleinere SL) |
| Winrate | ⬇️ Licht lager (meer setups, niet elk ideaal) |
| Netto winst | ⬆️ Significant hoger |

#### Aandachtspunten

- `InpBiasTF = H4` is de trend-TF — zet naar `H1` voor snellere trendherkenning op kleinere accounts
- `InpEMA_Period = 50` is de pullback-EMA — consistent met de bias EMA-fast
- Setup1 is **niet verwijderd** — zet `InpUseImprovedEntry = false` om terug te vallen op de oude entry

---

## [v22.4] — 2026-04-23

### Changed — Over-filtering reductie: block → scale, drempelwaarden versoepeld

**Doel**: verhoog handelsfrequentie zonder de risicobeheersing op te geven. Elke fix zet een hard `return` om naar een gedoseerde aanpassing van lot-grootte of risico-factor.

| # | Component | Oud | Nieuw | Reden |
|---|-----------|-----|-------|-------|
| 1 | `BreakPrevHighLow` | `r[1].close > r[2].high` | `r[1].close > r[2].close` | Minder laat instappen, betere RR; close>prev.close bevestigt al momentum |
| 2 | `VolBlock` in `ProcessSymbol` | `return;` (hard blok) | `volMult = min(volMult, 0.5)` (risk scaling) | Lage vol ≠ slechte trade; lot-grootte halveert maar trade gaat door |
| 3 | `EqRegime_Update` drempels | `<2% neutral`, `<5% caution`, `≥5% defensive` | `<5% neutral`, `<10% caution`, `≥10% defensive` | Normale DD triggerde al risk reduction; nieuwe waarden volgen marktpraktijk |
| 4 | `InpCorrAbsThreshold` | `0.85` | `0.90` | Veel FX-paren zijn structureel >0.85 gecorreleerd; 0.90 filtert alleen echte clusters |
| 5 | `InpCorrUseWeightedExposure` | `true` | `false` | Gewogen lot-som blokkeert ook paren met kleine posities; simpele drempel is beter |
| 6 | SL-fallback in `CurrentPortfolioRiskPct` | `eq * (portfolioCap/100)` | `eq * 0.5 * (portfolioCap/100)` | Één positie zonder SL bevroor eerder alle entries; nu gedeeltelijke impact |
| 7 | `FailSafe_Trip` gate | `return;` (alle entries gestopt) | `g_riskMult = min(g_riskMult, 0.2)` | File-open / ML-fail stopt nu niet de EA maar reduceert lot-grootte drastisch |
| 8 | `OnTester` trade-penalty | Soft penalty via `InpTester_MinTradesForFullScore` | Extra harde drempel: `if(trades<100) tradeFactor *= trades/100` | Voorkomt overfit op strategieën met weinig trades met hoge PF |
| 9 | Setup2 activatie | Alleen fallback als BreakPrev faalt | Ook als confirmatie als S1+S2 dezelfde richting geven (`setup="S1+S2"`) | 30–50% meer confluence-trades; geen richting-conflict want zelfde richting vereist |

### Niet gewijzigd (bewust)

- `DailyLoss CB` en `EquityCB` — harde circuit breakers blijven als laatste vangnet.
- `InpLossStreakBlock_Enable = false` — bewaard uit lean-test profiel.
- `InpUseSetup2 = false` — lean-test profiel-instelling; deze fix werkt pas als Setup2 aan staat in productie.

---

## [v22.3-lean-test] — 2026-04-23

### Changed — Lean Test Profiel (minimale filters, maximale data)

**Doel**: Zoveel mogelijk trades genereren in de Strategy Tester zodat we
echte data terug krijgen om de instellingen daarna te verbeteren.
**Gebruik**: Alleen voor testdraaien / data-verzameling. Niet voor live.

| Parameter | v22.2 | v22.3-lean | Reden |
|-----------|-------|-----------|-------|
| `InpMinATR_Pips` | 8.0 | **4.0** | Meer setups doorlaten |
| `InpMinADXForEntry` | 25.0 | **15.0** | Ook matige trends meenemen |
| `InpMinADXEntryFilter` | 25.0 | **15.0** | Idem |
| `InpEntryMinBodyATRFrac` | 0.20 | **0.10** | Kleinere body toegestaan |
| `InpEntryMinCloseInRangeFrac` | 0.60 | **0.45** | Ruimere close-locatie |
| `InpEntryUseFollowThrough` | true | **false** | Geen follow-through vereist |
| `InpEntryUseWickFilter` | true | **false** | Geen wick-filter |
| `InpEntryUseRangeATRFilter` | true | **false** | Geen range/ATR-filter |
| `InpUseHTFBias` | true | **false** | Geen H4 bias filter |
| `InpUseCorrelationGuard` | true | **false** | Geen correlatie-blokkering |
| `InpUseVolRegime` | true | **false** | Geen vol-regime blokkering |
| `InpUseSetup2` | false | **true** | Fallback signaal voor extra trades |
| `InpUseSessions` | true | **false** | Handel ook buiten London/NY |
| `InpMaxSpreadPips_FX` | 2.0 | **3.5** | Meer brokers/momenten toegestaan |
| `InpMinMinutesBetweenEntries` | 20 | **5** | Minder wachttijd tussen entries |
| `InpMaxEntriesPerSymbolPerDay` | 5 | **10** | Ruimere dagcap per symbool |
| `InpMaxEntriesTotalPerDay` | 10 | **25** | Ruimere totale dagcap |
| `InpLossStreakBlock_Enable` | true | **false** | Geen verlies-streak blokkering |
| `InpDailyLoss_PctBalance` | 2.0 % | **5.0 %** | Ruimere daily-loss CB voor test |
| `InpEquityCB_Pct` | 5.0 % | **15.0 %** | Ruimere equity CB voor test |
| `InpEnableMLExport` | false | **true** | Data verzamelen voor analyse |
| `InpTester_UseCustomCriterion` | false | **true** | Custom score voor optimalisatie |

### Volgend stap na testrun
1. Export `ml_export_v2.csv` uit de tester-run.
2. Draai `python tools/wfo_pipeline.py ml_export_v2.csv` → WFO rapport.
3. Draai `python tools/stress_test.py ml_export_v2.csv` → stress-gates.
4. Zet filters die data bevestigt stap voor stap terug aan (begin met ADX en sessies).

### Filter-conflicten opgelost (v22.3 patch)

Na analyse van de entry-flow zijn drie filter-conflicten gevonden en gecorrigeerd:

| # | Conflict | Fix |
|---|---------|-----|
| 1 | **Setup2 geeft contrarian richting** — als Setup1 een BUY geeft maar BreakPrev faalt, flipt Setup2 naar SELL op dezelfde candle | `InpUseSetup2 = false` |
| 2 | **VolRegime-blok vs ATR-min filter** — beide meten volatiliteit op M5; ATR-min selecteert al op "genoeg vol", waarna VolLowBlock dezelfde bars nogmaals uitsluit | `InpVolLowBlockEntries = false`; gebruik `InpVolHighRiskMult` voor lot-scaling i.p.v. hard blok |
| 3 | **WickFilter redundant met CloseInRange** — een candle die ≥ 45 % close-in-range haalt heeft per definitie een kleine tegengestelde wick; WickFilter voegt niets toe | WickFilter was al `false` in lean-test |

> **Resterende aandachtspunten na testrun:**
> - Als HTF bias (H4) later weer aan gaat → verlaag ADX-entry drempel naar ~18 (H4 doet de grove richting al).
> - DailyLoss CB + Equity CB zijn voldoende bescherming op portfolio-niveau; LossStreakBlock staat uit in lean-test.

---

## [v22.2] — 2026-04-23

### Changed — Demo-Ready Parameter Tuning

**Goal**: Achieve positive Profit Factor on demo by reducing signal noise and improving risk/reward.

| Parameter | Old | New | Reden |
|-----------|-----|-----|-------|
| `InpEntryTF` | M1 | **M5** | M1 is te ruis-gevoelig; M5 geeft schonere signalen |
| `InpConfirmTF` | M5 | **H1** | H1 bevestiging filtert false breakouts eruit |
| `InpBiasTF` | H1 | **H4** | H4 trend-bias = alleen traden met sterke trend |
| `InpATR_Period` | 7 | **14** | Standaard periode; stabieler en minder gevoelig voor uitschieters |
| `InpADX_Period` | 7 | **14** | Standaard periode; stabieler ADX-meting |
| `InpMinADXForEntry` | 22.0 | **25.0** | Alleen instappen bij duidelijke trend |
| `InpMinADXEntryFilter` | 22.0 | **25.0** | Idem |
| `InpMinATR_Pips` | 12.0 | **8.0** | M5-bars zijn kleiner; 8 pip ATR is voldoende volatiliteit |
| `InpSL_ATR_Mult` | 1.6 | **1.5** | Iets kleiner verlies per trade |
| `InpTP_RR` | 1.4 | **1.8** | Hogere RR compenseert lagere win-rate |
| `InpTP_RR_TrendBonus` | 0.30 | **0.40** | Laat winnaars verder lopen in sterke trends |
| `InpTP_RR_TrendBonusADX` | 30.0 | **28.0** | Bonus al bij iets zwakkere trend |
| `InpTP_RR_Max` | 2.50 | **3.00** | Meer ruimte voor winnaars |
| `InpLossStreakBlockAfter` | 2 | **3** | Minder vroeg blokkeren = meer herstelopties |
| `InpLossStreakBlockMinutes` | 240 | **120** | Kortere cooldown zodat goede setups niet gemist worden |
| `InpMinMinutesBetweenEntries` | 30 | **20** | Iets meer setups per dag mogelijk |
| `InpMaxEntriesPerSymbolPerDay` | 4 | **5** | Iets meer kansen per symbool |
| `InpMaxEntriesTotalPerDay` | 8 | **10** | Meer totale kansen |

### Context
Met M1 + periode=7 genereerde de EA te veel ruis-signalen (PF ~0.73, verlies).
Door M5 entries + H1 bevestiging + H4 bias worden alleen echte trends gehandeld.
RR van 1.8 betekent dat zelfs bij 37% win-rate de EA winstgevend is.

---

## [v22.1] — 2026-04-23

### Added — Anti-Loss Hardening

**1. Daily loss circuit breaker (`InpDailyLoss_Enable`, `InpDailyLoss_PctBalance=2%`, `InpDailyLoss_CloseAll`)**
- Records the account balance at the start of each trading day (`g_dailyLossStartBal`).
- If intraday P&L drops below –`InpDailyLoss_PctBalance`% of the day-start balance, all new
  entries are halted for the remainder of the day (`g_dailyLossBreached`).
- Optional nuclear mode (`InpDailyLoss_CloseAll=true`) closes all open positions on breach.
- Resets automatically at the start of the next trading day.
- Audit-logged on trigger.

**2. Equity drawdown circuit breaker (`InpEquityCB_Enable`, `InpEquityCB_Pct=5%`)**
- Integrated into `EqRegime_Update()`.
- Sets `g_equityCBBreached=true` when live equity DD from peak ≥ `InpEquityCB_Pct`.
- Auto-clears when equity recovers back above the threshold.
- Acts as a hard entry gate above the existing loss-streak and rate-limit guards.

**3. Dashboard CB indicators**
- Status line now shows `DAILY_LOSS_CB` or `EQUITY_CB` (red) when a circuit breaker is active.

### Changed — Anti-Overtrading Defaults

| Parameter | Old | New |
|-----------|-----|-----|
| `InpLossStreakBlockAfter` | 3 | **2** |
| `InpLossStreakBlockMinutes` | 180 | **240** |
| `InpMinMinutesBetweenEntries` | 15 | **30** |
| `InpMaxEntriesPerSymbolPerDay` | 6 | **4** |
| `InpMaxEntriesTotalPerDay` | 12 | **8** |

### Changed — Entry Filter Defaults

| Parameter | Old | New |
|-----------|-----|-----|
| `InpMaxSpreadPips_FX` | 3.0 | **2.0** |
| `InpMinATR_Pips` | 10.0 | **12.0** |
| `InpMinADXForEntry` | 20.0 | **22.0** |
| `InpMinADXEntryFilter` | 20.0 | **22.0** |
| `InpUseSessions` | false | **true** (London 07–17 + NY 12–21 UTC) |
| `InpVolHighRiskMult` | 0.50 | **0.25** |

### Context
The v22.0 backtest baseline showed:
- Net profit: **–300.98 USD** (GBPUSD M15, 283 trades), PF **0.68**, max equity DD **3.75 %**
- Root causes identified: overtrading in low-quality setups + no hard loss cap.

---

## [v22.0] — 2026-04-22

### Added — Optimisation Infrastructure

**1. KPI framework (`docs/KPI_TARGETS.md`)**
- Defined 6 primary KPIs: net expectancy (R), win rate, profit factor, max equity DD%,
  Sharpe ratio, Calmar ratio — each with a minimum-acceptable and target value.
- Added regime-specific sub-targets (trend / range / volatile).
- Added 3-tier stress-test gate table (normal 1.0×, moderate 1.4×, high 2.0× spread).
- Defined rollback trigger conditions.

**2. Baseline measurement system (`docs/BASELINE.md`, `tools/baseline_report.py`)**
- `baseline_report.py`: parses the EA's ML-export CSV and computes all KPIs.
- Outputs a machine-readable JSON snapshot (`tools/baseline_kpis.json`).
- `docs/BASELINE.md`: locked configuration table and sprint comparison table.

**3. Walk-Forward Optimisation pipeline (`tools/wfo_pipeline.py`)**
- Rolling IS/OOS window splits (configurable folds and OOS ratio).
- Heuristic market-regime detection (trend / range / volatile) per fold.
- Per-regime KPI summary and overall robustness score.
- Outputs ACCEPT / REJECT recommendation based on OOS PF and robustness.

**4. Monte Carlo overfitting detection (`tools/monte_carlo_analysis.py`)**
- 2000-iteration trade-sequence reshuffling by default.
- Computes PF / DD / Expectancy distributions (p5–p95).
- Raises OVERFIT_RISK flag when real PF is in the top 5% of random reshuffles.

**5. Stress testing (`tools/stress_test.py`)**
- Applies spread multipliers and fixed slippage additions to the trade history.
- Checks P&L survival against KPI-gate table (PF ≥ 1.30 / 1.10 / 0.90).
- PASS / FAIL verdict used as a hard gate before live deployment.

**6. Session-level execution analysis (`tools/session_analysis.py`)**
- Classifies each trade into Asia / London / Overlap / NewYork / LateNY sessions.
- Also breaks down KPIs per weekday (Mon–Fri).
- Generates KEEP / REDUCE_RISK / BLOCK_ENTRIES recommendations per session.
- Computes spread-cost % of gross profit as execution-quality signal.

**7. Automated test suite (`tools/test_tools.py`)**
- 55 pytest tests covering all five Python tools.
- Runs on every push/PR via GitHub Actions.

**8. CI pipeline (`.github/workflows/ci.yml`)**
- `test` job: lint + pytest on every push and PR.
- `wfo` job: weekly WFO + Monte Carlo run every Wednesday 02:00 UTC.
- Artefact upload of WFO and stress-test JSON results (30-day retention).

**9. Phased deployment guide (`docs/DEPLOYMENT.md`)**
- 4-phase rollout: Development → Backtest → Forward test → Full live.
- Complete feature-flag table with all EA `input bool` guards.
- Manual and automatic rollback procedures.

**10. Optimisation governance (`docs/GOVERNANCE.md`)**
- Weekly optimisation cycle (Mon–Fri + weekend monitoring).
- CI cadence table.
- Decision authority matrix by change risk level.
- Anti-overfitting rules (max 5 free params, ≥ 3 symbols, OOS ≥ 30 %).
- Documentation standards for WFO/stress result artefacts.

### Context
The backtest result that motivated this sprint showed:
- Net profit: **–300.98 USD** (GBPUSD M15, 283 trades)
- Profit factor: **0.68**
- Max equity DD: **3.75 %**
- Recommendation: tighten entry filters and validate all changes with the new WFO
  pipeline before any live parameter change.

---

## [v14.8] — baseline

- Initial version with full multi-symbol pullback-scalper logic, news engine,
  correlation guard, volatility regime, equity drawdown tracker, Telegram integration,
  ML export, auto-tune / rollback engine.
