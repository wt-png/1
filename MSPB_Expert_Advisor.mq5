#property strict
#property description "MultiSymbol Pullback Scalper v19.0: multi-session, multi-symbol, multi-TF EA with execution-quality gate, equity-regime filter, Telegram integration and walk-forward robustness scoring."

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include "MSPB_EA_Telegram.mqh"
#include "MSPB_EA_OrderExec.mqh"
#include "MSPB_EA_Dashboard.mqh"
#include "MSPB_EA_Risk.mqh"
#include "MSPB_EA_ExecQual.mqh"
#include "MSPB_EA_Entry.mqh"

// EA version string -- used in startup logs and Telegram messages.
#define EA_VERSION "20.0"

// __TIME__ compatibility: some older MT5 builds do not expose this predefined macro.
// This EA does not use __TIME__ directly; the guard prevents "undeclared identifier"
// errors when upgrading to or from external modules that may reference it.
#ifndef __TIME__
   #define __TIME__ ((datetime)0)   // zero sentinel — intentionally unused in runtime logic
#endif


// --- Compatibility helpers ----------------------------------------------------
// Some older MT5 builds miss certain constants/method overloads.
// We avoid direct use of missing identifiers (DEAL_SL/DEAL_TP, PositionClose(ticket) overload, etc.).
#ifndef TRADE_RETCODE_CONNECTION
   // Older builds use TRADE_RETCODE_NO_CONNECTION. Treat them equivalently.
   #define TRADE_RETCODE_CONNECTION TRADE_RETCODE_NO_CONNECTION
#endif
#ifndef TRADE_RETCODE_TOO_MANY_REQUESTS
   // Build-compatible fallback value (official retcode is 10024 on modern MT5 builds).
   #define TRADE_RETCODE_TOO_MANY_REQUESTS 10024
#endif
#ifndef FILE_SHARE_READ
   // Some older builds may miss FILE_SHARE_* flags.
   #define FILE_SHARE_READ 0
#endif
// --------------------------------------------------------------------------------

// Read a full line from a FILE_TXT handle (safe when fields contain spaces).
bool FileReadLineTxt(const int handle, string &line)
{
   line="";
   if(handle==INVALID_HANDLE) return false;
   if(FileIsEnding(handle)) return false;

   while(!FileIsEnding(handle))
   {
      string ch = FileReadString(handle, 1);
      if(ch=="")
      {
         if(FileIsEnding(handle)) break;
         continue;
      }
      int c = StringGetCharacter(ch, 0);
      if(c=='\r') continue;
      if(c=='\n') break;
      line += ch;
   }
   return true;
}

// v14.7 hotfix summary:
// 1) News CSV: throttle reload attempts when cache file missing + robust line reading (spaces safe)
// 2) BreakPrev: only count rejection when Setup2 fallback is not used
// 3) ManagePositions: pip guards + iterate PositionsTotal()-1..0 (avoid skipping on closes)
// 4) Correlation cache: update once per CorrTF bar from OnTick/OnTimer
// 5) Symbol overrides CSV: robust line reading (spaces safe)
// 6) Cooldown: loose symbol match (suffix/prefix safe)
// 7) Portfolio risk: fallback estimate when SL missing + optional audit/ML notice (throttled)

/*
 * =========================
 * Embedded News Engine (CSV cache + optional News-aware trailing with rollover ignore)
 * =========================
 * - Calendar News from CSV file in Files folder (InpNews_CacheFile). Format: time,event,impact,currency
 * - News-aware trailing uses spike detection (ATR-based), can be suppressed during rollover.
 */

// --- News inputs
input bool     InpNews_Enable              = false;
input string   InpNews_CacheFile           = "news_cache.csv";
input int      InpNews_RefreshSec          = 300;    // reload file interval
input int      InpNews_BlockLeadMin        = 10;     // block entries/exits before event
input int      InpNews_BlockLagMin         = 5;      // block after event
input bool     InpNews_BlockEntries        = false;
input bool     InpAvoidEntriesDuringNews   = false;   // extra guard: skip entry checks during news window
input bool     InpNews_BlockExits          = false;
input bool     InpNews_UseRiskScaling      = false;  // scale risk by impact (lots multiplier)
input double   InpNews_RiskMultHigh        = 0.0;    // 0 => skip trades on high
input double   InpNews_RiskMultMed         = 0.5;
input double   InpNews_RiskMultLow         = 0.75;
input bool     InpNews_FailClosedOnError   = false;  // if true: when cache errors exist, treat as blocked (fail-closed)
input int      InpNews_TimeOffsetMinutes   = 0;      // optional time offset applied to CSV timestamps (e.g. CSV is UTC, broker is GMT+X)

// --- News internal
struct NewsEvent
{
   datetime t;
   string   event;
   int      impact; // 1 low, 2 med, 3 high
   string   ccy;
};

NewsEvent g_news_events[2048];
int       g_news_n=0;
datetime  g_news_lastLoad=0;
string    g_news_lastError="";
bool      g_news_enabled=false;

// helper: strip UTF-8 BOM (Excel often writes UTF-8 BOM)
string StripBOM(string s)
{
   if(StringLen(s)>=1 && StringGetCharacter(s,0)==0xFEFF) // U+FEFF
      return StringSubstr(s,1);

   // Sometimes BOM is mis-decoded as 3 chars: ï»¿ (0x00EF 0x00BB 0x00BF)
   if(StringLen(s)>=3)
   {
      int c0=StringGetCharacter(s,0);
      int c1=StringGetCharacter(s,1);
      int c2=StringGetCharacter(s,2);
      if(c0==0x00EF && c1==0x00BB && c2==0x00BF)
         return StringSubstr(s,3);
   }
   return s;
}

// helper: trim
string TrimStr(string s)
{
   s=StripBOM(s);
   while(StringLen(s)>0 && (StringGetCharacter(s,0)==' ' || StringGetCharacter(s,0)=='\t' || StringGetCharacter(s,0)=='\r' || StringGetCharacter(s,0)=='\n'))
      s=StringSubstr(s,1);
   while(StringLen(s)>0)
   {
      int last=StringLen(s)-1;
      int c=StringGetCharacter(s,last);
      if(c==' '||c=='\t'||c=='\r'||c=='\n') s=StringSubstr(s,0,last);
      else break;
   }
   return s;
}

int ParseImpact(const string s0)
{
   string s=TrimStr(s0);
   StringToLower(s);
   if(StringFind(s,"high")>=0 || s=="3") return 3;
   if(StringFind(s,"med")>=0  || s=="2") return 2;
   if(StringFind(s,"low")>=0  || s=="1") return 1;
   return 0;
}

// Safe convert string -> datetime (supports "YYYY.MM.DD HH:MI" or "YYYY-MM-DD HH:MI[:SS]" or ISO-ish)
datetime ParseTime(const string s0)
{
   string s=TrimStr(s0);
   if(s=="") return 0;

   // tolerate ISO-ish formats
   StringReplace(s,"T"," ");

   // strip trailing Z
   int L=StringLen(s);
   if(L>0)
   {
      int last=StringGetCharacter(s,L-1);
      if(last=='Z' || last=='z')
         s=StringSubstr(s,0,L-1);
   }

   // strip timezone like "+00:00" or "-05:00" if present (ISO suffix)
   for(int i=StringLen(s)-1;i>=0;i--)
   {
      int c=StringGetCharacter(s,i);
      if(c=='+' || c=='-')
      {
         // avoid stripping the '-' in the date (YYYY-MM-DD) by requiring i>10
         if(i>10)
         {
            string tail=StringSubstr(s,i);
            if(StringFind(tail,":")>=0)
               s=StringSubstr(s,0,i);
         }
         break;
      }
   }

   s=TrimStr(s);
   // normalize separators
   StringReplace(s,"-",".");
   datetime t=StringToTime(s); // supports seconds too
   if(t<=0) return 0;

   // apply offset
   if(InpNews_TimeOffsetMinutes!=0) t += (InpNews_TimeOffsetMinutes*60);
   return t;
}

// split CSV line by comma/semicolon (quote-aware)
int SplitCSV(const string line, string &out[])
{
   ArrayResize(out,0);

   string s=line;
   bool hasComma=(StringFind(s,",")>=0);
   bool hasSemi =(StringFind(s,";")>=0);
   int delim = (hasSemi && !hasComma ? ';' : ',');

   bool inQ=false;
   string field="";

   int L=StringLen(s);
   for(int i=0;i<L;i++)
   {
      int c=StringGetCharacter(s,i);

      if(c=='"')
      {
         // escaped quote inside quoted field: "" => "
         if(inQ && (i+1<L) && StringGetCharacter(s,i+1)=='"')
         {
            field += "\"";
            i++;
         }
         else
         {
            inQ = !inQ;
         }
         continue;
      }

      if(!inQ && c==delim)
      {
         int n=ArraySize(out);
         ArrayResize(out,n+1);
         out[n]=TrimStr(field);
         field="";
         continue;
      }

      field += StringSubstr(s,i,1);
   }

   int n=ArraySize(out);
   ArrayResize(out,n+1);
   out[n]=TrimStr(field);
   return ArraySize(out);
}

bool News_LoadCache()
{
   g_news_lastError="";
   g_news_n=0;
   int handle=FileOpen(InpNews_CacheFile, FILE_READ|FILE_TXT|FILE_ANSI);
   if(handle==INVALID_HANDLE)
   {
      g_news_lastError="NEWS_OPEN_FAIL";
      g_news_enabled=true; // module still runs; policy handled elsewhere
      g_news_lastLoad=TimeCurrent(); // HOTFIX: throttle reload attempts when file missing
      return false;
   }

   int parsed=0, skipped=0;
   int lineNo=0;
   // local guard so we only log header detection once per load
   bool loggedHeader=false;

   while(!FileIsEnding(handle) && g_news_n<2048)
   {
      string line="";
      if(!FileReadLineTxt(handle, line)) break;
      lineNo++;

      line=TrimStr(line);
      if(line=="" || StringGetCharacter(line,0)=='#') continue;

      string cols[];
      int n=SplitCSV(line, cols);
      if(!loggedHeader)
      {
         loggedHeader=true;
         if(InpDebug)
            Print("[NEWS] First non-comment line cols=",n," | ",line);
         string c0=cols[0];
         StringToLower(c0);
         if(StringFind(c0,"time")>=0 || StringFind(c0,"date")>=0)
         {
            skipped++;
            continue; // header row
         }
      }
      if(n<2)
      {
         skipped++;
         continue;
      }

      datetime t=ParseTime(cols[0]);
      if(t<=0)
      {
         skipped++;
         continue;
      }

      string ev=(n>=2?TrimStr(cols[1]):"");
      int imp=(n>=3?ParseImpact(cols[2]):0);
      string ccy=(n>=4?TrimStr(cols[3]):"");
      StringToUpper(ccy);
      if(ev=="") ev="(news)";

      g_news_events[g_news_n].t=t;
      g_news_events[g_news_n].event=ev;
      g_news_events[g_news_n].impact=imp;
      g_news_events[g_news_n].ccy=ccy;
      g_news_n++;
      parsed++;
   }
   FileClose(handle);
   g_news_lastLoad=TimeCurrent();
   g_news_enabled=true;

   // validate: if enabled and parsed 0 but file existed, mark error
   if(parsed==0)
      g_news_lastError="NEWS_EMPTY_OR_PARSE_FAIL";


   return true;
}

void News_UpdateIfDue()
{
   if(!InpNews_Enable) { g_news_enabled=false; return; }
   datetime now=TimeCurrent();
   if(g_news_lastLoad==0 || (now - g_news_lastLoad) >= InpNews_RefreshSec)
      News_LoadCache();
}

string News_LastError() { return g_news_lastError; }

bool News_IsBlockedForSymbol(const string sym, int &impactOut, string &eventOut, int &minutesToEvent)
{
   impactOut=0; eventOut=""; minutesToEvent=9999;
   if(!InpNews_Enable || !g_news_enabled) return false;

   // fail-closed policy: when errors exist, treat as blocked
   if(InpNews_FailClosedOnError && g_news_lastError!="")
   {
      impactOut=3;
      eventOut=g_news_lastError;
      minutesToEvent=0;
      return true;
   }

   // match currency: by base/profit
   string base=SymbolInfoString(sym, SYMBOL_CURRENCY_BASE);
   string prof=SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);

   datetime now=TimeCurrent();
   for(int i=0;i<g_news_n;i++)
   {
      datetime t=g_news_events[i].t;
      int diffMin=(int)MathFloor((double)(t - now)/60.0);
      // in window? diffMin positive means future
      if(diffMin > InpNews_BlockLeadMin) continue;
      if(diffMin < -InpNews_BlockLagMin) continue;

      // currency match: if ccy empty => apply to all
      string ccy=g_news_events[i].ccy;
      if(ccy!="")
      {
         if(ccy!=base && ccy!=prof) continue;
      }
      int imp=g_news_events[i].impact;
      if(imp<=0) imp=2;

      impactOut=imp;
      eventOut=g_news_events[i].event;
      minutesToEvent=diffMin;
      return true;
   }
   return false;
}

// return multiplier by impact; if none => 1.0
double News_RiskMultiplier(const string sym, string &why)
{
   why="";
   if(!InpNews_Enable || !InpNews_UseRiskScaling) return 1.0;
   int imp; string ev; int minTo;
   if(!News_IsBlockedForSymbol(sym, imp, ev, minTo)) return 1.0;

   why=ev;
   if(imp>=3) return InpNews_RiskMultHigh;
   if(imp==2) return InpNews_RiskMultMed;
   if(imp==1) return InpNews_RiskMultLow;
   return 1.0;
}

bool News_BlockEntriesForSymbol(const string sym, int &impactOut, string &eventOut, int &minutesToEvent)
{
   if(!InpNews_Enable || !InpNews_BlockEntries) return false;
   return News_IsBlockedForSymbol(sym, impactOut, eventOut, minutesToEvent);
}

bool News_BlockExitsForSymbol(const string sym, int &impactOut, string &eventOut, int &minutesToEvent)
{
   if(!InpNews_Enable || !InpNews_BlockExits) return false;
   return News_IsBlockedForSymbol(sym, impactOut, eventOut, minutesToEvent);
}

string KV_Safe(string s)
{
   StringReplace(s,"|","/");
   StringReplace(s,"\n"," ");
   StringReplace(s,"\r"," ");
   return s;
}

string News_StatusLine()
{
   if(!InpNews_Enable) return "NewsCSV: OFF";
   string err=(g_news_lastError=="" ? "OK" : g_news_lastError);
   return StringFormat("NewsCSV: %s (items=%d)", err, g_news_n);
}

/*
 * =========================
 * End Embedded News Engine
 * =========================
 */

// -----------------------------------------
// EA Inputs (overview; many kept from prior version)
// -----------------------------------------

// --- Symbols / TF
input string   InpSymbols                 = "EURUSD,GBPUSD,CUCUSD";
input ENUM_TIMEFRAMES InpEntryTF          = PERIOD_M1;  // DATA mode: more signals
input ENUM_TIMEFRAMES InpConfirmTF        = PERIOD_M5;  // DATA mode: faster confirm


// --- Optional: auto-resolve + per-symbol overrides (CSV in MQL5/Files)
input bool     InpAutoResolveSymbols         = true;   // try to map symbols with broker suffix/prefix (CFDs/stocks)
input bool     InpResolveAllowContainsMatch  = false;  // NEW: allow risky "contains" fallback only if unique
input bool     InpSymbolOverrides_Enable     = true;   // per-symbol parameter overrides from CSV
input string   InpSymbolOverrides_File       = "MSPB_SymbolOverrides.csv";
input bool     InpSymbolOverrides_UseCommonFolder = false;
input bool     InpSymbolOverrides_HotReload  = true;   // reload while running
input int      InpSymbolOverrides_ReloadSec  = 60;     // reload interval (seconds)
input bool     InpSymbolOverrides_PrintOnLoad= true;   // print loaded overrides in Experts log
// --- General
input long     InpMagic                   = 20250213;
input bool     InpAllowBuy                = true;
input bool     InpAllowSell               = true;
input int      InpMaxPositionsPerSymbol   = 2;
input int      InpMaxPositionsTotal       = 6;

// --- Entry driver / management
input bool     InpUseTimerForEntries      = true;   // if true, entries evaluated in OnTimer; else in OnTick
input bool     InpManageOnTick            = true;   // if true, position mgmt runs on tick; else in timer
input int      InpTimerSec                = 1;
input bool     InpSmartOrderRoute        = false;  // only use market orders when spread < ATR*InpSOR_SpreadATRRatio
input double   InpSOR_SpreadATRRatio     = 0.15;   // max spread/ATR ratio for market order execution

// --- Risk
input bool     InpUseRiskPercent          = true;
input double   InpRiskPercent             = 0.30;  // per trade (0.25 = nog stabieler)
input double   InpLots                    = 0.01; // fixed lot fallback when risk sizing disabled
input bool     InpUsePortfolioRiskGuard   = true;
input double   InpMaxPortfolioRiskPct     = 2.0;
input int      InpRisk_Cap_Mode           = 1;     // 0=Off, 1=Absolute
input double   InpRisk_Cap_USD_R          = 1.0;
input double   InpRisk_Cap_EUR_R          = 1.0;
input double   InpRisk_Cap_GBP_R          = 1.0;
input double   InpRisk_Cap_Other_R        = 1.0;
input bool     InpRisk_Cap_LogDetail      = true;
input int      InpRisk_Cap_TelegramCooldownSec = 120;

// --- SL/TP
input double   InpSL_ATR_Mult             = 1.2;  // DATA mode: slightly tighter SL for more turnover
input double   InpTP_RR                   = 0.8;  // DATA mode: faster TP

// --- Filters
input bool     InpUsePullbackEMA          = false;
input int      InpEMA_Period              = 50;
input bool     InpUseATRFilter            = true;
input double   InpMinATR_Pips             = 10.0;
input bool     InpUseADXFilter            = true;
input int      InpADX_Period              = 7;   // DATA mode: faster warm-up
input int      InpATR_Period             = 7;   // DATA mode: ATR period (was hardcoded 14)
input double   InpMinADXForEntry          = 20.0;
input double   InpMinADXEntryFilter       = 20.0;
input bool     InpUseBodyFilter           = false;
input double   InpMinBodyPips             = 2.0;


// --- Advanced filters / regimes (v9)
input bool     InpUseHTFBias              = true;
input ENUM_TIMEFRAMES InpBiasTF           = PERIOD_H1;
input int      InpBiasEMAFast             = 50;
input int      InpBiasEMASlow             = 200;
input bool     InpBias_FailClosed         = false; // if true: block entries when bias data not ready

input bool     InpUseCorrelationGuard     = true;
input ENUM_TIMEFRAMES InpCorrTF           = PERIOD_M15;
input int      InpCorrLookbackBars        = 120;
input double   InpCorrAbsThreshold        = 0.85;  // abs(corr) >= threshold blocks entry
input bool     InpCorrFXLikeOnly          = true;  // only apply to FX-like symbols (base!=profit)

// --- Execution / safety (v10)
input bool     InpUseMarketOrdersNoPrice  = true;   // send market orders with price=0.0 (less requotes)
input bool     InpUseAdaptiveDeviation    = true;   // adapt deviation to spread/ATR
input int      InpDev_MinPoints           = 10;
input double   InpDev_SpreadMult          = 2.0;    // deviation points = spreadPoints*mult + ATRPoints*ATRMult
input double   InpDev_ATRMult             = 0.10;
input int      InpDev_MaxPoints           = 200;    // safety cap (0 => no cap)

// --- Correlation guard behavior (v10)
input bool     InpCorrSameExposureOnly    = true;   // if true: block only when entry increases exposure (direction-aware)
input bool     InpCorrUseWeightedExposure = true;   // weight correlated exposure by lots and abs(corr)
input double   InpCorrMaxWeightedLots     = 2.0;    // block if sum(abs(corr)*openLots)+newLots exceeds this (FX-like only)

// --- Per-symbol cooldown after exits (v11)
input bool     InpUseSymbolCooldown       = true;
input bool     InpCooldownLossOnly        = true;   // apply cooldown only when net position P/L < 0
input double   InpCooldownLossMinR        = 0.10;  // apply cooldown only if loss <= -X R (e.g. 0.10). 0 => any loss
input int      InpCooldownSLMin           = 5;      // cooldown minutes after SL close (when loss-only: only if loss)
input int      InpCooldownTPMin           = 0;      // cooldown minutes after TP close (when loss-only: usually not applied)
input int      InpCooldownManualMin       = 1;      // cooldown minutes after manual/time-stop/other close (when loss-only: only if loss)
input int      InpCooldownExitMin         = 1;      // DEPRECATED: kept for compatibility (unused in v11)

input bool     InpUseVolRegime            = true;
input ENUM_TIMEFRAMES InpVolRegimeTF      = PERIOD_M5;
input int      InpVolRegimeLookbackBars   = 200;
input double   InpVolLowPct               = 20.0;  // <= => low vol regime
input double   InpVolHighPct              = 80.0;  // >= => high vol regime
input bool     InpVolLowBlockEntries      = true;  // block entries in low regime
input double   InpVolHighRiskMult         = 0.50;  // risk multiplier in high regime

// --- Volatility percentile filter (v18)
input bool     InpVolPctFilter_Enable    = false;  // block entries when ATR(20) below Nth pct of ATR(100)
input int      InpVolPctFilter_Period    = 20;     // short ATR period for percentile filter
input int      InpVolPctFilter_Base      = 100;    // base ATR period (denominator)
input double   InpVolPctFilter_Threshold = 30.0;  // block if below this percentile (0-100)

// --- Setup2
input bool     InpUseSetup2               = true;
input bool     InpUseBreakPrevHighLow     = true;

// --- Sessions
input bool     InpUseSessions             = false;
input int      InpLondonStartHour         = 7;
input int      InpLondonEndHour           = 17;
input int      InpNYStartHour             = 12;
input int      InpNYEndHour               = 21;
input double   InpLondon_SL_ATR_Mult     = 1.0;  // London session SL ATR multiplier (1.0 = same as base)
input double   InpAsia_SL_ATR_Mult       = 0.85; // Asia session SL ATR multiplier (tighter range)

// --- Swing S/R TP (v18)
input bool     InpUseSwingSR_TP          = false;  // use nearest swing high/low as TP target
input int      InpSwingSR_Lookback       = 30;     // bars to look back for swing points on confirmTF
input double   InpSwingSR_MinRR          = 1.2;    // minimum RR required to use the S/R TP
input double   InpSwingSR_MinDistPips    = 3.0;    // minimum distance (pips) between entry and S/R TP level
input int      InpSwingSR_SwingBars      = 2;      // N bars each side required for a swing point (1=3-bar, 2=5-bar, etc.)

// --- Body-to-range ratio filter — rejects doji/pinbar entries (P2-6)
input bool     InpUseBodyRatioFilter     = false;   // block if body/range < InpMinBodyRatio
input double   InpMinBodyRatio           = 0.30;    // min candle body fraction (0.0–1.0)

// --- Dynamic spread/ATR filter applied to all setups (P2-5)
input bool     InpUseDynamicSpreadFilter = false;   // block if spread/ATR > threshold (complements static InpMaxSpreadPips_FX)
input double   InpDynSpread_ATRRatio     = 0.15;    // max allowed spread/ATR ratio (e.g. 0.15 = 15 % of ATR)

// --- RSI divergence filter (P2-4)
input bool     InpUseDivergenceFilter    = false;   // require RSI divergence confirmation
input int      InpRSI_Period             = 14;      // RSI period for divergence check

// --- Ultra-HTF bias: third TF alignment (P2-7)
input bool     InpUseUltraHTFBias       = false;
input ENUM_TIMEFRAMES InpUltraBiasTF    = PERIOD_H4;
input int      InpUltraBiasEMAFast      = 50;
input int      InpUltraBiasEMASlow      = 200;

// --- Weekday filter (P3-8)
input bool     InpBlockMonday           = false;   // skip entries on Monday open (00:00–InpLondonStartHour)
input bool     InpBlockFriday           = false;   // skip entries on Friday from hour InpBlockFridayFromHour
input int      InpBlockFridayFromHour   = 17;      // hour (broker time) from which Friday entries are blocked

// --- Weekly loss limit (P3-9)
input bool     InpWeeklyLossLimit_Enable = false;
input double   InpWeeklyLossLimit_Pct    = 5.0;   // block new entries when week equity DD% exceeds this

// --- Post-SL bar-based cooldown (P3-10)
input bool     InpPostSL_CooldownBars_Enable = false;
input int      InpPostSL_CooldownBars        = 3;  // bars on entryTF to block after SL hit (stacks with minute cooldown)

// --- Adaptive ATR lookback based on EqRegime (P5-15)
input bool     InpAdaptiveATR_Enable    = false;
input int      InpATR_Period_Fast       = 5;       // ATR period in EQ_DEFENSIVE regime (shorter = more reactive)
input int      InpATR_Period_Mid        = 10;      // ATR period in EQ_CAUTION regime

// --- Slippage-adjusted OnTester score (P5-16)
input bool     InpTester_SlippagePenalty      = false;
input double   InpTester_SlippagePenalty_Mult = 0.1; // score deducted = mult * avg_slip_pips

// --- Spread
input double   InpMaxSpreadPips_FX        = 25.0;
input double   InpMaxSpreadPips_XAU       = 500.0;

input double   InpMaxSpreadPips_STOCK     = 50.0;   // stocks/CFDs default (if no overrides row; units follow symbol pip)
// --- Break-even / trailing
input bool     InpUseBreakEven            = true;
input double   InpBE_At_R                 = 0.8;
input double   InpBE_LockPips             = 1.0;
input double   InpBE_MinStepPips          = 0.5;

input bool     InpUseATRTrailing          = true;
input double   InpTrail_ATR_Mult          = 1.2;
input double   InpTrail_MinStepPips       = 0.8;

input bool     InpUseNewsAwareTrailing    = true; // spike-based trail tightening (no calendar)
input bool     InpIgnoreNewsTriggersDuringRollover = false;
input double   InpNewsSpike_ATR_Mult      = 2.5;
input double   InpNewsSpike_TightenMult   = 0.6;
input int      InpNewsSpike_CooldownMin   = 30;
input bool     InpNewsFreezeBE            = true;

input double   InpNewsSpike_MinATRPips     = 0.0;   // NEW: minimum ATR(pips) required for spike detection (0 => disabled)
// --- Exits
input bool     InpUseTimeStop             = true;
input int      InpTimeStopBars            = 2;    // DATA mode: faster timeout on M1
input bool     InpUseProtectMode          = true;
input bool     InpDSP_CloseWinnerBelowPipsIfNoSL = true;
input double   InpDSP_CloseWinnerBelowPips = 3.0;
input int      InpDSP_MinHoldBars         = 3; // NEW: avoid closing too early due to spread noise

// --- Telegram / Audit / ML
input bool     InpEnableTelegram          = false;
input string   InpTGMessagePrefix         = "EA";
input bool     InpTGEnableIncoming        = false;   // Incoming commands are not implemented in this build.

// Telegram credentials are loaded from a config file (avoid keeping secrets in Inputs/code).
// Place the file in:  MQL5\\Files\\  (or enable InpTGConfig_UseCommonFolder to use the common folder).
// Supported formats: KEY=VALUE per line. Lines starting with # or ; are ignored.
// Keys (case-insensitive): BOT_TOKEN (or TOKEN), CHAT_ID (or CHATID), ALLOWED_USER_ID, SECRET, PREFIX.
input string   InpTGConfigFile            = "MSPB_Telegram.cfg";
input bool     InpTGConfig_UseCommonFolder= false;
input bool     InpTGConfig_HotReload      = true;
input int      InpTGConfig_ReloadSec      = 300;

// --- Telegram Bot API (WebRequest) config (non-secret)
input int      InpTGTimeoutMS             = 5000;   // WebRequest timeout (ms)
input bool     InpTGDisableWebPreview     = true;   // disable link previews
input bool     InpTGTestOnInit            = true;   // send a startup test message
input bool     InpTGNotifyEntries         = false;  // send entry notifications
input bool     InpTGNotifyExitDeals       = false;  // send exit-deal notifications (can be noisy)
input bool     InpTGUseQueue              = true;   // queue + rate limit (recommended to avoid blocking/spam)
input int      InpTGRateLimitMs           = 1000;   // min delay between Telegram sends (ms). 1000 => 1 msg/sec
input int      InpTGBackoffMaxSec         = 60;     // max backoff on Telegram errors/429

input bool     InpEnableAuditLog          = true;
input bool     InpAuditFlushAlways        = false;

input bool     InpEnableMLExport          = false;
input string   InpMLFile                  = "ml_export_v2.csv";
input string   InpMLDelimiter             = ";";
input int      InpMLFlushEveryNRows       = 50; // increased for IO perf
input bool     InpMLLogSLMods             = true;
input bool     InpMLLogFailedOrders       = false; // log failed order attempts to ML (default: keep dataset clean)

// --- Auto proposal on closed trades
input bool     InpProposalOnClosedTrades      = true;
input int      InpProposalClosedTradesTrigger = 30;
input int      InpProposalMinMinutesBetween   = 60;

// --- Proposal report details (advanced stats + file export)
input int      InpProposalLookbackDays        = 365;   // history window to reconstruct trades
input bool     InpProposalSaveToFile          = true;  // save proposal report as .txt
input string   InpProposalFileName            = "MSPB_OptimizationProposal.txt";
input bool     InpProposalAppendToFile        = true;  // append instead of overwrite
input bool     InpProposalUseCommonFolder     = false; // true => terminal common files folder
input bool     InpProposalSplitPerSymbolFiles = true;  // also write one file per symbol
input ENUM_TIMEFRAMES InpProposalMAEMFETF     = PERIOD_M1; // timeframe used for MAE/MFE scan
input int      InpProposalMAEMFE_MaxBars      = 5000;  // safety cap for bar scan
input int      InpProposalMinTradesPerSymbol  = 5;     // minimum trades before giving per-symbol tuning hints
input int      InpProposalMAEMFE_MinTradeMinutes = 0;  // NEW: compute MAE/MFE only if duration >= X minutes (0 => all)


// --- Monthly tuning / acceptance / rollback (v11)
input bool     InpTune_Enable                  = false;
input string   InpTune_StateFile               = "MSPB_TuneState.csv";
input bool     InpTune_StateUseCommonFolder    = false;
input int      InpProposalTradesPerSymbol      = 300;   // gate: per symbol must have >= this many NEW closed positions before "ready to tune"
input int      InpTune_BaselineTrades          = 300;   // baseline window (closed positions) right BEFORE a settings-change

// Run 2nd Saturday of month @ (local terminal time) HH:MM (window to avoid missing timer drift)
input bool     InpTune_MonthlyNotify_Enable    = true;
input int      InpTune_RunHour                 = 2;
input int      InpTune_RunMinute               = 0;
input int      InpTune_RunWindowMinutes        = 10;

// Auto-rollback trial monitoring (per symbol overrides)
input bool     InpTune_Rollback_Enable         = true;
input int      InpTune_Rollback_MinDays        = 14;
input int      InpTune_Rollback_MinTrades      = 50;
input double   InpTune_Rollback_PF_Drop        = 0.10;  // rollback if PF < baselinePF - drop
input double   InpTune_Rollback_DD_IncreasePct = 10.0;  // rollback if DD(money) > baselineDD * (1+pct)
input double   InpTune_Rollback_AvgR_Drop      = 0.00;  // rollback if AvgR < baselineAvgR - drop (0 = must be >= baseline)
input int      InpTune_CheckEverySec           = 1800;  // throttle heavy history scans
input bool     InpTune_Rollback_AutoApply      = true;  // if false: only notify + optionally stop entries
input bool     InpTune_Rollback_StopEntries    = true;

input bool     InpSLModRetryTransient     = true;  // retry SL modify on transient retcodes
input int      InpSLModMaxRetries         = 1;
input int      InpSLModRetrySleepMS       = 100;   // NEW: delay between retries (ms), 0 => none

// --- Order (close/entry) retry on transient broker errors
input bool     InpOrderRetryTransient     = true;  // retry close/entry OrderSend on transient retcodes (requote, timeout, etc.)
input int      InpOrderRetryMaxRetries    = 2;     // max extra attempts (total = 1 + this; 2 => up to 3 sends)
input int      InpOrderRetrySleepMS       = 500;   // delay between retry attempts (ms)

// --- Fail safe
input bool     InpFailSafeStopEntriesOnMLFail = true;
input bool     InpFailSafeStopEntriesOnAuditFail = false;

// --- Sanity mode (startup guard for indicator readiness)
input bool     InpSanityMode_Enable        = true;
input int      InpSanityMode_Seconds       = 15;     // disable spike/trailing at least X seconds after start AND until ATR/ADX buffers are ready

// --- Debug / Dashboard
input bool     InpDebug                   = true;
input bool     InpShowDashboard           = true;




// --- Tester / robustness / diagnostics (NEW v12)
input double   InpSpreadStressMult        = 1.0;   // 1.0 normal; 1.4 => +40% spread stress (affects spread checks + deviation only)
input bool     InpTester_UseCustomCriterion = false; // enable OnTester() custom score (Strategy Tester optimization)
input int      InpTester_MinTradesForFullScore = 200; // trades below this get a penalty in score (0 => no penalty)
input double   InpTester_DDCapPct         = 20.0;  // hard reject in OnTester if equity DD% > cap (0 => no cap)
input bool     InpAppliedLog_Enable       = true;  // append applied settings snapshot to CSV when changed
input string   InpAppliedLog_File         = "MSPB_AppliedSettings.csv";
input bool     InpAppliedLog_UseCommonFolder = false;
input int      InpTradeDensity_MinTrades30d_Warn = 30; // warn if <X closed positions per symbol in last 30 days (0=off)
input int      InpTradeDensity_CheckSec   = 3600;  // how often to re-check history for trade-density warnings (sec)

// ============================================================
// v20.0 — Rendement improvements
// ============================================================

// --- A1: ML entry-gate (XGBoost threshold from export_model_thresholds.py)
input bool     InpUseMLEntryGate         = false;  // block entries when ML score < InpML_MinScore
input string   InpMLGateFile             = "ml_entry_threshold.json"; // output of export_model_thresholds.py
input double   InpML_MinScore            = 0.55;   // minimum score to allow entry (0-1)
input bool     InpMLGate_UseCommonFolder = false;

// --- A2: Three-level partial TP ladder (33/33/trailing rest)
input bool     InpTP_Ladder_Enable       = false;  // enable 3-level TP ladder
input double   InpTP_R1_ClosePct         = 33.0;   // % of position to close at R1 TP (R1 = initRisk * InpTP_R1_R)
input double   InpTP_R1_R                = 1.0;    // R multiple to trigger first partial close
input double   InpTP_R2_ClosePct         = 33.0;   // % of position to close at R2
input double   InpTP_R2_R                = 2.0;    // R multiple to trigger second partial close
input double   InpTP_R3_Trail_Mult       = 1.5;    // ATR trailing mult for remaining position after R2

// --- A3: Chandelier Exit as alternative trailing stop
input bool     InpUseChandelierExit      = false;  // use Chandelier Exit instead of fixed ATR trail
input int      InpChandelier_Period      = 22;     // highest-high / lowest-low lookback bars
input double   InpChandelier_Mult        = 3.0;    // ATR multiplier for chandelier distance

// --- A4: Re-entry / pyramiding after partial TP hit
input bool     InpUsePyramiding          = false;  // add a pyramid lot after first partial TP + BE
input int      InpPyramid_MaxAdds        = 1;      // maximum pyramid adds per position chain
input double   InpPyramid_RiskPct        = 0.5;    // % risk for each pyramid add (< normal risk)

// --- B6: Per-symbol auto-disable on negative expectancy
input bool     InpAutoDisable_Enable     = false;  // disable symbol for the week if expectancy < 0
input int      InpAutoDisable_Lookback   = 30;     // number of recent trades to measure expectancy

// --- B7: Kelly-fraction risk scaling
input bool     InpUseKellyScaling        = false;  // scale lot size by half-Kelly fraction
input int      InpKelly_Lookback         = 20;     // closed trades per symbol used for Kelly calculation
input double   InpKelly_Fraction         = 0.5;    // Kelly fraction (0.5 = half-Kelly, safer)
input double   InpKelly_MinMult          = 0.25;   // minimum Kelly multiplier (floor)
input double   InpKelly_MaxMult          = 2.0;    // maximum Kelly multiplier (cap)

// --- C8: Limit-order re-entry after spread block
input bool     InpUseLimitOnSpreadBlock  = false;  // place pending limit order when spread blocks entry
input int      InpLimitOrderTTL_Min      = 5;      // TTL in minutes before limit order is cancelled

// --- C9: Entry micro-delay after bar open (reduces slippage)
input int      InpEntryDelay_Ms          = 0;      // delay in ms before placing order (0 = disabled); e.g. 1500

// --- D10: Weekly symbol ranking via Sharpe (tools/rank_symbols.py)
input bool     InpUseWeeklySymbolRank    = false;  // enable/disable symbols based on weekly Sharpe ranking
input string   InpSymbolRankFile         = "ml_symbol_rank.csv"; // output of rank_symbols.py
input int      InpSymbolRank_TopN        = 3;      // number of top-ranked symbols to enable
input bool     InpSymbolRank_UseCommonFolder = false;

// --- D11: Cross-symbol spread-aware correlation filter
// Extends InpUseCorrelationGuard: when two correlated symbols both have signals,
// allow entry only on the symbol with the lower spread (vs blocking both).
input bool     InpCorrSpreadPrefer       = false;  // true: prefer lower-spread symbol; false: block as before

// -----------------------------------------
// Globals / enums
// -----------------------------------------
CTrade        trade;
CPositionInfo posInfo;

enum RejectReason
{
   REJ_NONE=0,
   REJ_NEWBAR,
   REJ_SESSION,
   REJ_SPREAD,
   REJ_ATR_MIN,
   REJ_ADX_TREND_MIN,
   REJ_ADX_ENTRY_MIN,
   REJ_BODY_MIN,
   REJ_BREAKPREV_FAIL,
   REJ_RISK_GUARDS,
   REJ_NEWS_STATE,
   REJ_BIAS_FAIL,
   REJ_CORR_GUARD,
   REJ_VOL_REGIME,
   REJ_COOLDOWN,    // NEW v10
   REJ_FAILSAFE,     // NEW
   REJ_MAX
};

string g_rejNames[REJ_MAX] = {
   "NONE","NEWBAR","SESSION","SPREAD","ATR_MIN","ADX_TREND_MIN","ADX_ENTRY_MIN","BODY_MIN","BREAKPREV_FAIL","RISK_GUARDS","NEWS_STATE","BIAS_FAIL","CORR_GUARD","VOL_REGIME","COOLDOWN","FAILSAFE"
};

int g_rejCounts[REJ_MAX];
int g_rejCountsSym[64][REJ_MAX];

void IncReject(const int symIdx, const RejectReason rr)
{
   if(rr<=REJ_NONE || rr>=REJ_MAX) return;
   g_rejCounts[rr]++;
   if(symIdx>=0 && symIdx<64) g_rejCountsSym[symIdx][rr]++;
}

// --- Symbol handling
string g_syms[64];
int    g_symCount=0;

// --- Per-cycle tick cache (micro-perf)
ulong g_cycleId=0;

struct SymTickCache
{
   ulong  cycleId;
   double bid;
   double ask;
   bool   valid;
};
SymTickCache g_tickCache[64];

// --- Fail-safe runtime state (NEW)
bool     g_failSafeStopEntries=false;
string   g_failSafeReason="";
datetime g_failSafeSince=0;
void     FailSafe_Trip(const string why); // forward declaration

// --- Tune state / auto-rollback (v11)
void     TuneState_Load();
void     TuneState_Save();
void     Tune_SyncWithOverrides(const bool onInit=false);
void     Tune_MaybeCheckRollback();
void     Tune_MaybeMonthlyNotify();


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
};

SymbolOverrides g_ovr[128];
int      g_ovrCount=0;
datetime g_ovrLastLoad=0;
datetime g_ovrNextReload=0;

string UpperTrim(const string s)
{
   string t=TrimStr(s);
   StringToUpper(t);
   return t;
}

double ParseDbl(const string s,const double defv=0.0)
{
   string t=TrimStr(s);
   if(t=="") return defv;
   return StringToDouble(t);
}
int ParseInt(const string s,const int defv=0)
{
   string t=TrimStr(s);
   if(t=="") return defv;
   return (int)StringToInteger(t);
}

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

      if(g_ovrCount>=ArraySize(g_ovr)) break;

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
               " ema=",(string)g_ovr[i].usePullbackEMA);
      }
   }
   return true;
}

void SymbolOverrides_UpdateIfDue()
{
   if(!InpSymbolOverrides_Enable || !InpSymbolOverrides_HotReload) return;
   datetime now=TimeCurrent();
   if(now<g_ovrNextReload) return;
   bool ok=LoadSymbolOverrides();
   if(ok && InpTune_Enable) Tune_SyncWithOverrides(false);
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
   return InpMinATR_Pips;
}
double Sym_MinADXTrend(const string sym)
{
   int k=FindOverrideIndex(sym);
   if(k>=0 && g_ovr[k].minADXTrend>0) return g_ovr[k].minADXTrend;
   return InpMinADXForEntry;
}
double Sym_MinADXEntry(const string sym)
{
   int k=FindOverrideIndex(sym);
   if(k>=0 && g_ovr[k].minADXEntry>0) return g_ovr[k].minADXEntry;
   return InpMinADXEntryFilter;
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

// Try to auto-resolve broker symbol names (useful for stocks/CFDs with suffix/prefix)
string ResolveSymbolName(const string raw)
{
   string s=TrimStr(raw);
   if(s=="") return "";

   // try direct select
   if(SymbolSelect(s,true)) return s;

   if(!InpAutoResolveSymbols) return s;

   string target=s; StringToUpper(target);
   int total=SymbolsTotal(false);

   // exact (case-insensitive)
   for(int i=0;i<total;i++)
   {
      string name=SymbolName(i,false);
      string up=name; StringToUpper(up);
      if(up==target)
         if(SymbolSelect(name,true)) return name;
   }
   // prefix match
   for(int i=0;i<total;i++)
   {
      string name=SymbolName(i,false);
      string up=name; StringToUpper(up);
      if(StringFind(up,target)==0)
         if(SymbolSelect(name,true)) return name;
   }

   // NEW: contains match only if explicitly allowed AND unique
   if(InpResolveAllowContainsMatch)
   {
      string hit="";
      int hits=0;
      for(int i=0;i<total;i++)
      {
         string name=SymbolName(i,false);
         string up=name; StringToUpper(up);
         if(StringFind(up,target)>=0)
         {
            hit=name;
            hits++;
            if(hits>1) break;
         }
      }
      if(hits==1)
         if(SymbolSelect(hit,true)) return hit;
   }

   return s;
}


// ----------------------------------------------------
// Hard whitelist: trade only these FX pairs (suffix ok)
// ----------------------------------------------------
bool IsAllowedTradeSymbol(const string sym)
{
   string base = SymbolInfoString(sym, SYMBOL_CURRENCY_BASE);
   string prof = SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);

   string pair = UpperTrim(base) + UpperTrim(prof);

   // Fallback: if currency fields are unavailable (some CFDs), use prefix match
   if(pair=="")
   {
      string up=sym; StringToUpper(up);
      if(StringFind(up,"EURUSD")==0) pair="EURUSD";
      else if(StringFind(up,"GBPUSD")==0) pair="GBPUSD";
      else if(StringFind(up,"CUCUSD")==0) pair="CUCUSD";
   }

   return (pair=="EURUSD" || pair=="GBPUSD" || pair=="CUCUSD");
}


struct SymbolState
{
   datetime lastBar;
   datetime lastConfirmBar;
   datetime lastNewsSpike; // for spike cooldown
   // v9 caches
   datetime lastBiasBar;
   int      biasDir;
   datetime lastVolBar;
   double   volMult;
   bool     volBlock;
   double   volPct;
   bool     volValid;
   // v10 cooldown (entry throttle after exit)
   datetime cooldownUntil;
   int      cooldownReason; // 0 none, 2 SL, 3 TP, 4 MANUAL/OTHER
   // v20: per-symbol runtime state
   datetime autoDisabledUntil; // epoch until symbol is auto-disabled (B6)
   int      pyramidCount;      // active pyramid adds on this symbol (A4)
   // v20: Kelly & auto-disable rolling stats (last InpKelly_Lookback trades)
   double   kellyPnL[64];      // circular buffer of per-trade P&L
   int      kellyPnLHead;      // head pointer into circular buffer
   int      kellyPnLN;         // number of trades recorded (capped at 64)
   // v20: TP-ladder state per position chain (tracked by open position posId)
   long     ladderPosId;       // posId being tracked by the ladder
   bool     ladderR1Done;      // first partial close done
   bool     ladderR2Done;      // second partial close done
   double   ladderInitRisk;    // initial risk in pips for the tracked position
   double   ladderVolInit;     // initial volume for partial-close calculations
   // v20: rank-disable flag (refreshed weekly from ml_symbol_rank.csv)
   bool     rankEnabled;       // true if symbol is in the top-N weekly ranking
};
SymbolState g_sym[64];

// --- Equity regime
enum EqRegime { EQ_NEUTRAL=0, EQ_CAUTION=1, EQ_DEFENSIVE=2 };
EqRegime g_eqRegime=EQ_NEUTRAL;
double   g_riskMult=1.0;

// --- Dashboard
string g_dashObjPrefix="MSPB_DASH_";

// --- ML export state
int    g_mlHandle=INVALID_HANDLE;
string g_mlSchema="v2";
int    g_mlRowsSinceFlush=0;
datetime g_mlLastRot=0;

// --- Audit log state
int    g_auditHandle=INVALID_HANDLE;
bool   g_inAuditLog=false;

// --- v20 ML gate state
double   g_mlGateThreshold    = 0.55;      // loaded from JSON
double   g_mlGateWeights[6];               // feature weights (parallel to NUMERIC_FEATURES)
double   g_mlGateMeans[6];                 // feature means
double   g_mlGateStds[6];                  // feature stds
bool     g_mlGateLoaded        = false;    // true once JSON loaded
datetime g_mlGateLastLoad      = 0;        // last load time

// v20 NUMERIC_FEATURES order: atr_pips(0), adx_trend(1), adx_entry(2), spread_pips(3), body_pips(4), r_mult(5)
const int ML_GATE_NFEAT = 6;

// --- v20 pending limit orders (C8)
struct PendingLimit
{
   ulong    ticket;
   string   sym;
   datetime expiresAt;
};
PendingLimit g_pendingLimits[32];
int          g_pendingLimitsN = 0;

// --- v20 weekly symbol rank refresh state (D10)
datetime g_rankLastRefresh = 0;

// --- Deal queue
ulong  g_dealQueueTickets[4096];
int    g_dealQHead=0, g_dealQTail=0;
datetime g_dealQLastProgress=0;
int     g_dealQBackoffSec=0;

datetime g_dealQNextTry=0; // NEW: backoff timer for deal queue processing
datetime g_riskCapLastTG=0;

// --- Sanity mode runtime state (NEW)
datetime g_startTime=0;       // EA start time for sanity warm-up
datetime g_sanityNextCheck=0; // next time we probe indicator readiness
bool     g_indReady[64];      // per-symbol indicator readiness (ATR+ADX buffers ready)
// --- entry loop re-entrancy guard
bool g_entryLoopBusy=false;
// --- Auto proposal counters
int      g_closedTradesSinceProposal = 0;
datetime g_lastProposalTime = 0;

// --- Position closure tracker (to count *closed positions* reliably, even with multi-fill exit deals)
long   g_posTrackId[256];
double g_posTrackVolIn[256];
double g_posTrackVolOut[256];
double g_posTrackProfit[256];
double g_posTrackRiskMoney[256];
double g_posTrackOpenSum[256];
double g_posTrackSL0[256];
long   g_posTrackLastReason[256];
int    g_posTrackN=0;



// -----------------------------------------
// Utility: string helpers
// -----------------------------------------
string Shorten(const string s, const int maxLen=80)
{
   if(StringLen(s)<=maxLen) return s;
   return StringSubstr(s,0,maxLen-3)+"...";
}

string NowStr()
{
   datetime now=TimeCurrent();
   return TimeToString(now, TIME_DATE|TIME_SECONDS);
}

// -----------------------------------------
// Closed-position counting helper
// -----------------------------------------
int PosTrackFind(const long posId)
{
   for(int i=0;i<g_posTrackN;i++)
      if(g_posTrackId[i]==posId) return i;
   return -1;
}

// Returns true exactly once when the tracked position becomes fully closed (based on deal volumes).
bool PosTrackUpdate(const string sym,
                    const long posId,
                    const int  dealEntry,
                    const double vol,
                    const double dealProfitSum,
                    const long dealReason,
                    const double dealPrice,
                    const double dealSL,
                    double &outPosProfit,
                    long &outLastReason,
                    double &outPosRiskMoney)
{
   outPosProfit=0.0;
   outLastReason=0;
   outPosRiskMoney=0.0;

   if(posId<=0 || vol<=0.0) return false;

   int idx=PosTrackFind(posId);
   if(idx<0)
   {
      if(g_posTrackN>=ArraySize(g_posTrackId))
      {
         // Tracker full; fall back to counting per exit deal (won't break EA)
         bool isExit = (dealEntry==DEAL_ENTRY_OUT || dealEntry==DEAL_ENTRY_OUT_BY || dealEntry==DEAL_ENTRY_INOUT);
         if(isExit)
         {
            outPosProfit = dealProfitSum;
            outLastReason = dealReason;
         }
         return isExit;
      }
      idx=g_posTrackN++;
      g_posTrackId[idx]=posId;
      g_posTrackVolIn[idx]=0.0;
      g_posTrackVolOut[idx]=0.0;
      g_posTrackProfit[idx]=0.0;
      g_posTrackRiskMoney[idx]=0.0;
      g_posTrackOpenSum[idx]=0.0;
      g_posTrackSL0[idx]=0.0;
      g_posTrackLastReason[idx]=0;
   }

   // Accumulate volume + profit
   if(dealEntry==DEAL_ENTRY_IN || dealEntry==DEAL_ENTRY_INOUT)
      g_posTrackVolIn[idx]+=vol;

   // Track weighted average entry price for fallback risk estimation
   if(dealEntry==DEAL_ENTRY_IN || dealEntry==DEAL_ENTRY_INOUT)
      g_posTrackOpenSum[idx] += dealPrice * vol;

   // Track first seen entry SL as initial SL (fallback)
   if((dealEntry==DEAL_ENTRY_IN || dealEntry==DEAL_ENTRY_INOUT) && dealSL>0.0 && g_posTrackSL0[idx]<=0.0)
      g_posTrackSL0[idx]=dealSL;

   if(dealEntry==DEAL_ENTRY_OUT || dealEntry==DEAL_ENTRY_OUT_BY || dealEntry==DEAL_ENTRY_INOUT)
      g_posTrackVolOut[idx]+=vol;

   // Track initial risk money from entry-side deals when SL is known.
   if((dealEntry==DEAL_ENTRY_IN || dealEntry==DEAL_ENTRY_INOUT) && dealSL>0.0)
   {
      double rm = PositionRiskMoney(sym, dealPrice, dealSL, vol);
      if(rm>0.0) g_posTrackRiskMoney[idx] += rm;
   }

   g_posTrackProfit[idx] += dealProfitSum;

   // Track last exit reason (only meaningful on exit-side deals)
   if(dealEntry==DEAL_ENTRY_OUT || dealEntry==DEAL_ENTRY_OUT_BY || dealEntry==DEAL_ENTRY_INOUT)
      g_posTrackLastReason[idx]=dealReason;

   // If we never saw the entry deal (EA restarted), we cannot reliably count closures unless seeded.
   if(g_posTrackVolIn[idx]<=0.0)
      return false;

   // Fully closed?
   if(g_posTrackVolOut[idx] + 1e-8 >= g_posTrackVolIn[idx])
   {
      outPosProfit    = g_posTrackProfit[idx];
      outLastReason   = g_posTrackLastReason[idx];
      outPosRiskMoney = g_posTrackRiskMoney[idx];

      // Fallback: if entry deals didn't carry DEAL_SL, try compute risk from stored avg entry + initial SL.
      if(outPosRiskMoney<=0.0)
      {
         if(g_posTrackVolIn[idx]>0.0 && g_posTrackSL0[idx]>0.0 && g_posTrackOpenSum[idx]>0.0)
         {
            double avgEntry = g_posTrackOpenSum[idx] / g_posTrackVolIn[idx];
            double rm = PositionRiskMoney(sym, avgEntry, g_posTrackSL0[idx], g_posTrackVolIn[idx]);
            if(rm>0.0) outPosRiskMoney = rm;
         }

         // Rare edge-case: during partial closes, the position can still exist.
         if(outPosRiskMoney<=0.0)
         {
            int tot=PositionsTotal();
            for(int pi=0; pi<tot; pi++)
            {
               ulong pt=PositionGetTicket(pi);
               if(pt==0) continue;
               if(!PositionSelectByTicket(pt)) continue;
               if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
               if(PositionGetString(POSITION_SYMBOL)!=sym) continue;
               long pid=(long)PositionGetInteger(POSITION_IDENTIFIER);
               if(pid!=posId) continue;

               double op=PositionGetDouble(POSITION_PRICE_OPEN);
               double slp=PositionGetDouble(POSITION_SL);
               double vv=PositionGetDouble(POSITION_VOLUME);
               double rm = PositionRiskMoney(sym, op, slp, vv);
               if(rm>0.0) { outPosRiskMoney = rm; break; }
            }
         }
      }

      // Remove by swap-with-last
      int last=g_posTrackN-1;
      g_posTrackId[idx]=g_posTrackId[last];
      g_posTrackVolIn[idx]=g_posTrackVolIn[last];
      g_posTrackVolOut[idx]=g_posTrackVolOut[last];
      g_posTrackProfit[idx]=g_posTrackProfit[last];
      g_posTrackRiskMoney[idx]=g_posTrackRiskMoney[last];
      g_posTrackOpenSum[idx]=g_posTrackOpenSum[last];
      g_posTrackSL0[idx]=g_posTrackSL0[last];
      g_posTrackLastReason[idx]=g_posTrackLastReason[last];
      g_posTrackN--;
      return true;
   }
   return false;
}

void PosTrackSeedOpenPositions()
{
   // Reset and seed from currently open positions (useful after EA restart)
   g_posTrackN=0;
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      long magic=(long)PositionGetInteger(POSITION_MAGIC);
      if(magic!=InpMagic) continue;
      string sym=PositionGetString(POSITION_SYMBOL);
      long posId=(long)PositionGetInteger(POSITION_IDENTIFIER);
      double vol=PositionGetDouble(POSITION_VOLUME);
      if(posId<=0 || vol<=0.0) continue;

      if(g_posTrackN>=ArraySize(g_posTrackId)) break;
      g_posTrackId[g_posTrackN]=posId;
      g_posTrackVolIn[g_posTrackN]=vol;
      g_posTrackVolOut[g_posTrackN]=0.0;
      g_posTrackProfit[g_posTrackN]=0.0;
      g_posTrackLastReason[g_posTrackN]=0;
      double openPx=PositionGetDouble(POSITION_PRICE_OPEN);
      double slPx=PositionGetDouble(POSITION_SL);
      g_posTrackOpenSum[g_posTrackN]=openPx*vol;
      g_posTrackSL0[g_posTrackN]=slPx;
      g_posTrackRiskMoney[g_posTrackN]=PositionRiskMoney(sym, openPx, slPx, vol);
      g_posTrackN++;
   }
}

// -----------------------------------------
// Status helper
// -----------------------------------------
void Status_SetTrade(const string key, const int code, const string msg)
{
   if(InpDebug)
      PrintFormat("STATUS %s code=%d msg=%s", key, code, msg);
}


// --- Fail-safe implementation (NEW)
void FailSafe_Trip(const string why)
{
   if(g_failSafeStopEntries) return;
   g_failSafeStopEntries=true;
   g_failSafeReason=why;
   g_failSafeSince=TimeCurrent();
   Print("FAILSAFE: Entries stopped. Reason=", why);

   if(InpEnableTelegram)
      TelegramSendMessage("FAILSAFE: Entries stopped. Reason=" + why);
}

// -----------------------------------------
// Audit log
// -----------------------------------------
bool Audit_Open()
{
   if(!InpEnableAuditLog) return true;
   if(g_auditHandle!=INVALID_HANDLE) return true;

   string fn = "audit_log.txt";
   bool exists = FileIsExist(fn);

   // Open in append mode (do NOT truncate on restart)
   // NEW: FILE_SHARE_READ so we can read/tail it live
   g_auditHandle = FileOpen(fn, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_WRITE|FILE_SHARE_READ);
   if(g_auditHandle==INVALID_HANDLE)
   {
      Status_SetTrade("AUDIT_OPEN_FAIL", GetLastError(), "");
      if(InpFailSafeStopEntriesOnAuditFail)
         FailSafe_Trip("AUDIT_OPEN_FAIL");
      return false;
   }
   if(exists) FileSeek(g_auditHandle, 0, SEEK_END);
   return true;
}

void Audit_Log(const string ev, const string kv, const bool sendTelegram=false)
{
   if(!InpEnableAuditLog) return;
   if(g_auditHandle==INVALID_HANDLE)
   {
      if(!Audit_Open()) return;
   }

   string line=StringFormat("%s | %s | %s", NowStr(), ev, kv);

   ResetLastError();
   int bytes=(int)FileWriteString(g_auditHandle, line+"\r\n");
   int err=GetLastError();

   if(InpAuditFlushAlways) FileFlush(g_auditHandle);

   if(bytes<=0 || err!=0)
   {
      Status_SetTrade("AUDIT_WRITE_FAIL", err, "");
      if(InpFailSafeStopEntriesOnAuditFail)
         FailSafe_Trip("AUDIT_WRITE_FAIL");
   }

   if(sendTelegram) TelegramSendMessage(line);
}

void Audit_Close()
{
   if(g_auditHandle!=INVALID_HANDLE)
   {
      FileClose(g_auditHandle);
      g_auditHandle=INVALID_HANDLE;
   }
}

// -----------------------------------------
// ML export
// -----------------------------------------
char GetMLDelim()
{
   if(StringLen(InpMLDelimiter)<1) return ';';
   return (char)StringGetCharacter(InpMLDelimiter,0);
}

bool ML_Open()
{
   if(!InpEnableMLExport) return true;
   if(g_mlHandle!=INVALID_HANDLE) return true;

   bool exists = (FileIsExist(InpMLFile));
   g_mlHandle=FileOpen(InpMLFile, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_WRITE, GetMLDelim());
   if(g_mlHandle==INVALID_HANDLE)
   {
      Status_SetTrade("ML_OPEN_FAIL", GetLastError(), InpMLFile);
      if(InpFailSafeStopEntriesOnMLFail)
         FailSafe_Trip("ML_OPEN_FAIL");
      return false;
   }
   if(exists) FileSeek(g_mlHandle, 0, SEEK_END);
   if(!exists)
   {
      // header v2
      FileWrite(g_mlHandle,
         "run_id","ts","symbol","setup","dir","entry","sl","tp","lots","risk_money",
         "atr_pips","adx_trend","adx_entry","spread_pips","body_pips",
         "rej_reason","rej_detail",
         "pos_id","event","profit_pips","profit_money","r_mult",
         "slmod_ret","comment","schema"
      );
      // config row
      FileWrite(g_mlHandle, "cfg", NowStr(), "", "", "", "", "", "", "", "",
                "", "", "", "", "", "", "",
                "", "CONFIG", "", "", "",
                "", "schema="+g_mlSchema, g_mlSchema);
   }
   return true;
}

void ML_Close()
{
   if(g_mlHandle!=INVALID_HANDLE)
   {
      FileClose(g_mlHandle);
      g_mlHandle=INVALID_HANDLE;
   }
}

void ML_MaybeFlush()
{
   if(!InpEnableMLExport) return;
   if(g_mlHandle==INVALID_HANDLE) return;
   if(g_mlRowsSinceFlush >= InpMLFlushEveryNRows)
   {
      FileFlush(g_mlHandle);
      g_mlRowsSinceFlush=0;
   }
}

// NEW: per-symbol digits helpers (ML + audit)
int SymDigitsSafe(const string sym)
{
   if(sym=="") return _Digits;
   int d=(int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   if(d<=0) d=_Digits;
   return d;
}
string FmtPriceSym(const string sym, const double v)
{
   if(v==0.0) return "0";
   return DoubleToString(v, SymDigitsSafe(sym));
}

void ML_WriteRowV2(
   const string run_id,
   const string ts,
   const string sym,
   const string setup,
   const string dir,
   const double entry,
   const double sl,
   const double tp,
   const double lots,
   const double risk_money,
   const double atr_pips,
   const double adx_trend,
   const double adx_entry,
   const double spread_pips,
   const double body_pips,
   const string rej_reason,
   const string rej_detail,
   const long pos_id,
   const string event,
   const double profit_pips,
   const double profit_money,
   const double r_mult,
   const int slmod_ret,
   const string comment,
   const string schema,
   const string kv=""
)
{
   if(!InpEnableMLExport) return;
   if(g_mlHandle==INVALID_HANDLE)
   {
      if(!ML_Open())
      {
         if(InpFailSafeStopEntriesOnMLFail)
            FailSafe_Trip("ML_OPEN_FAIL");
         return;
      }
   }

   int d = SymDigitsSafe(sym);

FileWrite(g_mlHandle,
      run_id, ts, sym, setup, dir,
      DoubleToString(entry, d),
      DoubleToString(sl,    d),
      DoubleToString(tp,    d),
      DoubleToString(lots,2),
      DoubleToString(risk_money,2),
      DoubleToString(atr_pips,2),
      DoubleToString(adx_trend,2),
      DoubleToString(adx_entry,2),
      DoubleToString(spread_pips,2),
      DoubleToString(body_pips,2),
      rej_reason, rej_detail,
      (string)pos_id, event,
      DoubleToString(profit_pips,2),
      DoubleToString(profit_money,2),
      DoubleToString(r_mult,2),
      slmod_ret,
      comment,
      schema
   );
   g_mlRowsSinceFlush++;
   ML_MaybeFlush();
}

// -----------------------------------------
// Risk helpers
// -----------------------------------------
double PipSize(const string sym)
{
   double pt=SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits=(int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   // 5-digit FX: pip=10 points
   if(digits==3 || digits==5) return pt*10.0;
   return pt;
}
void Cycle_Begin()
{
   g_cycleId++;
   if(g_cycleId==0) g_cycleId=1;
}

bool GetBidAskCached(const int symIdx, const string sym, double &bid, double &ask)
{
   if(symIdx>=0 && symIdx<64 &&
      g_tickCache[symIdx].valid &&
      g_tickCache[symIdx].cycleId==g_cycleId)
   {
      bid=g_tickCache[symIdx].bid;
      ask=g_tickCache[symIdx].ask;
      return (bid>0.0 && ask>0.0);
   }

   MqlTick tk;
   if(!SymbolInfoTick(sym, tk)) return false;

   bid=tk.bid;
   ask=tk.ask;

   if(symIdx>=0 && symIdx<64)
   {
      g_tickCache[symIdx].cycleId=g_cycleId;
      g_tickCache[symIdx].valid=true;
      g_tickCache[symIdx].bid=bid;
      g_tickCache[symIdx].ask=ask;
   }
   return (bid>0.0 && ask>0.0);
}

double SpreadPipsPrices(const string sym, const double bid, const double ask)
{
   double pip=PipSize(sym);
   if(pip<=0.0) return 0.0;

   double sp = (ask-bid)/pip;
   double mult = (InpSpreadStressMult<=0.0 ? 1.0 : InpSpreadStressMult);
   return sp * mult;
}

bool SpreadAllowsPrices(const string sym, const double bid, const double ask)
{
   double sp=SpreadPipsPrices(sym,bid,ask);
   double maxsp=Sym_MaxSpreadPips(sym);
   return (sp<=maxsp);
}

int AdaptiveDeviationPointsPrices(const string sym, const double bid, const double ask, const double atrPips)
{
   int minp = MathMax(1, InpDev_MinPoints);
   if(!InpUseAdaptiveDeviation) return minp;
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt<=0.0) return minp;
   double pip = PipSize(sym);
   double mult = (InpSpreadStressMult<=0.0 ? 1.0 : InpSpreadStressMult);
   double spreadPoints = ((ask-bid)/pt) * mult;
   double atrPoints = 0.0;
   if(pip>0.0 && atrPips>0.0) atrPoints = (atrPips*pip)/pt;
   double raw = MathMax((double)minp, spreadPoints*InpDev_SpreadMult + atrPoints*InpDev_ATRMult);
   int dev = (int)MathCeil(raw);
   if(InpDev_MaxPoints>0) dev = (int)MathMin((double)dev, (double)InpDev_MaxPoints);
   if(dev<1) dev=1;
   return dev;
}

int SymIndexByName(const string sym)
{
   for(int i=0;i<g_symCount;i++)
      if(g_syms[i]==sym) return i;
   return -1;
}

int SymIndexByNameLoose(const string sym)
{
   int idx=SymIndexByName(sym);
   if(idx>=0) return idx;

   string us=sym;
   StringToUpper(us);

   int best=-1;
   int bestScore=-1;

   for(int i=0;i<g_symCount;i++)
   {
      string ug=g_syms[i];
      StringToUpper(ug);

      if(ug==us) return i;

      // Prefix/suffix tolerant matching (common broker suffix like ".m", "-ECN", etc.)
      bool match=false;
      if(StringFind(us, ug)==0) match=true;           // sym starts with g_syms[i]
      else if(StringFind(ug, us)==0) match=true;      // g_syms[i] starts with sym

      if(match)
      {
         int score=StringLen(ug);
         if(score>bestScore)
         {
            bestScore=score;
            best=i;
         }
      }
   }

   // As a last resort, try containment match (pick the longest match).
   if(best<0)
   {
      for(int i=0;i<g_symCount;i++)
      {
         string ug=g_syms[i];
         StringToUpper(ug);
         if(StringFind(us, ug)>=0 || StringFind(ug, us)>=0)
         {
            int score=StringLen(ug);
            if(score>bestScore)
            {
               bestScore=score;
               best=i;
            }
         }
      }
   }
   return best;
}




void Cooldown_Apply(const string sym,
                    const datetime now,
                    const long closeReason,
                    const double posProfit,
                    const double posRiskMoney)
{
   int i = SymIndexByNameLoose(sym);

   // P3-10: bar-based cooldown on SL hit (unconditional — not subject to LossOnly filter)
   if(closeReason == DEAL_REASON_SL && i >= 0 && i < g_symCount)
      PostSL_CooldownBars_Trigger(i);

   if(!InpUseSymbolCooldown) return;

   // v12: apply cooldown only when net position P/L < 0 (optional)
   // and optionally only when the loss exceeds a minimum in R (micro-loss filter).
   if(InpCooldownLossOnly)
   {
      if(posProfit >= 0.0) return;
      if(InpCooldownLossMinR > 0.0 && posRiskMoney > 0.0)
      {
         double r = posProfit / posRiskMoney; // negative on loss
         if(r > -InpCooldownLossMinR) return; // loss smaller than threshold
      }
   }

   if(i<0 || i>=g_symCount) return;

   int mins=0;
   if(closeReason==DEAL_REASON_SL) mins = InpCooldownSLMin;
   else if(closeReason==DEAL_REASON_TP) mins = InpCooldownTPMin;
   else mins = InpCooldownManualMin;

   // Backward compatibility: if ManualMin not set, fall back to ExitMin
   if(mins<=0 && closeReason!=DEAL_REASON_SL && closeReason!=DEAL_REASON_TP)
      mins = InpCooldownExitMin;

   if(mins<=0) return;

   datetime until = now + (mins*60);
   if(until > g_sym[i].cooldownUntil) g_sym[i].cooldownUntil = until;

   // reason codes: 2=SL,3=TP,4=MANUAL/OTHER
   if(closeReason==DEAL_REASON_SL) g_sym[i].cooldownReason = 2;
   else if(closeReason==DEAL_REASON_TP) g_sym[i].cooldownReason = 3;
   else g_sym[i].cooldownReason = 4;
}


// -----------------------------------------
// Weekday filter (P3-8)
// -----------------------------------------
bool WeekdayAllows()
{
   if(!InpBlockMonday && !InpBlockFriday) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int dow = dt.day_of_week; // 0=Sun,1=Mon,...,5=Fri,6=Sat
   if(InpBlockMonday && dow == 1 && dt.hour < InpLondonStartHour)
      return false;
   if(InpBlockFriday && dow == 5 && dt.hour >= InpBlockFridayFromHour)
      return false;
   return true;
}

// -----------------------------------------
// Weekly loss limit (P3-9)
// -----------------------------------------
void WeeklyLoss_UpdateIfNewWeek()
{
   if(!InpWeeklyLossLimit_Enable) return;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int dow = dt.day_of_week;
   if(dow == 0) dow = 7; // treat Sunday as day 7 so Monday is day 1
   datetime monStart = TimeCurrent() - ((datetime)(dow - 1)) * 86400
                     - (datetime)dt.hour * 3600 - (datetime)dt.min * 60 - (datetime)dt.sec;
   if(monStart != g_weekStart)
   {
      g_weekStart   = monStart;
      g_weekEqStart = AccountInfoDouble(ACCOUNT_EQUITY);
      if(g_weekEqStart <= 0.0) g_weekEqStart = AccountInfoDouble(ACCOUNT_BALANCE);
   }
}

bool WeeklyLossAllows()
{
   if(!InpWeeklyLossLimit_Enable) return true;
   if(g_weekEqStart <= 0.0) return true;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq <= 0.0) eq = AccountInfoDouble(ACCOUNT_BALANCE);
   double ddPct = (g_weekEqStart - eq) / g_weekEqStart * 100.0;
   if(ddPct >= InpWeeklyLossLimit_Pct)
   {
      if(InpDebug)
         PrintFormat("WEEKLY_LOSS_BLOCK: weekDD=%.2f%% >= limit=%.2f%%", ddPct, InpWeeklyLossLimit_Pct);
      return false;
   }
   return true;
}

// -----------------------------------------
// Deal deduplication helpers (P1-3)
// -----------------------------------------
bool DealSeen_Add(const ulong ticket)
{
   // Returns true if newly added (not yet seen), false if duplicate.
   int cap = ArraySize(g_processedDeals);
   int check = MathMin(g_processedDealsN, cap);
   for(int i = 0; i < check; i++)
      if(g_processedDeals[i] == ticket) return false;
   g_processedDeals[g_processedDealsN % cap] = ticket;
   g_processedDealsN++;
   return true;
}

// -----------------------------------------
// Adaptive ATR period based on EqRegime (P5-15)
// -----------------------------------------
int GetCurrentATRPeriod()
{
   if(!InpAdaptiveATR_Enable) return MathMax(1, InpATR_Period);
   if(g_eqRegime == EQ_DEFENSIVE) return MathMax(1, InpATR_Period_Fast);
   if(g_eqRegime == EQ_CAUTION)   return MathMax(1, InpATR_Period_Mid);
   return MathMax(1, InpATR_Period);
}

// -----------------------------------------
// Indicator handle revalidation (P1-2)
// Called from OnTimer; catches handles that became INVALID_HANDLE after reconnect.
// -----------------------------------------
void Handles_CheckAndReinit()
{
   bool needEMA_global = (InpUsePullbackEMA || InpSymbolOverrides_Enable);
   for(int i = 0; i < g_symCount; i++)
   {
      string sym = g_syms[i];
      bool needEMA = (needEMA_global || Sym_UsePullbackEMA(sym));
      bool reinit  = false;

      if(needEMA && g_emaHandle[i] == INVALID_HANDLE)           reinit = true;
      if(g_atrHandle[i] == INVALID_HANDLE)                      reinit = true;
      if(InpUseVolRegime && g_atrVolHandle[i] == INVALID_HANDLE) reinit = true;
      if(InpUseADXFilter && (g_adxHandle[i] == INVALID_HANDLE ||
                             g_adxEntryHandle[i] == INVALID_HANDLE)) reinit = true;
      if(InpUseHTFBias && (g_biasFastHandle[i] == INVALID_HANDLE ||
                           g_biasSlowHandle[i] == INVALID_HANDLE))  reinit = true;
      if(InpUseDivergenceFilter && g_rsiHandle[i] == INVALID_HANDLE) reinit = true;
      if(InpUseUltraHTFBias && (g_ultraBiasFastHandle[i] == INVALID_HANDLE ||
                                g_ultraBiasSlowHandle[i] == INVALID_HANDLE)) reinit = true;

      if(!reinit) continue;
      if(InpDebug) PrintFormat("[HANDLE_REINIT] sym=%s — reinitialising invalid handles", sym);

      int atrPer = GetCurrentATRPeriod();
      if(needEMA && g_emaHandle[i] == INVALID_HANDLE)
         g_emaHandle[i] = iMA(sym, InpEntryTF, InpEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
      if(g_atrHandle[i] == INVALID_HANDLE)
         g_atrHandle[i] = iATR(sym, InpEntryTF, atrPer);
      if(InpUseVolRegime && g_atrVolHandle[i] == INVALID_HANDLE)
         g_atrVolHandle[i] = iATR(sym, InpVolRegimeTF, atrPer);
      if(InpUseADXFilter)
      {
         if(g_adxHandle[i] == INVALID_HANDLE)
            g_adxHandle[i] = iADX(sym, InpConfirmTF, InpADX_Period);
         if(g_adxEntryHandle[i] == INVALID_HANDLE)
            g_adxEntryHandle[i] = iADX(sym, InpEntryTF, InpADX_Period);
      }
      if(InpUseHTFBias)
      {
         if(g_biasFastHandle[i] == INVALID_HANDLE)
            g_biasFastHandle[i] = iMA(sym, InpBiasTF, InpBiasEMAFast, 0, MODE_EMA, PRICE_CLOSE);
         if(g_biasSlowHandle[i] == INVALID_HANDLE)
            g_biasSlowHandle[i] = iMA(sym, InpBiasTF, InpBiasEMASlow, 0, MODE_EMA, PRICE_CLOSE);
      }
      if(InpUseDivergenceFilter && g_rsiHandle[i] == INVALID_HANDLE)
         g_rsiHandle[i] = iRSI(sym, InpEntryTF, InpRSI_Period, PRICE_CLOSE);
      if(InpUseUltraHTFBias)
      {
         if(g_ultraBiasFastHandle[i] == INVALID_HANDLE)
            g_ultraBiasFastHandle[i] = iMA(sym, InpUltraBiasTF, InpUltraBiasEMAFast, 0, MODE_EMA, PRICE_CLOSE);
         if(g_ultraBiasSlowHandle[i] == INVALID_HANDLE)
            g_ultraBiasSlowHandle[i] = iMA(sym, InpUltraBiasTF, InpUltraBiasEMASlow, 0, MODE_EMA, PRICE_CLOSE);
      }
   }
}

// -----------------------------------------
// Bar-based SL cooldown (P3-10)
// -----------------------------------------
void PostSL_CooldownBars_Trigger(const int symIdx)
{
   if(!InpPostSL_CooldownBars_Enable) return;
   if(symIdx < 0 || symIdx >= g_symCount) return;
   // Capture current bar open time
   datetime curBar[1];
   if(CopyTime(g_syms[symIdx], InpEntryTF, 0, 1, curBar) == 1)
      g_slCooldownBarTime[symIdx] = curBar[0];
   g_slCooldownBarsLeft[symIdx] = MathMax(1, InpPostSL_CooldownBars);
}

bool PostSL_CooldownBars_IsActive(const int symIdx, const string sym)
{
   if(!InpPostSL_CooldownBars_Enable) return false;
   if(symIdx < 0 || symIdx >= g_symCount) return false;
   if(g_slCooldownBarsLeft[symIdx] <= 0) return false;

   datetime curBar[1];
   if(CopyTime(sym, InpEntryTF, 0, 1, curBar) != 1) return true; // can't check -> stay blocked
   if(curBar[0] != g_slCooldownBarTime[symIdx])
   {
      g_slCooldownBarsLeft[symIdx]--;
      g_slCooldownBarTime[symIdx] = curBar[0];
      if(g_slCooldownBarsLeft[symIdx] <= 0) return false;
   }
   return true;
}

// extracted to MSPB_EA_Risk.mqh

// -----------------------------------------
// v9: Correlation guard / HTF bias / Volatility regime
// -----------------------------------------
bool IsFXLikeSymbol(const string sym)
{
   // "FX-like" here means the symbol has usable currency metadata.
   // Many non-FX instruments (stocks/indices/CFDs) may have base==profit currency (e.g., USD/USD),
   // but we still treat them as eligible for correlation guard when currencies are defined.
   string base=SymbolInfoString(sym, SYMBOL_CURRENCY_BASE);
   string prof=SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);
   if(StringLen(base)!=3 || StringLen(prof)!=3) return false;
   if(base=="" || prof=="") return false;
   return true;
}


// --- Correlation cache (per TF bar) to avoid repeated CopyClose() calls ---------------
datetime g_corrCacheBar=0;
bool     g_corrCacheReady=false;
int      g_corrCacheBars=0;
double   g_corrCacheMat[];   // flat [n*n]
uchar    g_corrCacheOk[];    // flat [n*n], 1 => ok
double   g_corrCacheCloses[];// flat [n*nBars]
int      g_corrCacheGot[64];

datetime CorrCache_GetBarTime()
{
   datetime t[1];
   datetime best=0;
   // Use the most recent bar time across all symbols on CorrTF.
   // This avoids stale correlation cache when the first symbol has no new bars (e.g. stocks outside trading hours).
   for(int i=0;i<g_symCount;i++)
   {
      if(CopyTime(g_syms[i], InpCorrTF, 0, 1, t)==1)
      {
         if(t[0] > best) best = t[0];
      }
   }
   return best;
}

int CorrCache_Index(const string sym)
{
   for(int i=0;i<g_symCount;i++)
      if(g_syms[i]==sym) return i;
   return -1;
}

double CorrCache_ComputePair(const int ia, const int ib, bool &ok)
{
   ok=false;
   if(ia<0 || ib<0) return 0.0;

   int nBars=g_corrCacheBars;
   if(nBars<31) return 0.0;

   int ga=g_corrCacheGot[ia];
   int gb=g_corrCacheGot[ib];
   int n=MathMin(ga, gb);
   if(n<31) return 0.0;

   int m=n-1;
   double sumA=0.0, sumB=0.0;
   int used=0;

   int baseA = ia*nBars;
   int baseB = ib*nBars;

   for(int i=0;i<m;i++)
   {
      double a0=g_corrCacheCloses[baseA+i];
      double a1=g_corrCacheCloses[baseA+i+1];
      double b0=g_corrCacheCloses[baseB+i];
      double b1=g_corrCacheCloses[baseB+i+1];
      if(a0<=0.0 || a1<=0.0 || b0<=0.0 || b1<=0.0) continue;
      double ra=MathLog(a0/a1);
      double rb=MathLog(b0/b1);
      sumA += ra;
      sumB += rb;
      used++;
   }
   if(used<30) return 0.0;

   double meanA=sumA/used;
   double meanB=sumB/used;
   double sxx=0.0, syy=0.0, sxy=0.0;

   for(int i=0;i<m;i++)
   {
      double a0=g_corrCacheCloses[baseA+i];
      double a1=g_corrCacheCloses[baseA+i+1];
      double b0=g_corrCacheCloses[baseB+i];
      double b1=g_corrCacheCloses[baseB+i+1];
      if(a0<=0.0 || a1<=0.0 || b0<=0.0 || b1<=0.0) continue;
      double ra=MathLog(a0/a1) - meanA;
      double rb=MathLog(b0/b1) - meanB;
      sxx += ra*ra;
      syy += rb*rb;
      sxy += ra*rb;
   }
   if(sxx<=1e-12 || syy<=1e-12) return 0.0;

   ok=true;
   return sxy/MathSqrt(sxx*syy);
}

void CorrCache_UpdateIfNeeded()
{
   if(!InpUseCorrelationGuard) { g_corrCacheReady=false; return; }
   if(g_symCount<=1) { g_corrCacheReady=false; return; }

   datetime barTime = CorrCache_GetBarTime();
   if(barTime<=0) { g_corrCacheReady=false; return; }

   int nBars = MathMax(31, InpCorrLookbackBars);

   if(g_corrCacheReady && g_corrCacheBar==barTime && g_corrCacheBars==nBars)
      return;

   g_corrCacheBar=barTime;
   g_corrCacheBars=nBars;

   int n=g_symCount;
   ArrayResize(g_corrCacheCloses, n*nBars);
   ArrayResize(g_corrCacheMat, n*n);
   ArrayResize(g_corrCacheOk, n*n);

   // Load closes once per symbol
   for(int i=0;i<n;i++)
   {
      g_corrCacheGot[i]=0;
      double c[];
      ArrayResize(c,nBars);
      ArraySetAsSeries(c,true);
      int got=CopyClose(g_syms[i], InpCorrTF, 0, nBars, c);
      if(got<0) got=0;
      if(got>nBars) got=nBars;
      g_corrCacheGot[i]=got;

      int base=i*nBars;
      for(int k=0;k<nBars;k++)
         g_corrCacheCloses[base+k] = (k<got ? c[k] : 0.0);
   }

   // Compute matrix
   for(int i=0;i<n;i++)
   {
      for(int j=0;j<n;j++)
      {
         int idx=i*n+j;
         g_corrCacheMat[idx]=0.0;
         g_corrCacheOk[idx]=0;
      }
   }

   for(int i=0;i<n;i++)
   {
      int idxii=i*n+i;
      g_corrCacheMat[idxii]=1.0;
      g_corrCacheOk[idxii]=1;

      for(int j=i+1;j<n;j++)
      {
         bool ok=false;
         double corr=CorrCache_ComputePair(i,j,ok);
         int idxij=i*n+j;
         int idxji=j*n+i;
         g_corrCacheMat[idxij]=corr;
         g_corrCacheMat[idxji]=corr;
         g_corrCacheOk[idxij]=(uchar)(ok?1:0);
         g_corrCacheOk[idxji]=(uchar)(ok?1:0);
      }
   }

   g_corrCacheReady=true;
}

bool CorrCache_Get(const string a, const string b, double &corrOut, bool &okOut)
{
   corrOut=0.0; okOut=false;
   if(!g_corrCacheReady) return false;
   int ia=CorrCache_Index(a);
   int ib=CorrCache_Index(b);
   if(ia<0 || ib<0) return false;
   int n=g_symCount;
   int idx=ia*n+ib;
   corrOut=g_corrCacheMat[idx];
   okOut=(g_corrCacheOk[idx]>0);
   return true;
}
// -------------------------------------------------------------------

double CorrSymbols(const string a, const string b, const ENUM_TIMEFRAMES tf, const int lookbackBars, bool &ok)
{
   ok=false;
   int nBars = MathMax(30, lookbackBars);
   double ca[]; double cb[];
   ArraySetAsSeries(ca,true);
   ArraySetAsSeries(cb,true);
   int ga=CopyClose(a, tf, 0, nBars, ca);
   int gb=CopyClose(b, tf, 0, nBars, cb);
   int n=MathMin(ga, gb);
   if(n < 31) return 0.0;
   int m = n-1;
   double sumA=0.0, sumB=0.0;
   int used=0;
   for(int i=0;i<m;i++)
   {
      double a0=ca[i]; double a1=ca[i+1];
      double b0=cb[i]; double b1=cb[i+1];
      if(a0<=0.0 || a1<=0.0 || b0<=0.0 || b1<=0.0) continue;
      double ra=MathLog(a0/a1);
      double rb=MathLog(b0/b1);
      sumA += ra;
      sumB += rb;
      used++;
   }
   if(used < 30) return 0.0;
   double meanA = sumA/used;
   double meanB = sumB/used;
   double sxx=0.0, syy=0.0, sxy=0.0;
   for(int i=0;i<m;i++)
   {
      double a0=ca[i]; double a1=ca[i+1];
      double b0=cb[i]; double b1=cb[i+1];
      if(a0<=0.0 || a1<=0.0 || b0<=0.0 || b1<=0.0) continue;
      double ra=MathLog(a0/a1) - meanA;
      double rb=MathLog(b0/b1) - meanB;
      sxx += ra*ra;
      syy += rb*rb;
      sxy += ra*rb;
   }
   if(sxx<=1e-12 || syy<=1e-12) return 0.0;
   ok=true;
   return sxy / MathSqrt(sxx*syy);
}

bool CorrelationAllowsEntry(const int symIdx,
                            const string sym,
                            const int newDir,
                            const double newLots,
                            string &detailOut)
{
   detailOut="";
   if(!InpUseCorrelationGuard) return true;
   if(newDir==0) return true;
   if(newLots<=0.0) return true;
   if(InpCorrFXLikeOnly && !IsFXLikeSymbol(sym)) return true;


   double sumWeightedLots = 0.0;
   string worstSym = "";
   double worstCorr = 0.0;
   double worstW = 0.0;
   double worstLots = 0.0;
   int    worstODir = 0;

   int total=PositionsTotal();
   for(int i=0;i<total;i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;

      string osym=PositionGetString(POSITION_SYMBOL);
      if(osym==sym) continue;
      if(InpCorrFXLikeOnly && !IsFXLikeSymbol(osym)) continue;

      long ptype = PositionGetInteger(POSITION_TYPE);
      int  oDir  = (ptype==POSITION_TYPE_BUY ? 1 : (ptype==POSITION_TYPE_SELL ? -1 : 0));
      if(oDir==0) continue;

      double oLots = PositionGetDouble(POSITION_VOLUME);
      if(oLots<=0.0) continue;

      bool ok=false;
      double corr=0.0;
      if(!CorrCache_Get(sym, osym, corr, ok))
         corr=CorrSymbols(sym, osym, InpCorrTF, InpCorrLookbackBars, ok);
      if(!ok) continue;
      if(MathAbs(corr) < InpCorrAbsThreshold) continue;

      // v10/v11: block only if this entry increases exposure (direction-aware).
      if(InpCorrSameExposureOnly)
      {
         int sign = (corr>=0.0 ? 1 : -1);
         int equiv = oDir * sign; // open position direction mapped into 'sym' direction
         if(equiv != newDir) continue; // exposure-reducing => ignore in exposure sum
      }

      double w = MathAbs(corr) * oLots;
      sumWeightedLots += w;

      if(w > worstW)
      {
         worstW = w;
         worstSym = osym;
         worstCorr = corr;
         worstLots = oLots;
         worstODir = oDir;
      }
   }

   if(sumWeightedLots <= 0.0) return true;

   // v20-D11: spread-prefer mode — allow entry if current symbol spread < worst correlated symbol spread
   if(InpCorrSpreadPrefer && worstSym != "")
   {
      MqlTick tickNew, tickWorst;
      bool gotNew   = SymbolInfoTick(sym,      tickNew);
      bool gotWorst = SymbolInfoTick(worstSym, tickWorst);
      if(gotNew && gotWorst)
      {
         double spreadNew   = SpreadPipsPrices(sym,      tickNew.bid,   tickNew.ask);
         double spreadWorst = SpreadPipsPrices(worstSym, tickWorst.bid, tickWorst.ask);
         if(spreadNew <= spreadWorst)
         {
            // Current symbol has equal or tighter spread — allow entry
            detailOut = StringFormat("corrSpreadPrefer|sym_spread=%.2f<=worst_spread=%.2f|worst=%s",
                                     spreadNew, spreadWorst, worstSym);
            return true;
         }
      }
   }

   // v11: weighted exposure mode (recommended)
   if(InpCorrUseWeightedExposure)
   {
      double totalEff = sumWeightedLots + newLots; // newLots ~ self-corr=1.0
      if(InpCorrMaxWeightedLots > 0.0 && totalEff > InpCorrMaxWeightedLots)
      {
         detailOut = StringFormat("corrW=%.2f|newLots=%.2f|sumW=%.2f|maxW=%.2f|worst=%s|worstCorr=%.2f|worstLots=%.2f|oDir=%s|newDir=%s",
                                  totalEff, newLots, sumWeightedLots, InpCorrMaxWeightedLots,
                                  worstSym, worstCorr, worstLots,
                                  (worstODir>0?"BUY":"SELL"), (newDir>0?"BUY":"SELL"));
         return false;
      }
      return true;
   }

   // legacy mode: any correlated position blocks
   detailOut = StringFormat("corr>=%.2f|with=%s|tf=%s|n=%d|oLots=%.2f|oDir=%s|newLots=%.2f|newDir=%s",
                            InpCorrAbsThreshold, worstSym, EnumToString(InpCorrTF), InpCorrLookbackBars,
                            worstLots, (worstODir>0?"BUY":"SELL"), newLots, (newDir>0?"BUY":"SELL"));
   return false;
}

int GetBiasDirCached(const int symIdx, const string sym, double &fastOut, double &slowOut)
{
   fastOut=0.0; slowOut=0.0;
   if(!InpUseHTFBias) return 0;
   if(symIdx<0 || symIdx>=g_symCount) return 0;

   datetime t[1];
   if(CopyTime(sym, InpBiasTF, 0, 1, t)!=1)
      return (InpBias_FailClosed ? 99 : 0);

   if(g_sym[symIdx].lastBiasBar==t[0])
      return g_sym[symIdx].biasDir;

   if(g_biasFastHandle[symIdx]==INVALID_HANDLE || g_biasSlowHandle[symIdx]==INVALID_HANDLE)
      return (InpBias_FailClosed ? 99 : 0);

   double f[]; double s[];
   ArrayResize(f,1);
   ArrayResize(s,1);
   ArraySetAsSeries(f,true);
   ArraySetAsSeries(s,true);
   if(CopyBuffer(g_biasFastHandle[symIdx],0,0,1,f)!=1 || CopyBuffer(g_biasSlowHandle[symIdx],0,0,1,s)!=1)
      return (InpBias_FailClosed ? 99 : 0);

   fastOut=f[0];
   slowOut=s[0];
   int dir=0;
   if(fastOut>slowOut) dir=1;
   else if(fastOut<slowOut) dir=-1;
   g_sym[symIdx].lastBiasBar=t[0];
   g_sym[symIdx].biasDir=dir;
   return dir;
}

bool VolRegime_Get(const int symIdx, const string sym, double &multOut, bool &blockOut, double &pctOut)
{
   multOut=1.0; blockOut=false; pctOut=50.0;
   if(!InpUseVolRegime) return true;
   if(symIdx<0 || symIdx>=g_symCount) return true;
   if(g_atrVolHandle[symIdx]==INVALID_HANDLE) return true;

   datetime t[1];
   if(CopyTime(sym, InpVolRegimeTF, 0, 1, t)!=1) return true;
   if(g_sym[symIdx].volValid && g_sym[symIdx].lastVolBar==t[0])
   {
      multOut=g_sym[symIdx].volMult;
      blockOut=g_sym[symIdx].volBlock;
      pctOut=g_sym[symIdx].volPct;
      return true;
   }

   int n=MathMax(50, InpVolRegimeLookbackBars);
   double atr[];
   ArraySetAsSeries(atr,true);
   int got=CopyBuffer(g_atrVolHandle[symIdx],0,0,n,atr);
   if(got<20)
   {
      // not enough data => neutral
      g_sym[symIdx].lastVolBar=t[0];
      g_sym[symIdx].volMult=1.0;
      g_sym[symIdx].volBlock=false;
      g_sym[symIdx].volPct=50.0;
      g_sym[symIdx].volValid=true;
      multOut=1.0; blockOut=false; pctOut=50.0;
      return true;
   }

   // current ATR in pips based on symbol pip size
   double pip=PipSize(sym);
   if(pip<=0.0 || atr[0]<=0.0)
   {
      g_sym[symIdx].lastVolBar=t[0];
      g_sym[symIdx].volMult=1.0;
      g_sym[symIdx].volBlock=false;
      g_sym[symIdx].volPct=50.0;
      g_sym[symIdx].volValid=true;
      multOut=1.0; blockOut=false; pctOut=50.0;
      return true;
   }

   double curPips = atr[0]/pip;
   int denom=0, lessEq=0;
   for(int i=1;i<got;i++)
   {
      if(atr[i]<=0.0) continue;
      double p = atr[i]/pip;
      denom++;
      if(p <= curPips) lessEq++;
   }
   if(denom<=10) pctOut=50.0;
   else pctOut = (double)lessEq/(double)denom*100.0;

   multOut=1.0;
   blockOut=false;
   if(pctOut <= InpVolLowPct)
   {
      blockOut = InpVolLowBlockEntries;
      multOut  = 1.0;
   }
   else if(pctOut >= InpVolHighPct)
   {
      multOut = MathMax(0.0, InpVolHighRiskMult);
      blockOut = false;
   }

   g_sym[symIdx].lastVolBar=t[0];
   g_sym[symIdx].volMult=multOut;
   g_sym[symIdx].volBlock=blockOut;
   g_sym[symIdx].volPct=pctOut;
   g_sym[symIdx].volValid=true;
   return true;
}

// extracted to MSPB_EA_Risk.mqh

// -----------------------------------------
// Indicators per symbol
// -----------------------------------------
int g_emaHandle[64];
int g_atrHandle[64];
int g_adxHandle[64];           // ADX on confirm TF (trend)
int g_adxEntryHandle[64];      // ADX on entry TF (entry filter)
int g_biasFastHandle[64];      // v9: HTF bias EMA fast
int g_biasSlowHandle[64];      // v9: HTF bias EMA slow
int g_atrVolHandle[64];        // v9: volatility regime ATR on InpVolRegimeTF
int g_rsiHandle[64];           // P2-4: RSI for divergence filter
int g_ultraBiasFastHandle[64]; // P2-7: ultra-HTF EMA fast
int g_ultraBiasSlowHandle[64]; // P2-7: ultra-HTF EMA slow

// --- Weekly loss limit tracking (P3-9)
double   g_weekEqStart   = 0.0;   // equity recorded at start of current trading week
datetime g_weekStart     = 0;     // broker datetime of Monday 00:00 of current week

// --- Bar-based SL cooldown per symbol (P3-10)
datetime g_slCooldownBarTime[64]; // bar open-time when SL hit was recorded
int      g_slCooldownBarsLeft[64]; // bars remaining in cooldown (counts down on new bar)

// --- Slippage stats for OnTester score (P5-16)
double g_totalSlippagePips = 0.0;
int    g_slippageCount     = 0;

// --- Deal deduplication: ring buffer of recently processed deal tickets (P1-3)
ulong g_processedDeals[512];
int   g_processedDealsN = 0;

// --- OnTradeTransaction: flag that HistorySelectByPosition succeeded (P1-1)
bool g_dealQHistoryFresh   = false;
datetime g_dealQHistoryFreshTime = 0;


// Copy buffer helper
bool CopyLast(const int handle, const int buffer, const int start, const int count, double &out[])
{
   ArraySetAsSeries(out,true);
   int got=CopyBuffer(handle, buffer, start, count, out);
   return (got==count);
}

bool CopyRatesLast(const string sym, const ENUM_TIMEFRAMES tf, const int start, const int count, MqlRates &out[])
{
   ArraySetAsSeries(out,true);
   int got=CopyRates(sym, tf, start, count, out);
   return (got==count);
}

// -----------------------------------------
// extracted to MSPB_EA_ExecQual.mqh


bool IsNewBar(const int symIdx, const string sym, const ENUM_TIMEFRAMES tf)
{
   datetime t[1];
   if(CopyTime(sym, tf, 0, 1, t)!=1) return false;
   if(g_sym[symIdx].lastBar==0)
   {
      g_sym[symIdx].lastBar=t[0];
      return false;
   }
   if(t[0]!=g_sym[symIdx].lastBar)
   {
      g_sym[symIdx].lastBar=t[0];
      return true;
   }
   return false;
}

bool IsNewConfirmBar(const int symIdx, const string sym)
{
   datetime t[1];
   if(CopyTime(sym, InpConfirmTF, 0, 1, t)!=1) return false;
   if(g_sym[symIdx].lastConfirmBar==0)
   {
      g_sym[symIdx].lastConfirmBar=t[0];
      return false;
   }
   if(t[0]!=g_sym[symIdx].lastConfirmBar)
   {
      g_sym[symIdx].lastConfirmBar=t[0];
      return true;
   }
   return false;
}

// -----------------------------------------
// Session / Spread checks
// -----------------------------------------
bool SessionAllows()
{
   if(!InpUseSessions) return true;
   datetime now=TimeCurrent();
   MqlDateTime dt; TimeToStruct(now, dt);
   int h=dt.hour;

   bool london=(h>=InpLondonStartHour && h<InpLondonEndHour);
   bool ny=(h>=InpNYStartHour && h<InpNYEndHour);
   return (london || ny);
}

bool SpreadAllows(const string sym)
{
   double sp=SpreadPips(sym);
   double maxsp=Sym_MaxSpreadPips(sym);
   return(sp<=maxsp);
}


// -----------------------------------------
// Positions count
// -----------------------------------------
int CountOpenPositionsOurMagic(const string sym="")
{
   int total=PositionsTotal();
   int cnt=0;
   for(int i=0;i<total;i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0)
      {
         if(InpDebug) Print("WARN: PositionGetTicket returned 0");
         continue;
      }
      if(!PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(sym!="" && PositionGetString(POSITION_SYMBOL)!=sym) continue;
      cnt++;
   }
   return cnt;
}

// NEW: count per-symbol and total in one pass (avoids double scanning + consistency issues)
void CountOpenPositionsOurMagicBoth(const string sym, int &cntSym, int &cntTotal)
{
   cntSym=0; cntTotal=0;
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;

      cntTotal++;
      if(sym!="" && PositionGetString(POSITION_SYMBOL)==sym)
         cntSym++;
   }
}


// -----------------------------------------
// Broker stop/freeze checks
// -----------------------------------------
bool CanModifyStopsNow(const string sym, const long type, const double newSL)
{
   double pt=SymbolInfoDouble(sym, SYMBOL_POINT);
   double stops=SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL)*pt;
   double freeze=SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL)*pt;

   double bid=SymbolInfoDouble(sym, SYMBOL_BID);
   double ask=SymbolInfoDouble(sym, SYMBOL_ASK);
   double price = (type==POSITION_TYPE_BUY ? bid : ask);

   if(stops>0 && MathAbs(price-newSL) < stops) return false;
   if(freeze>0 && MathAbs(price-newSL) < freeze) return false;
   return true;
}

double ClampSLToStopsLevel(const string sym, const long type, const double price, double sl)
{
   double pt=SymbolInfoDouble(sym, SYMBOL_POINT);
   double stops=SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL)*pt;
   if(stops<=0) return sl;

   if(type==POSITION_TYPE_BUY)
   {
      if((price - sl) < stops) sl = price - stops;
   }
   else
   {
      if((sl - price) < stops) sl = price + stops;
   }
   return sl;
}

// -----------------------------------------
// Equity regime filter (simple drawdown in R over last N deals)
// -----------------------------------------
double g_eqPeak=0.0;
double g_eqTrough=0.0;

// extracted to MSPB_EA_Risk.mqh

// -----------------------------------------
// Deal queue (track exits precisely)
// -----------------------------------------
bool DealQ_IsEmpty(){ return g_dealQHead==g_dealQTail; }
bool DealQ_Push(const ulong dealTicket)
{
   int next=(g_dealQTail+1)%4096;
   if(next==g_dealQHead) return false; // full
   g_dealQueueTickets[g_dealQTail]=dealTicket;
   g_dealQTail=next;
   return true;
}
bool DealQ_Pop(ulong &dealTicket)
{
   if(DealQ_IsEmpty()) return false;
   dealTicket=g_dealQueueTickets[g_dealQHead];
   g_dealQHead=(g_dealQHead+1)%4096;
   return true;
}

void ProcessDealQueue()
{
   if(DealQ_IsEmpty()) return;

   datetime now=TimeCurrent();

   // time-based backoff to avoid busy-loop when history is not ready
   if(g_dealQBackoffSec>0 && g_dealQNextTry>0 && now < g_dealQNextTry)
      return;

   static datetime lastHistorySelect=0;

   // P1-1/P1-3: use pre-selected history from OnTradeTransaction when fresh (< 5 sec old)
   bool usePreselected = (g_dealQHistoryFresh && (now - g_dealQHistoryFreshTime) < 5);
   if(!usePreselected)
      g_dealQHistoryFresh = false; // stale

   if(!usePreselected)
   {
      // Only do HistorySelect occasionally for perf; expand window on backoff
      if(lastHistorySelect==0 || (now - lastHistorySelect) >= 5)
      {
         int lookbackDays = (g_dealQBackoffSec > 0) ? 14 : 7;
         datetime from = now - ((datetime)lookbackDays * 86400);

         if(!HistorySelect(from, now))
         {
            g_dealQBackoffSec = MathMin(60, (g_dealQBackoffSec<=0 ? 1 : g_dealQBackoffSec*2));
            g_dealQNextTry = now + g_dealQBackoffSec;
            return;
         }
         lastHistorySelect = now;
      }
   }

   int processed=0;

   for(int k=0;k<256;k++)
   {
      ulong dealTicket;
      if(!DealQ_Pop(dealTicket)) break;

      // P1-3: skip already-processed deals (deduplication)
      if(!DealSeen_Add(dealTicket)) { processed++; continue; }

      if(!HistoryDealSelect(dealTicket))
      {
         // Not available yet -> push back + backoff
         if(!DealQ_Push(dealTicket))
         {
            PrintFormat("DEALQ_OVERFLOW: cannot requeue deal %I64d", (long)dealTicket);
            FailSafe_Trip("DEALQ_OVERFLOW");
         }
         g_dealQBackoffSec = MathMin(60, (g_dealQBackoffSec<=0 ? 1 : g_dealQBackoffSec*2));
         g_dealQNextTry = now + g_dealQBackoffSec;
         break;
      }

      string sym=HistoryDealGetString(dealTicket, DEAL_SYMBOL);
      long magic=HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
      if(magic!=InpMagic) continue;

      long entry=HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      double vol=HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
      long posId=HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);

      double pSum = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                  + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION)
                  + HistoryDealGetDouble(dealTicket, DEAL_SWAP);
      long reason = HistoryDealGetInteger(dealTicket, DEAL_REASON);
      double posProfit=0.0; long closeReason=0;

      // Update close-tracker for *positions* (robust against multi-fill exits) + collect net P/L
      double dealPrice=HistoryDealGetDouble(dealTicket, DEAL_PRICE);
      // NOTE: Some older MT5 builds don't support DEAL_SL/DEAL_TP deal properties.
      // We recover entry SL/TP from the originating ORDER instead (more compatible).
      double dealSL=0.0;
      ulong orderTicket=(ulong)HistoryDealGetInteger(dealTicket, DEAL_ORDER);
      if(orderTicket>0 && HistoryOrderSelect(orderTicket))
         dealSL=HistoryOrderGetDouble(orderTicket, ORDER_SL);

      double posRiskMoney=0.0;
      bool posClosedNow = PosTrackUpdate(sym, posId,(int)entry,vol,pSum,reason,dealPrice,dealSL,posProfit,closeReason,posRiskMoney);

      // We only log/export for exit-side deals.
      if(!(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY || entry==DEAL_ENTRY_INOUT))
      {
         // Rare edge-case: position closure caused by a non-exit deal (shouldn't normally happen).
         // Count it for proposal triggers to avoid undercounting.
         if(posClosedNow)
         {
            g_closedTradesSinceProposal++;
            CheckTradeCountProposal();
            Audit_Log("POS_CLOSED_NONEXIT_DEAL",
                      StringFormat("sym=%s|posId=%I64d|deal=%I64d|entry=%d", sym, posId, (long)dealTicket, (int)entry),
                      false);
            Cooldown_Apply(sym, now, closeReason, posProfit, posRiskMoney);
         }
         continue;
      }

      double profit=HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      double price=HistoryDealGetDouble(dealTicket, DEAL_PRICE);
      string comment=HistoryDealGetString(dealTicket, DEAL_COMMENT);
      // reason already fetched above
      // wasSL no longer used (v11)


      // Optional Telegram exit-deal notification (can be noisy)
      if(InpEnableTelegram && InpTGNotifyExitDeals)
      {
         int d=(int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         TelegramSendMessage(StringFormat("EXIT %s | deal=%I64d | profit=%.2f | price=%s | %s",
                                          sym, (long)dealTicket, profit, DoubleToString(price,d), Shorten(comment,40)));
      }

      if(InpEnableMLExport)
      {
         // log posId as pos_id, keep dealTicket in comment
         ML_WriteRowV2("exit", NowStr(), sym, "", "", price, 0,0, 0,0,
                      0,0,0,0,0,
                      "", "",
                      (long)posId, "EXIT", 0, profit, 0,
                      0, "deal="+(string)dealTicket+"|"+Shorten(comment,40), g_mlSchema);
      }
      processed++;

      if(posClosedNow)
      {
         g_closedTradesSinceProposal++;
            Cooldown_Apply(sym, now, closeReason, posProfit, posRiskMoney);
         CheckTradeCountProposal();

         // v20-B6/B7: record trade P&L for Kelly & auto-disable tracking
         int symIdx2 = SymIndexByNameLoose(sym);
         if(symIdx2 >= 0)
         {
            AutoDisable_RecordTrade(symIdx2, profit);
            AutoDisable_MaybeDisable(symIdx2, sym);
            // Reset pyramid count when a full position chain closes
            if(g_sym[symIdx2].pyramidCount > 0)
               g_sym[symIdx2].pyramidCount = 0;
            // Reset ladder state
            if(g_sym[symIdx2].ladderPosId == (long)posId)
            {
               g_sym[symIdx2].ladderPosId   = 0;
               g_sym[symIdx2].ladderR1Done  = false;
               g_sym[symIdx2].ladderR2Done  = false;
               g_sym[symIdx2].ladderInitRisk = 0.0;
               g_sym[symIdx2].ladderVolInit  = 0.0;
            }
         }
      }

      g_dealQLastProgress=now;
   }

   if(processed>0)
   {
      // success -> reset backoff
      g_dealQBackoffSec=0;
      g_dealQNextTry=0;
      g_dealQLastProgress=now;
   }
}

// -----------------------------------------
// -----------------------------------------
// Auto proposal based on closed trade count
// -----------------------------------------

// --- Closed trade reconstruction + advanced metrics (RR, PF, DD, MAE/MFE)
struct ClosedTradeRec
{
   long     posId;
   string   sym;
   datetime openTime;
   datetime closeTime;
   int      dir;        //  1=buy, -1=sell
   double   volume;
   double   openPrice;
   double   closePrice;
   double   slPrice;
   double   tpPrice;
   double   profit;     // deal profit + commission + swap (summed)
   double   riskMoney;  // money risk to initial SL (approx)
   double   profitR;    // profit/riskMoney
   double   slPips;
   double   maePips;
   double   mfePips;
};

struct SymPerf
{
   string sym;
   int    trades;
   int    wins;
   int    losses;
   double grossProfit;
   double grossLoss;
   double net;
   double maxDD;
   double sumR;
   int    countR;
   double sumMAE;
   double sumMFE;
   int    countMAEMFE;
   double sumMAE_R;
   double sumMFE_R;
   int    countMAE_R;
   double maxMAE;
   double maxMFE;
   double cum;
   double peak;
};

// --- MAE/MFE cache (NEW)
struct MaeMfeCacheItem
{
   long   posId;
   double mae;
   double mfe;
};
MaeMfeCacheItem g_maeCache[512];
int g_maeCacheN=0;
int g_maeCachePtr=0;

bool MaeMfeCache_Get(const long posId, double &mae, double &mfe)
{
   for(int i=0;i<g_maeCacheN;i++)
   {
      if(g_maeCache[i].posId==posId)
      {
         mae=g_maeCache[i].mae;
         mfe=g_maeCache[i].mfe;
         return true;
      }
   }
   return false;
}
void MaeMfeCache_Put(const long posId, const double mae, const double mfe)
{
   if(posId<=0) return;

   for(int i=0;i<g_maeCacheN;i++)
   {
      if(g_maeCache[i].posId==posId)
      {
         g_maeCache[i].mae=mae;
         g_maeCache[i].mfe=mfe;
         return;
      }
   }

   if(g_maeCacheN < ArraySize(g_maeCache))
   {
      g_maeCache[g_maeCacheN].posId=posId;
      g_maeCache[g_maeCacheN].mae=mae;
      g_maeCache[g_maeCacheN].mfe=mfe;
      g_maeCacheN++;
      return;
   }

   g_maeCache[g_maeCachePtr].posId=posId;
   g_maeCache[g_maeCachePtr].mae=mae;
   g_maeCache[g_maeCachePtr].mfe=mfe;
   g_maeCachePtr = (g_maeCachePtr+1) % ArraySize(g_maeCache);
}

double SafeDiv(const double a, const double b)
{
   if(MathAbs(b) <= 1e-12) return 0.0;
   return a / b;
}

// =============================================================
// v20.0 Helper functions
// =============================================================

// ----- A1: ML Entry Gate ----
double MLGate_Sigmoid(const double x)
{
   double cx = x;
   if(cx >  500.0) cx =  500.0;
   if(cx < -500.0) cx = -500.0;
   return 1.0 / (1.0 + MathExp(-cx));
}

// Load ml_entry_threshold.json into global arrays.
// JSON is simple enough to parse with string ops (no full JSON library needed).
void MLGate_Load()
{
   if(!InpUseMLEntryGate) return;
   int flags = FILE_READ | FILE_TXT;
   if(InpMLGate_UseCommonFolder) flags |= FILE_COMMON;
   int h = FileOpen(InpMLGateFile, flags);
   if(h == INVALID_HANDLE)
   {
      if(InpDebug) PrintFormat("[MLGate] Cannot open %s — gate disabled", InpMLGateFile);
      g_mlGateLoaded = false;
      return;
   }

   string json = "";
   while(!FileIsEnding(h))
      json += FileReadString(h);
   FileClose(h);

   // Extract threshold
   string threshKey = "\"threshold\":";
   int pos = StringFind(json, threshKey);
   if(pos >= 0)
   {
      int start = pos + StringLen(threshKey);
      while(start < StringLen(json) && (StringGetCharacter(json, start)==' ' || StringGetCharacter(json, start)=='\n')) start++;
      int end = start;
      while(end < StringLen(json) && StringGetCharacter(json, end) != ',' && StringGetCharacter(json, end) != '\n' && StringGetCharacter(json, end) != '}') end++;
      g_mlGateThreshold = StringToDouble(StringSubstr(json, start, end - start));
   }

   // Feature order: atr_pips, adx_trend, adx_entry, spread_pips, body_pips, r_mult
   string featNames[] = {"atr_pips", "adx_trend", "adx_entry", "spread_pips", "body_pips", "r_mult"};
   for(int fi = 0; fi < ML_GATE_NFEAT; fi++)
   {
      // Extract weight
      string wKey = "\"" + featNames[fi] + "\":";
      // Search in feature_weights section
      int wStart = StringFind(json, "\"feature_weights\"");
      int wPos = (wStart >= 0) ? StringFind(json, wKey, wStart) : -1;
      if(wPos >= 0)
      {
         int vs = wPos + StringLen(wKey);
         while(vs < StringLen(json) && (StringGetCharacter(json, vs)==' ' || StringGetCharacter(json, vs)=='\n')) vs++;
         int ve = vs;
         while(ve < StringLen(json) && StringGetCharacter(json, ve) != ',' && StringGetCharacter(json, ve) != '\n' && StringGetCharacter(json, ve) != '}') ve++;
         g_mlGateWeights[fi] = StringToDouble(StringSubstr(json, vs, ve - vs));
      }
      else g_mlGateWeights[fi] = 1.0 / ML_GATE_NFEAT;

      // Extract mean
      int statsStart = StringFind(json, "\"feature_stats\"");
      int featSection = (statsStart >= 0) ? StringFind(json, "\"" + featNames[fi] + "\"", statsStart) : -1;
      if(featSection >= 0)
      {
         string meanKey = "\"mean\":";
         int mPos = StringFind(json, meanKey, featSection);
         int stdPos2 = StringFind(json, "}", featSection);
         if(mPos >= 0 && (stdPos2 < 0 || mPos < stdPos2))
         {
            int ms = mPos + StringLen(meanKey);
            while(ms < StringLen(json) && (StringGetCharacter(json, ms)==' ')) ms++;
            int me = ms;
            while(me < StringLen(json) && StringGetCharacter(json, me) != ',' && StringGetCharacter(json, me) != '}') me++;
            g_mlGateMeans[fi] = StringToDouble(StringSubstr(json, ms, me - ms));
         }
         string stdKey = "\"std\":";
         int sPos = (featSection >= 0) ? StringFind(json, stdKey, featSection) : -1;
         if(sPos >= 0 && (stdPos2 < 0 || sPos < stdPos2))
         {
            int ss = sPos + StringLen(stdKey);
            while(ss < StringLen(json) && (StringGetCharacter(json, ss)==' ')) ss++;
            int se = ss;
            while(se < StringLen(json) && StringGetCharacter(json, se) != ',' && StringGetCharacter(json, se) != '}') se++;
            double std = StringToDouble(StringSubstr(json, ss, se - ss));
            g_mlGateStds[fi] = (std > 1e-9 ? std : 1.0);
         }
         else g_mlGateStds[fi] = 1.0;
      }
      else
      {
         g_mlGateMeans[fi] = 0.0;
         g_mlGateStds[fi]  = 1.0;
      }
   }

   g_mlGateLoaded = true;
   g_mlGateLastLoad = TimeCurrent();
   if(InpDebug)
      PrintFormat("[MLGate] Loaded: threshold=%.4f", g_mlGateThreshold);
}

double MLGate_Score(const double atrPips, const double adxTrend, const double adxEntry,
                    const double spreadPips, const double bodyPips, const double rMult)
{
   if(!g_mlGateLoaded) return 1.0; // pass-through if not loaded
   double feats[] = {atrPips, adxTrend, adxEntry, spreadPips, bodyPips, rMult};
   double z = 0.0;
   for(int fi = 0; fi < ML_GATE_NFEAT; fi++)
   {
      double w    = g_mlGateWeights[fi];
      double mean = g_mlGateMeans[fi];
      double std  = (g_mlGateStds[fi] > 1e-9 ? g_mlGateStds[fi] : 1.0);
      z += w * (feats[fi] - mean) / std;
   }
   return MLGate_Sigmoid(z);
}

// ----- B6: Auto-disable per symbol -----
void AutoDisable_RecordTrade(const int symIdx, const double pnl)
{
   if(!InpAutoDisable_Enable || symIdx < 0 || symIdx >= g_symCount) return;
   int cap = ArraySize(g_sym[symIdx].kellyPnL);
   g_sym[symIdx].kellyPnL[g_sym[symIdx].kellyPnLHead] = pnl;
   g_sym[symIdx].kellyPnLHead = (g_sym[symIdx].kellyPnLHead + 1) % cap;
   if(g_sym[symIdx].kellyPnLN < cap) g_sym[symIdx].kellyPnLN++;
}

bool AutoDisable_IsBlocked(const int symIdx)
{
   if(!InpAutoDisable_Enable || symIdx < 0) return false;
   if(g_sym[symIdx].autoDisabledUntil > TimeCurrent()) return true;
   return false;
}

void AutoDisable_MaybeDisable(const int symIdx, const string sym)
{
   if(!InpAutoDisable_Enable || symIdx < 0 || symIdx >= g_symCount) return;
   int n = MathMin(g_sym[symIdx].kellyPnLN, InpAutoDisable_Lookback);
   if(n < MathMax(5, InpAutoDisable_Lookback / 2)) return; // need enough data

   int cap = ArraySize(g_sym[symIdx].kellyPnL);
   int wins=0; double sumWin=0, sumLoss=0;
   for(int i=0; i<n; i++)
   {
      int idx2 = (g_sym[symIdx].kellyPnLHead - 1 - i + cap) % cap;
      double p = g_sym[symIdx].kellyPnL[idx2];
      if(p > 0) { wins++; sumWin += p; }
      else       sumLoss += MathAbs(p);
   }
   double lossCount = n - wins;
   double winRate   = (n > 0 ? (double)wins / n : 0.0);
   double avgWin    = (wins > 0 ? sumWin / wins : 0.0);
   double avgLoss   = (lossCount > 0 ? sumLoss / lossCount : 0.0);
   double expectancy = winRate * avgWin - (1.0 - winRate) * avgLoss;

   if(expectancy < 0.0)
   {
      // Disable until next Monday 00:00
      datetime now = TimeCurrent();
      MqlDateTime mdt; TimeToStruct(now, mdt);
      int dow = mdt.day_of_week;
      if(dow == 0) dow = 7;
      int daysToMon = (8 - dow) % 7;
      if(daysToMon == 0) daysToMon = 7;
      datetime monNext = now - (datetime)(mdt.hour*3600 + mdt.min*60 + mdt.sec)
                             + (datetime)(daysToMon * 86400);
      g_sym[symIdx].autoDisabledUntil = monNext;
      if(InpDebug)
         PrintFormat("[AutoDisable] %s disabled until %s | exp=%.4f wr=%.2f avgW=%.2f avgL=%.2f n=%d",
                     sym, TimeToString(monNext, TIME_DATE|TIME_MINUTES),
                     expectancy, winRate, avgWin, avgLoss, n);
   }
}

// ----- B7: Kelly sizing -----
double Kelly_GetMult(const int symIdx)
{
   if(!InpUseKellyScaling || symIdx < 0) return 1.0;
   int n = MathMin(g_sym[symIdx].kellyPnLN, InpKelly_Lookback);
   if(n < MathMax(5, InpKelly_Lookback / 2)) return 1.0; // not enough data

   int cap = ArraySize(g_sym[symIdx].kellyPnL);
   int wins=0; double sumWin=0, sumLoss=0;
   for(int i=0; i<n; i++)
   {
      int idx2 = (g_sym[symIdx].kellyPnLHead - 1 - i + cap) % cap;
      double p = g_sym[symIdx].kellyPnL[idx2];
      if(p > 0) { wins++; sumWin += p; }
      else       sumLoss += MathAbs(p);
   }
   if(wins == 0 || wins == n) return 1.0; // degenerate: no Kelly signal
   double lossCount = n - wins;
   double winRate   = (double)wins / n;
   double avgWin    = sumWin / wins;
   double avgLoss   = (lossCount > 0 ? sumLoss / lossCount : 0.0);
   if(avgLoss <= 0) return 1.0;
   double bRatio    = avgWin / avgLoss;                      // b = avg_win / avg_loss
   double kellyFull = (winRate * (bRatio + 1.0) - 1.0) / bRatio; // Kelly criterion
   double kellyHalf = kellyFull * InpKelly_Fraction;
   // Normalise: if kelly=0.25 means "use 25% of normal risk"; we set the lot multiplier
   // relative to current baseline so Kelly=0 => minimal, Kelly=0.5 => normal, Kelly=1 => 2x.
   // Interpretation: kellyHalf * 2 maps 0.5 -> 1.0, 0.25 -> 0.5, etc.
   double mult = kellyHalf * 2.0;
   mult = MathMax(InpKelly_MinMult, MathMin(InpKelly_MaxMult, mult));
   return mult;
}

// ----- A3: Chandelier Exit -----
double Chandelier_GetStop(const int symIdx, const string sym, const long posType, const double atrPips)
{
   if(!InpUseChandelierExit) return 0.0;
   double pip = PipSize(sym);
   if(pip <= 0 || atrPips <= 0) return 0.0;
   int n = MathMax(2, InpChandelier_Period);

   double prices[];
   ArraySetAsSeries(prices, true);
   if(posType == POSITION_TYPE_BUY)
   {
      // For long: use highest high over N bars
      double highs[];
      ArraySetAsSeries(highs, true);
      if(CopyHigh(sym, InpEntryTF, 0, n, highs) < n) return 0.0;
      double hh = highs[0];
      for(int i=1;i<n;i++) if(highs[i] > hh) hh = highs[i];
      return hh - InpChandelier_Mult * atrPips * pip;
   }
   else
   {
      // For short: use lowest low over N bars
      double lows[];
      ArraySetAsSeries(lows, true);
      if(CopyLow(sym, InpEntryTF, 0, n, lows) < n) return 0.0;
      double ll = lows[0];
      for(int i=1;i<n;i++) if(lows[i] < ll) ll = lows[i];
      return ll + InpChandelier_Mult * atrPips * pip;
   }
}

// ----- D10: Weekly symbol ranking -----
void WeeklyRank_MaybeLoad()
{
   if(!InpUseWeeklySymbolRank) return;

   // Refresh on Monday open (or if never loaded)
   datetime now = TimeCurrent();
   if(g_rankLastRefresh > 0)
   {
      // Reload once per week: check if it's been >= 7 days
      if((now - g_rankLastRefresh) < 6 * 86400) return;
   }

   int flags = FILE_READ | FILE_CSV;
   if(InpSymbolRank_UseCommonFolder) flags |= FILE_COMMON;
   int h = FileOpen(InpSymbolRankFile, flags, ';');
   if(h == INVALID_HANDLE)
   {
      if(InpDebug) PrintFormat("[RankLoad] Cannot open %s — all symbols enabled", InpSymbolRankFile);
      // default: enable all
      for(int i=0;i<g_symCount;i++) g_sym[i].rankEnabled = true;
      g_rankLastRefresh = now;
      return;
   }

   // Mark all disabled first
   for(int i=0;i<g_symCount;i++) g_sym[i].rankEnabled = false;

   int row = 0;
   while(!FileIsEnding(h))
   {
      string sym_col = FileReadString(h);
      if(FileIsLineEnding(h)) { row++; continue; }
      string rank_col    = FileReadString(h);
      string sharpe_col  = FileReadString(h);
      string trades_col  = FileReadString(h);
      string winrate_col = FileReadString(h);
      string enabled_col = FileReadString(h);
      if(row == 0) { row++; continue; } // header

      string sym_upper = sym_col;
      StringToUpper(sym_upper);
      int enabled = (int)StringToInteger(TrimStr(enabled_col));

      for(int i=0;i<g_symCount;i++)
      {
         string gs = g_syms[i]; StringToUpper(gs);
         if(gs == sym_upper || StringFind(gs, sym_upper)==0)
         {
            g_sym[i].rankEnabled = (enabled == 1);
         }
      }
      row++;
   }
   FileClose(h);
   g_rankLastRefresh = now;
   if(InpDebug)
   {
      string en="";
      for(int i=0;i<g_symCount;i++) if(g_sym[i].rankEnabled) en += g_syms[i] + " ";
      PrintFormat("[RankLoad] Loaded from %s | enabled: %s", InpSymbolRankFile, en);
   }
}

// ----- C8: Expire stale pending limits -----
void PendingLimits_ExpireStale()
{
   if(!InpUseLimitOnSpreadBlock) return;
   datetime now = TimeCurrent();
   for(int i = g_pendingLimitsN - 1; i >= 0; i--)
   {
      if(now >= g_pendingLimits[i].expiresAt)
      {
         // Try to delete the order
         if(g_pendingLimits[i].ticket > 0)
            trade.OrderDelete(g_pendingLimits[i].ticket);
         // Remove from array (shift left)
         for(int j=i; j<g_pendingLimitsN-1; j++)
            g_pendingLimits[j] = g_pendingLimits[j+1];
         g_pendingLimitsN--;
      }
   }
}

void PendingLimits_Add(const ulong ticket, const string sym, const datetime expiresAt)
{
   if(g_pendingLimitsN >= ArraySize(g_pendingLimits)) return;
   g_pendingLimits[g_pendingLimitsN].ticket    = ticket;
   g_pendingLimits[g_pendingLimitsN].sym       = sym;
   g_pendingLimits[g_pendingLimitsN].expiresAt = expiresAt;
   g_pendingLimitsN++;
}

bool PendingLimits_HasFor(const string sym)
{
   for(int i=0;i<g_pendingLimitsN;i++)
      if(g_pendingLimits[i].sym == sym) return true;
   return false;
}

string FileStamp()
{
   // 20260212_1403
   string s = TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES);
   StringReplace(s, ".", "");
   StringReplace(s, ":", "");
   StringReplace(s, " ", "_");
   return s;
}

string StripTxtExt(const string fn)
{
   int n = StringLen(fn);
   if(n >= 4 && StringSubstr(fn, n-4, 4) == ".txt")
      return StringSubstr(fn, 0, n-4);
   return fn;
}

bool WriteTextFile(const string fileName, const string text, const bool append, const bool useCommon)
{
   int flags = FILE_TXT | FILE_WRITE;
   if(append) flags |= FILE_READ;
   if(useCommon) flags |= FILE_COMMON;

   int h = FileOpen(fileName, flags);
   if(h == INVALID_HANDLE)
      return false;

   if(append)
      FileSeek(h, 0, SEEK_END);

   FileWriteString(h, text);
   FileClose(h);
   return true;
}

double CalcRiskMoneyApprox(const string sym, const double volume, const double openPrice, const double slPrice)
{
   if(volume <= 0.0) return 0.0;
   if(slPrice <= 0.0) return 0.0;

   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0) return 0.0;

   double diff = MathAbs(openPrice - slPrice);
   return (tickValue / tickSize) * diff * volume;
}

bool CalcMAEMFEFromBars(const string sym, const int dir, const datetime openTime, const datetime closeTime,
                        const double openPrice, double &outMAE, double &outMFE)
{
   outMAE = 0.0;
   outMFE = 0.0;
   if(closeTime <= openTime) return false;

   double pip = PipSize(sym);
   if(pip <= 0.0) return false;

   MqlRates rates[];
   int copied = CopyRates(sym, InpProposalMAEMFETF, openTime, closeTime, rates);
   if(copied <= 0) return false;

   if(InpProposalMAEMFE_MaxBars > 0 && copied > InpProposalMAEMFE_MaxBars)
      return false; // prevent heavy scans on very long trades

   double maxHigh = rates[0].high;
   double minLow  = rates[0].low;
   for(int i=1;i<copied;i++)
   {
      if(rates[i].high > maxHigh) maxHigh = rates[i].high;
      if(rates[i].low  < minLow)  minLow  = rates[i].low;
   }

   double maePrice=0.0, mfePrice=0.0;
   if(dir > 0)
   {
      mfePrice = maxHigh - openPrice;
      maePrice = openPrice - minLow;
   }
   else
   {
      mfePrice = openPrice - minLow;
      maePrice = maxHigh - openPrice;
   }

   if(mfePrice < 0.0) mfePrice = 0.0;
   if(maePrice < 0.0) maePrice = 0.0;

   outMFE = mfePrice / pip;
   outMAE = maePrice / pip;
   return true;
}

int FindPosAggIndex(const long &ids[], const long posId)
{
   int n = ArraySize(ids);
   for(int i=0;i<n;i++)
      if(ids[i] == posId) return i;
   return -1;
}

// NEW: quicksort (O(n log n)) instead of O(n^2)
void QuickSortTradesByClose(ClosedTradeRec &a[], int left, int right)
{
   int i=left, j=right;
   datetime pivot = a[(left+right)/2].closeTime;

   while(i<=j)
   {
      while(a[i].closeTime < pivot) i++;
      while(a[j].closeTime > pivot) j--;

      if(i<=j)
      {
         ClosedTradeRec tmp=a[i];
         a[i]=a[j];
         a[j]=tmp;
         i++; j--;
      }
   }
   if(left<j)  QuickSortTradesByClose(a, left, j);
   if(i<right) QuickSortTradesByClose(a, i, right);
}

void SortTradesByCloseTime(ClosedTradeRec &trades[])
{
   int n = ArraySize(trades);
   if(n<=1) return;
   QuickSortTradesByClose(trades, 0, n-1);
}

int BuildClosedTradesFromHistory(ClosedTradeRec &outTrades[])
{
   ArrayResize(outTrades, 0);

   datetime to   = TimeCurrent();
   datetime from = to - (datetime)(InpProposalLookbackDays * 86400);
   if(!HistorySelect(from, to)) return 0;

   int total = HistoryDealsTotal();
   if(total <= 0) return 0;

   long    ids[];
   string  syms[];
   double  volIn[], volOut[], openPx[], closePx[], slPx[], tpPx[], profit[];
   datetime openT[], closeT[];
   int     dir[];
   bool    hasEntry[], hasExit[];

   ArrayResize(ids, 0);

   for(int i=0;i<total;i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(!HistoryDealSelect(deal)) continue;
      if(HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic) continue;

      long posId = (long)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      string sym = HistoryDealGetString(deal, DEAL_SYMBOL);
      int idx = FindPosAggIndex(ids, posId);
      if(idx < 0)
      {
         idx = ArraySize(ids);
         ArrayResize(ids, idx+1);
         ArrayResize(syms, idx+1);
         ArrayResize(volIn, idx+1);
         ArrayResize(volOut, idx+1);
         ArrayResize(openPx, idx+1);
         ArrayResize(closePx, idx+1);
         ArrayResize(slPx, idx+1);
         ArrayResize(tpPx, idx+1);
         ArrayResize(profit, idx+1);
         ArrayResize(openT, idx+1);
         ArrayResize(closeT, idx+1);
         ArrayResize(dir, idx+1);
         ArrayResize(hasEntry, idx+1);
         ArrayResize(hasExit, idx+1);

         ids[idx]=posId;
         syms[idx]=sym;
         volIn[idx]=0.0;
         volOut[idx]=0.0;
         openPx[idx]=0.0;
         closePx[idx]=0.0;
         slPx[idx]=0.0;
         tpPx[idx]=0.0;
         profit[idx]=0.0;
         openT[idx]=0;
         closeT[idx]=0;
         dir[idx]=0;
         hasEntry[idx]=false;
         hasExit[idx]=false;
      }

      int entry = (int)HistoryDealGetInteger(deal, DEAL_ENTRY);
      ENUM_DEAL_TYPE dtype = (ENUM_DEAL_TYPE)HistoryDealGetInteger(deal, DEAL_TYPE);
      datetime t = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
      double price = HistoryDealGetDouble(deal, DEAL_PRICE);
      double vol = HistoryDealGetDouble(deal, DEAL_VOLUME);

      double p = HistoryDealGetDouble(deal, DEAL_PROFIT)
               + HistoryDealGetDouble(deal, DEAL_COMMISSION)
               + HistoryDealGetDouble(deal, DEAL_SWAP);
      profit[idx] += p;

      if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
      {
         hasEntry[idx]=true;
         if(openT[idx] == 0 || t < openT[idx]) openT[idx]=t;
         if(dtype == DEAL_TYPE_BUY) dir[idx]=1;
         else if(dtype == DEAL_TYPE_SELL) dir[idx]=-1;

         double prevVol = volIn[idx];
         volIn[idx] += vol;
         if(volIn[idx] > 0.0)
            openPx[idx] = (openPx[idx]*prevVol + price*vol) / volIn[idx];

         double dsl = 0.0;
         double dtp = 0.0;
         ulong ord = (ulong)HistoryDealGetInteger(deal, DEAL_ORDER);
         if(ord>0 && HistoryOrderSelect(ord))
         {
            dsl = HistoryOrderGetDouble(ord, ORDER_SL);
            dtp = HistoryOrderGetDouble(ord, ORDER_TP);
         }
         if(dsl > 0.0 && slPx[idx] <= 0.0) slPx[idx] = dsl;
         if(dtp > 0.0 && tpPx[idx] <= 0.0) tpPx[idx] = dtp;
      }

      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT)
      {
         hasExit[idx]=true;
         volOut[idx] += vol;
         if(t >= closeT[idx])
         {
            closeT[idx]=t;
            closePx[idx]=price;
         }
      }
   }

   // Build closed trades
   int nAgg = ArraySize(ids);
   for(int i=0;i<nAgg;i++)
   {
      if(!hasEntry[i] || !hasExit[i]) continue;
      if(volIn[i] <= 0.0) continue;
      if(volOut[i] < volIn[i] - 1e-8) continue;

      ClosedTradeRec tr;
      tr.posId=ids[i];
      tr.sym=syms[i];
      tr.openTime=openT[i];
      tr.closeTime=closeT[i];
      tr.dir=dir[i];
      tr.volume=volIn[i];
      tr.openPrice=openPx[i];
      tr.closePrice=closePx[i];
      tr.slPrice=slPx[i];
      tr.tpPrice=tpPx[i];
      tr.profit=profit[i];

      tr.riskMoney = CalcRiskMoneyApprox(tr.sym, tr.volume, tr.openPrice, tr.slPrice);
      tr.profitR = (tr.riskMoney > 0.0 ? tr.profit / tr.riskMoney : 0.0);
      tr.slPips = (tr.slPrice > 0.0 ? MathAbs(tr.openPrice - tr.slPrice) / PipSize(tr.sym) : 0.0);

      // NEW: MAE/MFE computed later only for last-N trades (performance)
      tr.maePips=0.0;
      tr.mfePips=0.0;

      int nOut = ArraySize(outTrades);
      ArrayResize(outTrades, nOut+1);
      outTrades[nOut] = tr;
   }

   return ArraySize(outTrades);
}

int SymPerfIndex(SymPerf &arr[], const string sym)
{
   int n = ArraySize(arr);
   for(int i=0;i<n;i++)
      if(arr[i].sym == sym) return i;
   return -1;
}

string BuildPerfLine(const SymPerf &st)
{
   double winrate = SafeDiv((double)st.wins, (double)st.trades) * 100.0;
   double pf = (st.grossLoss < 0.0 ? SafeDiv(st.grossProfit, MathAbs(st.grossLoss)) : (st.grossProfit > 0.0 ? 999.0 : 0.0));
   double avgWin  = (st.wins   > 0 ? st.grossProfit / st.wins : 0.0);
   double avgLoss = (st.losses > 0 ? MathAbs(st.grossLoss) / st.losses : 0.0);
   double rr = (avgLoss > 0.0 ? avgWin / avgLoss : (avgWin>0.0 ? 999.0 : 0.0));
   double avgR = (st.countR > 0 ? st.sumR / st.countR : 0.0);
   double avgMAE = (st.countMAEMFE > 0 ? st.sumMAE / st.countMAEMFE : 0.0);
   double avgMFE = (st.countMAEMFE > 0 ? st.sumMFE / st.countMAEMFE : 0.0);
   double avgMAE_R = (st.countMAE_R > 0 ? st.sumMAE_R / st.countMAE_R : 0.0);
   double avgMFE_R = (st.countMAE_R > 0 ? st.sumMFE_R / st.countMAE_R : 0.0);

   return StringFormat("%s | n=%d | win=%.1f%% | PF=%.2f | RR=%.2f | net=%.2f | maxDD=%.2f | avgR=%.2f | MAE=%.1fp (%.2fR) | MFE=%.1fp (%.2fR)",
                       st.sym, st.trades, winrate, pf, rr, st.net, st.maxDD, avgR, avgMAE, avgMAE_R, avgMFE, avgMFE_R);
}

string BuildSuggestion(const SymPerf &st)
{
   if(st.trades <= 0) return "";

   double winrate = SafeDiv((double)st.wins, (double)st.trades) * 100.0;
   double pf = (st.grossLoss < 0.0 ? SafeDiv(st.grossProfit, MathAbs(st.grossLoss)) : (st.grossProfit > 0.0 ? 999.0 : 0.0));
   double avgWin  = (st.wins   > 0 ? st.grossProfit / st.wins : 0.0);
   double avgLoss = (st.losses > 0 ? MathAbs(st.grossLoss) / st.losses : 0.0);
   double rr = (avgLoss > 0.0 ? avgWin / avgLoss : (avgWin>0.0 ? 999.0 : 0.0));
   double avgMAE_R = (st.countMAE_R > 0 ? st.sumMAE_R / st.countMAE_R : 0.0);
   double avgMFE_R = (st.countMAE_R > 0 ? st.sumMFE_R / st.countMAE_R : 0.0);

   string sug = "";
   if(st.trades < InpProposalMinTradesPerSymbol)
   {
      sug = StringFormat("Nog te weinig data (min %d trades per symbool). Verzamel meer trades voordat je hard aanpast.", InpProposalMinTradesPerSymbol);
   }
   else if(pf < 0.90 && winrate < 45.0)
   {
      double newADXTrend = InpMinADXForEntry    + 2.0;
      double newADXEntry = InpMinADXEntryFilter + 2.0;

      sug = StringFormat("Ondermaats (PF<0.90 & winrate<45). Probeer strenger: InpMinADXForEntry=%.1f en InpMinADXEntryFilter=%.1f. Of zet %s tijdelijk uit (verwijder uit InpSymbolsCSV).",
                         newADXTrend, newADXEntry, st.sym);
   }
   else if(pf < 1.0 && winrate > 55.0 && rr < 0.90)
   {
      sug = StringFormat("Winrate ok maar RR laag. Overweeg TP_RR omhoog (%.2f -> %.2f) zodat wins meer ruimte krijgen.", InpTP_RR, InpTP_RR+0.25);
   }
   else if(pf > 1.30 && winrate > 60.0)
   {
      sug = "Sterk (PF>1.3 & winrate>60). Je kunt iets losser zetten voor meer trades (MinADXForEntry -1) of risk licht omhoog.";
   }
   else
   {
      sug = "Neutraal. Kleine tweaks pas na meer data.";
   }

   if(st.countMAE_R > 0)
   {
      if(avgMFE_R > InpTP_RR*1.40)
         sug += StringFormat(" | MFE gemiddeld (%.2fR) is veel groter dan TP (%.2fR): TP_RR verhogen kan.", avgMFE_R, InpTP_RR);
      if(avgMAE_R > 0.90 && winrate < 50.0)
         sug += StringFormat(" | MAE vaak dicht bij SL (%.2fR): entries te vroeg of SL te krap. Overweeg SL_ATR_Mult iets hoger of strengere filters.", avgMAE_R);
   }

   return sug;
}

void GenerateTradeCountProposal()
{
   int need = InpProposalClosedTradesTrigger;
   if(need <= 0) return;

   ClosedTradeRec tradesAll[];
   int nAll = BuildClosedTradesFromHistory(tradesAll);
   if(nAll <= 0)
   {
      Print("AUTO PROPOSAL: Geen gesloten trades gevonden in History (controleer lookback/magic). ");
      return;
   }

   SortTradesByCloseTime(tradesAll);

   int used = MathMin(need, nAll);
   int start = nAll - used;

   // NEW: compute MAE/MFE only for last 'used' trades (performance)
   for(int i=start;i<nAll;i++)
   {
      if(InpProposalMAEMFE_MinTradeMinutes>0)
      {
         int durMin = (int)((tradesAll[i].closeTime - tradesAll[i].openTime)/60);
         if(durMin < InpProposalMAEMFE_MinTradeMinutes)
            continue;
      }

      double mae=0.0, mfe=0.0;
      if(!MaeMfeCache_Get(tradesAll[i].posId, mae, mfe))
      {
         CalcMAEMFEFromBars(tradesAll[i].sym, tradesAll[i].dir, tradesAll[i].openTime, tradesAll[i].closeTime, tradesAll[i].openPrice, mae, mfe);
         MaeMfeCache_Put(tradesAll[i].posId, mae, mfe);
      }
      tradesAll[i].maePips = mae;
      tradesAll[i].mfePips = mfe;
   }

   // Aggregate per symbol + overall
   SymPerf perSym[];
   ArrayResize(perSym, 0);
   SymPerf all; all.sym="ALL"; all.trades=0; all.wins=0; all.losses=0; all.grossProfit=0; all.grossLoss=0; all.net=0; all.maxDD=0;
   all.sumR=0; all.countR=0; all.sumMAE=0; all.sumMFE=0; all.countMAEMFE=0; all.sumMAE_R=0; all.sumMFE_R=0; all.countMAE_R=0;
   all.maxMAE=0; all.maxMFE=0; all.cum=0; all.peak=0;

   for(int i=start;i<nAll;i++)
   {
      ClosedTradeRec tr = tradesAll[i];
      // overall
      all.trades++;
      all.net += tr.profit;
      if(tr.profit >= 0.0) { all.wins++; all.grossProfit += tr.profit; }
      else                 { all.losses++; all.grossLoss += tr.profit; }
      if(tr.riskMoney > 0.0) { all.sumR += tr.profitR; all.countR++; }

      if(tr.maePips > 0.0 || tr.mfePips > 0.0)
      {
         all.sumMAE += tr.maePips;
         all.sumMFE += tr.mfePips;
         all.countMAEMFE++;
         if(tr.maePips > all.maxMAE) all.maxMAE = tr.maePips;
         if(tr.mfePips > all.maxMFE) all.maxMFE = tr.mfePips;
      }
      if(tr.slPips > 0.0)
      {
         all.sumMAE_R += (tr.maePips / tr.slPips);
         all.sumMFE_R += (tr.mfePips / tr.slPips);
         all.countMAE_R++;
      }
      all.cum += tr.profit;
      if(all.cum > all.peak) all.peak = all.cum;
      double ddAll = all.peak - all.cum;
      if(ddAll > all.maxDD) all.maxDD = ddAll;

      // per symbol
      int idx = SymPerfIndex(perSym, tr.sym);
      if(idx < 0)
      {
         idx = ArraySize(perSym);
         ArrayResize(perSym, idx+1);
         perSym[idx].sym=tr.sym;
         perSym[idx].trades=0; perSym[idx].wins=0; perSym[idx].losses=0;
         perSym[idx].grossProfit=0; perSym[idx].grossLoss=0; perSym[idx].net=0; perSym[idx].maxDD=0;
         perSym[idx].sumR=0; perSym[idx].countR=0;
         perSym[idx].sumMAE=0; perSym[idx].sumMFE=0; perSym[idx].countMAEMFE=0;
         perSym[idx].sumMAE_R=0; perSym[idx].sumMFE_R=0; perSym[idx].countMAE_R=0;
         perSym[idx].maxMAE=0; perSym[idx].maxMFE=0; perSym[idx].cum=0; perSym[idx].peak=0;
      }
      perSym[idx].trades++;
      perSym[idx].net += tr.profit;
      if(tr.profit >= 0.0) { perSym[idx].wins++; perSym[idx].grossProfit += tr.profit; }
      else                 { perSym[idx].losses++; perSym[idx].grossLoss += tr.profit; }
      if(tr.riskMoney > 0.0) { perSym[idx].sumR += tr.profitR; perSym[idx].countR++; }

      if(tr.maePips > 0.0 || tr.mfePips > 0.0)
      {
         perSym[idx].sumMAE += tr.maePips;
         perSym[idx].sumMFE += tr.mfePips;
         perSym[idx].countMAEMFE++;
         if(tr.maePips > perSym[idx].maxMAE) perSym[idx].maxMAE = tr.maePips;
         if(tr.mfePips > perSym[idx].maxMFE) perSym[idx].maxMFE = tr.mfePips;
      }
      if(tr.slPips > 0.0)
      {
         perSym[idx].sumMAE_R += (tr.maePips / tr.slPips);
         perSym[idx].sumMFE_R += (tr.mfePips / tr.slPips);
         perSym[idx].countMAE_R++;
      }

      perSym[idx].cum += tr.profit;
      if(perSym[idx].cum > perSym[idx].peak) perSym[idx].peak = perSym[idx].cum;
      double dd = perSym[idx].peak - perSym[idx].cum;
      if(dd > perSym[idx].maxDD) perSym[idx].maxDD = dd;
   }

   // Build report
   string report = "";
   report += StringFormat("MSPB AUTO-ANALYSE (last %d gesloten posities)\r\n", used);
   report += StringFormat("Tijd: %s | Account: %d | Magic: %d\r\n", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), (int)AccountInfoInteger(ACCOUNT_LOGIN), (int)InpMagic);
   report += StringFormat("MAE/MFE timeframe: %s | LookbackDays: %d\r\n\r\n", EnumToString(InpProposalMAEMFETF), InpProposalLookbackDays);

   // Overall line
   report += "[OVERALL]\r\n";
   report += BuildPerfLine(all) + "\r\n\r\n";

   report += "[PER SYMBOOL]\r\n";
   for(int i=0;i<ArraySize(perSym);i++)
      report += BuildPerfLine(perSym[i]) + "\r\n";
   report += "\r\n";

   // Detailed per symbol proposals
   string stamp = FileStamp();
   string baseNoExt = StripTxtExt(InpProposalFileName);

   report += "[VOORSTELLEN PER SYMBOOL]\r\n";
   for(int i=0;i<ArraySize(perSym);i++)
   {
      string s = perSym[i].sym;
      string sug = BuildSuggestion(perSym[i]);

      report += StringFormat("=== SYMBOL %s ===\r\n", s);
      report += BuildPerfLine(perSym[i]) + "\r\n";
      report += "Voorstel: " + sug + "\r\n";
      report += StringFormat("Solo-test snippet (alleen %s): MinADXTrend=%.1f | MinADXEntry=%.1f | MinATR=%.2f | MinBody=%.2f | TP_RR=%.2f\r\n\r\n",
                             s, InpMinADXForEntry, InpMinADXEntryFilter, InpMinATR_Pips, InpMinBodyPips, InpTP_RR);

      if(InpProposalSaveToFile && InpProposalSplitPerSymbolFiles)
      {
         string sec = "";
         sec += StringFormat("MSPB AUTO-ANALYSE (last %d gesloten posities)\r\n", used);
         sec += StringFormat("Tijd: %s\r\n\r\n", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));
         sec += StringFormat("SYMBOL: %s\r\n", s);
         sec += BuildPerfLine(perSym[i]) + "\r\n";
         sec += "Voorstel: " + sug + "\r\n";
         sec += StringFormat("\r\nSolo-test snippet (alleen %s):\r\n", s);
         sec += StringFormat("InpSymbolsCSV=%s\r\n", s);
         sec += StringFormat("InpMinADXForEntry=%.1f\r\n", InpMinADXForEntry);
         sec += StringFormat("InpMinADXEntryFilter=%.1f\r\n", InpMinADXEntryFilter);
         sec += StringFormat("InpMinATR_Pips=%.2f\r\n", InpMinATR_Pips);
         sec += StringFormat("InpMinBodyPips=%.2f\r\n", InpMinBodyPips);
         sec += StringFormat("InpTP_RR=%.2f\r\n", InpTP_RR);

         string fn = StringFormat("%s_%s_%s.txt", baseNoExt, s, stamp);
         WriteTextFile(fn, "\r\n\r\n============================\r\n" + stamp + "\r\n============================\r\n" + sec + "\r\n", false, InpProposalUseCommonFolder);
      }
   }

   // Print + audit + telegram
   Print(report);
   Audit_Log("AUTO_PROPOSAL_ADV", report, false);

   if(InpEnableTelegram)
   {
      string tg = report;
      if(StringLen(tg) > 3500) tg = StringSubstr(tg, 0, 3500) + "...";
      TelegramSendMessage(tg);
   }

   // Save combined report
   if(InpProposalSaveToFile)
   {
      string header = "\r\n\r\n============================\r\n" + stamp + "\r\n============================\r\n";
      bool ok = WriteTextFile(InpProposalFileName, header + report + "\r\n", InpProposalAppendToFile, InpProposalUseCommonFolder);
      if(!ok)
         Print("AUTO PROPOSAL: Kon rapport niet wegschrijven (FileOpen failed). Check rechten/FILE_COMMON.");
      else
         Print(StringFormat("AUTO PROPOSAL: Rapport opgeslagen naar %s (%s)", InpProposalFileName, (InpProposalUseCommonFolder?"Common\\Files":"MQL5\\Files")));
   }
}

void CheckTradeCountProposal()
{
   if(!InpProposalOnClosedTrades) return;
   if(InpProposalClosedTradesTrigger <= 0) return;
   if(g_closedTradesSinceProposal < InpProposalClosedTradesTrigger) return;
   if((TimeCurrent() - g_lastProposalTime) < InpProposalMinMinutesBetween * 60) return;

   GenerateTradeCountProposal();
   g_closedTradesSinceProposal = 0;
   g_lastProposalTime = TimeCurrent();
}


// =========================
// Tune state + auto-rollback (v11)
// =========================
#define TUNE_STATE_VERSION 1

struct TunePerf
{
   int trades;
   int wins;
   int losses;
   double grossProfit;
   double grossLoss;
   double net;
   double pf;
   double maxDD;
   double avgR;
   int rCount;
};

void TunePerf_Reset(TunePerf &m)
{
   m.trades=0; m.wins=0; m.losses=0;
   m.grossProfit=0.0; m.grossLoss=0.0; m.net=0.0;
   m.pf=0.0; m.maxDD=0.0; m.avgR=0.0; m.rCount=0;
}

struct TuneStateRow
{
   string   sym;                 // normalized (upper, trimmed)
   datetime last_used_close;      // close-time watermark: trades <= this are "already used" for next tune gate

   // Current vs previous override snapshots (for rollback)
   string   active_sig;
   SymbolOverrides active_ovr;

   string   prev_sig;
   SymbolOverrides prev_ovr;

   // Trial monitoring (started when overrides changed)
   bool     trial_active;
   datetime trial_start_time;      // TimeCurrent() at detection
   datetime trial_close_watermark; // last closed position time BEFORE change (boundary for trial trades)

   // Baseline (pre-change) metrics captured at trial start
   int      base_trades;
   double   base_pf;
   double   base_dd;
   double   base_avgr;
   double   base_net;
};

TuneStateRow g_tune[];
bool g_tuneLoaded=false;
bool g_tuneWarnedNoFile=false;
datetime g_tuneNextHeavyCheck=0;
int g_tune_lastMonthlyRunKey=0; // YYYYMMDD local

string Tune_NormSym(const string sym){ return UpperTrim(sym); }

void Tune_OvrInitEmpty(SymbolOverrides &o)
{
   o.sym="";
   o.maxSpreadPips=0;
   o.minATR_Pips=0;
   o.minADXTrend=0;
   o.minADXEntry=0;
   o.minBodyPips=0;
   o.slATRMult=0;
   o.tpRR=0;
   o.useBreakPrev=-1;
   o.allowBuy=-1;
   o.allowSell=-1;
   o.usePullbackEMA=-1;
}

string Tune_OvrSig(const SymbolOverrides &o)
{
   // Stable signature (fixed precision)
   return StringFormat("%s|%s|%s|%s|%s|%s|%s|%d|%d|%d|%d",
      DoubleToString(o.maxSpreadPips, 2),
      DoubleToString(o.minATR_Pips, 2),
      DoubleToString(o.minADXTrend, 2),
      DoubleToString(o.minADXEntry, 2),
      DoubleToString(o.minBodyPips, 2),
      DoubleToString(o.slATRMult, 2),
      DoubleToString(o.tpRR, 2),
      (int)o.useBreakPrev,
      (int)o.allowBuy,
      (int)o.allowSell,
      (int)o.usePullbackEMA
   );
}

int Tune_FindIdx(const string symNorm)
{
   for(int i=0;i<ArraySize(g_tune);i++)
      if(g_tune[i].sym==symNorm) return i;
   return -1;
}

int Tune_EnsureRow(const string symNorm)
{
   int idx=Tune_FindIdx(symNorm);
   if(idx>=0) return idx;

   TuneStateRow row;
   row.sym=symNorm;
   row.last_used_close=0;

   row.active_sig="";
   Tune_OvrInitEmpty(row.active_ovr);

   row.prev_sig="";
   Tune_OvrInitEmpty(row.prev_ovr);

   row.trial_active=false;
   row.trial_start_time=0;
   row.trial_close_watermark=0;

   row.base_trades=0;
   row.base_pf=0;
   row.base_dd=0;
   row.base_avgr=0;
   row.base_net=0;

   int n=ArraySize(g_tune);
   ArrayResize(g_tune, n+1);
   g_tune[n]=row;
   return n;
}

bool TuneState_BackupExisting()
{
   string fn=InpTune_StateFile;
   int commonFlag = InpTune_StateUseCommonFolder ? FILE_COMMON : 0;

   if(!FileIsExist(fn, commonFlag))
      return true;

   string bak=fn+".bak";

   int fr=FileOpen(fn, FILE_READ|FILE_TXT|FILE_ANSI | commonFlag);
   if(fr==INVALID_HANDLE) return false;

   int fw=FileOpen(bak, FILE_WRITE|FILE_TXT|FILE_ANSI | commonFlag);
   if(fw==INVALID_HANDLE){ FileClose(fr); return false; }

   while(!FileIsEnding(fr))
   {
      string line;
      if(!FileReadLineTxt(fr, line)) break;
      FileWriteString(fw, line+"\r\n");
   }
   FileClose(fr);
   FileClose(fw);
   return true;
}

void TuneState_Load()
{
   if(!InpTune_Enable) return;
   g_tuneLoaded=true;

   ArrayResize(g_tune, 0);

   string fn=InpTune_StateFile;
   int commonFlag = InpTune_StateUseCommonFolder ? FILE_COMMON : 0;

   if(!FileIsExist(fn, commonFlag))
   {
      if(!g_tuneWarnedNoFile)
      {
         Print("[TUNE] No state file found, starting fresh.");
         g_tuneWarnedNoFile=true;
      }
      return;
   }

   int h=FileOpen(fn, FILE_READ|FILE_TXT|FILE_ANSI | commonFlag);
   if(h==INVALID_HANDLE)
   {
      Print("[TUNE] Failed to open state file: ", fn, " err=", GetLastError());
      return;
   }

   int version=0;
   bool versionSeen=false;

   while(!FileIsEnding(h))
   {
      string line;
      if(!FileReadLineTxt(h, line)) break;

      line=TrimStr(line);
      if(line=="" || StringGetCharacter(line,0)=='#') continue;

      string f[];
      int n=SplitCSV(line, f);
      if(n<2) continue;

      // Version header line: VERSION;1
      if(!versionSeen && (f[0]=="VERSION" || f[0]=="version" || f[0]=="Version"))
      {
         version=(int)StringToInteger(f[1]);
         versionSeen=true;
         continue;
      }

      string sym=Tune_NormSym(f[0]);
      if(sym=="") continue;

      int idx=Tune_EnsureRow(sym);

      // Columns (v1):
      // 0 sym
      // 1 last_used_close (int)
      // 2 trial_active (0/1)
      // 3 trial_start_time (int)
      // 4 trial_close_watermark (int)
      // 5 base_trades
      // 6 base_pf
      // 7 base_dd
      // 8 base_avgr
      // 9 base_net
      // 10..20 active override fields (11)
      // 21..31 prev override fields (11)

      g_tune[idx].last_used_close = (datetime)StringToInteger(f[1]);

      int cur=2;
      if(n>cur) g_tune[idx].trial_active = (StringToInteger(f[cur])!=0); cur++;
      if(n>cur) g_tune[idx].trial_start_time = (datetime)StringToInteger(f[cur]); cur++;
      if(n>cur) g_tune[idx].trial_close_watermark = (datetime)StringToInteger(f[cur]); cur++;
      if(n>cur) g_tune[idx].base_trades = (int)StringToInteger(f[cur]); cur++;
      if(n>cur) g_tune[idx].base_pf = StringToDouble(f[cur]); cur++;
      if(n>cur) g_tune[idx].base_dd = StringToDouble(f[cur]); cur++;
      if(n>cur) g_tune[idx].base_avgr = StringToDouble(f[cur]); cur++;
      if(n>cur) g_tune[idx].base_net = StringToDouble(f[cur]); cur++;

      if(n>=cur+11)
      {
         SymbolOverrides o;
         Tune_OvrInitEmpty(o);
         o.sym=sym;

         o.maxSpreadPips = StringToDouble(f[cur+0]);
         o.minATR_Pips   = StringToDouble(f[cur+1]);
         o.minADXTrend   = StringToDouble(f[cur+2]);
         o.minADXEntry   = StringToDouble(f[cur+3]);
         o.minBodyPips   = StringToDouble(f[cur+4]);
         o.slATRMult     = StringToDouble(f[cur+5]);
         o.tpRR          = StringToDouble(f[cur+6]);
         o.useBreakPrev  = (int)StringToInteger(f[cur+7]);
         o.allowBuy      = (int)StringToInteger(f[cur+8]);
         o.allowSell     = (int)StringToInteger(f[cur+9]);
         o.usePullbackEMA= (int)StringToInteger(f[cur+10]);

         g_tune[idx].active_ovr=o;
         g_tune[idx].active_sig=Tune_OvrSig(o);
      }
      cur += 11;

      if(n>=cur+11)
      {
         SymbolOverrides o;
         Tune_OvrInitEmpty(o);
         o.sym=sym;

         o.maxSpreadPips = StringToDouble(f[cur+0]);
         o.minATR_Pips   = StringToDouble(f[cur+1]);
         o.minADXTrend   = StringToDouble(f[cur+2]);
         o.minADXEntry   = StringToDouble(f[cur+3]);
         o.minBodyPips   = StringToDouble(f[cur+4]);
         o.slATRMult     = StringToDouble(f[cur+5]);
         o.tpRR          = StringToDouble(f[cur+6]);
         o.useBreakPrev  = (int)StringToInteger(f[cur+7]);
         o.allowBuy      = (int)StringToInteger(f[cur+8]);
         o.allowSell     = (int)StringToInteger(f[cur+9]);
         o.usePullbackEMA= (int)StringToInteger(f[cur+10]);

         g_tune[idx].prev_ovr=o;
         g_tune[idx].prev_sig=Tune_OvrSig(o);
      }
   }

   FileClose(h);
}

void TuneState_Save()
{
   if(!InpTune_Enable) return;

   TuneState_BackupExisting();

   string fn=InpTune_StateFile;
   int commonFlag = InpTune_StateUseCommonFolder ? FILE_COMMON : 0;

   int h=FileOpen(fn, FILE_WRITE|FILE_TXT|FILE_ANSI | commonFlag);
   if(h==INVALID_HANDLE)
   {
      Print("[TUNE] Failed to save state file: ", fn, " err=", GetLastError());
      return;
   }

   FileWriteString(h, StringFormat("VERSION;%d\r\n", TUNE_STATE_VERSION));
   FileWriteString(h, "#sym;last_used_close;trial_active;trial_start_time;trial_close_watermark;base_trades;base_pf;base_dd;base_avgr;base_net;" +
                      "act_maxSpread;act_minATR;act_minADXTrend;act_minADXEntry;act_minBody;act_slATRMult;act_tpRR;act_useBreakPrev;act_allowBuy;act_allowSell;act_usePullbackEMA;" +
                      "prev_maxSpread;prev_minATR;prev_minADXTrend;prev_minADXEntry;prev_minBody;prev_slATRMult;prev_tpRR;prev_useBreakPrev;prev_allowBuy;prev_allowSell;prev_usePullbackEMA\r\n");

   // Reset-guard: only save current symbols (if InpSymbols changes, stale rows disappear automatically)
   for(int i=0;i<g_symCount;i++)
   {
      string sym=Tune_NormSym(g_syms[i]);
      int idx=Tune_FindIdx(sym);
      if(idx<0) continue;

      const TuneStateRow r=g_tune[idx]; // copy (MQL has no local references)

      string line = sym + ";" + (string)(long)r.last_used_close + ";" +
                    (r.trial_active?"1":"0") + ";" + (string)(long)r.trial_start_time + ";" + (string)(long)r.trial_close_watermark + ";" +
                    (string)r.base_trades + ";" + DoubleToString(r.base_pf,2) + ";" + DoubleToString(r.base_dd,2) + ";" +
                    DoubleToString(r.base_avgr,4) + ";" + DoubleToString(r.base_net,2) + ";" +

                    DoubleToString(r.active_ovr.maxSpreadPips,2) + ";" + DoubleToString(r.active_ovr.minATR_Pips,2) + ";" +
                    DoubleToString(r.active_ovr.minADXTrend,2) + ";" + DoubleToString(r.active_ovr.minADXEntry,2) + ";" +
                    DoubleToString(r.active_ovr.minBodyPips,2) + ";" + DoubleToString(r.active_ovr.slATRMult,2) + ";" +
                    DoubleToString(r.active_ovr.tpRR,2) + ";" + (string)r.active_ovr.useBreakPrev + ";" + (string)r.active_ovr.allowBuy + ";" +
                    (string)r.active_ovr.allowSell + ";" + (string)r.active_ovr.usePullbackEMA + ";" +

                    DoubleToString(r.prev_ovr.maxSpreadPips,2) + ";" + DoubleToString(r.prev_ovr.minATR_Pips,2) + ";" +
                    DoubleToString(r.prev_ovr.minADXTrend,2) + ";" + DoubleToString(r.prev_ovr.minADXEntry,2) + ";" +
                    DoubleToString(r.prev_ovr.minBodyPips,2) + ";" + DoubleToString(r.prev_ovr.slATRMult,2) + ";" +
                    DoubleToString(r.prev_ovr.tpRR,2) + ";" + (string)r.prev_ovr.useBreakPrev + ";" + (string)r.prev_ovr.allowBuy + ";" +
                    (string)r.prev_ovr.allowSell + ";" + (string)r.prev_ovr.usePullbackEMA;

      FileWriteString(h, line+"\r\n");
   }

   FileClose(h);
}
// --- Applied-settings audit log (NEW v12)
// Records whenever the EA's effective tunable settings change (inputs / overrides / spread-stress multiplier).
string g_appliedLastHash = "";

ulong Hash64_FNV1a(const string s)
{
   // MQL does not support C-style integer suffixes like ULL, so we cast explicitly.
   ulong h = (ulong)1469598103934665603; // FNV offset basis
   int n = StringLen(s);
   for(int i=0;i<n;i++)
   {
      ushort c = (ushort)StringGetCharacter(s, i);
      h ^= (ulong)c;
      h *= (ulong)1099511628211;         // FNV prime
   }
   return h;
}

string Hash64_ToHex(ulong h)
{
   const string hex = "0123456789ABCDEF";
   string out = "";
   for(int i=0;i<16;i++)
   {
      int nib = (int)(h & 15);
      out = StringSubstr(hex, nib, 1) + out;
      h >>= 4;
   }
   return out;
}

string AppliedLog_LastHashFile()
{
   return "MSPB_AppliedSettings.last";
}

string AppliedLog_BuildSignature()
{
   string s = "";
   s += "prog=" + MQLInfoString(MQL_PROGRAM_NAME) + "|";
   s += "magic=" + (string)InpMagic + "|";
   s += "symbols=" + InpSymbols + "|";
   s += "entryTF=" + EnumToString(InpEntryTF) + "|";
   s += "confirmTF=" + EnumToString(InpConfirmTF) + "|";

   // tunable params (allowed to optimize)
   s += "minADXTrend=" + DoubleToString(InpMinADXForEntry, 1) + "|";
   s += "minADXEntry=" + DoubleToString(InpMinADXEntryFilter, 1) + "|";
   s += "minATRpips=" + DoubleToString(InpMinATR_Pips, 2) + "|";
   s += "minBodyPips=" + DoubleToString(InpMinBodyPips, 2) + "|";
   s += "usePullbackEMA=" + (InpUsePullbackEMA ? "1" : "0") + "|";
   s += "slATRMult=" + DoubleToString(InpSL_ATR_Mult, 2) + "|";
   s += "tpRR=" + DoubleToString(InpTP_RR, 2) + "|";
   s += "useBreakPrev=" + (InpUseBreakPrevHighLow ? "1" : "0") + "|";

   // symbol overrides (file + count)
   s += "ovrEnabled=" + (InpSymbolOverrides_Enable ? "1" : "0") + "|";
   s += "ovrFile=" + InpSymbolOverrides_File + "|";
   s += "ovrCount=" + (string)g_ovrCount + "|";

   // robustness tests
   s += "spreadStressMult=" + DoubleToString(InpSpreadStressMult, 2) + "|";

   return s;
}

void AppliedLog_LoadLastHash()
{
   g_appliedLastHash = "";
   int flags = FILE_READ | FILE_TXT | FILE_ANSI;
   if(InpAppliedLog_UseCommonFolder) flags |= FILE_COMMON;

   int h = FileOpen(AppliedLog_LastHashFile(), flags);
   if(h == INVALID_HANDLE)
      return;

   string line = "";
   if(!FileIsEnding(h))
      line = FileReadString(h);

   FileClose(h);
   g_appliedLastHash = TrimStr(line);
}

void AppliedLog_SaveLastHash()
{
   if(!InpAppliedLog_Enable) return;

   int flags = FILE_WRITE | FILE_TXT | FILE_ANSI;
   if(InpAppliedLog_UseCommonFolder) flags |= FILE_COMMON;

   int h = FileOpen(AppliedLog_LastHashFile(), flags);
   if(h == INVALID_HANDLE)
      return;

   FileWriteString(h, g_appliedLastHash);
   FileClose(h);
}

void AppliedLog_AppendIfChanged()
{
   if(!InpAppliedLog_Enable) return;

   if(g_appliedLastHash == "")
      AppliedLog_LoadLastHash();

   string sig = AppliedLog_BuildSignature();
   string hx  = Hash64_ToHex(Hash64_FNV1a(sig));

   if(hx == g_appliedLastHash)
      return;

   int flags = FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_WRITE;
   if(InpAppliedLog_UseCommonFolder) flags |= FILE_COMMON;

   int fh = FileOpen(InpAppliedLog_File, flags, ';');
   if(fh == INVALID_HANDLE)
   {
      Print("[APPLIED] Cannot open log file: ", InpAppliedLog_File, " err=", GetLastError());
      return;
   }

   bool newFile = (FileSize(fh) == 0);
   FileSeek(fh, 0, SEEK_END);

   if(newFile)
   {
      FileWrite(fh,
         "ts","hash","program","magic","symbols","entryTF","confirmTF",
         "minADXTrend","minADXEntry","minATRpips","minBodyPips",
         "usePullbackEMA","slATRMult","tpRR","useBreakPrev",
         "ovrEnabled","ovrFile","ovrCount",
         "spreadStressMult"
      );
   }

   FileWrite(fh,
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
      hx,
      MQLInfoString(MQL_PROGRAM_NAME),
      (string)InpMagic,
      InpSymbols,
      EnumToString(InpEntryTF),
      EnumToString(InpConfirmTF),
      DoubleToString(InpMinADXForEntry, 1),
      DoubleToString(InpMinADXEntryFilter, 1),
      DoubleToString(InpMinATR_Pips, 2),
      DoubleToString(InpMinBodyPips, 2),
      (InpUsePullbackEMA ? "1" : "0"),
      DoubleToString(InpSL_ATR_Mult, 2),
      DoubleToString(InpTP_RR, 2),
      (InpUseBreakPrevHighLow ? "1" : "0"),
      (InpSymbolOverrides_Enable ? "1" : "0"),
      InpSymbolOverrides_File,
      (string)g_ovrCount,
      DoubleToString(InpSpreadStressMult, 2)
   );

   FileClose(fh);

   g_appliedLastHash = hx;
   AppliedLog_SaveLastHash();

   Print("[APPLIED] Logged settings snapshot (hash=", hx, ")");
}




bool Tune_GetCurrentOverrideForSymbol(const string sym, SymbolOverrides &out)
{
   int idx=FindOverrideIndex(sym);
   if(idx<0) return false;
   out=g_ovr[idx];
   out.sym=Tune_NormSym(sym);
   return true;
}

bool Tune_PerfFromTrades(const ClosedTradeRec &allTrades[], const string symNorm,
                               const datetime closeTimeMinExcl, const datetime closeTimeMaxExcl,
                               const int maxTrades, TunePerf &out)
{
   TunePerf_Reset(out);

   ClosedTradeRec tmp[];
   ArrayResize(tmp,0);

   int nAll=ArraySize(allTrades);
   for(int i=0;i<nAll;i++)
   {
      string ts=Tune_NormSym(allTrades[i].sym);
      if(ts!=symNorm) continue;

      datetime ct=allTrades[i].closeTime;
      if(closeTimeMinExcl>0 && ct<=closeTimeMinExcl) continue;
      if(closeTimeMaxExcl>0 && ct>=closeTimeMaxExcl) continue;

      int n=ArraySize(tmp);
      ArrayResize(tmp, n+1);
      tmp[n]=allTrades[i];
   }

   int n=ArraySize(tmp);
   if(n<=0) return true;

   SortTradesByCloseTime(tmp);

   int start=0;
   if(maxTrades>0 && n>maxTrades) start=n-maxTrades;

   double cum=0.0, peak=0.0, maxdd=0.0;
   double sumR=0.0; int cntR=0;
   double gp=0.0, gl=0.0;

   for(int i=start;i<n;i++)
   {
      double p=tmp[i].profit;

      out.trades++;
      out.net += p;

      if(p>=0.0){ out.wins++; gp += p; }
      else      { out.losses++; gl += p; }

      if(tmp[i].riskMoney>0.0)
      {
         sumR += tmp[i].profitR;
         cntR++;
      }

      cum += p;
      if(cum>peak) peak=cum;
      double dd=peak-cum;
      if(dd>maxdd) maxdd=dd;
   }

   out.grossProfit=gp;
   out.grossLoss=gl;
   out.maxDD=maxdd;

   if(gl<0.0) out.pf = (gp>0.0 ? gp/MathAbs(gl) : 0.0);
   else       out.pf = (gp>0.0 ? 999.0 : 0.0);

   out.avgR  = (cntR>0 ? sumR/cntR : 0.0);
   out.rCount=cntR;

   return true;
}

datetime Tune_LastCloseBefore(const ClosedTradeRec &allTrades[], const string symNorm, const datetime beforeTime)
{
   datetime last=0;
   int nAll=ArraySize(allTrades);
   for(int i=0;i<nAll;i++)
   {
      string ts=Tune_NormSym(allTrades[i].sym);
      if(ts!=symNorm) continue;
      datetime ct=allTrades[i].closeTime;
      if(ct<beforeTime && ct>last) last=ct;
   }
   return last;
}

int Tune_CountTradesSince(const ClosedTradeRec &allTrades[], const string symNorm, const datetime watermark, datetime &lastCloseOut)
{
   int cnt=0;
   lastCloseOut=0;
   int nAll=ArraySize(allTrades);
   for(int i=0;i<nAll;i++)
   {
      string ts=Tune_NormSym(allTrades[i].sym);
      if(ts!=symNorm) continue;
      datetime ct=allTrades[i].closeTime;
      if(ct<=watermark) continue;
      cnt++;
      if(ct>lastCloseOut) lastCloseOut=ct;
   }
   return cnt;
}

bool Tune_IsSecondSaturday(const datetime t)
{
   MqlDateTime dt; TimeToStruct(t, dt);
   if(dt.day_of_week!=6) return false; // Saturday
   if(dt.day<8 || dt.day>14) return false; // 2nd Saturday window
   return true;
}

int Tune_DateKey(const datetime t)
{
   MqlDateTime dt; TimeToStruct(t, dt);
   return dt.year*10000 + dt.mon*100 + dt.day;
}

bool Tune_IsMonthlyRunWindow(const datetime t)
{
   if(!Tune_IsSecondSaturday(t)) return false;
   MqlDateTime dt; TimeToStruct(t, dt);
   int m0 = dt.hour*60 + dt.min;
   int target = InpTune_RunHour*60 + InpTune_RunMinute;
   return (m0>=target && m0 < target + MathMax(1,InpTune_RunWindowMinutes));
}

bool Tune_WriteOverrideRow(const string symNorm, const SymbolOverrides &ovr)
{
   // Rewrite overrides CSV, preserving existing comment/header lines.
   string fn=InpSymbolOverrides_File;
   int commonFlag = InpSymbolOverrides_UseCommonFolder ? FILE_COMMON : 0;

   string lines[];
   ArrayResize(lines,0);

   if(FileIsExist(fn, commonFlag))
   {
      int hr=FileOpen(fn, FILE_READ|FILE_TXT|FILE_ANSI | commonFlag);
      if(hr!=INVALID_HANDLE)
      {
         while(!FileIsEnding(hr))
         {
            string line;
            if(!FileReadLineTxt(hr,line)) break;
            ArrayResize(lines, ArraySize(lines)+1);
            lines[ArraySize(lines)-1]=line;
         }
         FileClose(hr);
      }
   }

   if(ArraySize(lines)==0)
   {
      ArrayResize(lines,1);
      lines[0]="#symbol;maxSpreadPips;minATR_Pips;minADXTrend;minADXEntry;minBodyPips;slATRMult;tpRR;useBreakPrev;allowBuy;allowSell;usePullbackEMA";
   }

   string newLine = symNorm + ";" +
                    DoubleToString(ovr.maxSpreadPips,2) + ";" +
                    DoubleToString(ovr.minATR_Pips,2) + ";" +
                    DoubleToString(ovr.minADXTrend,2) + ";" +
                    DoubleToString(ovr.minADXEntry,2) + ";" +
                    DoubleToString(ovr.minBodyPips,2) + ";" +
                    DoubleToString(ovr.slATRMult,2) + ";" +
                    DoubleToString(ovr.tpRR,2) + ";" +
                    (string)ovr.useBreakPrev + ";" +
                    (string)ovr.allowBuy + ";" +
                    (string)ovr.allowSell + ";" +
                    (string)ovr.usePullbackEMA;

   bool replaced=false;
   for(int i=0;i<ArraySize(lines);i++)
   {
      string lt=TrimStr(lines[i]);
      if(lt=="" || StringGetCharacter(lt,0)=='#') continue;

      string f[];
      int n=SplitCSV(lt,f);
      if(n<1) continue;

      string s0=Tune_NormSym(f[0]);
      if(s0==symNorm)
      {
         lines[i]=newLine;
         replaced=true;
         break;
      }
   }

   if(!replaced)
   {
      int n=ArraySize(lines);
      ArrayResize(lines,n+1);
      lines[n]=newLine;
   }

   int hw=FileOpen(fn, FILE_WRITE|FILE_TXT|FILE_ANSI | commonFlag);
   if(hw==INVALID_HANDLE) return false;

   for(int i=0;i<ArraySize(lines);i++)
      FileWriteString(hw, lines[i]+"\r\n");

   FileClose(hw);
   return true;
}

void Tune_StartTrial(const string symNorm, TuneStateRow &row, const SymbolOverrides &newOvr)
{
   // Capture baseline + watermark at the moment the overrides change is detected
   ClosedTradeRec allTrades[];
   int nAll=BuildClosedTradesFromHistory(allTrades);
   if(nAll>0) SortTradesByCloseTime(allTrades);

   row.prev_ovr = row.active_ovr;
   row.prev_sig = row.active_sig;

   row.active_ovr = newOvr;
   row.active_sig = Tune_OvrSig(newOvr);

   row.trial_active=true;
   row.trial_start_time=TimeCurrent();

   row.trial_close_watermark = Tune_LastCloseBefore(allTrades, symNorm, row.trial_start_time);
   if(row.trial_close_watermark==0) row.trial_close_watermark = row.trial_start_time;

   // Baseline = last N closed positions BEFORE change
   TunePerf base;
   Tune_PerfFromTrades(allTrades, symNorm, 0, row.trial_start_time, MathMax(10,InpTune_BaselineTrades), base);

   row.base_trades = base.trades;
   row.base_pf     = base.pf;
   row.base_dd     = base.maxDD;
   row.base_avgr   = base.avgR;
   row.base_net    = base.net;

   // Mark trades up to watermark as "used" (gate for next tune proposal)
   if(row.last_used_close < row.trial_close_watermark)
      row.last_used_close = row.trial_close_watermark;

   string msg = StringFormat("[TUNE] New settings detected for %s. Trial started. Baseline: trades=%d PF=%.2f DD=%.2f AvgR=%.3f Net=%.2f",
                             symNorm, row.base_trades, row.base_pf, row.base_dd, row.base_avgr, row.base_net);
   TelegramSendMessage(msg);

   TuneState_Save();
}

void Tune_SyncWithOverrides(const bool onInit=false)
{
   if(!InpTune_Enable) return;

   if(!g_tuneLoaded) TuneState_Load();

   for(int i=0;i<g_symCount;i++)
   {
      string symNorm=Tune_NormSym(g_syms[i]);
      int idx=Tune_EnsureRow(symNorm);

      SymbolOverrides cur;
      if(!Tune_GetCurrentOverrideForSymbol(g_syms[i], cur))
         continue; // no override row -> can't auto-rollback

      cur.sym=symNorm;
      string sig=Tune_OvrSig(cur);

      if(g_tune[idx].active_sig=="")
      {
         g_tune[idx].active_ovr=cur;
         g_tune[idx].active_sig=sig;
         continue;
      }

      if(sig!=g_tune[idx].active_sig)
      {
         Tune_StartTrial(symNorm, g_tune[idx], cur);
      }
   }

   if(onInit) TuneState_Save();
}

void Tune_HandleRollback(const string symNorm, TuneStateRow &row, const TunePerf &trial)
{
   string msg=StringFormat("[TUNE][ROLLBACK] %s: Trial FAILED. Baseline(PF=%.2f DD=%.2f AvgR=%.3f) -> Trial(PF=%.2f DD=%.2f AvgR=%.3f trades=%d).",
                           symNorm, row.base_pf, row.base_dd, row.base_avgr, trial.pf, trial.maxDD, trial.avgR, trial.trades);

   TelegramSendMessage(msg);

   if(!InpTune_Rollback_AutoApply)
   {
      if(InpTune_Rollback_StopEntries)
         FailSafe_Trip("Tune rollback recommended");
      row.trial_active=false;
      TuneState_Save();
      return;
   }

   if(row.prev_sig=="" || row.prev_sig==row.active_sig)
   {
      TelegramSendMessage(StringFormat("[TUNE][ROLLBACK] %s: No previous settings stored. Stopping entries.", symNorm));
      FailSafe_Trip("Tune rollback no prev");
      row.trial_active=false;
      TuneState_Save();
      return;
   }

   if(!Tune_WriteOverrideRow(symNorm, row.prev_ovr))
   {
      TelegramSendMessage(StringFormat("[TUNE][ROLLBACK] %s: FAILED to write overrides file. Stopping entries.", symNorm));
      FailSafe_Trip("Tune rollback write failed");
      row.trial_active=false;
      TuneState_Save();
      return;
   }

   // reload overrides so EA uses them immediately (if hot reload is enabled)
   LoadSymbolOverrides();


   row.active_ovr = row.prev_ovr;
   row.active_sig = row.prev_sig;
   row.trial_active=false;

   TuneState_Save();

   TelegramSendMessage(StringFormat("[TUNE][ROLLBACK] %s: Previous settings restored.", symNorm));
}

void Tune_HandleAccept(const string symNorm, TuneStateRow &row, const TunePerf &trial)
{
   row.trial_active=false;
   TuneState_Save();

   string msg=StringFormat("[TUNE][ACCEPT] %s: Trial PASSED. Baseline(PF=%.2f DD=%.2f AvgR=%.3f) -> Trial(PF=%.2f DD=%.2f AvgR=%.3f trades=%d).",
                           symNorm, row.base_pf, row.base_dd, row.base_avgr, trial.pf, trial.maxDD, trial.avgR, trial.trades);
   TelegramSendMessage(msg);
}

void Tune_MaybeCheckRollback()
{
   if(!InpTune_Enable) return;
   if(!InpTune_Rollback_Enable) return;

   datetime now=TimeCurrent();
   if(now < g_tuneNextHeavyCheck) return;
   g_tuneNextHeavyCheck = now + MathMax(30, InpTune_CheckEverySec);

   ClosedTradeRec allTrades[];
   int nAll=BuildClosedTradesFromHistory(allTrades);
   if(nAll<=0) return;
   SortTradesByCloseTime(allTrades);

   for(int i=0;i<ArraySize(g_tune);i++)
   {
      // NOTE: MQL does not support local references like `TuneStateRow &row = g_tune[i];`
      // so we access the array element directly.
      if(!g_tune[i].trial_active) continue;
      if(g_tune[i].trial_start_time==0) continue;

      int days=(int)((now - g_tune[i].trial_start_time)/86400);
      if(days < InpTune_Rollback_MinDays) continue;

      TunePerf trial;
      Tune_PerfFromTrades(allTrades, g_tune[i].sym, g_tune[i].trial_close_watermark, 0, 0, trial);

      if(trial.trades < InpTune_Rollback_MinTrades) continue;

      bool pfBad = (g_tune[i].base_pf>0.0 && trial.pf < (g_tune[i].base_pf - InpTune_Rollback_PF_Drop - 1e-9));
      bool ddBad = (g_tune[i].base_dd>0.0 && trial.maxDD > g_tune[i].base_dd * (1.0 + InpTune_Rollback_DD_IncreasePct/100.0 + 1e-9));
      bool rBad  = (trial.avgR < (g_tune[i].base_avgr - InpTune_Rollback_AvgR_Drop - 1e-9));

      if(pfBad || ddBad || rBad)
         Tune_HandleRollback(g_tune[i].sym, g_tune[i], trial);
      else
         Tune_HandleAccept(g_tune[i].sym, g_tune[i], trial);
   }
}

void Tune_MaybeMonthlyNotify()
{
   if(!InpTune_Enable) return;
   if(!InpTune_MonthlyNotify_Enable) return;

   datetime t=TimeLocal(); // schedule based on terminal local time
   if(!Tune_IsMonthlyRunWindow(t)) return;

   int key=Tune_DateKey(t);
   if(key==g_tune_lastMonthlyRunKey) return;
   g_tune_lastMonthlyRunKey=key;

   if(!g_tuneLoaded) TuneState_Load();

   ClosedTradeRec allTrades[];
   int nAll=BuildClosedTradesFromHistory(allTrades);
   if(nAll<=0)
   {
      TelegramSendMessage("[TUNE] Monthly check: no closed trades found in history.");
      return;
   }
   SortTradesByCloseTime(allTrades);

   string msg="[TUNE] Monthly eligibility check (2nd Saturday)\n";
   bool any=false;

   for(int i=0;i<g_symCount;i++)
   {
      string symNorm=Tune_NormSym(g_syms[i]);
      int idx=Tune_FindIdx(symNorm);
      if(idx<0) continue;

      datetime lastCloseUsed=g_tune[idx].last_used_close;
      datetime lastClose=0;
      int cnt=Tune_CountTradesSince(allTrades, symNorm, lastCloseUsed, lastClose);

      if(cnt>=InpProposalTradesPerSymbol)
      {
         any=true;
         msg += StringFormat("%s: %d new trades (since %s)\n", symNorm, cnt, TimeToString(lastCloseUsed, TIME_DATE|TIME_MINUTES));
      }
   }

   if(any)
      TelegramSendMessage(msg + "Ready to run TRAIN/OOS optimization.");
   else
      TelegramSendMessage(msg + "No symbol has enough NEW trades yet.");
}


// News-aware trailing spike detection (no API)
// -----------------------------------------
bool IsRolloverTime()
{
   // heuristic: around 23:58-00:05 server time
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.hour==23 && dt.min>=55) return true;
   if(dt.hour==0 && dt.min<=10) return true;
   return false;
}

bool DetectNewsSpike(const string sym, const int symIdx, const double atrPips)
{
   if(!InpUseNewsAwareTrailing) return false;
   if(InpIgnoreNewsTriggersDuringRollover && IsRolloverTime()) return false;

   // NEW: optional minimum ATR gate to avoid low-ATR false positives
   if(InpNewsSpike_MinATRPips>0.0 && atrPips <= InpNewsSpike_MinATRPips) return false;
   if(atrPips<=0.0) return false; // NEW: guard against indicator/data not ready
   // cooldown
   datetime now=TimeCurrent();
   if(g_sym[symIdx].lastNewsSpike>0 && (now - g_sym[symIdx].lastNewsSpike) < (InpNewsSpike_CooldownMin*60))
      return false;

   // spike: current candle range vs ATR
   MqlRates r[2];
   if(!CopyRatesLast(sym, InpEntryTF, 0, 2, r)) return false;
   double pip=PipSize(sym);
   if(pip<=0) return false;
   double rangePips=(r[0].high - r[0].low)/pip;

   if(rangePips >= atrPips * InpNewsSpike_ATR_Mult)
   {
      g_sym[symIdx].lastNewsSpike=now;
      return true;
   }
   return false;
}


// --- Volatility percentile filter (v18): block entries when volatility is too low
bool VolPctFilter_Block(const int symIdx, const string sym)
{
   if(!InpVolPctFilter_Enable) return false;
   if(symIdx < 0 || symIdx >= g_symCount) return false;
   if(g_atrHandle[symIdx] == INVALID_HANDLE) return false;

   int shortN  = MathMax(5,  InpVolPctFilter_Period);
   int baseN   = MathMax(20, InpVolPctFilter_Base);

   double shortBuf[], baseBuf[];
   ArraySetAsSeries(shortBuf, true);
   ArraySetAsSeries(baseBuf,  true);

   if(CopyBuffer(g_atrHandle[symIdx], 0, 0, shortN,  shortBuf) < shortN)  return false;
   if(CopyBuffer(g_atrHandle[symIdx], 0, 0, baseN,   baseBuf)  < baseN)   return false;

   double curATR = shortBuf[0];
   if(curATR <= 0.0) return false;

   int below = 0, total = 0;
   for(int i = 1; i < baseN; i++)
   {
      if(baseBuf[i] <= 0.0) continue;
      total++;
      if(baseBuf[i] >= curATR) below++;   // curATR is <= baseBuf[i], so curATR ranks lower
   }
   if(total < 10) return false;  // not enough data
   double pct = (double)below / total * 100.0;
   return (pct >= (100.0 - InpVolPctFilter_Threshold));  // blocked when in bottom X%
}

// --- Smart order routing: only enter when spread/ATR ratio is acceptable
bool SmartOrderRoute_IsLiquid(const int symIdx, const string sym, const double atrPips)
{
   if(!InpSmartOrderRoute) return true;  // disabled -> always allow
   if(atrPips <= 0.0) return true;
   double sp = SpreadPips(sym);
   double ratio = sp / atrPips;
   bool liquid = (ratio <= InpSOR_SpreadATRRatio);
   if(!liquid && InpDebug)
      PrintFormat("SOR_ILLIQUID %s spread=%.2f atr=%.2f ratio=%.3f (max=%.3f)",
                  sym, sp, atrPips, ratio, InpSOR_SpreadATRRatio);
   return liquid;
}


// -----------------------------------------
// extracted to MSPB_EA_Entry.mqh

// -----------------------------------------
// ProcessSymbol
// -----------------------------------------
void ProcessSymbol(const int idx, const string sym)
{
   // fail-safe stop entries
   if(g_failSafeStopEntries)
   {
      IncReject(idx, REJ_FAILSAFE);
      return;
   }

   // P5-17: Telegram /pause command
   if(TG_IsPaused())
   {
      IncReject(idx, REJ_FAILSAFE);
      return;
   }

   // v20-D10: Weekly symbol rank filter
   if(InpUseWeeklySymbolRank && !g_sym[idx].rankEnabled)
   {
      IncReject(idx, REJ_FAILSAFE);
      return;
   }

   // v20-B6: per-symbol auto-disable on negative expectancy
   if(AutoDisable_IsBlocked(idx))
   {
      IncReject(idx, REJ_COOLDOWN);
      if(InpDebug) PrintFormat("AUTO_DISABLE_BLOCK %s until %s",
                               sym, TimeToString(g_sym[idx].autoDisabledUntil, TIME_DATE|TIME_MINUTES));
      return;
   }

   // once-per-bar guard on entryTF
   if(!IsNewBar(idx, sym, InpEntryTF))
   {
      IncReject(idx, REJ_NEWBAR);
      return;
   }

   // P3-8: weekday filter
   if(!WeekdayAllows())
   {
      IncReject(idx, REJ_SESSION);
      return;
   }

   // P3-9: weekly loss limit
   if(!WeeklyLossAllows())
   {
      IncReject(idx, REJ_RISK_GUARDS);
      return;
   }

   if(!SessionAllows())
   {
      IncReject(idx, REJ_SESSION);
      return;
   }

   // price snapshot (cached per cycle)
   double bid=0.0, ask=0.0;
   if(!GetBidAskCached(idx, sym, bid, ask))
   {
      IncReject(idx, REJ_SPREAD);
      return;
   }
   double spreadPips = SpreadPipsPrices(sym, bid, ask);
   if(!SpreadAllowsPrices(sym, bid, ask))
   {
      IncReject(idx, REJ_SPREAD);
      return;
   }

   // News blocking entries (calendar)
   int nImp; string nEv; int nMin;
   if(InpNews_Enable && (InpAvoidEntriesDuringNews || InpNews_BlockEntries))
   {
      if(News_IsBlockedForSymbol(sym, nImp, nEv, nMin))
      {
         IncReject(idx, REJ_NEWS_STATE);
         if(InpDebug) PrintFormat("NEWS_BLOCK_ENTRY %s imp=%d ev=%s min=%d", sym, nImp, nEv, nMin);
         return;
      }
   }


   // v10: per-symbol cooldown after exits
   if(InpUseSymbolCooldown && g_sym[idx].cooldownUntil>0 && TimeCurrent() < g_sym[idx].cooldownUntil)
   {
      IncReject(idx, REJ_COOLDOWN);
      return;
   }

   // P3-10: bar-based SL cooldown
   if(PostSL_CooldownBars_IsActive(idx, sym))
   {
      IncReject(idx, REJ_COOLDOWN);
      return;
   }

   // max positions (single-pass count)
   int openSym=0, openTot=0;
   CountOpenPositionsOurMagicBoth(sym, openSym, openTot);

   // v20-A4: Pyramid re-entry — add a micro-lot to an existing BE position
   // Condition: R1 TP hit + BE stop set + openSym already has a position
   if(InpUsePyramiding && openSym > 0 && openSym < InpMaxPositionsPerSymbol &&
      g_sym[idx].ladderR1Done && g_sym[idx].pyramidCount < InpPyramid_MaxAdds)
   {
      // Check if the existing position has BE set
      bool hasBE = false;
      for(int pi=PositionsTotal()-1; pi>=0; pi--)
      {
         ulong pTick2 = PositionGetTicket(pi);
         if(pTick2==0 || !PositionSelectByTicket(pTick2)) continue;
         if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         if(PositionGetString(POSITION_SYMBOL) != sym) continue;
         double pSL2   = PositionGetDouble(POSITION_SL);
         double pOpen2 = PositionGetDouble(POSITION_PRICE_OPEN);
         long   pType2 = PositionGetInteger(POSITION_TYPE);
         // BE is set if SL >= openPrice (for BUY) or SL <= openPrice (for SELL)
         bool beBuy  = (pType2==POSITION_TYPE_BUY  && pSL2 >= pOpen2 - 1e-9);
         bool beSell = (pType2==POSITION_TYPE_SELL && pSL2 <= pOpen2 + 1e-9);
         if(beBuy || beSell) { hasBE = true; break; }
      }

      if(hasBE)
      {
         // Compute pyramid SL/TP using pullback to current EMA if available
         double bid2=0, ask2=0;
         GetBidAskCached(idx, sym, bid2, ask2);
         double atrBuf2[2]; double atrPips2=0;
         if(CopyLast(g_atrHandle[idx],0,0,2,atrBuf2))
            atrPips2 = atrBuf2[0] / MathMax(PipSize(sym), 1e-9);
         if(atrPips2 > 0 && bid2 > 0 && ask2 > 0)
         {
            bool pyrBuy = false;
            // Determine pyramid direction from existing position
            for(int pi=PositionsTotal()-1; pi>=0; pi--)
            {
               ulong pTick3 = PositionGetTicket(pi);
               if(pTick3==0 || !PositionSelectByTicket(pTick3)) continue;
               if((long)PositionGetInteger(POSITION_MAGIC)!= InpMagic) continue;
               if(PositionGetString(POSITION_SYMBOL) != sym) continue;
               pyrBuy = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
               break;
            }
            double pyrEntry = pyrBuy ? ask2 : bid2;
            double pyrSL    = ComputeSL(sym, pyrBuy, pyrEntry, atrPips2);
            pyrSL = ClampSLToStopsLevel(sym, pyrBuy?POSITION_TYPE_BUY:POSITION_TYPE_SELL, pyrEntry, pyrSL);
            double pyrTP    = ComputeTP_Smart(sym, pyrBuy, pyrEntry, pyrSL);

            double pyrRMult = (InpPyramid_RiskPct / MathMax(InpRiskPercent, 1e-9));
            double pyrLots, pyrRiskMoney;
            if(CalcRiskLotsEx(sym, pyrEntry, pyrSL, pyrRMult * g_riskMult, pyrLots, pyrRiskMoney) && pyrLots > 0)
            {
               trade.SetExpertMagicNumber((long)InpMagic);
               int devPts3 = AdaptiveDeviationPointsPrices(sym, bid2, ask2, atrPips2);
               trade.SetDeviationInPoints(devPts3);
               bool pyrOk = pyrBuy ? trade.Buy(pyrLots, sym, 0.0, pyrSL, pyrTP, "PYRAMID")
                                   : trade.Sell(pyrLots, sym, 0.0, pyrSL, pyrTP, "PYRAMID");
               if(pyrOk)
               {
                  g_sym[idx].pyramidCount++;
                  Audit_Log("PYRAMID_ADD",
                            StringFormat("sym=%s|lots=%.2f|pyramidN=%d|sl=%s",
                                         sym, pyrLots, g_sym[idx].pyramidCount,
                                         FmtPriceSym(sym, pyrSL)),
                            false);
               }
            }
         }
      }
   }

   if(openSym >= InpMaxPositionsPerSymbol) return;
   if(openTot >= InpMaxPositionsTotal) return;
   // compute signals
   bool isBuy1; double adxTrend, adxEntry, atrPips, bodyPips;
   bool ok1 = EntrySignal_Setup1(idx, sym, isBuy1, adxTrend, adxEntry, atrPips, bodyPips);
   if(!ok1) return;

   // ATR filter
   if(InpUseATRFilter && atrPips < Sym_MinATR_Pips(sym))
   {
      IncReject(idx, REJ_ATR_MIN);
      return;
   }

   // ADX filters
   if(InpUseADXFilter && adxTrend < Sym_MinADXTrend(sym))
   {
      IncReject(idx, REJ_ADX_TREND_MIN);
      return;
   }
   if(InpUseADXFilter && adxEntry < Sym_MinADXEntry(sym))
   {
      IncReject(idx, REJ_ADX_ENTRY_MIN);
      return;
   }

   // body filter
   if(InpUseBodyFilter && bodyPips < Sym_MinBodyPips(sym))
   {
      IncReject(idx, REJ_BODY_MIN);
      return;
   }

   // BreakPrev logic: Setup2 only if setup1 fails by breakPrev
   bool breakOk = BreakPrevHighLow(sym,isBuy1,Sym_UseBreakPrev(sym));
   bool useSetup2=false;
   bool isBuy=isBuy1;
   string setup="S1";

   if(!breakOk)
   {
      if(InpUseSetup2)
      {
         bool isBuy2=false;
         if(EntrySignal_Setup2(idx, sym, isBuy2))
         {
            useSetup2=true;
            isBuy=isBuy2;
            setup="S2";
         }
      }
      // HOTFIX: only count BreakPrev rejection when we *actually* reject (no Setup2 fallback)
      if(!useSetup2)
      {
         IncReject(idx, REJ_BREAKPREV_FAIL);
         return;
      }
   }

   // direction allowed
   if(isBuy && !Sym_AllowBuy(sym)) return;
   if(!isBuy && !Sym_AllowSell(sym)) return;

   // v9: volatility regime (ATR percentile)
   double volMult=1.0; bool volBlock=false; double volPct=50.0;
   VolRegime_Get(idx, sym, volMult, volBlock, volPct);
   if(volBlock)
   {
      IncReject(idx, REJ_VOL_REGIME);
      if(InpDebug) PrintFormat("VOL_BLOCK_ENTRY %s pct=%.1f tf=%s", sym, volPct, EnumToString(InpVolRegimeTF));
      return;
   }

   // v18: volatility percentile filter
   if(VolPctFilter_Block(idx, sym))
   {
      IncReject(idx, REJ_VOL_REGIME);
      return;
   }

   // v9: higher timeframe bias filter
   if(InpUseHTFBias)
   {
      double bf=0.0, bs=0.0;
      int bdir = GetBiasDirCached(idx, sym, bf, bs);
      if(bdir==99)
      {
         IncReject(idx, REJ_BIAS_FAIL);
         if(InpDebug) PrintFormat("BIAS_NOT_READY %s tf=%s", sym, EnumToString(InpBiasTF));
         return;
      }
      if(bdir>0 && !isBuy) { IncReject(idx, REJ_BIAS_FAIL); return; }
      if(bdir<0 &&  isBuy) { IncReject(idx, REJ_BIAS_FAIL); return; }
   }

   // P2-7: ultra-HTF (third TF) bias filter
   if(InpUseUltraHTFBias)
   {
      if(g_ultraBiasFastHandle[idx] == INVALID_HANDLE || g_ultraBiasSlowHandle[idx] == INVALID_HANDLE)
      {
         IncReject(idx, REJ_BIAS_FAIL);
         if(InpDebug) PrintFormat("ULTRA_BIAS_NOT_READY %s tf=%s", sym, EnumToString(InpUltraBiasTF));
         return;
      }
      double ubf[2], ubs[2];
      bool ubfOk = CopyLast(g_ultraBiasFastHandle[idx], 0, 0, 2, ubf);
      bool ubsOk = CopyLast(g_ultraBiasSlowHandle[idx], 0, 0, 2, ubs);
      if(!ubfOk || !ubsOk)
      {
         IncReject(idx, REJ_BIAS_FAIL);
         return;
      }
      int ubdir = (ubf[1] > ubs[1]) ? 1 : ((ubf[1] < ubs[1]) ? -1 : 0);
      if(ubdir > 0 && !isBuy) { IncReject(idx, REJ_BIAS_FAIL); return; }
      if(ubdir < 0 &&  isBuy) { IncReject(idx, REJ_BIAS_FAIL); return; }
   }

   // P2-5: dynamic spread/ATR filter (applies to all setups when enabled)
   if(InpUseDynamicSpreadFilter && atrPips > 0.0)
   {
      double dynRatio = spreadPips / atrPips;
      if(dynRatio > InpDynSpread_ATRRatio)
      {
         IncReject(idx, REJ_SPREAD);
         if(InpDebug) PrintFormat("DYN_SPREAD_BLOCK %s spread=%.2f atr=%.2f ratio=%.3f (max=%.3f)",
                                  sym, spreadPips, atrPips, dynRatio, InpDynSpread_ATRRatio);

         // v20-C8: place pending limit order at signal price with TTL
         if(InpUseLimitOnSpreadBlock && !PendingLimits_HasFor(sym))
         {
            double limEntry = isBuy ? ask : bid;
            double limSL    = ComputeSL(sym, isBuy, limEntry, atrPips);
            limSL = ClampSLToStopsLevel(sym, isBuy?POSITION_TYPE_BUY:POSITION_TYPE_SELL, limEntry, limSL);
            double limTP    = ComputeTP_Smart(sym, isBuy, limEntry, limSL);
            double limLots, limRiskMoney;
            double limRMult = g_riskMult * volMult;
            double limE2    = isBuy ? ask : bid;
            if(CalcRiskLotsEx(sym, limE2, limSL, limRMult, limLots, limRiskMoney) && limLots > 0)
            {
               trade.SetExpertMagicNumber((long)InpMagic);
               int devPts2 = AdaptiveDeviationPointsPrices(sym, bid, ask, atrPips);
               trade.SetDeviationInPoints(devPts2);
               bool limOk = false;
               if(isBuy)  limOk = trade.BuyLimit(limLots, limEntry, sym, limSL, limTP, ORDER_TIME_SPECIFIED,
                                                  TimeCurrent() + InpLimitOrderTTL_Min*60, "LIM_SPREAD");
               else       limOk = trade.SellLimit(limLots, limEntry, sym, limSL, limTP, ORDER_TIME_SPECIFIED,
                                                   TimeCurrent() + InpLimitOrderTTL_Min*60, "LIM_SPREAD");
               if(limOk)
               {
                  ulong limTicket = trade.ResultOrder();
                  PendingLimits_Add(limTicket, sym, TimeCurrent() + InpLimitOrderTTL_Min*60);
                  if(InpDebug) PrintFormat("LIMIT_ON_SPREAD_BLOCK %s %s lots=%.2f price=%s ttl=%dm",
                                           sym, (isBuy?"BUY":"SELL"), limLots, FmtPriceSym(sym, limEntry),
                                           InpLimitOrderTTL_Min);
               }
            }
         }
         return;
      }
   }


   // combined risk multiplier (equity regime * vol regime)
   double tradeRiskMult = g_riskMult * volMult;

   // v20-B7: apply Kelly fraction multiplier to risk
   double kellyMult = Kelly_GetMult(idx);
   if(InpUseKellyScaling && kellyMult != 1.0)
      tradeRiskMult *= kellyMult;

   // v20-A1: ML entry gate (block if weighted feature score < threshold)
   if(InpUseMLEntryGate && g_mlGateLoaded)
   {
      double mlScore = MLGate_Score(atrPips, adxTrend, adxEntry, spreadPips, bodyPips, tradeRiskMult);
      if(mlScore < MathMax(0.0, InpML_MinScore))
      {
         IncReject(idx, REJ_BIAS_FAIL);
         if(InpDebug) PrintFormat("ML_GATE_BLOCK %s score=%.4f < min=%.4f", sym, mlScore, InpML_MinScore);
         return;
      }
   }

   double entry = isBuy ? ask : bid;

   double sl = ComputeSL(sym, isBuy, entry, atrPips);
   sl = ClampSLToStopsLevel(sym, isBuy?POSITION_TYPE_BUY:POSITION_TYPE_SELL, entry, sl);
   double tp = ComputeTP_Smart(sym, isBuy, entry, sl);

   // v20-C9: micro-delay after bar open (reduces slippage at volatile openings)
   if(InpEntryDelay_Ms > 0)
      Sleep(InpEntryDelay_Ms);

   // risk lots
   double lots, riskMoney;
   if(isBuy)
   {
      if(!CalcRiskLotsEx(sym, ask, sl, tradeRiskMult, lots, riskMoney))
      {
         IncReject(idx, REJ_RISK_GUARDS);
         if(InpDebug) PrintFormat("RISK_LOTS_FAIL %s BUY | entry=%.5f sl=%.5f", sym, ask, sl);
         Status_SetTrade("RISK_LOTS_FAIL", -1, sym);
         return;
      }
      else
      {
         // resync riskMoney with rounded volume (portfolio guard wants actual risk)
         const double _riskBudget = riskMoney;
         const double _riskActual = PositionRiskMoney(sym, ask, sl, lots);
         if(_riskActual > 0.0) riskMoney = _riskActual;
         else riskMoney = _riskBudget;
      }

      // News risk scaling (optional, per impact)
      if(InpNews_Enable && InpNews_UseRiskScaling)
      {
         string nwhy="";
         double nmult = News_RiskMultiplier(sym, nwhy);
         if(nmult <= 0.0) { IncReject(idx, REJ_NEWS_STATE); return; }
         if(nmult < 0.999)
         {
            double scaledLots = lots * nmult;
            double floored = NormalizeVolumeFloor(sym, scaledLots);
            if(floored <= 0.0)
            {
               IncReject(idx, REJ_NEWS_STATE);
               if(InpDebug) PrintFormat("NEWS_RISK_LOTS_BELOW_MIN %s BUY | mult=%.3f scaled=%.4f why=%s", sym, nmult, scaledLots, nwhy);
               Status_SetTrade("NEWS_RISK_LOTS_BELOW_MIN", -1, nwhy);
               return;
            }
            lots = floored;
            const double _riskAfter = PositionRiskMoney(sym, ask, sl, lots);
            if(_riskAfter > 0.0) riskMoney = _riskAfter;
            else riskMoney *= nmult;
         }
      }
      if(lots <= 0.0) { IncReject(idx, REJ_NEWS_STATE); return; }

      // portfolio risk guard
      if(!PortfolioRiskAllows(riskMoney))
      {
         IncReject(idx, REJ_RISK_GUARDS);
         return;
      }

      // v11: correlation exposure guard (direction-aware + weighted by lots)
      if(InpUseCorrelationGuard)
      {
         string cdet="";
         if(!CorrelationAllowsEntry(idx, sym, (isBuy?1:-1), lots, cdet))
         {
            IncReject(idx, REJ_CORR_GUARD);
            if(InpDebug) PrintFormat("CORR_BLOCK_ENTRY %s %s", sym, cdet);
            return;
         }
      }

      double intendedR = RiskCap_MoneyToR(riskMoney);
      if(!RiskCap_AllowsEntry(idx, sym, "BUY", setup, intendedR, riskMoney))
         return;


      if(!SmartOrderRoute_IsLiquid(idx, sym, atrPips))
      {
         IncReject(idx, REJ_SPREAD);
         return;
      }

      // send order
      trade.SetExpertMagicNumber((long)InpMagic);
      int devPts = AdaptiveDeviationPointsPrices(sym, bid, ask, atrPips);
      trade.SetDeviationInPoints(devPts);
      double priceParam = (InpUseMarketOrdersNoPrice ? 0.0 : entry);
      bool ok = trade.Buy(lots, sym, priceParam, sl, tp, setup);
      int ret=(int)trade.ResultRetcode();
      bool success = (ok || ret==TRADE_RETCODE_DONE || ret==TRADE_RETCODE_DONE_PARTIAL);
      Status_SetTrade("BUY", ret, trade.ResultComment());
      // --- Partial fill detection (D1) ---
      if(ret == TRADE_RETCODE_DONE_PARTIAL)
      {
         double filledVol = trade.ResultVolume();
         if(filledVol > 0.0 && filledVol < lots - 1e-9)
         {
            double actualRisk = PositionRiskMoney(sym, entry, sl, filledVol);
            if(InpDebug) PrintFormat("PARTIAL_FILL %s BUY: requested=%.2f filled=%.2f riskAdj=%.2f",
                                     sym, lots, filledVol, actualRisk);
            Audit_Log("PARTIAL_FILL",
                      StringFormat("sym=%s|dir=BUY|requested=%.2f|filled=%.2f|risk_adj=%.2f",
                                   sym, lots, filledVol, actualRisk),
                      false);
         }
      }

      // --- Slippage tracking (D2) ---
      if(success && trade.ResultPrice() > 0.0)
      {
         double slipPips = (trade.ResultPrice() - entry) / MathMax(PipSize(sym), 1e-9);
         // P5-16: accumulate slippage stats for OnTester score
         g_totalSlippagePips += MathAbs(slipPips);
         g_slippageCount++;
         int sess = GetCurrentSession();
         string sessName = (sess==0?"Asia":(sess==1?"London":(sess==2?"NY":"Other")));
         if(InpDebug) PrintFormat("SLIPPAGE %s BUY: intended=%.5f filled=%.5f slip=%.2fpips sess=%s",
                                  sym, entry, trade.ResultPrice(), slipPips, sessName);
         if(InpEnableMLExport)
         {
            ML_WriteRowV2("slippage", NowStr(), sym, setup, "BUY",
                         entry, sl, tp, lots, riskMoney,
                         atrPips, adxTrend, adxEntry, spreadPips, bodyPips,
                         "", StringFormat("slip_pips=%.3f|sess=%s", slipPips, sessName),
                         (long)trade.ResultDeal(), "SLIPPAGE", 0,0,tradeRiskMult,
                         0, StringFormat("slip=%.3f|sess=%s", slipPips, sessName), g_mlSchema);
         }
      }


      if(InpEnableMLExport)
      {
         if(success || InpMLLogFailedOrders)
         {
            string rid = (success ? "entry" : "entry_fail");
            string ev  = (success ? "ENTRY" : "ENTRY_FAIL");
            long pid   = (success ? (long)trade.ResultDeal() : 0);
            string rr  = (success ? "" : "ORDER_FAIL");
            string rd  = (success ? "" : ("ret="+(string)ret));
            string cmt = (success ? ("deal="+(string)trade.ResultDeal()+"|"+Shorten(trade.ResultComment(),60))
                             : ("ret="+(string)ret+"|"+Shorten(trade.ResultComment(),60)));

            ML_WriteRowV2(rid, NowStr(), sym, setup, "BUY",
                         entry, sl, tp, lots, riskMoney,
                         atrPips, adxTrend, adxEntry, spreadPips, bodyPips,
                         rr, rd,
                         pid, ev, 0,0,tradeRiskMult,
                         0, cmt, g_mlSchema);
         }
      }

      if(ok)
      {
         Audit_Log("ENTRY_BUY",
                   StringFormat("sym=%s|setup=%s|lots=%.2f|sl=%s|tp=%s",
                                sym, setup, lots,
                                FmtPriceSym(sym, sl),
                                FmtPriceSym(sym, tp)),
                   false);

         if(InpEnableTelegram && InpTGNotifyEntries)
         {
            int d=(int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
            TelegramSendMessage(StringFormat("ENTRY %s %s BUY | lots=%.2f | entry=%s | SL=%s | TP=%s",
                                             sym, setup, lots,
                                             DoubleToString(entry,d),
                                             DoubleToString(sl,d),
                                             DoubleToString(tp,d)));
         }

         // v20-A4: initialise pyramid tracking for this new position
         if(InpUsePyramiding && g_sym[idx].pyramidCount == 0)
         {
            double pip2 = PipSize(sym);
            double initRisk2 = (pip2 > 0 && sl > 0) ? MathAbs(entry - sl) / pip2 : 0.0;
            g_sym[idx].ladderPosId   = (long)trade.ResultDeal();
            g_sym[idx].ladderInitRisk = initRisk2;
            g_sym[idx].ladderVolInit  = lots;
            g_sym[idx].ladderR1Done   = false;
            g_sym[idx].ladderR2Done   = false;
         }
      }
   }
   else
   {
      if(!CalcRiskLotsEx(sym, bid, sl, tradeRiskMult, lots, riskMoney))
      {
         IncReject(idx, REJ_RISK_GUARDS);
         if(InpDebug) PrintFormat("RISK_LOTS_FAIL %s SELL | entry=%.5f sl=%.5f", sym, bid, sl);
         Status_SetTrade("RISK_LOTS_FAIL", -1, sym);
         return;
      }
      else
      {
         const double _riskBudget = riskMoney;
         const double _riskActual = PositionRiskMoney(sym, bid, sl, lots);
         if(_riskActual > 0.0) riskMoney = _riskActual;
         else riskMoney = _riskBudget;
      }

      // News risk scaling
      if(InpNews_Enable && InpNews_UseRiskScaling)
      {
         string nwhy="";
         double nmult = News_RiskMultiplier(sym, nwhy);
         if(nmult <= 0.0) { IncReject(idx, REJ_NEWS_STATE); return; }
         if(nmult < 0.999)
         {
            double scaledLots = lots * nmult;
            double floored = NormalizeVolumeFloor(sym, scaledLots);
            if(floored <= 0.0)
            {
               IncReject(idx, REJ_NEWS_STATE);
               if(InpDebug) PrintFormat("NEWS_RISK_LOTS_BELOW_MIN %s SELL | mult=%.3f scaled=%.4f why=%s", sym, nmult, scaledLots, nwhy);
               Status_SetTrade("NEWS_RISK_LOTS_BELOW_MIN", -1, nwhy);
               return;
            }
            lots = floored;
            const double _riskAfter = PositionRiskMoney(sym, bid, sl, lots);
            if(_riskAfter > 0.0) riskMoney = _riskAfter;
            else riskMoney *= nmult;
         }
      }
      if(lots <= 0.0) { IncReject(idx, REJ_NEWS_STATE); return; }

      if(!PortfolioRiskAllows(riskMoney))
      {
         IncReject(idx, REJ_RISK_GUARDS);
         return;
      }

      // v11: correlation exposure guard (direction-aware + weighted by lots)
      if(InpUseCorrelationGuard)
      {
         string cdet="";
         if(!CorrelationAllowsEntry(idx, sym, (isBuy?1:-1), lots, cdet))
         {
            IncReject(idx, REJ_CORR_GUARD);
            if(InpDebug) PrintFormat("CORR_BLOCK_ENTRY %s %s", sym, cdet);
            return;
         }
      }

      double intendedR = RiskCap_MoneyToR(riskMoney);
      if(!RiskCap_AllowsEntry(idx, sym, "SELL", setup, intendedR, riskMoney))
         return;


      if(!SmartOrderRoute_IsLiquid(idx, sym, atrPips))
      {
         IncReject(idx, REJ_SPREAD);
         return;
      }

      trade.SetExpertMagicNumber((long)InpMagic);
      int devPts = AdaptiveDeviationPointsPrices(sym, bid, ask, atrPips);
      trade.SetDeviationInPoints(devPts);
      double priceParam = (InpUseMarketOrdersNoPrice ? 0.0 : entry);
      bool ok = trade.Sell(lots, sym, priceParam, sl, tp, setup);
      int ret=(int)trade.ResultRetcode();
      bool success = (ok || ret==TRADE_RETCODE_DONE || ret==TRADE_RETCODE_DONE_PARTIAL);
      Status_SetTrade("SELL", ret, trade.ResultComment());
      // --- Partial fill detection (D1) ---
      if(ret == TRADE_RETCODE_DONE_PARTIAL)
      {
         double filledVol = trade.ResultVolume();
         if(filledVol > 0.0 && filledVol < lots - 1e-9)
         {
            double actualRisk = PositionRiskMoney(sym, entry, sl, filledVol);
            if(InpDebug) PrintFormat("PARTIAL_FILL %s SELL: requested=%.2f filled=%.2f riskAdj=%.2f",
                                     sym, lots, filledVol, actualRisk);
            Audit_Log("PARTIAL_FILL",
                      StringFormat("sym=%s|dir=SELL|requested=%.2f|filled=%.2f|risk_adj=%.2f",
                                   sym, lots, filledVol, actualRisk),
                      false);
         }
      }

      // --- Slippage tracking (D2) ---
      if(success && trade.ResultPrice() > 0.0)
      {
         double slipPips = (entry - trade.ResultPrice()) / MathMax(PipSize(sym), 1e-9);
         // P5-16: accumulate slippage stats for OnTester score
         g_totalSlippagePips += MathAbs(slipPips);
         g_slippageCount++;
         int sess = GetCurrentSession();
         string sessName = (sess==0?"Asia":(sess==1?"London":(sess==2?"NY":"Other")));
         if(InpDebug) PrintFormat("SLIPPAGE %s SELL: intended=%.5f filled=%.5f slip=%.2fpips sess=%s",
                                  sym, entry, trade.ResultPrice(), slipPips, sessName);
         if(InpEnableMLExport)
         {
            ML_WriteRowV2("slippage", NowStr(), sym, setup, "SELL",
                         entry, sl, tp, lots, riskMoney,
                         atrPips, adxTrend, adxEntry, spreadPips, bodyPips,
                         "", StringFormat("slip_pips=%.3f|sess=%s", slipPips, sessName),
                         (long)trade.ResultDeal(), "SLIPPAGE", 0,0,tradeRiskMult,
                         0, StringFormat("slip=%.3f|sess=%s", slipPips, sessName), g_mlSchema);
         }
      }


      if(InpEnableMLExport)
      {
         if(success || InpMLLogFailedOrders)
         {
            string rid = (success ? "entry" : "entry_fail");
            string ev  = (success ? "ENTRY" : "ENTRY_FAIL");
            long pid   = (success ? (long)trade.ResultDeal() : 0);
            string rr  = (success ? "" : "ORDER_FAIL");
            string rd  = (success ? "" : ("ret="+(string)ret));
            string cmt = (success ? ("deal="+(string)trade.ResultDeal()+"|"+Shorten(trade.ResultComment(),60))
                             : ("ret="+(string)ret+"|"+Shorten(trade.ResultComment(),60)));

            ML_WriteRowV2(rid, NowStr(), sym, setup, "SELL",
                         entry, sl, tp, lots, riskMoney,
                         atrPips, adxTrend, adxEntry, spreadPips, bodyPips,
                         rr, rd,
                         pid, ev, 0,0,tradeRiskMult,
                         0, cmt, g_mlSchema);
         }
      }

      if(ok)
      {
         Audit_Log("ENTRY_SELL",
                   StringFormat("sym=%s|setup=%s|lots=%.2f|sl=%s|tp=%s",
                                sym, setup, lots,
                                FmtPriceSym(sym, sl),
                                FmtPriceSym(sym, tp)),
                   false);

         if(InpEnableTelegram && InpTGNotifyEntries)
         {
            int d=(int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
            TelegramSendMessage(StringFormat("ENTRY %s %s SELL | lots=%.2f | entry=%s | SL=%s | TP=%s",
                                             sym, setup, lots,
                                             DoubleToString(entry,d),
                                             DoubleToString(sl,d),
                                             DoubleToString(tp,d)));
         }

         // v20-A4: initialise pyramid tracking for this new SELL position
         if(InpUsePyramiding && g_sym[idx].pyramidCount == 0)
         {
            double pip2 = PipSize(sym);
            double initRisk2 = (pip2 > 0 && sl > 0) ? MathAbs(entry - sl) / pip2 : 0.0;
            g_sym[idx].ladderPosId    = (long)trade.ResultDeal();
            g_sym[idx].ladderInitRisk = initRisk2;
            g_sym[idx].ladderVolInit  = lots;
            g_sym[idx].ladderR1Done   = false;
            g_sym[idx].ladderR2Done   = false;
         }
      }
   }
}


// -----------------------------------------
// Position management (BE, trailing, time stop, protect)
// -----------------------------------------
int BarsSinceOpen(const string sym, const datetime openTime)
{
   int shift = iBarShift(sym, InpEntryTF, openTime, false);  // exact=false => works for trade openTime
   if(shift<0) return 0;
   return shift;
}

double ProfitPips(const string sym, const long type, const double openPrice, const double bid, const double ask)
{
   double pip=PipSize(sym);
   if(pip<=0.0) return 0.0;
   if(type==POSITION_TYPE_BUY) return (bid-openPrice)/pip;
   else return (openPrice-ask)/pip;
}

void ManagePositions()
{
   int total=PositionsTotal();
   for(int i=total-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;

      string sym=PositionGetString(POSITION_SYMBOL);
      long type=PositionGetInteger(POSITION_TYPE);
      double vol=PositionGetDouble(POSITION_VOLUME);
      double openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      datetime openTime=(datetime)PositionGetInteger(POSITION_TIME);
      long posId=(long)PositionGetInteger(POSITION_IDENTIFIER);
      string setup=PositionGetString(POSITION_COMMENT);

      double floatMoney=PositionGetDouble(POSITION_PROFIT);

      // ATR pips for trailing decisions
      double pip=PipSize(sym);
      bool pipOk = (pip > 0.0);
      double atrBuf[2];
      double atrPips=0.0;
      int symIdx=SymIndexByNameLoose(sym);
      if(symIdx>=0 && symIdx<g_symCount && pipOk && CopyLast(g_atrHandle[symIdx],0,0,2,atrBuf))
            atrPips = atrBuf[0]/pip;

      // price snapshot (cached per cycle; safe if symIdx==-1)
      double bid=0.0, ask=0.0;
      bool haveTick = GetBidAskCached(symIdx, sym, bid, ask);
      double profitPips = (haveTick ? ProfitPips(sym, type, openPrice, bid, ask) : 0.0);

      // initial risk R
      double initRisk=0.0;
      if(pipOk && sl>0) initRisk = MathAbs(openPrice-sl)/pip;
      double floatR = (initRisk>0 ? profitPips/initRisk : 0);

      // news calendar block exits?
      int nImp; string nEv; int nMin;
      bool exitBlockedByNews=false;
      if(News_BlockExitsForSymbol(sym, nImp, nEv, nMin))
         exitBlockedByNews=true;

      // News spike detection (for trailing tighten)
      bool spike=false;
      bool sanityBlock = Sanity_BlockTrailingSpike(symIdx);
      if(!sanityBlock)
         spike=DetectNewsSpike(sym, symIdx, atrPips);

      // Break-even
      if(InpUseBreakEven && haveTick && pipOk && !(spike && InpNewsFreezeBE))
      {
         double move = profitPips;
         if(initRisk>0 && move >= initRisk * InpBE_At_R)
         {
            double lock = InpBE_LockPips;
            double newSL = (type==POSITION_TYPE_BUY ? openPrice + lock*pip : openPrice - lock*pip);
            double pxNow = (type==POSITION_TYPE_BUY ? bid : ask);
            newSL = ClampSLToStopsLevel(sym, type, pxNow, newSL);

            bool improve=false;
            if(type==POSITION_TYPE_BUY && (sl<=0 || newSL>sl + InpBE_MinStepPips*pip)) improve=true;
            if(type==POSITION_TYPE_SELL && (sl<=0 || newSL<sl - InpBE_MinStepPips*pip)) improve=true;

            if(improve)
            {
               string kv=StringFormat("lockPips=%.2f|newSL=%s", lock, FmtPriceSym(sym,newSL));
               ModifySL_Safe(symIdx, sym, ticket, posId, type, setup,
                            sl, tp, vol,
                            openPrice, atrPips,
                            profitPips, floatMoney, floatR,
                            newSL, InpBE_MinStepPips*pip, "BE", kv);
            }
         }
      }

      // Trailing
      if(InpUseATRTrailing && haveTick && pipOk && sl>0 && atrPips>0.0 && !sanityBlock)
      {
         // v20-A3: Chandelier Exit replaces standard ATR trail when enabled
         if(InpUseChandelierExit)
         {
            double chanStop = Chandelier_GetStop(symIdx, sym, type, atrPips);
            if(chanStop > 0.0)
            {
               chanStop = ClampSLToStopsLevel(sym, type, (type==POSITION_TYPE_BUY?bid:ask), chanStop);
               string kvC = StringFormat("chanPer=%d|chanMult=%.2f|level=%s",
                                         InpChandelier_Period, InpChandelier_Mult, FmtPriceSym(sym, chanStop));
               ModifySL_Safe(symIdx, sym, ticket, posId, type, setup,
                            sl, tp, vol,
                            openPrice, atrPips,
                            profitPips, floatMoney, floatR,
                            chanStop, InpTrail_MinStepPips*pip, "CHAN", kvC);
            }
         }
         else
         {
            double trailMult=InpTrail_ATR_Mult;
            if(spike) trailMult *= InpNewsSpike_TightenMult;

            double dist=atrPips * trailMult * pip;
            double desiredSL = (type==POSITION_TYPE_BUY ? bid - dist : ask + dist);
            desiredSL = ClampSLToStopsLevel(sym, type, (type==POSITION_TYPE_BUY?bid:ask), desiredSL);

            string kv=StringFormat("trailMult=%.2f|distPips=%.2f|spike=%s", trailMult, dist/pip, (spike?"Y":"N"));
            ModifySL_Safe(symIdx, sym, ticket, posId, type, setup,
                         sl, tp, vol,
                         openPrice, atrPips,
                         profitPips, floatMoney, floatR,
                         desiredSL, InpTrail_MinStepPips*pip, "TRAIL", kv);
         }
      }

      // v20-A3: after-R3 trailing for ladder remainder (ATR mult override)
      if(InpTP_Ladder_Enable && symIdx>=0 && g_sym[symIdx].ladderR2Done &&
         haveTick && pipOk && sl>0 && atrPips>0.0 && !sanityBlock)
      {
         // Use a more aggressive trail for the remainder after R2
         double r3TrailMult = InpTP_R3_Trail_Mult;
         if(spike) r3TrailMult *= InpNewsSpike_TightenMult;
         double r3Dist = atrPips * r3TrailMult * pip;
         double r3SL   = (type==POSITION_TYPE_BUY ? bid - r3Dist : ask + r3Dist);
         r3SL = ClampSLToStopsLevel(sym, type, (type==POSITION_TYPE_BUY?bid:ask), r3SL);
         string kvR3 = StringFormat("R3trail|mult=%.2f", r3TrailMult);
         ModifySL_Safe(symIdx, sym, ticket, posId, type, setup,
                      sl, tp, vol, openPrice, atrPips,
                      profitPips, floatMoney, floatR,
                      r3SL, InpTrail_MinStepPips*pip, "R3TRAIL", kvR3);
      }

      // v20-A2: TP ladder — partial closes at R1 and R2
      if(InpTP_Ladder_Enable && symIdx>=0 && initRisk>0 && haveTick && pipOk && vol>0)
      {
         bool posTracked = (g_sym[symIdx].ladderPosId == posId);
         if(!posTracked && g_sym[symIdx].ladderPosId == 0)
         {
            // First time we see this position — start tracking
            g_sym[symIdx].ladderPosId    = posId;
            g_sym[symIdx].ladderInitRisk = initRisk;
            g_sym[symIdx].ladderVolInit  = vol;
            g_sym[symIdx].ladderR1Done   = false;
            g_sym[symIdx].ladderR2Done   = false;
            posTracked = true;
         }

         if(posTracked)
         {
            double volInit = (g_sym[symIdx].ladderVolInit > 0 ? g_sym[symIdx].ladderVolInit : vol);

            // R1: close InpTP_R1_ClosePct% at InpTP_R1_R * initRisk pips profit
            if(!g_sym[symIdx].ladderR1Done && profitPips >= initRisk * InpTP_R1_R)
            {
               double r1CloseLots = NormalizeVolumeFloor(sym, volInit * (InpTP_R1_ClosePct / 100.0));
               if(r1CloseLots > 0.0 && r1CloseLots < vol - 1e-9)
               {
                  int devPtsL = (haveTick ? AdaptiveDeviationPointsPrices(sym, bid, ask, atrPips) : MathMax(1, InpDev_MinPoints));
                  trade.SetDeviationInPoints(devPtsL);
                  bool partOk = trade.PositionClosePartial(ticket, r1CloseLots);
                  if(partOk)
                  {
                     g_sym[symIdx].ladderR1Done = true;
                     Audit_Log("LADDER_R1",
                               StringFormat("sym=%s|posId=%I64d|closed=%.2f|pips=%.2f",
                                            sym, posId, r1CloseLots, profitPips),
                               false);
                  }
               }
               else g_sym[symIdx].ladderR1Done = true; // vol too small; skip
            }

            // R2: close InpTP_R2_ClosePct% at InpTP_R2_R * initRisk pips profit
            if(g_sym[symIdx].ladderR1Done && !g_sym[symIdx].ladderR2Done && profitPips >= initRisk * InpTP_R2_R)
            {
               double r2CloseLots = NormalizeVolumeFloor(sym, volInit * (InpTP_R2_ClosePct / 100.0));
               if(r2CloseLots > 0.0 && r2CloseLots < vol - 1e-9)
               {
                  int devPtsL = (haveTick ? AdaptiveDeviationPointsPrices(sym, bid, ask, atrPips) : MathMax(1, InpDev_MinPoints));
                  trade.SetDeviationInPoints(devPtsL);
                  bool partOk = trade.PositionClosePartial(ticket, r2CloseLots);
                  if(partOk)
                  {
                     g_sym[symIdx].ladderR2Done = true;
                     Audit_Log("LADDER_R2",
                               StringFormat("sym=%s|posId=%I64d|closed=%.2f|pips=%.2f",
                                            sym, posId, r2CloseLots, profitPips),
                               false);
                  }
               }
               else g_sym[symIdx].ladderR2Done = true;
            }
         }
      }

      // Time stop
      if(InpUseTimeStop && !exitBlockedByNews)
      {
         int bars=BarsSinceOpen(sym, openTime);
         if(bars>=InpTimeStopBars)
         {
            int ret=0; string cmt="";
            int devPts = (haveTick ? AdaptiveDeviationPointsPrices(sym, bid, ask, atrPips) : MathMax(1, InpDev_MinPoints));
            bool ok=ClosePositionByTicketSafe(sym, ticket, type, vol, devPts, ret, cmt);
            Status_SetTrade("TIMESTOP_CLOSE", ret, cmt);
            if(ok) Audit_Log("EXIT_TIMESTOP", StringFormat("sym=%s|posId=%I64d|bars=%d", sym, posId, bars), false);
         }
      }

      // Protect mode (close winners if no SL and cannot BE lock)
      if(InpUseProtectMode && InpDSP_CloseWinnerBelowPipsIfNoSL && sl<=0 && profitPips>0)
      {
         int bars=BarsSinceOpen(sym, openTime);
         if(bars >= InpDSP_MinHoldBars && profitPips <= InpDSP_CloseWinnerBelowPips)
         {
            int ret=0; string cmt="";
            int devPts = (haveTick ? AdaptiveDeviationPointsPrices(sym, bid, ask, atrPips) : MathMax(1, InpDev_MinPoints));
            bool ok=ClosePositionByTicketSafe(sym, ticket, type, vol, devPts, ret, cmt);
            Status_SetTrade("DSP_CLOSE", ret, cmt);
            if(ok) Audit_Log("EXIT_DSP", StringFormat("sym=%s|posId=%I64d|pips=%.2f|bars=%d", sym, posId, profitPips, bars), false);
         }
      }
   }
}


// -----------------------------------------
// EA init/deinit/tick/timer
// -----------------------------------------

// --- Data completeness check (NEW v12)
// Ensures required bar history exists for each symbol/TF combination.
// If history is missing (common for some CFDs/stocks in multi-symbol tests), we skip that symbol.
int Data_CopyRatesCount(const string sym, ENUM_TIMEFRAMES tf, int need)
{
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int got = CopyRates(sym, tf, 0, need, r);
   if(got < 0) got = 0;
   return got;
}

string TFName(const ENUM_TIMEFRAMES tf)
{
   return EnumToString(tf);
}

bool Data_CheckSymbol(const string sym, string &reason)
{
   reason = "";

   int needEntry = 200;
   needEntry = MathMax(needEntry, InpATR_Period + 50);
   needEntry = MathMax(needEntry, InpADX_Period + 50);
   needEntry = MathMax(needEntry, InpEMA_Period + 50);
   needEntry = MathMax(needEntry, InpCorrLookbackBars + 50);
   needEntry = MathMax(needEntry, InpVolRegimeLookbackBars + 50);
   needEntry = MathMax(needEntry, InpBiasEMASlow + 50);

   int gotEntry = Data_CopyRatesCount(sym, InpEntryTF, needEntry);
   if(gotEntry < needEntry)
   {
      reason = StringFormat("ENTRYTF %s bars=%d need=%d", TFName(InpEntryTF), gotEntry, needEntry);
      return false;
   }

   int needConf = 120;
   needConf = MathMax(needConf, InpADX_Period + 50);
   int gotConf = Data_CopyRatesCount(sym, InpConfirmTF, needConf);
   if(gotConf < needConf)
   {
      reason = StringFormat("CONFIRMTF %s bars=%d need=%d", TFName(InpConfirmTF), gotConf, needConf);
      return false;
   }

   if(InpUseHTFBias)
   {
      int needBias = 120;
      needBias = MathMax(needBias, InpBiasEMASlow + 50);
      int gotBias = Data_CopyRatesCount(sym, InpBiasTF, needBias);
      if(gotBias < needBias)
      {
         reason = StringFormat("BIASTF %s bars=%d need=%d", TFName(InpBiasTF), gotBias, needBias);
         return false;
      }
   }

   if(InpUseVolRegime)
   {
      int needVol = 120;
      needVol = MathMax(needVol, InpVolRegimeLookbackBars + 20);
      int gotVol = Data_CopyRatesCount(sym, InpVolRegimeTF, needVol);
      if(gotVol < needVol)
      {
         reason = StringFormat("VOLTF %s bars=%d need=%d", TFName(InpVolRegimeTF), gotVol, needVol);
         return false;
      }
   }

   if(InpUseCorrelationGuard)
   {
      int needCorr = 120;
      needCorr = MathMax(needCorr, InpCorrLookbackBars + 20);
      int gotCorr = Data_CopyRatesCount(sym, InpCorrTF, needCorr);
      if(gotCorr < needCorr)
      {
         reason = StringFormat("CORRTF %s bars=%d need=%d", TFName(InpCorrTF), gotCorr, needCorr);
         return false;
      }
   }

   return true;
}



/* --------------------------------------------------------------------------
   Equity drawdown tracker (build-compatible)

   Some MT5 builds miss certain TesterStatistics() ENUM_STATISTICS constants
   (e.g. STAT_EQUITY_DDREL / *_PERCENT). We compute max equity DD% ourselves
   during the test so OnTester() can use it everywhere.
--------------------------------------------------------------------------- */
bool   gEqDD_Init      = false;
double gEqDD_Peak      = 0.0;
double gEqDD_MaxPct    = 0.0;

void EquityDD_Reset()
{
   gEqDD_Init   = false;
   gEqDD_Peak   = 0.0;
   gEqDD_MaxPct = 0.0;
}

void EquityDD_Update()
{
   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(!gEqDD_Init)
   {
      gEqDD_Init   = true;
      gEqDD_Peak   = eq;
      gEqDD_MaxPct = 0.0;
      return;
   }

   if(eq > gEqDD_Peak)
      gEqDD_Peak = eq;

   if(gEqDD_Peak > 0.0)
   {
      const double dd = (gEqDD_Peak - eq) / gEqDD_Peak * 100.0;
      if(dd > gEqDD_MaxPct)
         gEqDD_MaxPct = dd;
   }
}

double EquityDD_MaxPct()
{
   return (gEqDD_Init ? gEqDD_MaxPct : 0.0);
}

int OnInit()
{
   Sanity_Reset(); // NEW: startup warm-up baseline
   EquityDD_Reset(); // init DD tracker for OnTester()
   // Load Telegram config early (if enabled) so startup test messages can be sent immediately.
   TG_Config_UpdateIfDue(true);
   // parse symbols
   string tmp[];
   int n=StringSplit(InpSymbols, ',', tmp);
   g_symCount=0;
   for(int i=0;i<n && i<64;i++)
   {
      string raw=TrimStr(tmp[i]);
      if(raw=="") continue;

      string sym=ResolveSymbolName(raw);
      if(sym=="") continue;

      if(!SymbolSelect(sym,true))
      {
         Print("Symbol not available/selected: ",raw," (resolved: ",sym,"). Add to MarketWatch or adjust InpSymbols.");
         continue;
      }


      // Hard whitelist: only trade EURUSD/GBPUSD/CUCUSD (suffix ok)
      if(!IsAllowedTradeSymbol(sym))
      {
         Print("[INIT] Skipping not-allowed symbol: ", raw, " (resolved: ", sym, ")");
         continue;
      }

      // data completeness check (skip symbols with missing history)
      string dwhy="";
      if(!Data_CheckSymbol(sym, dwhy))
      {
         Print("[INIT] Skip symbol (insufficient data): ",sym," | ",dwhy);
         continue;
      }

      bool dup=false;
      for(int j=0;j<g_symCount;j++)
      {
         if(g_syms[j]==sym){ dup=true; break; }
      }
      if(dup) continue;

      g_syms[g_symCount]=sym;
      g_sym[g_symCount].lastBar=0;
      g_sym[g_symCount].lastConfirmBar=0;
      g_sym[g_symCount].lastNewsSpike=0;
      g_sym[g_symCount].lastBiasBar=0;
      g_sym[g_symCount].biasDir=0;
      g_sym[g_symCount].lastVolBar=0;
      g_sym[g_symCount].volMult=1.0;
      g_sym[g_symCount].volBlock=false;
      g_sym[g_symCount].volPct=50.0;
      g_sym[g_symCount].volValid=false;
      g_sym[g_symCount].cooldownUntil=0;
      g_sym[g_symCount].cooldownReason=0;
      // v20 fields
      g_sym[g_symCount].autoDisabledUntil=0;
      g_sym[g_symCount].pyramidCount=0;
      g_sym[g_symCount].kellyPnLHead=0;
      g_sym[g_symCount].kellyPnLN=0;
      g_sym[g_symCount].ladderPosId=0;
      g_sym[g_symCount].ladderR1Done=false;
      g_sym[g_symCount].ladderR2Done=false;
      g_sym[g_symCount].ladderInitRisk=0.0;
      g_sym[g_symCount].ladderVolInit=0.0;
      g_sym[g_symCount].rankEnabled=true; // default enabled until first rank load
      g_symCount++;
   }
   if(g_symCount<=0) return INIT_FAILED;

   // per-symbol overrides (optional)
   LoadSymbolOverrides();

   // tune state / auto-rollback (optional)
   if(InpTune_Enable)
   {
      TuneState_Load();
      Tune_SyncWithOverrides(true);
   }


   // init indicators per symbol
   bool needEMA = (InpUsePullbackEMA || InpSymbolOverrides_Enable);
   for(int i=0;i<g_symCount;i++)
   {
      g_emaHandle[i]=INVALID_HANDLE;
      g_atrHandle[i]=INVALID_HANDLE;
      g_atrVolHandle[i]=INVALID_HANDLE;
      g_adxHandle[i]=INVALID_HANDLE;
      g_adxEntryHandle[i]=INVALID_HANDLE;
      g_biasFastHandle[i]=INVALID_HANDLE;
      g_biasSlowHandle[i]=INVALID_HANDLE;
      g_rsiHandle[i]=INVALID_HANDLE;            // P2-4
      g_ultraBiasFastHandle[i]=INVALID_HANDLE;  // P2-7
      g_ultraBiasSlowHandle[i]=INVALID_HANDLE;  // P2-7
      g_slCooldownBarTime[i]=0;                 // P3-10
      g_slCooldownBarsLeft[i]=0;                // P3-10
   }

   // Initialize indicator handles. If one symbol fails (no data / invalid handle),
   // we SKIP that symbol instead of failing the whole EA (multi-symbol friendly).
   int valid=0;
   for(int i=0;i<g_symCount;i++)
   {
      string sym=g_syms[i];

      bool useEMA = (InpUsePullbackEMA || Sym_UsePullbackEMA(sym));

      int ema=INVALID_HANDLE;
      int atr=INVALID_HANDLE;
      int atrVol=INVALID_HANDLE;
      int adx=INVALID_HANDLE;
      int adxE=INVALID_HANDLE;
      int bf=INVALID_HANDLE;
      int bs=INVALID_HANDLE;
      int rsi=INVALID_HANDLE;       // P2-4
      int ubf=INVALID_HANDLE;       // P2-7
      int ubs=INVALID_HANDLE;       // P2-7

      if(useEMA)
         ema=iMA(sym, InpEntryTF, InpEMA_Period, 0, MODE_EMA, PRICE_CLOSE);

      int atrPer = GetCurrentATRPeriod();

      atr=iATR(sym, InpEntryTF, atrPer);

      if(InpUseVolRegime)
         atrVol=iATR(sym, InpVolRegimeTF, atrPer);

      if(InpUseADXFilter)
      {
         adx = iADX(sym, InpConfirmTF, InpADX_Period);
         adxE= iADX(sym, InpEntryTF,   InpADX_Period);
      }

      if(InpUseHTFBias)
      {
         bf=iMA(sym, InpBiasTF, InpBiasEMAFast, 0, MODE_EMA, PRICE_CLOSE);
         bs=iMA(sym, InpBiasTF, InpBiasEMASlow, 0, MODE_EMA, PRICE_CLOSE);
      }

      if(InpUseDivergenceFilter)
         rsi = iRSI(sym, InpEntryTF, MathMax(2, InpRSI_Period), PRICE_CLOSE);

      if(InpUseUltraHTFBias)
      {
         ubf = iMA(sym, InpUltraBiasTF, MathMax(1, InpUltraBiasEMAFast), 0, MODE_EMA, PRICE_CLOSE);
         ubs = iMA(sym, InpUltraBiasTF, MathMax(1, InpUltraBiasEMASlow), 0, MODE_EMA, PRICE_CLOSE);
      }

      bool ok=true;
      if(atr==INVALID_HANDLE) ok=false;
      if(useEMA && ema==INVALID_HANDLE) ok=false;
      if(InpUseVolRegime && atrVol==INVALID_HANDLE) ok=false;
      if(InpUseADXFilter && (adx==INVALID_HANDLE || adxE==INVALID_HANDLE)) ok=false;
      if(InpUseHTFBias && (bf==INVALID_HANDLE || bs==INVALID_HANDLE)) ok=false;
      if(InpUseDivergenceFilter && rsi==INVALID_HANDLE) ok=false;
      if(InpUseUltraHTFBias && (ubf==INVALID_HANDLE || ubs==INVALID_HANDLE)) ok=false;

      if(!ok)
      {
         Print("Indicator init failed for ", sym, " -> skipping symbol");

         if(ema!=INVALID_HANDLE)     IndicatorRelease(ema);
         if(atr!=INVALID_HANDLE)     IndicatorRelease(atr);
         if(atrVol!=INVALID_HANDLE)  IndicatorRelease(atrVol);
         if(adx!=INVALID_HANDLE)     IndicatorRelease(adx);
         if(adxE!=INVALID_HANDLE)    IndicatorRelease(adxE);
         if(bf!=INVALID_HANDLE)      IndicatorRelease(bf);
         if(bs!=INVALID_HANDLE)      IndicatorRelease(bs);
         if(rsi!=INVALID_HANDLE)     IndicatorRelease(rsi);
         if(ubf!=INVALID_HANDLE)     IndicatorRelease(ubf);
         if(ubs!=INVALID_HANDLE)     IndicatorRelease(ubs);

         continue;
      }

      if(valid!=i)
      {
         g_syms[valid]=g_syms[i];
         g_sym[valid]=g_sym[i];
      }

      g_emaHandle[valid]=ema;
      g_atrHandle[valid]=atr;
      g_atrVolHandle[valid]=atrVol;
      g_adxHandle[valid]=adx;
      g_adxEntryHandle[valid]=adxE;
      g_biasFastHandle[valid]=bf;
      g_biasSlowHandle[valid]=bs;
      g_rsiHandle[valid]=rsi;
      g_ultraBiasFastHandle[valid]=ubf;
      g_ultraBiasSlowHandle[valid]=ubs;

      valid++;
   }

   g_symCount=valid;
   if(g_symCount<=0)
   {
      Print("No valid symbols after indicator init.");
      return INIT_FAILED;
   }

   // P3-9: seed weekly equity baseline
   WeeklyLoss_UpdateIfNewWeek();

   Sanity_UpdateReadiness();
   // open logs
   Audit_Open();
   ML_Open();

   // initial news cache load
   News_UpdateIfDue();

   // seed closed-position counter helper (important after terminal/EA restart)
   PosTrackSeedOpenPositions();

   // timer
   EventSetTimer(MathMax(1, InpTimerSec));

   DashClear();
   DashboardUpdate();

   // Telegram startup test (optional)
   if(InpEnableTelegram && InpTGTestOnInit)
      TelegramSendMessage(StringFormat("EA gestart | magic=%d | symbols=%d | TF=%s/%s", (int)InpMagic, g_symCount, EnumToString(InpEntryTF), EnumToString(InpConfirmTF)));

   AppliedLog_AppendIfChanged();

   // v20: load optional ML gate + symbol rank on startup
   MLGate_Load();
   WeeklyRank_MaybeLoad();

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   DashClear();
   ML_Close();
   Audit_Close();

   // tune state save (v11)
   if(InpTune_Enable) TuneState_Save();

   // release indicators
   for(int i=0;i<g_symCount;i++)
   {
      if(g_emaHandle[i]!=INVALID_HANDLE)            IndicatorRelease(g_emaHandle[i]);
      if(g_atrHandle[i]!=INVALID_HANDLE)            IndicatorRelease(g_atrHandle[i]);
      if(g_adxHandle[i]!=INVALID_HANDLE)            IndicatorRelease(g_adxHandle[i]);
      if(g_adxEntryHandle[i]!=INVALID_HANDLE)       IndicatorRelease(g_adxEntryHandle[i]);
      if(g_biasFastHandle[i]!=INVALID_HANDLE)       IndicatorRelease(g_biasFastHandle[i]);
      if(g_biasSlowHandle[i]!=INVALID_HANDLE)       IndicatorRelease(g_biasSlowHandle[i]);
      if(g_atrVolHandle[i]!=INVALID_HANDLE)         IndicatorRelease(g_atrVolHandle[i]);
      if(g_rsiHandle[i]!=INVALID_HANDLE)            IndicatorRelease(g_rsiHandle[i]);
      if(g_ultraBiasFastHandle[i]!=INVALID_HANDLE)  IndicatorRelease(g_ultraBiasFastHandle[i]);
      if(g_ultraBiasSlowHandle[i]!=INVALID_HANDLE)  IndicatorRelease(g_ultraBiasSlowHandle[i]);
   }
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   // P1-1: capture exit deals; try immediate HistorySelectByPosition for lower latency.
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong deal=trans.deal;
      if(deal>0)
      {
         // Attempt to pre-select history using positionId (available on MT5 build 1820+).
         // This avoids waiting for the next ProcessDealQueue / HistorySelect throttle cycle.
         if(trans.position > 0)
         {
            if(HistorySelectByPosition(trans.position))
            {
               g_dealQHistoryFresh     = true;
               g_dealQHistoryFreshTime = TimeCurrent();
            }
         }
         if(!DealQ_Push(deal))
         {
            PrintFormat("DEALQ_OVERFLOW: queue full, dropping deal %I64d", (long)deal);
            FailSafe_Trip("DEALQ_OVERFLOW");
         }
      }
   }
}

void OnTick()
{
   Cycle_Begin();
   EqRegime_Update();
   News_UpdateIfDue();
   Sanity_UpdateReadiness(); // NEW: update indicator readiness (sanity mode)

   // HOTFIX: update correlation cache once per CorrTF bar (avoids repeated CopyClose in entry checks)
   if(InpUseCorrelationGuard) CorrCache_UpdateIfNeeded();

   if(InpManageOnTick) ManagePositions();

   // entries on tick only if not using timer
   if(!InpUseTimerForEntries)
   {
      if(g_entryLoopBusy) return;
      g_entryLoopBusy=true;
      for(int i=0;i<g_symCount;i++)
         ProcessSymbol(i, g_syms[i]);
      g_entryLoopBusy=false;
   }

   ProcessDealQueue();
   EquityDD_Update();
   TradeDensity_Check();

   // tune engine (v11)
   if(InpTune_Enable)
   {
      Tune_MaybeMonthlyNotify();
      Tune_MaybeCheckRollback();
   }

   // dashboard: if timer handles frequent updates, skip heavy updates on tick
   if(!InpUseTimerForEntries)
      DashboardUpdate();
}


// --- Trade-density warning (NEW v12)
// Warns if the EA isn't generating enough closed trades for some symbols (often due to too many filters or missing data).
void TradeDensity_Check()
{
   if(InpTradeDensity_MinTrades30d_Warn<=0) return;
   if(InpTradeDensity_CheckSec<=0) return;

   static datetime nextCheck=0;
   datetime now=TimeCurrent();
   if(nextCheck>0 && now < nextCheck) return;
   nextCheck = now + (datetime)InpTradeDensity_CheckSec;

   datetime from = now - 30*86400;
   if(!HistorySelect(from, now))
      return;

   int counts[];
   ArrayResize(counts, g_symCount);
   ArrayInitialize(counts, 0);

   long  posIds[];
   string posSyms[];
   double vin[];
   double vout[];
   bool  hasIn[];
   bool  hasOut[];
   int n=0;

   int total = HistoryDealsTotal();
   for(int i=0;i<total;i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal==0) continue;

      long magic = (long)HistoryDealGetInteger(deal, DEAL_MAGIC);
      if(magic != (long)InpMagic) continue;

      string sym = HistoryDealGetString(deal, DEAL_SYMBOL);
      long posId = (long)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      if(posId<=0) continue;

      ENUM_DEAL_ENTRY ent = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      double vol = HistoryDealGetDouble(deal, DEAL_VOLUME);

      int idx=-1;
      for(int j=0;j<n;j++)
         if(posIds[j]==posId) { idx=j; break; }

      if(idx<0)
      {
         idx=n++;
         ArrayResize(posIds,n);
         ArrayResize(posSyms,n);
         ArrayResize(vin,n);
         ArrayResize(vout,n);
         ArrayResize(hasIn,n);
         ArrayResize(hasOut,n);
         posIds[idx]=posId;
         posSyms[idx]=sym;
         vin[idx]=0.0;
         vout[idx]=0.0;
         hasIn[idx]=false;
         hasOut[idx]=false;
      }

      if(ent==DEAL_ENTRY_IN || ent==DEAL_ENTRY_INOUT)
      {
         vin[idx]+=vol;
         hasIn[idx]=true;
      }
      if(ent==DEAL_ENTRY_OUT || ent==DEAL_ENTRY_INOUT)
      {
         vout[idx]+=vol;
         hasOut[idx]=true;
      }
   }

   for(int j=0;j<n;j++)
   {
      if(!hasIn[j] || !hasOut[j]) continue;
      if(vout[j] + 1e-8 < vin[j]) continue; // not fully closed

      int sidx = SymIndexByNameLoose(posSyms[j]);
      if(sidx>=0 && sidx<g_symCount)
         counts[sidx]++;
   }

   for(int i=0;i<g_symCount;i++)
   {
      if(counts[i] < InpTradeDensity_MinTrades30d_Warn)
      {
         Print("[DENSITY] ", g_syms[i],
               " closed positions last 30d=", counts[i],
               " (<", InpTradeDensity_MinTrades30d_Warn,
               "). Trade flow may be too low (filters/data/sessions).");
      }
   }
}

void OnTimer()
{
   Cycle_Begin();
   SymbolOverrides_UpdateIfDue();
   EqRegime_Update();
   News_UpdateIfDue();
   Sanity_UpdateReadiness();

   // P1-2: periodically check and reinitialise indicator handles that became INVALID_HANDLE
   // (e.g. after broker reconnect, chart reload). Runs once per timer cycle (cheap: O(n) checks).
   Handles_CheckAndReinit();

   // P3-9: check if the trading week has rolled over and reset the weekly equity baseline
   WeeklyLoss_UpdateIfNewWeek();

   // HOTFIX: update correlation cache once per CorrTF bar (avoids repeated CopyClose in entry checks)
   if(InpUseCorrelationGuard) CorrCache_UpdateIfNeeded();

   // v20: expire stale pending limit orders (C8) + weekly symbol rank refresh (D10)
   PendingLimits_ExpireStale();
   WeeklyRank_MaybeLoad();

   if(!InpManageOnTick) ManagePositions();

   if(InpUseTimerForEntries)
   {
      if(g_entryLoopBusy) return;
      g_entryLoopBusy=true;
      for(int i=0;i<g_symCount;i++)
         ProcessSymbol(i, g_syms[i]);
      g_entryLoopBusy=false;
   }

   ProcessDealQueue();
   EquityDD_Update();
   DashboardUpdate();
   // Optional hot-reload of Telegram config (also used by queue processor).
   TG_Config_UpdateIfDue(false);
   TelegramQueue_Process();
   // P5-17: poll for inbound Telegram commands
   TG_PollCommands();
}

// -----------------------------------------
// AutoTune placeholder
// -----------------------------------------
double AutoTuneScore()
{
   return 0.0;
}

// -----------------------------------------
// Strategy Tester custom score (NEW v12)
// Enable via: InpTester_UseCustomCriterion = true
// -----------------------------------------
double OnTester()
{
   if(!InpTester_UseCustomCriterion)
      return 0.0; // use built-in criterion

   double trades = TesterStatistics(STAT_TRADES);
   double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   double net    = TesterStatistics(STAT_PROFIT);
   double ddPct  = EquityDD_MaxPct();

   if(trades<=0)
      return -1e9;

   if(InpTester_DDCapPct>0.0 && ddPct > InpTester_DDCapPct)
      return -1e9;

   // Cap extreme PF values (usually caused by too few trades)
   if(pf > 10.0) pf = 10.0;
   if(pf < 0.0)  pf = 0.0;

   // Trade-count penalty
   double tradeFactor = 1.0;
   if(InpTester_MinTradesForFullScore>0)
   {
      tradeFactor = trades / (double)InpTester_MinTradesForFullScore;
      if(tradeFactor > 1.0) tradeFactor = 1.0;
      if(tradeFactor < 0.05) tradeFactor = 0.05;
   }

   // Drawdown factor
   double ddFactor = 1.0 - ddPct/100.0;
   if(ddFactor < 0.0) ddFactor = 0.0;

   // Score: prefer NetProfit, reward PF, penalize DD + low trade count.
   double score = net * (0.25 + pf) * ddFactor * tradeFactor;

   // P5-16: slippage penalty — penalise runs where average slippage is high.
   // Uses slippage tracked via the SLIPPAGE ML rows accumulated during the test.
   if(InpTester_SlippagePenalty && g_slippageCount > 0)
   {
      double avgSlipPips = g_totalSlippagePips / (double)g_slippageCount;
      if(avgSlipPips > 0.0)
         score -= InpTester_SlippagePenalty_Mult * avgSlipPips;
   }

   // Hard penalize non-profitable runs
   if(net <= 0.0)
      score = net - 1000000.0;

   return score;
}
