import os, json, urllib.request, uuid
env = os.environ  # 需要 GROQ_API_KEY 環境變數
VO = os.path.join('C:/Users/葉士愷/Documents/友達智慧座艙/錄製/20261007', '語音')
res = {}
for f in ['N1', 'N2', 'N3', 'N9']:
    b = uuid.uuid4().hex; data = open(os.path.join(VO, f + '.m4a'), 'rb').read(); parts = []
    for k, v in [('model', 'whisper-large-v3'), ('language', 'zh'), ('response_format', 'verbose_json'), ('timestamp_granularities[]', 'segment')]:
        parts.append(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    parts.append(f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="a.m4a"\r\nContent-Type: audio/mp4\r\n\r\n'.encode() + data + f'\r\n--{b}--\r\n'.encode())
    req = urllib.request.Request('https://api.groq.com/openai/v1/audio/transcriptions', data=b''.join(parts),
          headers={'Authorization': 'Bearer ' + env['GROQ_API_KEY'], 'Content-Type': 'multipart/form-data; boundary=' + b, 'User-Agent': 'curl/8'})
    r = json.load(urllib.request.urlopen(req)); res[f] = [(s['start'], s['end'], s['text']) for s in r['segments']]
    print(f); [print(f'  {a:5.2f}-{e:5.2f} {t}') for a, e, t in res[f]]
json.dump(res, open('F:/tmp/edit/vo_segments.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
