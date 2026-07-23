//+------------------------------------------------------------------+
//|                                       POI_Reversal_Signal.mq5     |
//|     POI + Sweep Liquidity + iFVG + CISD + MSS reversal model      |
//|                                                                  |
//|  A high-quality reversal is confirmed only when this ordered      |
//|  cascade completes at a Point-of-Interest:                        |
//|                                                                  |
//|   1. POI    : price reaches a liquidity level, taken from a       |
//|               selectable timeframe (e.g. mark POI on M15 while     |
//|               entering on M1).                                    |
//|   2. FVG    : a Fair Value Gap is left behind on the way in.      |
//|   3. Sweep  : that liquidity is swept (wick beyond, close back).  |
//|   4. iFVG   : price closes back through the left-behind FVG.      |
//|   5. CISD   : Change In State of Direction — close beyond the     |
//|               opening range of the final impulse leg.             |
//|   6. MSS    : Market Structure Shift — close beyond the swing     |
//|               high/low of the candle set that produced CISD.      |
//|                                                                  |
//|  An arrow prints only when 1->6 complete in order. Every level    |
//|  (POI / iFVG / CISD / MSS) is drawn as a labelled line, and a     |
//|  dashboard shows the live progress of each side.                  |
//|                                                                  |
//|  No-Repaint: swings are confirmed with a right-hand offset and    |
//|  every stage is evaluated on CLOSED bars, so a printed arrow      |
//|  never moves or vanishes.                                        |
//+------------------------------------------------------------------+
#property copyright "Indicator"
#property version   "2.00"
#property description "POI(MTF) + Sweep + iFVG + CISD + MSS reversal confirmation with labels & dashboard."

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
input group "=== POI (Point of Interest) — multi-timeframe ==="
input ENUM_TIMEFRAMES InpPOITimeframe = PERIOD_CURRENT; // POI timeframe (e.g. M15 while entering on M1)
input double InpPOITolerancePoints = 60.0; // POI touch tolerance (points)

input group "=== Swing / liquidity detection ==="
input int    InpSwingLen    = 3;   // Fractal swing length (bars each side)
input int    InpLegLookback = 12;  // Impulse-leg lookback for CISD/MSS (bars)

input group "=== FVG (Fair Value Gap) ==="
input int    InpFVGMaxAge   = 40;  // Max age of the left-behind FVG at sweep (bars)

input group "=== Sequence timing ==="
input int    InpMaxBars     = 30;  // Max bars per phase before the setup resets

input group "=== Level lines ==="
input bool   InpDrawLevels  = true; // Draw labelled POI / iFVG / CISD / MSS lines
input int    InpLevelExtendBars = 12; // How far right to extend level lines (bars)

input group "=== Dashboard ==="
input bool   InpShowDashboard = true; // Show the status dashboard
input int    InpDashCorner   = 1;   // 0=TopLeft 1=TopRight 2=BottomLeft 3=BottomRight
input int    InpDashFontSize = 9;    // Dashboard / label font size
input color  InpDashText     = clrGainsboro; // Dashboard text colour

input group "=== Signal display ==="
input int    InpArrowOffsetPoints = 150; // Arrow distance from candle (points)
input bool   InpAlertPopup  = false; // Popup alert on new confirmed reversal
input bool   InpAlertPush   = false; // Push notification on new confirmed reversal

//+------------------------------------------------------------------+
//| Buffers                                                          |
//+------------------------------------------------------------------+
double BuyBuffer[];
double SellBuffer[];

//--- Non-series price copies (index 0 = oldest) to match OnCalculate
double O[], H[], L[], C[];
datetime T[];

//--- POI swing levels pulled from the POI timeframe (with confirm times)
double   PoiLowP[];  datetime PoiLowT[];
double   PoiHighP[]; datetime PoiHighT[];

//--- Stage constants for the reversal state machine
#define ST_IDLE  0
#define ST_POI   1   // price reached the POI, a valid FVG is on record
#define ST_SWEPT 2   // liquidity swept inside the POI
#define ST_IFVG  3   // price closed back through the left-behind FVG
#define ST_CISD  4   // change in state of direction confirmed

//--- One reversal setup (bullish or bearish share the same struct)
struct Setup
  {
   int    stage;
   int    poiBar;       // bar where the POI was first reached
   double poiLevel;     // the POI liquidity level being tracked
   int    sweepBar;     // bar of the sweep
   double refFVGTop;    // left-behind FVG top / bottom (the level to invert)
   double refFVGBot;
   double cisdLevel;    // Entry 1 — opening-range level of the impulse leg
   double ifvgLevel;    // Entry 2 — the inverted FVG (iFVG)
   double obLevel;      // Entry 3 — order block (origin candle of the sweep)
   double mssLevel;     // MSS trigger — swing high/low that must break
   double runExtreme;   // running high (bull) / low (bear) since the sweep
  };

Setup Bull, Bear;

//--- Last confirmed signals (for the dashboard)
datetime LastBuyTime  = 0;
datetime LastSellTime = 0;

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
//| Deinit — clean up our objects                                    |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, "POIrev_");
  }

//+------------------------------------------------------------------+
//| Short timeframe name (e.g. "M15") for labels                     |
//+------------------------------------------------------------------+
string TFName(const ENUM_TIMEFRAMES tf)
  {
   string s = EnumToString(tf);
   int pos = StringFind(s, "PERIOD_");
   if(pos == 0) s = StringSubstr(s, 7);
   return(s);
  }

//+------------------------------------------------------------------+
//| Reset a setup to idle                                            |
//+------------------------------------------------------------------+
void ResetSetup(Setup &s)
  {
   s.stage      = ST_IDLE;
   s.poiBar     = -1;
   s.poiLevel   = 0.0;
   s.sweepBar   = -1;
   s.refFVGTop  = 0.0;
   s.refFVGBot  = 0.0;
   s.cisdLevel  = 0.0;
   s.ifvgLevel  = 0.0;
   s.obLevel    = 0.0;
   s.mssLevel   = 0.0;
   s.runExtreme = 0.0;
  }

//+------------------------------------------------------------------+
//| Order-block level = origin candle of the sweep (deepest retest)   |
//|   bull: high of the lowest-low candle of the leg into the sweep    |
//|   bear: low  of the highest-high candle of the leg into the sweep  |
//+------------------------------------------------------------------+
double BullOB(const int b)
  {
   int lowBar = b;
   for(int k = b; k >= 1 && k > b - InpLegLookback - 1; k--)
      if(L[k] < L[lowBar]) lowBar = k;
   return(H[lowBar]);
  }

double BearOB(const int b)
  {
   int highBar = b;
   for(int k = b; k >= 1 && k > b - InpLegLookback - 1; k--)
      if(H[k] > H[highBar]) highBar = k;
   return(L[highBar]);
  }

//+------------------------------------------------------------------+
//| Build POI swing levels from the POI timeframe                    |
//|   Confirmation time = close of the bar that completes the pivot, |
//|   so on the chart TF a level is only used once it cannot repaint. |
//+------------------------------------------------------------------+
void BuildPOISwings(const datetime t_from, const datetime t_to)
  {
   ArrayResize(PoiLowP, 0);  ArrayResize(PoiLowT, 0);
   ArrayResize(PoiHighP, 0); ArrayResize(PoiHighT, 0);

   ENUM_TIMEFRAMES tf = (InpPOITimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpPOITimeframe;
   int secs = PeriodSeconds(tf);
   int len  = InpSwingLen;

   MqlRates r[];
   ArraySetAsSeries(r, false);
   int n = CopyRates(_Symbol, tf, t_from - (datetime)(secs * (len + 2)), t_to, r);
   if(n < 2 * len + 1)
      return;

   for(int j = len; j <= n - len - 1; j++)
     {
      bool sh = true, sl = true;
      for(int k = 1; k <= len; k++)
        {
         if(r[j-k].high > r[j].high || r[j+k].high > r[j].high) sh = false;
         if(r[j-k].low  < r[j].low  || r[j+k].low  < r[j].low ) sl = false;
        }
      datetime conf = (datetime)(r[j+len].time + secs); // pivot confirmed at this close
      if(sh)
        {
         int s = ArraySize(PoiHighP);
         ArrayResize(PoiHighP, s+1); ArrayResize(PoiHighT, s+1);
         PoiHighP[s] = r[j].high; PoiHighT[s] = conf;
        }
      if(sl)
        {
         int s = ArraySize(PoiLowP);
         ArrayResize(PoiLowP, s+1); ArrayResize(PoiLowT, s+1);
         PoiLowP[s] = r[j].low; PoiLowT[s] = conf;
        }
     }
  }

//+------------------------------------------------------------------+
//| CISD opening-range level of the down-leg into sweep bar b        |
//|   = highest OPEN of the consecutive bearish candles of the leg    |
//+------------------------------------------------------------------+
double DownLegCISD(const int b)
  {
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
//| CISD opening-range level of the up-leg into sweep bar b          |
//+------------------------------------------------------------------+
double UpLegCISD(const int b)
  {
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
//| Draw a labelled horizontal segment (line + text tag)             |
//+------------------------------------------------------------------+
void DrawTaggedLine(const string id, const string text,
                    const datetime t0, const datetime t1,
                    const double price, const color col)
  {
   if(!InpDrawLevels) return;

   string ln = "POIrev_" + id;
   if(ObjectFind(0, ln) < 0)
      ObjectCreate(0, ln, OBJ_TREND, 0, t0, price, t1, price);
   ObjectSetInteger(0, ln, OBJPROP_TIME,  0, t0);
   ObjectSetDouble (0, ln, OBJPROP_PRICE, 0, price);
   ObjectSetInteger(0, ln, OBJPROP_TIME,  1, t1);
   ObjectSetDouble (0, ln, OBJPROP_PRICE, 1, price);
   ObjectSetInteger(0, ln, OBJPROP_COLOR, col);
   ObjectSetInteger(0, ln, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, ln, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, ln, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, ln, OBJPROP_BACK, true);
   ObjectSetInteger(0, ln, OBJPROP_SELECTABLE, false);

   string tx = "POIrev_" + id + "_t";
   if(ObjectFind(0, tx) < 0)
      ObjectCreate(0, tx, OBJ_TEXT, 0, t0, price);
   ObjectSetInteger(0, tx, OBJPROP_TIME,  0, t0);
   ObjectSetDouble (0, tx, OBJPROP_PRICE, 0, price);
   ObjectSetString (0, tx, OBJPROP_TEXT, " " + text);
   ObjectSetInteger(0, tx, OBJPROP_COLOR, col);
   ObjectSetInteger(0, tx, OBJPROP_FONTSIZE, InpDashFontSize);
   ObjectSetInteger(0, tx, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, tx, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
//| Draw the full labelled level set for one confirmed side          |
//+------------------------------------------------------------------+
void DrawSet(const string sig, const Setup &s, const bool is_buy,
             const int endIdx, const ENUM_TIMEFRAMES tf)
  {
   datetime t1 = T[endIdx];
   color poiCol  = clrDodgerBlue;
   color cisdCol = clrGold;        // Entry 1
   color ifvgCol = clrDeepSkyBlue; // Entry 2
   color obCol   = clrMediumOrchid;// Entry 3
   color mssCol  = is_buy ? clrLime : clrOrangeRed;

   int pb = (s.poiBar  >= 0) ? s.poiBar  : s.sweepBar;
   int sb = (s.sweepBar >= 0) ? s.sweepBar : pb;

   DrawTaggedLine(sig + "_POI",  "POI " + TFName(tf),  T[pb], t1, s.poiLevel,  poiCol);
   DrawTaggedLine(sig + "_MSS",  "MSS (trigger)",      T[sb], t1, s.mssLevel,  mssCol);
   DrawTaggedLine(sig + "_E1",   "Entry 1: CISD",      T[sb], t1, s.cisdLevel, cisdCol);
   DrawTaggedLine(sig + "_E2",   "Entry 2: iFVG",      T[sb], t1, s.ifvgLevel, ifvgCol);
   DrawTaggedLine(sig + "_E3",   "Entry 3: OB",        T[sb], t1, s.obLevel,   obCol);
  }

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
string Tick(const int stage, const int need) { return (stage >= need ? "[x]" : "[ ]"); }

string StageName(const int stage, const bool fired)
  {
   if(fired)            return("ENTRY SIGNAL");
   switch(stage)
     {
      case ST_POI:   return("at POI");
      case ST_SWEPT: return("swept");
      case ST_IFVG:  return("iFVG done");
      case ST_CISD:  return("await MSS");
     }
   return("idle");
  }

void DashLine(const int row, const string text, const color col,
              const int corner, const int x0, const int y0, const int dy)
  {
   // Right-hand corners must anchor the text on its right edge, otherwise
   // the panel is drawn off the right side of the chart.
   bool isRight = (corner == CORNER_RIGHT_UPPER || corner == CORNER_RIGHT_LOWER);
   ENUM_ANCHOR_POINT anchor = isRight ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER;

   string name = "POIrev_dash_" + (string)row;
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x0);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y0 + row * dy);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpDashFontSize);
   ObjectSetString (0, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetString (0, name, OBJPROP_TEXT, text);
  }

void DrawDashboard(const ENUM_TIMEFRAMES tf, const bool buyFired, const bool sellFired)
  {
   if(!InpShowDashboard) return;

   int corner = InpDashCorner; // 0..3 map directly to CORNER_* enum
   int x0 = 12;
   int y0 = 18;
   int dy = InpDashFontSize + 8;

   int bs = Bull.stage, es = Bear.stage;
   color hdr = clrWhite, tc = InpDashText;

   DashLine(0, "POI Reversal  |  POI TF: " + TFName(tf),                 hdr, corner, x0, y0, dy);
   DashLine(1, "step          BULL   BEAR",                              tc,  corner, x0, y0, dy);
   DashLine(2, "1 POI         " + Tick(bs,ST_POI)   + "   " + Tick(es,ST_POI),   (bs>=ST_POI  ||es>=ST_POI )?clrAqua:tc, corner, x0, y0, dy);
   DashLine(3, "2 FVG         " + Tick(bs,ST_POI)   + "   " + Tick(es,ST_POI),   (bs>=ST_POI  ||es>=ST_POI )?clrAqua:tc, corner, x0, y0, dy);
   DashLine(4, "3 Sweep       " + Tick(bs,ST_SWEPT) + "   " + Tick(es,ST_SWEPT), (bs>=ST_SWEPT||es>=ST_SWEPT)?clrAqua:tc, corner, x0, y0, dy);
   DashLine(5, "4 iFVG        " + Tick(bs,ST_IFVG)  + "   " + Tick(es,ST_IFVG),  (bs>=ST_IFVG ||es>=ST_IFVG )?clrAqua:tc, corner, x0, y0, dy);
   DashLine(6, "5 CISD        " + Tick(bs,ST_CISD)  + "   " + Tick(es,ST_CISD),  (bs>=ST_CISD ||es>=ST_CISD )?clrAqua:tc, corner, x0, y0, dy);
   DashLine(7, "6 MSS/Entry   " + (buyFired?"[x]":"[ ]") + "   " + (sellFired?"[x]":"[ ]"),
                                                                          (buyFired||sellFired)?clrYellow:tc, corner, x0, y0, dy);
   DashLine(8, "BULL: " + StageName(bs, buyFired) + "   BEAR: " + StageName(es, sellFired),
               (buyFired?clrLime:(sellFired?clrOrangeRed:tc)), corner, x0, y0, dy);
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

   ENUM_TIMEFRAMES poiTF = (InpPOITimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpPOITimeframe;
   BuildPOISwings(T[0], T[rates_total - 1]);

//--- Full rebuild: clear buffers/objects, replay the state machine.
   ArrayInitialize(BuyBuffer,  0.0);
   ArrayInitialize(SellBuffer, 0.0);
   ObjectsDeleteAll(0, "POIrev_");
   ResetSetup(Bull);
   ResetSetup(Bear);

   double offset = InpArrowOffsetPoints * _Point;
   double tol    = InpPOITolerancePoints * _Point;

//--- Running references maintained as bars stream in (left -> right).
   double lastBearTop = 0.0, lastBearBot = 0.0; int lastBearBar = -1;
   double lastBullTop = 0.0, lastBullBot = 0.0; int lastBullBar = -1;

//--- POI level cursors (advance as their confirm time passes)
   int    loIdx = -1, hiIdx = -1;
   double poiLow = 0.0, poiHigh = 0.0;
   bool   havePoiLow = false, havePoiHigh = false;

   bool buyFired = false, sellFired = false;
   int  last_closed = rates_total - 2;

   for(int i = 2; i <= last_closed; i++)
     {
      //=== (a) Update the most recent unbroken FVGs =================
      if(H[i] < L[i-2])
        { lastBearTop = L[i-2]; lastBearBot = H[i]; lastBearBar = i; }
      if(L[i] > H[i-2])
        { lastBullTop = L[i]; lastBullBot = H[i-2]; lastBullBar = i; }
      if(lastBearBar >= 0 && i > lastBearBar && C[i] > lastBearTop && Bull.stage == ST_IDLE)
         lastBearBar = -1;
      if(lastBullBar >= 0 && i > lastBullBar && C[i] < lastBullBot && Bear.stage == ST_IDLE)
         lastBullBar = -1;

      //=== (b) Advance the POI liquidity levels for this bar ========
      while(loIdx + 1 < ArraySize(PoiLowT)  && PoiLowT[loIdx+1]  <= T[i]) { loIdx++; poiLow  = PoiLowP[loIdx];  havePoiLow  = true; }
      while(hiIdx + 1 < ArraySize(PoiHighT) && PoiHighT[hiIdx+1] <= T[i]) { hiIdx++; poiHigh = PoiHighP[hiIdx]; havePoiHigh = true; }

      //=== (c) BULLISH reversal machine ============================
      if(Bull.stage == ST_POI   && i - Bull.poiBar   > InpMaxBars) ResetSetup(Bull);
      if(Bull.stage >= ST_SWEPT && i - Bull.sweepBar > InpMaxBars) ResetSetup(Bull);

      //   1+2: price reaches the POI with a bearish FVG left behind.
      if(Bull.stage == ST_IDLE && havePoiLow)
        {
         bool fvgOk = (lastBearBar >= 0 && (i - lastBearBar) <= InpFVGMaxAge && lastBearTop > poiLow);
         if(L[i] <= poiLow + tol && fvgOk)
           {
            Bull.stage    = ST_POI;
            Bull.poiBar   = i;
            Bull.poiLevel = poiLow;
            Bull.refFVGTop = lastBearTop;
            Bull.refFVGBot = lastBearBot;
           }
        }
      //   3: sweep — wick below the POI then close back above it.
      if(Bull.stage == ST_POI && L[i] < Bull.poiLevel)
        {
         if(C[i] > Bull.poiLevel)
           {
            Bull.stage      = ST_SWEPT;
            Bull.sweepBar   = i;
            Bull.cisdLevel  = DownLegCISD(i);
            Bull.obLevel    = BullOB(i);
            Bull.runExtreme = H[i];
           }
         else
            ResetSetup(Bull); // closed through the POI = level broke, no sweep
        }
      //   track the swing high of the candle set built since the sweep
      if(Bull.stage == ST_SWEPT || Bull.stage == ST_IFVG)
         if(H[i] > Bull.runExtreme) Bull.runExtreme = H[i];
      //   4: iFVG — close back above the left-behind bearish FVG.
      if(Bull.stage == ST_SWEPT && C[i] > Bull.refFVGTop)
        { Bull.stage = ST_IFVG; Bull.ifvgLevel = Bull.refFVGTop; }
      //   5: CISD — close above the impulse opening range.
      if(Bull.stage == ST_IFVG && C[i] > Bull.cisdLevel)
        { Bull.stage = ST_CISD; Bull.mssLevel = Bull.runExtreme; }
      //   6: MSS — close above that swing high -> confirmed BUY.
      if(Bull.stage == ST_CISD && C[i] > Bull.mssLevel)
        {
         BuyBuffer[i] = L[i] - offset;
         int endIdx = MathMin(i + InpLevelExtendBars, rates_total - 1);
         DrawSet((string)(long)T[i] + "_B", Bull, true, endIdx, poiTF);
         if(i == last_closed) { buyFired = true; RaiseAlert(true, T[i]); }
         ResetSetup(Bull);
        }

      //=== (d) BEARISH reversal machine ===========================
      if(Bear.stage == ST_POI   && i - Bear.poiBar   > InpMaxBars) ResetSetup(Bear);
      if(Bear.stage >= ST_SWEPT && i - Bear.sweepBar > InpMaxBars) ResetSetup(Bear);

      if(Bear.stage == ST_IDLE && havePoiHigh)
        {
         bool fvgOk = (lastBullBar >= 0 && (i - lastBullBar) <= InpFVGMaxAge && lastBullBot < poiHigh);
         if(H[i] >= poiHigh - tol && fvgOk)
           {
            Bear.stage    = ST_POI;
            Bear.poiBar   = i;
            Bear.poiLevel = poiHigh;
            Bear.refFVGTop = lastBullTop;
            Bear.refFVGBot = lastBullBot;
           }
        }
      if(Bear.stage == ST_POI && H[i] > Bear.poiLevel)
        {
         if(C[i] < Bear.poiLevel)
           {
            Bear.stage      = ST_SWEPT;
            Bear.sweepBar   = i;
            Bear.cisdLevel  = UpLegCISD(i);
            Bear.obLevel    = BearOB(i);
            Bear.runExtreme = L[i];
           }
         else
            ResetSetup(Bear);
        }
      if(Bear.stage == ST_SWEPT || Bear.stage == ST_IFVG)
         if(L[i] < Bear.runExtreme) Bear.runExtreme = L[i];
      if(Bear.stage == ST_SWEPT && C[i] < Bear.refFVGBot)
        { Bear.stage = ST_IFVG; Bear.ifvgLevel = Bear.refFVGBot; }
      if(Bear.stage == ST_IFVG && C[i] < Bear.cisdLevel)
        { Bear.stage = ST_CISD; Bear.mssLevel = Bear.runExtreme; }
      if(Bear.stage == ST_CISD && C[i] < Bear.mssLevel)
        {
         SellBuffer[i] = H[i] + offset;
         int endIdx = MathMin(i + InpLevelExtendBars, rates_total - 1);
         DrawSet((string)(long)T[i] + "_S", Bear, false, endIdx, poiTF);
         if(i == last_closed) { sellFired = true; RaiseAlert(false, T[i]); }
         ResetSetup(Bear);
        }
     }

//--- Draw the live (still-forming) setups so POI/levels are visible.
   int liveEnd = rates_total - 1;
   if(Bull.stage >= ST_POI)
     {
      datetime t1 = T[liveEnd];
      DrawTaggedLine("live_B_POI", "POI " + TFName(poiTF), T[Bull.poiBar], t1, Bull.poiLevel, clrDodgerBlue);
      if(Bull.stage >= ST_SWEPT) DrawTaggedLine("live_B_E1", "Entry 1: CISD", T[Bull.sweepBar], t1, Bull.cisdLevel, clrGold);
      if(Bull.stage >= ST_SWEPT) DrawTaggedLine("live_B_E3", "Entry 3: OB",   T[Bull.sweepBar], t1, Bull.obLevel,   clrMediumOrchid);
      if(Bull.stage >= ST_IFVG)  DrawTaggedLine("live_B_E2", "Entry 2: iFVG", T[Bull.sweepBar], t1, Bull.ifvgLevel, clrDeepSkyBlue);
      if(Bull.stage >= ST_CISD)  DrawTaggedLine("live_B_MSS","MSS (trigger)", T[Bull.sweepBar], t1, Bull.mssLevel,  clrLime);
     }
   if(Bear.stage >= ST_POI)
     {
      datetime t1 = T[liveEnd];
      DrawTaggedLine("live_S_POI", "POI " + TFName(poiTF), T[Bear.poiBar], t1, Bear.poiLevel, clrDodgerBlue);
      if(Bear.stage >= ST_SWEPT) DrawTaggedLine("live_S_E1", "Entry 1: CISD", T[Bear.sweepBar], t1, Bear.cisdLevel, clrGold);
      if(Bear.stage >= ST_SWEPT) DrawTaggedLine("live_S_E3", "Entry 3: OB",   T[Bear.sweepBar], t1, Bear.obLevel,   clrMediumOrchid);
      if(Bear.stage >= ST_IFVG)  DrawTaggedLine("live_S_E2", "Entry 2: iFVG", T[Bear.sweepBar], t1, Bear.ifvgLevel, clrDeepSkyBlue);
      if(Bear.stage >= ST_CISD)  DrawTaggedLine("live_S_MSS","MSS (trigger)", T[Bear.sweepBar], t1, Bear.mssLevel,  clrOrangeRed);
     }

   DrawDashboard(poiTF, buyFired, sellFired);

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
   if(is_buy)  { if(bar_time == LastBuyTime)  return; LastBuyTime  = bar_time; }
   else        { if(bar_time == LastSellTime) return; LastSellTime = bar_time; }

   string dir = is_buy ? "BUY" : "SELL";
   string msg = StringFormat("%s %s reversal: POI sweep + iFVG + CISD + MSS confirmed",
                             _Symbol, dir);
   if(InpAlertPopup) Alert(msg);
   if(InpAlertPush)  SendNotification(msg);
  }
//+------------------------------------------------------------------+
