#ifndef MSPB_EA_RISK_MQH
#define MSPB_EA_RISK_MQH

// =============================================================================
// MSPB_EA_Risk.mqh
// Purpose  : Risk management layer for the MSPB Expert Advisor.
// Inputs   : InpEqDD_*, InpDailyLossLimit_*, InpConsecLoss_*, InpTP_Partial_*
//            (all declared as EA inputs in MSPB_Expert_Advisor.mq5)
// Outputs  : g_eqRegime, g_riskMult, g_dailyLossTripped, g_consecLosses,
//            g_partialDoneN — read by entry logic, dashboard, and position manager.
// Side effects : Sends Telegram alerts via TelegramSendMessage() when limits trip.
// =============================================================================

// -----------------------------------------
// Equity regime
// -----------------------------------------
enum EqRegime { EQ_NEUTRAL=0, EQ_CAUTION=1, EQ_DEFENSIVE=2 };
EqRegime g_eqRegime = EQ_NEUTRAL;
double   g_riskMult  = 1.0;

// Running equity peak/trough used by EqRegime_Update().
double g_eqPeak   = 0.0;
double g_eqTrough = 0.0;

// -----------------------------------------
// Daily loss limit state
// -----------------------------------------
double   g_dayStartBalance  = 0.0;
datetime g_dayStartTime     = 0;
bool     g_dailyLossTripped = false;

// -----------------------------------------
// Consecutive loss guard state
// -----------------------------------------
int      g_consecLosses         = 0;
datetime g_consecLossPauseUntil = 0;

// -----------------------------------------
// Partial TP tracking
// Ring buffer of ticket IDs that already had a partial close applied.
// Capacity mirrors MAX_POSITION_TRACK.
// -----------------------------------------
ulong g_partialDoneTick[MAX_POSITION_TRACK];
int   g_partialDoneN = 0;

// -----------------------------------------
// Partial TP helpers
// -----------------------------------------
bool PartialTP_AlreadyDone(const ulong ticket)
{
   for(int i = 0; i < g_partialDoneN; i++)
      if(g_partialDoneTick[i] == ticket) return true;
   return false;
}

void PartialTP_MarkDone(const ulong ticket)
{
   if(g_partialDoneN < ArraySize(g_partialDoneTick))
      g_partialDoneTick[g_partialDoneN++] = ticket;
   else
      Print("[PARTIAL_TP] WARNING: partial TP ring buffer full (",
            ArraySize(g_partialDoneTick), "). Ticket ", ticket, " not marked.");
}

void PartialTP_Remove(const ulong ticket)
{
   for(int i = 0; i < g_partialDoneN; i++)
   {
      if(g_partialDoneTick[i] == ticket)
      {
         g_partialDoneTick[i] = g_partialDoneTick[--g_partialDoneN];
         return;
      }
   }
}

// -----------------------------------------
// Daily loss limit helpers (3C)
// -----------------------------------------
void DailyLoss_ResetIfNewDay()
{
   if(!InpDailyLossLimit_Enable) return;
   MqlDateTime now_dt; TimeToStruct(TimeCurrent(), now_dt);
   MqlDateTime start_dt;
   bool needReset = (g_dayStartTime == 0);
   if(!needReset && g_dayStartTime > 0)
   {
      TimeToStruct(g_dayStartTime, start_dt);
      needReset = (now_dt.day  != start_dt.day  ||
                   now_dt.mon  != start_dt.mon  ||
                   now_dt.year != start_dt.year);
   }
   if(needReset)
   {
      g_dayStartBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dayStartTime     = TimeCurrent();
      g_dailyLossTripped = false;
   }
}

bool DailyLoss_IsTripped()
{
   if(!InpDailyLossLimit_Enable) return false;
   if(g_dailyLossTripped) return true;
   if(g_dayStartBalance <= 0.0) return false;
   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct = (g_dayStartBalance - eq) / g_dayStartBalance * 100.0;
   if(ddPct >= InpDailyLossLimitPct)
   {
      g_dailyLossTripped = true;
      string msg = StringFormat("DAILY_LOSS_LIMIT hit: %.2f%% (limit=%.2f%%)",
                                ddPct, InpDailyLossLimitPct);
      Print(msg);
      if(InpEnableTelegram) TelegramSendMessage(msg, TGC_RISK);
   }
   return g_dailyLossTripped;
}

// -----------------------------------------
// Consecutive loss guard helpers (3D)
// -----------------------------------------
bool ConsecLoss_IsBlocked()
{
   if(!InpConsecLoss_Enable) return false;
   return (g_consecLossPauseUntil > 0 && TimeCurrent() < g_consecLossPauseUntil);
}

void ConsecLoss_OnTradeClosed(const double profitMoney)
{
   if(!InpConsecLoss_Enable) return;
   if(profitMoney < 0.0)
   {
      g_consecLosses++;
      if(g_consecLosses >= InpConsecLoss_MaxN)
      {
         g_consecLossPauseUntil = TimeCurrent() + (datetime)(InpConsecLoss_CooldownMin * 60);
         g_consecLosses         = 0;
         string msg = StringFormat(
            "CONSEC_LOSS_BLOCK: %d consecutive losses → entries paused for %d min.",
            InpConsecLoss_MaxN, InpConsecLoss_CooldownMin);
         Print(msg);
         if(InpEnableTelegram) TelegramSendMessage(msg, TGC_RISK);
      }
   }
   else
   {
      g_consecLosses = 0;
   }
}

// -----------------------------------------
// Per-symbol risk weight getter (3B)
// Returns the riskWeight override for a symbol, or 1.0 if not set.
// -----------------------------------------
double Sym_RiskWeight(const string sym)
{
   int k = FindOverrideIndex(sym);
   if(k >= 0 && g_ovr[k].riskWeight > 0.0) return g_ovr[k].riskWeight;
   return 1.0;
}

// -----------------------------------------
// Equity regime string helper
// -----------------------------------------
string EqRegToStr(const EqRegime r)
{
   if(r == EQ_NEUTRAL)   return "NEUTRAL";
   if(r == EQ_CAUTION)   return "CAUTION";
   if(r == EQ_DEFENSIVE) return "DEFENSIVE";
   return "?";
}

// -----------------------------------------
// Equity regime update
// Call on every tick/timer to keep g_eqRegime and g_riskMult current.
// -----------------------------------------
void EqRegime_Update()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_eqPeak == 0.0) { g_eqPeak = eq; g_eqTrough = eq; }
   if(eq > g_eqPeak)   g_eqPeak   = eq;
   if(eq < g_eqTrough) g_eqTrough = eq;

   double ddPct = 0.0;
   if(g_eqPeak > 0.0) ddPct = (g_eqPeak - eq) / g_eqPeak * 100.0;

   double cauPct = MathMax(0.1, InpEqDD_Caution_Pct);
   double defPct = MathMax(cauPct + EQ_DD_MIN_THRESHOLD_GAP, InpEqDD_Defensive_Pct);

   // Warn once when the user has set Defensive ≤ Caution (auto-clamped).
   static bool s_warnedDefClamp = false;
   if(!s_warnedDefClamp &&
      (InpEqDD_Defensive_Pct <= InpEqDD_Caution_Pct ||
       (InpEqDD_Defensive_Pct - InpEqDD_Caution_Pct) < EQ_DD_MIN_THRESHOLD_GAP))
   {
      s_warnedDefClamp = true;
      PrintFormat("[EqRegime] WARNING: InpEqDD_Defensive_Pct (%.2f) is too close to or below "
                  "InpEqDD_Caution_Pct (%.2f) (min gap %.2f%%). "
                  "Defensive threshold auto-clamped to %.2f%%.",
                  InpEqDD_Defensive_Pct, InpEqDD_Caution_Pct,
                  EQ_DD_MIN_THRESHOLD_GAP, defPct);
   }

   if(ddPct < cauPct)      g_eqRegime = EQ_NEUTRAL;
   else if(ddPct < defPct) g_eqRegime = EQ_CAUTION;
   else                    g_eqRegime = EQ_DEFENSIVE;

   if(g_eqRegime == EQ_NEUTRAL)
      g_riskMult = 1.0;
   if(g_eqRegime == EQ_CAUTION)
      g_riskMult = MathMax(0.01, MathMin(1.0, InpEqDD_Caution_RiskMult));
   if(g_eqRegime == EQ_DEFENSIVE)
      g_riskMult = MathMax(0.01, MathMin(1.0, InpEqDD_Defensive_RiskMult));
}

#endif // MSPB_EA_RISK_MQH
