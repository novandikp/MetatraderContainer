//+------------------------------------------------------------------+
//| Expert Advisor SLAVE - Execute MultiSignal from Master           |
//+------------------------------------------------------------------+
#property strict
#property description "EA SLAVE - Execute signals from Master EA"
#property copyright "Copyright 2025"
#property version   "1.0"

input string InpFileName     = "MultiSignal.txt";
input bool   InpMasterLots   = true;       // Follow master's lot size
input double InpFixedLots    = 0.01;        // Fixed lot (if InpMasterLots=false)
input double InpLotMultiplier = 1.0;        // Multiplier for master lot
input int    InpSlaveMagic   = 2025;        // Magic number for slave trades
input int    InpSlippage     = 30;           // Slippage in points
input string InpSlaveComment = "SlaveEA";    // Order comment

struct SignalData
{
   string symbol;
   string type;
   double lots;
   double price;
   long   ticket;
};

SignalData signals[];
string lastFileContent = "";

//+------------------------------------------------------------------+
int OnInit()
{
   string filePath = TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "\\Files\\" + InpFileName;
   Print("==============================================");
   Print("✅ EA Slave v1.0 Started");
   Print("📂 Reading: ", filePath);
   Print("🔢 Magic: ", InpSlaveMagic);
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   string content = ReadSignalFile();
   if(content == lastFileContent)
      return;
   lastFileContent = content;

   if(content == "" || content == "no signal")
   {
      Print("[SLAVE] No signal — closing all");
      CloseAllSlavePositions();
      return;
   }

   ParseSignals(content);
   SyncPositions();
}

//+------------------------------------------------------------------+
string ReadSignalFile()
{
   int file = FileOpen(InpFileName, FILE_READ | FILE_TXT | FILE_COMMON | FILE_ANSI);
   if(file == INVALID_HANDLE)
   {
      return "";
   }

   string content = "";
   while(!FileIsEnding(file))
   {
      content += FileReadString(file);
   }
   FileClose(file);

   return StringTrim(content);
}

//+------------------------------------------------------------------+
void ParseSignals(string content)
{
   ArrayFree(signals);

   if(content == "" || content == "no signal")
      return;

   string parts[];
   int count = StringSplit(content, '|', parts);
   int signalCount = count / 5;
   ArrayResize(signals, signalCount);

   for(int i = 0; i < signalCount; i++)
   {
      int idx = i * 5;
      signals[i].symbol = StringTrim(parts[idx]);
      signals[i].type   = StringTrim(parts[idx + 1]);
      signals[i].lots   = StringToDouble(parts[idx + 2]);
      signals[i].price  = StringToDouble(parts[idx + 3]);
      signals[i].ticket = (long)StringToInteger(parts[idx + 4]);
   }

   Print("[SLAVE] Signals: ", ArraySize(signals), " entries");
}

//+------------------------------------------------------------------+
void SyncPositions()
{
   // Open missing signals
   for(int i = 0; i < ArraySize(signals); i++)
   {
      if(!HasMatchingPosition(signals[i]))
      {
         OpenTrade(signals[i]);
      }
   }

   // Close slave positions not in signal
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if((int)PositionGetInteger(POSITION_MAGIC) != InpSlaveMagic)
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      int type = (int)PositionGetInteger(POSITION_TYPE);
      string typeStr = (type == POSITION_TYPE_BUY) ? "BUY" : "SELL";

      if(!SignalExists(sym, typeStr))
      {
         ClosePosition(ticket);
      }
   }
}

//+------------------------------------------------------------------+
bool HasMatchingPosition(SignalData &sig)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if((int)PositionGetInteger(POSITION_MAGIC) != InpSlaveMagic)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != sig.symbol)
         continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
      string typeStr = (type == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      if(typeStr == sig.type)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool SignalExists(string symbol, string type)
{
   for(int i = 0; i < ArraySize(signals); i++)
   {
      if(signals[i].symbol == symbol && signals[i].type == type)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void OpenTrade(SignalData &sig)
{
   double lots = InpMasterLots ? sig.lots * InpLotMultiplier : InpFixedLots;

   double minLot = SymbolInfoDouble(sig.symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sig.symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(sig.symbol, SYMBOL_VOLUME_STEP);
   lots = MathMax(minLot, MathMin(maxLot, lots));
   lots = MathRound(lots / stepLot) * stepLot;

   int type = (sig.type == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(sig.symbol, SYMBOL_ASK)
                                            : SymbolInfoDouble(sig.symbol, SYMBOL_BID);

   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action   = TRADE_ACTION_DEAL;
   req.symbol   = sig.symbol;
   req.volume   = lots;
   req.type     = (ENUM_ORDER_TYPE)type;
   req.price    = price;
   req.deviation = InpSlippage;
   req.magic    = InpSlaveMagic;
   req.comment  = InpSlaveComment;

   if(!OrderSend(req, res))
   {
      Print("[SLAVE] ❌ Open ", sig.symbol, " ", sig.type, " fail: ", res.retcode);
   }
   else
   {
      Print("[SLAVE] ✅ Open ", sig.symbol, " ", sig.type, " ", lots, " @ ", price);
   }
}

//+------------------------------------------------------------------+
void ClosePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return;

   string symbol = PositionGetString(POSITION_SYMBOL);
   int type = (int)PositionGetInteger(POSITION_TYPE);
   double volume = PositionGetDouble(POSITION_VOLUME);

   int closeType = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   double price = (closeType == ORDER_TYPE_SELL) ? SymbolInfoDouble(symbol, SYMBOL_BID)
                                                  : SymbolInfoDouble(symbol, SYMBOL_ASK);

   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action   = TRADE_ACTION_DEAL;
   req.symbol   = symbol;
   req.volume   = volume;
   req.type     = (ENUM_ORDER_TYPE)closeType;
   req.price    = price;
   req.deviation = InpSlippage;
   req.magic    = InpSlaveMagic;
   req.position = ticket;

   if(!OrderSend(req, res))
   {
      Print("[SLAVE] ❌ Close ", symbol, " fail: ", res.retcode);
   }
   else
   {
      Print("[SLAVE] ✅ Close ", symbol);
   }
}

//+------------------------------------------------------------------+
void CloseAllSlavePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if((int)PositionGetInteger(POSITION_MAGIC) != InpSlaveMagic)
         continue;

      ClosePosition(ticket);
   }
}

//+------------------------------------------------------------------+
string StringTrim(string text)
{
   StringTrimLeft(text);
   StringTrimRight(text);
   return text;
}
//+------------------------------------------------------------------+