// MSPB_EA_ExecQual.mqh — v18.0
// Execution quality gate: sanity mode (startup indicator readiness guard).
// Globals used from MSPB_Expert_Advisor.mq5:
//   g_startTime, g_sanityNextCheck, g_indReady[], g_symCount, g_atrHandle[],
//   InpSanityMode_Enable, InpSanityMode_Seconds
#pragma once

// -----------------------------------------
// Sanity mode (startup indicator readiness guard)
// -----------------------------------------
void Sanity_Reset()
{
   g_startTime = TimeCurrent();
   g_sanityNextCheck = 0;
   for(int i=0;i<64;i++) g_indReady[i]=false;
}

void Sanity_UpdateReadiness()
{
   if(!InpSanityMode_Enable) return;
   datetime now=TimeCurrent();
   if(g_sanityNextCheck!=0 && now < g_sanityNextCheck) return;
   g_sanityNextCheck = now + 1; // probe at most once per second (cheap + avoids tick spam)

   // if already all ready, we can stop probing
   int ready=0;
   for(int i=0;i<g_symCount;i++) if(g_indReady[i]) ready++;
   if(g_symCount>0 && ready>=g_symCount) return;

   for(int i=0;i<g_symCount;i++)
   {
      if(g_indReady[i]) continue;

      // Trailing/spike logic needs ATR only. If ADX is missing or never becomes ready,
      // we still want management features to work.
      double b1[1];
      bool okAtr = (g_atrHandle[i]!=INVALID_HANDLE && CopyLast(g_atrHandle[i],0,0,1,b1));
      if(okAtr) g_indReady[i]=true;
   }
}

int Sanity_ReadyCount()
{
   int c=0;
   for(int i=0;i<g_symCount;i++) if(g_indReady[i]) c++;
   return c;
}

int Sanity_RemainingSeconds()
{
   if(!InpSanityMode_Enable) return 0;
   if(InpSanityMode_Seconds<=0) return 0;
   datetime now=TimeCurrent();
   if(g_startTime==0) g_startTime=now;
   int rem = (int)(InpSanityMode_Seconds - (now - g_startTime));
   if(rem<0) rem=0;
   return rem;
}

bool Sanity_BlockTrailingSpike(const int symIdx)
{
   if(!InpSanityMode_Enable) return false;
   datetime now=TimeCurrent();
   if(g_startTime==0) g_startTime=now;

   // time warm-up
   if(InpSanityMode_Seconds>0 && (now - g_startTime) < InpSanityMode_Seconds)
      return true;

   // indicator warm-up (ATR + ADX buffers must be ready)
   if(symIdx<0 || symIdx>=g_symCount) return true;
   if(!g_indReady[symIdx]) return true;
   return false;
}
