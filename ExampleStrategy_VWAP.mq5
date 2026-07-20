//+------------------------------------------------------------------+
//|                                        ExampleStrategy_VWAP.mq5   |
//|            Example EA: VWAP mean-reversion with SD bands          |
//|                                                                  |
//|  Demonstrates how to consume the VWAP.ex5 indicator via iCustom  |
//|  and turn its buffers into trade signals. This is a template /   |
//|  starting point, NOT a turnkey profitable system. Test on a      |
//|  demo account and optimise before any live use.                  |
//+------------------------------------------------------------------+
#property copyright "Indicator"
#property version   "1.00"
#property description "VWAP mean-reversion example strategy (uses VWAP.ex5 via iCustom)."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input double   InpLots        = 0.10;   // Fixed lot size
input int      InpStopPoints  = 400;    // Stop loss (points, 0 = off)
input int      InpTakePoints  = 400;    // Take profit (points, 0 = off)
input ulong    InpMagic       = 20260720; // Magic number
input bool     InpUseTrendFilter = true; // Only trade back toward VWAP

//--- VWAP indicator parameters (must match VWAP.mq5 input order)
input int      InpVwapAnchor  = 0;      // 0=Session 1=Week 2=Month 3=Continuous
input int      InpVwapPrice   = 0;      // 0=Typical 1=Close 2=HLC 3=OHLC
input int      InpVwapVolume  = 0;      // 0=Tick 1=Real
input double   InpBand1Mult   = 1.0;    // Band 1 SD multiplier
input double   InpBand2Mult   = 2.0;    // Band 2 SD multiplier

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
int    g_vwap_handle = INVALID_HANDLE;
CTrade g_trade;

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_vwap_handle = iCustom(_Symbol, _Period, "VWAP",
                           InpVwapAnchor,
                           InpVwapPrice,
                           InpVwapVolume,
                           true,          // show bands (needed for buffers 1-4)
                           InpBand1Mult,
                           InpBand2Mult);

   if(g_vwap_handle == INVALID_HANDLE)
     {
      Print("Failed to create VWAP indicator handle. Is VWAP.ex5 compiled in MQL5/Indicators?");
      return(INIT_FAILED);
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Deinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_vwap_handle != INVALID_HANDLE)
      IndicatorRelease(g_vwap_handle);
  }

//+------------------------------------------------------------------+
//| Is there already a position from this EA on this symbol?         |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)InpMagic)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| New bar detection                                                |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   static datetime last_time = 0;
   datetime t = iTime(_Symbol, _Period, 0);
   if(t != last_time)
     {
      last_time = t;
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Tick handler                                                     |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!IsNewBar())
      return;
   if(HasOpenPosition())
      return;

//--- Read VWAP buffers on the last closed bar (index 1)
   double vwap[2], up2[2], lo2[2];
   if(CopyBuffer(g_vwap_handle, 0, 0, 2, vwap) < 2) return;  // VWAP
   if(CopyBuffer(g_vwap_handle, 3, 0, 2, up2)  < 2) return;  // +2SD
   if(CopyBuffer(g_vwap_handle, 4, 0, 2, lo2)  < 2) return;  // -2SD

   double last_close = iClose(_Symbol, _Period, 1);
   double vwap_v = vwap[1];
   double upper  = up2[1];
   double lower  = lo2[1];

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

//--- Mean-reversion logic:
//    Price closed below -2SD -> expect reversion up -> BUY
//    Price closed above +2SD -> expect reversion down -> SELL
   bool buy_signal  = (last_close < lower);
   bool sell_signal = (last_close > upper);

//--- Optional trend filter: only trade toward the VWAP mean
   if(InpUseTrendFilter)
     {
      if(buy_signal  && last_close >= vwap_v) buy_signal  = false;
      if(sell_signal && last_close <= vwap_v) sell_signal = false;
     }

   if(buy_signal)
     {
      double sl = (InpStopPoints > 0) ? ask - InpStopPoints * point : 0.0;
      double tp = (InpTakePoints > 0) ? ask + InpTakePoints * point : vwap_v;
      g_trade.Buy(InpLots, _Symbol, ask, sl, tp, "VWAP revert buy");
     }
   else if(sell_signal)
     {
      double sl = (InpStopPoints > 0) ? bid + InpStopPoints * point : 0.0;
      double tp = (InpTakePoints > 0) ? bid - InpTakePoints * point : vwap_v;
      g_trade.Sell(InpLots, _Symbol, bid, sl, tp, "VWAP revert sell");
     }
  }
//+------------------------------------------------------------------+
