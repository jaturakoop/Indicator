//+------------------------------------------------------------------+
//|                                          VWAP_EMA_Signal.mq5      |
//|        VWAP + EMA(9) trend, EMA(5)/EMA(20) momentum, arrows       |
//|                                                                  |
//|  Strategy logic                                                  |
//|   * Trend   : EMA(9) vs VWAP        (EMA9 > VWAP = bullish)       |
//|   * Momentum: EMA(5) - EMA(20) gap  (wider gap = stronger push)  |
//|   * Signal  : arrow when trend + momentum align (edge trigger)   |
//|                                                                  |
//|  No-Repaint: signals are evaluated only on CLOSED bars using     |
//|  finalised EMA/VWAP values, so a printed arrow never moves.      |
//+------------------------------------------------------------------+
#property copyright "Indicator"
#property version   "1.00"
#property description "VWAP + EMA(9) trend with EMA(5)/EMA(20) momentum spread. No-repaint arrows."

#property indicator_chart_window
#property indicator_buffers 3
#property indicator_plots   2

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

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== EMA settings ==="
input int    InpEMAfast   = 5;    // Fast EMA (momentum)
input int    InpEMAmid    = 9;    // Mid EMA (trend, paired with VWAP)
input int    InpEMAslow   = 20;   // Slow EMA (momentum)
input ENUM_APPLIED_PRICE InpEMAPrice = PRICE_CLOSE; // EMA applied price

input group "=== Momentum (EMA5-EMA20 spread) ==="
input double InpMinSpreadPoints = 50.0; // Min |EMA5-EMA20| in points to confirm
input bool   InpRequireExpanding = true; // Require spread to be widening

input group "=== Trend strength (EMA9-VWAP gap) ==="
input double InpMinVwapGapPoints = 0.0;  // Min |EMA9-VWAP| in points (0 = direction only)
input bool   InpVwapExpanding    = false; // Require EMA9-VWAP gap to be widening

input group "=== Volatility (Bollinger Band width) ==="
input int    InpBBPeriod    = 20;  // Bollinger Band period
input double InpBBDev       = 2.0; // Bollinger Band deviations
input ENUM_APPLIED_PRICE InpBBPrice = PRICE_CLOSE; // BB applied price
input bool   InpBBExpanding    = true; // Require upper/lower band to be spreading apart
input int    InpBBExpandLookback = 1;  // Expansion lookback (bars): width now > width N bars ago
input double InpMinBBWidthPct = 0.0; // Extra: min band width as % of basis (0 = off)

input group "=== VWAP (via iCustom to VWAP.ex5) ==="
input int    InpVwapAnchor  = 0;  // 0=Session 1=Week 2=Month 3=Continuous
input int    InpVwapPrice   = 0;  // 0=Typical 1=Close 2=HLC 3=OHLC
input int    InpVwapVolume  = 0;  // 0=Tick 1=Real

input group "=== Signal display ==="
input int    InpArrowOffsetPoints = 100; // Arrow distance from candle (points)
input bool   InpAlertPopup  = false; // Popup alert on new signal
input bool   InpAlertPush   = false; // Push notification on new signal

//+------------------------------------------------------------------+
//| Buffers                                                          |
//+------------------------------------------------------------------+
double BuyBuffer[];
double SellBuffer[];
double TrendStateBuffer[]; // internal: +1 bull, -1 bear, 0 none (per closed bar)

//--- Indicator handles
int h_ema_fast = INVALID_HANDLE;
int h_ema_mid  = INVALID_HANDLE;
int h_ema_slow = INVALID_HANDLE;
int h_vwap     = INVALID_HANDLE;
int h_bb       = INVALID_HANDLE;

//--- Local copies (non-series: index 0 = oldest)
double EMAf[], EMAm[], EMAs[], VWAP[];
double BBup[], BBlo[], BBmid[];

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, BuyBuffer,        INDICATOR_DATA);
   SetIndexBuffer(1, SellBuffer,       INDICATOR_DATA);
   SetIndexBuffer(2, TrendStateBuffer, INDICATOR_CALCULATIONS);

   PlotIndexSetInteger(0, PLOT_ARROW, 233); // up arrow
   PlotIndexSetInteger(1, PLOT_ARROW, 234); // down arrow
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, 0.0);

//--- EMA handles
   h_ema_fast = iMA(_Symbol, _Period, InpEMAfast, 0, MODE_EMA, InpEMAPrice);
   h_ema_mid  = iMA(_Symbol, _Period, InpEMAmid,  0, MODE_EMA, InpEMAPrice);
   h_ema_slow = iMA(_Symbol, _Period, InpEMAslow, 0, MODE_EMA, InpEMAPrice);

//--- VWAP handle (requires VWAP.ex5 in MQL5/Indicators)
   h_vwap = iCustom(_Symbol, _Period, "VWAP",
                    InpVwapAnchor,
                    InpVwapPrice,
                    InpVwapVolume,
                    true,   // show bands (buffer 0 = VWAP either way)
                    1.0,
                    2.0);

//--- Bollinger Bands handle (volatility filter)
   h_bb = iBands(_Symbol, _Period, InpBBPeriod, 0, InpBBDev, InpBBPrice);

   if(h_ema_fast == INVALID_HANDLE || h_ema_mid == INVALID_HANDLE ||
      h_ema_slow == INVALID_HANDLE || h_vwap == INVALID_HANDLE ||
      h_bb == INVALID_HANDLE)
     {
      Print("VWAP_EMA_Signal: failed to create a handle. Ensure VWAP.ex5 is compiled in MQL5/Indicators.");
      return(INIT_FAILED);
     }

//--- Non-series destination arrays to match OnCalculate indexing
   ArraySetAsSeries(EMAf, false);
   ArraySetAsSeries(EMAm, false);
   ArraySetAsSeries(EMAs, false);
   ArraySetAsSeries(VWAP, false);
   ArraySetAsSeries(BBup,  false);
   ArraySetAsSeries(BBlo,  false);
   ArraySetAsSeries(BBmid, false);

   IndicatorSetString(INDICATOR_SHORTNAME, "VWAP+EMA Signal");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Deinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(h_ema_fast != INVALID_HANDLE) IndicatorRelease(h_ema_fast);
   if(h_ema_mid  != INVALID_HANDLE) IndicatorRelease(h_ema_mid);
   if(h_ema_slow != INVALID_HANDLE) IndicatorRelease(h_ema_slow);
   if(h_vwap     != INVALID_HANDLE) IndicatorRelease(h_vwap);
   if(h_bb       != INVALID_HANDLE) IndicatorRelease(h_bb);
  }

//+------------------------------------------------------------------+
//| Evaluate the directional state on a single CLOSED bar i          |
//|   returns +1 bullish aligned, -1 bearish aligned, 0 none         |
//+------------------------------------------------------------------+
int BarState(const int i)
  {
   double point = _Point;
   double spread = EMAf[i] - EMAs[i];              // EMA5 - EMA20
   double spread_prev = (i > 0) ? EMAf[i-1] - EMAs[i-1] : spread;
   double min_gap = InpMinSpreadPoints * point;

//--- Trend strength from EMA(9) vs VWAP (magnitude, not just side)
   double vgap = EMAm[i] - VWAP[i];                // EMA9 - VWAP
   double vgap_prev = (i > 0) ? EMAm[i-1] - VWAP[i-1] : vgap;
   double min_vgap = InpMinVwapGapPoints * point;

//--- Trend from EMA(9) vs VWAP: require a minimum separation
   bool trend_up   = (vgap >  min_vgap);
   bool trend_down = (vgap < -min_vgap);

//--- Optional: require the EMA9-VWAP gap to be widening (trend accelerating)
   if(InpVwapExpanding)
     {
      if(trend_up   && !(vgap > vgap_prev)) trend_up   = false;
      if(trend_down && !(vgap < vgap_prev)) trend_down = false;
     }

//--- Momentum from EMA5/EMA20 separation
   bool mom_up   = (spread >  min_gap);
   bool mom_down = (spread < -min_gap);

//--- Optional: require the gap to be widening in the trade direction
   if(InpRequireExpanding)
     {
      if(mom_up   && !(spread > spread_prev)) mom_up   = false;
      if(mom_down && !(spread < spread_prev)) mom_down = false;
     }

//--- Volatility gate: upper/lower Bollinger bands must be spreading apart.
//--- Only the raw distance (upper - lower) matters; the basis is ignored.
   double bbwidth = BBup[i] - BBlo[i];
   int    lb      = (InpBBExpandLookback < 1) ? 1 : InpBBExpandLookback;
   double bbwidth_ref = (i >= lb) ? BBup[i-lb] - BBlo[i-lb] : bbwidth;

   bool vol_ok = true;
   if(InpBBExpanding)
      vol_ok = (bbwidth > bbwidth_ref);            // bands widening = volatility in
   if(vol_ok && InpMinBBWidthPct > 0.0)            // optional extra width floor
     {
      double bbw_pct = (BBmid[i] != 0.0) ? bbwidth / MathAbs(BBmid[i]) * 100.0 : 0.0;
      vol_ok = (bbw_pct >= InpMinBBWidthPct);
     }
   if(!vol_ok)
      return(0);

   if(trend_up   && mom_up)   return(+1);
   if(trend_down && mom_down) return(-1);
   return(0);
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
   int min_bars = MathMax(MathMax(InpEMAslow, InpEMAmid), InpBBPeriod) + 2;
   if(rates_total < min_bars)
      return(0);

//--- Pull finalised values for the whole series (index 0 = oldest)
   if(CopyBuffer(h_ema_fast, 0, 0, rates_total, EMAf)  < rates_total) return(prev_calculated);
   if(CopyBuffer(h_ema_mid,  0, 0, rates_total, EMAm)  < rates_total) return(prev_calculated);
   if(CopyBuffer(h_ema_slow, 0, 0, rates_total, EMAs)  < rates_total) return(prev_calculated);
   if(CopyBuffer(h_vwap,     0, 0, rates_total, VWAP)  < rates_total) return(prev_calculated);
   if(CopyBuffer(h_bb, BASE_LINE,  0, rates_total, BBmid) < rates_total) return(prev_calculated);
   if(CopyBuffer(h_bb, UPPER_BAND, 0, rates_total, BBup)  < rates_total) return(prev_calculated);
   if(CopyBuffer(h_bb, LOWER_BAND, 0, rates_total, BBlo)  < rates_total) return(prev_calculated);

   double offset = InpArrowOffsetPoints * _Point;

//--- Recompute only from the last unfinished region; past closed bars are
//--- stable so their arrows never change (no-repaint).
   int start = prev_calculated - 1;
   if(start < min_bars)
      start = min_bars;

//--- Iterate closed bars only. The forming bar is rates_total-1 -> skip it.
   for(int i = start; i <= rates_total - 2; i++)
     {
      BuyBuffer[i]  = 0.0;
      SellBuffer[i] = 0.0;

      int state      = BarState(i);
      int state_prev = BarState(i - 1);
      TrendStateBuffer[i] = state;

      //--- Edge trigger: arrow only when alignment first appears
      if(state == +1 && state_prev != +1)
        {
         BuyBuffer[i] = low[i] - offset;
         if(i == rates_total - 2)
            RaiseAlert(true, time[i]);
        }
      else if(state == -1 && state_prev != -1)
        {
         SellBuffer[i] = high[i] + offset;
         if(i == rates_total - 2)
            RaiseAlert(false, time[i]);
        }
     }

//--- Keep the forming bar clean (never plot on it -> no-repaint)
   if(rates_total >= 1)
     {
      BuyBuffer[rates_total - 1]  = 0.0;
      SellBuffer[rates_total - 1] = 0.0;
     }

   return(rates_total);
  }

//+------------------------------------------------------------------+
//| Fire an alert once per newly-closed signal bar                   |
//+------------------------------------------------------------------+
void RaiseAlert(const bool is_buy, const datetime bar_time)
  {
   static datetime last_alert = 0;
   if(bar_time == last_alert)
      return;
   last_alert = bar_time;

   string dir = is_buy ? "BUY" : "SELL";
   string msg = StringFormat("%s %s: VWAP+EMA9 trend & EMA5/20 momentum aligned",
                             _Symbol, dir);
   if(InpAlertPopup) Alert(msg);
   if(InpAlertPush)  SendNotification(msg);
  }
//+------------------------------------------------------------------+
