import React from 'react';
import {C, Stage, useIn} from './theme';

export const End: React.FC<{total: number}> = ({total}) => (
  <Stage total={total}>
    <div style={{position: 'absolute', top: 230, width: '100%', textAlign: 'center'}}>
      <div style={{fontSize: 124, fontWeight: 800, letterSpacing: 10, ...useIn(0.2)}}>該說才說</div>
      <div style={{fontSize: 54, marginTop: 14, ...useIn(0.6)}}>會自己動手的安靜座艙 AI</div>
      <div style={{display: 'flex', justifyContent: 'center', gap: 26, marginTop: 70, fontSize: 38}}>
        {['規則決策', '端側 Qwen2.5-1.5B 措辭', '本地知識庫問答'].map((s, i) => (
          <div key={s} style={{padding: '14px 28px', border: `1px solid ${C.line}`, borderRadius: 16, ...useIn(1.2 + i * 0.35)}}>{s}</div>
        ))}
      </div>
      <div style={{fontSize: 42, color: C.acc, marginTop: 40, fontWeight: 700, ...useIn(2.4)}}>斷網照常運作（Offline First）</div>
      <div style={{fontSize: 36, color: C.lo, marginTop: 50, ...useIn(3.0)}}>感知有度 Sense in Balance</div>
    </div>
  </Stage>
);
