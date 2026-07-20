//+------------------------------------------------------------------+
//|                                             Elliott_Signal.mq5    |
//|        Elliott Wave 3 breakout entry from confirmed swing pivots  |
//|                                                                  |
//|  Strategy logic                                                  |
//|   * Pivots : fractal swing highs/lows, confirmed `Depth` bars     |
//|              later (a pivot never moves once confirmed).          |
//|   * Setup  : three alternating pivots P0-P1-P2 that look like     |
//|              wave 1 + wave 2, validated by Elliott's core rule    |
//|              (wave 2 must not retrace past the start of wave 1).  |
//|       BUY  : P0 low, P1 high, P2 low  with P2 > P0, P2 < P1       |
//|       SELL : P0 high, P1 low, P2 high with P2 < P0, P2 > P1       |
//|   * Trigger: CLOSE breaks the wave-1 extreme (P1) -> wave 3 on.   |
//|   * Target : Fibonacci 1.618 extension of wave 1, from P2.        |
//|                                                                  |
//|  No-Repaint: pivots are only used once confirmed, and the         |
//|  breakout is a close-cross on a CLOSED bar, so arrows never move. |
//+------------------------------------------------------------------+
#property copyright "Indicator"
#property version   "1.00"
#property description "Elliott wave-3 breakout from confirmed swing pivots (Rule 1 validated). No-repaint arrows."

#property indicator_chart_window
#property indicator_buffers 4
#property indicator_plots   4

//--- Plot 0: Buy arrow
#property indicator_label1  "Buy"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLime
#property indicator_width1  2

//--- Plot 1: Sell arrow
#property indicator_label2  "Sell"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_width2  2

//--- Plot 2: Pivot High marker
#property indicator_label3  "PivotHigh"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrOrange
#property indicator_width3  1

//--- Plot 3: Pivot Low marker
#property indicator_label4  "PivotLow"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrDodgerBlue
#property indicator_width4  1

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Swing pivots ==="
input int    InpDepth        = 5;    // Fractal depth (bars each side of a pivot)
input double InpMinSwingPts   = 0.0; // Min swing size vs previous pivot (points, 0 = off)

input group "=== Elliott rules ==="
input bool   InpRule3NotShortest = true; // Prefer setups where wave 1 leaves room (info)
input double InpMaxWave2Retr = 100.0;    // Max wave-2 retrace of wave 1 (% ; <100 stricter)

input group "=== Fibonacci target ==="
input double InpWave3Ext     = 1.618; // Wave-3 extension of wave 1 for the target

input group "=== Signal display ==="
input int    InpArrowOffsetPts = 100; // Arrow distance from candle (points)
input bool   InpShowPivots     = true;// Draw confirmed pivot markers
input bool   InpAlertPopup     = false;// Popup alert on new signal
input bool   InpAlertPush      = false;// Push notification on new signal

//+------------------------------------------------------------------+
//| Buffers (series indexing: index 0 = newest)                      |
//+------------------------------------------------------------------+
double BuyBuffer[];
double SellBuffer[];
double PivotHiBuffer[];
double PivotLoBuffer[];

//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, BuyBuffer,     INDICATOR_DATA);
   SetIndexBuffer(1, SellBuffer,    INDICATOR_DATA);
   SetIndexBuffer(2, PivotHiBuffer, INDICATOR_DATA);
   SetIndexBuffer(3, PivotLoBuffer, INDICATOR_DATA);

   PlotIndexSetInteger(0, PLOT_ARROW, 233); // up
   PlotIndexSetInteger(1, PLOT_ARROW, 234); // down
   PlotIndexSetInteger(2, PLOT_ARROW, 159); // dot
   PlotIndexSetInteger(3, PLOT_ARROW, 159); // dot
   for(int p = 0; p < 4; p++)
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, 0.0);

   ArraySetAsSeries(BuyBuffer,     true);
   ArraySetAsSeries(SellBuffer,    true);
   ArraySetAsSeries(PivotHiBuffer, true);
   ArraySetAsSeries(PivotLoBuffer, true);

   IndicatorSetString(INDICATOR_SHORTNAME, "Elliott Signal");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Is bar c a fractal swing high? (strict max over +/- depth)       |
//| Series indexing: index 0 = newest.                               |
//+------------------------------------------------------------------+
bool IsPivotHigh(const double &high[], const int c, const int depth, const int total)
  {
   if(c - depth < 0 || c + depth >= total)
      return(false);
   double v = high[c];
   for(int k = 1; k <= depth; k++)
     {
      if(high[c - k] >= v) return(false); // newer side
      if(high[c + k] >  v) return(false); // older side
     }
   return(true);
  }

bool IsPivotLow(const double &low[], const int c, const int depth, const int total)
  {
   if(c - depth < 0 || c + depth >= total)
      return(false);
   double v = low[c];
   for(int k = 1; k <= depth; k++)
     {
      if(low[c - k] <= v) return(false);
      if(low[c + k] <  v) return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| OnCalculate                                                      |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   int depth = (InpDepth < 1) ? 1 : InpDepth;
   int min_bars = 2 * depth + 4;
   if(rates_total < min_bars)
      return(0);

   ArraySetAsSeries(time,  true);
   ArraySetAsSeries(high,  true);
   ArraySetAsSeries(low,   true);
   ArraySetAsSeries(close, true);

//--- Full recompute each call keeps the pivot state machine consistent.
   ArrayInitialize(BuyBuffer,     0.0);
   ArrayInitialize(SellBuffer,    0.0);
   ArrayInitialize(PivotHiBuffer, 0.0);
   ArrayInitialize(PivotLoBuffer, 0.0);

   double point  = _Point;
   double offset = InpArrowOffsetPts * point;
   double minSwing = InpMinSwingPts * point;

//--- Last three confirmed pivots: index 2 = newest.
   double pPrice[3];
   bool   pIsHigh[3];
   int    pBar[3];
   int    npiv = 0;

   int lastBuyBar = -1;   // wave-1 pivot bar of the last BUY setup fired
   int lastSellBar = -1;

//--- Walk bars oldest -> newest (decreasing series index). When at bar i
//--- we can confirm the pivot centered at c = i + depth (it now has
//--- `depth` newer bars), then test a breakout on bar i itself.
   int i_start = rates_total - 1 - 2 * depth;
   for(int i = i_start; i >= 1; i--)
     {
      int c = i + depth;

      //--- Confirm a pivot centered at c
      bool isHi = IsPivotHigh(high, c, depth, rates_total);
      bool isLo = IsPivotLow(low,  c, depth, rates_total);
      if(isHi || isLo)
        {
         double  newPrice = isHi ? high[c] : low[c];
         bool    newIsHigh = isHi;

         if(InpShowPivots)
           {
            if(isHi) PivotHiBuffer[c] = high[c] + offset * 0.5;
            else     PivotLoBuffer[c] = low[c]  - offset * 0.5;
           }

         if(npiv == 0)
           {
            pPrice[0] = newPrice; pIsHigh[0] = newIsHigh; pBar[0] = c; npiv = 1;
           }
         else if(pIsHigh[npiv > 3 ? 2 : npiv - 1] == newIsHigh)
           {
            //--- same type as the newest pivot: keep the more extreme one
            int last = (npiv >= 3) ? 2 : npiv - 1;
            bool better = newIsHigh ? (newPrice > pPrice[last]) : (newPrice < pPrice[last]);
            if(better) { pPrice[last] = newPrice; pBar[last] = c; }
           }
         else
           {
            //--- alternating pivot: optional minimum swing filter
            int last = (npiv >= 3) ? 2 : npiv - 1;
            bool swingOk = (minSwing <= 0.0) || (MathAbs(newPrice - pPrice[last]) >= minSwing);
            if(swingOk)
              {
               if(npiv < 3)
                 {
                  pPrice[npiv] = newPrice; pIsHigh[npiv] = newIsHigh; pBar[npiv] = c; npiv++;
                 }
               else
                 {
                  pPrice[0]=pPrice[1]; pIsHigh[0]=pIsHigh[1]; pBar[0]=pBar[1];
                  pPrice[1]=pPrice[2]; pIsHigh[1]=pIsHigh[2]; pBar[1]=pBar[2];
                  pPrice[2]=newPrice;  pIsHigh[2]=newIsHigh;  pBar[2]=c;
                 }
              }
           }
        }

      //--- Need three alternating pivots for a wave 1+2 shape
      if(npiv < 3)
         continue;

      double P0 = pPrice[0], P1 = pPrice[1], P2 = pPrice[2];
      double maxRetr = InpMaxWave2Retr * 0.01;

      //--- BULLISH setup: low(P0) -> high(P1) -> low(P2)
      if(!pIsHigh[0] && pIsHigh[1] && !pIsHigh[2])
        {
         double wave1 = P1 - P0;
         bool ruleOk = (P2 > P0) && (P2 < P1) && (wave1 > 0.0)
                       && ((P1 - P2) <= wave1 * maxRetr);
         bool breakout = (close[i] > P1) && (close[i + 1] <= P1);
         if(ruleOk && breakout && pBar[1] != lastBuyBar)
           {
            BuyBuffer[i] = low[i] - offset;
            lastBuyBar = pBar[1];
            if(i == 1)
              {
               double target = P2 + wave1 * InpWave3Ext;
               RaiseAlert(true, time[i], target);
              }
           }
        }

      //--- BEARISH setup: high(P0) -> low(P1) -> high(P2)
      if(pIsHigh[0] && !pIsHigh[1] && pIsHigh[2])
        {
         double wave1 = P0 - P1;
         bool ruleOk = (P2 < P0) && (P2 > P1) && (wave1 > 0.0)
                       && ((P2 - P1) <= wave1 * maxRetr);
         bool breakout = (close[i] < P1) && (close[i + 1] >= P1);
         if(ruleOk && breakout && pBar[1] != lastSellBar)
           {
            SellBuffer[i] = high[i] + offset;
            lastSellBar = pBar[1];
            if(i == 1)
              {
               double target = P2 - wave1 * InpWave3Ext;
               RaiseAlert(false, time[i], target);
              }
           }
        }
     }

   return(rates_total);
  }

//+------------------------------------------------------------------+
//| Fire an alert once per newly-closed signal bar                   |
//+------------------------------------------------------------------+
void RaiseAlert(const bool is_buy, const datetime bar_time, const double target)
  {
   static datetime last_alert = 0;
   if(bar_time == last_alert)
      return;
   last_alert = bar_time;

   string dir = is_buy ? "BUY" : "SELL";
   string msg = StringFormat("%s %s: Elliott wave-3 breakout. Target ~ %s",
                             _Symbol, dir, DoubleToString(target, _Digits));
   if(InpAlertPopup) Alert(msg);
   if(InpAlertPush)  SendNotification(msg);
  }
//+------------------------------------------------------------------+
