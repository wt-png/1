// =============================================================================
// MSPB_EA_OrderExec.mqh
// Order execution helpers for MSPB Expert Advisor
// Extracted from MSPB_Expert_Advisor.mq5 v14.7; EA bumped to v17.2 by this refactor
// =============================================================================
#property strict

// -----------------------------------------
// Stop modification safe helper with logging + optional retry (hedging-safe)
// -----------------------------------------
bool IsTransientRetcode(const int retcode)
{
   // NOTE: keep this list limited to official ENUM_TRADE_RETURN_CODE values to ensure compilation on all MT5 builds.
   // Transient conditions where a short retry can succeed.
   switch(retcode)
   {
      case TRADE_RETCODE_REQUOTE:
      case TRADE_RETCODE_PRICE_CHANGED:
      case TRADE_RETCODE_PRICE_OFF:
      case TRADE_RETCODE_TIMEOUT:
      case TRADE_RETCODE_TOO_MANY_REQUESTS:
      case TRADE_RETCODE_CONNECTION:
         return true;
   }
   return false;
}

// NEW: modify SL/TP by POSITION TICKET (hedging-safe, works on netting too)
bool SendSLTPModifyByTicket(const string sym, const ulong posTicket, const double sl, const double tp, int &retcode, string &comment)
{
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action   = TRADE_ACTION_SLTP;
   req.symbol   = sym;
   req.position = posTicket;
   req.sl       = sl;
   req.tp       = tp;
   req.magic    = InpMagic;

   ResetLastError();
   bool ok = OrderSend(req, res);

   retcode = (int)res.retcode;
   comment = res.comment;

   if(!ok && comment=="")
      comment = "OrderSend failed err=" + (string)GetLastError();

   return ok;
}

bool ModifySL_Safe(const int symIdx,
                   const string sym,
                   const ulong posTicket,     // position ticket (hedging-safe)
                   const long posId,
                   const long type,
                   const string setup,
                   double &slRef,
                   const double tp,
                   const double vol,
                   const double openPrice,
                   const double atrPips,
                   const double profitPips,
                   const double floatMoney,
                   const double floatR,
                   const double newSL,
                   const double minStepPrice,
                   const string modReason,
                   const string kvExtra="")
{
   if(newSL<=0.0) return false;
   if(!CanModifyStopsNow(sym, type, newSL)) return false;

   double pt=SymbolInfoDouble(sym, SYMBOL_POINT);
   double step = (minStepPrice>0.0 ? minStepPrice : pt);
   if(MathAbs(newSL - slRef) < (step - pt*0.5)) return false;

   double oldSL = slRef;

   // Never worsen SL (monotonic). Trailing/BE should only tighten risk.
   if(slRef>0.0)
   {
      if(type==POSITION_TYPE_BUY  && newSL <= slRef) return false;
      if(type==POSITION_TYPE_SELL && newSL >= slRef) return false;
   }


   bool accepted=false;
   int ret=0;
   string comm="";
   int tries=0;

   int maxRetries = (InpSLModRetryTransient ? MathMax(0, InpSLModMaxRetries) : 0);
   // Avoid rapid retry bursts in tick-based management
   if(InpManageOnTick) maxRetries = 0;
   for(int attempt=0; attempt<=maxRetries; attempt++)
   {
      tries = attempt+1;

      bool ok = SendSLTPModifyByTicket(sym, posTicket, newSL, tp, ret, comm);
      Status_SetTrade(StringFormat("SLMOD_%s_try%d", modReason, tries), ret, comm);

      accepted = (ret==TRADE_RETCODE_DONE) || (ret==TRADE_RETCODE_NO_CHANGES);
      if(accepted) break;

      if(!(InpSLModRetryTransient && attempt<maxRetries && IsTransientRetcode(ret)))
         break;

      // Short delay between retries (avoid hammering server); avoid Sleep in OnTick mgmt
      if(InpSLModRetrySleepMS>0 && !InpManageOnTick)
         Sleep(InpSLModRetrySleepMS);
   }

   // Always log details when not accepted
   if(!accepted)
   {
      string kv = StringFormat("sym=%s|posTicket=%I64d|posId=%I64d|setup=%s|reason=%s|oldSL=%s|newSL=%s|ret=%d|cmt=%s",
                               sym, (long)posTicket, posId, setup, modReason,
                               FmtPriceSym(sym, oldSL),
                               FmtPriceSym(sym, newSL),
                               ret, KV_Safe(Shorten(comm,80)));
      Audit_Log("SLMOD_FAIL", kv, false);
   }
   else if(tries>1)
   {
      string kv = StringFormat("sym=%s|posTicket=%I64d|posId=%I64d|setup=%s|reason=%s|tries=%d|ret=%d|cmt=%s",
                               sym, (long)posTicket, posId, setup, modReason, tries, ret, KV_Safe(Shorten(comm,80)));
      Audit_Log("SLMOD_RETRY_OK", kv, false);
   }

   if(InpEnableMLExport && InpMLLogSLMods)
   {
      string ts=NowStr();
      string dir=(type==POSITION_TYPE_BUY?"BUY":"SELL");
      string comment = StringFormat("%s|tries=%d|ret=%d|%s", modReason, tries, ret, Shorten(comm,80));
      string kv = StringFormat("oldSL=%s|newSL=%s|posTicket=%I64d|%s",
                               FmtPriceSym(sym, oldSL),
                               FmtPriceSym(sym, newSL),
                               (long)posTicket, kvExtra);
      ML_WriteRowV2("slmod", ts, sym, setup, dir,
                   openPrice, oldSL, tp, vol, 0,
                   atrPips, 0,0, SpreadPips(sym), 0,
                   "", "",
                   posId, "SLMOD", profitPips, floatMoney, floatR,
                   ret, comment, g_mlSchema, kv);
   }

   if(accepted)
      slRef = newSL;

   return accepted;
}



// -----------------------------------------
// Position close helper (hedging + netting, compatible with older builds)
// -----------------------------------------
bool ClosePositionByTicketSafe(const string sym,
                               const ulong posTicket,
                               const long posType,
                               const double volume,
                               const int deviationPts,
                               int &retcode,
                               string &comment)
{
   retcode=0;
   comment="";
   if(sym=="" || posTicket==0 || volume<=0.0) return false;

   double bid=SymbolInfoDouble(sym, SYMBOL_BID);
   double ask=SymbolInfoDouble(sym, SYMBOL_ASK);
   if(bid<=0.0 || ask<=0.0)
   {
      MqlTick tk;
      if(!SymbolInfoTick(sym, tk)) return false;
      bid=tk.bid; ask=tk.ask;
   }

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = sym;
   req.position  = posTicket;
   req.magic     = InpMagic;
   req.volume    = volume;
   req.deviation = (deviationPts>0 ? deviationPts : MathMax(1, InpDev_MinPoints));
   req.type_time = ORDER_TIME_GTC;

   if(posType==POSITION_TYPE_BUY)
   {
      req.type  = ORDER_TYPE_SELL;
      req.price = bid;
   }
   else if(posType==POSITION_TYPE_SELL)
   {
      req.type  = ORDER_TYPE_BUY;
      req.price = ask;
   }
   else
      return false;

   // Best-effort filling mode
   long fm = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if(fm==SYMBOL_FILLING_FOK)      req.type_filling = ORDER_FILLING_FOK;
   else if(fm==SYMBOL_FILLING_IOC) req.type_filling = ORDER_FILLING_IOC;
   else                           req.type_filling = ORDER_FILLING_RETURN;

   ResetLastError();
   bool ok = OrderSend(req, res);

   retcode = (int)res.retcode;
   comment = res.comment;

   if(!ok && comment=="")
      comment = "OrderSend failed err=" + (string)GetLastError();

   return ok;
}
