#ifndef MSPB_EA_EXECQUAL_MQH
#define MSPB_EA_EXECQUAL_MQH

// -----------------------------------------
// Execution-Quality gate (ExecQual)
//
// Tracks per-symbol/per-session spread and slippage samples in
// rolling windows and gates new entries when execution quality has
// degraded beyond configurable thresholds.
//
// Dependencies (resolved from the main compilation unit):
//   Inputs  : InpExecQual_*, InpEnableTelegram, InpDebug,
//             InpEnableMLExport, InpExecQual_BadSlipPips,
//             InpExecQual_MaxBadFillRate, InpExecQual_SpreadAvgMult,
//             InpExecQual_BlockCooldownSec, InpExecQual_TelegramCooldownSec,
//             InpMinMinutesBetweenEntriesPerSymbol,
//             InpExecQual_Persist, InpExecQual_PersistFile,
//             InpExecQual_AdaptThresholds, InpExecQual_LearnRate,
//             InpExecQual_LearnMinSamples, InpExecQual_LearnIntervalMin
//   Globals : g_symCount, g_syms (from main file)
//   Funcs   : TelegramSendMessage, Audit_Log, ML_WriteRowV2,
//             GetSessionBucket, SessionBucketName,
//             SymIndexByNameLoose, PipSize, IsMyMagic,
//             IncReject, NowStr, TrimStr
//   Enum    : SessionBucket (SESSION_ASIA/LONDON/NEWYORK/UNKNOWN),
//             EXEC_QUAL_OFF / EXEC_QUAL_SHADOW / EXEC_QUAL_ENFORCE,
//             REJ_RISK_GUARDS
// -----------------------------------------

// --- ExecQual constants -------------------------------------------------
#define EXEC_QUAL_BUCKETS          4
#define EXEC_QUAL_MAX_WINDOW       256    // max rolling samples per (symbol, bucket)
#define EXEC_QUAL_INTENT_MAX       128    // ring capacity for pending entry intents
#define EXEC_QUAL_SEEN_DEALS_MAX   512    // deduplication ring for processed deal tickets
#define EXEC_QUAL_INT_MATCH_MAX_SEC 300   // max seconds between intent and fill for matching
#define EXEC_QUAL_INT_MAX          2147483647
#define EXEC_QUAL_EPS              1e-12
#define EXEC_QUAL_SEC_PER_MIN      60

// Flatten 3-D [MAX_SYMBOLS][EXEC_QUAL_BUCKETS][EXEC_QUAL_MAX_WINDOW] → 1-D index
#define ExecIdx(sym,bucket,pos) ((sym)*EXEC_QUAL_BUCKETS*EXEC_QUAL_MAX_WINDOW+(bucket)*EXEC_QUAL_MAX_WINDOW+(pos))

// --- ExecQual global state ----------------------------------------------
string   g_execIntentSym[EXEC_QUAL_INTENT_MAX];
int      g_execIntentDir[EXEC_QUAL_INTENT_MAX];
double   g_execIntentReqPrice[EXEC_QUAL_INTENT_MAX];
int      g_execIntentDevPts[EXEC_QUAL_INTENT_MAX];
double   g_execIntentSpreadPips[EXEC_QUAL_INTENT_MAX];
datetime g_execIntentTs[EXEC_QUAL_INTENT_MAX];
string   g_execIntentSetup[EXEC_QUAL_INTENT_MAX];
int      g_execIntentHead = 0;

ulong    g_execSeenDeals[EXEC_QUAL_SEEN_DEALS_MAX];
int      g_execSeenDealsHead = 0;

// Dynamic history arrays — allocated in OnInit via ArrayResize.
double   g_execSpreadHist[];
double   g_execSlipHist[];
uchar    g_execBadHist[];

int      g_execHistN[MAX_SYMBOLS][EXEC_QUAL_BUCKETS];
int      g_execHistPos[MAX_SYMBOLS][EXEC_QUAL_BUCKETS];
double   g_execSpreadSum[MAX_SYMBOLS][EXEC_QUAL_BUCKETS];
double   g_execSlipSum[MAX_SYMBOLS][EXEC_QUAL_BUCKETS];
int      g_execBadCount[MAX_SYMBOLS][EXEC_QUAL_BUCKETS];
double   g_execWorstSlip[MAX_SYMBOLS][EXEC_QUAL_BUCKETS];

datetime g_execLastEntryIntent[MAX_SYMBOLS];
datetime g_execBlockUntil[MAX_SYMBOLS];
datetime g_execQualLastTG    = 0;
datetime g_execQual_lastSave = 0;
datetime g_execQual_lastLearn= 0;
bool     g_execQual_dirty    = false;  // true when state has changed since last file save

double   g_execSlipThresh[EXEC_QUAL_BUCKETS];
double   g_execSpreadThresh[EXEC_QUAL_BUCKETS];

// --- Functions ----------------------------------------------------------

int ExecQual_WindowSize()
{
   int w = MathMax(5, InpExecQual_WindowPerBucket);
   if(w > EXEC_QUAL_MAX_WINDOW) w = EXEC_QUAL_MAX_WINDOW;
   return w;
}

void ExecQual_RecomputeWorstSlip(const int symIdx, const int bucket)
{
   if(symIdx < 0 || symIdx >= MAX_SYMBOLS || bucket < 0 || bucket >= EXEC_QUAL_BUCKETS) return;
   int n = g_execHistN[symIdx][bucket];
   if(n <= 0) { g_execWorstSlip[symIdx][bucket] = 0.0; return; }
   double w = 0.0;
   for(int i = 0; i < n; i++)
      if(g_execSlipHist[ExecIdx(symIdx, bucket, i)] > w)
         w = g_execSlipHist[ExecIdx(symIdx, bucket, i)];
   g_execWorstSlip[symIdx][bucket] = w;
}

void ExecQual_AddSample(const int symIdx,
                        const int bucket,
                        const double spreadPips,
                        const double absSlipPips)
{
   if(symIdx < 0 || symIdx >= MAX_SYMBOLS || bucket < 0 || bucket >= EXEC_QUAL_BUCKETS) return;
   int w   = ExecQual_WindowSize();
   int n   = g_execHistN[symIdx][bucket];
   int p   = g_execHistPos[symIdx][bucket];
   int bad = (absSlipPips > MathMax(0.0, InpExecQual_BadSlipPips) ? 1 : 0);

   if(n < w)
   {
      g_execSpreadHist[ExecIdx(symIdx, bucket, n)] = spreadPips;
      g_execSlipHist[ExecIdx(symIdx, bucket, n)]   = absSlipPips;
      g_execBadHist[ExecIdx(symIdx, bucket, n)]    = (uchar)bad;
      g_execHistN[symIdx][bucket]                  = n + 1;
      g_execSpreadSum[symIdx][bucket]             += spreadPips;
      g_execSlipSum[symIdx][bucket]               += absSlipPips;
      g_execBadCount[symIdx][bucket]              += bad;
      if(absSlipPips > g_execWorstSlip[symIdx][bucket]) g_execWorstSlip[symIdx][bucket] = absSlipPips;
      return;
   }

   double oldSpread = g_execSpreadHist[ExecIdx(symIdx, bucket, p)];
   double oldSlip   = g_execSlipHist[ExecIdx(symIdx, bucket, p)];
   int    oldBad    = (int)g_execBadHist[ExecIdx(symIdx, bucket, p)];

   g_execSpreadHist[ExecIdx(symIdx, bucket, p)] = spreadPips;
   g_execSlipHist[ExecIdx(symIdx, bucket, p)]   = absSlipPips;
   g_execBadHist[ExecIdx(symIdx, bucket, p)]    = (uchar)bad;
   g_execHistPos[symIdx][bucket]                = (p + 1) % w;

   g_execSpreadSum[symIdx][bucket] += (spreadPips  - oldSpread);
   g_execSlipSum[symIdx][bucket]   += (absSlipPips - oldSlip);
   g_execBadCount[symIdx][bucket]  += (bad - oldBad);
   if(absSlipPips >= g_execWorstSlip[symIdx][bucket])
      g_execWorstSlip[symIdx][bucket] = absSlipPips;
   else if(oldSlip >= g_execWorstSlip[symIdx][bucket] - EXEC_QUAL_EPS)
      ExecQual_RecomputeWorstSlip(symIdx, bucket);
   g_execQual_dirty = true;
}

void ExecQual_GetStats(const int symIdx,
                       const int bucket,
                       int &nOut,
                       double &avgSpreadOut,
                       double &avgSlipOut,
                       double &worstSlipOut,
                       double &badRateOut)
{
   nOut = 0; avgSpreadOut = 0.0; avgSlipOut = 0.0; worstSlipOut = 0.0; badRateOut = 0.0;
   if(symIdx < 0 || symIdx >= MAX_SYMBOLS || bucket < 0 || bucket >= EXEC_QUAL_BUCKETS) return;
   int n = g_execHistN[symIdx][bucket];
   if(n <= 0) return;
   nOut         = n;
   avgSpreadOut = g_execSpreadSum[symIdx][bucket] / n;
   avgSlipOut   = g_execSlipSum[symIdx][bucket]   / n;
   worstSlipOut = g_execWorstSlip[symIdx][bucket];
   badRateOut   = ((double)g_execBadCount[symIdx][bucket]) / n;
}

bool ExecQual_IsDealSeen(const ulong dealTicket)
{
   if(dealTicket == 0) return true;
   for(int i = 0; i < EXEC_QUAL_SEEN_DEALS_MAX; i++)
   {
      if(g_execSeenDeals[i] == 0) break;
      if(g_execSeenDeals[i] == dealTicket) return true;
   }
   return false;
}

void ExecQual_MarkDealSeen(const ulong dealTicket)
{
   if(dealTicket == 0) return;
   g_execSeenDeals[g_execSeenDealsHead] = dealTicket;
   g_execSeenDealsHead = (g_execSeenDealsHead + 1) % EXEC_QUAL_SEEN_DEALS_MAX;
}

void ExecQual_RecordEntryIntent(const int symIdx,
                                const string sym,
                                const int dir,
                                const double reqPrice,
                                const int devPts,
                                const double spreadPips,
                                const string setup)
{
   datetime now = TimeCurrent();
   int i = g_execIntentHead;
   g_execIntentSym[i]        = sym;
   g_execIntentDir[i]        = dir;
   g_execIntentReqPrice[i]   = reqPrice;
   g_execIntentDevPts[i]     = devPts;
   g_execIntentSpreadPips[i] = spreadPips;
   g_execIntentTs[i]         = now;
   g_execIntentSetup[i]      = setup;
   g_execIntentHead          = (g_execIntentHead + 1) % EXEC_QUAL_INTENT_MAX;
   if(symIdx >= 0 && symIdx < MAX_SYMBOLS) g_execLastEntryIntent[symIdx] = now;
}

int ExecQual_FindIntent(const string sym, const int dir, const datetime dealTime)
{
   int best = -1;
   int bestDeltaSec = EXEC_QUAL_INT_MAX;
   for(int i = 0; i < EXEC_QUAL_INTENT_MAX; i++)
   {
      if(g_execIntentTs[i] <= 0) continue;
      if(g_execIntentDir[i] != dir) continue;
      if(g_execIntentSym[i] != sym) continue;
      int deltaSec = (int)MathAbs(dealTime - g_execIntentTs[i]);
      if(deltaSec > EXEC_QUAL_INT_MATCH_MAX_SEC) continue;
      if(deltaSec < bestDeltaSec) { best = i; bestDeltaSec = deltaSec; }
   }
   return best;
}

bool ExecQual_ShouldSendTelegram()
{
   if(!InpEnableTelegram) return false;
   datetime now = TimeCurrent();
   int cd = MathMax(1, InpExecQual_TelegramCooldownSec);
   if(g_execQualLastTG > 0 && (now - g_execQualLastTG) < cd) return false;
   g_execQualLastTG = now;
   return true;
}

void ExecQual_HandleEntryFill(const ulong dealTicket,
                              const string sym,
                              const int dir,
                              const datetime dealTime,
                              const double dealPrice)
{
   if(ExecQual_IsDealSeen(dealTicket)) return;
   ExecQual_MarkDealSeen(dealTicket);

   int symIdx = SymIndexByNameLoose(sym);
   if(symIdx < 0 || symIdx >= g_symCount) return;
   int bucket    = GetSessionBucket(dealTime);
   int intentIdx = ExecQual_FindIntent(sym, dir, dealTime);
   if(intentIdx < 0) return;

   double pip = PipSize(sym);
   if(pip <= 0.0) return;
   double req = g_execIntentReqPrice[intentIdx];
   if(req <= 0.0) return;

   double absSlipPips = MathAbs(dealPrice - req) / pip;
   ExecQual_AddSample(symIdx, bucket, g_execIntentSpreadPips[intentIdx], absSlipPips);

   g_execIntentTs[intentIdx]  = 0;
   g_execIntentSym[intentIdx] = "";
}

void ExecQual_TryCaptureDeal(const ulong dealTicket)
{
   if(dealTicket == 0 || ExecQual_IsDealSeen(dealTicket)) return;
   if(!HistoryDealSelect(dealTicket)) return;
   if(!IsMyMagic((long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC))) return;

   long entry = (long)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   if(!(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)) return;

   ENUM_DEAL_TYPE dtype = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   int dir = 0;
   if(dtype == DEAL_TYPE_BUY)  dir =  1;
   else if(dtype == DEAL_TYPE_SELL) dir = -1;
   if(dir == 0) return;

   string   sym      = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   datetime dealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
   double   dealPrice= HistoryDealGetDouble(dealTicket, DEAL_PRICE);
   ExecQual_HandleEntryFill(dealTicket, sym, dir, dealTime, dealPrice);
}

// Online learning of ExecQual thresholds via 75th-percentile update.
void ExecQual_AdaptThresholds()
{
   if(!InpExecQual_AdaptThresholds) return;
   datetime now = TimeCurrent();
   int intervalSec = MathMax(1, InpExecQual_LearnIntervalMin) * 60;
   if(g_execQual_lastLearn > 0 && (now - g_execQual_lastLearn) < intervalSec) return;
   g_execQual_lastLearn = now;

   int    minSamples = MathMax(1, InpExecQual_LearnMinSamples);
   double lr         = MathMax(0.0, MathMin(1.0, InpExecQual_LearnRate));
   int    w          = ExecQual_WindowSize();

   // Pre-allocate to the theoretical maximum to avoid O(n²) ArrayResize inside the loop.
   int maxSamples = MAX_SYMBOLS * w;
   double spreadArr[];
   double slipArr[];
   ArrayResize(spreadArr, maxSamples);
   ArrayResize(slipArr,   maxSamples);

   for(int b = 0; b < EXEC_QUAL_BUCKETS; b++)
   {
      int totalN = 0;

      for(int s = 0; s < MAX_SYMBOLS; s++)
      {
         int n = g_execHistN[s][b];
         if(n <= 0) continue;
         int cnt  = MathMin(n, w);
         int head = g_execHistPos[s][b];
         for(int k = 0; k < cnt; k++)
         {
            int pos = (head - cnt + k + w) % w;
            spreadArr[totalN] = g_execSpreadHist[ExecIdx(s, b, pos)];
            slipArr[totalN]   = g_execSlipHist[ExecIdx(s, b, pos)];
            totalN++;
         }
      }

      if(totalN < minSamples) continue;

      // Sort copies to find 75th percentile (ArraySort sorts in-place ascending).
      double spreadSorted[];
      double slipSorted[];
      ArrayCopy(spreadSorted, spreadArr, 0, 0, totalN);
      ArrayCopy(slipSorted,   slipArr,   0, 0, totalN);
      ArraySort(spreadSorted);
      ArraySort(slipSorted);
      int p75idx = (int)MathFloor(totalN * 0.75);
      if(p75idx >= totalN) p75idx = totalN - 1;
      double p75spread = spreadSorted[p75idx];
      double p75slip   = slipSorted[p75idx];

      // Exponential moving average update with 20 % tolerance above the 75th percentile.
      double newSpreadMult = g_execSpreadThresh[b] * (1.0 - lr) + (p75spread * 1.2) * lr;
      double newSlipThresh = g_execSlipThresh[b]   * (1.0 - lr) + (p75slip   * 1.2) * lr;

      g_execSpreadThresh[b] = MathMax(0.1, newSpreadMult);
      g_execSlipThresh[b]   = MathMax(0.0, newSlipThresh);
      g_execQual_dirty      = true;

      Print(StringFormat("[ExecQual_Adapt] bucket=%d N=%d p75_spread=%.4f p75_slip=%.4f"
            " new_spread_mult=%.4f new_slip_thresh=%.4f",
            b, totalN, p75spread, p75slip, g_execSpreadThresh[b], g_execSlipThresh[b]));
   }
}

bool ExecQual_AllowsEntry(const int symIdx,
                          const string sym,
                          const string dir,
                          const string setup,
                          const double spreadNowPips,
                          const double riskMoney,
                          const double atrPips,
                          const double adxTrend,
                          const double adxEntry,
                          const double bodyPips)
{
   if(InpExecQual_Mode <= EXEC_QUAL_OFF) return true;

   datetime now    = TimeCurrent();
   int      bucket = GetSessionBucket(now);

   string reason = "";
   if(bucket == SESSION_ASIA && !InpAllowAsiaEntries)
      reason = "SESSION_ASIA_DISABLED";
   else if(bucket == SESSION_UNKNOWN)
      reason = "SESSION_UNKNOWN_DISABLED";
   else if(InpExecQual_BlockCooldownSec > 0 &&
           g_execBlockUntil[symIdx] > 0 &&
           now < g_execBlockUntil[symIdx])
      reason = "EXEC_BLOCK_COOLDOWN";
   else if(InpMinMinutesBetweenEntriesPerSymbol > 0 &&
           g_execLastEntryIntent[symIdx] > 0 &&
           (now - g_execLastEntryIntent[symIdx]) <
              (InpMinMinutesBetweenEntriesPerSymbol * EXEC_QUAL_SEC_PER_MIN))
      reason = "ENTRY_SYMBOL_COOLDOWN";

   int    n = 0;
   double avgSpread = 0.0, avgSlip = 0.0, worstSlip = 0.0, badRate = 0.0;
   ExecQual_GetStats(symIdx, bucket, n, avgSpread, avgSlip, worstSlip, badRate);

   if(reason == "" && n > 0 && avgSpread > 0.0)
   {
      double mult = MathMax(0.1, g_execSpreadThresh[bucket]);
      if(spreadNowPips > (avgSpread * mult))
         reason = "SPREAD_SHOCK";
   }
   if(reason == "" && n > 0)
   {
      if(badRate > MathMax(0.0, InpExecQual_MaxBadFillRate))
         reason = "BAD_FILL_RATE_DEGRADED";
      else if(avgSlip > MathMax(0.0, g_execSlipThresh[bucket]))
         reason = "AVG_SLIPPAGE_DEGRADED";
   }

   if(reason == "") return true;

   string kv = StringFormat(
      "symbol=%s|dir=%s|setup=%s|SESSION_BUCKET=%s|WOULD_BLOCK_REASON=%s|mode=%d"
      "|spread_now=%.2f|spread_avg=%.2f|slip_avg=%.2f|slip_worst=%.2f"
      "|bad_fill_rate=%.2f|N=%d",
      sym, dir, setup, SessionBucketName(bucket), reason, InpExecQual_Mode,
      spreadNowPips, avgSpread, avgSlip, worstSlip, badRate, n);
   string mlKv = StringFormat(
      "SESSION_BUCKET=%s|WOULD_BLOCK_REASON=%s|spread_now=%.2f|spread_avg=%.2f"
      "|slip_avg=%.2f|slip_worst=%.2f|bad_fill_rate=%.2f|N=%d",
      SessionBucketName(bucket), reason,
      spreadNowPips, avgSpread, avgSlip, worstSlip, badRate, n);

   bool   enforce = (InpExecQual_Mode == EXEC_QUAL_ENFORCE);
   string ev      = (enforce ? "BLOCKED_ENTRY" : "WOULD_BLOCK_ENTRY");
   Audit_Log(ev, kv, false);

   if(InpEnableMLExport)
   {
      string rid     = (enforce ? "entry_block" : "entry_would_block");
      string comment = (ev + "|" + mlKv);
      ML_WriteRowV2(rid, NowStr(), sym, setup, dir,
                    0, 0, 0, 0, riskMoney,
                    atrPips, adxTrend, adxEntry, spreadNowPips, bodyPips,
                    "EXEC_QUALITY", reason,
                    0, ev, 0, 0, 0,
                    0, comment, g_mlSchema);
   }

   if(ExecQual_ShouldSendTelegram())
      TelegramSendMessage(StringFormat("%s %s %s %s", ev, sym, dir, mlKv), TGC_ALERT);

   if(!enforce) return true;

   if(InpExecQual_BlockCooldownSec > 0)
      g_execBlockUntil[symIdx] = now + (datetime)InpExecQual_BlockCooldownSec;
   IncReject(symIdx, REJ_RISK_GUARDS);
   return false;
}

// -----------------------------------------
// ExecQual CSV persistence
// -----------------------------------------
void ExecQual_SaveState()
{
   if(!InpExecQual_Persist) return;
   if(TrimStr(InpExecQual_PersistFile) == "") return;
   if(!g_execQual_dirty) return;   // skip write when nothing changed

   int h = FileOpen(InpExecQual_PersistFile, FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(h == INVALID_HANDLE)
   {
      Print("[ExecQual] SaveState: FileOpen failed err=", GetLastError());
      return;
   }
   FileWrite(h, "sym", "bucket", "avgSpread", "avgSlip", "badRate", "samples");
   for(int s = 0; s < g_symCount; s++)
   {
      for(int b = 0; b < EXEC_QUAL_BUCKETS; b++)
      {
         int    n = 0;
         double avgSpread = 0.0, avgSlip = 0.0, worstSlip = 0.0, badRate = 0.0;
         ExecQual_GetStats(s, b, n, avgSpread, avgSlip, worstSlip, badRate);
         FileWrite(h, g_syms[s], b,
                   DoubleToString(avgSpread, 6),
                   DoubleToString(avgSlip,   6),
                   DoubleToString(badRate,   6),
                   n);
      }
   }
   FileClose(h);
   g_execQual_lastSave = TimeCurrent();
   g_execQual_dirty    = false;
   if(InpDebug) Print("[ExecQual] State saved to ", InpExecQual_PersistFile);
}

bool ExecQual_LoadState()
{
   if(!InpExecQual_Persist) return false;
   if(TrimStr(InpExecQual_PersistFile) == "") return false;

   ResetLastError();
   int h = FileOpen(InpExecQual_PersistFile, FILE_READ|FILE_CSV|FILE_ANSI);
   if(h == INVALID_HANDLE)
   {
      if(InpDebug) Print("[ExecQual] LoadState: file not found (",
                         InpExecQual_PersistFile, "), starting fresh.");
      return false;
   }
   // Skip header row (6 columns).
   if(!FileIsEnding(h))
      for(int col = 0; col < 6; col++) FileReadString(h);

   int loaded = 0;
   while(!FileIsEnding(h))
   {
      string symName     = FileReadString(h);
      string bucketStr   = FileReadString(h);
      string avgSpreadStr= FileReadString(h);
      string avgSlipStr  = FileReadString(h);
      string badRateStr  = FileReadString(h);
      string samplesStr  = FileReadString(h);
      if(symName == "") continue;
      int    bucket = (int)StringToInteger(bucketStr);
      double avgSp  = StringToDouble(avgSpreadStr);
      double avgSl  = StringToDouble(avgSlipStr);
      int    nSamp  = (int)StringToInteger(samplesStr);
      if(bucket < 0 || bucket >= EXEC_QUAL_BUCKETS) continue;
      if(nSamp <= 0) continue;
      int symIdx = SymIndexByNameLoose(symName);
      if(symIdx < 0 || symIdx >= g_symCount) continue;
      // Inject a small number of synthetic samples to seed the baselines.
      int injectN = MathMin(nSamp, 5);
      for(int i = 0; i < injectN; i++)
         ExecQual_AddSample(symIdx, bucket, avgSp, avgSl);
      loaded++;
   }
   FileClose(h);
   if(InpDebug) Print("[ExecQual] LoadState: loaded ", loaded,
                      " bucket rows from ", InpExecQual_PersistFile);
   return loaded > 0;
}

#endif // MSPB_EA_EXECQUAL_MQH
