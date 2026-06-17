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
input string InpSymbolMapping = "";          // Symbol map: XAUUSD.c=XAUUSDm;EURUSD=EURUSDx

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
   if(content == "__READ_ERROR__")
      return;
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
   int file = FileOpen(InpFileName, FILE_READ | FILE_TXT | FILE_COMMON | FILE_ANSI | FILE_SHARE_WRITE);
   if(file == INVALID_HANDLE)
   {
      return "__READ_ERROR__";
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

   string entries[];
   int eCount = StringSplit(content, ';', entries);
   int sigCount = 0;
   ArrayResize(signals, eCount);

   for(int i = 0; i < eCount; i++)
   {
      string parts[];
      if(StringSplit(entries[i], '|', parts) < 5) continue;

      signals[sigCount].symbol = MapSymbol(StringTrim(parts[0]));
      signals[sigCount].type   = StringTrim(parts[1]);
      signals[sigCount].lots   = StringToDouble(parts[2]);
      signals[sigCount].price  = StringToDouble(parts[3]);
      signals[sigCount].ticket = (long)StringToInteger(parts[4]);
      sigCount++;
   }
   ArrayResize(signals, sigCount);

   Print("[SLAVE] Signals: ", sigCount, " entries");
}

//+------------------------------------------------------------------+
void SyncPositions()
{
   int sigCount = ArraySize(signals);
   bool matched[];
   ArrayResize(matched, sigCount);
   ArrayInitialize(matched, false);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if((int)PositionGetInteger(POSITION_MAGIC) != InpSlaveMagic)
         continue;

      long masterTicket = ExtractMasterTicket(PositionGetString(POSITION_COMMENT));
      int sigIdx = FindMasterTicketIndex(masterTicket, sigCount);
      if(sigIdx >= 0)
      {
         matched[sigIdx] = true;
      }
      else
      {
         ClosePosition(ticket);
      }
   }

   for(int i = 0; i < sigCount; i++)
   {
      if(!matched[i])
      {
         OpenTrade(signals[i]);
      }
   }
}

//+------------------------------------------------------------------+
int FindMasterTicketIndex(long masterTicket, int sigCount)
{
   for(int i = 0; i < sigCount; i++)
   {
      if(signals[i].ticket == masterTicket)
         return i;
   }
   return -1;
}

long ExtractMasterTicket(string comment)
{
   int pos = StringFind(comment, "_");
   if(pos >= 0)
      return StringToInteger(StringSubstr(comment, pos + 1));
   return 0;
}

//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
void OpenTrade(SignalData &sig)
{
   double lots = InpMasterLots ? sig.lots * InpLotMultiplier : InpFixedLots;

   double minLot = SymbolInfoDouble(sig.symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sig.symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(sig.symbol, SYMBOL_VOLUME_STEP);
   lots = MathMax(minLot, MathMin(maxLot, lots));
   if(stepLot > 0) lots = MathRound(lots / stepLot) * stepLot;

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
   req.comment  = InpSlaveComment + "_" + IntegerToString(sig.ticket);

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
string MapSymbol(string sym)
{
   if(InpSymbolMapping == "") return sym;
   string pairs[];
   int pcount = StringSplit(InpSymbolMapping, ';', pairs);
   for(int i = 0; i < pcount; i++)
   {
      string kv[];
      if(StringSplit(pairs[i], '=', kv) == 2)
      {
         if(kv[0] == sym) return kv[1];
      }
   }
   return sym;
}
//+------------------------------------------------------------------+