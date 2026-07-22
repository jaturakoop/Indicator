//+------------------------------------------------------------------+
//|                                       POI_Reversal_Signal.mq5     |
//|     POI + Sweep Liquidity + iFVG + CISD + MSS reversal model      |
//|                                                                  |
//|  A high-quality reversal is confirmed only when this ordered      |
//|  cascade completes inside a Point-of-Interest zone:               |
//|                                                                  |
//|   1. POI      : price trades into a swing-liquidity level         |
//|                 (optionally gated to a manual price zone).         |
//|   2. FVG      : a Fair Value Gap is left behind on the way in.     |
//|   3. Sweep    : that liquidity is swept (wick beyond, close back). |
//|   4. iFVG     : price closes back through the left-behind FVG      |
//|                 (the FVG is inverted -> support/resistance flip).  |
//|   5. CISD     : Change In State of Direction — close beyond the    |
//|                 opening range of the final impulse leg.            |
//|   6. MSS      : Market Structure Shift — close beyond the swing    |
//|                 high/low of the candle set that produced CISD.     |
//|                                                                  |
//|  Only when 1->6 complete in order is an arrow printed.            |
//|                                                                  |
//|  No-Repaint: swings are confirmed with a right-hand offset and     |
//|  every stage is evaluated on CLOSED bars, so a printed arrow       |
//|  never moves or vanishes. Levels for entry (iFVG / CISD / MSS)     |
//|  are drawn as reference lines when the signal fires.               |
//+------------------------------------------------------------------+
#property copyright "Indicator"
#property version   "1.00"
#property description "POI + Sweep Liquidity + iFVG + CISD + MSS reversal confirmation. No-repaint arrows."

#property indicator_chart_window
#property indicator_buffers 2
#property indicator_plots   2

//--- Plot 0: Buy arrow (bullish reversal confirmed)
#property indicator_label1  "Buy reversal"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLime
#property indicator_width1  3

//--- Plot 1: Sell arrow (bearish reversal confirmed)
#property indicator_label2  "Sell reversal"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_width2  3

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Swing / liquidity detection ==="
input int    InpSwingLen   = 3;    // Fractal swing length (bars each side)
input int    InpLegLookback = 12;  // Impulse-leg lookback for CISD/MSS (bars)

input group "=== FVG (Fair Value Gap) ==="
input int    InpFVGMaxAge  = 40;   // Max age of the left-behind FVG at sweep (bars)

input group "=== Point of Interest gate (optional manual zone) ==="
input bool   InpUsePOIZone = false; // Only accept sweeps inside a manual zone
input double InpPOIUpper   = 0.0;   // POI zone upper price
input double InpPOILower   = 0.0;   // POI zone lower price

input group "=== Sequence timing ==="
input int    InpMaxBars    = 30;    // Max bars from sweep to MSS before reset

input group "=== Signal display ==="
input int    InpArrowOffsetPoints = 150; // Arrow distance from candle (points)
input bool   InpDrawLevels = true;  // Draw iFVG / CISD / MSS reference lines
input int    InpLevelExtendBars = 12; // How far right to extend level lines (bars)
input bool   InpAlertPopup = false; // Popup alert on new confirmed reversal
input bool   InpAlertPush  = false; // Push notification on new confirmed reversal

//+------------------------------------------------------------------+
//| Buffers                                                          |
//+------------------------------------------------------------------+
double BuyBuffer[];
double SellBuffer[];

//--- Non-series price copies (index 0 = oldest) to match OnCalculate
double O[], H[], L[], C[];
datetime T[];

//--- Stage constants for the reversal state machine
#define ST_IDLE   0
#define ST_SWEPT  1   // liquidity swept inside POI, FVG referenced
#define ST_IFVG   2   // price closed back through the left-behind FVG
#define ST_CISD   3   // change in state of direction confirmed

//--- One reversal setup (bullish or bearish share the same struct)
struct Setup
  {
   int    stage;        // ST_*
   int    sweepBar;     // bar index of the sweep
   double refFVGTop;    // left-behind FVG top / bottom (the level to invert)
   double refFVGBot;
   double cisdLevel;    // opening-range level of the final impulse leg
   double ifvgLevel;    // recorded iFVG price (for entry reference)
   double mssLevel;     // swing high/low that must break for MSS
  };

Setup Bull, Bear;

//--- Recompute guard: only rebuild once per newly closed bar
int LastCalcBars = 0;

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, BuyBuffer,  INDICATOR_DATA);
   SetIndexBuffer(1, SellBuffer, INDICATOR_DATA);

   PlotIndexSetInteger(0, PLOT_ARROW, 233); // up arrow
   PlotIndexSetInteger(1, PLOT_ARROW, 234); // down arrow
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, 0.0);

   ArraySetAsSeries(O, false);
   ArraySetAsSeries(H, false);
   ArraySetAsSeries(L, false);
   ArraySetAsSeries(C, false);
   ArraySetAsSeries(T, false);

   IndicatorSetString(INDICATOR_SHORTNAME, "POI Reversal (Sweep+iFVG+CISD+MSS)");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Deinit — clean up our reference-line objects                     |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, "POIrev_");
  }

//+------------------------------------------------------------------+
//| Fractal swing test on a fully-formed pivot bar p                 |
//|   needs InpSwingLen bars on each side (p must be <= last-Len)     |
//+------------------------------------------------------------------+
bool IsSwingHigh(const int p, const int len)
  {
   if(p - len < 0) return(false);
   double v = H[p];
   for(int k = 1; k <= len; k++)
      if(H[p-k] > v || H[p+k] > v) return(false);
   return(true);
  }

bool IsSwingLow(const int p, const int len)
  {
   if(p - len < 0) return(false);
   double v = L[p];
   for(int k = 1; k <= len; k++)
      if(L[p-k] < v || L[p+k] < v) return(false);
   return(true);
  }

//+------------------------------------------------------------------+
//| Reset a setup to idle                                            |
//+------------------------------------------------------------------+
void ResetSetup(Setup &s)
  {
   s.stage     = ST_IDLE;
   s.sweepBar  = -1;
   s.refFVGTop = 0.0;
   s.refFVGBot = 0.0;
   s.cisdLevel = 0.0;
   s.ifvgLevel = 0.0;
   s.mssLevel  = 0.0;
  }

//+------------------------------------------------------------------+
//| POI gate: is the sweep extreme allowed by the manual zone?       |
//+------------------------------------------------------------------+
bool InPOIZone(const double price)
  {
   if(!InpUsePOIZone) return(true);
   double hi = MathMax(InpPOIUpper, InpPOILower);
   double lo = MathMin(InpPOIUpper, InpPOILower);
   return(price >= lo && price <= hi);
  }

//+------------------------------------------------------------------+
//| CISD opening-range level of the down-leg that made the low at b  |
//|   = highest OPEN among the consecutive bearish candles into b     |
//+------------------------------------------------------------------+
double DownLegCISD(const int b)
  {
   // highest OPEN of the consecutive bearish candles of the leg into the
   // sweep bar b. The sweep bar itself may close back up, so we skip
   // leading non-bearish candles and start the run at the first bearish one.
   double lvl = O[b];
   bool started = false;
   for(int k = b; k >= 1 && k > b - InpLegLookback - 1; k--)
     {
      if(C[k] < O[k])
        { lvl = started ? MathMax(lvl, O[k]) : O[k]; started = true; }
      else if(started)
         break;
     }
   return(lvl);
  }

//+------------------------------------------------------------------+
//| CISD opening-range level of the up-leg that made the high at b   |
//|   = lowest OPEN among the consecutive bullish candles into b      |
//+------------------------------------------------------------------+
double UpLegCISD(const int b)
  {
   // lowest OPEN of the consecutive bullish candles of the leg into sweep bar b
   double lvl = O[b];
   bool started = false;
   for(int k = b; k >= 1 && k > b - InpLegLookback - 1; k--)
     {
      if(C[k] > O[k])
        { lvl = started ? MathMin(lvl, O[k]) : O[k]; started = true; }
      else if(started)
         break;
     }
   return(lvl);
  }

//+------------------------------------------------------------------+
//| Draw an entry-reference line + label for a confirmed reversal    |
//+------------------------------------------------------------------+
void DrawLevel(const string tag, const datetime t0, const int barIdx,
               const double price, const color col, const int rt)
  {
   if(!InpDrawLevels) return;
   int endIdx = MathMin(barIdx + InpLevelExtendBars, rt - 1);
   string name = "POIrev_" + tag + "_" + (string)(long)t0;
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TREND, 0, t0, price, T[endIdx], price);
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t0);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 0, price);
   ObjectSetInteger(0, name, OBJPROP_TIME, 1, T[endIdx]);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 1, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetString (0, name, OBJPROP_TOOLTIP, tag);
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
   int min_bars = InpSwingLen * 2 + InpLegLookback + 5;
   if(rates_total < min_bars)
      return(0);

//--- Only rebuild on a newly closed bar (the machine is stateful).
   if(prev_calculated > 0 && rates_total == LastCalcBars)
      return(rates_total);
   LastCalcBars = rates_total;

//--- Copy series into non-series arrays (index 0 = oldest).
   if(ArrayResize(O, rates_total) < 0) return(prev_calculated);
   if(ArrayResize(H, rates_total) < 0) return(prev_calculated);
   if(ArrayResize(L, rates_total) < 0) return(prev_calculated);
   if(ArrayResize(C, rates_total) < 0) return(prev_calculated);
   if(ArrayResize(T, rates_total) < 0) return(prev_calculated);
   for(int i = 0; i < rates_total; i++)
     {
      O[i] = open[i];  H[i] = high[i];  L[i] = low[i];  C[i] = close[i];  T[i] = time[i];
     }

//--- Full rebuild: clear buffers and objects, replay the state machine.
   ArrayInitialize(BuyBuffer,  0.0);
   ArrayInitialize(SellBuffer, 0.0);
   ObjectsDeleteAll(0, "POIrev_");
   ResetSetup(Bull);
   ResetSetup(Bear);

   double offset = InpArrowOffsetPoints * _Point;

//--- Running references maintained as bars stream in (left -> right).
   double lastBearTop = 0.0, lastBearBot = 0.0; int lastBearBar = -1; // most recent unbroken bearish FVG
   double lastBullTop = 0.0, lastBullBot = 0.0; int lastBullBar = -1; // most recent unbroken bullish FVG
   double prevSwingHigh = 0.0; int prevSwingHighBar = -1;             // last confirmed swing high
   double prevSwingLow  = 0.0; int prevSwingLowBar  = -1;             // last confirmed swing low

//--- Process CLOSED bars only. The forming bar is rates_total-1 -> skip.
   int last_closed = rates_total - 2;

   for(int i = 2; i <= last_closed; i++)
     {
      //=== (a) Update the most recent unbroken FVGs =================
      //   Bearish FVG at i: high[i] < low[i-2]  (gap down, left on the way down)
      if(H[i] < L[i-2])
        { lastBearTop = L[i-2]; lastBearBot = H[i]; lastBearBar = i; }
      //   Bullish FVG at i: low[i] > high[i-2]  (gap up, left on the way up)
      if(L[i] > H[i-2])
        { lastBullTop = L[i]; lastBullBot = H[i-2]; lastBullBar = i; }
      //   A close beyond an FVG (on a later bar) means it has already been
      //   traded through, so it is no longer a valid "left-behind" gap.
      //   Skip while a setup is holding it as its reference to invert.
      if(lastBearBar >= 0 && i > lastBearBar && C[i] > lastBearTop && Bull.stage == ST_IDLE)
         lastBearBar = -1;
      if(lastBullBar >= 0 && i > lastBullBar && C[i] < lastBullBot && Bear.stage == ST_IDLE)
         lastBullBar = -1;

      //=== (b) Confirm swing pivots at bar i-InpSwingLen ============
      int p = i - InpSwingLen;
      if(p >= InpSwingLen)
        {
         if(IsSwingHigh(p, InpSwingLen)) { prevSwingHigh = H[p]; prevSwingHighBar = p; }
         if(IsSwingLow (p, InpSwingLen)) { prevSwingLow  = L[p]; prevSwingLowBar  = p; }
        }

      //=== (c) BULLISH reversal machine ============================
      //   Timeout
      if(Bull.stage != ST_IDLE && i - Bull.sweepBar > InpMaxBars)
         ResetSetup(Bull);

      //   Stage 1+2+3: sell-side liquidity sweep at a prior swing low,
      //   with a bearish FVG left behind on the way down.
      if(Bull.stage == ST_IDLE)
        {
         bool sweep = (prevSwingLowBar >= 0 && prevSwingLowBar < i &&
                       L[i] < prevSwingLow && C[i] > prevSwingLow);
         bool fvgOk = (lastBearBar >= 0 && (i - lastBearBar) <= InpFVGMaxAge &&
                       lastBearTop > L[i]);
         if(sweep && fvgOk && InPOIZone(L[i]))
           {
            Bull.stage     = ST_SWEPT;
            Bull.sweepBar  = i;
            Bull.refFVGTop = lastBearTop;
            Bull.refFVGBot = lastBearBot;
            Bull.cisdLevel = DownLegCISD(i);
           }
        }
      //   Stage 4: iFVG — close back above the left-behind bearish FVG.
      if(Bull.stage == ST_SWEPT && C[i] > Bull.refFVGTop)
        {
         Bull.stage     = ST_IFVG;
         Bull.ifvgLevel = Bull.refFVGTop;
        }
      //   Stage 5: CISD — close above the impulse opening-range level.
      if(Bull.stage == ST_IFVG && C[i] > Bull.cisdLevel)
        {
         Bull.stage    = ST_CISD;
         //   MSS reference = swing high of the candle set built so far.
         double hh = H[Bull.sweepBar];
         for(int k = Bull.sweepBar + 1; k <= i; k++) if(H[k] > hh) hh = H[k];
         Bull.mssLevel = hh;
        }
      //   Stage 6: MSS — close above that swing high -> confirmed BUY.
      if(Bull.stage == ST_CISD && C[i] > Bull.mssLevel)
        {
         BuyBuffer[i] = L[i] - offset;
         DrawLevel("iFVG", T[i], i, Bull.ifvgLevel, clrDeepSkyBlue, rates_total);
         DrawLevel("CISD", T[i], i, Bull.cisdLevel, clrGold,        rates_total);
         DrawLevel("MSS",  T[i], i, Bull.mssLevel,  clrLime,        rates_total);
         if(i == last_closed) RaiseAlert(true, T[i]);
         ResetSetup(Bull);
        }

      //=== (d) BEARISH reversal machine ===========================
      if(Bear.stage != ST_IDLE && i - Bear.sweepBar > InpMaxBars)
         ResetSetup(Bear);

      if(Bear.stage == ST_IDLE)
        {
         bool sweep = (prevSwingHighBar >= 0 && prevSwingHighBar < i &&
                       H[i] > prevSwingHigh && C[i] < prevSwingHigh);
         bool fvgOk = (lastBullBar >= 0 && (i - lastBullBar) <= InpFVGMaxAge &&
                       lastBullBot < H[i]);
         if(sweep && fvgOk && InPOIZone(H[i]))
           {
            Bear.stage     = ST_SWEPT;
            Bear.sweepBar  = i;
            Bear.refFVGTop = lastBullTop;
            Bear.refFVGBot = lastBullBot;
            Bear.cisdLevel = UpLegCISD(i);
           }
        }
      if(Bear.stage == ST_SWEPT && C[i] < Bear.refFVGBot)
        {
         Bear.stage     = ST_IFVG;
         Bear.ifvgLevel = Bear.refFVGBot;
        }
      if(Bear.stage == ST_IFVG && C[i] < Bear.cisdLevel)
        {
         Bear.stage    = ST_CISD;
         double ll = L[Bear.sweepBar];
         for(int k = Bear.sweepBar + 1; k <= i; k++) if(L[k] < ll) ll = L[k];
         Bear.mssLevel = ll;
        }
      if(Bear.stage == ST_CISD && C[i] < Bear.mssLevel)
        {
         SellBuffer[i] = H[i] + offset;
         DrawLevel("iFVG", T[i], i, Bear.ifvgLevel, clrDeepSkyBlue, rates_total);
         DrawLevel("CISD", T[i], i, Bear.cisdLevel, clrGold,        rates_total);
         DrawLevel("MSS",  T[i], i, Bear.mssLevel,  clrRed,         rates_total);
         if(i == last_closed) RaiseAlert(false, T[i]);
         ResetSetup(Bear);
        }
     }

//--- Never plot on the forming bar (no-repaint).
   if(rates_total >= 1)
     {
      BuyBuffer[rates_total - 1]  = 0.0;
      SellBuffer[rates_total - 1] = 0.0;
     }

   return(rates_total);
  }

//+------------------------------------------------------------------+
//| Fire an alert once per newly-confirmed reversal bar              |
//+------------------------------------------------------------------+
void RaiseAlert(const bool is_buy, const datetime bar_time)
  {
   static datetime last_alert = 0;
   if(bar_time == last_alert)
      return;
   last_alert = bar_time;

   string dir = is_buy ? "BUY" : "SELL";
   string msg = StringFormat("%s %s reversal: POI sweep + iFVG + CISD + MSS confirmed",
                             _Symbol, dir);
   if(InpAlertPopup) Alert(msg);
   if(InpAlertPush)  SendNotification(msg);
  }
//+------------------------------------------------------------------+
