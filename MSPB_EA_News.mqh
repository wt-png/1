#ifndef MSPB_EA_NEWS_MQH
#define MSPB_EA_NEWS_MQH

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

#endif // MSPB_EA_NEWS_MQH
