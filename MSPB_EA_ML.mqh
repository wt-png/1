#ifndef MSPB_EA_ML_MQH
#define MSPB_EA_ML_MQH

// --- ML export state
int    g_mlHandle=INVALID_HANDLE;
string g_mlSchema="v2";
int    g_mlRowsSinceFlush=0;
datetime g_mlLastRot=0;

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
         "slmod_ret","comment","schema",
         "day_of_week","hour_of_day","session_bucket","eq_regime","vol_regime"
      );
      // config row
      FileWrite(g_mlHandle, "cfg", NowStr(), "", "", "", "", "", "", "", "",
                "", "", "", "", "", "", "",
                "", "CONFIG", "", "", "",
                "", "schema="+g_mlSchema, g_mlSchema,
                "", "", "", "", "");
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
   const string kv="",
   // 6A: new context columns (default empty for backward compat)
   const string ctx_dow="",
   const string ctx_hour="",
   const string ctx_session="",
   const string ctx_eq_regime="",
   const string ctx_vol_regime=""
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
      schema,
      ctx_dow, ctx_hour, ctx_session, ctx_eq_regime, ctx_vol_regime
   );
   g_mlRowsSinceFlush++;
   ML_MaybeFlush();
}

#endif // MSPB_EA_ML_MQH
