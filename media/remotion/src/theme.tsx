import React from 'react';
import {staticFile, interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';

export const C = {bg: '#0B0B0D', hi: '#F2F2F4', lo: '#8A8A92', line: '#3A3A40', red: '#D63031', acc: '#78C8AA', card: '#16161A'};
export const FONT = 'NotoTC';

export const FontFace: React.FC = () => (
  <style>{`@font-face{font-family:'${FONT}';src:url('${staticFile('NotoSansTC-VF.ttf')}') format('truetype');font-weight:100 900;}`}</style>
);

// 進場：從 at 秒開始，淡入＋位移
export const useIn = (at: number, dist = 24, dur = 0.6) => {
  const f = useCurrentFrame();
  const {fps} = useVideoConfig();
  const p = spring({frame: f - at * fps, fps, config: {damping: 200}, durationInFrames: Math.round(dur * fps)});
  return {opacity: p, transform: `translateY(${(1 - p) * dist}px)`};
};

// 整體淡入淡出（片段頭尾 0.5 秒）
export const useFade = (total: number) => {
  const f = useCurrentFrame();
  const {fps} = useVideoConfig();
  return interpolate(f, [0, 0.5 * fps, total - 0.5 * fps, total], [0, 1, 1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
};

export const Stage: React.FC<{children: React.ReactNode; total: number}> = ({children, total}) => {
  const o = useFade(total);
  return (
    <div style={{position: 'absolute', inset: 0, background: C.bg, fontFamily: FONT, color: C.hi}}>
      <FontFace />
      <div style={{position: 'absolute', inset: 0, opacity: o}}>{children}</div>
    </div>
  );
};
