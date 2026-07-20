//+------------------------------------------------------------------+
//|                                                         VWAP.mq5  |
//|                       Volume Weighted Average Price (VWAP)        |
//|                                                                  |
//|  Session/period-anchored VWAP with optional standard-deviation   |
//|  bands. Designed to be usable in discretionary trading and as a  |
//|  building block for automated strategies (via iCustom).          |
//+------------------------------------------------------------------+
#property copyright "Indicator"
#property version   "1.00"
#property description "Volume Weighted Average Price with anchoring and standard deviation bands."

#property indicator_chart_window
#property indicator_buffers 8
#property indicator_plots   5

//--- Plot 0: VWAP line
#property indicator_label1  "VWAP"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrDodgerBlue
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

//--- Plot 1: Upper band 1
#property indicator_label2  "VWAP +1SD"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrOrange
#property indicator_style2  STYLE_DOT
#property indicator_width2  1

//--- Plot 2: Lower band 1
#property indicator_label3  "VWAP -1SD"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrOrange
#property indicator_style3  STYLE_DOT
#property indicator_width3  1

//--- Plot 3: Upper band 2
#property indicator_label4  "VWAP +2SD"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrTomato
#property indicator_style4  STYLE_DOT
#property indicator_width4  1

//--- Plot 4: Lower band 2
#property indicator_label5  "VWAP -2SD"
#property indicator_type5   DRAW_LINE
#property indicator_color5  clrTomato
#property indicator_style5  STYLE_DOT
#property indicator_width5  1

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_VWAP_ANCHOR
  {
   ANCHOR_SESSION,   // Reset every trading day (session)
   ANCHOR_WEEK,      // Reset every week
   ANCHOR_MONTH,     // Reset every month
   ANCHOR_CONTINUOUS // Never reset (rolling from first bar)
  };

enum ENUM_VWAP_PRICE
  {
   VWAP_PRICE_TYPICAL, // Typical (H+L+C)/3
   VWAP_PRICE_CLOSE,   // Close
   VWAP_PRICE_HLC,     // Weighted (H+L+C+C)/4
   VWAP_PRICE_OHLC     // Average (O+H+L+C)/4
  };

enum ENUM_VWAP_VOLUME
  {
   VWAP_VOL_TICK, // Tick volume
   VWAP_VOL_REAL  // Real volume (if available from broker)
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input ENUM_VWAP_ANCHOR InpAnchor      = ANCHOR_SESSION;      // Anchor / reset period
input ENUM_VWAP_PRICE  InpPriceType   = VWAP_PRICE_TYPICAL;  // Price source
input ENUM_VWAP_VOLUME InpVolumeType   = VWAP_VOL_TICK;      // Volume source
input bool             InpShowBands   = true;                // Show standard deviation bands
input double           InpBand1Mult   = 1.0;                 // Band 1 multiplier (SD)
input double           InpBand2Mult   = 2.0;                 // Band 2 multiplier (SD)

//+------------------------------------------------------------------+
//| Buffers                                                          |
//+------------------------------------------------------------------+
double VwapBuffer[];       // Plot 0
double UpperBand1Buffer[]; // Plot 1
double LowerBand1Buffer[]; // Plot 2
double UpperBand2Buffer[]; // Plot 3
double LowerBand2Buffer[]; // Plot 4

//--- Calculation buffers (not plotted)
double CumPVBuffer[];      // Cumulative price*volume
double CumVBuffer[];       // Cumulative volume
double CumPV2Buffer[];     // Cumulative price^2 * volume (for variance)

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, VwapBuffer,       INDICATOR_DATA);
   SetIndexBuffer(1, UpperBand1Buffer, INDICATOR_DATA);
   SetIndexBuffer(2, LowerBand1Buffer, INDICATOR_DATA);
   SetIndexBuffer(3, UpperBand2Buffer, INDICATOR_DATA);
   SetIndexBuffer(4, LowerBand2Buffer, INDICATOR_DATA);
   SetIndexBuffer(5, CumPVBuffer,      INDICATOR_CALCULATIONS);
   SetIndexBuffer(6, CumVBuffer,       INDICATOR_CALCULATIONS);
   SetIndexBuffer(7, CumPV2Buffer,     INDICATOR_CALCULATIONS);

//--- Draw as left-to-right (time series indexing is default in OnCalculate arrays)
   for(int i = 0; i < 5; i++)
      PlotIndexSetDouble(i, PLOT_EMPTY_VALUE, 0.0);

//--- Hide bands if disabled
   int band_draw = InpShowBands ? DRAW_LINE : DRAW_NONE;
   PlotIndexSetInteger(1, PLOT_DRAW_TYPE, band_draw);
   PlotIndexSetInteger(2, PLOT_DRAW_TYPE, band_draw);
   PlotIndexSetInteger(3, PLOT_DRAW_TYPE, band_draw);
   PlotIndexSetInteger(4, PLOT_DRAW_TYPE, band_draw);

   IndicatorSetString(INDICATOR_SHORTNAME, "VWAP");
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Select the price source for a bar                                |
//+------------------------------------------------------------------+
double GetPrice(const int i,
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[])
  {
   switch(InpPriceType)
     {
      case VWAP_PRICE_CLOSE:
         return(close[i]);
      case VWAP_PRICE_HLC:
         return((high[i] + low[i] + close[i] + close[i]) / 4.0);
      case VWAP_PRICE_OHLC:
         return((open[i] + high[i] + low[i] + close[i]) / 4.0);
      case VWAP_PRICE_TYPICAL:
      default:
         return((high[i] + low[i] + close[i]) / 3.0);
     }
  }

//+------------------------------------------------------------------+
//| Decide whether bar i starts a new anchor period                  |
//+------------------------------------------------------------------+
bool IsNewPeriod(const int i, const datetime &time[])
  {
   if(i == 0)
      return(true);

   MqlDateTime cur, prev;
   TimeToStruct(time[i],   cur);
   TimeToStruct(time[i-1], prev);

   switch(InpAnchor)
     {
      case ANCHOR_CONTINUOUS:
         return(false);

      case ANCHOR_WEEK:
         // New week when current day-of-week is <= previous (wrapped) or gap >= 7 days
         if(cur.day_of_week < prev.day_of_week)
            return(true);
         return((time[i] - time[i-1]) >= 7 * 24 * 3600);

      case ANCHOR_MONTH:
         return(cur.mon != prev.mon || cur.year != prev.year);

      case ANCHOR_SESSION:
      default:
         return(cur.day != prev.day || cur.mon != prev.mon || cur.year != prev.year);
     }
  }

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
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
   if(rates_total < 2)
      return(0);

//--- Determine the starting index. We recompute from the beginning of the
//--- current anchor period to keep cumulative sums correct.
   int start = prev_calculated - 1;
   if(start < 0)
      start = 0;

//--- Walk back to the start of the anchor period that contains 'start'
   while(start > 0 && !IsNewPeriod(start, time))
      start--;

   for(int i = start; i < rates_total; i++)
     {
      double price = GetPrice(i, open, high, low, close);
      double vol   = (InpVolumeType == VWAP_VOL_REAL)
                     ? (double)volume[i]
                     : (double)tick_volume[i];

      //--- Guard against zero volume bars (weekends/illiquid)
      if(vol <= 0.0)
         vol = 1.0;

      double pv  = price * vol;
      double pv2 = price * price * vol;

      if(i == 0 || IsNewPeriod(i, time))
        {
         CumPVBuffer[i]  = pv;
         CumVBuffer[i]   = vol;
         CumPV2Buffer[i] = pv2;
        }
      else
        {
         CumPVBuffer[i]  = CumPVBuffer[i-1]  + pv;
         CumVBuffer[i]   = CumVBuffer[i-1]   + vol;
         CumPV2Buffer[i] = CumPV2Buffer[i-1] + pv2;
        }

      double cumV = CumVBuffer[i];
      double vwap = (cumV > 0.0) ? CumPVBuffer[i] / cumV : price;
      VwapBuffer[i] = vwap;

      //--- Volume-weighted variance: E[p^2] - (E[p])^2
      double meanP2 = (cumV > 0.0) ? CumPV2Buffer[i] / cumV : price * price;
      double variance = meanP2 - vwap * vwap;
      if(variance < 0.0)
         variance = 0.0;              // numerical safety
      double sd = MathSqrt(variance);

      if(InpShowBands)
        {
         UpperBand1Buffer[i] = vwap + InpBand1Mult * sd;
         LowerBand1Buffer[i] = vwap - InpBand1Mult * sd;
         UpperBand2Buffer[i] = vwap + InpBand2Mult * sd;
         LowerBand2Buffer[i] = vwap - InpBand2Mult * sd;
        }
      else
        {
         UpperBand1Buffer[i] = vwap;
         LowerBand1Buffer[i] = vwap;
         UpperBand2Buffer[i] = vwap;
         LowerBand2Buffer[i] = vwap;
        }
     }

   return(rates_total);
  }
//+------------------------------------------------------------------+
