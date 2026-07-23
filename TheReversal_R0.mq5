//+------------------------------------------------------------------+
//|                                            TheReversal_R0.mq5     |
//|   POI + Sweep Liquidity + iFVG + CISD + MSS  reversal system      |
//|                                                                  |
//|   Revision tag: R0  (bump to R1, R2, ... on every change)         |
//|                                                                  |
//|   Modules (see banners below):                                    |
//|     1) POI Manager        — build POI zones on a chosen TF        |
//|     2) FVG Detector       — left-behind Fair Value Gaps           |
//|     3) Sweep Scanner      — liquidity grab at the POI             |
//|     4) iFVG Confirmation  — close back through the FVG            |
//|     5) CISD Marker        — change in state of direction          |
//|     6) MSS Checker        — market structure shift = trigger      |
//|     7) Entry Planner      — Entry 1=CISD 2=iFVG 3=OB              |
//|     8) Dashboard / UI     — live checklist + zone boxes           |
//|                                                                  |
//|   No-Repaint: HTF POI zones use closed-bar confirm times, and     |
//|   every stage is evaluated on CLOSED bars only.                   |
//+------------------------------------------------------------------+
#property copyright "Indicator"
#property version   "1.00"
#property description "TheReversal R0 — POI(MTF, type-selectable) + Sweep + iFVG + CISD + MSS with zones & dashboard."

#property indicator_chart_window
#property indicator_buffers 2
#property indicator_plots   2

#property indicator_label1  "Buy reversal"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLime
#property indicator_width1  3

#property indicator_label2  "Sell reversal"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_width2  3

//+------------------------------------------------------------------+
//| Types                                                            |
//+------------------------------------------------------------------+
enum ENUM_POI_TYPE
  {
   POI_SWING = 0, // Swing / Key Level (liquidity)
   POI_FVG   = 1, // HTF Fair Value Gap
   POI_OB    = 2, // HTF Order Block
   POI_FIBO  = 3  // Fibonacci retracement zone
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== POI Manager ==="
input ENUM_TIMEFRAMES InpPOITimeframe = PERIOD_M15; // POI timeframe (entry runs on the chart TF)
input ENUM_POI_TYPE   InpPOIType      = POI_SWING;  // POI type
input double InpPOIZonePoints      = 80.0;  // Zone thickness for Swing/OB fallback (points)
input double InpPOITolerancePoints = 60.0;  // POI touch tolerance (points)
input double InpFibA = 0.5;                 // Fibo zone near edge (e.g. 0.5)
input double InpFibB = 0.786;               // Fibo zone far edge (e.g. 0.786)
input color  InpPOIColor = clrSlateBlue;    // POI zone colour

input group "=== Sequence engine ==="
input int    InpSwingLen    = 3;   // Fractal swing length (bars each side)
input int    InpLegLookback = 12;  // Impulse-leg lookback for CISD/OB (bars)
input int    InpFVGMaxAge   = 40;  // Max age of the left-behind FVG at sweep (bars)
input int    InpMaxBars     = 30;  // Max bars per phase before reset

input group "=== Entry Planner / levels ==="
input bool   InpDrawZones   = true; // Draw POI zone boxes
input bool   InpDrawLevels  = true; // Draw labelled Entry / MSS lines
input int    InpLevelExtendBars = 12; // Extend level lines/zones (bars)

input group "=== Dashboard ==="
input bool   InpShowDashboard = true; // Show the status dashboard
input int    InpDashCorner   = 1;   // 0=TopLeft 1=TopRight 2=BottomLeft 3=BottomRight
input int    InpDashFontSize = 9;    // Dashboard / label font size
input color  InpDashText     = clrGainsboro; // Dashboard text colour

input group "=== Alerts ==="
input int    InpArrowOffsetPoints = 150; // Arrow distance from candle (points)
input bool   InpAlertPopup  = false; // Popup alert on new confirmed reversal
input bool   InpAlertPush   = false; // Push notification
input bool   InpAlertEmail  = false; // E-mail alert

//+------------------------------------------------------------------+
//| Buffers & working copies                                         |
//+------------------------------------------------------------------+
double BuyBuffer[];
double SellBuffer[];

double O[], H[], L[], C[];
datetime T[];

//--- POI zones (parallel arrays; sorted by confirm time ascending)
double   SupTop[], SupBot[], SupTgt[]; datetime SupT[]; // support (bull)
double   ResTop[], ResBot[], ResTgt[]; datetime ResT[]; // resistance (bear)

//--- Stage constants
#define ST_IDLE  0
#define ST_POI   1
#define ST_SWEPT 2
#define ST_IFVG  3
#define ST_CISD  4

struct Setup
  {
   int    stage;
   int    poiBar;
   double poiTop, poiBot, poiTgt; // POI zone + sweep target level
   int    sweepBar;
   double refFVGTop, refFVGBot;
   double cisdLevel;   // Entry 1
   double ifvgLevel;   // Entry 2
   double obLevel;     // Entry 3
   double mssLevel;    // trigger
   double runExtreme;
  };

Setup Bull, Bear;

//--- Last confirmed signal (dashboard)
datetime LastBuyTime = 0, LastSellTime = 0;
int      LastBuyBar = -1, LastSellBar = -1;

int LastCalcBars = 0;

//+------------------------------------------------------------------+
//| Init / Deinit                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, BuyBuffer,  INDICATOR_DATA);
   SetIndexBuffer(1, SellBuffer, INDICATOR_DATA);
   PlotIndexSetInteger(0, PLOT_ARROW, 233);
   PlotIndexSetInteger(1, PLOT_ARROW, 234);
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, 0.0);

   ArraySetAsSeries(O, false); ArraySetAsSeries(H, false);
   ArraySetAsSeries(L, false); ArraySetAsSeries(C, false);
   ArraySetAsSeries(T, false);

   IndicatorSetString(INDICATOR_SHORTNAME, "TheReversal R0");
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, "TR0_");
  }

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
string TFName(const ENUM_TIMEFRAMES tf)
  {
   string s = EnumToString(tf);
   if(StringFind(s, "PERIOD_") == 0) s = StringSubstr(s, 7);
   return(s);
  }

string POITypeName(const ENUM_POI_TYPE t)
  {
   switch(t)
     {
      case POI_SWING: return("Swing");
      case POI_FVG:   return("FVG");
      case POI_OB:    return("OB");
      case POI_FIBO:  return("Fibo");
     }
   return("?");
  }

void ResetSetup(Setup &s)
  {
   s.stage = ST_IDLE; s.poiBar = -1;
   s.poiTop = 0; s.poiBot = 0; s.poiTgt = 0;
   s.sweepBar = -1; s.refFVGTop = 0; s.refFVGBot = 0;
   s.cisdLevel = 0; s.ifvgLevel = 0; s.obLevel = 0;
   s.mssLevel = 0; s.runExtreme = 0;
  }

void PushSup(const double top, const double bot, const double tgt, const datetime tm)
  {
   int n = ArraySize(SupTop);
   ArrayResize(SupTop, n+1); ArrayResize(SupBot, n+1); ArrayResize(SupTgt, n+1); ArrayResize(SupT, n+1);
   SupTop[n] = top; SupBot[n] = bot; SupTgt[n] = tgt; SupT[n] = tm;
  }
void PushRes(const double top, const double bot, const double tgt, const datetime tm)
  {
   int n = ArraySize(ResTop);
   ArrayResize(ResTop, n+1); ArrayResize(ResBot, n+1); ArrayResize(ResTgt, n+1); ArrayResize(ResT, n+1);
   ResTop[n] = top; ResBot[n] = bot; ResTgt[n] = tgt; ResT[n] = tm;
  }

//+==================================================================+
//|  MODULE 1 — POI MANAGER : build POI zones from the POI timeframe  |
//+==================================================================+
void BuildPOIs(const datetime t_from, const datetime t_to)
  {
   ArrayResize(SupTop,0); ArrayResize(SupBot,0); ArrayResize(SupTgt,0); ArrayResize(SupT,0);
   ArrayResize(ResTop,0); ArrayResize(ResBot,0); ArrayResize(ResTgt,0); ArrayResize(ResT,0);

   ENUM_TIMEFRAMES tf = (InpPOITimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpPOITimeframe;
   int secs = PeriodSeconds(tf);
   int len  = InpSwingLen;
   double zh = InpPOIZonePoints * _Point;

   MqlRates r[];
   ArraySetAsSeries(r, false);
   int n = CopyRates(_Symbol, tf, t_from - (datetime)(secs * (len + 2)), t_to, r);
   if(n < 2 * len + 1) return;

   //--- for FIBO we need the previous opposite pivot to define a leg
   double prevLowP = 0.0;  datetime prevLowT = 0;  bool haveLow = false;
   double prevHighP = 0.0; datetime prevHighT = 0; bool haveHigh = false;

   for(int j = len; j <= n - len - 1; j++)
     {
      bool sh = true, sl = true;
      for(int k = 1; k <= len; k++)
        {
         if(r[j-k].high > r[j].high || r[j+k].high > r[j].high) sh = false;
         if(r[j-k].low  < r[j].low  || r[j+k].low  < r[j].low ) sl = false;
        }
      datetime conf = (datetime)(r[j+len].time + secs);

      //--- SWING LOW -> a support / demand POI (bullish reversal side)
      if(sl)
        {
         double top = 0, bot = 0, tgt = r[j].low;
         if(InpPOIType == POI_SWING)
           { bot = r[j].low; top = r[j].low + zh; }
         else if(InpPOIType == POI_OB)
           {
            int m = -1;
            for(int q = j; q >= j - 3 && q >= 1; q--) if(r[q].close < r[q].open) { m = q; break; }
            if(m >= 0) { top = r[m].high; bot = r[m].low; tgt = r[m].low; }
            else       { bot = r[j].low;  top = r[j].low + zh; }
           }
         else if(InpPOIType == POI_FVG)
           {
            int b = -1;
            for(int q = j; q <= j + 4 && q <= n - 1; q++) if(q >= 2 && r[q].low > r[q-2].high) { b = q; break; }
            if(b >= 0) { top = r[b].low; bot = r[b-2].high; tgt = r[b-2].high; }
            else       { bot = r[j].low; top = r[j].low + zh; }
           }
         else if(InpPOIType == POI_FIBO && haveHigh && prevHighT > prevLowT)
           {
            // last up-leg = prevLow -> prevHigh ; price retraces down into it
            double lo = r[j].low, hi = prevHighP;      // use this fresh low as leg base
            if(hi > lo)
              { top = hi - InpFibA * (hi - lo); bot = hi - InpFibB * (hi - lo); tgt = bot; }
           }
         if(top > 0 && top > bot) PushSup(top, bot, tgt, conf);
         prevLowP = r[j].low; prevLowT = conf; haveLow = true;
        }

      //--- SWING HIGH -> a resistance / supply POI (bearish reversal side)
      if(sh)
        {
         double top = 0, bot = 0, tgt = r[j].high;
         if(InpPOIType == POI_SWING)
           { top = r[j].high; bot = r[j].high - zh; }
         else if(InpPOIType == POI_OB)
           {
            int m = -1;
            for(int q = j; q >= j - 3 && q >= 1; q--) if(r[q].close > r[q].open) { m = q; break; }
            if(m >= 0) { top = r[m].high; bot = r[m].low; tgt = r[m].high; }
            else       { top = r[j].high; bot = r[j].high - zh; }
           }
         else if(InpPOIType == POI_FVG)
           {
            int b = -1;
            for(int q = j; q <= j + 4 && q <= n - 1; q++) if(q >= 2 && r[q].high < r[q-2].low) { b = q; break; }
            if(b >= 0) { top = r[b-2].low; bot = r[b].high; tgt = r[b-2].low; }
            else       { top = r[j].high; bot = r[j].high - zh; }
           }
         else if(InpPOIType == POI_FIBO && haveLow && prevLowT > prevHighT)
           {
            double hi = r[j].high, lo = prevLowP;      // last down-leg base
            if(hi > lo)
              { bot = lo + InpFibA * (hi - lo); top = lo + InpFibB * (hi - lo); tgt = top; }
           }
         if(top > 0 && top > bot) PushRes(top, bot, tgt, conf);
         prevHighP = r[j].high; prevHighT = conf; haveHigh = true;
        }
     }
  }

//+==================================================================+
//|  MODULE 5 — CISD MARKER : opening range of the final impulse leg  |
//+==================================================================+
double DownLegCISD(const int b)
  {
   double lvl = O[b]; bool started = false;
   for(int k = b; k >= 1 && k > b - InpLegLookback - 1; k--)
     {
      if(C[k] < O[k]) { lvl = started ? MathMax(lvl, O[k]) : O[k]; started = true; }
      else if(started) break;
     }
   return(lvl);
  }
double UpLegCISD(const int b)
  {
   double lvl = O[b]; bool started = false;
   for(int k = b; k >= 1 && k > b - InpLegLookback - 1; k--)
     {
      if(C[k] > O[k]) { lvl = started ? MathMin(lvl, O[k]) : O[k]; started = true; }
      else if(started) break;
     }
   return(lvl);
  }

//+==================================================================+
//|  MODULE 7 — ENTRY PLANNER : order-block (Entry 3) origin candle   |
//+==================================================================+
double BullOB(const int b)
  {
   int lowBar = b;
   for(int k = b; k >= 1 && k > b - InpLegLookback - 1; k--) if(L[k] < L[lowBar]) lowBar = k;
   return(H[lowBar]);
  }
double BearOB(const int b)
  {
   int highBar = b;
   for(int k = b; k >= 1 && k > b - InpLegLookback - 1; k--) if(H[k] > H[highBar]) highBar = k;
   return(L[highBar]);
  }

//+==================================================================+
//|  MODULE 8 — DRAWING (zones, levels, dashboard)                    |
//+==================================================================+
void DrawZone(const string id, const datetime t0, const datetime t1,
              const double top, const double bot, const color col)
  {
   if(!InpDrawZones) return;
   string nm = "TR0_" + id;
   if(ObjectFind(0, nm) < 0) ObjectCreate(0, nm, OBJ_RECTANGLE, 0, t0, top, t1, bot);
   ObjectSetInteger(0, nm, OBJPROP_TIME, 0, t0);  ObjectSetDouble(0, nm, OBJPROP_PRICE, 0, top);
   ObjectSetInteger(0, nm, OBJPROP_TIME, 1, t1);  ObjectSetDouble(0, nm, OBJPROP_PRICE, 1, bot);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, col);
   ObjectSetInteger(0, nm, OBJPROP_FILL, true);
   ObjectSetInteger(0, nm, OBJPROP_BACK, true);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
  }

void DrawTaggedLine(const string id, const string text, const datetime t0, const datetime t1,
                    const double price, const color col)
  {
   if(!InpDrawLevels) return;
   string ln = "TR0_" + id;
   if(ObjectFind(0, ln) < 0) ObjectCreate(0, ln, OBJ_TREND, 0, t0, price, t1, price);
   ObjectSetInteger(0, ln, OBJPROP_TIME, 0, t0);  ObjectSetDouble(0, ln, OBJPROP_PRICE, 0, price);
   ObjectSetInteger(0, ln, OBJPROP_TIME, 1, t1);  ObjectSetDouble(0, ln, OBJPROP_PRICE, 1, price);
   ObjectSetInteger(0, ln, OBJPROP_COLOR, col);
   ObjectSetInteger(0, ln, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, ln, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, ln, OBJPROP_BACK, true);
   ObjectSetInteger(0, ln, OBJPROP_SELECTABLE, false);
   string tx = "TR0_" + id + "_t";
   if(ObjectFind(0, tx) < 0) ObjectCreate(0, tx, OBJ_TEXT, 0, t0, price);
   ObjectSetInteger(0, tx, OBJPROP_TIME, 0, t0);  ObjectSetDouble(0, tx, OBJPROP_PRICE, 0, price);
   ObjectSetString (0, tx, OBJPROP_TEXT, " " + text);
   ObjectSetInteger(0, tx, OBJPROP_COLOR, col);
   ObjectSetInteger(0, tx, OBJPROP_FONTSIZE, InpDashFontSize);
   ObjectSetInteger(0, tx, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, tx, OBJPROP_SELECTABLE, false);
  }

void DrawEntrySet(const string sig, const Setup &s, const bool is_buy, const int endIdx)
  {
   datetime t1 = T[endIdx];
   int sb = (s.sweepBar >= 0) ? s.sweepBar : s.poiBar;
   color mssCol = is_buy ? clrLime : clrOrangeRed;
   DrawTaggedLine(sig + "_MSS", "MSS (trigger)", T[sb], t1, s.mssLevel,  mssCol);
   DrawTaggedLine(sig + "_E1",  "Entry 1: CISD", T[sb], t1, s.cisdLevel, clrGold);
   DrawTaggedLine(sig + "_E2",  "Entry 2: iFVG", T[sb], t1, s.ifvgLevel, clrDeepSkyBlue);
   DrawTaggedLine(sig + "_E3",  "Entry 3: OB",   T[sb], t1, s.obLevel,   clrMediumOrchid);
  }

//--- dashboard cell helpers
string YN(const bool b) { return b ? "YES" : " - "; }

void DashLine(const int row, const string text, const color col, const int corner,
              const int x0, const int y0, const int dy)
  {
   bool isRight = (corner == CORNER_RIGHT_UPPER || corner == CORNER_RIGHT_LOWER);
   ENUM_ANCHOR_POINT anchor = isRight ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER;
   string nm = "TR0_dash_" + (string)row;
   if(ObjectFind(0, nm) < 0) ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, nm, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, nm, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, x0);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, y0 + row * dy);
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, InpDashFontSize);
   ObjectSetString (0, nm, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, nm, OBJPROP_COLOR, col);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetString (0, nm, OBJPROP_TEXT, text);
  }

//+------------------------------------------------------------------+
//| OnCalculate                                                      |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[], const double &high[],
                const double &low[], const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
  {
   int min_bars = InpSwingLen * 2 + InpLegLookback + 5;
   if(rates_total < min_bars) return(0);
   if(prev_calculated > 0 && rates_total == LastCalcBars) return(rates_total);
   LastCalcBars = rates_total;

   if(ArrayResize(O, rates_total) < 0) return(prev_calculated);
   ArrayResize(H, rates_total); ArrayResize(L, rates_total);
   ArrayResize(C, rates_total); ArrayResize(T, rates_total);
   for(int i = 0; i < rates_total; i++)
     { O[i]=open[i]; H[i]=high[i]; L[i]=low[i]; C[i]=close[i]; T[i]=time[i]; }

   ENUM_TIMEFRAMES poiTF = (InpPOITimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpPOITimeframe;
   BuildPOIs(T[0], T[rates_total - 1]);

   ArrayInitialize(BuyBuffer, 0.0);
   ArrayInitialize(SellBuffer, 0.0);
   ObjectsDeleteAll(0, "TR0_");
   ResetSetup(Bull);
   ResetSetup(Bear);

   double offset = InpArrowOffsetPoints * _Point;
   double tol    = InpPOITolerancePoints * _Point;

   //--- MODULE 2: chart-TF left-behind FVGs
   double lastBearTop=0, lastBearBot=0; int lastBearBar=-1;
   double lastBullTop=0, lastBullBot=0; int lastBullBar=-1;

   //--- POI zone cursors
   int    supIdx=-1, resIdx=-1;
   double supTop=0, supBot=0, supTgt=0; bool haveSup=false;
   double resTop=0, resBot=0, resTgt=0; bool haveRes=false;

   bool buyFired=false, sellFired=false;
   int  last_closed = rates_total - 2;

   for(int i = 2; i <= last_closed; i++)
     {
      //=== MODULE 2 — FVG Detector =================================
      if(H[i] < L[i-2]) { lastBearTop=L[i-2]; lastBearBot=H[i]; lastBearBar=i; }
      if(L[i] > H[i-2]) { lastBullTop=L[i];   lastBullBot=H[i-2]; lastBullBar=i; }
      if(lastBearBar>=0 && i>lastBearBar && C[i]>lastBearTop && Bull.stage==ST_IDLE) lastBearBar=-1;
      if(lastBullBar>=0 && i>lastBullBar && C[i]<lastBullBot && Bear.stage==ST_IDLE) lastBullBar=-1;

      //=== MODULE 1 — advance POI zones valid at this bar ==========
      while(supIdx+1 < ArraySize(SupT) && SupT[supIdx+1] <= T[i]) { supIdx++; supTop=SupTop[supIdx]; supBot=SupBot[supIdx]; supTgt=SupTgt[supIdx]; haveSup=true; }
      while(resIdx+1 < ArraySize(ResT) && ResT[resIdx+1] <= T[i]) { resIdx++; resTop=ResTop[resIdx]; resBot=ResBot[resIdx]; resTgt=ResTgt[resIdx]; haveRes=true; }

      //=== BULLISH reversal machine ===============================
      if(Bull.stage==ST_POI   && i-Bull.poiBar   > InpMaxBars) ResetSetup(Bull);
      if(Bull.stage>=ST_SWEPT && i-Bull.sweepBar > InpMaxBars) ResetSetup(Bull);

      if(Bull.stage==ST_IDLE && haveSup)
        {
         bool fvgOk = (lastBearBar>=0 && (i-lastBearBar)<=InpFVGMaxAge && lastBearTop>supTgt);
         if(L[i] <= supTop + tol && fvgOk)
           {
            Bull.stage=ST_POI; Bull.poiBar=i;
            Bull.poiTop=supTop; Bull.poiBot=supBot; Bull.poiTgt=supTgt;
            Bull.refFVGTop=lastBearTop; Bull.refFVGBot=lastBearBot;
           }
        }
      if(Bull.stage==ST_POI && L[i] < Bull.poiTgt)          // MODULE 3 — Sweep
        {
         if(C[i] > Bull.poiTgt)
           { Bull.stage=ST_SWEPT; Bull.sweepBar=i; Bull.cisdLevel=DownLegCISD(i); Bull.obLevel=BullOB(i); Bull.runExtreme=H[i]; }
         else ResetSetup(Bull);
        }
      if(Bull.stage==ST_SWEPT || Bull.stage==ST_IFVG)
         if(H[i] > Bull.runExtreme) Bull.runExtreme = H[i];
      if(Bull.stage==ST_SWEPT && C[i] > Bull.refFVGTop)     // MODULE 4 — iFVG
        { Bull.stage=ST_IFVG; Bull.ifvgLevel=Bull.refFVGTop; }
      if(Bull.stage==ST_IFVG && C[i] > Bull.cisdLevel)      // MODULE 5 — CISD
        { Bull.stage=ST_CISD; Bull.mssLevel=Bull.runExtreme; }
      if(Bull.stage==ST_CISD && C[i] > Bull.mssLevel)       // MODULE 6 — MSS
        {
         BuyBuffer[i] = L[i] - offset;
         int endIdx = MathMin(i + InpLevelExtendBars, rates_total - 1);
         DrawEntrySet((string)(long)T[i] + "_B", Bull, true, endIdx);
         LastBuyTime = T[i]; LastBuyBar = i;
         if(i == last_closed) { buyFired = true; RaiseAlert(true, T[i]); }
         ResetSetup(Bull);
        }

      //=== BEARISH reversal machine ===============================
      if(Bear.stage==ST_POI   && i-Bear.poiBar   > InpMaxBars) ResetSetup(Bear);
      if(Bear.stage>=ST_SWEPT && i-Bear.sweepBar > InpMaxBars) ResetSetup(Bear);

      if(Bear.stage==ST_IDLE && haveRes)
        {
         bool fvgOk = (lastBullBar>=0 && (i-lastBullBar)<=InpFVGMaxAge && lastBullBot<resTgt);
         if(H[i] >= resBot - tol && fvgOk)
           {
            Bear.stage=ST_POI; Bear.poiBar=i;
            Bear.poiTop=resTop; Bear.poiBot=resBot; Bear.poiTgt=resTgt;
            Bear.refFVGTop=lastBullTop; Bear.refFVGBot=lastBullBot;
           }
        }
      if(Bear.stage==ST_POI && H[i] > Bear.poiTgt)
        {
         if(C[i] < Bear.poiTgt)
           { Bear.stage=ST_SWEPT; Bear.sweepBar=i; Bear.cisdLevel=UpLegCISD(i); Bear.obLevel=BearOB(i); Bear.runExtreme=L[i]; }
         else ResetSetup(Bear);
        }
      if(Bear.stage==ST_SWEPT || Bear.stage==ST_IFVG)
         if(L[i] < Bear.runExtreme) Bear.runExtreme = L[i];
      if(Bear.stage==ST_SWEPT && C[i] < Bear.refFVGBot)
        { Bear.stage=ST_IFVG; Bear.ifvgLevel=Bear.refFVGBot; }
      if(Bear.stage==ST_IFVG && C[i] < Bear.cisdLevel)
        { Bear.stage=ST_CISD; Bear.mssLevel=Bear.runExtreme; }
      if(Bear.stage==ST_CISD && C[i] < Bear.mssLevel)
        {
         SellBuffer[i] = H[i] + offset;
         int endIdx = MathMin(i + InpLevelExtendBars, rates_total - 1);
         DrawEntrySet((string)(long)T[i] + "_S", Bear, false, endIdx);
         LastSellTime = T[i]; LastSellBar = i;
         if(i == last_closed) { sellFired = true; RaiseAlert(false, T[i]); }
         ResetSetup(Bear);
        }
     }

   //--- Draw the active POI zone boxes (support + resistance)
   datetime tEnd = T[rates_total - 1];
   if(haveSup) DrawZone("zoneSup", (datetime)(supIdx>=0?SupT[supIdx]:T[0]), tEnd, supTop, supBot, InpPOIColor);
   if(haveRes) DrawZone("zoneRes", (datetime)(resIdx>=0?ResT[resIdx]:T[0]), tEnd, resTop, resBot, InpPOIColor);

   //--- Draw live (forming) setup levels
   DrawLiveSide(Bull, true,  poiTF, rates_total);
   DrawLiveSide(Bear, false, poiTF, rates_total);

   //--- MODULE 8 — Dashboard
   bool inPOIb = haveSup && L[last_closed] <= supTop && H[last_closed] >= supBot;
   bool inPOIs = haveRes && H[last_closed] >= resBot && L[last_closed] <= resTop;
   DrawDashboard(poiTF, haveSup, haveRes, inPOIb, inPOIs,
                 lastBearBar>=0, lastBullBar>=0, buyFired, sellFired, last_closed);

   if(rates_total >= 1) { BuyBuffer[rates_total-1]=0.0; SellBuffer[rates_total-1]=0.0; }
   return(rates_total);
  }

//+------------------------------------------------------------------+
//| Draw a still-forming setup's POI + entry levels                  |
//+------------------------------------------------------------------+
void DrawLiveSide(const Setup &s, const bool is_buy, const ENUM_TIMEFRAMES tf, const int rates_total)
  {
   if(s.stage < ST_POI) return;
   datetime t1 = T[rates_total - 1];
   string p = is_buy ? "liveB_" : "liveS_";
   color mssCol = is_buy ? clrLime : clrOrangeRed;
   DrawZone(p + "poi", T[s.poiBar], t1, s.poiTop, s.poiBot, InpPOIColor);
   if(s.stage >= ST_SWEPT) DrawTaggedLine(p+"E1", "Entry 1: CISD", T[s.sweepBar], t1, s.cisdLevel, clrGold);
   if(s.stage >= ST_SWEPT) DrawTaggedLine(p+"E3", "Entry 3: OB",   T[s.sweepBar], t1, s.obLevel,   clrMediumOrchid);
   if(s.stage >= ST_IFVG)  DrawTaggedLine(p+"E2", "Entry 2: iFVG", T[s.sweepBar], t1, s.ifvgLevel, clrDeepSkyBlue);
   if(s.stage >= ST_CISD)  DrawTaggedLine(p+"MSS","MSS (trigger)", T[s.sweepBar], t1, s.mssLevel,  mssCol);
  }

//+------------------------------------------------------------------+
//| Dashboard renderer                                               |
//+------------------------------------------------------------------+
void DrawDashboard(const ENUM_TIMEFRAMES tf, const bool poiB, const bool poiS,
                   const bool inB, const bool inS, const bool fvgB, const bool fvgS,
                   const bool buyFired, const bool sellFired, const int last_closed)
  {
   if(!InpShowDashboard) return;
   int corner = InpDashCorner, x0 = 12, y0 = 18, dy = InpDashFontSize + 8;
   color tc = InpDashText, hi = clrAqua;

   int bs = Bull.stage, es = Bear.stage;
   string entB = (LastBuyBar  >= 0 && last_closed - LastBuyBar  <= InpMaxBars) ? "1/2/3" : "  -  ";
   string entS = (LastSellBar >= 0 && last_closed - LastSellBar <= InpMaxBars) ? "1/2/3" : "  -  ";
   string sigB = (LastBuyTime  > 0) ? TimeToString(LastBuyTime,  TIME_MINUTES) : "  --  ";
   string sigS = (LastSellTime > 0) ? TimeToString(LastSellTime, TIME_MINUTES) : "  --  ";

   DashLine(0,  "TheReversal R0  ·  POI " + POITypeName(InpPOIType) + " " + TFName(tf), clrWhite, corner, x0, y0, dy);
   DashLine(1,  "status          BULL  BEAR",                                     tc, corner, x0, y0, dy);
   DashLine(2,  "POI Found       " + YN(poiB) + "   " + YN(poiS),                 (poiB||poiS)?hi:tc, corner, x0, y0, dy);
   DashLine(3,  "Price In POI    " + YN(inB)  + "   " + YN(inS),                  (inB||inS)?hi:tc,   corner, x0, y0, dy);
   DashLine(4,  "FVG Created     " + YN(fvgB) + "   " + YN(fvgS),                 (fvgB||fvgS)?hi:tc, corner, x0, y0, dy);
   DashLine(5,  "Liquidity Sweep " + YN(bs>=ST_SWEPT) + "   " + YN(es>=ST_SWEPT), (bs>=ST_SWEPT||es>=ST_SWEPT)?hi:tc, corner, x0, y0, dy);
   DashLine(6,  "iFVG            " + YN(bs>=ST_IFVG)  + "   " + YN(es>=ST_IFVG),  (bs>=ST_IFVG||es>=ST_IFVG)?hi:tc,   corner, x0, y0, dy);
   DashLine(7,  "CISD            " + YN(bs>=ST_CISD)  + "   " + YN(es>=ST_CISD),  (bs>=ST_CISD||es>=ST_CISD)?hi:tc,   corner, x0, y0, dy);
   DashLine(8,  "MSS Confirmed   " + YN(buyFired)     + "   " + YN(sellFired),    (buyFired||sellFired)?clrYellow:tc, corner, x0, y0, dy);
   DashLine(9,  "Entry Level     " + entB + " " + entS,                          tc, corner, x0, y0, dy);
   DashLine(10, "Signal Time     " + sigB + " " + sigS,                          tc, corner, x0, y0, dy);
   DashLine(11, "BULL: " + StageName(bs, buyFired) + "  BEAR: " + StageName(es, sellFired),
                (buyFired?clrLime:(sellFired?clrOrangeRed:tc)), corner, x0, y0, dy);
  }

string StageName(const int stage, const bool fired)
  {
   if(fired) return("ENTRY SIGNAL");
   switch(stage)
     {
      case ST_POI:   return("at POI");
      case ST_SWEPT: return("swept");
      case ST_IFVG:  return("iFVG done");
      case ST_CISD:  return("await MSS");
     }
   return("idle");
  }

//+------------------------------------------------------------------+
//| Alerts                                                           |
//+------------------------------------------------------------------+
void RaiseAlert(const bool is_buy, const datetime bar_time)
  {
   static datetime lastB = 0, lastS = 0;
   if(is_buy)  { if(bar_time == lastB) return; lastB = bar_time; }
   else        { if(bar_time == lastS) return; lastS = bar_time; }
   string dir = is_buy ? "BUY" : "SELL";
   string msg = StringFormat("TheReversal R0: %s %s reversal confirmed (POI+Sweep+iFVG+CISD+MSS)", _Symbol, dir);
   if(InpAlertPopup) Alert(msg);
   if(InpAlertPush)  SendNotification(msg);
   if(InpAlertEmail) SendMail("TheReversal R0 signal", msg);
  }
//+------------------------------------------------------------------+
