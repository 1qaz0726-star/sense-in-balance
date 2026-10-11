import React from 'react';
import {C, Stage, useIn} from './theme';

const rows: [string, string, number][] = [
  ['葉士愷', '標註資料・程式開發', 3.9],
  ['黃昱羲', '感知處理流程・Android HMI', 9.7],
  ['胡馨', '提案簡報・驗證證據整理', 14.3],
];

export const Team: React.FC<{total: number}> = ({total}) => (
  <Stage total={total}>
    <div style={{position: 'absolute', top: 190, width: '100%', textAlign: 'center'}}>
      <div style={{fontSize: 100, fontWeight: 800, ...useIn(0.2)}}>感知有度</div>
      <div style={{fontSize: 46, color: C.lo, marginTop: 6, ...useIn(0.7)}}>Sense in Balance</div>
    </div>
    <div style={{position: 'absolute', top: 500, left: 520, width: 900}}>
      {rows.map(([n, r, at]) => {
        const s = useIn(at, 0, 0.7);
        return (
          <div key={n} style={{display: 'flex', alignItems: 'center', height: 120, opacity: s.opacity, transform: `translateX(${(1 - (s.opacity as number)) * -40}px)`}}>
            <div style={{width: 6, height: 64, background: C.acc, marginRight: 34, borderRadius: 3}} />
            <div style={{fontSize: 56, fontWeight: 700, width: 240}}>{n}</div>
            <div style={{fontSize: 42, color: C.lo}}>{r}</div>
          </div>
        );
      })}
    </div>
  </Stage>
);
