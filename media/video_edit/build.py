# 報名影片剪接：分段渲染 → 串接 → 旁白混音 → 燒字幕
import json, os, re, subprocess, sys
SRC = r'C:\Users\葉士愷\Documents\友達智慧座艙\錄製\20261007'
VO = SRC + r'\語音'
W = r'F:\tmp\edit'
OUT = r'C:\Users\葉士愷\Documents\友達智慧座艙\錄製\成品'
os.makedirs(OUT, exist_ok=True); os.makedirs(W + r'\seg', exist_ok=True)
V = {'02': 'VID_20261009_233616_0002.MP4', '04': 'VID_20261009_233843_0004.MP4',
     '05': 'VID_20261009_233913_0005.MP4', '08': 'VID_20261010_000410_0008.MP4',
     '09': 'VID_20261010_000549_0009.MP4'}
CROP = {'02a': (380, 380, 3164, 1780), '02b': (440, 343, 3230, 1817), '02c': (470, 360, 3200, 1800),
        '04': (500, 300, 3200, 1800), '05': (800, 380, 3040, 1710), '08p': (0, 0, 3840, 2160),
        '08': (384, 150, 3456, 1944), '09': (380, 630, 2720, 1530)}

def dur(p):
    return float(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', p]).decode().strip())

N = {k: VO + '\\' + k + '.m4a' for k in ['提案名稱', 'N1', 'N2', 'N3', 'N4', 'N5a', 'N5b', 'N6', 'N7', 'N8', 'N9']}
ND = {k: dur(v) for k, v in N.items()}

# 字幕稿（定稿）
TXT = {
 '提案名稱': '該說才說，會自己動手的安靜座艙 AI',
 'N1': '大家好，我們是感知有度 Sense in Balance。我是葉士愷，負責標註資料以及程式開發。我們的隊員有黃昱羲，負責感知處理流程與 Android HMI；還有胡馨，負責提案簡報以及驗證證據整理。',
 'N2': '現在的車越來越愛說話：提醒、建議、通知，一個接一個。但很多事，駕駛不需要知道，也不該由駕駛去做。',
 'N3': '我們的做法是：判斷交給規則，說話交給車上的小模型。系統能自己做的，就自己做；只有在有代價、或是有危險的時候，才用一句話告訴你。',
 'N4': '一切正常時，儀表只留時速、檔位、油量。沒有提示，就是最好的提示。',
 'N5a': '車內二氧化碳正在上升。',
 'N5b': '系統直接切成外循環，不叫駕駛動手。車外 34 度，車內會變熱，這是駕駛感覺得到的代價，所以才說這一句。這句話，是車上的小模型即時講出來的。',
 'N6': '把網路關掉，系統照樣運作。模型在車上，知識庫也在車上。',
 'N7': '危險的事不等模型，規則直接發出警示，8 個字以內。方向用圖示與紅邊，一眼就懂。',
 'N8': '停好車才開放提問，行駛中不能操作螢幕。問答刻意不交給模型，而是查車上的知識庫；查不到就說查不到，不會亂編。',
 'N9': '下一步，有網路時由雲端理解問題，再由知識庫找答案；沒有網路，一樣能用。判斷用規則，可以驗證；說話用小模型，留在車上。',
}

# 段落：(種類, 來源, 起, 迄, 裁切, 原音增益, 情境標籤, [旁白(檔, 段內延遲)], [車內語音字幕(文字, 段內起, 段內迄)], [框選(x,y,w,h,段內起,段內迄)])
S = [
 ('rmt', 'Title', 0, 150/30, None, 0, None, [('提案名稱', 0.5)], [], []),
 ('rmt', 'Team', 0, 610/30, None, 0, None, [('N1', 0.3)], [], []),
 ('rmt', 'Problem', 0, 300/30, None, 0, None, [('N2', 0.3)], [], []),
 ('rmt', 'Arch', 0, 405/30, None, 0, None, [('N3', 0.3)], [], []),
 ('vid', '02', 10.8, 18.3, '02a', 0, '情境 A｜一切正常：系統不說話', [('N4', 0.3)], [], [(40, 530, 690, 390, 0, 99), (760, 60, 1130, 850, 0, 99)]),
 ('vid', '02', 18.6, 22.6, '02a', 0, '情境 B｜車內 CO2 慢慢上升（模擬訊號）', [('N5a', 0.1)], [], []),
 ('vid', '02', 25.5, 32.0, '02a', 1.3, '情境 B｜系統自動切換外循環', [], [('已自動切換外循環，會稍熱', 2.5, 5.8)], []),
 ('vid', '04', 12.0, 24.0, '04', 0, '情境 B｜近拍：卡片標明端側模型、4.6 秒、離線', [('N5b', 0.2)], [], [(320, 800, 470, 80, 3.5, 12.0)]),
 ('vid', '02', 32.0, 35.0, '02a', 0, '情境 B｜這句話由車上的小模型講出來', [], [], []),
 ('vid', '08', 0.5, 1.4, '08p', 0, '斷網測試｜在鏡頭前關閉行動數據', [], [], []),
 ('freeze', '08', 1.4, 2.9, '08p', 0, '斷網測試｜行動數據：關　Wi-Fi：關', [], [], [(905, 535, 120, 105, 0, 9), (390, 375, 130, 105, 0, 9)]),
 ('vid', '08', 1.4, 8.0, '08p', 0, '斷網測試｜手機已沒有網路（平板經手機熱點區網連線）', [('N6', 0.1)], [], []),
 ('vid', '08', 31.0, 38.0, '08', 6.5, '斷網後（同一段錄影）｜端側模型照樣措辭，小字：離線', [], [('已經自動切換外循環，會稍微變熱', 2.0, 4.8)], []),
 ('vid', '08', 58.0, 66.0, '08', 6.5, '斷網後（同一段錄影）｜知識庫照樣回答，小字：離線作答', [], [('可以，提示與問答都在車上運算，不需要網路', 1.5, 7.8)], []),
 ('vid', '02', 35.5, 41.5, '02a', 1.3, '情境 C｜盲點：先打方向燈，再注入模擬來車訊號', [], [('右後方有機車', 2.4, 4.8)], []),
 ('vid', '02', 45.5, 51.0, '02b', 1.3, '情境 C｜盲點警示：規則直出，不等模型', [], [('左後方有自行車', 0.6, 3.0)], []),
 ('vid', '09', 21.0, 32.0, '09', 0, '情境 C｜儀表特寫：紅邊與來車圖示在同一側', [('N7', 0.5)], [], []),
 ('vid', '02', 51.0, 58.0, '02c', 0, '情境 D｜停車（P 檔）才開放提問', [('N8', 0.0)], [], []),
 ('vid', '05', 19.0, 25.0, '05', 0, '情境 D｜停車才能打字提問', [], [], []),
 ('vid', '05', 36.0, 45.0, '05', 1.3, '情境 D｜答案來自車上的知識庫', [], [('車內二氧化碳累積會讓人昏沉，定時開外循環換氣', 3.0, 8.5)], []),
 ('vid', '02', 70.7, 76.0, '02c', 1.3, '情境 D｜故意問知識庫外的題：查不到就說查不到', [], [('這個我查不到，請參考車主手冊', 1.3, 4.8)], []),
 ('vid', '02', 77.5, 84.0, '02c', 0, None, [('N9', 0.3)], [], []),
 ('rmt', 'End', 0, 240/30, None, 0, None, [], [], []),
]

FF = ['ffmpeg', '-v', 'error', '-y']
ENC = ['-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-pix_fmt', 'yuv420p', '-r', '30',
       '-c:a', 'aac', '-b:a', '192k', '-ar', '48000', '-ac', '2']

def render(i, s):
    kind, src, a, b, crop, gain, label, vo, sysv, boxes = s
    d = b - a
    out = f'{W}\\seg\\{i:02d}.mp4'
    if kind == 'rmt':
        out = os.path.join(W, 'seg', f'{i:02d}_rmt.mp4')
        cmd = FF + ['-i', os.path.join('F:/remotion_hmi/out/mp4', src + '.mp4'), '-f', 'lavfi', '-t', f'{d}', '-i', 'anullsrc=r=48000:cl=stereo',
                    '-map', '0:v', '-map', '1:a', '-vf', 'fps=30,format=yuv420p', '-t', f'{d}'] + ENC + [out]
    elif kind == 'card':
        vf = f'scale=1920:1080,fps=30,fade=t=in:st=0:d=0.5,fade=t=out:st={d-0.5}:d=0.5,format=yuv420p'
        cmd = FF + ['-loop', '1', '-t', f'{d}', '-i', f'{W}\\{src}.png', '-f', 'lavfi', '-t', f'{d}', '-i', 'anullsrc=r=48000:cl=stereo',
                    '-vf', vf, '-shortest'] + ENC + [out]
    elif kind == 'photo':
        n = int(d * 30)
        vf = (f'crop=2987:1680:420:480,scale=3840:2160,zoompan=z=\'1+0.10*on/{n}\':x=\'iw/2-(iw/zoom/2)\':y=\'ih/2-(ih/zoom/2)\':d={n}:s=1920x1080:fps=30,'
              f'fade=t=in:st=0:d=0.5,fade=t=out:st={d-0.5}:d=0.5,format=yuv420p')
        cmd = FF + ['-i', f'{SRC}\\IMG_20261009_233530_0001.JPG', '-f', 'lavfi', '-t', f'{d}', '-i', 'anullsrc=r=48000:cl=stereo',
                    '-vf', vf, '-frames:v', str(n), '-shortest'] + ENC + [out]
    elif kind == 'freeze':
        x, y, w, h = CROP[crop]
        vf = f'crop={w}:{h}:{x}:{y},scale=1920:1080:flags=lanczos,loop=loop=-1:size=1:start=0,trim=duration={d},setpts=N/30/TB'
        for (bx, by, bw, bh, t0, t1) in boxes:
            vf += f",drawbox=x={bx}:y={by}:w={bw}:h={bh}:color=0x78C8AA@0.95:t=6"
        vf += ',format=yuv420p'
        cmd = FF + ['-ss', f'{a}', '-i', f'{SRC}\{V[src]}', '-f', 'lavfi', '-t', f'{d}', '-i', 'anullsrc=r=48000:cl=stereo',
                    '-map', '0:v', '-map', '1:a', '-vf', vf, '-t', f'{d}', '-shortest'] + ENC + [out]
    else:
        x, y, w, h = CROP[crop]
        vf = f'crop={w}:{h}:{x}:{y},scale=1920:1080:flags=lanczos,fps=30'
        vf += ',format=yuv420p'   # 框選改在馬賽克之後畫（綠框會被當成面紙色點）
        if gain > 0:
            cmd = FF + ['-ss', f'{a}', '-t', f'{d}', '-i', f'{SRC}\\{V[src]}', '-vf', vf,
                        '-af', f'highpass=f=120,volume={gain}'] + ENC + [out]
        else:
            cmd = FF + ['-ss', f'{a}', '-t', f'{d}', '-i', f'{SRC}\\{V[src]}', '-f', 'lavfi', '-t', f'{d}', '-i', 'anullsrc=r=48000:cl=stereo',
                        '-map', '0:v', '-map', '1:a', '-vf', vf, '-shortest'] + ENC + [out]
    if not os.path.exists(out) or '--force' in sys.argv:
        subprocess.run(cmd, check=True)
    if kind in ('vid', 'photo'):
        mout = os.path.join(W, 'segm', f'{i:02d}.mp4')
        if not os.path.exists(mout):
            subprocess.run([sys.executable, os.path.join(W, 'mosaic.py'), out, mout], check=True)
        out = mout
    if kind == 'vid' and boxes:
        bout = os.path.join(W, 'segm', f'{i:02d}_box.mp4')
        if not os.path.exists(bout):
            bvf = ','.join(f"drawbox=x={bx}:y={by}:w={bw}:h={bh}:color=0x78C8AA@0.95:t=5:enable='between(t,{t0},{t1})'"
                           for (bx, by, bw, bh, t0, t1) in boxes)
            subprocess.run(FF + ['-i', out, '-vf', bvf, '-c:a', 'copy', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18',
                                 '-pix_fmt', 'yuv420p', bout], check=True)
        out = bout
    return out, d

def ts(t):
    h = int(t // 3600); m = int(t % 3600 // 60); s = t % 60
    return f'{h}:{m:02d}:{s:05.2f}'

def chunks(text, maxlen=20):
    parts = re.split(r'(?<=[，。；：、！？])', text)
    out, cur = [], ''
    for p in parts:
        if not p: continue
        if len(cur) + len(p) <= maxlen: cur += p
        else:
            if cur: out.append(cur)
            cur = p
    if cur: out.append(cur)
    return [c.rstrip('，。；：、') for c in out]

def main():
    segs, t = [], 0.0
    vo_place, events = [], []
    for i, s in enumerate(S):
        out, d = render(i, s)
        segs.append(out)
        kind, src, a, b, crop, gain, label, vo, sysv, boxes = s
        if label:
            events.append(('Label', t + 0.2, t + d - 0.1, label))
            if label.startswith('情境 A'):
                events.append(('Tag', t + 0.2, t + d - 0.1, r'{\an1\pos(46,515)}駕駛儀表（手機）'))
                events.append(('Tag', t + 0.2, t + d - 0.1, r'{\an9\pos(1886,920)}中控（iPad）'))
            if label.startswith('情境 C'):
                events.append(('Note', t + 0.2, t + d - 0.1, '盲點事件為模擬注入，尚未接攝影機'))
        for (k, off) in vo:
            st = t + off; vo_place.append((N[k], st))
            cs = chunks(TXT[k]); total = sum(len(c) for c in cs); cur = st
            for c in cs:
                dd = ND[k] * len(c) / total
                events.append(('Sub', cur, cur + dd, c)); cur += dd
        for (txt, t0, t1) in sysv:
            events.append(('Sys', t + t0, t + t1, '（車內語音）' + txt))
        t += d
    total = t
    print(f'總長 {total:.1f} 秒')
    # 串接
    with open(W + r'\list.txt', 'w', encoding='utf-8') as f:
        for p in segs: f.write(f"file '{p}'\n")
    subprocess.run(FF + ['-f', 'concat', '-safe', '0', '-i', W + r'\list.txt', '-c', 'copy', W + r'\joined.mp4'], check=True)
    # 字幕
    ass = ['[Script Info]', 'ScriptType: v4.00+', 'PlayResX: 1920', 'PlayResY: 1080', '', '[V4+ Styles]',
           'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding',
           'Style: Sub,Noto Sans TC,52,&H00FFFFFF,&H00FFFFFF,&H70000000,&H70000000,1,0,0,0,100,100,1,0,3,10,0,2,80,80,46,1',
           'Style: Sys,Noto Sans TC,50,&H00AAC878,&H00AAC878,&H70000000,&H70000000,1,0,0,0,100,100,1,0,3,10,0,2,80,80,46,1',
           'Style: Tag,Noto Sans TC,44,&H00FFFFFF,&H00FFFFFF,&H30785A28,&H30785A28,1,0,0,0,100,100,1,0,3,12,0,7,0,0,0,1',
           'Style: Note,Noto Sans TC,36,&H00FFFFFF,&H00FFFFFF,&H40000000,&H40000000,1,0,0,0,100,100,1,0,3,10,0,9,48,48,40,1',
           'Style: Label,Noto Sans TC,36,&H00F4F2F2,&H00F4F2F2,&H00000000,&HA0000000,1,0,0,0,100,100,1,0,3,10,0,7,48,48,40,1',
           '', '[Events]', 'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text']
    for (st, a, b, txt) in events:
        ass.append(f'Dialogue: 0,{ts(a)},{ts(b)},{st},,0,0,0,,{txt}')
    open(W + r'\subs.ass', 'w', encoding='utf-8-sig').write('\n'.join(ass))
    json.dump({'total': total, 'events': events}, open(W + r'\timeline.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    # 旁白軌
    inputs, flt = [], []
    for j, (p, st) in enumerate(vo_place):
        inputs += ['-i', p]
        ms = int(st * 1000)
        flt.append(f'[{j+1}:a]aresample=48000,aformat=channel_layouts=stereo,highpass=f=80,volume=2.2,adelay={ms}|{ms}[v{j}]')
    mix = ''.join(f'[v{j}]' for j in range(len(vo_place)))
    flt.append(f'[0:a]volume=1.0[c]')
    flt.append(f'[c]{mix}amix=inputs={len(vo_place)+1}:normalize=0:duration=first,loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000[aout]')
    # 分三步：①混音成 wav ②影片燒字幕（無音軌）③合併。放在同一個 filtergraph 會讓旁白錯位（2026-10-08 實測）
    subprocess.run(FF + ['-i', W + r'\joined.mp4'] + inputs + ['-filter_complex', ';'.join(flt), '-map', '[aout]',
                   '-ar', '48000', W + r'\mix.wav'], check=True)
    subprocess.run(FF + ['-i', W + r'\joined.mp4', '-vf', 'subtitles=subs.ass:fontsdir=fonts', '-an',
                   '-c:v', 'libx264', '-preset', 'medium', '-crf', '19', '-pix_fmt', 'yuv420p', '-r', '30', W + '/vsubs.mp4'],
                   check=True, cwd=W)
    subprocess.run(FF + ['-i', W + '/vsubs.mp4', '-i', W + r'\mix.wav', '-map', '0:v', '-map', '1:a', '-c:v', 'copy',
                   '-c:a', 'aac', '-b:a', '192k', '-shortest', '-movflags', '+faststart', OUT + r'\感知有度_報名影片_v4.mp4'], check=True)
    print('done', OUT + r'\感知有度_報名影片_v4.mp4')

main()
