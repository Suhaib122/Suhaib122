//+------------------------------------------------------------------+
//| NORO_AI_GOLD_SCALPER.mq5                                         |
//| Multi-signal XAUUSD M5 scalper for MT5 (Hedging accounts)        |
//| Risk-first implementation; no daily profit/loss stop.            |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "NORO AI GOLD SCALPER EA - XAUUSD M5"
#property description "EMA/RSI/MACD/ATR + candle confirmation + dynamic trailing"

#include <Trade/Trade.mqh>
CTrade trade;

//------------------------------ Inputs ------------------------------
input ulong  InpMagic                  = 17112026;
input ENUM_TIMEFRAMES InpSignalTF      = PERIOD_M5;
input bool   InpOnlyGoldSymbols        = true;
input double InpRiskPerTradePct        = 0.25;
input double InpMaxAggregateRiskPct    = 2.00;
input int    InpMaxOpenPositions       = 10;
input int    InpMaxPositionsPerSide    = 10;
input int    InpTargetTradesPerDay     = 100;     // Operational reference only; never forces entries
input int    InpMaxSpreadPoints        = 80;
input int    InpMinATRPoints           = 20;
input int    InpMaxATRPoints           = 2000;
input int    InpStopLossPoints         = 350;
input int    InpTrailStartPoints       = 150;
input int    InpTrailDistancePoints    = 100;
input int    InpTrailStepPoints        = 20;
input int    InpSlippagePoints         = 30;
input int    InpFastEMA                = 9;
input int    InpMediumEMA              = 21;
input int    InpSlowEMA                = 50;
input int    InpRSIPeriod              = 14;
input double InpBuyRSIMin              = 52.0;
input double InpSellRSIMax             = 48.0;
input int    InpMACDFast               = 12;
input int    InpMACDSlow               = 26;
input int    InpMACDSignal             = 9;
input int    InpATRPeriod              = 14;
input double InpMinSignalScore         = 6.0;     // out of 7
input bool   InpUseSessionFilter       = false;
input int    InpSessionStartHour       = 6;       // server time
input int    InpSessionEndHour         = 22;      // server time
input bool   InpUseCalendarNewsFilter  = false;   // MT5 calendar availability/broker dependent
input int    InpNewsMinutesBefore      = 20;
input int    InpNewsMinutesAfter       = 20;
input string InpNewsCurrency           = "USD";
input bool   InpShowDashboard          = true;
input bool   InpCloseOnlyThisEA        = true;

//------------------------------ Globals -----------------------------
int hFast=INVALID_HANDLE, hMedium=INVALID_HANDLE, hSlow=INVALID_HANDLE;
int hRSI=INVALID_HANDLE, hMACD=INVALID_HANDLE, hATR=INVALID_HANDLE;
bool g_enabled=true, g_panelVisible=true;
datetime g_lastBar=0;
datetime g_lastEntryBar=0;
string PREFIX="NORO_AI_";
string g_status="INITIALIZING";
double g_peakEquity=0.0, g_maxDD=0.0;
int g_todayEntries=0;
datetime g_dayStart=0;
double g_dayProfit=0,g_dayLoss=0,g_dayNet=0;
int g_win=0,g_loss=0;
double g_avgWin=0,g_avgLoss=0,g_profitFactor=0;
string g_trend="NEUTRAL", g_rsiState="--",g_macdState="--",g_filterState="--";

//------------------------------ Helpers -----------------------------
double Pt(){ return SymbolInfoDouble(_Symbol,SYMBOL_POINT); }
int Dig(){ return (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS); }
double NPrice(double p){ return NormalizeDouble(p,Dig()); }
bool IsOurPosition()
{
   if(PositionGetString(POSITION_SYMBOL)!=_Symbol) return false;
   if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic) return false;
   return true;
}
int CountPositions(int side=-1)
{
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t) || !IsOurPosition()) continue;
      long type=PositionGetInteger(POSITION_TYPE);
      if(side==-1 || (side==0 && type==POSITION_TYPE_BUY) ||
         (side==1 && type==POSITION_TYPE_SELL)) n++;
   }
   return n;
}
double TotalLots()
{
   double v=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t) || !IsOurPosition()) continue;
      v+=PositionGetDouble(POSITION_VOLUME);
   }
   return v;
}
double CurrentSpreadPoints()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || Pt()<=0) return 1e9;
   return (tick.ask-tick.bid)/Pt();
}
bool IsGoldSymbol()
{
   string s=_Symbol;
   StringToUpper(s);
   return (StringFind(s,"XAU")>=0 || StringFind(s,"GOLD")>=0);
}
datetime StartOfDay(datetime t)
{
   MqlDateTime x; TimeToStruct(t,x);
   x.hour=0; x.min=0; x.sec=0;
   return StructToTime(x);
}
bool NewBar()
{
   datetime t=iTime(_Symbol,InpSignalTF,0);
   if(t<=0) return false;
   if(t!=g_lastBar){ g_lastBar=t; return true; }
   return false;
}
bool ReadBuffer(int handle,int buffer,int shift,double &value)
{
   double a[1];
   if(handle==INVALID_HANDLE || CopyBuffer(handle,buffer,shift,1,a)!=1) return false;
   value=a[0]; return MathIsValidNumber(value);
}
bool ReadIndicators(int shift,double &e9,double &e21,double &e50,double &rsi,
                    double &macd,double &signal,double &atr)
{
   return ReadBuffer(hFast,0,shift,e9) && ReadBuffer(hMedium,0,shift,e21) &&
          ReadBuffer(hSlow,0,shift,e50) && ReadBuffer(hRSI,0,shift,rsi) &&
          ReadBuffer(hMACD,0,shift,macd) && ReadBuffer(hMACD,1,shift,signal) &&
          ReadBuffer(hATR,0,shift,atr);
}
bool BullishCandle(int shift)
{
   double o=iOpen(_Symbol,InpSignalTF,shift), c=iClose(_Symbol,InpSignalTF,shift);
   double h=iHigh(_Symbol,InpSignalTF,shift), l=iLow(_Symbol,InpSignalTF,shift);
   if(h<=l || c<=o) return false;
   double body=c-o, range=h-l;
   return (body/range>=0.45 && c>(h+l)/2.0);
}
bool BearishCandle(int shift)
{
   double o=iOpen(_Symbol,InpSignalTF,shift), c=iClose(_Symbol,InpSignalTF,shift);
   double h=iHigh(_Symbol,InpSignalTF,shift), l=iLow(_Symbol,InpSignalTF,shift);
   if(h<=l || c>=o) return false;
   double body=o-c, range=h-l;
   return (body/range>=0.45 && c<(h+l)/2.0);
}
bool BullishPriceAction(int shift)
{
   double close1=iClose(_Symbol,InpSignalTF,shift);
   double high2=iHigh(_Symbol,InpSignalTF,shift+1);
   double close2=iClose(_Symbol,InpSignalTF,shift+1);
   return BullishCandle(shift) && (close1>high2 || close1>close2);
}
bool BearishPriceAction(int shift)
{
   double close1=iClose(_Symbol,InpSignalTF,shift);
   double low2=iLow(_Symbol,InpSignalTF,shift+1);
   double close2=iClose(_Symbol,InpSignalTF,shift+1);
   return BearishCandle(shift) && (close1<low2 || close1<close2);
}
bool SessionAllowed()
{
   if(!InpUseSessionFilter) return true;
   MqlDateTime x; TimeToStruct(TimeTradeServer(),x);
   if(InpSessionStartHour<=InpSessionEndHour)
      return (x.hour>=InpSessionStartHour && x.hour<InpSessionEndHour);
   return (x.hour>=InpSessionStartHour || x.hour<InpSessionEndHour);
}
bool CalendarNewsBlocked()
{
   if(!InpUseCalendarNewsFilter) return false;
   // Economic calendar times are broker/server-calendar dependent.
   // Fail closed if enabled but no usable calendar query is available.
   datetime now=TimeTradeServer();
   MqlCalendarValue values[];
   datetime from=now-InpNewsMinutesAfter*60;
   datetime to=now+InpNewsMinutesBefore*60;
   int count=CalendarValueHistory(values,from,to,NULL,InpNewsCurrency);
   if(count<0) return true;
   for(int i=0;i<count;i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id,ev)) continue;
      if(ev.importance==CALENDAR_IMPORTANCE_HIGH) return true;
   }
   return false;
}
bool MarketFiltersOK(double atr)
{
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) {g_filterState="NO CONNECTION"; return false;}
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {g_filterState="TRADING DISABLED"; return false;}
   if(CurrentSpreadPoints()>InpMaxSpreadPoints) {g_filterState="SPREAD"; return false;}
   double atrPts=atr/Pt();
   if(atrPts<InpMinATRPoints || atrPts>InpMaxATRPoints) {g_filterState="ATR"; return false;}
   if(!SessionAllowed()) {g_filterState="SESSION"; return false;}
   if(CalendarNewsBlocked()) {g_filterState="HIGH IMPACT NEWS"; return false;}
   g_filterState="OK"; return true;
}
double NormalizeVolume(double lots)
{
   double minv=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxv=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0) return 0;
   lots=MathMax(minv,MathMin(maxv,lots));
   lots=MathFloor(lots/step+1e-8)*step;
   int vd=2;
   if(step<0.01) vd=3;
   if(step<0.001) vd=4;
   return NormalizeDouble(lots,vd);
}
double RiskMoneyForPosition(double volume,double openPrice,double stopPrice)
{
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue<=0) tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   if(tickSize<=0 || tickValue<=0) return DBL_MAX;
   return MathAbs(openPrice-stopPrice)/tickSize*tickValue*volume;
}
double AggregateOpenRiskMoney()
{
   double risk=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t) || !IsOurPosition()) continue;
      double sl=PositionGetDouble(POSITION_SL);
      if(sl<=0) return DBL_MAX; // no SL => unknown/unacceptable aggregate risk
      risk+=RiskMoneyForPosition(PositionGetDouble(POSITION_VOLUME),
              PositionGetDouble(POSITION_PRICE_OPEN),sl);
   }
   return risk;
}
double CalculateLots(ENUM_ORDER_TYPE type,double entry,double sl)
{
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double riskCash=equity*InpRiskPerTradePct/100.0;
   double riskPerLot=RiskMoneyForPosition(1.0,entry,sl);
   if(riskPerLot<=0 || riskPerLot==DBL_MAX) return 0;
   double lots=NormalizeVolume(riskCash/riskPerLot);
   double minv=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   // Never round up above risk allocation. If min lot breaches budget, skip.
   if(lots<minv || RiskMoneyForPosition(lots,entry,sl)>riskCash*1.001) return 0;
   double maxTotal=equity*InpMaxAggregateRiskPct/100.0;
   if(AggregateOpenRiskMoney()+RiskMoneyForPosition(lots,entry,sl)>maxTotal) return 0;
   double margin=0;
   if(!OrderCalcMargin(type,_Symbol,lots,entry,margin)) return 0;
   if(margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE)) return 0;
   return lots;
}
bool ValidInitialSL(ENUM_ORDER_TYPE type,double entry,double &sl)
{
   double point=Pt();
   long stops=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   int dist=MathMax(InpStopLossPoints,(int)stops+2);
   if(type==ORDER_TYPE_BUY) sl=entry-dist*point;
   else sl=entry+dist*point;
   sl=NPrice(sl);
   return (sl>0);
}
bool OpenTrade(ENUM_ORDER_TYPE type)
{
   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return false;
   double entry=(type==ORDER_TYPE_BUY?tick.ask:tick.bid);
   double sl=0; if(!ValidInitialSL(type,entry,sl)) return false;
   double lots=CalculateLots(type,entry,sl);
   if(lots<=0) return false;
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   bool ok=false;
   if(type==ORDER_TYPE_BUY) ok=trade.Buy(lots,_Symbol,0,sl,0,"NORO AI BUY");
   else ok=trade.Sell(lots,_Symbol,0,sl,0,"NORO AI SELL");
   if(!ok)
      Print("NORO entry failed: ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
   else
   {
      g_todayEntries++;
      g_lastEntryBar=iTime(_Symbol,InpSignalTF,0);
   }
   return ok;
}
void ManageTrailing()
{
   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;
   double point=Pt();
   long stops=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long freeze=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist=(MathMax(stops,freeze)+2)*point;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t) || !IsOurPosition()) continue;
      long type=PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double oldSL=PositionGetDouble(POSITION_SL);
      double profitPts=(type==POSITION_TYPE_BUY?(tick.bid-open):(open-tick.ask))/point;
      if(profitPts<InpTrailStartPoints) continue;
      double proposed=(type==POSITION_TYPE_BUY?
                       tick.bid-InpTrailDistancePoints*point:
                       tick.ask+InpTrailDistancePoints*point);
      if(type==POSITION_TYPE_BUY)
      {
         proposed=MathMin(proposed,tick.bid-minDist);
         proposed=NPrice(proposed);
         if(oldSL>0 && proposed<=oldSL+InpTrailStepPoints*point) continue;
         if(proposed>=tick.bid-minDist+point) continue;
      }
      else
      {
         proposed=MathMax(proposed,tick.ask+minDist);
         proposed=NPrice(proposed);
         if(oldSL>0 && proposed>=oldSL-InpTrailStepPoints*point) continue;
         if(proposed<=tick.ask+minDist-point) continue;
      }
      trade.SetExpertMagicNumber(InpMagic);
      if(!trade.PositionModify(t,proposed,PositionGetDouble(POSITION_TP)))
         Print("Trailing modify failed ticket=",t," code=",trade.ResultRetcode(),
               " ",trade.ResultRetcodeDescription()," (existing SL retained)");
   }
}
void CloseAllOurPositions()
{
   trade.SetExpertMagicNumber(InpMagic);
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t) || !IsOurPosition()) continue;
      if(!trade.PositionClose(t))
         Print("Close failed ticket=",t," ",trade.ResultRetcodeDescription());
   }
}
void CalculateStatistics()
{
   datetime now=TimeTradeServer();
   g_dayStart=StartOfDay(now);
   g_dayProfit=0; g_dayLoss=0; g_dayNet=0;
   g_win=0; g_loss=0; g_avgWin=0; g_avgLoss=0; g_profitFactor=0;
   double wins=0,losses=0,closedWin=0,closedLoss=0;
   if(!HistorySelect(g_dayStart,now)) return;
   int deals=HistoryDealsTotal();
   g_todayEntries=0;
   for(int i=0;i<deals;i++)
   {
      ulong d=HistoryDealGetTicket(i);
      if(d==0) continue;
      if(HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol ||
         (ulong)HistoryDealGetInteger(d,DEAL_MAGIC)!=InpMagic) continue;
      long entry=HistoryDealGetInteger(d,DEAL_ENTRY);
      double net=HistoryDealGetDouble(d,DEAL_PROFIT)+
                 HistoryDealGetDouble(d,DEAL_SWAP)+
                 HistoryDealGetDouble(d,DEAL_COMMISSION)+
                 HistoryDealGetDouble(d,DEAL_FEE);
      if(entry==DEAL_ENTRY_IN || entry==DEAL_ENTRY_INOUT) g_todayEntries++;
      if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY || entry==DEAL_ENTRY_INOUT)
      {
         g_dayNet+=net;
         if(net>0){g_dayProfit+=net;wins+=net;g_win++;closedWin+=net;}
         if(net<0){g_dayLoss+=MathAbs(net);losses+=MathAbs(net);g_loss++;closedLoss+=MathAbs(net);}
      }
   }
   if(g_win>0) g_avgWin=closedWin/g_win;
   if(g_loss>0) g_avgLoss=closedLoss/g_loss;
   if(losses>0) g_profitFactor=wins/losses;
   else if(wins>0) g_profitFactor=999;
}
double WinRate(){ int n=g_win+g_loss; return n>0?100.0*g_win/n:0; }
string Money(double v){ return DoubleToString(v,2); }
void SetLabel(string name,string text,int x,int y,color clr,int size=9)
{
   string id=PREFIX+name;
   if(ObjectFind(0,id)<0) ObjectCreate(0,id,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,id,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,id,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,id,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,id,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,id,OBJPROP_FONTSIZE,size);
   ObjectSetString(0,id,OBJPROP_FONT,"Arial");
   ObjectSetString(0,id,OBJPROP_TEXT,text);
}
void MakeButton(string name,string caption,int x,int y,int w,int h)
{
   string id=PREFIX+name;
   if(ObjectFind(0,id)<0) ObjectCreate(0,id,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,id,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,id,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,id,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,id,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,id,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,id,OBJPROP_BGCOLOR,clrMidnightBlue);
   ObjectSetInteger(0,id,OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(0,id,OBJPROP_BORDER_COLOR,clrSlateGray);
   ObjectSetInteger(0,id,OBJPROP_FONTSIZE,8);
   ObjectSetString(0,id,OBJPROP_TEXT,caption);
}
void CreateDashboard()
{
   if(!InpShowDashboard) return;
   g_panelVisible=true;
   string bg=PREFIX+"BG";
   if(ObjectFind(0,bg)<0) ObjectCreate(0,bg,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,bg,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,bg,OBJPROP_XDISTANCE,10);
   ObjectSetInteger(0,bg,OBJPROP_YDISTANCE,20);
   ObjectSetInteger(0,bg,OBJPROP_XSIZE,300);
   ObjectSetInteger(0,bg,OBJPROP_YSIZE,390);
   ObjectSetInteger(0,bg,OBJPROP_BGCOLOR,C'14,20,32');
   ObjectSetInteger(0,bg,OBJPROP_COLOR,clrSlateGray);
   ObjectSetInteger(0,bg,OBJPROP_BACK,false);
   MakeButton("TOGGLE","PAUSE / RESUME",20,390,130,22);
   MakeButton("CLOSE","CLOSE EA TRADES",160,390,140,22);
   MakeButton("HIDE","HIDE PANEL",20,416,130,22);
}
void DeleteDashboard()
{
   for(int i=ObjectsTotal(0)-1;i>=0;i--)
   {
      string n=ObjectName(0,i);
      if(StringFind(n,PREFIX)==0) ObjectDelete(0,n);
   }
}
void UpdateDashboard()
{
   if(!g_panelVisible || !InpShowDashboard) return;
   CalculateStatistics();
   double e9,e21,e50,rsi,macd,sig,atr;
   if(ReadIndicators(1,e9,e21,e50,rsi,macd,sig,atr))
   {
      g_trend=(e9>e21 && e21>e50?"BUY":(e9<e21 && e21<e50?"SELL":"NEUTRAL"));
      g_rsiState=DoubleToString(rsi,1);
      g_macdState=(macd>sig?"BULLISH":(macd<sig?"BEARISH":"FLAT"));
   }
   int b=CountPositions(0),s=CountPositions(1),all=b+s;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_peakEquity<=0 || eq>g_peakEquity) g_peakEquity=eq;
   double dd=(g_peakEquity>0?(g_peakEquity-eq)/g_peakEquity*100:0);
   if(dd>g_maxDD) g_maxDD=dd;
   int y=30;
   SetLabel("TITLE","NORO AI GOLD SCALPER",22,y,clrDeepSkyBlue,11); y+=24;
   SetLabel("STATUS","EA: "+string(g_enabled?"ACTIVE":"PAUSED")+" | "+_Symbol,22,y,g_enabled?clrLime:clrOrange); y+=19;
   SetLabel("TF","Timeframe: "+EnumToString(_Period)+" | Signal: "+EnumToString(InpSignalTF),22,y,clrWhite); y+=19;
   SetLabel("TREND","Market trend: "+g_trend,22,y,clrAqua); y+=19;
   SetLabel("TRADES","Today entries: "+IntegerToString(g_todayEntries)+" / "+IntegerToString(InpTargetTradesPerDay),22,y,clrWhite); y+=19;
   SetLabel("POSITIONS","Open: "+IntegerToString(all)+" (BUY "+IntegerToString(b)+" / SELL "+IntegerToString(s)+")",22,y,clrWhite); y+=19;
   SetLabel("DAYPROFIT","Daily profit: "+Money(g_dayProfit),22,y,clrLime); y+=19;
   SetLabel("DAYLOSS","Daily loss: "+Money(g_dayLoss),22,y,clrTomato); y+=19;
   SetLabel("DAYNET","Daily net: "+Money(g_dayNet),22,y,g_dayNet>=0?clrLime:clrTomato); y+=19;
   SetLabel("WINRATE","Win rate: "+DoubleToString(WinRate(),1)+"% ("+IntegerToString(g_win)+"W/"+IntegerToString(g_loss)+"L)",22,y,clrWhite); y+=19;
   SetLabel("VOLUME","Open lots: "+DoubleToString(TotalLots(),2),22,y,clrWhite); y+=19;
   SetLabel("SPREAD","Spread: "+DoubleToString(CurrentSpreadPoints(),1)+" points",22,y,clrWhite); y+=19;
   SetLabel("RSI","RSI(14): "+g_rsiState+" | MACD: "+g_macdState,22,y,clrWhite); y+=19;
   SetLabel("TRAIL","Trailing: start "+IntegerToString(InpTrailStartPoints)+" / gap "+IntegerToString(InpTrailDistancePoints),22,y,clrWhite); y+=19;
   SetLabel("BALANCE","Balance: "+Money(AccountInfoDouble(ACCOUNT_BALANCE)),22,y,clrWhite); y+=19;
   SetLabel("EQUITY","Equity: "+Money(eq)+" | DD: "+DoubleToString(g_maxDD,2)+"%",22,y,clrWhite); y+=19;
   SetLabel("FILTER","Filters: "+g_filterState,22,y,g_filterState=="OK"?clrLime:clrOrange); y+=19;
   SetLabel("PF","Avg W/L: "+Money(g_avgWin)+"/"+Money(g_avgLoss)+" | PF: "+DoubleToString(g_profitFactor,2),22,y,clrWhite);
   ChartRedraw(0);
}
void EvaluateAndTrade()
{
   if(!g_enabled || !NewBar()) return;
   if(InpOnlyGoldSymbols && !IsGoldSymbol()) return;
   if(_Period!=InpSignalTF) {g_filterState="ATTACH TO M5"; return;}
   if(CountPositions()>=InpMaxOpenPositions) return;
   if(g_lastEntryBar==iTime(_Symbol,InpSignalTF,0)) return;
   double e9,e21,e50,rsi,macd,sig,atr;
   if(!ReadIndicators(1,e9,e21,e50,rsi,macd,sig,atr)) return;
   if(!MarketFiltersOK(atr)) return;
   // Use the last fully closed candle to avoid intrabar indicator repaint.
   double close=iClose(_Symbol,InpSignalTF,1);
   bool buyTrend=(e9>e21 && e21>e50 && close>e50);
   bool sellTrend=(e9<e21 && e21<e50 && close<e50);
   bool buyRSI=(rsi>=InpBuyRSIMin && rsi<75);
   bool sellRSI=(rsi<=InpSellRSIMax && rsi>25);
   bool buyMACD=(macd>sig);
   bool sellMACD=(macd<sig);
   bool buyPA=BullishPriceAction(1);
   bool sellPA=BearishPriceAction(1);
   double buyScore=0,sellScore=0;
   if(buyTrend) buyScore+=2;
   if(buyRSI) buyScore+=1;
   if(buyMACD) buyScore+=1;
   if(buyPA) buyScore+=2;
   if(close>iHigh(_Symbol,InpSignalTF,2)) buyScore+=1;
   if(sellTrend) sellScore+=2;
   if(sellRSI) sellScore+=1;
   if(sellMACD) sellScore+=1;
   if(sellPA) sellScore+=2;
   if(close<iLow(_Symbol,InpSignalTF,2)) sellScore+=1;
   if(buyScore>=InpMinSignalScore && buyScore>sellScore &&
      CountPositions(0)<InpMaxPositionsPerSide) OpenTrade(ORDER_TYPE_BUY);
   else if(sellScore>=InpMinSignalScore && sellScore>buyScore &&
           CountPositions(1)<InpMaxPositionsPerSide) OpenTrade(ORDER_TYPE_SELL);
}
void RestoreState()
{
   string key=StringFormat("NORO_%I64u_%s_peak",InpMagic,_Symbol);
   if(GlobalVariableCheck(key)) g_peakEquity=GlobalVariableGet(key);
   else g_peakEquity=AccountInfoDouble(ACCOUNT_EQUITY);
}
void SaveState()
{
   string key=StringFormat("NORO_%I64u_%s_peak",InpMagic,_Symbol);
   GlobalVariableSet(key,g_peakEquity);
}
//------------------------------ Events -------------------------------
int OnInit()
{
   if(InpRiskPerTradePct<=0 || InpMaxAggregateRiskPct<=0 ||
      InpMaxOpenPositions<1 || InpTrailDistancePoints<1)
      return INIT_PARAMETERS_INCORRECT;
   if(InpOnlyGoldSymbols && !IsGoldSymbol())
      Print("Warning: this EA is intended for XAUUSD/GOLD symbols.");
   hFast=iMA(_Symbol,InpSignalTF,InpFastEMA,0,MODE_EMA,PRICE_CLOSE);
   hMedium=iMA(_Symbol,InpSignalTF,InpMediumEMA,0,MODE_EMA,PRICE_CLOSE);
   hSlow=iMA(_Symbol,InpSignalTF,InpSlowEMA,0,MODE_EMA,PRICE_CLOSE);
   hRSI=iRSI(_Symbol,InpSignalTF,InpRSIPeriod,PRICE_CLOSE);
   hMACD=iMACD(_Symbol,InpSignalTF,InpMACDFast,InpMACDSlow,InpMACDSignal,PRICE_CLOSE);
   hATR=iATR(_Symbol,InpSignalTF,InpATRPeriod);
   if(hFast==INVALID_HANDLE || hMedium==INVALID_HANDLE || hSlow==INVALID_HANDLE ||
      hRSI==INVALID_HANDLE || hMACD==INVALID_HANDLE || hATR==INVALID_HANDLE)
      return INIT_FAILED;
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   RestoreState();
   CreateDashboard();
   EventSetTimer(1);
   g_status="READY";
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   EventKillTimer();
   SaveState();
   if(hFast!=INVALID_HANDLE) IndicatorRelease(hFast);
   if(hMedium!=INVALID_HANDLE) IndicatorRelease(hMedium);
   if(hSlow!=INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hRSI!=INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hMACD!=INVALID_HANDLE) IndicatorRelease(hMACD);
   if(hATR!=INVALID_HANDLE) IndicatorRelease(hATR);
   DeleteDashboard();
}
void OnTick()
{
   ManageTrailing();
   EvaluateAndTrade();
}
void OnTimer()
{
   UpdateDashboard();
   SaveState();
}
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(id!=CHARTEVENT_OBJECT_CLICK) return;
   if(sparam==PREFIX+"TOGGLE")
   {
      g_enabled=!g_enabled;
      ObjectSetInteger(0,PREFIX+"TOGGLE",OBJPROP_STATE,false);
      UpdateDashboard();
   }
   else if(sparam==PREFIX+"CLOSE")
   {
      CloseAllOurPositions();
      ObjectSetInteger(0,PREFIX+"CLOSE",OBJPROP_STATE,false);
   }
   else if(sparam==PREFIX+"HIDE")
   {
      g_panelVisible=!g_panelVisible;
      if(g_panelVisible) CreateDashboard();
      else DeleteDashboard();
   }
}
//+------------------------------------------------------------------+