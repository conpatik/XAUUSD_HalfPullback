#ifndef HALF_PULLBACK_NOTICE
#define HALF_PULLBACK_NOTICE
// Bits: BUY=1, SELL=2. One state belongs to one chart candle.
struct NoticeState
{
   int active;
   int instantSent;
   int cancelSent;
};

void ResetNotice(NoticeState &state)
{
   state.active=0; state.instantSent=0; state.cancelSent=0;
}

void StepNotice(int current,NoticeState &state,int &instantMask,int &cancelMask)
{
   instantMask=current & ~state.instantSent;
   cancelMask=state.active & ~current & state.instantSent & ~state.cancelSent;
   state.instantSent|=instantMask;
   state.cancelSent|=cancelMask;
   state.active=current;
}

void FinalNotice(int finalMask,const NoticeState &state,int &confirmedMask,int &rejectedMask)
{
   confirmedMask=finalMask;
   // A previous cancellation does not replace the final status message.
   rejectedMask=state.instantSent & ~finalMask;
}
#endif
