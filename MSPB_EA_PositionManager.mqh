// MSPB_EA_PositionManager.mqh — Deal queue ring-buffer + closed-position tracker
// Included by MSPB_Expert_Advisor.mq5
#ifndef MSPB_EA_POSITIONMANAGER_MQH
#define MSPB_EA_POSITIONMANAGER_MQH

ulong  g_dealQueueTickets[DEAL_QUEUE_MAX];
int    g_dealQHead=0, g_dealQTail=0;
datetime g_dealQLastProgress=0;
int     g_dealQBackoffSec=0;

datetime g_dealQNextTry=0; // NEW: backoff timer for deal queue processing

long   g_posTrackId[MAX_POSITION_TRACK];
double g_posTrackVolIn[MAX_POSITION_TRACK];
double g_posTrackVolOut[MAX_POSITION_TRACK];
double g_posTrackProfit[MAX_POSITION_TRACK];
double g_posTrackRiskMoney[MAX_POSITION_TRACK];
double g_posTrackOpenSum[MAX_POSITION_TRACK];
double g_posTrackSL0[MAX_POSITION_TRACK];
long   g_posTrackLastReason[MAX_POSITION_TRACK];
int    g_posTrackN=0;


// -----------------------------------------
// Closed-position counting helper
// -----------------------------------------
int PosTrackFind(const long posId)
{
   for(int i=0;i<g_posTrackN;i++)
      if(g_posTrackId[i]==posId) return i;
   return -1;
}

// Returns true exactly once when the tracked position becomes fully closed (based on deal volumes).
bool PosTrackUpdate(const string sym,
                    const long posId,
                    const int  dealEntry,
                    const double vol,
                    const double dealProfitSum,
                    const long dealReason,
                    const double dealPrice,
                    const double dealSL,
                    double &outPosProfit,
                    long &outLastReason,
                    double &outPosRiskMoney)
{
   outPosProfit=0.0;
   outLastReason=0;
   outPosRiskMoney=0.0;

   if(posId<=0 || vol<=0.0) return false;

   int idx=PosTrackFind(posId);
   if(idx<0)
   {
      if(g_posTrackN>=ArraySize(g_posTrackId))
      {
         // Tracker full; fall back to counting per exit deal (won't break EA)
         bool isExit = (dealEntry==DEAL_ENTRY_OUT || dealEntry==DEAL_ENTRY_OUT_BY || dealEntry==DEAL_ENTRY_INOUT);
         if(isExit)
         {
            outPosProfit = dealProfitSum;
            outLastReason = dealReason;
         }
         return isExit;
      }
      idx=g_posTrackN++;
      g_posTrackId[idx]=posId;
      g_posTrackVolIn[idx]=0.0;
      g_posTrackVolOut[idx]=0.0;
      g_posTrackProfit[idx]=0.0;
      g_posTrackRiskMoney[idx]=0.0;
      g_posTrackOpenSum[idx]=0.0;
      g_posTrackSL0[idx]=0.0;
      g_posTrackLastReason[idx]=0;
   }

   // Accumulate volume + profit
   if(dealEntry==DEAL_ENTRY_IN || dealEntry==DEAL_ENTRY_INOUT)
      g_posTrackVolIn[idx]+=vol;

   // Track weighted average entry price for fallback risk estimation
   if(dealEntry==DEAL_ENTRY_IN || dealEntry==DEAL_ENTRY_INOUT)
      g_posTrackOpenSum[idx] += dealPrice * vol;

   // Track first seen entry SL as initial SL (fallback)
   if((dealEntry==DEAL_ENTRY_IN || dealEntry==DEAL_ENTRY_INOUT) && dealSL>0.0 && g_posTrackSL0[idx]<=0.0)
      g_posTrackSL0[idx]=dealSL;

   if(dealEntry==DEAL_ENTRY_OUT || dealEntry==DEAL_ENTRY_OUT_BY || dealEntry==DEAL_ENTRY_INOUT)
      g_posTrackVolOut[idx]+=vol;

   // Track initial risk money from entry-side deals when SL is known.
   if((dealEntry==DEAL_ENTRY_IN || dealEntry==DEAL_ENTRY_INOUT) && dealSL>0.0)
   {
      double rm = PositionRiskMoney(sym, dealPrice, dealSL, vol);
      if(rm>0.0) g_posTrackRiskMoney[idx] += rm;
   }

   g_posTrackProfit[idx] += dealProfitSum;

   // Track last exit reason (only meaningful on exit-side deals)
   if(dealEntry==DEAL_ENTRY_OUT || dealEntry==DEAL_ENTRY_OUT_BY || dealEntry==DEAL_ENTRY_INOUT)
      g_posTrackLastReason[idx]=dealReason;

   // If we never saw the entry deal (EA restarted), we cannot reliably count closures unless seeded.
   if(g_posTrackVolIn[idx]<=0.0)
      return false;

   // Fully closed?
   if(g_posTrackVolOut[idx] + 1e-8 >= g_posTrackVolIn[idx])
   {
      outPosProfit    = g_posTrackProfit[idx];
      outLastReason   = g_posTrackLastReason[idx];
      outPosRiskMoney = g_posTrackRiskMoney[idx];

      // Fallback: if entry deals didn't carry DEAL_SL, try compute risk from stored avg entry + initial SL.
      if(outPosRiskMoney<=0.0)
      {
         if(g_posTrackVolIn[idx]>0.0 && g_posTrackSL0[idx]>0.0 && g_posTrackOpenSum[idx]>0.0)
         {
            double avgEntry = g_posTrackOpenSum[idx] / g_posTrackVolIn[idx];
            double rm = PositionRiskMoney(sym, avgEntry, g_posTrackSL0[idx], g_posTrackVolIn[idx]);
            if(rm>0.0) outPosRiskMoney = rm;
         }

         // Rare edge-case: during partial closes, the position can still exist.
         if(outPosRiskMoney<=0.0)
         {
            int tot=PositionsTotal();
            for(int pi=0; pi<tot; pi++)
            {
               ulong pt=PositionGetTicket(pi);
               if(pt==0) continue;
               if(!PositionSelectByTicket(pt)) continue;
               if(!IsMyMagic((long)PositionGetInteger(POSITION_MAGIC))) continue;
               if(PositionGetString(POSITION_SYMBOL)!=sym) continue;
               long pid=(long)PositionGetInteger(POSITION_IDENTIFIER);
               if(pid!=posId) continue;

               double op=PositionGetDouble(POSITION_PRICE_OPEN);
               double slp=PositionGetDouble(POSITION_SL);
               double vv=PositionGetDouble(POSITION_VOLUME);
               double rm = PositionRiskMoney(sym, op, slp, vv);
               if(rm>0.0) { outPosRiskMoney = rm; break; }
            }
         }
      }

      // Remove by swap-with-last
      int last=g_posTrackN-1;
      g_posTrackId[idx]=g_posTrackId[last];
      g_posTrackVolIn[idx]=g_posTrackVolIn[last];
      g_posTrackVolOut[idx]=g_posTrackVolOut[last];
      g_posTrackProfit[idx]=g_posTrackProfit[last];
      g_posTrackRiskMoney[idx]=g_posTrackRiskMoney[last];
      g_posTrackOpenSum[idx]=g_posTrackOpenSum[last];
      g_posTrackSL0[idx]=g_posTrackSL0[last];
      g_posTrackLastReason[idx]=g_posTrackLastReason[last];
      g_posTrackN--;
      return true;
   }
   return false;
}

void PosTrackSeedOpenPositions()
{
   // Reset and seed from currently open positions (useful after EA restart)
   g_posTrackN=0;
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      long magic=(long)PositionGetInteger(POSITION_MAGIC);
      if(!IsMyMagic(magic)) continue;
      string sym=PositionGetString(POSITION_SYMBOL);
      long posId=(long)PositionGetInteger(POSITION_IDENTIFIER);
      double vol=PositionGetDouble(POSITION_VOLUME);
      if(posId<=0 || vol<=0.0) continue;

      if(g_posTrackN>=ArraySize(g_posTrackId)) break;
      g_posTrackId[g_posTrackN]=posId;
      g_posTrackVolIn[g_posTrackN]=vol;
      g_posTrackVolOut[g_posTrackN]=0.0;
      g_posTrackProfit[g_posTrackN]=0.0;
      g_posTrackLastReason[g_posTrackN]=0;
      double openPx=PositionGetDouble(POSITION_PRICE_OPEN);
      double slPx=PositionGetDouble(POSITION_SL);
      g_posTrackOpenSum[g_posTrackN]=openPx*vol;
      g_posTrackSL0[g_posTrackN]=slPx;
      g_posTrackRiskMoney[g_posTrackN]=PositionRiskMoney(sym, openPx, slPx, vol);
      g_posTrackN++;
   }
}

// -----------------------------------------
// Deal queue (track exits precisely)
// -----------------------------------------
bool DealQ_IsEmpty(){ return g_dealQHead==g_dealQTail; }
bool DealQ_Push(const ulong dealTicket)
{
   int next=(g_dealQTail+1)%DEAL_QUEUE_MAX;
   if(next==g_dealQHead) return false; // full
   g_dealQueueTickets[g_dealQTail]=dealTicket;
   g_dealQTail=next;
   return true;
}
bool DealQ_Pop(ulong &dealTicket)
{
   if(DealQ_IsEmpty()) return false;
   dealTicket=g_dealQueueTickets[g_dealQHead];
   g_dealQHead=(g_dealQHead+1)%DEAL_QUEUE_MAX;
   return true;
}

void ProcessDealQueue()
{
   if(DealQ_IsEmpty()) return;

   datetime now=TimeCurrent();

   // NEW: time-based backoff to avoid busy-loop when history is not ready
   if(g_dealQBackoffSec>0 && g_dealQNextTry>0 && now < g_dealQNextTry)
      return;

   static datetime lastHistorySelect=0;

   // Only do HistorySelect occasionally for perf
   if(lastHistorySelect==0 || (now - lastHistorySelect) >= 5)
   {
      int lookbackDays=5;
      if(g_dealQBackoffSec>0) lookbackDays=10;

      datetime from=now - (lookbackDays*86400);

      if(!HistorySelect(from, now))
      {
         // History not available now (connection/busy) -> backoff
         g_dealQBackoffSec = MathMin(60, (g_dealQBackoffSec<=0 ? 1 : g_dealQBackoffSec*2));
         g_dealQNextTry = now + g_dealQBackoffSec;
         return;
      }

      lastHistorySelect=now;
   }

   int processed=0;

   for(int k=0;k<256;k++)
   {
      ulong dealTicket;
      if(!DealQ_Pop(dealTicket)) break;

      if(!HistoryDealSelect(dealTicket))
      {
         // Not available yet -> push back + backoff
         if(!DealQ_Push(dealTicket))
         {
            PrintFormat("DEALQ_OVERFLOW: cannot requeue deal %I64d", (long)dealTicket);
            FailSafe_Trip("DEALQ_OVERFLOW");
         }
         g_dealQBackoffSec = MathMin(60, (g_dealQBackoffSec<=0 ? 1 : g_dealQBackoffSec*2));
         g_dealQNextTry = now + g_dealQBackoffSec;
         break;
      }

      string sym=HistoryDealGetString(dealTicket, DEAL_SYMBOL);
      long magic=HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
      if(!IsMyMagic(magic)) continue;

      long entry=HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      double vol=HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
      long posId=HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      ENUM_DEAL_TYPE dtype=(ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);

      double pSum = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                  + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION)
                  + HistoryDealGetDouble(dealTicket, DEAL_SWAP);
      long reason = HistoryDealGetInteger(dealTicket, DEAL_REASON);
      double posProfit=0.0; long closeReason=0;

      // Update close-tracker for *positions* (robust against multi-fill exits) + collect net P/L
      double dealPrice=HistoryDealGetDouble(dealTicket, DEAL_PRICE);
      // NOTE: Some older MT5 builds don't support DEAL_SL/DEAL_TP deal properties.
      // We recover entry SL/TP from the originating ORDER instead (more compatible).
      double dealSL=0.0;
      ulong orderTicket=(ulong)HistoryDealGetInteger(dealTicket, DEAL_ORDER);
      if(orderTicket>0 && HistoryOrderSelect(orderTicket))
         dealSL=HistoryOrderGetDouble(orderTicket, ORDER_SL);

      double posRiskMoney=0.0;
      bool posClosedNow = PosTrackUpdate(sym, posId,(int)entry,vol,pSum,reason,dealPrice,dealSL,posProfit,closeReason,posRiskMoney);

      if(entry==DEAL_ENTRY_IN || entry==DEAL_ENTRY_INOUT)
      {
         int fillDir=0;
         if(dtype==DEAL_TYPE_BUY) fillDir=1;
         else if(dtype==DEAL_TYPE_SELL) fillDir=-1;
         if(fillDir!=0)
         {
            datetime dealTime=(datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
            ExecQual_HandleEntryFill(dealTicket, sym, fillDir, dealTime, dealPrice);
         }
      }

      // We only log/export for exit-side deals.
      if(!(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY || entry==DEAL_ENTRY_INOUT))
      {
         // Rare edge-case: position closure caused by a non-exit deal (shouldn't normally happen).
         // Count it for proposal triggers to avoid undercounting.
         if(posClosedNow)
         {
            g_closedTradesSinceProposal++;
            CheckTradeCountProposal();
            Audit_Log("POS_CLOSED_NONEXIT_DEAL",
                      StringFormat("sym=%s|posId=%I64d|deal=%I64d|entry=%d", sym, posId, (long)dealTicket, (int)entry),
                      false);
            Cooldown_Apply(sym, now, closeReason, posProfit, posRiskMoney);
            ConsecLoss_OnTradeClosed(posProfit);
            PartialTP_Remove((ulong)posId);
         }
         continue;
      }

      double profit=HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      double price=HistoryDealGetDouble(dealTicket, DEAL_PRICE);
      string comment=HistoryDealGetString(dealTicket, DEAL_COMMENT);
      // reason already fetched above
      // wasSL no longer used (v11)


      // Optional Telegram exit-deal notification (can be noisy)
      if(InpEnableTelegram && InpTGNotifyExitDeals)
      {
         int d=(int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         TelegramSendMessage(StringFormat("EXIT %s | deal=%I64d | profit=%.2f | price=%s | %s",
                                          sym, (long)dealTicket, profit, DoubleToString(price,d), Shorten(comment,40)), TGC_TRADE);
      }

      if(InpEnableMLExport)
      {
         // log posId as pos_id, keep dealTicket in comment
         ML_WriteRowV2("exit", NowStr(), sym, "", "", price, 0,0, 0,0,
                      0,0,0,0,0,
                      "", "",
                      (long)posId, "EXIT", 0, profit, 0,
                      0, "deal="+(string)dealTicket+"|"+Shorten(comment,40), g_mlSchema);
      }
      processed++;

      if(posClosedNow)
      {
         g_closedTradesSinceProposal++;
         Cooldown_Apply(sym, now, closeReason, posProfit, posRiskMoney);
         CheckTradeCountProposal();
         ConsecLoss_OnTradeClosed(posProfit);
         PartialTP_Remove((ulong)posId);
      }

      g_dealQLastProgress=now;
   }

   if(processed>0)
   {
      // success -> reset backoff
      g_dealQBackoffSec=0;
      g_dealQNextTry=0;
      g_dealQLastProgress=now;
   }
}

#endif // MSPB_EA_POSITIONMANAGER_MQH
