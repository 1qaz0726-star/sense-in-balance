p = 'F:/tmp/edit/build.py'; s = open(p, encoding='utf-8').read()
R = [(" ('card', 'card_title', 0, 5.0,", " ('rmt', 'Title', 0, 150/30,"),
     (" ('card', 'card_team', 0, ND['N1'] + 0.8,", " ('rmt', 'Team', 0, 610/30,"),
     (" ('photo', 'photo', 0, 10.0,", " ('rmt', 'Problem', 0, 300/30,"),
     (" ('card', 'card_arch', 0, ND['N3'] + 0.8,", " ('rmt', 'Arch', 0, 405/30,"),
     (" ('card', 'card_end', 0, 8.0,", " ('rmt', 'End', 0, 240/30,"),
     ("感知有度_報名影片_v3.mp4", "感知有度_報名影片_v4.mp4")]
for a, b in R:
    assert a in s, a
    s = s.replace(a, b)
a = "    if kind == 'card':"
assert a in s
s = s.replace(a, """    if kind == 'rmt':
        out = f'{W}\\seg\\{i:02d}_rmt.mp4'
        cmd = FF + ['-i', f'F:\\remotion_hmi\\out\\mp4\\{src}.mp4', '-f', 'lavfi', '-t', f'{d}', '-i', 'anullsrc=r=48000:cl=stereo',
                    '-map', '0:v', '-map', '1:a', '-vf', 'fps=30,format=yuv420p', '-t', f'{d}'] + ENC + [out]
    elif kind == 'card':""", 1)
open(p, 'w', encoding='utf-8').write(s); print('ok')
