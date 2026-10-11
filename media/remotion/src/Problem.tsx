import React from 'react';
import {Img, staticFile, useCurrentFrame, useVideoConfig, interpolate, spring} from 'remotion';
import {C, Stage} from './theme';

// N2：「提醒、建議、通知，一個接一個」→ 假通知一張張疊上來；「但很多事…」開始變暗；最後全部淡出
const notes: [string, string, number][] = [
  ['提醒', '胎壓偏低，請盡快檢查', 2.3],
  ['建議', '前方 2 公里有休息站，要不要停一下？', 3.1],
  ['通知', '您有一則新訊息', 3.9],
  ['提醒', '請保持安全車距', 4.5],
  ['建議', '要切換成節能模式嗎？', 5.0],
];

export const Problem: React.FC<{total: number}> = ({total}) => {
  const f = useCurrentFrame();
  const {fps} = useVideoConfig();
  const t = f / fps;
  // 照片：原圖 3840x2160 取 (420,480) 起 2987x1680，慢慢推近
  const base = 1920 / 2987;
  const z = interpolate(t, [0, total / fps], [1, 1.1]);
  const dim = interpolate(t, [5.4, 7.2], [0, 0.45], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const out = interpolate(t, [7.6, 8.6], [1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  return (
    <Stage total={total}>
      <div style={{position: 'absolute', inset: 0, overflow: 'hidden'}}>
        <div style={{position: 'absolute', inset: 0, transform: `scale(${z})`, transformOrigin: '50% 50%'}}>
          <Img src={staticFile('desk.jpg')} style={{position: 'absolute', width: 3840 * base, height: 2160 * base, left: -420 * base, top: -480 * base}} />
        </div>
        <div style={{position: 'absolute', inset: 0, background: '#000', opacity: dim}} />
      </div>
      <div style={{position: 'absolute', right: 70, top: 70, width: 760, opacity: out}}>
        {notes.map(([k, txt, at], i) => {
          const p = spring({frame: f - at * fps, fps, config: {damping: 16, stiffness: 160}});
          return (
            <div key={i} style={{
              display: 'flex', alignItems: 'center', gap: 22, marginBottom: 16, padding: '22px 28px',
              background: 'rgba(22,22,26,0.92)', border: `1px solid ${C.line}`, borderRadius: 22,
              opacity: Math.min(1, p), transform: `translateX(${(1 - p) * 80}px) scale(${0.96 + 0.04 * Math.min(1, p)})`,
            }}>
              <div style={{width: 18, height: 18, borderRadius: 9, background: k === '提醒' ? '#E0A030' : k === '建議' ? '#5AA0E0' : C.lo}} />
              <div style={{fontSize: 30, color: C.lo, width: 70}}>{k}</div>
              <div style={{fontSize: 34, color: C.hi}}>{txt}</div>
            </div>
          );
        })}
      </div>
    </Stage>
  );
};
