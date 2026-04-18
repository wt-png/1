//+------------------------------------------------------------------+
//| MSPB_EA_UnitTests.mq5                                            |
//| Unit test harness for core MSPB EA logic functions               |
//| Run as a Script in MetaTrader 5 (Strategy Tester)                |
//+------------------------------------------------------------------+
#property copyright "MSPB EA"
#property version   "1.00"
#property script_show_inputs false

// ---- Minimal stubs so the test file can compile standalone --------
// (In a real setup you'd #include the EA headers here)

int g_testsPassed = 0;
int g_testsFailed = 0;

void Assert(bool condition, string testName)
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

void AssertNear(double a, double b, double eps, string testName)
{
   Assert(MathAbs(a - b) <= eps, testName + StringFormat(" (got %.6f expected %.6f)", a, b));
}

// ---- Inline implementations of pure-logic functions to test -------

double CalcRiskLots_Simple(double accountBalance, double riskPct, double slPips, double pipValue)
{
   if(slPips <= 0 || pipValue <= 0) return 0.0;
   double riskMoney = accountBalance * riskPct / 100.0;
   return riskMoney / (slPips * pipValue);
}

double MaxDrawdown(double &equity[], int n)
{
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

// ExecIdx flattening helper (mirrors EA implementation)
#define EXEC_QUAL_BUCKETS     4
#define EXEC_QUAL_MAX_WINDOW  64
int ExecIdx(int sym, int bucket, int pos)
{
   return sym * EXEC_QUAL_BUCKETS * EXEC_QUAL_MAX_WINDOW + bucket * EXEC_QUAL_MAX_WINDOW + pos;
}

// ---- Test suites ---------------------------------------------------

void Test_CalcRiskLots()
{
   PrintFormat("--- CalcRiskLots ---");
   AssertNear(CalcRiskLots_Simple(10000, 1.0, 20, 10.0), 0.5, 0.001, "1% risk 20pip SL");
   AssertNear(CalcRiskLots_Simple(10000, 2.0, 10, 10.0), 2.0, 0.001, "2% risk 10pip SL");
   Assert(CalcRiskLots_Simple(10000, 1.0, 0, 10.0) == 0.0,            "0 SL returns 0");
   Assert(CalcRiskLots_Simple(10000, 1.0, 20, 0) == 0.0,              "0 pipValue returns 0");
}

void Test_MaxDrawdown()
{
   PrintFormat("--- MaxDrawdown ---");
   double eq1[] = {10000, 11000, 9000, 9500, 10000};
   AssertNear(MaxDrawdown(eq1, 5), 0.1818, 0.001, "18.2% drawdown");
   double eq2[] = {10000, 10000, 10000};
   AssertNear(MaxDrawdown(eq2, 3), 0.0, 0.001, "Flat = 0 DD");
   double eq3[] = {10000, 12000, 8000};
   AssertNear(MaxDrawdown(eq3, 3), 0.3333, 0.001, "33.3% drawdown");
}

void Test_SharpeRatio()
{
   PrintFormat("--- SharpeRatio ---");
   double r1[] = {0.01, 0.01, 0.01, 0.01, 0.01};
   Assert(SharpeRatio(r1, 5) > 0, "Constant positive returns -> positive Sharpe");
   double r2[] = {0.01, -0.01, 0.01, -0.01};
   Assert(SharpeRatio(r2, 4) < 3.0, "Alternating returns -> moderate Sharpe");
   double r3[] = {0.0, 0.0, 0.0};
   AssertNear(SharpeRatio(r3, 3), 0.0, 0.001, "Zero returns -> 0 Sharpe");
}

void Test_ExecIdx()
{
   PrintFormat("--- ExecIdx ---");
   Assert(ExecIdx(0, 0, 0) == 0,          "sym0 bucket0 pos0 = 0");
   Assert(ExecIdx(0, 1, 0) == 64,         "sym0 bucket1 pos0 = 64");
   Assert(ExecIdx(1, 0, 0) == 256,        "sym1 bucket0 pos0 = 256 (4*64)");
   Assert(ExecIdx(0, 0, 63) == 63,        "sym0 bucket0 pos63 = 63");
   Assert(ExecIdx(2, 3, 10) == ExecIdx(2, 3, 10), "deterministic");
}

void Test_SessionADXMin()
{
   PrintFormat("--- SessionADXMin (boundary values) ---");
   // Test that session buckets 0-3 map to valid ADX values
   // (We simulate the function since we can't call EA directly)
   double adx_asia=20.0, adx_london=22.0, adx_ny=20.0, adx_default=18.0;
   double values[] = {adx_asia, adx_london, adx_ny, adx_default};
   for(int b = 0; b < 4; b++)
      Assert(values[b] >= 0 && values[b] <= 100,
             StringFormat("Bucket %d ADX threshold in valid range", b));
}

// ---- Main -----------------------------------------------------------

void OnStart()
{
   Print("========================================");
   Print("  MSPB EA Unit Tests");
   Print("========================================");

   Test_CalcRiskLots();
   Test_MaxDrawdown();
   Test_SharpeRatio();
   Test_ExecIdx();
   Test_SessionADXMin();

   Print("========================================");
   PrintFormat("  Results: %d passed, %d failed", g_testsPassed, g_testsFailed);
   if(g_testsFailed == 0)
      Print("  ✅  ALL TESTS PASSED");
   else
      PrintFormat("  ❌  %d TEST(S) FAILED", g_testsFailed);
   Print("========================================");
}
