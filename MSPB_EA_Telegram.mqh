// =============================================================================
// MSPB_EA_Telegram.mqh
// Telegram Bot API integration for MSPB Expert Advisor
// Extracted from MSPB_Expert_Advisor.mq5 v14.7; EA bumped to v17.2 by this refactor
// =============================================================================
#property strict

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

bool TelegramSendMessage(const string msg)
{
   if(!InpEnableTelegram) return false;

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
