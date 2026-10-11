# 成品音軌驗證：依時間軸把每一句旁白／車內語音切出來，逐段 Whisper，和預期文字比對
import json, os, subprocess, urllib.request, uuid, difflib, sys
FINAL = r'C:\Users\葉士愷\Documents\友達智慧座艙\錄製\成品\感知有度_報名影片_v4.mp4'
TL = json.load(open(r'F:\tmp\edit\timeline.json', encoding='utf-8'))
env = os.environ  # 需要 GROQ_API_KEY 環境變數

def whisper(path):
    b = uuid.uuid4().hex; data = open(path, 'rb').read(); parts = []
    for k, v in [('model', 'whisper-large-v3'), ('language', 'zh'), ('response_format', 'json')]:
        parts.append(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    parts.append(f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="a.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode() + data + f'\r\n--{b}--\r\n'.encode())
    req = urllib.request.Request('https://api.groq.com/openai/v1/audio/transcriptions', data=b''.join(parts),
          headers={'Authorization': 'Bearer ' + env['GROQ_API_KEY'], 'Content-Type': 'multipart/form-data; boundary=' + b, 'User-Agent': 'curl/8'})
    return json.load(urllib.request.urlopen(req))['text']

# 把連續的字幕併回一句（同一段旁白）
groups = []
for st, a, b, txt in TL['events']:
    if st in ('Label', 'Note', 'Tag'): continue
    txt = txt.replace('（車內語音）', '')
    if groups and st == 'Sub' and groups[-1][0] == 'Sub' and abs(groups[-1][2] - a) < 0.05:
        groups[-1][2] = b; groups[-1][3] += txt
    else:
        groups.append([st, a, b, txt])

import re, opencc
_cc = opencc.OpenCC('s2t')
norm = lambda s: _cc.convert(s) if False else re.sub(r'[\s，。；：、,.!?！？（）()A-Za-z0-9]', '', _cc.convert(s))
_unused = lambda s: re.sub(r'[\s，。；：、,.!?！？（）()A-Za-z0-9]', '', s)
bad = 0
for i, (st, a, b, txt) in enumerate(groups):
    wav = rf'F:\tmp\edit\chk_{i:02d}.wav'
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', f'{max(0,a-0.2):.2f}', '-to', f'{b+0.3:.2f}', '-i', FINAL, '-vn', '-ac', '1', '-ar', '16000', wav], check=True)
    got = whisper(wav)
    r = difflib.SequenceMatcher(None, norm(txt), norm(got)).ratio()
    flag = 'OK ' if r >= 0.6 else 'BAD'
    if r < 0.6: bad += 1
    print(f'{flag} {r:.2f} [{st} {a:6.1f}-{b:6.1f}] 預期：{txt[:28]}｜聽到：{got[:28]}')
print('不符段數', bad, '/', len(groups))
