// MSPB_EA_Entry.mqh — v18.0
// Entry signal logic: Setup1/Setup2, SL/TP computation, session-aware SL, swing S/R TP.
// All globals and inputs are defined in MSPB_Expert_Advisor.mq5 which #includes this file.
#pragma once

// -----------------------------------------
// Core: entry logic (Setup1 / Setup2)
// -----------------------------------------
bool BreakPrevHighLow(const string sym,const bool isBuy,const bool useBreakPrev)
{
   if(!useBreakPrev) return true;
   // Break previous bar high/low on entryTF using CLOSED candles (avoid intra-bar repaint).
   // r[0] = current forming bar, r[1] = last closed, r[2] = bar before last closed
   MqlRates r[3];
   if(!CopyRatesLast(sym, InpEntryTF, 0, 3, r)) return false;
   if(isBuy) return (r[1].close > r[2].high);
   else      return (r[1].close < r[2].low);
}

bool EntrySignal_Setup1(const int symIdx, const string sym, bool &isBuy, double &adxTrend, double &adxEntry, double &atrPips, double &bodyPips)
{
   isBuy=false; adxTrend=0; adxEntry=0; atrPips=0; bodyPips=0;

   // rates
   MqlRates r[3];
   if(!CopyRatesLast(sym, InpEntryTF, 0, 3, r)) return false;

   double pip=PipSize(sym);
   if(pip<=0) return false;

   // Use last CLOSED candle for signal calculations (avoid intra-bar repaint).
   bodyPips = MathAbs(r[1].close - r[1].open)/pip;

   // ATR (use last closed bar value)
   double atrBuf[2];
   if(!CopyLast(g_atrHandle[symIdx],0,0,2,atrBuf)) return false;
   atrPips = atrBuf[1]/pip;

   // ADX filters are optional (InpUseADXFilter). If disabled, skip handle/buffer reads.
   if(InpUseADXFilter)
   {
      // ADX (trend TF)
      double adxBufT[2];
      if(!CopyLast(g_adxHandle[symIdx],0,0,2,adxBufT)) return false;
      adxTrend = adxBufT[1];

      // ADX (entry TF)
      double adxBufE[2];
      if(!CopyLast(g_adxEntryHandle[symIdx],0,0,2,adxBufE)) return false;
      adxEntry = adxBufE[1];
   }
   else
   {
      adxTrend = 999.0;
      adxEntry = 999.0;
   }

   // Pullback EMA touch check (closed candle + closed EMA)
   if(InpUsePullbackEMA || Sym_UsePullbackEMA(sym))
   {
      if(g_emaHandle[symIdx]==INVALID_HANDLE) return false;
      double emaBuf[2];
      if(!CopyLast(g_emaHandle[symIdx],0,0,2,emaBuf)) return false;
      double ema=emaBuf[1];
      bool touched = (r[1].low <= ema && r[1].high >= ema);
      if(!touched) return false;
   }

   // direction: simple - close above open => buy, else sell
   isBuy = (r[1].close > r[1].open);
   return true;
}

bool EntrySignal_Setup2(const int symIdx, const string sym, bool &isBuy)
{
   // Simple fallback: contrarian direction based on last CLOSED candle (avoid intra-bar repaint)
   MqlRates r[2];
   if(!CopyRatesLast(sym, InpEntryTF, 0, 2, r)) return false;
   isBuy = (r[1].close < r[1].open); // contrarian
   return true;
}

// --- Session identification (Asia=0, London=1, NY=2, Other=3)
// NOTE: uses broker server time (TimeCurrent). Adjust InpLondonStartHour / InpNYStartHour
// for your broker's GMT offset and Daylight Saving Time if needed.
int GetCurrentSession()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if(h < InpLondonStartHour)                        return 0; // Asia
   if(h >= InpLondonStartHour && h < InpNYStartHour) return 1; // London
   if(h >= InpNYStartHour     && h < InpNYEndHour)   return 2; // NY (incl. London/NY overlap)
   return 3; // other / off-session
}

// --- Session-aware SL ATR multiplier
double GetSessionSL_ATR_Mult(const string sym)
{
   int sess = GetCurrentSession();
   if(sess == 0 && InpAsia_SL_ATR_Mult > 0.0)   return Sym_SL_ATR_Mult(sym) * InpAsia_SL_ATR_Mult;
   if(sess == 1 && InpLondon_SL_ATR_Mult > 0.0)  return Sym_SL_ATR_Mult(sym) * InpLondon_SL_ATR_Mult;
   return Sym_SL_ATR_Mult(sym);
}

double ComputeSL(const string sym, const bool isBuy, const double entry, const double atrPips)
{
   double pip=PipSize(sym);
   double slDist = atrPips * GetSessionSL_ATR_Mult(sym) * pip;
   if(isBuy) return entry - slDist;
   else      return entry + slDist;
}

double ComputeTP(const string sym, const bool isBuy, const double entry, const double sl)
{
   double dist=MathAbs(entry-sl);
   if(isBuy) return entry + dist*Sym_TP_RR(sym);
   else      return entry - dist*Sym_TP_RR(sym);
}

// --- Swing high/low TP on confirmTF (looks back InpSwingSR_Lookback closed bars)
double FindSwingTP(const string sym, const bool isBuy, const double entry)
{
   if(!InpUseSwingSR_TP) return 0.0;
   int look = MathMax(5, InpSwingSR_Lookback);
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int got = CopyRates(sym, InpConfirmTF, 1, look, r); // start from bar 1 (last closed)
   if(got < 3) return 0.0;

   double pip = PipSize(sym);
   if(pip <= 0.0) return 0.0;
   double minDistPips = MathMax(0.5, InpSwingSR_MinDistPips); // min distance from entry to S/R level

   if(isBuy)
   {
      // nearest swing high above entry
      double best = 0.0;
      int swing = MathMax(1, InpSwingSR_SwingBars);
      for(int i = swing; i < got - swing; i++)
      {
         double h = r[i].high;
         if(h <= entry + minDistPips*pip) continue;
         // swing high: r[i] is the highest within [i-swing, i+swing]
         bool isSwing = true;
         for(int k = i - swing; k <= i + swing && isSwing; k++)
            if(k != i && r[k].high >= h) isSwing = false;
         if(isSwing)
            if(best <= 0.0 || h < best) best = h;
      }
      return best;
   }
   else
   {
      // nearest swing low below entry
      double best = 0.0;
      int swing = MathMax(1, InpSwingSR_SwingBars);
      for(int i = swing; i < got - swing; i++)
      {
         double l = r[i].low;
         if(l >= entry - minDistPips*pip) continue;
         // swing low: r[i] is the lowest within [i-swing, i+swing]
         bool isSwing = true;
         for(int k = i - swing; k <= i + swing && isSwing; k++)
            if(k != i && r[k].low <= l) isSwing = false;
         if(isSwing)
            if(best <= 0.0 || l > best) best = l;
      }
      return best;
   }
}

// --- Compute TP: use swing S/R if enabled and found, else fixed RR
double ComputeTP_Smart(const string sym, const bool isBuy, const double entry, const double sl)
{
   if(InpUseSwingSR_TP)
   {
      double srTP = FindSwingTP(sym, isBuy, entry);
      if(srTP > 0.0)
      {
         // only use if RR is at least InpSwingSR_MinRR
         double slDist = MathAbs(entry - sl);
         double tpDist = MathAbs(srTP - entry);
         if(slDist > 0.0 && (tpDist/slDist) >= InpSwingSR_MinRR)
            return srTP;
      }
   }
   return ComputeTP(sym, isBuy, entry, sl);
}
