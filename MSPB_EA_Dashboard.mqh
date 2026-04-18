//+------------------------------------------------------------------+
//| MSPB_EA_Dashboard.mqh                                            |
//| Interactive dashboard buttons and chart-overlay rendering        |
//| Included by MSPB_Expert_Advisor.mq5                              |
//+------------------------------------------------------------------+
#ifndef MSPB_EA_DASHBOARD_MQH
#define MSPB_EA_DASHBOARD_MQH

// -----------------------------------------
// Interactive Dashboard Buttons
// -----------------------------------------
void DashButtons_Create()
{
   if(!InpDashButtons) return;
   string names[4] = {"MSPB_BTN_PAUSE", "MSPB_BTN_RESUME", "MSPB_BTN_RISK_UP", "MSPB_BTN_RISK_DN"};
   string labels[4] = {"⏸ PAUSE", "▶ RESUME", "📈 RISK +", "📉 RISK -"};
   int yPos[4] = {120, 145, 170, 195};
   for(int i = 0; i < 4; i++)
   {
      if(ObjectFind(0, names[i]) < 0)
         ObjectCreate(0, names[i], OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, names[i], OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(0, names[i], OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, names[i], OBJPROP_YDISTANCE, yPos[i]);
      ObjectSetInteger(0, names[i], OBJPROP_XSIZE,     100);
      ObjectSetInteger(0, names[i], OBJPROP_YSIZE,     20);
      ObjectSetInteger(0, names[i], OBJPROP_FONTSIZE,  8);
      ObjectSetString(0,  names[i], OBJPROP_TEXT,      labels[i]);
   }
   color pauseCol = g_tradingPaused ? clrRed : clrGreen;
   ObjectSetInteger(0, "MSPB_BTN_PAUSE", OBJPROP_BGCOLOR, pauseCol);
   ChartRedraw(0);
}

void DashButtons_Delete()
{
   string names[4] = {"MSPB_BTN_PAUSE", "MSPB_BTN_RESUME", "MSPB_BTN_RISK_UP", "MSPB_BTN_RISK_DN"};
   for(int i = 0; i < 4; i++)
      ObjectDelete(0, names[i]);
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   if(!InpDashButtons) return;

   bool handled = false;
   if(sparam == "MSPB_BTN_PAUSE")
   {
      g_tradingPaused = true;
      Print("[DashBtn] Trading PAUSED via dashboard button.");
      if(InpEnableTelegram) TelegramSendMessage("⏸ Trading PAUSED via dashboard button.", TGC_SYSTEM);
      handled = true;
   }
   else if(sparam == "MSPB_BTN_RESUME")
   {
      g_tradingPaused = false;
      Print("[DashBtn] Trading RESUMED via dashboard button.");
      if(InpEnableTelegram) TelegramSendMessage("▶ Trading RESUMED via dashboard button.", TGC_SYSTEM);
      handled = true;
   }
   else if(sparam == "MSPB_BTN_RISK_UP")
   {
      g_riskMultiplierOverride = MathMin(InpMaxRiskMultiplier, g_riskMultiplierOverride * 1.1);
      Print(StringFormat("[DashBtn] Risk multiplier increased to %.3f", g_riskMultiplierOverride));
      handled = true;
   }
   else if(sparam == "MSPB_BTN_RISK_DN")
   {
      g_riskMultiplierOverride = MathMax(0.1, g_riskMultiplierOverride * 0.9);
      Print(StringFormat("[DashBtn] Risk multiplier decreased to %.3f", g_riskMultiplierOverride));
      handled = true;
   }

   if(handled)
   {
      RuntimeState_Save();
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      color pauseCol = g_tradingPaused ? clrRed : clrGreen;
      ObjectSetInteger(0, "MSPB_BTN_PAUSE", OBJPROP_BGCOLOR, pauseCol);
      DashboardUpdate();
      ChartRedraw(0);
   }
}

// -----------------------------------------
// Dashboard rendering
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
   // ObjectFind() returns the object index (>=0) when found, -1 when not found.
   // Do NOT use '!ObjectFind(...)' because index 0 is valid.
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

   if(InpDailyLossLimit_Enable || InpConsecLoss_Enable)
   {
      string guardLine = "";
      if(InpDailyLossLimit_Enable)
      {
         double ddPct = (g_dayStartBalance > 0 ? (g_dayStartBalance - AccountInfoDouble(ACCOUNT_EQUITY)) / g_dayStartBalance * 100.0 : 0.0);
         guardLine += StringFormat("DailyLoss:%.2f%%/%s%.1f%% ", ddPct, (g_dailyLossTripped?"BLOCKED/":""), InpDailyLossLimitPct);
      }
      if(InpConsecLoss_Enable)
      {
         bool blocked = ConsecLoss_IsBlocked();
         guardLine += StringFormat("ConsecL:%d/%d%s", g_consecLosses, InpConsecLoss_MaxN, (blocked?" PAUSED":""));
      }
      color gc = (g_dailyLossTripped || ConsecLoss_IsBlocked()) ? clrOrange : clrSilver;
      DashSetLine(line++, TrimStr(guardLine), gc);
   }

   string entryDrv = (InpUseTimerForEntries ? "TIMER" : "TICK");
   string mgmtDrv  = (InpManageOnTick ? "TICK" : "TIMER");
   string newsLine = StringFormat("%s | SpikeNews:%s | AvoidNewsEntries:%s",
                                 News_StatusLine(),
                                 (InpUseNewsAwareTrailing?"ON":"OFF"),
                                 (InpAvoidEntriesDuringNews?"Y":"N"));
   DashSetLine(line++, StringFormat("Driver: entries=%s manage=%s | %s", entryDrv, mgmtDrv, newsLine), clrSilver);

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

   string rej="Rej:";
   for(int i=1;i<REJ_MAX;i++)
      if(g_rejCounts[i]>0)
         rej += StringFormat(" %s=%d", g_rejNames[i], g_rejCounts[i]);
   DashSetLine(line++, rej, clrSilver);

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

   static const string _bucketNames[4] = {"Asia","London","NY","Other"};
   DashSetLine(line++, "=== EXEC QUALITY ===", clrYellow);
   for(int b=0;b<EXEC_QUAL_BUCKETS;b++)
   {
      double spreadSum=0.0;
      int    totalN=0;
      for(int s=0;s<g_symCount;s++)
      {
         int sn=0; double sa=0.0,sl2=0.0,sw=0.0,sbr=0.0;
         ExecQual_GetStats(s, b, sn, sa, sl2, sw, sbr);
         if(sn>0){ spreadSum+=sa*sn; totalN+=sn; }
      }
      string avgStr = (totalN>0 ? StringFormat("%.2f", spreadSum/totalN) : "n/a");
      DashSetLine(line++, StringFormat("%-6s avg_spd=%s n=%d", _bucketNames[b], avgStr, totalN), clrSilver);
   }

   if(InpShowRejHeatmap)
   {
      DashSetLine(line++, "=== REJECTION HEATMAP ===", clrYellow);
      int maxRej=1;
      for(int h=0;h<24;h++) if(g_rejHour[h]>maxRej) maxRej=g_rejHour[h];
      for(int h=0;h<24;h++)
      {
         if(g_rejHour[h]<=0) continue;
         int barLen = (int)MathRound((double)g_rejHour[h]/maxRej*7);
         string bar="";
         for(int k=0;k<barLen;k++) bar+="█";
         for(int k=barLen;k<7;k++) bar+="░";
         DashSetLine(line++, StringFormat("H%02d: %s (%d)", h, bar, g_rejHour[h]), clrSilver);
      }
   }

   if(InpDashButtons)
   {
      color pauseCol = g_tradingPaused ? clrRed : clrGreen;
      ObjectSetInteger(0, "MSPB_BTN_PAUSE", OBJPROP_BGCOLOR, pauseCol);
   }
}

#endif // MSPB_EA_DASHBOARD_MQH
