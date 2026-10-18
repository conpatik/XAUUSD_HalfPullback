// Causal price-action and wave engine. No terminal or notification functions.
#ifndef HALF_PULLBACK_CORE
#define HALF_PULLBACK_CORE
struct WaveState
{
   bool active;
   int base;
   int tip;
   double start;
   double end;
   double reference;
   int referenceIndex;
   bool breakConfirmed;
   bool signaled;
   string waitingReason;
};
struct PivotState
{
   int type;
   int index;
   double price;
   int oppositeIndex;
   double oppositePrice;
   int previousSameIndex;
   double previousSamePrice;
};
struct WaveDiagnostic
{
   bool signal;
   bool invalid;
   bool touched;
   int age;
   int patterns;
   double lower;
   double middle;
   double upper;
   string reason;
};

int PivotType(const MqlRates &r[],int i)
{
   bool hi=true,lo=true;
   for(int k=1;k<=InpPivotLeft;k++)
   {
      if(r[i].high<=r[i+k].high) hi=false;
      if(r[i].low>=r[i+k].low) lo=false;
   }
   for(int k=1;k<=InpPivotRight;k++)
   {
      if(r[i].high<=r[i-k].high) hi=false;
      if(r[i].low>=r[i-k].low) lo=false;
   }
   if(hi==lo) return 0;
   return hi?1:-1;
}

int PatternFlags(const MqlRates &r[],int s,int dir)
{
   double o=r[s].open,c=r[s].close,h=r[s].high,l=r[s].low;
   double body=MathAbs(c-o),range=h-l;
   if(range<=0) return 0;
   bool engulf=false,pin=false;
   if(InpEngulf)
   {
      if(dir==1) engulf=(c>o && r[s+1].close<r[s+1].open && o<=r[s+1].close && c>=r[s+1].open);
      else engulf=(c<o && r[s+1].close>r[s+1].open && o>=r[s+1].close && c<=r[s+1].open);
   }
   if(InpPin && body<=range*InpPinBodyMax)
   {
      double lower=MathMin(o,c)-l,upper=h-MathMax(o,c);
      if(dir==1) pin=(lower>=body*InpWickBody && lower>upper && c>=h-range*InpCloseFraction);
      else pin=(upper>=body*InpWickBody && upper>lower && c<=l+range*InpCloseFraction);
   }
   int flags=0;
   if(engulf) flags|=1;
   if(pin) flags|=2;
   return flags;
}

// Keep an existing impulse even when new correction pivots appear.
void StartWave(PivotState &p,int s,WaveState &w)
{
   if(w.active || p.oppositeIndex<0 || p.oppositeIndex-p.index<InpMinImpulse ||
      p.oppositeIndex-s>InpLookback) return;
   if((p.type==1 && p.price<=p.oppositePrice) || (p.type==-1 && p.price>=p.oppositePrice)) return;
   bool broke=(p.previousSameIndex>=0 &&
      ((p.type==1 && p.price>p.previousSamePrice) || (p.type==-1 && p.price<p.previousSamePrice)));
   if(InpRequireBreak && !broke)
   {
      w.waitingReason=p.previousSameIndex<0?"比較する直前高安待ち":
         (p.type==1?"直前高値を更新した推進波待ち":"直前安値を更新した推進波待ち");
      return;
   }
   w.active=true; w.base=p.oppositeIndex; w.tip=p.index;
   w.start=p.oppositePrice; w.end=p.price;
   w.reference=p.previousSamePrice; w.referenceIndex=p.previousSameIndex;
   w.breakConfirmed=broke; w.signaled=false; w.waitingReason="";
}

void AdvancePivot(const MqlRates &r[],int s,PivotState &p,WaveState &buy,WaveState &sell)
{
   int i=s+InpPivotRight+1; // signal bar s never confirms a pivot
   if(i+InpPivotLeft>=ArraySize(r)) return;
   int type=PivotType(r,i);
   if(type==0) return;
   double price=type==1?r[i].high:r[i].low;
   if(type==p.type)
   {
      if((type==1 && price<=p.price) || (type==-1 && price>=p.price)) return;
   }
   else
   {
      p.previousSameIndex=p.oppositeIndex; p.previousSamePrice=p.oppositePrice;
      p.oppositeIndex=p.index; p.oppositePrice=p.price;
   }
   p.type=type; p.index=i; p.price=price;
   if(type==1) StartWave(p,s,buy);
   else StartWave(p,s,sell);
}

// Replay and live evaluation use the same OHLC-only function.
void EvaluateWave(const MqlRates &r[],int s,int dir,const WaveState &w,WaveDiagnostic &d)
{
   d.signal=false; d.invalid=false; d.touched=false; d.age=-1;
   d.patterns=PatternFlags(r,s,dir);
   d.lower=0; d.middle=0; d.upper=0; d.reason="波形待ち";
   if(!w.active)
   { if(w.waitingReason!="") d.reason=w.waitingReason; return; }
   double bottom=MathMin(w.start,w.end),top=MathMax(w.start,w.end),span=top-bottom;
   d.middle=(top+bottom)/2;
   d.lower=d.middle-span*InpHalfTolerance/100.0;
   d.upper=d.middle+span*InpHalfTolerance/100.0;
   if(span<=0) { d.invalid=true; d.reason="波形の値幅なし"; return; }
   if(w.tip-s>InpMaxCorrection) { d.invalid=true; d.reason="修正波の期限切れ"; return; }
   // Never revive a wave whose origin or endpoint has already been broken.
   for(int k=w.tip-1;k>=s;k--)
   {
      if((dir==1 && r[k].low<=bottom) || (dir==-1 && r[k].high>=top))
      { d.invalid=true; d.reason="推進波の起点割れ"; return; }
      if((dir==1 && r[k].high>top) || (dir==-1 && r[k].low<bottom))
      { d.invalid=true; d.reason="推進波の先端更新"; return; }
   }
   if(w.tip-s<InpMinCorrection) { d.reason="修正波の本数不足"; return; }
   // Range intersection counts as contact. Most recent contact starts the window.
   for(int k=s;k<w.tip;k++)
   {
      if(r[k].low<=d.upper && r[k].high>=d.lower)
      { d.touched=true; d.age=k-s; break; }
   }
   if(InpOneSignalPerWave && w.signaled)
   { d.reason="この推進波は初回確定サイン済み"; return; }
   if(!d.touched) { d.reason="半値への接触待ち"; return; }
   if(d.age>InpTouchWaitBars) { d.reason="半値接触後の待機期限切れ"; return; }
   if((dir==1 && r[s].close<d.lower) || (dir==-1 && r[s].close>d.upper))
   { d.reason="半値ゾーンへの回復待ち"; return; }
   if(d.patterns==0) { d.reason="包み足・ピンバー待ち"; return; }
   d.signal=true; d.reason="成立";
}

// A provisional signal never consumes the wave; a confirmed signal does.
void CommitWaveResult(int s,const WaveDiagnostic &d,WaveState &w)
{
   if(d.invalid) w.active=false;
   if(s>0 && d.signal) w.signaled=true;
}
#endif
