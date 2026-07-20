//+------------------------------------------------------------------+
//|                                             Wyckoff_Signal.mq5    |
//|        Wyckoff Spring / Upthrust (+ optional SOS/SOW) signals     |
//|                                                                  |
//|  Strategy logic                                                  |
//|   * Trading Range : rolling highest-high / lowest-low over N      |
//|                     PRIOR bars (current bar excluded).            |
//|   * Spring  (BUY) : bar pierces below range low but CLOSES back   |
//|                     inside the range  -> failed breakdown.        |
//|   * Upthrust(SELL): bar pierces above range high but CLOSES back  |
//|                     inside the range  -> failed breakout.         |
//|   * SOS/SOW       : optional. A decisive CLOSE outside the range  |
//|                     on strong volume  -> breakout continuation.   |
//|   * Effort/Result : volume gate vs its moving average.            |
//|                                                                  |
//|  No-Repaint: the range is built from bars strictly BEFORE the     |
//|  evaluated bar, and signals are printed only on CLOSED bars, so   |
//|  a printed arrow never moves.                                     |
//+------------------------------------------------------------------+
#property copyright "Indicator"
#property version   "1.00"
#property description "Wyckoff Spring/Upthrust (+SOS/SOW) with volume confirmation. No-repaint arrows."

#property indicator_chart_window
#property indicator_buffers 5
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

//--- Plot 2: Range High line
#property indicator_label3  "Range High"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrSilver
#property indicator_style3  STYLE_DOT
#property indicator_width3  1

//--- Plot 3: Range Low line
#property indicator_label4  "Range Low"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrSilver
#property indicator_style4  STYLE_DOT
#property indicator_width4  1

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Trading Range ==="
input int    InpRangeLookback   = 20;   // Bars used to build the range (prior bars)
input double InpPenetrationPts  = 0.0;  // Min penetration beyond range in points (0 = any)
input double InpRecoveryFrac    = 0.0;  // Min recovery back inside range, as % of range height

input group "=== Volume (Effort vs Result) ==="
input bool   InpUseVolume       = true;  // Require volume confirmation
input int    InpVolMAPeriod     = 20;    // Volume moving-average period
input double InpSpringVolMult   = 1.5;   // Spring/Upthrust need vol >= avg * this (climactic)
input double InpBreakVolMult    = 1.5;   // SOS/SOW need vol >= avg * this
input bool   InpUseRealVolume   = false; // true = real volume, false = tick volume

input group "=== Events to trade ==="
input bool   InpTradeSpring     = true;  // Spring -> BUY, Upthrust -> SELL (reversal)
input bool   InpTradeBreakout   = false; // SOS -> BUY, SOW -> SELL (continuation)

input group "=== Signal display ==="
input int    InpArrowOffsetPts  = 100;  // Arrow distance from candle (points)
input bool   InpShowRange       = true; // Draw range high/low lines
input bool   InpAlertPopup      = false;// Popup alert on new signal
input bool   InpAlertPush       = false;// Push notification on new signal

//+------------------------------------------------------------------+
//| Buffers                                                          |
//+------------------------------------------------------------------+
double BuyBuffer[];
double SellBuffer[];
double RangeHiBuffer[];
double RangeLoBuffer[];
double StateBuffer[]; // internal: encodes last event (0 none, +1 buy, -1 sell)

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, BuyBuffer,     INDICATOR_DATA);
   SetIndexBuffer(1, SellBuffer,    INDICATOR_DATA);
   SetIndexBuffer(2, RangeHiBuffer, INDICATOR_DATA);
   SetIndexBuffer(3, RangeLoBuffer, INDICATOR_DATA);
   SetIndexBuffer(4, StateBuffer,   INDICATOR_CALCULATIONS);

   PlotIndexSetInteger(0, PLOT_ARROW, 233); // up arrow
   PlotIndexSetInteger(1, PLOT_ARROW, 234); // down arrow
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(3, PLOT_EMPTY_VALUE, 0.0);

   ArraySetAsSeries(BuyBuffer,     true);
   ArraySetAsSeries(SellBuffer,    true);
   ArraySetAsSeries(RangeHiBuffer, true);
   ArraySetAsSeries(RangeLoBuffer, true);
   ArraySetAsSeries(StateBuffer,   true);

   IndicatorSetString(INDICATOR_SHORTNAME, "Wyckoff Signal");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Average of the volume series over [i+1 .. i+period] (prior bars) |
//| Series indexing: index 0 = newest bar.                           |
//+------------------------------------------------------------------+
double VolAverage(const long &vol[], const int i, const int total)
  {
   int period = (InpVolMAPeriod < 1) ? 1 : InpVolMAPeriod;
   int n = 0;
   double sum = 0.0;
   for(int k = 1; k <= period; k++)
     {
      int idx = i + k;
      if(idx >= total)
         break;
      sum += (double)vol[idx];
      n++;
     }
   if(n == 0)
      return(0.0);
   return(sum / n);
  }

//+------------------------------------------------------------------+
//| OnCalculate  (series indexing: index 0 = newest)                 |
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
   int lookback = (InpRangeLookback < 2) ? 2 : InpRangeLookback;
   int min_bars = lookback + MathMax(InpVolMAPeriod, 2) + 2;
   if(rates_total < min_bars)
      return(0);

   ArraySetAsSeries(time,  true);
   ArraySetAsSeries(high,  true);
   ArraySetAsSeries(low,   true);
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(tick_volume, true);
   ArraySetAsSeries(volume,      true);

   double point  = _Point;
   double pen    = InpPenetrationPts * point;
   double offset = InpArrowOffsetPts * point;

//--- How many bars to (re)compute. In series indexing the newest closed
//--- bar is index 1 (index 0 is the still-forming bar). Recompute a small
//--- trailing window; older closed bars are stable (no-repaint).
   int limit;
   if(prev_calculated <= 0)
      limit = rates_total - lookback - 2; // oldest computable series index
   else
      limit = rates_total - prev_calculated + 1;
   if(limit > rates_total - lookback - 2)
      limit = rates_total - lookback - 2;

//--- Walk from older -> newer closed bars so edge detection sees history.
   for(int i = limit; i >= 1; i--)
     {
      BuyBuffer[i]  = 0.0;
      SellBuffer[i] = 0.0;

      //--- Trading range from the N bars strictly BEFORE bar i
      double rangeHi = high[i + 1];
      double rangeLo = low[i + 1];
      for(int k = 1; k <= lookback; k++)
        {
         int idx = i + k;
         if(idx >= rates_total)
            break;
         if(high[idx] > rangeHi) rangeHi = high[idx];
         if(low[idx]  < rangeLo) rangeLo = low[idx];
        }
      RangeHiBuffer[i] = InpShowRange ? rangeHi : 0.0;
      RangeLoBuffer[i] = InpShowRange ? rangeLo : 0.0;

      double rangeHeight = rangeHi - rangeLo;
      double minRecovery = InpRecoveryFrac * 0.01 * rangeHeight;

      //--- Volume (Effort vs Result)
      double vol_now = InpUseRealVolume ? (double)volume[i] : (double)tick_volume[i];
      double vol_avg = InpUseRealVolume ? VolAverage(volume, i, rates_total)
                                        : VolAverage(tick_volume, i, rates_total);

      bool springVolOk = !InpUseVolume || (vol_avg > 0.0 && vol_now >= vol_avg * InpSpringVolMult);
      bool breakVolOk  = !InpUseVolume || (vol_avg > 0.0 && vol_now >= vol_avg * InpBreakVolMult);

      int event = 0; // +1 buy, -1 sell

      //--- Spring (BUY): pierce below range low, close back inside
      bool spring = InpTradeSpring
                    && (low[i] < rangeLo - pen)
                    && (close[i] > rangeLo + minRecovery)
                    && springVolOk;

      //--- Upthrust (SELL): pierce above range high, close back inside
      bool upthrust = InpTradeSpring
                      && (high[i] > rangeHi + pen)
                      && (close[i] < rangeHi - minRecovery)
                      && springVolOk;

      //--- SOS (BUY): fresh decisive close above range high on strong volume
      bool sos = InpTradeBreakout
                 && (close[i] > rangeHi + pen)
                 && (close[i + 1] <= rangeHi)
                 && breakVolOk;

      //--- SOW (SELL): fresh decisive close below range low on strong volume
      bool sow = InpTradeBreakout
                 && (close[i] < rangeLo - pen)
                 && (close[i + 1] >= rangeLo)
                 && breakVolOk;

      if(spring || sos)
         event = +1;
      else if(upthrust || sow)
         event = -1;

      StateBuffer[i] = event;

      if(event == +1)
        {
         BuyBuffer[i] = low[i] - offset;
         if(i == 1)
            RaiseAlert(true, time[i], spring ? "Spring" : "SOS");
        }
      else if(event == -1)
        {
         SellBuffer[i] = high[i] + offset;
         if(i == 1)
            RaiseAlert(false, time[i], upthrust ? "Upthrust" : "SOW");
        }
     }

//--- Never plot on the still-forming bar (index 0) -> no-repaint
   BuyBuffer[0]  = 0.0;
   SellBuffer[0] = 0.0;
   RangeHiBuffer[0] = 0.0;
   RangeLoBuffer[0] = 0.0;

   return(rates_total);
  }

//+------------------------------------------------------------------+
//| Fire an alert once per newly-closed signal bar                   |
//+------------------------------------------------------------------+
void RaiseAlert(const bool is_buy, const datetime bar_time, const string ev)
  {
   static datetime last_alert = 0;
   if(bar_time == last_alert)
      return;
   last_alert = bar_time;

   string dir = is_buy ? "BUY" : "SELL";
   string msg = StringFormat("%s %s: Wyckoff %s", _Symbol, dir, ev);
   if(InpAlertPopup) Alert(msg);
   if(InpAlertPush)  SendNotification(msg);
  }
//+------------------------------------------------------------------+
