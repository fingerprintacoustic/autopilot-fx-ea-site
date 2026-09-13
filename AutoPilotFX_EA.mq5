//+------------------------------------------------------------------+
//|                                          AutoPilotFX_EA.mq5      |
//|                        Fingerprint Acoustic Trade                |
//|                                                                    |
//| Strategy: Stop-and-reverse breakout straddle                      |
//| Places a Buy Stop above price and a Sell Stop below price,        |
//| each with tight SL/TP. Whichever order triggers first follows     |
//| the market's move; the opposite pending order is cancelled        |
//| (OCO behaviour). Once the resulting trade closes (SL or TP hit),  |
//| a fresh straddle is placed around the new current price.          |
//| Distance between price and the stop orders is calculated          |
//| dynamically from ATR, so it widens/narrows with volatility.       |
//|                                                                    |
//| SL/TP and straddle distance can be calculated two ways, chosen    |
//| via InpCalcMode:                                                  |
//|   - Fixed Points: SL/TP in points, distance = ATR * multiplier    |
//|     (the original behaviour, unchanged).                          |
//|   - Percentage of Price: SL/TP and distance are each a % of the   |
//|     current price instead of raw points/ATR.                      |
//|                                                                    |
//| Includes an adjustable daily loss limit, and an input-sanity      |
//| check that warns (Alert + log) with reasoning any time a setting  |
//| is changed away from the recommended safe range.                  |
//+------------------------------------------------------------------+
#property copyright "Fingerprint Acoustic Trade"
#property version   "1.21"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

CTrade         trade;
CPositionInfo  positionInfo;
COrderInfo     orderInfo;

//--- SL/TP and straddle-distance calculation mode
enum ENUM_CALC_MODE
{
   CALC_MODE_FIXED_POINTS,  // Fixed Points (SL/TP in points, ATR-based distance)
   CALC_MODE_PERCENT        // Percentage of Price (SL/TP % of entry, % distance)
};

//--- Inputs (all adjustable in MT5 "Inputs" tab)
input group    "=== SL / TP / Distance Calculation Mode ==="
input ENUM_CALC_MODE InpCalcMode = CALC_MODE_FIXED_POINTS; // Fixed Points vs Percentage of Price

input group    "=== ATR / Distance Settings (used when Calc Mode = Fixed Points) ==="
input int      InpATRPeriod        = 14;      // ATR Period
input ENUM_TIMEFRAMES InpATRTimeframe = PERIOD_M15; // ATR Timeframe
input double   InpATRMultiplier    = 1.0;     // Distance = ATR * this multiplier

input group    "=== SL / TP Settings, in points (used when Calc Mode = Fixed Points) ==="
input int      InpSLPoints         = 80;      // Stop Loss in points
input int      InpTPPoints         = 120;     // Take Profit in points

input group    "=== SL / TP / Distance Settings, in % of price (used when Calc Mode = Percentage) ==="
input double   InpSLPercent        = 0.07;    // Stop Loss (% of entry price)
input double   InpTPPercent        = 0.11;    // Take Profit (% of entry price)
input double   InpDistancePercent  = 0.05;    // Straddle distance (% of current price)

input group    "=== Trade Settings ==="
input double   InpLotSize          = 0.01;    // Lot size
input int      InpMagicNumber      = 260826;  // Magic number (unique EA ID)
input int      InpSlippage         = 5;       // Max slippage in points

input group    "=== Safety Filter ==="
input int      InpMaxSpreadPoints  = 200;     // Skip placing orders if spread exceeds this (points)

input group    "=== Straddle Refresh ==="
input int      InpRefreshSeconds   = 30;      // Min seconds between re-placing a stale straddle
input double   InpRepriceATRfactor = 0.5;     // Re-place straddle if price drifts this * ATR from pending price

input group    "=== Daily Loss Limit ==="
input bool     InpUseDailyLossLimit   = true;  // Enable daily loss limit
input bool     InpLimitIsPercent      = true;  // true = % of day-start balance, false = fixed money amount
input double   InpDailyLossPercent    = 3.0;   // Daily loss limit (% of day-start balance) - recommended max 5%
input double   InpDailyLossAmount     = 20.0;  // Daily loss limit (account currency, used if InpLimitIsPercent=false)
input bool     InpCloseOpenOnLimitHit = true;  // Also close any open position when the limit is hit (recommended)

//--- Globals
int      atrHandle;
datetime lastStraddleTime = 0;
ulong    buyStopTicket    = 0;
ulong    sellStopTicket   = 0;

double   dayStartBalance  = 0;
datetime currentDay       = 0;
bool     dailyLimitHit    = false;

//+------------------------------------------------------------------+
//| Recommended safe ranges - used only for the sanity-check warnings |
//+------------------------------------------------------------------+
#define REC_MAX_DAILY_LOSS_PCT   5.0     // beyond this we warn it's risky
#define REC_MIN_DAILY_LOSS_PCT   0.5     // below this the bot may barely trade before halting
#define REC_MAX_LOT              0.10    // warn above this on a small/demo-style account
#define REC_MIN_SL_POINTS        30
#define REC_MAX_SPREAD_POINTS    50      // above this, spread cost eats tight TP quickly
#define REC_MIN_ATR_MULT         0.5
#define REC_MAX_ATR_MULT         3.0
#define REC_MIN_SL_PERCENT       0.03    // % of price - below this, spread/slippage can eat it instantly
#define REC_MAX_SL_PERCENT       1.0     // % of price - above this, a single stop-out costs a lot
#define REC_MIN_DISTANCE_PERCENT 0.02    // % of price - below this, stop orders sit on top of the noise
#define REC_MAX_DISTANCE_PERCENT 0.50    // % of price - above this, the bot may rarely get triggered

//+------------------------------------------------------------------+
//| Check every user-adjustable input against its recommended range   |
//| and Alert + log a warning with the reasoning if it's outside it.  |
//| This runs on every load/recompile, i.e. every time inputs change. |
//+------------------------------------------------------------------+
void RunInputSanityChecks()
{
   string warnings = "";

   // --- SL / TP / distance: checks depend on the active calculation mode ---
   if(InpCalcMode == CALC_MODE_PERCENT)
   {
      if(InpSLPercent < REC_MIN_SL_PERCENT)
         warnings += StringFormat("- Stop Loss (%.3f%%) is very tight for %s. Normal spread/slippage could stop you out instantly.\n", InpSLPercent, _Symbol);
      else if(InpSLPercent > REC_MAX_SL_PERCENT)
         warnings += StringFormat("- Stop Loss (%.3f%%) is unusually wide. A single stop-out would cost a large share of the position's value.\n", InpSLPercent);

      if(InpTPPercent < InpSLPercent)
         warnings += StringFormat("- Take Profit (%.3f%%) is smaller than Stop Loss (%.3f%%). You would need a win rate above 50%% just to break even.\n", InpTPPercent, InpSLPercent);

      if(InpDistancePercent < REC_MIN_DISTANCE_PERCENT)
         warnings += StringFormat("- Straddle distance (%.3f%%) is low: stop orders sit very close to price and may trigger on normal noise, not real breakouts.\n", InpDistancePercent);
      else if(InpDistancePercent > REC_MAX_DISTANCE_PERCENT)
         warnings += StringFormat("- Straddle distance (%.3f%%) is high: stop orders sit far from price, so the bot may rarely enter trades.\n", InpDistancePercent);
   }
   else
   {
      if(InpSLPoints < REC_MIN_SL_POINTS)
         warnings += StringFormat("- Stop Loss (%d pts) is very tight for %s. Normal spread/slippage could stop you out instantly.\n", InpSLPoints, _Symbol);

      if(InpTPPoints < InpSLPoints)
         warnings += StringFormat("- Take Profit (%d) is smaller than Stop Loss (%d). You would need a win rate above 50%% just to break even.\n", InpTPPoints, InpSLPoints);

      // --- ATR multiplier / straddle distance ---
      if(InpATRMultiplier < REC_MIN_ATR_MULT)
         warnings += StringFormat("- ATR multiplier (%.2f) is low: stop orders sit very close to price and may trigger on normal noise, not real breakouts.\n", InpATRMultiplier);
      else if(InpATRMultiplier > REC_MAX_ATR_MULT)
         warnings += StringFormat("- ATR multiplier (%.2f) is high: stop orders sit far from price, so the bot may rarely enter trades.\n", InpATRMultiplier);
   }

   // --- Lot size ---
   if(InpLotSize > REC_MAX_LOT)
      warnings += StringFormat("- Lot size (%.2f) is larger than the recommended starting size (%.2f). On a small account this risks a big % drawdown per trade.\n", InpLotSize, REC_MAX_LOT);

   // --- Spread filter ---
   if(InpMaxSpreadPoints > REC_MAX_SPREAD_POINTS)
      warnings += StringFormat("- Max spread filter (%d pts) is loose. Trades may be allowed during high-spread news spikes, which is dangerous with a tight TP of %d pts.\n", InpMaxSpreadPoints, InpTPPoints);

   // --- Daily loss limit ---
   if(!InpUseDailyLossLimit)
   {
      warnings += "- Daily loss limit is DISABLED. The bot can keep re-entering trades with no cap on how much it loses in a day. Strongly recommended to enable this.\n";
   }
   else
   {
      if(InpLimitIsPercent)
      {
         if(InpDailyLossPercent > REC_MAX_DAILY_LOSS_PCT)
            warnings += StringFormat("- Daily loss limit (%.1f%%) is above the recommended max (%.1f%%). A straddle bot can lose several trades quickly in a choppy market; a high limit lets losses compound before the bot stops itself.\n", InpDailyLossPercent, REC_MAX_DAILY_LOSS_PCT);
         else if(InpDailyLossPercent < REC_MIN_DAILY_LOSS_PCT)
            warnings += StringFormat("- Daily loss limit (%.1f%%) is very low. The bot may halt itself after just one small loss and stop trading for the rest of the day.\n", InpDailyLossPercent);
      }
      else
      {
         if(InpDailyLossAmount <= 0)
            warnings += "- Daily loss limit amount is 0 or negative, which will halt the bot immediately. Set a positive amount.\n";
      }

      if(!InpCloseOpenOnLimitHit)
         warnings += "- 'Close Open On Limit Hit' is OFF: when the daily limit is reached, the bot will stop opening new trades but will leave any currently open position running on its own SL/TP. Turning this ON is recommended so the day's loss is fully capped.\n";
   }

   if(warnings != "")
   {
      string fullMsg = "AutoPilotFX_EA - Input Review\n\nSome of your current settings differ from the recommended safe defaults:\n\n" + warnings + "\nThe bot will still run with these settings - review and adjust in the Inputs tab if needed.";
      Print(fullMsg);
      Alert("AutoPilotFX_EA: some inputs are outside recommended ranges - see Experts/Journal log for details and reasons.");
   }
   else
   {
      Print("AutoPilotFX_EA: all inputs are within recommended ranges.");
   }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   atrHandle = INVALID_HANDLE;
   if(InpCalcMode == CALC_MODE_FIXED_POINTS)
   {
      atrHandle = iATR(_Symbol, InpATRTimeframe, InpATRPeriod);
      if(atrHandle == INVALID_HANDLE)
      {
         Print("Failed to create ATR indicator handle. Error: ", GetLastError());
         return(INIT_FAILED);
      }
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   RunInputSanityChecks();
   InitDailyTracking();

   Print("AutoPilotFX_EA initialized on ", _Symbol);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
   Comment("");
}

//+------------------------------------------------------------------+
//| Reset the day-start balance snapshot for the daily loss limit     |
//+------------------------------------------------------------------+
void InitDailyTracking()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   currentDay      = StructToTime(dt);
   dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyLimitHit   = false;
}

//+------------------------------------------------------------------+
//| Check for a new trading day and reset tracking if so              |
//+------------------------------------------------------------------+
void CheckNewDay()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime today = StructToTime(dt);

   if(today != currentDay)
      InitDailyTracking();
}

//+------------------------------------------------------------------+
//| Returns true if the daily loss limit has been reached              |
//+------------------------------------------------------------------+
bool DailyLossLimitReached()
{
   if(!InpUseDailyLossLimit)
      return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossSoFar = dayStartBalance - equity; // positive number = a loss

   double limitAmount;
   if(InpLimitIsPercent)
      limitAmount = dayStartBalance * (InpDailyLossPercent / 100.0);
   else
      limitAmount = InpDailyLossAmount;

   return (lossSoFar >= limitAmount && limitAmount > 0);
}

//+------------------------------------------------------------------+
//| Close all EA-owned open positions on this symbol                  |
//+------------------------------------------------------------------+
void CloseAllOwnPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(positionInfo.SelectByIndex(i))
      {
         if(positionInfo.Symbol() == _Symbol && positionInfo.Magic() == InpMagicNumber)
            trade.PositionClose(positionInfo.Ticket());
      }
   }
}

//+------------------------------------------------------------------+
//| Get current ATR value                                             |
//+------------------------------------------------------------------+
double GetATR()
{
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(atrHandle, 0, 0, 1, atrBuffer) <= 0)
      return -1;
   return atrBuffer[0];
}

//+------------------------------------------------------------------+
//| Straddle distance (price units) for the active calc mode:         |
//| ATR * multiplier (Fixed Points mode) or % of price (Percent mode) |
//+------------------------------------------------------------------+
double GetStraddleDistance()
{
   if(InpCalcMode == CALC_MODE_PERCENT)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double midPrice = (ask + bid) / 2.0;
      return midPrice * (InpDistancePercent / 100.0);
   }

   double atr = GetATR();
   if(atr <= 0)
      return -1;
   return atr * InpATRMultiplier;
}

//+------------------------------------------------------------------+
//| Count our own open positions on this symbol                       |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(positionInfo.SelectByIndex(i))
      {
         if(positionInfo.Symbol() == _Symbol && positionInfo.Magic() == InpMagicNumber)
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find our pending orders (buy stop / sell stop) on this symbol     |
//+------------------------------------------------------------------+
void FindPendingOrders(ulong &buyTicket, ulong &sellTicket)
{
   buyTicket  = 0;
   sellTicket = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(orderInfo.SelectByIndex(i))
      {
         if(orderInfo.Symbol() != _Symbol || orderInfo.Magic() != InpMagicNumber)
            continue;

         if(orderInfo.OrderType() == ORDER_TYPE_BUY_STOP)
            buyTicket = orderInfo.Ticket();
         else if(orderInfo.OrderType() == ORDER_TYPE_SELL_STOP)
            sellTicket = orderInfo.Ticket();
      }
   }
}

//+------------------------------------------------------------------+
//| Delete every pending order this EA owns on this symbol - scans    |
//| the full order list rather than two tracked tickets, so it        |
//| self-heals if a past delete silently failed and left duplicates.  |
//+------------------------------------------------------------------+
void DeleteAllOwnPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(orderInfo.SelectByIndex(i))
      {
         if(orderInfo.Symbol() == _Symbol && orderInfo.Magic() == InpMagicNumber)
            trade.OrderDelete(orderInfo.Ticket());
      }
   }
   buyStopTicket  = 0;
   sellStopTicket = 0;
}

//+------------------------------------------------------------------+
//| Check current spread against max allowed                          |
//+------------------------------------------------------------------+
bool SpreadOK()
{
   long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spreadPoints <= InpMaxSpreadPoints);
}

//+------------------------------------------------------------------+
//| Place a fresh Buy Stop + Sell Stop straddle around current price  |
//+------------------------------------------------------------------+
void PlaceStraddle()
{
   double distance = GetStraddleDistance();
   if(distance <= 0)
   {
      Print("Invalid distance value, skipping straddle placement.");
      return;
   }

   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   int stopLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = stopLevel * point;
   if(distance < minDistance)
      distance = minDistance + point * 5; // small buffer

   double buyStopPrice  = NormalizeDouble(ask + distance, digits);
   double sellStopPrice = NormalizeDouble(bid - distance, digits);

   double buySL, buyTP, sellSL, sellTP;
   if(InpCalcMode == CALC_MODE_PERCENT)
   {
      buySL  = NormalizeDouble(buyStopPrice  * (1.0 - InpSLPercent / 100.0), digits);
      buyTP  = NormalizeDouble(buyStopPrice  * (1.0 + InpTPPercent / 100.0), digits);
      sellSL = NormalizeDouble(sellStopPrice * (1.0 + InpSLPercent / 100.0), digits);
      sellTP = NormalizeDouble(sellStopPrice * (1.0 - InpTPPercent / 100.0), digits);
   }
   else
   {
      buySL  = NormalizeDouble(buyStopPrice  - InpSLPoints * point, digits);
      buyTP  = NormalizeDouble(buyStopPrice  + InpTPPoints * point, digits);
      sellSL = NormalizeDouble(sellStopPrice + InpSLPoints * point, digits);
      sellTP = NormalizeDouble(sellStopPrice - InpTPPoints * point, digits);
   }

   if(trade.BuyStop(InpLotSize, buyStopPrice, _Symbol, buySL, buyTP, ORDER_TIME_GTC, 0, "AutoPilotFX Buy"))
      buyStopTicket = trade.ResultOrder();
   else
      Print("BuyStop failed: ", trade.ResultRetcodeDescription());

   if(trade.SellStop(InpLotSize, sellStopPrice, _Symbol, sellSL, sellTP, ORDER_TIME_GTC, 0, "AutoPilotFX Sell"))
      sellStopTicket = trade.ResultOrder();
   else
      Print("SellStop failed: ", trade.ResultRetcodeDescription());

   lastStraddleTime = TimeCurrent();
}

//+------------------------------------------------------------------+
//| Update the on-chart status comment                                 |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossSoFar = dayStartBalance - equity;
   double limitAmount = InpLimitIsPercent ? dayStartBalance * (InpDailyLossPercent / 100.0) : InpDailyLossAmount;

   string status = dailyLimitHit ? "HALTED - daily loss limit reached" : "Running";
   string mode   = (InpCalcMode == CALC_MODE_PERCENT) ? "Percentage of Price" : "Fixed Points (ATR distance)";

   string txt = StringFormat(
      "AutoPilotFX_EA | %s\nStatus: %s\nMode: %s\nDay-start balance: %.2f\nP/L today: %.2f\nDaily loss limit: %.2f (%s)",
      _Symbol, status, mode, dayStartBalance, -lossSoFar,
      limitAmount, InpUseDailyLossLimit ? "enabled" : "disabled");

   Comment(txt);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   CheckNewDay();

   // --- Daily loss limit check runs first, every tick ---
   if(InpUseDailyLossLimit && !dailyLimitHit && DailyLossLimitReached())
   {
      dailyLimitHit = true;
      DeleteAllOwnPendingOrders();
      if(InpCloseOpenOnLimitHit)
         CloseAllOwnPositions();

      string msg = StringFormat("AutoPilotFX_EA: Daily loss limit reached on %s. Bot halted for the rest of the day.", _Symbol);
      Print(msg);
      Alert(msg);
   }

   UpdateDashboard();

   if(dailyLimitHit)
      return; // no new trades until tomorrow

   // 1. If we have an open position, let SL/TP manage it and make sure
   //    the opposite pending order (if somehow still alive) is cancelled.
   if(HasOpenPosition())
   {
      DeleteAllOwnPendingOrders();
      return;
   }

   // 2. No open position -> make sure we have a straddle working.
   FindPendingOrders(buyStopTicket, sellStopTicket);

   bool haveBoth = (buyStopTicket != 0 && sellStopTicket != 0);

   if(!haveBoth)
   {
      // Clean up any orphaned single-sided order (or duplicates from a
      // previously failed delete), then place a fresh straddle
      DeleteAllOwnPendingOrders();

      if(!SpreadOK())
         return; // wait for spread to normalize

      PlaceStraddle();
      return;
   }

   // 3. We have both pending orders -> check if price has drifted far
   //    enough from them that we should re-center the straddle.
   if(TimeCurrent() - lastStraddleTime < InpRefreshSeconds)
      return;

   double distance = GetStraddleDistance();
   if(distance <= 0) return;

   if(orderInfo.Select(buyStopTicket))
   {
      double buyPrice = orderInfo.PriceOpen();
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(MathAbs(buyPrice - ask) > distance * InpRepriceATRfactor)
      {
         DeleteAllOwnPendingOrders();
         if(SpreadOK())
            PlaceStraddle();
      }
   }
}
//+------------------------------------------------------------------+
