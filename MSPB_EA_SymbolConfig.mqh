// MSPB_EA_SymbolConfig.mqh — Per-symbol override CSV loading + convenience getters
// Included by MSPB_Expert_Advisor.mq5
#ifndef MSPB_EA_SYMBOLCONFIG_MQH
#define MSPB_EA_SYMBOLCONFIG_MQH

// --- Per-symbol parameter overrides (CSV)
struct SymbolOverrides
{
   string sym;                 // key (e.g. "EURUSD" or "NVDA")
   double maxSpreadPips;       // <=0 => use global defaults
   double minATR_Pips;         // <=0 => use global
   double minADXTrend;         // <=0 => use global
   double minADXEntry;         // <=0 => use global
   double minBodyPips;         // <=0 => use global
   double slATRMult;           // <=0 => use global
   double tpRR;                // <=0 => use global
   int    useBreakPrev;        // -1 => use global, 0 => off, 1 => on
   int    allowBuy;            // -1 => use global, 0 => off, 1 => on
   int    allowSell;           // -1 => use global, 0 => off, 1 => on
   int    usePullbackEMA;      // -1 => use global, 0 => off, 1 => on
   double riskWeight;          // >0 => scale InpRiskPercent by this factor (e.g. 0.5 = half risk); <=0 => use 1.0
};

SymbolOverrides g_ovr[128];
int      g_ovrCount=0;
datetime g_ovrLastLoad=0;
datetime g_ovrNextReload=0;


int FindOverrideIndex(const string sym)
{
   string up=UpperTrim(sym);
   for(int i=0;i<g_ovrCount;i++)
      if(g_ovr[i].sym==up) return i;

   // prefix match: "NVDA" matches "NVDA.US"
   for(int i=0;i<g_ovrCount;i++)
      if(StringFind(up,g_ovr[i].sym)==0) return i;

   return -1;
}

bool LoadSymbolOverrides()
{
   g_ovrCount=0;
   if(!InpSymbolOverrides_Enable) return false;

   int flags=FILE_READ|FILE_TXT|FILE_ANSI;
   if(InpSymbolOverrides_UseCommonFolder) flags|=FILE_COMMON;

   int h=FileOpen(InpSymbolOverrides_File,flags);
   if(h==INVALID_HANDLE)
   {
      if(InpSymbolOverrides_PrintOnLoad)
         Print("[Overrides] Cannot open ",InpSymbolOverrides_File,
               " (place it in MQL5/Files). Err=",GetLastError());
      g_ovrLastLoad=TimeCurrent();
      g_ovrNextReload=g_ovrLastLoad+MathMax(5,InpSymbolOverrides_ReloadSec);
      return false;
   }

   int lineNo=0;
   bool loggedHeader=false;
   string line="";
   while(true)
   {
      if(!FileReadLineTxt(h, line)) break;
      lineNo++;
      line=TrimStr(line);
      if(line=="" || StringGetCharacter(line,0)=='#') continue;

      string cols[];
      int n=SplitCSV(line,cols);
      if(!loggedHeader)
      {
         loggedHeader=true;
         if(InpDebug)
            Print("[OVR] First non-comment line cols=",n," | ",line);
      }
      if(n<1) continue;

      string key=UpperTrim(cols[0]);
      if(key=="" || key=="SYMBOL" || key=="SYM") continue;

      if(g_ovrCount>=ArraySize(g_ovr))
      {
         Print("[Overrides] WARNING: override table is full (max=", ArraySize(g_ovr),
               "). Remaining rows in '", InpSymbolOverrides_File, "' were ignored.");
         break;
      }

      SymbolOverrides o;
      o.sym=key;
      o.maxSpreadPips=(n>1?ParseDbl(cols[1],0):0);
      o.minATR_Pips  =(n>2?ParseDbl(cols[2],0):0);
      o.minADXTrend  =(n>3?ParseDbl(cols[3],0):0);
      o.minADXEntry  =(n>4?ParseDbl(cols[4],0):0);
      o.minBodyPips  =(n>5?ParseDbl(cols[5],0):0);
      o.slATRMult    =(n>6?ParseDbl(cols[6],0):0);
      o.tpRR         =(n>7?ParseDbl(cols[7],0):0);
      o.useBreakPrev =(n>8?ParseInt(cols[8],-1):-1);
      o.allowBuy     =(n>9?ParseInt(cols[9],-1):-1);
      o.allowSell    =(n>10?ParseInt(cols[10],-1):-1);
      o.usePullbackEMA=(n>11?ParseInt(cols[11],-1):-1);
      o.riskWeight   =(n>12?ParseDbl(cols[12],0):0);

      g_ovr[g_ovrCount]=o;
      g_ovrCount++;
   }
   FileClose(h);

   g_ovrLastLoad=TimeCurrent();
   g_ovrNextReload=g_ovrLastLoad+MathMax(5,InpSymbolOverrides_ReloadSec);

   if(InpSymbolOverrides_PrintOnLoad)
   {
      Print("[Overrides] Loaded ",g_ovrCount," row(s) from ",InpSymbolOverrides_File);
      for(int i=0;i<g_ovrCount;i++)
      {
         Print("[Overrides] ",g_ovr[i].sym,
               " spread=",DoubleToString(g_ovr[i].maxSpreadPips,1),
               " minATR=",DoubleToString(g_ovr[i].minATR_Pips,1),
               " adxT=",DoubleToString(g_ovr[i].minADXTrend,1),
               " adxE=",DoubleToString(g_ovr[i].minADXEntry,1),
               " body=",DoubleToString(g_ovr[i].minBodyPips,1),
               " slMult=",DoubleToString(g_ovr[i].slATRMult,2),
               " tpRR=",DoubleToString(g_ovr[i].tpRR,2),
               " breakPrev=",(string)g_ovr[i].useBreakPrev,
               " buy=",(string)g_ovr[i].allowBuy,
               " sell=",(string)g_ovr[i].allowSell,
               " ema=",(string)g_ovr[i].usePullbackEMA,
               " riskW=",DoubleToString(g_ovr[i].riskWeight,2));
      }
   }
   return true;
}

void SymbolOverrides_UpdateIfDue()
{
   if(!InpSymbolOverrides_Enable || !InpSymbolOverrides_HotReload) return;
   datetime now=TimeCurrent();
   if(now<g_ovrNextReload) return;
   int prevCount = g_ovrCount;
   bool ok=LoadSymbolOverrides();
   if(ok)
   {
      // Log whenever the number of active override rows changes so the operator
      // can see that the file was reloaded and whether rows were added/removed.
      if(g_ovrCount != prevCount)
         PrintFormat("[Overrides] Hot-reload: row count changed %d → %d (file='%s')",
                     prevCount, g_ovrCount, InpSymbolOverrides_File);
      else
         PrintFormat("[Overrides] Hot-reload: %d row(s) unchanged (file='%s')",
                     g_ovrCount, InpSymbolOverrides_File);
      if(InpTune_Enable) Tune_SyncWithOverrides(false);
   }
}

// Convenience getters (per-symbol override if set, else global)
double Sym_MaxSpreadPips(const string sym)
{
   int k=FindOverrideIndex(sym);
   if(k>=0 && g_ovr[k].maxSpreadPips>0) return g_ovr[k].maxSpreadPips;

   string up=sym; StringToUpper(up);

   // Metals
   if(StringFind(up,"XAU")>=0 || StringFind(up,"XAG")>=0)
      return InpMaxSpreadPips_XAU;

   // FX-like (majors/minors)
   if(IsFXLikeSymbol(sym))
      return InpMaxSpreadPips_FX;

   // Stocks/CFDs (default)
   return InpMaxSpreadPips_STOCK;
}

double Sym_MinATR_Pips(const string sym)
{
   int k=FindOverrideIndex(sym);
   if(k>=0 && g_ovr[k].minATR_Pips>0) return g_ovr[k].minATR_Pips;
   return SessionATRMin();
}
double Sym_MinADXTrend(const string sym)
{
   int k=FindOverrideIndex(sym);
   if(k>=0 && g_ovr[k].minADXTrend>0) return g_ovr[k].minADXTrend;
   return SessionADXMin();
}
double Sym_MinADXEntry(const string sym)
{
   int k=FindOverrideIndex(sym);
   if(k>=0 && g_ovr[k].minADXEntry>0) return g_ovr[k].minADXEntry;
   return SessionADXMin();
}
double Sym_MinBodyPips(const string sym)
{
   int k=FindOverrideIndex(sym);
   if(k>=0 && g_ovr[k].minBodyPips>0) return g_ovr[k].minBodyPips;
   return InpMinBodyPips;
}
double Sym_SL_ATR_Mult(const string sym)
{
   int k=FindOverrideIndex(sym);
   if(k>=0 && g_ovr[k].slATRMult>0) return g_ovr[k].slATRMult;
   return InpSL_ATR_Mult;
}
double Sym_TP_RR(const string sym)
{
   int k=FindOverrideIndex(sym);
   if(k>=0 && g_ovr[k].tpRR>0) return g_ovr[k].tpRR;
   return InpTP_RR;
}
bool Sym_UseBreakPrev(const string sym)
{
   int k=FindOverrideIndex(sym);
   if(k>=0 && g_ovr[k].useBreakPrev!=-1) return (g_ovr[k].useBreakPrev>0);
   return InpUseBreakPrevHighLow;
}
bool Sym_AllowBuy(const string sym)
{
   int k=FindOverrideIndex(sym);
   if(k>=0 && g_ovr[k].allowBuy!=-1) return (g_ovr[k].allowBuy>0);
   return InpAllowBuy;
}
bool Sym_AllowSell(const string sym)
{
   int k=FindOverrideIndex(sym);
   if(k>=0 && g_ovr[k].allowSell!=-1) return (g_ovr[k].allowSell>0);
   return InpAllowSell;
}
bool Sym_UsePullbackEMA(const string sym)
{
   int k=FindOverrideIndex(sym);
   if(k>=0 && g_ovr[k].usePullbackEMA!=-1) return (g_ovr[k].usePullbackEMA>0);
   return InpUsePullbackEMA;
}

#endif // MSPB_EA_SYMBOLCONFIG_MQH
