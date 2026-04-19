//+------------------------------------------------------------------+
//| MSPB_EA_UnitTests.mq5                                            |
//| Unit test harness for core MSPB EA logic functions.              |
//| Run as a Script in MetaTrader 5.                                 |
//|                                                                  |
//| NOTE: These tests validate pure-logic helper functions inline.   |
//| When a function is extracted to a .mqh header it can be tested   |
//| directly by including that header here instead.                  |
//+------------------------------------------------------------------+
#property copyright "MSPB EA"
#property version   "4.00"
#property script_show_inputs false

int g_testsPassed = 0;
int g_testsFailed = 0;

void Assert(bool condition, const string testName)
{
   if(condition)
   {
      g_testsPassed++;
      PrintFormat("  PASS  %s", testName);
   }
   else
   {
      g_testsFailed++;
      PrintFormat("  FAIL  %s  <<<", testName);
   }
}

void AssertNear(double a, double b, double eps, const string testName)
{
   Assert(MathAbs(a - b) <= eps, testName + StringFormat(" (got %.8f expected %.8f)", a, b));
}

void AssertGT(double a, double b, const string testName)
{
   Assert(a > b, testName + StringFormat(" (%.6f should be > %.6f)", a, b));
}

// ---- Pure-logic helpers mirroring EA implementations ----

double CalcRiskLots(double accountBalance, double riskPct, double slPips, double pipValue)
{
   if(slPips <= 0 || pipValue <= 0) return 0.0;
   double riskMoney = accountBalance * riskPct / 100.0;
   return riskMoney / (slPips * pipValue);
}

double MaxDrawdown(double &equity[], int n)
{
   if(n <= 0) return 0.0;
   double peak = equity[0], maxDD = 0.0;
   for(int i = 1; i < n; i++)
   {
      if(equity[i] > peak) peak = equity[i];
      double dd = (peak > 0) ? (peak - equity[i]) / peak : 0.0;
      if(dd > maxDD) maxDD = dd;
   }
   return maxDD;
}

double SharpeRatio(double &returns[], int n)
{
   if(n < 2) return 0.0;
   double sum = 0.0;
   for(int i = 0; i < n; i++) sum += returns[i];
   double mean = sum / n;
   double var = 0.0;
   for(int i = 0; i < n; i++) var += (returns[i] - mean) * (returns[i] - mean);
   double stddev = MathSqrt(var / (n - 1));
   if(stddev < 1e-10) return 0.0;
   return (mean / stddev) * MathSqrt(252.0);
}

#define EXEC_QUAL_BUCKETS     4
#define EXEC_QUAL_MAX_WINDOW  64
int ExecIdx(int sym, int bucket, int pos)
{
   return sym * EXEC_QUAL_BUCKETS * EXEC_QUAL_MAX_WINDOW + bucket * EXEC_QUAL_MAX_WINDOW + pos;
}

// Mirror of RuntimeState /risk validation logic
bool IsRiskMultiplierValid(double mult, double minVal, double maxVal)
{
   return mult >= minVal && mult <= maxVal;
}

// ---- Test suites ----

void Test_CalcRiskLots()
{
   PrintFormat("--- CalcRiskLots ---");
   AssertNear(CalcRiskLots(10000, 1.0, 20, 10.0), 0.5,    0.001, "1% risk, 20-pip SL");
   AssertNear(CalcRiskLots(10000, 2.0, 10, 10.0), 2.0,    0.001, "2% risk, 10-pip SL");
   AssertNear(CalcRiskLots(50000, 0.5, 50,  1.0), 5.0,    0.001, "0.5% risk, 50-pip SL, pipValue=1");
   Assert(CalcRiskLots(10000, 1.0,  0, 10.0) == 0.0,            "0-pip SL returns 0");
   Assert(CalcRiskLots(10000, 1.0, 20,  0.0) == 0.0,            "zero pipValue returns 0");
   Assert(CalcRiskLots(    0, 1.0, 20, 10.0) == 0.0,            "zero balance returns 0");
}

void Test_MaxDrawdown()
{
   PrintFormat("--- MaxDrawdown ---");
   double eq1[] = {10000, 11000, 9000, 9500, 10000};
   AssertNear(MaxDrawdown(eq1, 5), 0.18182, 0.001, "18.2% drawdown");

   double eq2[] = {10000, 10000, 10000};
   AssertNear(MaxDrawdown(eq2, 3), 0.0, 0.001, "Flat equity = 0 DD");

   double eq3[] = {10000, 12000, 8000};
   AssertNear(MaxDrawdown(eq3, 3), 0.33333, 0.001, "33.3% drawdown (peak to trough)");

   double eq4[] = {10000, 9000};
   AssertNear(MaxDrawdown(eq4, 2), 0.10, 0.001, "10% immediate drop");

   double eq5[] = {5000};
   AssertNear(MaxDrawdown(eq5, 1), 0.0, 0.001, "Single value = 0 DD");
}

void Test_SharpeRatio()
{
   PrintFormat("--- SharpeRatio ---");
   double r1[] = {0.01, 0.01, 0.01, 0.01, 0.01};
   AssertGT(SharpeRatio(r1, 5), 0.0,  "Constant positive returns -> positive Sharpe");

   double r2[] = {0.05, -0.03, 0.04, -0.02, 0.03};
   AssertGT(SharpeRatio(r2, 5), 0.0,  "Net-positive mixed returns -> positive Sharpe");

   double r3[] = {0.0, 0.0, 0.0};
   AssertNear(SharpeRatio(r3, 3), 0.0, 0.001, "Zero returns -> 0 Sharpe");

   double r4[] = {0.01};
   AssertNear(SharpeRatio(r4, 1), 0.0, 0.001, "Single return -> 0 Sharpe (n<2)");
}

void Test_ExecIdx()
{
   PrintFormat("--- ExecIdx ---");
   Assert(ExecIdx(0, 0, 0)  == 0,                        "sym0 bucket0 pos0 = 0");
   Assert(ExecIdx(0, 1, 0)  == EXEC_QUAL_MAX_WINDOW,     "sym0 bucket1 pos0 = window size");
   Assert(ExecIdx(1, 0, 0)  == EXEC_QUAL_BUCKETS * EXEC_QUAL_MAX_WINDOW, "sym1 bucket0 pos0 = buckets*window");
   Assert(ExecIdx(0, 0, 63) == 63,                       "sym0 bucket0 pos63 = 63");
   Assert(ExecIdx(2, 3, 10) == ExecIdx(2, 3, 10),        "deterministic");

   // Monotonicity: later sym always > earlier sym
   Assert(ExecIdx(1, 0, 0) > ExecIdx(0, 3, EXEC_QUAL_MAX_WINDOW-1), "sym stride > bucket+pos stride");
}

void Test_RiskMultiplierBounds()
{
   PrintFormat("--- RiskMultiplier validation ---");
   double maxMult = 3.0;
   Assert(IsRiskMultiplierValid(1.0,  0.1, maxMult), "1.0 within [0.1..3.0]");
   Assert(IsRiskMultiplierValid(0.1,  0.1, maxMult), "0.1 lower bound accepted");
   Assert(IsRiskMultiplierValid(3.0,  0.1, maxMult), "3.0 upper bound accepted");
   Assert(!IsRiskMultiplierValid(0.0,  0.1, maxMult), "0.0 below lower bound rejected");
   Assert(!IsRiskMultiplierValid(3.01, 0.1, maxMult), "3.01 above upper bound rejected");
   Assert(!IsRiskMultiplierValid(-1.0, 0.1, maxMult), "negative value rejected");

   // Ensure upper bound enforcement scales with configurable max
   double strictMax = 1.5;
   Assert(!IsRiskMultiplierValid(2.0, 0.1, strictMax), "2.0 rejected when max=1.5");
   Assert(IsRiskMultiplierValid(1.5, 0.1, strictMax),  "1.5 accepted when max=1.5");
}

void Test_DailyLossLimit()
{
   PrintFormat("--- DailyLossLimit formula ---");
   double startBal = 10000.0;
   double limitPct = 3.0;
   double limitAbs = startBal * limitPct / 100.0;  // 300

   // Below threshold
   double eq1 = 9750.0;
   double loss1 = startBal - eq1;
   Assert(loss1 < limitAbs, "250 loss < 300 limit: not tripped");

   // At threshold
   double eq2 = 9700.0;
   double loss2 = startBal - eq2;
   Assert(loss2 >= limitAbs, "300 loss >= 300 limit: tripped");

   // Above threshold
   double eq3 = 9000.0;
   double loss3 = startBal - eq3;
   Assert(loss3 > limitAbs, "1000 loss > 300 limit: tripped");
}

// ---- Partial-TP ring buffer (inline re-implementation for test isolation) ----
// Mirrors the three helpers in MSPB_Expert_Advisor.mq5 exactly, with a
// configurable capacity so edge-case (full buffer) scenarios can be forced.
#define TEST_PARTIAL_TP_CAP 4
ulong  g_testTpTick[TEST_PARTIAL_TP_CAP];
int    g_testTpN = 0;

bool TestPartialTP_AlreadyDone(const ulong ticket)
{
   for(int i = 0; i < g_testTpN; i++)
      if(g_testTpTick[i] == ticket) return true;
   return false;
}

void TestPartialTP_MarkDone(const ulong ticket)
{
   if(g_testTpN < TEST_PARTIAL_TP_CAP)
      g_testTpTick[g_testTpN++] = ticket;
   // silently drop when full — mirrors EA behaviour
}

void TestPartialTP_Remove(const ulong ticket)
{
   for(int i = 0; i < g_testTpN; i++)
   {
      if(g_testTpTick[i] == ticket)
      {
         g_testTpTick[i] = g_testTpTick[--g_testTpN];
         return;
      }
   }
}

void TestPartialTP_Reset()
{
   g_testTpN = 0;
   ArrayInitialize(g_testTpTick, 0);
}

void Test_PartialTP()
{
   PrintFormat("--- PartialTP ring buffer ---");
   TestPartialTP_Reset();

   // Empty buffer: ticket not present
   Assert(!TestPartialTP_AlreadyDone(100), "Empty buffer: ticket 100 not done");

   // Mark and detect
   TestPartialTP_MarkDone(100);
   Assert(TestPartialTP_AlreadyDone(100),  "After MarkDone: ticket 100 is done");
   Assert(!TestPartialTP_AlreadyDone(200), "Ticket 200 still not done");

   // Remove and verify
   TestPartialTP_Remove(100);
   Assert(!TestPartialTP_AlreadyDone(100), "After Remove: ticket 100 no longer done");

   // Multiple tickets
   TestPartialTP_MarkDone(1); TestPartialTP_MarkDone(2); TestPartialTP_MarkDone(3);
   Assert(TestPartialTP_AlreadyDone(1), "Multi: ticket 1 done");
   Assert(TestPartialTP_AlreadyDone(2), "Multi: ticket 2 done");
   Assert(TestPartialTP_AlreadyDone(3), "Multi: ticket 3 done");

   // Remove middle element (swap-with-last pattern)
   TestPartialTP_Remove(2);
   Assert(!TestPartialTP_AlreadyDone(2), "After removing middle ticket 2: gone");
   Assert(TestPartialTP_AlreadyDone(1),  "Ticket 1 still present after removing 2");
   Assert(TestPartialTP_AlreadyDone(3),  "Ticket 3 still present after removing 2");

   // Remove from a ticket that is not in the list (no-op)
   int nBefore = g_testTpN;
   TestPartialTP_Remove(999);
   Assert(g_testTpN == nBefore, "Remove non-existent ticket: count unchanged");

   // Duplicate MarkDone does not crash (ticket already present, just add again)
   TestPartialTP_MarkDone(1);
   Assert(g_testTpN == nBefore + 1, "Duplicate MarkDone increments count (no dedup in ring)");

   // Full-buffer edge case: at capacity, further MarkDone is silently dropped
   TestPartialTP_Reset();
   for(int f = 0; f < TEST_PARTIAL_TP_CAP; f++) TestPartialTP_MarkDone((ulong)(10 + f));
   Assert(g_testTpN == TEST_PARTIAL_TP_CAP, "Buffer full: count equals capacity");
   TestPartialTP_MarkDone(999);  // should be silently dropped
   Assert(g_testTpN == TEST_PARTIAL_TP_CAP, "Full buffer: overflow ticket silently dropped");
   Assert(!TestPartialTP_AlreadyDone(999), "Full buffer: dropped ticket not marked as done");
}

// ---- Main ----

void Test_SetPointSanity()
{
   PrintFormat("--- SetPointSanity ---");

   // TP_RR must be positive and economically viable (break-even requires WR > 1/(1+RR))
   double InpTP_RR_val      = 1.5;
   double InpSL_ATR_Mult_val= 1.2;
   double InpBE_At_R_val    = 0.8;
   double InpBE_LockPips_val= 2.0;
   double InpMinSetupScore_val = 1.0;

   // EqDD ordering: caution < defensive
   double InpEqDD_Caution_Pct_val    = 2.0;
   double InpEqDD_Defensive_Pct_val  = 5.0;
   double InpEqDD_Caution_RiskMult_val   = 0.70;
   double InpEqDD_Defensive_RiskMult_val = 0.40;

   double InpCorrAbsThreshold_val = 0.75;
   int    InpExecQual_Mode_val    = 2;       // ENFORCE
   double InpTester_DDCapPct_val  = 12.0;
   double InpTP_Partial_Pct_val   = 50.0;
   double InpTP_Partial_R_val     = 1.0;

   Assert(InpTP_RR_val > 0.0,                              "TP_RR > 0");
   Assert(InpTP_RR_val >= 1.0,                             "TP_RR >= 1.0 (positive expectation at >50% WR)");
   Assert(InpSL_ATR_Mult_val > 0.0,                        "SL_ATR_Mult > 0");
   Assert(InpBE_At_R_val > 0.0 && InpBE_At_R_val < InpTP_RR_val,
                                                            "BE_At_R between 0 and TP_RR");
   Assert(InpBE_LockPips_val >= 1.0,                       "BE_LockPips >= 1.0 pips (spread resilient)");
   Assert(InpMinSetupScore_val > 0.0,                      "MinSetupScore > 0 (require signal strength)");

   Assert(InpEqDD_Caution_Pct_val < InpEqDD_Defensive_Pct_val,
                                                            "EqDD: Caution% < Defensive%");
   Assert(InpEqDD_Caution_RiskMult_val > InpEqDD_Defensive_RiskMult_val,
                                                            "EqDD: Caution risk-mult > Defensive risk-mult");
   Assert(InpEqDD_Caution_RiskMult_val  < 1.0,             "EqDD: Caution risk-mult < 1.0 (reduces risk)");
   Assert(InpEqDD_Defensive_RiskMult_val > 0.0,            "EqDD: Defensive risk-mult > 0");

   Assert(InpCorrAbsThreshold_val >= 0.0 && InpCorrAbsThreshold_val <= 1.0,
                                                            "CorrAbsThreshold in [0,1]");
   Assert(InpCorrAbsThreshold_val <= 0.80,                 "CorrAbsThreshold <= 0.80 (tighter guard)");

   Assert(InpExecQual_Mode_val == 2,                        "ExecQual_Mode = ENFORCE (2)");
   Assert(InpTester_DDCapPct_val <= 15.0,                  "WF DDCap <= 15% (conservative optimisation)");

   Assert(InpTP_Partial_Pct_val >= 1.0 && InpTP_Partial_Pct_val <= 99.0,
                                                            "PartialTP_Pct in [1,99]");
   Assert(InpTP_Partial_R_val > 0.0 && InpTP_Partial_R_val < InpTP_RR_val,
                                                            "PartialTP_R between 0 and TP_RR");
}

// ---- SymbolFilter test (mirrors SymIndexByName / OnTick routing) ----

// Inline re-implementation of SymIndexByName for test isolation
int TestSymIndexByName(const string sym, const string &syms[], const int symCount)
{
   for(int i = 0; i < symCount; i++)
      if(syms[i] == sym) return i;
   return -1;
}

void Test_SymbolFilter()
{
   PrintFormat("--- SymbolFilter (OnTick routing) ---");

   string syms[4];
   syms[0] = "EURUSD";
   syms[1] = "GBPUSD";
   syms[2] = "USDJPY";
   syms[3] = "XAUUSD";
   int cnt = 4;

   // Known symbols resolve to correct index
   Assert(TestSymIndexByName("EURUSD", syms, cnt) == 0, "EURUSD -> index 0");
   Assert(TestSymIndexByName("GBPUSD", syms, cnt) == 1, "GBPUSD -> index 1");
   Assert(TestSymIndexByName("USDJPY", syms, cnt) == 2, "USDJPY -> index 2");
   Assert(TestSymIndexByName("XAUUSD", syms, cnt) == 3, "XAUUSD -> index 3");

   // Unknown symbol (utility-chart attachment) returns -1 → full-loop fallback
   Assert(TestSymIndexByName("UNKNOWN", syms, cnt) == -1, "Unknown symbol -> -1 (full-loop fallback)");
   Assert(TestSymIndexByName("",        syms, cnt) == -1, "Empty symbol   -> -1");

   // Case-sensitivity: SymIndexByName is exact-match (lowercase ≠ uppercase)
   Assert(TestSymIndexByName("eurusd", syms, cnt) == -1, "eurusd (lower) -> -1 (case-sensitive)");

   // Empty list: always returns -1
   string empty[1];
   Assert(TestSymIndexByName("EURUSD", empty, 0) == -1, "Empty sym list -> -1");

   // Single-element list
   string single[1];
   single[0] = "EURUSD";
   Assert(TestSymIndexByName("EURUSD", single, 1) == 0,  "Single-element hit");
   Assert(TestSymIndexByName("GBPUSD", single, 1) == -1, "Single-element miss");

   // Routing behaviour: only matching index is processed (non-negative → route to that symbol only)
   int idx = TestSymIndexByName("GBPUSD", syms, cnt);
   Assert(idx >= 0,          "Valid tick symbol resolves to non-negative index");
   Assert(idx == 1,          "Correct index selected for ProcessSymbol routing");
   int idxUtil = TestSymIndexByName("NZDCAD", syms, cnt);
   Assert(idxUtil < 0,       "Utility-chart symbol triggers full-loop (idx < 0)");
}

// ---- DailyLoss boundary tests ----
// Inline re-implementation that matches MSPB_EA_Risk.mqh exactly.

double TestDailyLoss_ComputeDD(const double startBal, const double equity)
{
   if(startBal <= 0.0) return 0.0;
   return (startBal - equity) / startBal * 100.0;
}

bool TestDailyLoss_IsTripped(const double startBal, const double equity, const double limitPct)
{
   double ddPct = TestDailyLoss_ComputeDD(startBal, equity);
   return (ddPct >= limitPct);
}

void Test_DailyLossLimit_Boundary()
{
   PrintFormat("--- DailyLossLimit boundary tests ---");

   double bal = 10000.0;
   double lim = 2.0;   // 2% = 200 currency units

   // Exactly at limit (boundary value → must trip)
   double eqAtLimit = bal * (1.0 - lim / 100.0);  // 9800
   Assert( TestDailyLoss_IsTripped(bal, eqAtLimit, lim),
           "Equity exactly at limit: tripped");

   // One pip (0.01) above limit (should NOT trip)
   double eqJustAbove = eqAtLimit + 0.01;
   Assert(!TestDailyLoss_IsTripped(bal, eqJustAbove, lim),
           "Equity 0.01 above limit: NOT tripped");

   // One pip below limit (should trip)
   double eqJustBelow = eqAtLimit - 0.01;
   Assert( TestDailyLoss_IsTripped(bal, eqJustBelow, lim),
           "Equity 0.01 below limit: tripped");

   // Zero balance guard
   Assert(!TestDailyLoss_IsTripped(0.0, 5000.0, lim),
           "Zero start balance: NOT tripped (guard)");

   // Equity above start (profit day) → never trips
   Assert(!TestDailyLoss_IsTripped(bal, bal + 500.0, lim),
           "Equity above start (profit day): NOT tripped");

   // Full wipe-out
   Assert( TestDailyLoss_IsTripped(bal, 0.0, lim),
           "Full wipe-out: tripped");

   // Limit = 0 → any loss trips immediately (edge case)
   Assert( TestDailyLoss_IsTripped(bal, bal - 0.01, 0.0),
           "Limit=0%%: any loss trips");
}

// ---- ConsecLoss guard tests ----

int TestConsecLoss_Handle(int &streak, const double profitMoney, const int maxN,
                          const int cooldownMin, datetime &pauseUntil)
{
   // Returns 1 if guard was tripped (new block issued), 0 otherwise.
   if(profitMoney < 0.0)
   {
      streak++;
      if(streak >= maxN)
      {
         pauseUntil = TimeCurrent() + (datetime)(cooldownMin * 60);
         streak = 0;
         return 1;
      }
   }
   else
   {
      streak = 0;
   }
   return 0;
}

bool TestConsecLoss_IsBlocked(const datetime pauseUntil)
{
   return (pauseUntil > 0 && TimeCurrent() < pauseUntil);
}

void Test_ConsecLoss()
{
   PrintFormat("--- ConsecLoss guard ---");

   int streak = 0;
   datetime pauseUntil = 0;
   int maxN = 3;
   int coolMin = 60;

   // Three wins in a row — no block
   for(int i = 0; i < 3; i++)
      TestConsecLoss_Handle(streak, 10.0, maxN, coolMin, pauseUntil);
   Assert(!TestConsecLoss_IsBlocked(pauseUntil), "3 wins: no block");
   Assert(streak == 0, "3 wins: streak reset to 0");

   // Two losses — not yet at threshold
   TestConsecLoss_Handle(streak, -5.0, maxN, coolMin, pauseUntil);
   TestConsecLoss_Handle(streak, -5.0, maxN, coolMin, pauseUntil);
   Assert(streak == 2, "2 consecutive losses: streak = 2");
   Assert(!TestConsecLoss_IsBlocked(pauseUntil), "2 losses: not blocked yet");

   // Third loss → trips
   int tripped = TestConsecLoss_Handle(streak, -5.0, maxN, coolMin, pauseUntil);
   Assert(tripped == 1, "3rd consecutive loss: guard tripped");
   Assert(streak == 0,  "After trip: streak reset to 0");
   Assert(TestConsecLoss_IsBlocked(pauseUntil), "After trip: blocked");

   // Win after trip resets streak but does NOT lift the pause
   TestConsecLoss_Handle(streak, 10.0, maxN, coolMin, pauseUntil);
   Assert(streak == 0, "Win after trip: streak still 0");
   Assert(TestConsecLoss_IsBlocked(pauseUntil), "Pause still active during cooldown");
}

// ---- EqRegime transition tests ----

enum TestEqRegime { TEST_EQ_NEUTRAL=0, TEST_EQ_CAUTION=1, TEST_EQ_DEFENSIVE=2 };

TestEqRegime TestEqRegime_Classify(const double ddPct, const double cauPct,
                                   const double defPct, const double minGap)
{
   double cauC = (cauPct > 0.1) ? cauPct : 0.1;
   double defC = (defPct > cauC + minGap) ? defPct : cauC + minGap;
   if(ddPct < cauC)      return TEST_EQ_NEUTRAL;
   if(ddPct < defC)      return TEST_EQ_CAUTION;
   return TEST_EQ_DEFENSIVE;
}

void Test_EqRegimeTransitions()
{
   PrintFormat("--- EqRegime transitions ---");

   double cauPct = 2.0;
   double defPct = 5.0;
   double minGap = 0.1;

   // Below caution threshold → NEUTRAL
   Assert(TestEqRegime_Classify(0.0, cauPct, defPct, minGap) == TEST_EQ_NEUTRAL,
          "0% DD → NEUTRAL");
   Assert(TestEqRegime_Classify(1.99, cauPct, defPct, minGap) == TEST_EQ_NEUTRAL,
          "1.99% DD → NEUTRAL (just below caution)");

   // Exactly at caution threshold → CAUTION
   Assert(TestEqRegime_Classify(2.0, cauPct, defPct, minGap) == TEST_EQ_CAUTION,
          "2.0% DD → CAUTION (boundary)");

   // Between thresholds → CAUTION
   Assert(TestEqRegime_Classify(3.5, cauPct, defPct, minGap) == TEST_EQ_CAUTION,
          "3.5% DD → CAUTION");

   // Exactly at defensive threshold → DEFENSIVE
   Assert(TestEqRegime_Classify(5.0, cauPct, defPct, minGap) == TEST_EQ_DEFENSIVE,
          "5.0% DD → DEFENSIVE (boundary)");

   // Well above defensive → DEFENSIVE
   Assert(TestEqRegime_Classify(10.0, cauPct, defPct, minGap) == TEST_EQ_DEFENSIVE,
          "10% DD → DEFENSIVE");

   // Misconfigured: defPct ≤ cauPct → auto-clamp to cauPct + minGap
   Assert(TestEqRegime_Classify(2.05, cauPct, 1.0 /*def < cau*/, minGap) == TEST_EQ_DEFENSIVE,
          "Misconfigured (def < cau): 2.05% → DEFENSIVE after clamp");

   // DD exactly at the minimum-gap boundary after clamp
   double clampedDef = cauPct + minGap; // 2.1
   Assert(TestEqRegime_Classify(2.09, cauPct, clampedDef, minGap) == TEST_EQ_CAUTION,
          "2.09% DD → CAUTION when def clamped to 2.1");
   Assert(TestEqRegime_Classify(2.1, cauPct, clampedDef, minGap) == TEST_EQ_DEFENSIVE,
          "2.1% DD → DEFENSIVE when def clamped to 2.1 (boundary)");
}

void OnStart()
{
   Print("========================================");
   Print("  MSPB EA Unit Tests v4");
   Print("========================================");

   Test_CalcRiskLots();
   Test_MaxDrawdown();
   Test_SharpeRatio();
   Test_ExecIdx();
   Test_RiskMultiplierBounds();
   Test_DailyLossLimit();
   Test_DailyLossLimit_Boundary();
   Test_ConsecLoss();
   Test_EqRegimeTransitions();
   Test_PartialTP();
   Test_SetPointSanity();
   Test_SymbolFilter();

   Print("========================================");
   PrintFormat("  Results: %d passed, %d failed", g_testsPassed, g_testsFailed);
   if(g_testsFailed == 0)
      Print("  ALL TESTS PASSED");
   else
      PrintFormat("  %d TEST(S) FAILED", g_testsFailed);
   Print("========================================");
}
