// =============================================================================
// MSPB_EA_Dashboard.mqh
// On-chart dashboard for MSPB Expert Advisor
// Extracted from MSPB_Expert_Advisor.mq5 v14.7; EA bumped to v17.2 by this refactor
// =============================================================================
#property strict

// -----------------------------------------
// Dashboard
// -----------------------------------------
void DashClear()
{
   if(!InpShowDashboard) return;
   int total=ObjectsTotal(0,0,-1);
   for(int i=total-1;i>=0;i--)
   {
      string name=ObjectName(0,i,0,-1);
      if(StringFind(name,g_dashObjPrefix)==0)
         ObjectDelete(0,name);
   }
}

void DashSetLine(const int idx, const string text, const color col=clrWhite)
{
   if(!InpShowDashboard) return;
   string name=g_dashObjPrefix+(string)idx;
   // MQL5: ObjectFind() returns an index (>=0) when found, and -1 when not found.
   // Do NOT use '!ObjectFind(...)' because index 0 is valid and '-1' is truthy in C-like contexts.
   if(ObjectFind(0,name) < 0)
   {
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,10);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,10+idx*16);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,10);
      ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
   }
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_COLOR,col);
}

void DashboardUpdate()
{
   if(!InpShowDashboard) return;

   int line=0;
   string ts=NowStr();
   DashSetLine(line++, StringFormat("%s | %s", TG_GetPrefix(), ts), clrWhite);

   string status="OK";
   color statusCol=clrLime;

   if(g_failSafeStopEntries)
   {
      status="FAILSAFE_"+g_failSafeReason;
      statusCol=clrRed;
   }
   else if(InpNews_Enable && News_LastError()!="" && InpNews_FailClosedOnError)
   {
      status="NEWS_FAIL_CLOSED";
      statusCol=clrOrange;
   }

   DashSetLine(line++, StringFormat("Status: %s | EqReg: %s | RiskMult: %.2f", status, EqRegToStr(g_eqRegime), g_riskMult), statusCol);

   // driver + news mode summary
   string entryDrv = (InpUseTimerForEntries ? "TIMER" : "TICK");
   string mgmtDrv  = (InpManageOnTick ? "TICK" : "TIMER");
   string newsLine = StringFormat("%s | SpikeNews:%s | AvoidNewsEntries:%s",
                                 News_StatusLine(),
                                 (InpUseNewsAwareTrailing?"ON":"OFF"),
                                 (InpAvoidEntriesDuringNews?"Y":"N"));
   DashSetLine(line++, StringFormat("Driver: entries=%s manage=%s | %s", entryDrv, mgmtDrv, newsLine), clrSilver);

   // sanity mode status (startup guard for spike/trailing)
   if(InpSanityMode_Enable)
   {
      int ready=Sanity_ReadyCount();
      int rem=Sanity_RemainingSeconds();
      bool warm = (rem>0 || (g_symCount>0 && ready<g_symCount));
      color sc = (warm ? clrOrange : clrSilver);
      string extra = (rem>0 ? StringFormat(" | %ds", rem) : "");
      DashSetLine(line++, StringFormat("Sanity: %s | indReady=%d/%d%s", (warm?"WARMUP":"OK"), ready, g_symCount, extra), sc);
   }

   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   DashSetLine(line++, StringFormat("Balance: %.2f | Equity: %.2f", bal, eq), clrWhite);

   double pr=CurrentPortfolioRiskPct();
   DashSetLine(line++, StringFormat("PortRisk: %.2f%% (max %.2f%%)", pr, InpMaxPortfolioRiskPct), clrSilver);

   // Rejections summary
   string rej="Rej:";
   for(int i=1;i<REJ_MAX;i++)
      if(g_rejCounts[i]>0)
         rej += StringFormat(" %s=%d", g_rejNames[i], g_rejCounts[i]);
   DashSetLine(line++, rej, clrSilver);

   // per symbol short
   for(int s=0;s<g_symCount && line<20;s++)
   {
      string sym=g_syms[s];
      int open=CountOpenPositionsOurMagic(sym);
      double sp=SpreadPips(sym);
      int cdSec=0;
      if(InpUseSymbolCooldown && g_sym[s].cooldownUntil>0)
      {
         datetime now2=TimeCurrent();
         if(now2 < g_sym[s].cooldownUntil) cdSec=(int)(g_sym[s].cooldownUntil - now2);
      }
      if(cdSec>0)
         DashSetLine(line++, StringFormat("%s | open=%d | spread=%.2f | cd=%ds", sym, open, sp, cdSec), clrWhite);
      else
         DashSetLine(line++, StringFormat("%s | open=%d | spread=%.2f", sym, open, sp), clrWhite);
   }
}
