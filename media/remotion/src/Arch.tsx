import React from 'react';
import {useCurrentFrame, useVideoConfig, interpolate} from 'remotion';
import {C, Stage, useIn} from './theme';

// N3 時間點（片段內秒數）：判斷交給規則 2.0｜說話交給小模型 3.5｜自己做 5.8｜有代價或危險 8.4｜一句話 11.4
const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;

const Box: React.FC<{x: number; y: number; w: number; h: number; at: number; hi?: [number, number]; title: string; sub?: string; dashed?: boolean; color?: string}> =
  ({x, y, w, h, at, hi, title, sub, dashed, color}) => {
    const f = useCurrentFrame();
    const {fps} = useVideoConfig();
    const t = f / fps;
    const s = useIn(at, 16);
    const on = hi ? interpolate(t, [hi[0], hi[0] + 0.3, hi[1] - 0.3, hi[1]], [0, 1, 1, 0], clamp) : 0;
    const bc = color ?? (on > 0.01 ? `rgba(120,200,170,${0.35 + 0.65 * on})` : C.line);
    return (
      <div style={{position: 'absolute', left: x, top: y, width: w, height: h, borderRadius: 22, boxSizing: 'border-box',
        border: `${dashed ? 3 : 3}px ${dashed ? 'dashed' : 'solid'} ${bc}`, background: `rgba(120,200,170,${0.12 * on})`,
        boxShadow: on > 0.01 ? `0 0 ${36 * on}px rgba(120,200,170,${0.35 * on})` : 'none',
        display: 'flex', flexDirection: 'column', justifyContent: 'center', alignItems: 'center', ...s}}>
        <div style={{fontSize: 40, fontWeight: 700, color: dashed ? C.lo : C.hi}}>{title}</div>
        {sub && <div style={{fontSize: 27, color: C.lo, marginTop: 10, textAlign: 'center', whiteSpace: 'pre-line', lineHeight: 1.4}}>{sub}</div>}
      </div>
    );
  };

const Arrow: React.FC<{x1: number; y1: number; x2: number; y2: number; at: number}> = ({x1, y1, x2, y2, at}) => {
  const f = useCurrentFrame();
  const {fps} = useVideoConfig();
  const p = interpolate(f / fps, [at, at + 0.5], [0, 1], clamp);
  const len = Math.hypot(x2 - x1, y2 - y1);
  const a = Math.atan2(y2 - y1, x2 - x1);
  const hx = (s: number) => x2 - 20 * Math.cos(a + s), hy = (s: number) => y2 - 20 * Math.sin(a + s);
  return (
    <svg style={{position: 'absolute', inset: 0}} width={1920} height={1080}>
      <line x1={x1} y1={y1} x2={x2} y2={y2} stroke={C.lo} strokeWidth={4} strokeDasharray={len} strokeDashoffset={len * (1 - p)} />
      <polyline points={`${hx(0.5)},${hy(0.5)} ${x2},${y2} ${hx(-0.5)},${hy(-0.5)}`} fill="none" stroke={C.lo} strokeWidth={4} opacity={p > 0.95 ? 1 : 0} />
    </svg>
  );
};

export const Arch: React.FC<{total: number}> = ({total}) => {
  const f = useCurrentFrame();
  const {fps} = useVideoConfig();
  const t = f / fps;
  const frame = useIn(1.1, 16);
  const pulse = interpolate(t, [8.4, 8.8, 10.8, 11.2], [0, 1, 1, 0], clamp);
  return (
    <Stage total={total}>
      <div style={{position: 'absolute', top: 56, width: '100%', textAlign: 'center', fontSize: 50, fontWeight: 700, ...useIn(0.2)}}>
        判斷交給規則，說話交給車上的小模型
      </div>
      <Box x={70} y={360} w={340} h={250} at={0.5} title="車輛訊號" sub={'CO2・車溫・車速\n盲點訊號（模擬）・提問'} />
      <Arrow x1={420} y1={485} x2={560} y2={485} at={0.9} />
      <div style={{position: 'absolute', left: 570, top: 170, width: 780, height: 640, borderRadius: 28, border: `3px solid #5A5A62`, boxSizing: 'border-box', ...frame}}>
        <div style={{position: 'absolute', left: 30, top: 18, fontSize: 32, fontWeight: 700, color: C.lo}}>AI Box（車上・離線）</div>
        <div style={{position: 'absolute', right: 30, top: 24, fontSize: 26, color: C.lo}}>Qwen2.5-1.5B 在手機上執行</div>
      </div>
      <Box x={630} y={250} w={660} h={150} at={1.5} hi={[2.0, 3.5]} title="規則引擎：決定做什麼" />
      <Box x={630} y={425} w={660} h={150} at={1.7} hi={[3.5, 5.8]} title="端側小模型：講成一句話" />
      <Box x={630} y={600} w={660} h={150} at={1.9} title="知識庫：回答停車提問" />
      <Arrow x1={1360} y1={400} x2={1470} y2={330} at={5.8} />
      <Arrow x1={1360} y1={580} x2={1470} y2={650} at={5.9} />
      <Box x={1480} y={220} w={380} h={220} at={6.0} hi={[8.4, 11.2]} title="儀表（手機）" sub={'時速・檔位・油量\n盲點圖示'} />
      <Box x={1480} y={540} w={380} h={220} at={6.3} hi={[8.4, 11.2]} title="中控（平板）" sub={'告知卡片・語音\n停車提問'} />
      <div style={{position: 'absolute', left: 570, top: 826, width: 780, textAlign: 'center', fontSize: 30, fontWeight: 700,
        color: C.red, opacity: interpolate(t, [8.4, 8.9], [0, 1], clamp), textShadow: `0 0 ${18 * pulse}px rgba(214,48,49,0.6)`}}>
        安全警示（盲點）：規則直出，不等模型、不靠網路
      </div>
      <Box x={600} y={872} w={720} h={74} at={11.4} title="雲端增強（規劃中，有網路才用）" dashed color="#5A5A62" />
    </Stage>
  );
};
