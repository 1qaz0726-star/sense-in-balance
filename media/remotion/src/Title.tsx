import React from 'react';
import {useCurrentFrame, useVideoConfig, interpolate} from 'remotion';
import {C, Stage, useIn} from './theme';

const Chars: React.FC<{text: string; at: number; step: number; style: React.CSSProperties}> = ({text, at, step, style}) => {
  const f = useCurrentFrame();
  const {fps} = useVideoConfig();
  return (
    <div style={{display: 'flex', justifyContent: 'center', ...style}}>
      {[...text].map((ch, i) => {
        const t = f / fps - (at + i * step);
        const o = interpolate(t, [0, 0.45], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
        return <span key={i} style={{opacity: o, transform: `translateY(${(1 - o) * 18}px)`, display: 'inline-block'}}>{ch}</span>;
      })}
    </div>
  );
};

export const Title: React.FC<{total: number}> = ({total}) => {
  const f = useCurrentFrame();
  const {fps} = useVideoConfig();
  const w = interpolate(f / fps, [1.6, 2.4], [0, 120], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  return (
    <Stage total={total}>
      <div style={{position: 'absolute', top: 360, width: '100%'}}>
        <Chars text="該說才說" at={0.3} step={0.18} style={{fontSize: 150, fontWeight: 800, letterSpacing: 12}} />
        <div style={{textAlign: 'center', fontSize: 62, marginTop: 20, ...useIn(1.2)}}>會自己動手的安靜座艙 AI</div>
        <div style={{margin: '36px auto 0', height: 3, width: w, background: C.line}} />
        <div style={{textAlign: 'center', fontSize: 40, color: C.lo, marginTop: 34, ...useIn(2.0)}}>感知有度 Sense in Balance</div>
        <div style={{textAlign: 'center', fontSize: 30, color: C.lo, marginTop: 18, ...useIn(2.4)}}>2026 AI 座艙感知與視覺化 Hackathon・實作組</div>
      </div>
    </Stage>
  );
};
