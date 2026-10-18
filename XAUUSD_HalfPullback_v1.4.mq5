#property strict
#property version "1.40"
#property tester_everytick_calculate
#property description "Causal half-pullback with retained impulse and inspection panel."
#property indicator_chart_window
#property indicator_buffers 2
#property indicator_plots 2
#property indicator_label1 "Buy"
#property indicator_type1 DRAW_ARROW
#property indicator_color1 clrLimeGreen
#property indicator_width1 2
#property indicator_label2 "Sell"
#property indicator_type2 DRAW_ARROW
#property indicator_color2 clrTomato
#property indicator_width2 2

input group "時間足・方向判定"
input ENUM_TIMEFRAMES InpHigherTF=PERIOD_CURRENT; // 上位足（CURRENT＝自動）
input bool InpUseSMA=false; // 上位足20SMA条件も追加する
input bool InpInvalidateStructure=true; // 確定上位足のヒゲによる構造崩れを除外
input bool InpBuy=true; // 買いを検知
input bool InpSell=true; // 売りを検知
input group "波形・半値"
input int InpPivotLeft=2; // スイング判定：過去側の本数
input int InpPivotRight=2; // スイング確定：後続の確定足本数
input int InpLookback=300; // 波形探索の最大本数
input double InpHalfTolerance=10.0; // 半値の許容幅：推進波値幅に対する％（±）
input int InpTouchWaitBars=3; // 半値接触の足から何本後まで反転を認めるか
input int InpMinImpulse=2; // 推進波の最小本数
input int InpMinCorrection=1; // 修正波の最小本数
input int InpMaxCorrection=20; // 修正波の最大本数
input bool InpRequireBreak=true; // 推進波に直前スイング高値・安値の更新を必須にする
input bool InpOneSignalPerWave=true; // 1波につき初回確定サインの足だけを通知
input group "プライスアクション"
input bool InpEngulf=true; // 実体の包み足
input bool InpPin=true; // ピンバー
input double InpWickBody=2.0; // ピンバー：主ヒゲ／実体の最小倍率
input double InpCloseFraction=0.333333; // ピンバー：終値の端からの割合
input double InpPinBodyMax=0.333333; // ピンバー：実体／全値幅の最大割合
input group "表示・通知"
input double InpInstantStablePercent=1.0; // 即時成立を連続観測する時間：時間足の％、0でv1.3相当
input int InpHistoryBars=2000; // 過去の矢印・確認用履歴の本数
input double InpArrowRange=0.15; // 矢印の距離：足の値幅の倍率
input bool InpPopup=true; // PCアラート
input bool InpPush=true; // スマホPush通知
input bool InpAuditCSV=true; // サインの判定根拠をCSVへ保存
input bool InpAuditHistory=true; // 装着時の履歴確定サインもCSVへ保存
input group "判定の確認"
input bool InpShowDebug=true; // 確認パネル・波形・半値ゾーンを表示
input datetime InpInspectTime=0; // 確認する足の日時（サーバー時刻、0＝最新）
input bool InpInspectClick=true; // 通常チャートをクリックして過去足を確認
input int InpPanelX=12; // パネルの左位置
input int InpPanelY=30; // パネルの上位置
input int InpPanelFont=9; // パネル文字サイズ

#include "HalfPullbackCore_v1.4.mqh"
#include "HalfPullbackNotice_v1.4.mqh"
#include "HalfPullbackStability_v1.4.mqh"

struct TrendContext
{
   int dir;
   double h1;
   double h2;
   double l1;
   double l2;
   string reason;
};
double BuyBuffer[],SellBuffer[];
MqlRates Rates[],Higher[];
WaveState BuyAtOpen[],SellAtOpen[];
TrendContext TrendAtOpen[];
ENUM_TIMEFRAMES HigherTF;
datetime TrackedBar=0,InspectTime=0;
int HistoryCount=0;
NoticeState Notices;
StabilityState Stability;
int StableSeconds=0;
bool Ready=false;
string Prefix,PushQueue[];
string PushGate="HalfPullback.PushGate.v1";
int PushRetries=0;
ulong LastDebugRefresh=0;
int AuditHandle=INVALID_HANDLE;
string AuditFile="";

ENUM_TIMEFRAMES AutoHigher()
{
   int sec=PeriodSeconds(_Period);
   if(sec<300) return PERIOD_M5;
   if(sec<900) return PERIOD_M15;
   if(sec<3600) return PERIOD_H1;
   if(sec<14400) return PERIOD_H4;
   if(sec<86400) return PERIOD_D1;
   if(sec<604800) return PERIOD_W1;
   return PERIOD_MN1;
}

int Swings(const MqlRates &r[],int newest,int &types[],int &indices[],double &prices[])
{
   ArrayResize(types,0); ArrayResize(indices,0); ArrayResize(prices,0);
   int count=0;
   int oldest=MathMin(ArraySize(r)-InpPivotLeft-1,newest+InpLookback);
   for(int i=oldest;i>=newest+InpPivotRight;i--)
   {
      int type=PivotType(r,i);
      if(type==0) continue;
      double price=type==1?r[i].high:r[i].low;
      if(count>0 && types[count-1]==type)
      {
         if((type==1 && price>prices[count-1]) || (type==-1 && price<prices[count-1]))
         { indices[count-1]=i; prices[count-1]=price; }
         continue;
      }
      ArrayResize(types,count+1); ArrayResize(indices,count+1); ArrayResize(prices,count+1);
      types[count]=type; indices[count]=i; prices[count]=price; count++;
   }
   return count;
}

int ClosedHigherAt(datetime observation)
{
   for(int i=0;i<ArraySize(Higher);i++) if(Higher[i].time<=observation) return i+1;
   return -1;
}

void AnalyzeTrend(int start,TrendContext &t)
{
   ZeroMemory(t); t.reason="上位足の履歴不足";
   if(start<1 || start+InpPivotLeft+30>=ArraySize(Higher)) return;
   int ty[],ix[]; double pr[];
   int n=Swings(Higher,start,ty,ix,pr),nh=0,nl=0,hi=-1,li=-1;
   for(int j=n-1;j>=0 && (nh<2 || nl<2);j--)
   {
      if(ty[j]==1 && nh<2)
      { if(nh==0) { t.h1=pr[j]; hi=ix[j]; } else t.h2=pr[j]; nh++; }
      if(ty[j]==-1 && nl<2)
      { if(nl==0) { t.l1=pr[j]; li=ix[j]; } else t.l2=pr[j]; nl++; }
   }
   if(nh<2 || nl<2) { t.reason="上位足の山谷待ち"; return; }
   if(t.h1>t.h2 && t.l1>t.l2) t.dir=1;
   if(t.h1<t.h2 && t.l1<t.l2) t.dir=-1;
   t.reason="高値・安値の方向が不一致";
   if(t.dir==0) return;
   if(InpInvalidateStructure)
   {
      int anchor=t.dir==1?li:hi;
      for(int k=anchor-1;k>=start;k--)
      {
         if((t.dir==1 && Higher[k].low<=t.l1) || (t.dir==-1 && Higher[k].high>=t.h1))
         { t.dir=0; t.reason="上位足の構造崩れ"; return; }
      }
   }
   t.reason=t.dir==1?"高値・安値切り上げ":"高値・安値切り下げ";
   if(!InpUseSMA) return;
   double now=0,previous=0;
   for(int k=0;k<20;k++) { now+=Higher[start+k].close; previous+=Higher[start+k+1].close; }
   now/=20; previous/=20;
   if((t.dir==1 && !(Higher[start].close>now && now>previous)) ||
      (t.dir==-1 && !(Higher[start].close<now && now<previous)))
   { t.dir=0; t.reason="20SMA条件不成立"; }
}

void Diagnose(int s,int dir,const WaveState &w,const TrendContext &trend,WaveDiagnostic &d)
{
   EvaluateWave(Rates,s,dir,w,d);
   if((dir==1 && !InpBuy) || (dir==-1 && !InpSell))
   { d.signal=false; d.reason="検知OFF"; return; }
   if(trend.dir!=dir)
   { d.signal=false; d.reason="上位方向不一致 / "+d.reason; }
}

int SignalAt(int s)
{
   WaveDiagnostic b,d;
   Diagnose(s,1,BuyAtOpen[s],TrendAtOpen[s],b);
   Diagnose(s,-1,SellAtOpen[s],TrendAtOpen[s],d);
   return (b.signal?1:0)|(d.signal?2:0);
}

void Paint(int s,int mask)
{
   double gap=MathMax((Rates[s].high-Rates[s].low)*InpArrowRange,10*_Point);
   BuyBuffer[s]=(mask&1)!=0?Rates[s].low-gap:EMPTY_VALUE;
   SellBuffer[s]=(mask&2)!=0?Rates[s].high+gap:EMPTY_VALUE;
}

// Chronological replay freezes the impulse and HTF context at each bar opening.
void Replay()
{
   int n=ArraySize(Rates);
   ArrayResize(BuyAtOpen,n); ArrayResize(SellAtOpen,n); ArrayResize(TrendAtOpen,n);
   ArrayInitialize(BuyBuffer,EMPTY_VALUE); ArrayInitialize(SellBuffer,EMPTY_VALUE);
   WaveState buy,sell; PivotState pivot; TrendContext cached;
   ZeroMemory(buy); ZeroMemory(sell); ZeroMemory(pivot); ZeroMemory(cached);
   pivot.index=-1; pivot.oppositeIndex=-1; pivot.previousSameIndex=-1;
   int cachedStart=-2;
   int oldest=n-InpPivotLeft-InpPivotRight-2;
   for(int s=oldest;s>=0;s--)
   {
      AdvancePivot(Rates,s,pivot,buy,sell);
      BuyAtOpen[s]=buy; SellAtOpen[s]=sell;
      int start=ClosedHigherAt(Rates[s].time);
      if(start!=cachedStart) { AnalyzeTrend(start,cached); cachedStart=start; }
      TrendAtOpen[s]=cached;
      WaveDiagnostic b,d;
      Diagnose(s,1,buy,cached,b); Diagnose(s,-1,sell,cached,d);
      if(s<=HistoryCount) Paint(s,(b.signal?1:0)|(d.signal?2:0));
      // Invalidation is committed only after this bar is evaluated.
      CommitWaveResult(s,b,buy); CommitWaveResult(s,d,sell);
   }
}

void OpenAudit()
{
   if(!InpAuditCSV) return;
   string symbol=_Symbol;
   StringReplace(symbol,"/","_"); StringReplace(symbol,"\\","_"); StringReplace(symbol,":","_");
   StringReplace(symbol,"*","_"); StringReplace(symbol,"?","_"); StringReplace(symbol,"\"","_");
   StringReplace(symbol,"<","_"); StringReplace(symbol,">","_"); StringReplace(symbol,"|","_");
   AuditFile="HalfPullback_v1.4_"+symbol+"_"+EnumToString(_Period)+"_"+Prefix+".csv";
   AuditHandle=FileOpen(AuditFile,FILE_WRITE|FILE_CSV|FILE_UNICODE|FILE_COMMON|FILE_SHARE_READ,',');
   if(AuditHandle==INVALID_HANDLE)
   { PrintFormat("判定CSVを開けません: %d",GetLastError()); return; }
   FileWrite(AuditHandle,"version","event","event_time","bar_time","symbol","timeframe","higher_timeframe",
      "direction","wave_id","base_time","base_price","tip_time","tip_price","reference_time","reference_price",
      "break_confirmed","zone_lower","zone_middle","zone_upper","touch_age","pattern","open","high","low","close",
      "prev_open","prev_high","prev_low","prev_close",
      "htf_direction","htf_prev_high","htf_last_high","htf_prev_low","htf_last_low","result","reason",
      "require_break","one_per_wave","touch_wait_bars","half_tolerance","pivot_left","pivot_right","sma_filter","structure_guard",
      "instant_stable_percent","instant_stable_seconds","raw_seen_mask","instant_sent_mask","stability_wait_mask");
   FileFlush(AuditHandle);
   Print("判定CSV保存先: "+TerminalInfoString(TERMINAL_COMMONDATA_PATH)+"\\Files\\"+AuditFile);
}

void Audit(string stage,int bit,int s)
{
   WaveState w;
   if(bit==1) w=BuyAtOpen[s]; else w=SellAtOpen[s];
   int dir=bit==1?1:-1;
   WaveDiagnostic d; Diagnose(s,dir,w,TrendAtOpen[s],d);
   TrendContext t=TrendAtOpen[s];
   string baseTime="",tipTime="",referenceTime="";
   if(w.base>=0 && w.base<ArraySize(Rates)) baseTime=TimeToString(Rates[w.base].time,TIME_DATE|TIME_MINUTES);
   if(w.tip>=0 && w.tip<ArraySize(Rates)) tipTime=TimeToString(Rates[w.tip].time,TIME_DATE|TIME_MINUTES);
   if(w.referenceIndex>=0 && w.referenceIndex<ArraySize(Rates))
      referenceTime=TimeToString(Rates[w.referenceIndex].time,TIME_DATE|TIME_MINUTES);
   string waveId=(dir==1?"BUY:":"SELL:")+baseTime+":"+tipTime;
   if(stage!="履歴確定")
      PrintFormat("判定根拠 %s / %s / 波:%s→%s / 直前高安:%s / 半値:%s～%s / 接触:%d本前 / PA:%s / %s",
         stage,waveId,DoubleToString(w.start,_Digits),DoubleToString(w.end,_Digits),
         DoubleToString(w.reference,_Digits),DoubleToString(d.lower,_Digits),DoubleToString(d.upper,_Digits),
         d.age,PatternText(d.patterns),d.reason);
   if(AuditHandle==INVALID_HANDLE) return;
   uint written=FileWrite(AuditHandle,"1.4",stage,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),
      TimeToString(Rates[s].time,TIME_DATE|TIME_MINUTES),_Symbol,EnumToString(_Period),EnumToString(HigherTF),
      dir==1?"BUY":"SELL",waveId,baseTime,DoubleToString(w.start,_Digits),tipTime,DoubleToString(w.end,_Digits),
      referenceTime,DoubleToString(w.reference,_Digits),w.breakConfirmed?1:0,
      DoubleToString(d.lower,_Digits),DoubleToString(d.middle,_Digits),DoubleToString(d.upper,_Digits),
      d.age,PatternText(d.patterns),DoubleToString(Rates[s].open,_Digits),DoubleToString(Rates[s].high,_Digits),
      DoubleToString(Rates[s].low,_Digits),DoubleToString(Rates[s].close,_Digits),
      DoubleToString(Rates[s+1].open,_Digits),DoubleToString(Rates[s+1].high,_Digits),
      DoubleToString(Rates[s+1].low,_Digits),DoubleToString(Rates[s+1].close,_Digits),t.dir,
      DoubleToString(t.h2,_Digits),DoubleToString(t.h1,_Digits),DoubleToString(t.l2,_Digits),DoubleToString(t.l1,_Digits),
      d.signal?1:0,d.reason,InpRequireBreak?1:0,InpOneSignalPerWave?1:0,InpTouchWaitBars,InpHalfTolerance,
      InpPivotLeft,InpPivotRight,InpUseSMA?1:0,InpInvalidateStructure?1:0,
      InpInstantStablePercent,StableSeconds,
      stage=="履歴確定"?-1:Stability.seen,stage=="履歴確定"?-1:Notices.instantSent,
      stage=="履歴確定"?-1:Stability.waiting);
   if(written==0) PrintFormat("判定CSV書込失敗: %d",GetLastError());
   if(stage!="履歴確定") FileFlush(AuditHandle);
}

void Notify(string stage,int bit,datetime bar)
{
   string direction=bit==1?"買い":"売り";
   string msg=StringFormat("[%s] %s %s %s / 足:%s / 上位:%s",stage,_Symbol,EnumToString(_Period),direction,
                           TimeToString(bar,TIME_DATE|TIME_MINUTES),EnumToString(HigherTF));
   Print(msg);
   int shift=iBarShift(_Symbol,_Period,bar,true);
   if(shift>=0 && shift<ArraySize(TrendAtOpen)) Audit(stage,bit,shift);
   if(InpPopup && !MQLInfoInteger(MQL_TESTER)) Alert(msg);
   if(!InpPush || MQLInfoInteger(MQL_TESTER)) return;
   int n=ArraySize(PushQueue);
   if(n>=256) { Print("Push待ち行列が満杯。内容はExpertsログを確認してください。"); return; }
   ArrayResize(PushQueue,n+1); PushQueue[n]=StringSubstr(msg,0,255);
}

void OnTimer()
{
   if(ArraySize(PushQueue)==0 || !TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED)) return;
   double previous=GlobalVariableGet(PushGate),now=(double)TimeLocal();
   if(now-previous<7 || !GlobalVariableSetOnCondition(PushGate,now,previous)) return;
   ResetLastError();
   if(!SendNotification(PushQueue[0]))
   {
      PrintFormat("Push送信失敗: %d / %s",GetLastError(),PushQueue[0]);
      PushRetries++;
      if(PushRetries<3) return;
   }
   for(int i=1;i<ArraySize(PushQueue);i++) PushQueue[i-1]=PushQueue[i];
   ArrayResize(PushQueue,ArraySize(PushQueue)-1); PushRetries=0;
}

void ObjectStyle(string name,color c)
{
   ObjectSetInteger(0,name,OBJPROP_COLOR,c);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_BACK,true);
}

void Line(string key,datetime a,double pa,datetime b,double pb,color c,int style=STYLE_SOLID)
{
   string name=Prefix+key;
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_TREND,0,a,pa,b,pb);
   ObjectMove(0,name,0,a,pa); ObjectMove(0,name,1,b,pb);
   ObjectStyle(name,c); ObjectSetInteger(0,name,OBJPROP_RAY_RIGHT,false);
   ObjectSetInteger(0,name,OBJPROP_STYLE,style); ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
}

void PanelRow(int row,string text,color c=clrGainsboro)
{
   string name=Prefix+"panel"+IntegerToString(row);
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,InpPanelX+10);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,InpPanelY+8+row*(InpPanelFont+8));
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,InpPanelFont);
   ObjectSetInteger(0,name,OBJPROP_COLOR,c);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetString(0,name,OBJPROP_FONT,"Meiryo");
   ObjectSetString(0,name,OBJPROP_TEXT,text);
}

void PanelBackground()
{
   string name=Prefix+"background";
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,InpPanelX);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,InpPanelY);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,580);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,16+10*(InpPanelFont+8));
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,C'22,27,33');
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,C'65,75,85');
   ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
}

void Waiting(string msg)
{
   if(!InpShowDebug) return;
   PanelBackground();
   PanelRow(0,"HalfPullback v1.4 / 準備中",clrKhaki); PanelRow(1,msg);
   for(int i=2;i<10;i++) PanelRow(i,"");
}

string PatternText(int flags)
{
   if(flags==3) return "包み足＋ピンバー";
   if(flags==1) return "包み足";
   if(flags==2) return "ピンバー";
   return "未成立";
}

string ZoneText(const WaveState &w,const WaveDiagnostic &d)
{
   if(!w.active) return "波形待ち";
   return DoubleToString(d.lower,_Digits)+" ～ "+DoubleToString(d.upper,_Digits)+
          " / 接触:"+(d.touched?IntegerToString(d.age)+"本前":"なし");
}

void DrawWave(string key,int s,const WaveState &w,const WaveDiagnostic &d,color c)
{
   if(!w.active || w.tip<0 || w.base>=ArraySize(Rates))
   { ObjectsDeleteAll(0,Prefix+key); return; }
   datetime a=Rates[w.tip].time,b=Rates[s].time+PeriodSeconds(_Period);
   Line(key+"impulse",Rates[w.base].time,w.start,a,w.end,c);
   Line(key+"middle",a,d.middle,b,d.middle,c,STYLE_DASH);
   Line(key+"upper",a,d.upper,b,d.upper,c,STYLE_DOT);
   Line(key+"lower",a,d.lower,b,d.lower,c,STYLE_DOT);
   string name=Prefix+key+"zone";
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_RECTANGLE,0,a,d.upper,b,d.lower);
   ObjectMove(0,name,0,a,d.upper); ObjectMove(0,name,1,b,d.lower);
   ObjectStyle(name,c); ObjectSetInteger(0,name,OBJPROP_FILL,false);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,"半値ゾーン（水平レジサポの判定は未追加）");
}

int FindInspection()
{
   if(InspectTime==0) return 0;
   if(InspectTime>=Rates[0].time+PeriodSeconds(_Period)) return -1;
   for(int s=0;s<=HistoryCount;s++)
      if(Rates[s].time<=InspectTime)
      {
         if(InspectTime>=Rates[s].time+PeriodSeconds(_Period)) return -1;
         return s;
      }
   return -1;
}

void RenderDebug(bool force=false)
{
   if(!InpShowDebug || !Ready) return;
   ulong now=GetTickCount64();
   if(!force && now-LastDebugRefresh<200) return;
   LastDebugRefresh=now;
   int s=FindInspection();
   if(s<0)
   {
      ObjectsDeleteAll(0,Prefix+"buy_"); ObjectsDeleteAll(0,Prefix+"sell_");
      ObjectDelete(0,Prefix+"selected");
      Waiting("指定日時は未到達・休日または確認用履歴の範囲外です"); return;
   }
   WaveDiagnostic buy,sell;
   Diagnose(s,1,BuyAtOpen[s],TrendAtOpen[s],buy);
   Diagnose(s,-1,SellAtOpen[s],TrendAtOpen[s],sell);
   TrendContext t=TrendAtOpen[s];
   PanelBackground();
   string state=s==0?"形成中・変動あり":"確定OHLC";
   PanelRow(0,"HalfPullback v1.4 / "+TimeToString(Rates[s].time,TIME_DATE|TIME_MINUTES)+" / "+state,clrWhite);
   string direction=t.dir==1?"買い方向":(t.dir==-1?"売り方向":"方向なし");
   PanelRow(1,"上位 "+EnumToString(HigherTF)+"："+direction+" / "+t.reason,clrKhaki);
   PanelRow(2,"高値 "+DoubleToString(t.h2,_Digits)+" → "+DoubleToString(t.h1,_Digits)+
              " / 安値 "+DoubleToString(t.l2,_Digits)+" → "+DoubleToString(t.l1,_Digits));
   PanelRow(3,"買い："+buy.reason,clrLightSkyBlue);
   PanelRow(4,"半値帯 "+ZoneText(BuyAtOpen[s],buy));
   PanelRow(5,"買いPA："+PatternText(buy.patterns)+(BuyAtOpen[s].active?
      " / 波 "+DoubleToString(BuyAtOpen[s].start,_Digits)+" → "+DoubleToString(BuyAtOpen[s].end,_Digits)+
      " / 比較 "+DoubleToString(BuyAtOpen[s].reference,_Digits):""));
   PanelRow(6,"売り："+sell.reason,clrLightSalmon);
   PanelRow(7,"半値帯 "+ZoneText(SellAtOpen[s],sell));
   PanelRow(8,"売りPA："+PatternText(sell.patterns)+(SellAtOpen[s].active?
      " / 波 "+DoubleToString(SellAtOpen[s].start,_Digits)+" → "+DoubleToString(SellAtOpen[s].end,_Digits)+
      " / 比較 "+DoubleToString(SellAtOpen[s].reference,_Digits):""));
   PanelRow(9,"即時待機:"+IntegerToString(StableSeconds)+"秒 / 待機中:"+IntegerToString(Stability.waiting)+" / "+"直前高安更新:"+(InpRequireBreak?"必須":"任意")+" / 初回確定足のみ:"+
      (InpOneSignalPerWave?"ON":"OFF")+" / 青＝買い・橙＝売り",clrSilver);
   DrawWave("buy_",s,BuyAtOpen[s],buy,clrSteelBlue);
   DrawWave("sell_",s,SellAtOpen[s],sell,clrPeru);
   string selected=Prefix+"selected";
   if(s>0)
   {
      if(ObjectFind(0,selected)<0) ObjectCreate(0,selected,OBJ_VLINE,0,Rates[s].time,0);
      ObjectMove(0,selected,0,Rates[s].time,0); ObjectStyle(selected,clrSilver);
      ObjectSetInteger(0,selected,OBJPROP_STYLE,STYLE_DOT);
   }
   else ObjectDelete(0,selected);
   ChartRedraw();
}

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(id!=CHARTEVENT_CLICK || !InpShowDebug || !InpInspectClick || !Ready) return;
   int x=(int)lparam,y=(int)dparam;
   if(x>=InpPanelX && x<=InpPanelX+580 && y>=InpPanelY && y<=InpPanelY+16+10*(InpPanelFont+8)) return;
   int window=0; datetime when=0; double price=0;
   if(ChartXYToTimePrice(0,x,y,window,when,price) && window==0)
   { InspectTime=when; RenderDebug(true); }
}

int OnInit()
{
   if(!MathIsValidNumber(InpInstantStablePercent) || InpInstantStablePercent<0 || InpInstantStablePercent>50 ||
      InpPivotLeft<1 || InpPivotRight<1 || InpLookback<30 || InpLookback>3000 ||
      InpPivotLeft>20 || InpPivotRight>20 || InpHalfTolerance<0 || InpHalfTolerance>=50 ||
      InpTouchWaitBars<0 || InpTouchWaitBars>50 || InpMinImpulse<1 || InpMinCorrection<1 ||
      InpMaxCorrection<InpMinCorrection || InpMaxCorrection>InpLookback ||
      InpHistoryBars<0 || InpHistoryBars>10000 || InpWickBody<1 || InpArrowRange<0 ||
      InpCloseFraction<=0 || InpCloseFraction>0.5 || InpPinBodyMax<=0 || InpPinBodyMax>0.5 ||
      InpPanelX<0 || InpPanelY<0 || InpPanelFont<7 || InpPanelFont>18 ||
      (!InpEngulf && !InpPin)) return INIT_PARAMETERS_INCORRECT;
   HigherTF=InpHigherTF==PERIOD_CURRENT?AutoHigher():InpHigherTF;
   if(PeriodSeconds(HigherTF)<=PeriodSeconds(_Period))
   { Print("上位足はチャートより長い時間足を選択してください。月足チャートは対象外です。"); return INIT_PARAMETERS_INCORRECT; }
   Prefix="HP14_"+IntegerToString(ChartID())+"_"+IntegerToString((long)GetMicrosecondCount())+"_";
   InspectTime=InpInspectTime;
   ResetNotice(Notices);
   ResetStability(Stability);
   StableSeconds=(int)MathCeil(PeriodSeconds(_Period)*InpInstantStablePercent/100.0);
   SetIndexBuffer(0,BuyBuffer,INDICATOR_DATA); SetIndexBuffer(1,SellBuffer,INDICATOR_DATA);
   ArraySetAsSeries(BuyBuffer,true); ArraySetAsSeries(SellBuffer,true);
   ArraySetAsSeries(Rates,true); ArraySetAsSeries(Higher,true);
   PlotIndexSetInteger(0,PLOT_ARROW,233); PlotIndexSetInteger(1,PLOT_ARROW,234);
   PlotIndexSetDouble(0,PLOT_EMPTY_VALUE,EMPTY_VALUE); PlotIndexSetDouble(1,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   IndicatorSetString(INDICATOR_SHORTNAME,"HalfPullback 1.4 ["+EnumToString(HigherTF)+"]");
   if(!GlobalVariableCheck(PushGate)) GlobalVariableSet(PushGate,0);
   if(InpPush && !TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED))
      Print("ツール→オプション→通知でPushを設定してください。");
   if(InpPush && !MQLInfoInteger(MQL_TESTER)) EventSetTimer(1);
   OpenAudit();
   Waiting("チャート足・上位足の履歴を読み込んでいます");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(AuditHandle!=INVALID_HANDLE) { FileFlush(AuditHandle); FileClose(AuditHandle); AuditHandle=INVALID_HANDLE; }
   if(Prefix!="") ObjectsDeleteAll(0,Prefix);
   if(ArraySize(PushQueue)>0) PrintFormat("終了により未送信Push %d件を破棄。内容はログに記録済みです。",ArraySize(PushQueue));
}

int OnCalculate(const int rates_total,const int prev_calculated,const datetime &time[],
                const double &open[],const double &high[],const double &low[],const double &close[],
                const long &tick_volume[],const long &volume[],const int &spread[])
{
   if(prev_calculated==0)
   {
      Ready=false;
      ArrayInitialize(BuyBuffer,EMPTY_VALUE); ArrayInitialize(SellBuffer,EMPTY_VALUE);
   }
   int warmup=InpLookback+InpPivotLeft+InpPivotRight+10;
   if(rates_total<warmup)
   { Waiting("チャート履歴不足：最低 "+IntegerToString(warmup)+"本必要"); return 0; }
   int history=MathMin(InpHistoryBars,rates_total-warmup);
   int need=history+warmup;
   if(CopyRates(_Symbol,_Period,0,need,Rates)<need)
   { Waiting("チャート足の履歴取得待ち"); return prev_calculated; }
   if(!Ready || TrackedBar!=Rates[0].time)
   {
      int oldestShift=iBarShift(_Symbol,HigherTF,Rates[need-1].time,false);
      if(oldestShift<0) { Waiting("上位足の履歴取得待ち"); return prev_calculated; }
      int hneed=oldestShift+InpLookback+InpPivotLeft+30;
      int got=CopyRates(_Symbol,HigherTF,0,hneed,Higher);
      if(got<oldestShift+InpPivotLeft+32)
      { Waiting("上位足の履歴不足・取得待ち"); return prev_calculated; }
      datetime previous=TrackedBar;
      HistoryCount=history; Replay(); Ready=true;
      if(previous==0 && AuditHandle!=INVALID_HANDLE && InpAuditHistory)
      {
         for(int s=HistoryCount;s>=1;s--)
         {
            int mask=SignalAt(s);
            for(int bit=1;bit<=2;bit*=2) if((mask&bit)!=0) Audit("履歴確定",bit,s);
         }
         FileFlush(AuditHandle);
      }
      if(previous!=0 && previous!=Rates[0].time)
      {
         int old=iBarShift(_Symbol,_Period,previous,true);
         if(old>=1 && old<=HistoryCount+1 && old<ArraySize(BuyAtOpen))
         {
            int finalMask=SignalAt(old); Paint(old,finalMask);
            int confirmedMask=0,rejectedMask=0;
            FinalNotice(finalMask,Notices,confirmedMask,rejectedMask);
            int suppressed=Stability.seen & ~Notices.instantSent;
            for(int bit=1;bit<=2;bit*=2)
               if((suppressed&bit)!=0) Audit("即時抑制",bit,old);
            for(int bit=1;bit<=2;bit*=2)
            {
               if((confirmedMask&bit)!=0) Notify("確定",bit,previous);
               else if((rejectedMask&bit)!=0) Notify("確定不成立",bit,previous);
            }
         }
      }
      if(previous!=Rates[0].time) { ResetNotice(Notices); ResetStability(Stability); }
      TrackedBar=Rates[0].time;
   }
   int raw=SignalAt(0);
   int current=StableMask(raw,TimeCurrent(),StableSeconds,Notices.instantSent,Stability);
   Paint(0,current);
   int instantMask=0,cancelMask=0;
   StepNotice(current,Notices,instantMask,cancelMask);
   for(int bit=1;bit<=2;bit*=2)
   {
      if((instantMask&bit)!=0) Notify("即時",bit,TrackedBar);
      if((cancelMask&bit)!=0) Notify("条件崩れ",bit,TrackedBar);
   }
   RenderDebug();
   return rates_total;
}
