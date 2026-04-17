#property strict

input int    InpRisk_Cap_Mode                 = 1;     // 0=Off, 1=Absolute
input double InpRisk_Cap_USD_R                = 1.0;
input double InpRisk_Cap_EUR_R                = 1.0;
input double InpRisk_Cap_GBP_R                = 1.0;
input double InpRisk_Cap_Other_R              = 1.0;
input bool   InpRisk_Cap_LogDetail            = true;
input int    InpRisk_Cap_TelegramCooldownSec  = 120;

input string InpTelegramBotToken              = "";
input string InpTelegramChatId                = "";

enum RiskCapMode
{
   RISK_CAP_OFF = 0,
   RISK_CAP_ABSOLUTE = 1
};

struct CurrencyRiskBuckets
{
   double usd;
   double eur;
   double gbp;
   double other;
};

struct PositionRiskMeta
{
   ulong ticket;
   double initial_r;
};

PositionRiskMeta g_position_risk_meta[];
datetime g_risk_cap_last_telegram_at = 0;

int OnInit()
{
   return(INIT_SUCCEEDED);
}

void OnTick()
{
}

bool RiskCap_ParseBaseQuote(const string raw_symbol, string &base, string &quote)
{
   string letters = "";
   int n = StringLen(raw_symbol);

   for(int i = 0; i < n && StringLen(letters) < 6; ++i)
   {
      ushort ch = (ushort)StringGetCharacter(raw_symbol, i);
      bool isUpper = (ch >= 'A' && ch <= 'Z');
      bool isLower = (ch >= 'a' && ch <= 'z');
      if(!isUpper && !isLower)
         continue;

      if(isLower)
         ch = (ushort)(ch - 32);

      letters += CharToString(ch);
   }

   if(StringLen(letters) < 6)
      return(false);

   base = StringSubstr(letters, 0, 3);
   quote = StringSubstr(letters, 3, 3);
   return(true);
}

void RiskCap_RegisterPositionInitialR(const ulong ticket, const double initial_r)
{
   if(ticket == 0 || initial_r <= 0.0)
      return;

   int sz = ArraySize(g_position_risk_meta);
   for(int i = 0; i < sz; ++i)
   {
      if(g_position_risk_meta[i].ticket == ticket)
      {
         g_position_risk_meta[i].initial_r = initial_r;
         return;
      }
   }

   ArrayResize(g_position_risk_meta, sz + 1);
   g_position_risk_meta[sz].ticket = ticket;
   g_position_risk_meta[sz].initial_r = initial_r;
}

void RiskCap_UnregisterPositionInitialR(const ulong ticket)
{
   int sz = ArraySize(g_position_risk_meta);
   for(int i = 0; i < sz; ++i)
   {
      if(g_position_risk_meta[i].ticket != ticket)
         continue;

      for(int j = i; j < sz - 1; ++j)
         g_position_risk_meta[j] = g_position_risk_meta[j + 1];

      ArrayResize(g_position_risk_meta, sz - 1);
      return;
   }
}

bool RiskCap_GetPositionInitialR(const ulong ticket, double &initial_r)
{
   int sz = ArraySize(g_position_risk_meta);
   for(int i = 0; i < sz; ++i)
   {
      if(g_position_risk_meta[i].ticket == ticket)
      {
         initial_r = g_position_risk_meta[i].initial_r;
         return(true);
      }
   }

   initial_r = 0.0;
   return(false);
}

void RiskCap_AddToBucket(CurrencyRiskBuckets &buckets, const string ccy, const double pos_r)
{
   double abs_r = MathAbs(pos_r);
   if(ccy == "USD")
      buckets.usd += abs_r;
   else if(ccy == "EUR")
      buckets.eur += abs_r;
   else if(ccy == "GBP")
      buckets.gbp += abs_r;
   else
      buckets.other += abs_r;
}

void RiskCap_ZeroBuckets(CurrencyRiskBuckets &buckets)
{
   buckets.usd = 0.0;
   buckets.eur = 0.0;
   buckets.gbp = 0.0;
   buckets.other = 0.0;
}

string RiskCap_FormatBuckets(const CurrencyRiskBuckets &buckets)
{
   return(StringFormat("USD=%.4fR EUR=%.4fR GBP=%.4fR OTHER=%.4fR", buckets.usd, buckets.eur, buckets.gbp, buckets.other));
}

bool RiskCap_ComputeCurrentBuckets(CurrencyRiskBuckets &buckets)
{
   RiskCap_ZeroBuckets(buckets);

   int total = PositionsTotal();
   for(int i = 0; i < total; ++i)
   {
      if(!PositionSelectByIndex(i))
         continue;

      ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      string symbol = PositionGetString(POSITION_SYMBOL);

      double pos_r = 0.0;
      if(!RiskCap_GetPositionInitialR(ticket, pos_r))
      {
         if(InpRisk_Cap_LogDetail)
            PrintFormat("RiskCap: no initial_R metadata for ticket=%I64u symbol=%s", ticket, symbol);
         continue;
      }

      string base, quote;
      if(!RiskCap_ParseBaseQuote(symbol, base, quote))
      {
         if(InpRisk_Cap_LogDetail)
            PrintFormat("RiskCap: failed to parse symbol=%s for ticket=%I64u, assigning to OTHER bucket", symbol, ticket);
         base = "OTHER";
         quote = "OTHER";
      }

      RiskCap_AddToBucket(buckets, base, pos_r);
      RiskCap_AddToBucket(buckets, quote, pos_r);
   }

   return(true);
}

double RiskCap_GetCapByCurrency(const string ccy)
{
   if(ccy == "USD")
      return(InpRisk_Cap_USD_R);
   if(ccy == "EUR")
      return(InpRisk_Cap_EUR_R);
   if(ccy == "GBP")
      return(InpRisk_Cap_GBP_R);
   return(InpRisk_Cap_Other_R);
}

void RiskCap_AppendMlKv(
   string &kv,
   const string symbol,
   const string direction,
   const double intended_r_total,
   const CurrencyRiskBuckets &current,
   const CurrencyRiskBuckets &projected)
{
   string caps = StringFormat("USD=%.4f;EUR=%.4f;GBP=%.4f;OTHER=%.4f", InpRisk_Cap_USD_R, InpRisk_Cap_EUR_R, InpRisk_Cap_GBP_R, InpRisk_Cap_Other_R);
   kv += StringFormat(" risk_cap_event=BLOCKED_CURRENCY_RISK risk_cap_symbol=%s risk_cap_dir=%s risk_cap_intended_r=%.4f risk_cap_current='%s' risk_cap_projected='%s' risk_cap_caps='%s'",
                      symbol,
                      direction,
                      intended_r_total,
                      RiskCap_FormatBuckets(current),
                      RiskCap_FormatBuckets(projected),
                      caps);
}

string RiskCap_UrlEncode(const string text)
{
   uchar bytes[];
   StringToCharArray(text, bytes, 0, StringLen(text), CP_UTF8);

   string out = "";
   int n = ArraySize(bytes);
   for(int i = 0; i < n; ++i)
   {
      int c = (int)bytes[i];

      bool alnum = ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'));
      if(alnum || c == '-' || c == '_' || c == '.' || c == '~')
      {
         out += CharToString((ushort)c);
         continue;
      }

      string hex = StringFormat("%02X", c);
      out += "%" + hex;
   }

   return(out);
}

bool RiskCap_SendTelegramAlert(const string message)
{
   datetime now = TimeCurrent();
   if(InpRisk_Cap_TelegramCooldownSec > 0 && g_risk_cap_last_telegram_at > 0)
   {
      if((now - g_risk_cap_last_telegram_at) < InpRisk_Cap_TelegramCooldownSec)
         return(false);
   }

   g_risk_cap_last_telegram_at = now;

   if(StringLen(InpTelegramBotToken) == 0 || StringLen(InpTelegramChatId) == 0)
   {
      if(InpRisk_Cap_LogDetail)
         Print("RiskCap: Telegram token/chat id not configured; skipping Telegram send.");
      return(false);
   }

   string url = "https://api.telegram.org/bot" + InpTelegramBotToken + "/sendMessage";
   string payload = "chat_id=" + RiskCap_UrlEncode(InpTelegramChatId) + "&text=" + RiskCap_UrlEncode(message);
   uchar body[];
   StringToCharArray(payload, body, 0, StringLen(payload), CP_UTF8);

   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   uchar result[];
   string result_headers;
   ResetLastError();
   int code = WebRequest("POST", url, headers, 5000, body, result, result_headers);

   if(code < 200 || code >= 300)
   {
      if(InpRisk_Cap_LogDetail)
         PrintFormat("RiskCap: Telegram send failed code=%d err=%d", code, GetLastError());
      return(false);
   }

   return(true);
}

bool RiskCap_IsEntryBlockedByCaps(
   const string symbol,
   const bool is_buy,
   const double intended_r_total,
   CurrencyRiskBuckets &current,
   CurrencyRiskBuckets &projected,
   string &reason)
{
   reason = "";

   if(InpRisk_Cap_Mode != RISK_CAP_ABSOLUTE)
      return(false);

   if(intended_r_total <= 0.0)
      return(false);

   if(!RiskCap_ComputeCurrentBuckets(current))
   {
      reason = "failed_compute_current_buckets";
      return(false);
   }

   projected = current;

   string base, quote;
   if(!RiskCap_ParseBaseQuote(symbol, base, quote))
   {
      if(InpRisk_Cap_LogDetail)
         PrintFormat("RiskCap: failed to parse entry symbol=%s, assigning intended risk to OTHER bucket", symbol);
      base = "OTHER";
      quote = "OTHER";
   }

   RiskCap_AddToBucket(projected, base, intended_r_total);
   RiskCap_AddToBucket(projected, quote, intended_r_total);

   bool blocked = false;
   if(projected.usd > InpRisk_Cap_USD_R)
   {
      blocked = true;
      reason += "USD ";
   }
   if(projected.eur > InpRisk_Cap_EUR_R)
   {
      blocked = true;
      reason += "EUR ";
   }
   if(projected.gbp > InpRisk_Cap_GBP_R)
   {
      blocked = true;
      reason += "GBP ";
   }
   if(projected.other > InpRisk_Cap_Other_R)
   {
      blocked = true;
      reason += "OTHER ";
   }

   return(blocked);
}

bool RiskCap_CheckEntryAllowed(const string symbol, const bool is_buy, const double intended_r_total, string &ml_kv)
{
   // Entry-only gate. Do NOT call this for exits, SL/TP modifications, or protective actions.
   CurrencyRiskBuckets current, projected;
   string reason;
   bool blocked = RiskCap_IsEntryBlockedByCaps(symbol, is_buy, intended_r_total, current, projected, reason);
   if(!blocked)
      return(true);

   string direction = is_buy ? "BUY" : "SELL";
   PrintFormat(
      "BLOCKED_CURRENCY_RISK symbol=%s direction=%s intended_R_total=%.4f current={%s} projected={%s} caps={USD=%.4fR EUR=%.4fR GBP=%.4fR OTHER=%.4fR} reason=%s",
      symbol,
      direction,
      intended_r_total,
      RiskCap_FormatBuckets(current),
      RiskCap_FormatBuckets(projected),
      InpRisk_Cap_USD_R,
      InpRisk_Cap_EUR_R,
      InpRisk_Cap_GBP_R,
      InpRisk_Cap_Other_R,
      reason);

   RiskCap_SendTelegramAlert(StringFormat(
      "BLOCKED_CURRENCY_RISK %s %s intended=%.2fR current[%s] projected[%s] caps[USD=%.2f EUR=%.2f GBP=%.2f OTHER=%.2f]",
      symbol,
      direction,
      intended_r_total,
      RiskCap_FormatBuckets(current),
      RiskCap_FormatBuckets(projected),
      InpRisk_Cap_USD_R,
      InpRisk_Cap_EUR_R,
      InpRisk_Cap_GBP_R,
      InpRisk_Cap_Other_R));

   // If ML export is enabled by existing EA plumbing, append KV tags without changing schema.
   RiskCap_AppendMlKv(ml_kv, symbol, direction, intended_r_total, current, projected);

   return(false);
}
