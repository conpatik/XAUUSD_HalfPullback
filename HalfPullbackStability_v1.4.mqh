// Only the first provisional notification is delayed. Closed-bar rules stay unchanged.
struct StabilityState
{
   datetime buySince;
   datetime sellSince;
   int active;
   int seen;
   int waiting;
};

void ResetStability(StabilityState &state)
{
   state.buySince=0; state.sellSince=0;
   state.active=0; state.seen=0; state.waiting=0;
}

int StableMask(int raw,datetime now,int seconds,int alreadySent,StabilityState &state)
{
   int accepted=0;
   state.seen|=raw;
   for(int bit=1;bit<=2;bit*=2)
   {
      if((raw&bit)==0) continue;
      datetime since=bit==1?state.buySince:state.sellSince;
      if((state.active&bit)==0 || now<since) since=now;
      if(bit==1) state.buySince=since; else state.sellSince=since;
      if(seconds<=0 || (alreadySent&bit)!=0 || now-since>=seconds) accepted|=bit;
   }
   state.active=raw;
   state.waiting=raw & ~accepted;
   return accepted;
}
