#ifndef MSPB_EA_TELEGRAM_MQH
#define MSPB_EA_TELEGRAM_MQH

#include "MSPB_EA_JSON.mqh"

// Maximum age (seconds) of an incoming Telegram message that the EA will process.
// Messages older than this are silently discarded to prevent replay attacks.
#define TG_MAX_MSG_AGE_SEC 120

// Backward search window (characters) when locating the "date" field relative
// to the update_id end position.  Mirrors TG_JSON_TEXT_SEARCH_WINDOW in the main
// file but is defined here because this module owns the polling loop.
#define TG_JSON_DATE_SEARCH_WINDOW 200

// -----------------------------------------
// Telegram (Bot API via WebRequest)
// -----------------------------------------
// IMPORTANT (MT5):
//  Tools -> Options -> Expert Advisors -> "Allow WebRequest for listed URL"
//  Add this URL (exact): https://api.telegram.org
//
// Inputs needed:
//  InpEnableTelegram=true
//  InpTGConfigFile=<your cfg filename>
//  (cfg must contain BOT_TOKEN and CHAT_ID)
//
// NOTE: Incoming commands (InpTGEnableIncoming / InpTGSecret) are not implemented in this build.

string TG_UrlEncode(const string s)
{
   // URL-encode as application/x-www-form-urlencoded (UTF-8, spaces => '+')
   uchar data[];
   StringToCharArray(s, data, 0, WHOLE_ARRAY, CP_UTF8);

   string out = "";
   for(int i=0;i<ArraySize(data);i++)
   {
      int c = (int)data[i];
      if(c==0) break;

      if((c>='0' && c<='9') ||
         (c>='A' && c<='Z') ||
         (c>='a' && c<='z') ||
         c=='-' || c=='_' || c=='.' || c=='~')
      {
         out += StringFormat("%c", c);
      }
      else if(c==' ')
      {
         out += "+";
      }
      else
      {
         out += StringFormat("%%%02X", c);
      }
   }
   return out;
}

// --- Telegram config (secrets from file) ------------------------------
string   g_tgBotToken="";
string   g_tgChatId="";
long     g_tgAllowedUserId=0;      // optional (for future incoming commands)
string   g_tgSecret="";           // optional (for future incoming commands)
string   g_tgPrefixOverride="";   // optional override of InpTGMessagePrefix

string   g_tgCfgLastError="";
datetime g_tgCfgLastLoad=0;
datetime g_tgCfgNextReload=0;
bool     g_tgCfgWarned=false;

bool ParseBoolLoose(const string s,const bool def=false)
{
   string t=TrimStr(s);
   StringToLower(t);
   if(t=="1" || t=="true" || t=="yes" || t=="y" || t=="on")  return true;
   if(t=="0" || t=="false"|| t=="no"  || t=="n" || t=="off") return false;
   return def;
}

string TG_GetPrefix()
{
   if(g_tgPrefixOverride!="") return g_tgPrefixOverride;
   return InpTGMessagePrefix;
}

bool TG_Config_IsReady()
{
   return (g_tgBotToken!="" && g_tgChatId!="");
}

bool TG_Config_Load()
{
   g_tgCfgLastError="";
   if(TrimStr(InpTGConfigFile)=="")
   {
      g_tgCfgLastError="TGCFG_EMPTY_FILENAME";
      return false;
   }

   // Security check: warn when the config file resides in a path that is
   // accessible to other programs (MetaTrader "Common" shared folder).
   // Tokens stored in a shared location can be read by any process on the machine.
   string cfgLower = InpTGConfigFile;
   StringToLower(cfgLower);
   if(StringFind(cfgLower, "\\shared\\") >= 0 ||
      StringFind(cfgLower, "/shared/")  >= 0 ||
      InpTGConfig_UseCommonFolder)
   {
      Print("[SECURITY WARNING] TG config file is in a shared/common folder (",
            InpTGConfigFile, "). "
            "Anyone with access to the machine can read the bot token. "
            "Move the file to the MT5 data folder and disable InpTGConfig_UseCommonFolder.");
   }

   int flags = FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ;
   if(InpTGConfig_UseCommonFolder) flags |= FILE_COMMON;

   ResetLastError();
   int h=FileOpen(InpTGConfigFile, flags);
   if(h==INVALID_HANDLE)
   {
      g_tgCfgLastError = StringFormat("TGCFG_OPEN_FAIL file='%s' err=%d", InpTGConfigFile, GetLastError());
      return false;
   }

   string line;
   string newToken="";
   string newChat="";
   long   newAllowed=0;
   string newSecret="";
   string newPrefix="";
   int    loaded=0; // number of parsed keys (for debug)
   while(FileReadLineTxt(h, line))
   {
      line=TrimStr(line);
      if(line=="") continue;
      int c0=StringGetCharacter(line,0);
      if(c0=='#' || c0==';') continue;

      int sep=StringFind(line,"=");
      if(sep<0) sep=StringFind(line,":");
      if(sep<0) continue;

      string key=UpperTrim(StringSubstr(line,0,sep));
      string val=TrimStr(StringSubstr(line,sep+1));

      // Strip surrounding quotes
      int L=StringLen(val);
      if(L>=2)
      {
         int f=StringGetCharacter(val,0);
         int l=StringGetCharacter(val,L-1);
         if((f=='"' && l=='"') || (f=='\'' && l=='\''))
            val=StringSubstr(val,1,L-2);
      }

      if(key=="BOT_TOKEN" || key=="TOKEN" || key=="TGBOT_TOKEN") { newToken=val; loaded++; }
      else if(key=="CHAT_ID" || key=="CHATID" || key=="TGCHAT_ID") { newChat=val; loaded++; }
      else if(key=="ALLOWED_USER_ID" || key=="ALLOWEDUSERID" || key=="USER_ID") { newAllowed=(long)StringToInteger(val); loaded++; }
      else if(key=="SECRET" || key=="TGSECRET") { newSecret=val; loaded++; }
      else if(key=="PREFIX" || key=="MESSAGE_PREFIX") { newPrefix=val; loaded++; }
   }
   FileClose(h);

   if(newToken!="") g_tgBotToken=newToken;
   if(newChat!="")  g_tgChatId=newChat;
   if(newAllowed!=0) g_tgAllowedUserId=newAllowed;
   if(newSecret!="") g_tgSecret=newSecret;
   if(newPrefix!="") g_tgPrefixOverride=newPrefix;

   if(InpDebug)
      Print("[TG] Config read: keys=",loaded," file=",InpTGConfigFile);

   if(!TG_Config_IsReady())
   {
      g_tgCfgLastError = StringFormat("TGCFG_MISSING_KEYS (need BOT_TOKEN and CHAT_ID) in '%s'", InpTGConfigFile);
      return false;
   }
   return true;
}

void TG_Config_UpdateIfDue(const bool force=false)
{
   if(!InpEnableTelegram) return;

   datetime now=TimeCurrent();
   int reloadSec=MathMax(5, InpTGConfig_ReloadSec);

   bool due = force || (g_tgCfgLastLoad==0) || (InpTGConfig_HotReload && now>=g_tgCfgNextReload);
   if(!due) return;

   bool wasReady = TG_Config_IsReady();
   bool ok = TG_Config_Load();

   g_tgCfgLastLoad = now;
   g_tgCfgNextReload = now + (InpTGConfig_HotReload ? reloadSec : 1000000000);

   if(!ok)
   {
      if(!g_tgCfgWarned)
      {
         Print("[TG] Config not loaded: ", g_tgCfgLastError);
         g_tgCfgWarned=true;
      }
      return;
   }

   g_tgCfgWarned=false;
   if(!wasReady && TG_Config_IsReady())
      Print("[TG] Config loaded OK from '", InpTGConfigFile, "' (token/chat_id hidden)");
}

// --- Telegram queue (rate-limited) ---------------------------------
#define TGQ_MAX 128
string   g_tgQueue[TGQ_MAX];
int      g_tgQHead=0, g_tgQTail=0;
datetime g_tgNextSend=0;
int      g_tgBackoffSec=0;

// Per-category rate limiting
enum ETGCategory { TGC_TRADE=0, TGC_RISK=1, TGC_SYSTEM=2, TGC_ALERT=3, TGC_COUNT=4 };
datetime g_tgLastSendTime[TGC_COUNT];  // per-category last send timestamp (ms precision via GetTickCount)

int TGCategoryRateLimitMs(const ETGCategory cat)
{
   if(cat==TGC_TRADE)  return InpTGRateLimit_Trade_Ms;
   if(cat==TGC_RISK)   return InpTGRateLimit_Risk_Ms;
   if(cat==TGC_SYSTEM) return InpTGRateLimit_System_Ms;
   if(cat==TGC_ALERT)  return InpTGRateLimit_Alert_Ms;
   return InpTGRateLimitMs;
}

bool TGQ_IsEmpty(){ return g_tgQHead==g_tgQTail; }
int  TGQ_Next(const int x){ return (x+1)%TGQ_MAX; }

int TGQ_Size()
{
   if(g_tgQTail>=g_tgQHead) return (g_tgQTail-g_tgQHead);
   return (TGQ_MAX - g_tgQHead + g_tgQTail);
}

bool TGQ_Push(const string msg)
{
   int next = TGQ_Next(g_tgQTail);
   if(next==g_tgQHead)
   {
      // full -> drop oldest
      g_tgQHead = TGQ_Next(g_tgQHead);
      static datetime lastWarn=0;
      datetime now=TimeCurrent();
      if(lastWarn==0 || (now-lastWarn)>60)
      {
         Print("TGQ: queue full -> dropping oldest message(s).");
         lastWarn=now;
      }
   }
   g_tgQueue[g_tgQTail]=msg;
   g_tgQTail=next;
   return true;
}

bool TGQ_Pop(string &out)
{
   if(TGQ_IsEmpty()) return false;
   out=g_tgQueue[g_tgQHead];
   g_tgQueue[g_tgQHead]="";
   g_tgQHead=TGQ_Next(g_tgQHead);
   return true;
}

void TGQ_Clear()
{
   g_tgQHead=0; g_tgQTail=0;
}

// Parse "retry after X" seconds from Telegram 429 message
int TG_ParseRetryAfterSec(const string resp)
{
   string s=resp;
   StringToLower(s);
   int p=StringFind(s,"retry after");
   if(p<0) return 0;
   p += StringLen("retry after");
   // skip non-digits
   while(p<StringLen(s) && (StringGetCharacter(s,p)<'0' || StringGetCharacter(s,p)>'9')) p++;
   int start=p;
   while(p<StringLen(s) && (StringGetCharacter(s,p)>='0' && StringGetCharacter(s,p)<='9')) p++;
   if(p<=start) return 0;
   string num=StringSubstr(s,start,p-start);
   int v=(int)StringToInteger(num);
   return v;
}

bool TelegramSendNow(const string msg, int &httpOut, string &respOut)
{
   httpOut = 0; respOut="";
   if(!InpEnableTelegram) return false;

   // Ensure config is loaded at least once (won't reload every call unless due)
   TG_Config_UpdateIfDue(false);
   if(!TG_Config_IsReady())
   {
      static datetime lastWarn=0;
      datetime now=TimeCurrent();
      if(lastWarn==0 || (now-lastWarn)>60)
      {
         if(g_tgCfgLastError!="")
            Print("TG: Not configured. ", g_tgCfgLastError, " (and enable WebRequest to https://api.telegram.org).");
         else
            Print("TG: Not configured. Missing BOT_TOKEN/CHAT_ID in '", InpTGConfigFile, "' (and enable WebRequest to https://api.telegram.org).");
         lastWarn=now;
      }
      httpOut = 0;
      return false;
   }

   string text = msg;
   string pfx = TG_GetPrefix();
   if(pfx!="")
      text = pfx + ": " + msg;

   // Telegram max message length is ~4096 chars; keep margin
   if(StringLen(text)>3900)
      text = StringSubstr(text,0,3900) + "...";

   string url = "https://api.telegram.org/bot" + g_tgBotToken + "/sendMessage";

   string body = "chat_id=" + TG_UrlEncode(g_tgChatId)
               + "&text="   + TG_UrlEncode(text);

   if(InpTGDisableWebPreview)
      body += "&disable_web_page_preview=true";

   uchar post[];
   StringToCharArray(body, post, 0, WHOLE_ARRAY, CP_UTF8);

   uchar result[];
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string result_headers = "";

   ResetLastError();
   int http = WebRequest("POST", url, headers, InpTGTimeoutMS, post, result, result_headers);
   httpOut = http;

   if(http == -1)
   {
      int err = GetLastError();
      PrintFormat("TG: WebRequest failed (err=%d). MT5 must allow WebRequest to https://api.telegram.org. Also check internet/firewall.", err);
      return false;
   }

   string resp = CharArrayToString(result, 0, -1, CP_UTF8);
   respOut = resp;

   if(http != 200)
   {
      PrintFormat("TG: HTTP %d. Resp=%s", http, Shorten(resp, 160));
      return false;
   }

   return true;
}

bool TelegramSendMessage(const string msg, const ETGCategory cat=TGC_TRADE)
{
   if(!InpEnableTelegram) return false;

   // Per-category rate limiting (using datetime seconds as proxy)
   int catRateMs = TGCategoryRateLimitMs(cat);
   if(catRateMs > 0)
   {
      datetime now = TimeCurrent();
      int catRateSec = (int)MathCeil((double)catRateMs / 1000.0);
      if(catRateSec < 1) catRateSec = 1;
      if(g_tgLastSendTime[cat] > 0 && (now - g_tgLastSendTime[cat]) < catRateSec)
         return false; // rate-limited for this category
      g_tgLastSendTime[cat] = now;
   }

   // Queue mode avoids blocking the trading thread and reduces 429 risk
   if(!InpTGUseQueue)
   {
      int http; string resp;
      return TelegramSendNow(msg, http, resp);
   }

   return TGQ_Push(msg);
}

void TelegramQueue_Process()
{
   if(!InpEnableTelegram || !InpTGUseQueue) return;

   // Ensure config is loaded; if missing, keep the queue (user can fix cfg without losing messages)
   TG_Config_UpdateIfDue(false);
   if(!TG_Config_IsReady())
      return;

   datetime now=TimeCurrent();
   if(g_tgNextSend>0 && now < g_tgNextSend) return;

   string msg;
   if(!TGQ_Pop(msg)) return;

   int http; string resp;
   bool ok = TelegramSendNow(msg, http, resp);

   int rateSec = (int)MathCeil((double)InpTGRateLimitMs/1000.0);
   if(rateSec < 1) rateSec = 1;

   if(ok)
   {
      g_tgBackoffSec=0;
      g_tgNextSend = now + rateSec;
      return;
   }

   // Requeue for retry (best-effort)
   TGQ_Push(msg);

   int retry=0;
   if(http==429)
      retry = TG_ParseRetryAfterSec(resp);

   if(retry<=0)
   {
      int base = (g_tgBackoffSec>0 ? g_tgBackoffSec*2 : 5);
      retry = MathMin(InpTGBackoffMaxSec, MathMax(2, base));
   }
   g_tgBackoffSec = retry;
   g_tgNextSend = now + retry;
}



// -----------------------------------------
// Feature 5A: Daily Telegram Performance Report
// -----------------------------------------
void TG_SendDailyReport()
{
   if(!InpEnableTelegram || !TG_Config_IsReady()) return;

   datetime now = TimeCurrent();
   MqlDateTime dt; TimeToStruct(now, dt);

   // Compute today's date range
   MqlDateTime dayStart_dt; TimeToStruct(now, dayStart_dt);
   dayStart_dt.hour=0; dayStart_dt.min=0; dayStart_dt.sec=0;
   datetime todayStart = StructToTime(dayStart_dt);
   datetime todayEnd   = now;

   double totalPnl    = 0.0;
   int    nWins       = 0;
   int    nLosses     = 0;
   double maxDDMoney  = 0.0;
   double peakCum     = 0.0;
   double cumPnl      = 0.0;
   double pipsPnl     = 0.0;

   if(HistorySelect(todayStart, todayEnd))
   {
      int nd = HistoryDealsTotal();
      for(int i=0; i<nd; i++)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket==0) continue;
         if(!IsMyMagic((long)HistoryDealGetInteger(ticket, DEAL_MAGIC))) continue;
         long entry = (long)HistoryDealGetInteger(ticket, DEAL_ENTRY);
         if(entry != DEAL_ENTRY_OUT) continue;
         double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                       + HistoryDealGetDouble(ticket, DEAL_SWAP)
                       + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         totalPnl += profit;
         cumPnl   += profit;
         if(cumPnl > peakCum) peakCum = cumPnl;
         double dd = peakCum - cumPnl;
         if(dd > maxDDMoney) maxDDMoney = dd;
         if(profit >= 0.0) nWins++;
         else              nLosses++;
         // Approximate pips: use deal volume and symbol pip
         string sym = HistoryDealGetString(ticket, DEAL_SYMBOL);
         double vol = HistoryDealGetDouble(ticket, DEAL_VOLUME);
         double pip = PipSize(sym);
         double tickSz  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
         double tickVal = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
         if(tickSz>0.0 && tickVal>0.0 && vol>0.0 && pip>0.0)
            pipsPnl += profit / (tickVal / tickSz * vol * pip);
      }
   }

   int nTrades = nWins + nLosses;
   double winRate = (nTrades>0 ? (double)nWins/nTrades*100.0 : 0.0);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double maxDDPct = (balance>0.0 ? maxDDMoney/balance*100.0 : 0.0);
   int nPositions = PositionsTotal();

   string msg = StringFormat(
      "📊 Daily Report | %s\n"
      "Total P&L: %.2f | Pips: %.1f\n"
      "✅ Wins: %d | ❌ Losses: %d | Win%%: %.1f%%\n"
      "Max Intraday DD: %.2f%%\n"
      "Active positions: %d\n"
      "Equity: %.2f | Balance: %.2f",
      TimeToString(now, TIME_DATE),
      totalPnl, pipsPnl,
      nWins, nLosses, winRate,
      maxDDPct,
      nPositions,
      equity, balance
   );
   TelegramSendMessage(msg, TGC_SYSTEM);
}

// -----------------------------------------
// Feature 5B: Incoming Telegram Commands
// -----------------------------------------
void TG_CloseAllPositions()
{
   CTrade trade;
   trade.SetExpertMagicNumber((ulong)InpMagic);
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!IsMyMagic((long)PositionGetInteger(POSITION_MAGIC))) continue;
      trade.PositionClose(ticket);
   }
}

void TG_HandleCommand(const string rawText)
{
   string text = rawText;
   // Strip secret prefix if configured
   if(TrimStr(InpTGIncomingSecret)!="" &&
      StringFind(text, InpTGIncomingSecret)==0)
      text = TrimStr(StringSubstr(text, StringLen(InpTGIncomingSecret)));
   else if(TrimStr(InpTGIncomingSecret)!="")
      return; // secret not present, ignore

   string tl = text;
   StringToLower(tl);

   if(StringFind(tl, "/status")==0)
   {
      double bal = AccountInfoDouble(ACCOUNT_BALANCE);
      double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
      int nPos = PositionsTotal();
      string regime = (g_tradingPaused ? "PAUSED" : "ACTIVE");
      double ddPct = (g_dayStartBalance>0.0 ?
                      (g_dayStartBalance - eq)/g_dayStartBalance*100.0 : 0.0);
      string status = StringFormat(
         "📊 Status\nRegime: %s\nEquity: %.2f | Balance: %.2f\n"
         "Positions: %d | Daily DD: %.2f%%\n"
         "RiskMult: %.2f",
         regime, eq, bal, nPos, ddPct, g_riskMultiplierOverride);
      TelegramSendMessage(status, TGC_SYSTEM);
   }
   else if(StringFind(tl, "/pause")==0)
   {
      g_tradingPaused = true;
      RuntimeState_Save();
      TelegramSendMessage("⏸ Trading PAUSED via Telegram command.", TGC_SYSTEM);
   }
   else if(StringFind(tl, "/resume")==0)
   {
      g_tradingPaused = false;
      RuntimeState_Save();
      TelegramSendMessage("▶️ Trading RESUMED via Telegram command.", TGC_SYSTEM);
   }
   else if(StringFind(tl, "/risk ")==0)
   {
      string valStr = TrimStr(StringSubstr(text, 6));
      double mult = StringToDouble(valStr);
      double maxMult = MathMax(0.1, InpMaxRiskMultiplier);
      if(mult >= 0.1 && mult <= maxMult)
      {
         g_riskMultiplierOverride = mult;
         RuntimeState_Save();
         TelegramSendMessage(StringFormat("⚙️ Risk multiplier set to %.2f", mult), TGC_SYSTEM);
      }
      else
         TelegramSendMessage(StringFormat("⚠️ Invalid /risk value. Use /risk <0.1..%.1f>", maxMult), TGC_SYSTEM);
   }
   else if(StringFind(tl, "/close all")==0)
   {
      TG_CloseAllPositions();
      TelegramSendMessage("🔴 Close all positions command executed.", TGC_SYSTEM);
   }
}

void TG_PollCommands()
{
   if(!InpTGIncomingEnable) return;
   if(!InpEnableTelegram || !TG_Config_IsReady()) return;

   datetime now = TimeCurrent();
   int pollSec = MathMax(5, InpTGPollIntervalSec);
   if(g_tgLastPollTime > 0 && (now - g_tgLastPollTime) < pollSec) return;
   g_tgLastPollTime = now;

   string url = StringFormat(
      "https://api.telegram.org/bot%s/getUpdates?offset=%I64d&limit=10&timeout=0",
      g_tgBotToken, g_tgLastUpdateId + 1);

   uchar post_dummy[]; ArrayResize(post_dummy, 0);
   uchar result[];
   string result_headers = "";
   ResetLastError();
   int http = WebRequest("GET", url, "", InpTGTimeoutMS, post_dummy, result, result_headers);
   if(http == -1) { return; }
   if(http != 200) { return; }

   string resp = CharArrayToString(result, 0, -1, CP_UTF8);
   if(StringFind(resp, "\"ok\":true") < 0) return;

   // Walk through update objects using the JSON helpers from MSPB_EA_JSON.mqh.
   int searchPos = 0;
   while(true)
   {
      // Locate the next update_id field.
      int updateIdEnd = JsonGetLongEnd(resp, "update_id", searchPos);
      if(updateIdEnd < 0) break;
      long updateId = JsonGetLong(resp, "update_id", searchPos);
      searchPos = updateIdEnd;

      if(updateId > g_tgLastUpdateId)
         g_tgLastUpdateId = updateId;

      // --- Replay-attack guard ---
      // Extract message.date (Unix timestamp) and reject stale messages.
      long msgDate = JsonGetLong(resp, "date",
                                 searchPos - TG_JSON_DATE_SEARCH_WINDOW < 0
                                    ? 0 : searchPos - TG_JSON_DATE_SEARCH_WINDOW);
      if(msgDate != JSON_LONG_NOT_FOUND && msgDate > 0)
      {
         long ageSec = (long)now - msgDate;
         if(ageSec > TG_MAX_MSG_AGE_SEC)
         {
            if(InpDebug) Print(StringFormat("[TG] Discarded stale update_id=%I64d age=%I64ds (>%ds)",
                               updateId, ageSec, TG_MAX_MSG_AGE_SEC));
            continue;
         }
      }

      // Extract the text field; limit search to +500 chars from the update_id end
      // position to stay within this update object.
      string msgText = JsonGetString(resp, "text",
                                     searchPos - TG_JSON_TEXT_SEARCH_WINDOW < 0
                                        ? 0 : searchPos - TG_JSON_TEXT_SEARCH_WINDOW);
      if(msgText != "")
         TG_HandleCommand(msgText);
   }
}

#endif // MSPB_EA_TELEGRAM_MQH
