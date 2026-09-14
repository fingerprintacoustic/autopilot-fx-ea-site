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
//| SL/TP and straddle distance can be calculated three ways, chosen  |
//| via InpCalcMode:                                                  |
//|   - Fixed Points: SL/TP in points, distance = ATR * multiplier    |
//|     (the original behaviour, unchanged).                          |
//|   - Percentage of Price: SL/TP and distance are each a % of the   |
//|     current price instead of raw points/ATR.                      |
//|   - Auto / ATR-Relative: SL, TP, and distance are all multiples   |
//|     of the instrument's own live ATR, and the spread filter       |
//|     compares live spread to live ATR too - so nothing is a fixed  |
//|     number that a given instrument might outgrow. This is the     |
//|     only mode that re-calibrates itself continuously rather than  |
//|     using a value chosen once at setup time.                      |
//|                                                                    |
//| For anyone who doesn't want to tune the above by hand, InpPreset  |
//| offers ready-made bundles - Auto (default, works on anything),    |
//| Forex, Crypto, Metals & Indices - pick one and every detailed     |
//| setting below is configured for you. Leave it on Custom to        |
//| control every value yourself.                                     |
//|                                                                    |
//| Optional chop/trend filter (InpUseChopFilter, off by default):    |
//| pauses placing a NEW straddle whenever live ADX reads below       |
//| InpMinADX, i.e. the market looks like it's ranging rather than    |
//| trending - the condition a breakout straddle tends to whipsaw     |
//| and lose repeatedly in. It never touches a trade that's already   |
//| open; it only delays arming a fresh, unfilled straddle.           |
//|                                                                    |
//| Includes an adjustable daily loss limit, and an input-sanity      |
//| check that warns (Alert + log) with reasoning any time a setting  |
//| is changed away from the recommended safe range.                  |
//+------------------------------------------------------------------+
#property copyright "Fingerprint Acoustic Trade"
#property version   "1.50"
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
   CALC_MODE_PERCENT,       // Percentage of Price (SL/TP % of entry, % distance)
   CALC_MODE_ATR_RELATIVE   // Auto / ATR-Relative (SL, TP, and distance are all ATR multiples)
};

//--- Ready-made setting bundles for people who don't want to tune inputs by hand
enum ENUM_QUICK_PRESET
{
   PRESET_AUTO,          // Auto - Any Instrument (self-calibrates from live ATR & spread, no hand-picked numbers)
   PRESET_CUSTOM,        // Custom - use every detailed setting below
   PRESET_FOREX,         // Forex pairs (e.g. EURUSD, GBPUSD, AUDJPY)
   PRESET_CRYPTO,        // Crypto pairs (e.g. BTCUSD, ETHUSD)
   PRESET_METALS_INDEX   // Metals / Indices (e.g. XAUUSD, US30)
};

//--- Inputs (all adjustable in MT5 "Inputs" tab)
input group    "=== Quick Setup (recommended - overrides the detailed settings below unless Custom) ==="
input ENUM_QUICK_PRESET InpPreset = PRESET_AUTO; // What are you trading? (Auto works on anything; pick a specific preset or Custom to set values yourself)

input group    "=== SL / TP / Distance Calculation Mode (ignored unless Quick Setup = Custom) ==="
input ENUM_CALC_MODE InpCalcMode = CALC_MODE_FIXED_POINTS; // Fixed Points / Percentage of Price / Auto (ATR-Relative)

input group    "=== ATR / Distance Settings (used when Calc Mode = Fixed Points or Auto) ==="
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

input group    "=== SL / TP Settings, as ATR multiples (used when Calc Mode = Auto/ATR-Relative) ==="
input double   InpSLATRMultiplier      = 0.9;  // Stop Loss = ATR * this
input double   InpTPATRMultiplier      = 1.5;  // Take Profit = ATR * this
input double   InpMaxSpreadATRFactor   = 0.25; // Skip placing orders if spread exceeds ATR * this

input group    "=== Trade Settings ==="
input double   InpLotSize          = 0.01;    // Lot size
input int      InpMagicNumber      = 260826;  // Magic number (unique EA ID)
input int      InpSlippage         = 5;       // Max slippage in points

input group    "=== Safety Filter, points-based (ignored unless Quick Setup = Custom, Calc Mode != Auto) ==="
input int      InpMaxSpreadPoints  = 200;     // Skip placing orders if spread exceeds this (points)

input group    "=== Straddle Refresh ==="
input int      InpRefreshSeconds   = 30;      // Min seconds between re-placing a stale straddle
input double   InpRepriceATRfactor = 0.5;     // Re-place straddle if price drifts this * ATR from pending price

input group    "=== Chop / Trend Filter (optional - pauses new straddles in a non-trending market) ==="
input bool     InpUseChopFilter    = false;   // Enable ADX trend filter
input int      InpADXPeriod        = 14;      // ADX period
input ENUM_TIMEFRAMES InpADXTimeframe = PERIOD_M15; // ADX timeframe
input double   InpMinADX           = 20.0;    // Minimum ADX to allow a new straddle (below this = treated as ranging/chop)

input group    "=== Daily Loss Limit ==="
input bool     InpUseDailyLossLimit   = true;  // Enable daily loss limit
input bool     InpLimitIsPercent      = true;  // true = % of day-start balance, false = fixed money amount
input double   InpDailyLossPercent    = 3.0;   // Daily loss limit (% of day-start balance) - recommended max 5%
input double   InpDailyLossAmount     = 20.0;  // Daily loss limit (account currency, used if InpLimitIsPercent=false)
input bool     InpCloseOpenOnLimitHit = true;  // Also close any open position when the limit is hit (recommended)

//--- Globals
int      atrHandle;
int      adxHandle = INVALID_HANDLE;
datetime lastStraddleTime = 0;
ulong    buyStopTicket    = 0;
ulong    sellStopTicket   = 0;

double   dayStartBalance  = 0;
datetime currentDay       = 0;
bool     dailyLimitHit    = false;

datetime lastAlgoDisabledAlertTime = 0;

//--- Effective settings actually used by the EA: either the raw inputs
//    (Quick Setup = Custom) or values overridden by the chosen preset.
//    Populated once in OnInit() by ApplyPreset().
ENUM_CALC_MODE effCalcMode;
double         effSLPercent;
double         effTPPercent;
double         effDistancePercent;
int            effSLPoints;
int            effTPPoints;
double         effATRMultiplier;
int            effMaxSpreadPoints;
double         effSLATRMult;
double         effTPATRMult;
double         effMaxSpreadATRFactor;

//+------------------------------------------------------------------+
//| Resolve the effective settings from InpPreset. Custom passes the  |
//| detailed inputs through unchanged; any other preset overrides     |
//| calc mode, SL/TP/distance, and the spread filter with values      |
//| suited to that instrument class, so nothing needs hand-tuning.    |
//+------------------------------------------------------------------+
void ApplyPreset()
{
   switch(InpPreset)
   {
      case PRESET_AUTO:
         effCalcMode           = CALC_MODE_ATR_RELATIVE;
         effATRMultiplier      = 1.0;
         effSLATRMult          = 0.9;
         effTPATRMult          = 1.5;
         effMaxSpreadATRFactor = 0.25;
         Print("AutoPilotFX_EA: Quick Setup = Auto preset (ATR-relative: distance ATR x1.0, SL ATR x0.9, TP ATR x1.5, max spread = ATR x0.25). Scales itself to this instrument's own live volatility and spread - works on forex, crypto, metals, or indices without needing to pick one. Set InpPreset to Custom to override.");
         break;

      case PRESET_FOREX:
         effCalcMode        = CALC_MODE_FIXED_POINTS;
         effATRMultiplier   = 1.0;
         effSLPoints        = 80;
         effTPPoints        = 120;
         effMaxSpreadPoints = 200;
         Print("AutoPilotFX_EA: Quick Setup = Forex preset (Fixed Points, ATR x1.0, SL 80pts, TP 120pts, max spread 200pts). Set InpPreset to Custom to override.");
         break;

      case PRESET_CRYPTO:
         effCalcMode        = CALC_MODE_PERCENT;
         effSLPercent       = 1.5;
         effTPPercent       = 2.5;
         effDistancePercent = 1.0;
         effMaxSpreadPoints = 3000;
         Print("AutoPilotFX_EA: Quick Setup = Crypto preset (Percentage of Price, SL 1.5%, TP 2.5%, distance 1.0%, max spread 3000pts). Set InpPreset to Custom to override.");
         break;

      case PRESET_METALS_INDEX:
         effCalcMode        = CALC_MODE_PERCENT;
         effSLPercent       = 0.5;
         effTPPercent       = 0.8;
         effDistancePercent = 0.3;
         effMaxSpreadPoints = 500;
         Print("AutoPilotFX_EA: Quick Setup = Metals/Index preset (Percentage of Price, SL 0.5%, TP 0.8%, distance 0.3%, max spread 500pts). Set InpPreset to Custom to override.");
         break;

      default: // PRESET_CUSTOM
         effCalcMode           = InpCalcMode;
         effSLPercent          = InpSLPercent;
         effTPPercent          = InpTPPercent;
         effDistancePercent    = InpDistancePercent;
         effSLPoints           = InpSLPoints;
         effTPPoints           = InpTPPoints;
         effATRMultiplier      = InpATRMultiplier;
         effMaxSpreadPoints    = InpMaxSpreadPoints;
         effSLATRMult          = InpSLATRMultiplier;
         effTPATRMult          = InpTPATRMultiplier;
         effMaxSpreadATRFactor = InpMaxSpreadATRFactor;
         break;
   }
}

//+------------------------------------------------------------------+
//| Alert (throttled to once a minute) that orders are being rejected |
//| because algo trading is off somewhere - this used to only show up |
//| as a buried log line, which is easy to miss.                      |
//+------------------------------------------------------------------+
void AlertAlgoTradingDisabled()
{
   if(TimeCurrent() - lastAlgoDisabledAlertTime < 60)
      return;
   lastAlgoDisabledAlertTime = TimeCurrent();
   Alert("AutoPilotFX_EA: Orders are being rejected because Algo Trading is OFF. Click the 'Algo Trading' button in MT5's top toolbar, AND make sure 'Allow Algo Trading' is ticked in this EA's Common settings tab - both are required.");
}

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
#define REC_MIN_SL_ATRMULT       0.3     // ATR multiple - below this, normal noise can stop you out instantly
#define REC_MAX_SL_ATRMULT       2.0     // ATR multiple - above this, a single stop-out costs a lot
#define REC_MIN_SPREAD_ATRFACTOR 0.05    // below this, the spread filter blocks almost every trade
#define REC_MAX_SPREAD_ATRFACTOR 1.0     // above this, spread can eat most of a stop before it even fills
#define REC_MIN_ADX_THRESHOLD    10.0    // below this, the chop filter barely filters anything
#define REC_MAX_ADX_THRESHOLD    40.0    // above this, the chop filter may block almost all trading

//+------------------------------------------------------------------+
//| Check every user-adjustable input against its recommended range   |
//| and Alert + log a warning with the reasoning if it's outside it.  |
//| This runs on every load/recompile, i.e. every time inputs change. |
//+------------------------------------------------------------------+
void RunInputSanityChecks()
{
   string warnings = "";

   if(InpPreset != PRESET_CUSTOM)
   {
      Print("AutoPilotFX_EA: Quick Setup preset is active, so the detailed SL/TP/distance/spread inputs below are ignored - see the preset summary printed above. Set InpPreset to Custom to review those instead.");
   }
   else
   {
      // --- SL / TP / distance: checks depend on the active calculation mode ---
      if(effCalcMode == CALC_MODE_PERCENT)
      {
         if(effSLPercent < REC_MIN_SL_PERCENT)
            warnings += StringFormat("- Stop Loss (%.3f%%) is very tight for %s. Normal spread/slippage could stop you out instantly.\n", effSLPercent, _Symbol);
         else if(effSLPercent > REC_MAX_SL_PERCENT)
            warnings += StringFormat("- Stop Loss (%.3f%%) is unusually wide. A single stop-out would cost a large share of the position's value.\n", effSLPercent);

         if(effTPPercent < effSLPercent)
            warnings += StringFormat("- Take Profit (%.3f%%) is smaller than Stop Loss (%.3f%%). You would need a win rate above 50%% just to break even.\n", effTPPercent, effSLPercent);

         if(effDistancePercent < REC_MIN_DISTANCE_PERCENT)
            warnings += StringFormat("- Straddle distance (%.3f%%) is low: stop orders sit very close to price and may trigger on normal noise, not real breakouts.\n", effDistancePercent);
         else if(effDistancePercent > REC_MAX_DISTANCE_PERCENT)
            warnings += StringFormat("- Straddle distance (%.3f%%) is high: stop orders sit far from price, so the bot may rarely enter trades.\n", effDistancePercent);
      }
      else if(effCalcMode == CALC_MODE_ATR_RELATIVE)
      {
         if(effSLATRMult < REC_MIN_SL_ATRMULT)
            warnings += StringFormat("- Stop Loss (ATR x%.2f) is very tight for %s. Normal spread/slippage could stop you out instantly.\n", effSLATRMult, _Symbol);
         else if(effSLATRMult > REC_MAX_SL_ATRMULT)
            warnings += StringFormat("- Stop Loss (ATR x%.2f) is unusually wide. A single stop-out would cost a large share of the position's value.\n", effSLATRMult);

         if(effTPATRMult < effSLATRMult)
            warnings += StringFormat("- Take Profit (ATR x%.2f) is smaller than Stop Loss (ATR x%.2f). You would need a win rate above 50%% just to break even.\n", effTPATRMult, effSLATRMult);

         if(effATRMultiplier < REC_MIN_ATR_MULT)
            warnings += StringFormat("- Distance ATR multiplier (%.2f) is low: stop orders sit very close to price and may trigger on normal noise, not real breakouts.\n", effATRMultiplier);
         else if(effATRMultiplier > REC_MAX_ATR_MULT)
            warnings += StringFormat("- Distance ATR multiplier (%.2f) is high: stop orders sit far from price, so the bot may rarely enter trades.\n", effATRMultiplier);

         if(effMaxSpreadATRFactor < REC_MIN_SPREAD_ATRFACTOR)
            warnings += StringFormat("- Max spread filter (ATR x%.2f) is very tight: it may block trading almost all the time on an instrument with a naturally wider spread.\n", effMaxSpreadATRFactor);
         else if(effMaxSpreadATRFactor > REC_MAX_SPREAD_ATRFACTOR)
            warnings += StringFormat("- Max spread filter (ATR x%.2f) is loose: spread could eat most of a stop before the trade even fills.\n", effMaxSpreadATRFactor);
      }
      else
      {
         if(effSLPoints < REC_MIN_SL_POINTS)
            warnings += StringFormat("- Stop Loss (%d pts) is very tight for %s. Normal spread/slippage could stop you out instantly.\n", effSLPoints, _Symbol);

         if(effTPPoints < effSLPoints)
            warnings += StringFormat("- Take Profit (%d) is smaller than Stop Loss (%d). You would need a win rate above 50%% just to break even.\n", effTPPoints, effSLPoints);

         // --- ATR multiplier / straddle distance ---
         if(effATRMultiplier < REC_MIN_ATR_MULT)
            warnings += StringFormat("- ATR multiplier (%.2f) is low: stop orders sit very close to price and may trigger on normal noise, not real breakouts.\n", effATRMultiplier);
         else if(effATRMultiplier > REC_MAX_ATR_MULT)
            warnings += StringFormat("- ATR multiplier (%.2f) is high: stop orders sit far from price, so the bot may rarely enter trades.\n", effATRMultiplier);
      }

      // --- Spread filter (points-based modes only - Auto's spread filter was already checked above) ---
      if(effCalcMode != CALC_MODE_ATR_RELATIVE && effMaxSpreadPoints > REC_MAX_SPREAD_POINTS)
      {
         if(effCalcMode == CALC_MODE_PERCENT)
            warnings += StringFormat("- Max spread filter (%d pts) is loose. Trades may be allowed during high-spread news spikes, which is dangerous with a tight TP of %.3f%%.\n", effMaxSpreadPoints, effTPPercent);
         else
            warnings += StringFormat("- Max spread filter (%d pts) is loose. Trades may be allowed during high-spread news spikes, which is dangerous with a tight TP of %d pts.\n", effMaxSpreadPoints, effTPPoints);
      }
   }

   // --- Lot size ---
   if(InpLotSize > REC_MAX_LOT)
      warnings += StringFormat("- Lot size (%.2f) is larger than the recommended starting size (%.2f). On a small account this risks a big % drawdown per trade.\n", InpLotSize, REC_MAX_LOT);

   // --- Chop/trend filter (not preset-controlled, so always checked) ---
   if(InpUseChopFilter)
   {
      if(InpMinADX < REC_MIN_ADX_THRESHOLD)
         warnings += StringFormat("- Chop filter's minimum ADX (%.1f) is very low: it will barely filter anything, so it may not help against whipsaws.\n", InpMinADX);
      else if(InpMinADX > REC_MAX_ADX_THRESHOLD)
         warnings += StringFormat("- Chop filter's minimum ADX (%.1f) is very high: it may block trading almost all the time, even in reasonably trending conditions.\n", InpMinADX);
   }

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
   ApplyPreset();

   atrHandle = INVALID_HANDLE;
   if(effCalcMode != CALC_MODE_PERCENT) // Fixed Points and Auto/ATR-Relative both need ATR
   {
      atrHandle = iATR(_Symbol, InpATRTimeframe, InpATRPeriod);
      if(atrHandle == INVALID_HANDLE)
      {
         Print("Failed to create ATR indicator handle. Error: ", GetLastError());
         return(INIT_FAILED);
      }
   }

   adxHandle = INVALID_HANDLE;
   if(InpUseChopFilter)
   {
      adxHandle = iADX(_Symbol, InpADXTimeframe, InpADXPeriod);
      if(adxHandle == INVALID_HANDLE)
         Print("Failed to create ADX indicator handle. Error: ", GetLastError(), " - chop filter will be treated as pass-through until this resolves.");
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
   if(adxHandle != INVALID_HANDLE)
      IndicatorRelease(adxHandle);
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
//| Get current ADX main-line value (trend strength, 0-100)           |
//+------------------------------------------------------------------+
double GetADX()
{
   double adxBuffer[];
   ArraySetAsSeries(adxBuffer, true);
   if(CopyBuffer(adxHandle, 0, 0, 1, adxBuffer) <= 0)
      return -1;
   return adxBuffer[0];
}

//+------------------------------------------------------------------+
//| Chop/trend filter: true = OK to place a new straddle. Skips only  |
//| when InpUseChopFilter is on and live ADX reads below InpMinADX -  |
//| a low ADX means the market isn't trending, which is exactly when  |
//| a breakout straddle tends to whipsaw and lose repeatedly. Any     |
//| failure to read ADX (filter off, or handle/data unavailable) is   |
//| treated as pass-through rather than blocking trading outright.    |
//+------------------------------------------------------------------+
bool ChopFilterOK()
{
   if(!InpUseChopFilter)
      return true;
   if(adxHandle == INVALID_HANDLE)
      return true;

   double adx = GetADX();
   if(adx <= 0)
      return true; // can't read it yet (e.g. not enough history) - don't block on that alone

   return (adx >= InpMinADX);
}

//+------------------------------------------------------------------+
//| Straddle distance (price units) for the active calc mode:         |
//| ATR * multiplier (Fixed Points mode) or % of price (Percent mode) |
//+------------------------------------------------------------------+
double GetStraddleDistance()
{
   if(effCalcMode == CALC_MODE_PERCENT)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double midPrice = (ask + bid) / 2.0;
      return midPrice * (effDistancePercent / 100.0);
   }

   double atr = GetATR();
   if(atr <= 0)
      return -1;
   return atr * effATRMultiplier;
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
   if(effCalcMode == CALC_MODE_ATR_RELATIVE)
   {
      double atr = GetATR();
      if(atr <= 0)
         return false; // can't judge the spread against volatility we can't read - stay safe and skip

      double point       = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      long   spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      double spreadPrice  = spreadPoints * point;
      return (spreadPrice <= atr * effMaxSpreadATRFactor);
   }

   long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spreadPoints <= effMaxSpreadPoints);
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
   if(effCalcMode == CALC_MODE_PERCENT)
   {
      buySL  = NormalizeDouble(buyStopPrice  * (1.0 - effSLPercent / 100.0), digits);
      buyTP  = NormalizeDouble(buyStopPrice  * (1.0 + effTPPercent / 100.0), digits);
      sellSL = NormalizeDouble(sellStopPrice * (1.0 + effSLPercent / 100.0), digits);
      sellTP = NormalizeDouble(sellStopPrice * (1.0 - effTPPercent / 100.0), digits);
   }
   else if(effCalcMode == CALC_MODE_ATR_RELATIVE)
   {
      double atr = GetATR();
      if(atr <= 0)
      {
         Print("Invalid ATR value, skipping straddle placement.");
         return;
      }
      double slDist = atr * effSLATRMult;
      double tpDist = atr * effTPATRMult;
      buySL  = NormalizeDouble(buyStopPrice  - slDist, digits);
      buyTP  = NormalizeDouble(buyStopPrice  + tpDist, digits);
      sellSL = NormalizeDouble(sellStopPrice + slDist, digits);
      sellTP = NormalizeDouble(sellStopPrice - tpDist, digits);
   }
   else // CALC_MODE_FIXED_POINTS
   {
      buySL  = NormalizeDouble(buyStopPrice  - effSLPoints * point, digits);
      buyTP  = NormalizeDouble(buyStopPrice  + effTPPoints * point, digits);
      sellSL = NormalizeDouble(sellStopPrice + effSLPoints * point, digits);
      sellTP = NormalizeDouble(sellStopPrice - effTPPoints * point, digits);
   }

   if(trade.BuyStop(InpLotSize, buyStopPrice, _Symbol, buySL, buyTP, ORDER_TIME_GTC, 0, "AutoPilotFX Buy"))
      buyStopTicket = trade.ResultOrder();
   else
   {
      Print("BuyStop failed: ", trade.ResultRetcodeDescription());
      if(trade.ResultRetcode() == TRADE_RETCODE_CLIENT_DISABLES_AT)
         AlertAlgoTradingDisabled();
   }

   if(trade.SellStop(InpLotSize, sellStopPrice, _Symbol, sellSL, sellTP, ORDER_TIME_GTC, 0, "AutoPilotFX Sell"))
      sellStopTicket = trade.ResultOrder();
   else
   {
      Print("SellStop failed: ", trade.ResultRetcodeDescription());
      if(trade.ResultRetcode() == TRADE_RETCODE_CLIENT_DISABLES_AT)
         AlertAlgoTradingDisabled();
   }

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
   string mode;
   switch(effCalcMode)
   {
      case CALC_MODE_PERCENT:      mode = "Percentage of Price";        break;
      case CALC_MODE_ATR_RELATIVE: mode = "Auto (ATR-relative)";        break;
      default:                     mode = "Fixed Points (ATR distance)"; break;
   }
   string preset;
   switch(InpPreset)
   {
      case PRESET_AUTO:          preset = "Auto";            break;
      case PRESET_FOREX:         preset = "Forex";           break;
      case PRESET_CRYPTO:        preset = "Crypto";          break;
      case PRESET_METALS_INDEX:  preset = "Metals/Index";    break;
      default:                   preset = "Custom";          break;
   }

   string chopLine = "";
   if(InpUseChopFilter)
   {
      double adx = (adxHandle != INVALID_HANDLE) ? GetADX() : -1;
      string chopState = (adx <= 0) ? "reading..." : (adx >= InpMinADX ? "trending - OK" : "ranging - paused");
      chopLine = (adx <= 0)
         ? StringFormat("\nChop filter: %s (min ADX %.1f)", chopState, InpMinADX)
         : StringFormat("\nChop filter: ADX %.1f, min %.1f - %s", adx, InpMinADX, chopState);
   }

   string txt = StringFormat(
      "AutoPilotFX_EA | %s\nStatus: %s\nPreset: %s | Mode: %s%s\nDay-start balance: %.2f\nP/L today: %.2f\nDaily loss limit: %.2f (%s)",
      _Symbol, status, preset, mode, chopLine, dayStartBalance, -lossSoFar,
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

      if(!ChopFilterOK())
         return; // market not trending enough right now - wait rather than risk a whipsaw

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
         if(SpreadOK() && ChopFilterOK())
            PlaceStraddle();
      }
   }
}
//+------------------------------------------------------------------+
