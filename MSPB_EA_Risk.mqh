// MSPB_EA_Risk.mqh — v18.0
// Risk management: volume normalisation, lot sizing, RiskCap, portfolio risk guard, equity regime.
// All globals and inputs are defined in MSPB_Expert_Advisor.mq5 which #includes this file.
#pragma once

double SpreadPips(const string sym)
{
   MqlTick tk;
   if(!SymbolInfoTick(sym, tk)) return 0.0;
   double pip=PipSize(sym);
   if(pip<=0.0) return 0.0;

   double sp = (tk.ask - tk.bid)/pip;
   double mult = (InpSpreadStressMult<=0.0 ? 1.0 : InpSpreadStressMult);
   return sp * mult;
}

double NormalizeVolume(const string sym, double vol)
{
   double minv=SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxv=SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step<=0) step=0.01;

   if(vol<minv) vol=minv;
   if(vol>maxv) vol=maxv;

   double steps=MathFloor((vol-minv)/step);
   double out=minv + steps*step;
   if(out<minv) out=minv;
   if(out>maxv) out=maxv;

   // Digits based on volume step (avoids "Invalid volume" on brokers with 0.001 steps or stocks with 1.0 steps).
   int digits=0;
   double s=step;
   while(digits<8 && MathAbs(s - MathRound(s)) > 1e-12)
   {
      s*=10.0;
      digits++;
   }
   return NormalizeDouble(out, digits);
}

// --- floor-normalize volume (never rounds UP to min volume); returns 0 if below min
double NormalizeVolumeFloor(const string sym, double vol)
{
   double minv=SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxv=SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step<=0) step=0.01;

   if(vol < (minv - 1e-12)) return 0.0;
   if(vol > maxv) vol = maxv;

   double steps=MathFloor((vol-minv)/step + 1e-9);
   double out=minv + steps*step;

   // float safety: never exceed requested vol
   if(out > vol + 1e-12) out -= step;

   if(out < (minv - 1e-12)) return 0.0;
   if(out > maxv) out = maxv;

   // normalize digits based on step precision
   int digits=0;
   double s=step;
   while(digits<8 && MathAbs(s - MathRound(s)) > 1e-12)
   {
      s *= 10.0;
      digits++;
   }
   return NormalizeDouble(out, digits);
}

double PositionRiskMoney(const string sym, const double entry, const double sl, const double vol)
{
   double tickVal=SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize=SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal<=0 || tickSize<=0) return 0.0;

   double dist=MathAbs(entry-sl);
   if(dist<=0) return 0.0;

   // value per price unit:
   double vpu = tickVal / tickSize;
   double risk = dist * vpu * vol;
   return risk;
}

bool CalcRiskLotsEx(const string sym, const double entry, const double sl, const double riskMult, double &lotsOut, double &riskMoneyOut)
{
   lotsOut=0; riskMoneyOut=0;

   // Fixed-lot mode
   if(!InpUseRiskPercent || InpRiskPercent<=0.0)
   {
      lotsOut=NormalizeVolume(sym, InpLots);
      riskMoneyOut=PositionRiskMoney(sym, entry, sl, lotsOut);
      return (lotsOut>0.0);
   }

   // Risk-% mode (use EQUITY to avoid sizing too aggressively during floating drawdown)
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq<=0.0) eq=AccountInfoDouble(ACCOUNT_BALANCE);

   double riskBudget=eq * (InpRiskPercent/100.0);
   if(riskMult<=0.0) return false;
   riskBudget *= riskMult;

   double riskPerLot=PositionRiskMoney(sym, entry, sl, 1.0);
   if(riskPerLot<=0.0) return false;

   double rawLots = riskBudget / riskPerLot;

   // IMPORTANT: use floor-normalization so we don't round up to min lot and exceed the risk budget.
   double lots = NormalizeVolumeFloor(sym, rawLots);
   if(lots<=0.0) return false;

   double actual=PositionRiskMoney(sym, entry, sl, lots);
   lotsOut=lots;
   riskMoneyOut=actual;
   return true;
}

bool CalcRiskLots(const string sym, const double entry, const double sl, double &lotsOut, double &riskMoneyOut)
{
   // wrapper for legacy calls: equity-regime only
   return CalcRiskLotsEx(sym, entry, sl, g_riskMult, lotsOut, riskMoneyOut);
}

enum RiskCapBucket
{
   RISK_CAP_USD=0,
   RISK_CAP_EUR=1,
   RISK_CAP_GBP=2,
   RISK_CAP_OTHER=3
};
const double RISK_CAP_EPS = 1e-9;
// Fallback counts both FX legs into OTHER when parsing fails (base + quote => 2x).
const double RISK_CAP_PARSE_FALLBACK_MULT = 2.0;

bool RiskCap_IsEnabled()
{
   return (InpRisk_Cap_Mode==1);
}

double RiskCap_OneRMoney()
{
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq<=0.0) eq=AccountInfoDouble(ACCOUNT_BALANCE);
   if(eq<=0.0) return 0.0;
   if(!InpUseRiskPercent || InpRiskPercent<=0.0) return 0.0;
   return eq * (InpRiskPercent/100.0);
}

double RiskCap_MoneyToR(const double riskMoney)
{
   if(riskMoney<=0.0) return 0.0;
   double oneR=RiskCap_OneRMoney();
   if(oneR<=0.0) return 0.0;
   return (riskMoney/oneR);
}

string RiskCap_BucketName(const int idx)
{
   if(idx==RISK_CAP_USD) return "USD";
   if(idx==RISK_CAP_EUR) return "EUR";
   if(idx==RISK_CAP_GBP) return "GBP";
   return "OTHER";
}

double RiskCap_BucketCapR(const int idx)
{
   if(idx==RISK_CAP_USD) return MathMax(0.0, InpRisk_Cap_USD_R);
   if(idx==RISK_CAP_EUR) return MathMax(0.0, InpRisk_Cap_EUR_R);
   if(idx==RISK_CAP_GBP) return MathMax(0.0, InpRisk_Cap_GBP_R);
   return MathMax(0.0, InpRisk_Cap_Other_R);
}

int RiskCap_BucketIndexByCurrency(const string ccy)
{
   if(ccy=="USD") return RISK_CAP_USD;
   if(ccy=="EUR") return RISK_CAP_EUR;
   if(ccy=="GBP") return RISK_CAP_GBP;
   return RISK_CAP_OTHER;
}

bool RiskCap_ParseBaseQuote(const string sym, string &baseOut, string &quoteOut)
{
   baseOut="OTHER";
   quoteOut="OTHER";
   string letters="";
   int L=StringLen(sym);
   // Broker suffix/prefix safe: extract first 6 alphabetic chars, then split 3/3 (e.g. EURUSDm -> EUR/USD).
   for(int i=0; i<L && StringLen(letters)<6; i++)
   {
      ushort c=(ushort)StringGetCharacter(sym, i);
      bool isAlphabetic = ((c>='A' && c<='Z') || (c>='a' && c<='z'));
      if(isAlphabetic) letters += StringSubstr(sym, i, 1);
   }
   if(StringLen(letters)<6) return false;

   baseOut=StringSubstr(letters, 0, 3);
   quoteOut=StringSubstr(letters, 3, 3);
   StringToUpper(baseOut);
   StringToUpper(quoteOut);
   return true;
}

double RiskCap_PositionInitialRBestEffort(const string sym,
                                          const long posId,
                                          const double openPx,
                                          const double slPx,
                                          const double vol)
{
   double riskMoney=0.0;

   int tIdx=PosTrackFind(posId);
   if(tIdx>=0)
   {
      if(g_posTrackRiskMoney[tIdx]>0.0)
         riskMoney=g_posTrackRiskMoney[tIdx];
      else if(g_posTrackVolIn[tIdx]>0.0 && g_posTrackSL0[tIdx]>0.0 && g_posTrackOpenSum[tIdx]>0.0)
      {
         double avgEntry = g_posTrackOpenSum[tIdx] / g_posTrackVolIn[tIdx];
         riskMoney = PositionRiskMoney(sym, avgEntry, g_posTrackSL0[tIdx], g_posTrackVolIn[tIdx]);
      }
   }

   if(riskMoney<=0.0 && openPx>0.0 && slPx>0.0 && vol>0.0)
      riskMoney = PositionRiskMoney(sym, openPx, slPx, vol);

   return RiskCap_MoneyToR(riskMoney);
}

void RiskCap_AddSymbolExposure(const string sym, const double posR, double &buckets[])
{
   if(posR<=0.0) return;
   string base="", quote="";
   if(!RiskCap_ParseBaseQuote(sym, base, quote))
   {
      // parsing failed => fallback bucket
      buckets[RISK_CAP_OTHER] += (RISK_CAP_PARSE_FALLBACK_MULT*posR);
      if(InpRisk_Cap_LogDetail || InpDebug)
      {
         static datetime lastParseWarn=0;
         datetime now=TimeCurrent();
         if(lastParseWarn==0 || (now-lastParseWarn)>60)
         {
            PrintFormat("RISK_CAP_PARSE_FALLBACK symbol=%s posR=%.3f", sym, posR);
            lastParseWarn=now;
         }
      }
      return;
   }

   int b0=RiskCap_BucketIndexByCurrency(base);
   int b1=RiskCap_BucketIndexByCurrency(quote);
   buckets[b0] += posR;
   buckets[b1] += posR;
}

void RiskCap_CollectCurrentBuckets(double &buckets[])
{
   ArrayResize(buckets, 4);
   ArrayInitialize(buckets, 0.0);

   int total=PositionsTotal();
   for(int i=0;i<total;i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;

      string sym=PositionGetString(POSITION_SYMBOL);
      long posId=(long)PositionGetInteger(POSITION_IDENTIFIER);
      double openPx=PositionGetDouble(POSITION_PRICE_OPEN);
      double slPx=PositionGetDouble(POSITION_SL);
      double vol=PositionGetDouble(POSITION_VOLUME);

      double posR=RiskCap_PositionInitialRBestEffort(sym, posId, openPx, slPx, vol);
      if(posR<=0.0) continue;
      RiskCap_AddSymbolExposure(sym, posR, buckets);
   }
}

string RiskCap_BucketsKV(const double &vals[])
{
   return StringFormat("USD=%.3f|EUR=%.3f|GBP=%.3f|OTHER=%.3f",
                       vals[RISK_CAP_USD], vals[RISK_CAP_EUR], vals[RISK_CAP_GBP], vals[RISK_CAP_OTHER]);
}

string RiskCap_CapsKV()
{
   return StringFormat("USD=%.3f|EUR=%.3f|GBP=%.3f|OTHER=%.3f",
                       RiskCap_BucketCapR(RISK_CAP_USD),
                       RiskCap_BucketCapR(RISK_CAP_EUR),
                       RiskCap_BucketCapR(RISK_CAP_GBP),
                       RiskCap_BucketCapR(RISK_CAP_OTHER));
}

void RiskCap_SendBlockedTelegram(const string msg)
{
   if(!InpEnableTelegram) return;
   datetime now=TimeCurrent();
   int cooldownSec=MathMax(1, InpRisk_Cap_TelegramCooldownSec);
   if(g_riskCapLastTG>0 && (now-g_riskCapLastTG)<cooldownSec)
   {
      if(InpRisk_Cap_LogDetail || InpDebug)
         Print("RISK_CAP_TG_COOLDOWN active; blocked alert suppressed.");
      return;
   }
   g_riskCapLastTG=now;
   TelegramSendMessage(msg);
}

bool RiskCap_AllowsEntry(const int symIdx,
                         const string sym,
                         const string dir,
                         const string setup,
                         const double intendedR,
                         const double riskMoney)
{
   if(!RiskCap_IsEnabled()) return true;
   if(intendedR<=0.0) return true;

   double current[];
   RiskCap_CollectCurrentBuckets(current);

   double projected[];
   ArrayResize(projected, 4);
   for(int i=0;i<4;i++) projected[i]=current[i];
   RiskCap_AddSymbolExposure(sym, intendedR, projected);

   bool blocked=false;
   string breach="";
   for(int i=0;i<4;i++)
   {
      double cap=RiskCap_BucketCapR(i);
      if(projected[i] > cap + RISK_CAP_EPS)
      {
         blocked=true;
         if(breach!="") breach += ",";
         breach += RiskCap_BucketName(i);
      }
   }
   if(!blocked) return true;

   string kv = StringFormat("symbol=%s|dir=%s|setup=%s|intended_R_total=%.3f|breach=%s|current={%s}|projected={%s}|caps={%s}",
                            sym, dir, setup, intendedR, breach,
                            RiskCap_BucketsKV(current),
                            RiskCap_BucketsKV(projected),
                            RiskCap_CapsKV());

   Audit_Log("BLOCKED_CURRENCY_RISK", kv, false);

   if(InpEnableMLExport)
   {
      ML_WriteRowV2("entry_block", NowStr(), sym, setup, dir,
                    0, 0, 0, 0, riskMoney,
                    0, 0, 0, 0, 0,
                    "CURRENCY_RISK_CAP", breach,
                    0, "ENTRY_BLOCKED", 0, 0, 0,
                    0, "BLOCKED_CURRENCY_RISK "+kv, g_mlSchema);
   }

   if(InpRisk_Cap_LogDetail || InpDebug)
      Print("BLOCKED_CURRENCY_RISK ", kv);

   RiskCap_SendBlockedTelegram(StringFormat("BLOCKED_CURRENCY_RISK %s %s intendedR=%.3f breach=%s current={%s} projected={%s} caps={%s}",
                                            sym, dir, intendedR, breach,
                                            RiskCap_BucketsKV(current),
                                            RiskCap_BucketsKV(projected),
                                            RiskCap_CapsKV()));

   IncReject(symIdx, REJ_RISK_GUARDS);
   return false;
}

double CurrentPortfolioRiskPct()
{
   double totalRiskMoney=0.0;

   int total=PositionsTotal();
   for(int i=0;i<total;i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;

      string sym=PositionGetString(POSITION_SYMBOL);
      double vol=PositionGetDouble(POSITION_VOLUME);
      long type=PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);

      if(vol<=0.0 || open<=0.0) continue;

      // If SL is missing, estimate risk so portfolio guard does not under-report risk.
      if(sl<=0.0)
      {
         double pip=PipSize(sym);
         bool   estOk=false;

         if(pip>0.0)
         {
            // Prefer ATR-based estimate (EntryTF ATR)
            int idx=SymIndexByNameLoose(sym);
            if(idx>=0 && g_atrHandle[idx]!=INVALID_HANDLE)
            {
               double atrBuf[1];
               if(CopyLast(g_atrHandle[idx], 0, 0, 1, atrBuf))
               {
                  double atrPips = atrBuf[0]/pip;
                  if(atrPips>0.0)
                  {
                     double dist = atrPips * Sym_SL_ATR_Mult(sym) * pip;
                     double slEst = (type==POSITION_TYPE_BUY ? open - dist : open + dist);
                     double rm = PositionRiskMoney(sym, open, slEst, vol);
                     if(rm>0.0) { totalRiskMoney += rm; estOk=true; }
                  }
               }
            }

            // Fallback: use minimum ATR pips as proxy when ATR buffer isn't available yet
            if(!estOk)
            {
               double fbAtrPips = Sym_MinATR_Pips(sym);
               if(fbAtrPips<=0.0) fbAtrPips = InpMinATR_Pips;
               if(fbAtrPips<=0.0) fbAtrPips = 10.0;

               double dist = fbAtrPips * Sym_SL_ATR_Mult(sym) * pip;
               if(dist>0.0)
               {
                  double slEst = (type==POSITION_TYPE_BUY ? open - dist : open + dist);
                  double rm = PositionRiskMoney(sym, open, slEst, vol);
                  if(rm>0.0)
                  {
                     totalRiskMoney += rm;
                     estOk=true;

                     // Throttled audit/ML notice (optional) so you can see when portfolio risk uses a fallback estimate.
                     datetime nowFB=TimeCurrent();
                     if(InpEnableAuditLog)
                     {
                        static datetime lastAudit=0;
                        if(lastAudit==0 || (nowFB-lastAudit)>300)
                        {
                           long posId=(long)PositionGetInteger(POSITION_IDENTIFIER);
                           Audit_Log("PORT_RISK_FALLBACK",
                                     StringFormat("sym=%s|ticket=%I64d|posId=%I64d|vol=%.2f|distPips=%.2f|open=%s|note=noSL_noATR",
                                                  sym,(long)ticket,posId,vol,dist/pip,FmtPriceSym(sym,open)),
                                     false);
                           lastAudit=nowFB;
                        }
                     }
                     if(InpEnableMLExport)
                     {
                        static datetime lastML=0;
                        if(lastML==0 || (nowFB-lastML)>300)
                        {
                           long posId=(long)PositionGetInteger(POSITION_IDENTIFIER);
                           string dir=(type==POSITION_TYPE_BUY?"BUY":"SELL");
                           ML_WriteRowV2("risk_fb", NowStr(), sym, "", dir,
                                        open, 0,0, vol, rm,
                                        fbAtrPips, 0,0, 0,0,
                                        "", "",
                                        posId, "RISK_FALLBACK", 0,0,0,
                                        0, "noSL_noATR", g_mlSchema,
                                        StringFormat("distPips=%.2f|ticket=%I64d", dist/pip, (long)ticket));
                           lastML=nowFB;
                        }
                     }

                     // Throttled warning (debug only)
                     if(InpDebug)
                     {
                        static datetime lastWarn=0;
                        datetime now=TimeCurrent();
                        if(lastWarn==0 || (now-lastWarn)>60)
                        {
                           PrintFormat("PORT_RISK_FALLBACK: %s position has NO SL; ATR not ready -> using fallbackDist=%.1f pips (minATR*SLmult).",
                                       sym, fbAtrPips*Sym_SL_ATR_Mult(sym));
                           lastWarn=now;
                        }
                     }
                  }
               }
            }
         }

         if(!estOk)
         {
            // Ultimate fail-closed: count full allowed portfolio risk so new entries are blocked until stops exist.
            double eq=AccountInfoDouble(ACCOUNT_EQUITY);
            if(eq<=0.0) eq=AccountInfoDouble(ACCOUNT_BALANCE);
            if(eq>0.0)
               totalRiskMoney += eq * (InpMaxPortfolioRiskPct/100.0);
         }
         continue;
      }

      double rm=PositionRiskMoney(sym, open, sl, vol);
      if(rm>0.0) totalRiskMoney += rm;
   }

   // Use equity (safer during floating DD); fall back to balance if equity not available.
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq<=0.0) eq=AccountInfoDouble(ACCOUNT_BALANCE);
   if(eq<=0.0) return 0.0;

   return 100.0 * totalRiskMoney / eq;
}



bool PortfolioRiskAllows(const double addRiskMoney)
{
   if(!InpUsePortfolioRiskGuard) return true;
   // Use equity for consistency with CurrentPortfolioRiskPct() and risk sizing.
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq<=0.0) eq=AccountInfoDouble(ACCOUNT_BALANCE);
   if(eq<=0.0) return false;

   double curPct=CurrentPortfolioRiskPct();
   double addPct=(addRiskMoney/eq)*100.0;
   return (curPct + addPct) <= InpMaxPortfolioRiskPct;
}

// -----------------------------------------
// Equity regime filter (simple drawdown in R over last N deals)
// -----------------------------------------
string EqRegToStr(const EqRegime r)
{
   if(r==EQ_NEUTRAL) return "NEUTRAL";
   if(r==EQ_CAUTION) return "CAUTION";
   if(r==EQ_DEFENSIVE) return "DEFENSIVE";
   return "?";
}

void EqRegime_Update()
{
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_eqPeak==0.0) { g_eqPeak=eq; g_eqTrough=eq; }
   if(eq>g_eqPeak) g_eqPeak=eq;
   if(eq<g_eqTrough) g_eqTrough=eq;

   // compute drawdown in R-like scale: ddPct
   double ddPct=0.0;
   if(g_eqPeak>0.0) ddPct = (g_eqPeak - eq) / g_eqPeak * 100.0;

   if(ddPct<2.0) g_eqRegime=EQ_NEUTRAL;
   else if(ddPct<5.0) g_eqRegime=EQ_CAUTION;
   else g_eqRegime=EQ_DEFENSIVE;

   if(g_eqRegime==EQ_NEUTRAL) g_riskMult=1.0;
   if(g_eqRegime==EQ_CAUTION) g_riskMult=0.7;
   if(g_eqRegime==EQ_DEFENSIVE) g_riskMult=0.4;
}
