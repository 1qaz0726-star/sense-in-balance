"""把網頁版中控（build/web）打包進 APK 的 assets/web/，並更新 pubspec.yaml 的資產清單。

用法（在專案根目錄）：
    flutter build web -t lib/main_web.dart --release --no-web-resources-cdn --pwa-strategy=none
    python tool/pack_web.py
    flutter build apk --release

手機開「儀表＋AI Box」時，Hub 用 rootBundle 讀 assets/web/ 提供給 iPad。
不打包：assets/assets/web/（上一版自己被當成資產又打包一次）、skwasm*（只有 --wasm 建置才用）、*.symbols（除錯符號）、NOTICES、service worker。
"""
import os
import re
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'build', 'web')
DST = os.path.join(ROOT, 'assets', 'web')
SKIP = re.compile(r'^assets/assets/web/|(^|/)(skwasm[^/]*|[^/]*\.symbols|NOTICES|flutter_service_worker\.js|\.last_build_id)$')

if not os.path.exists(os.path.join(SRC, 'main.dart.js')):
    raise SystemExit('找不到 build/web/main.dart.js，先跑 flutter build web -t lib/main_web.dart')

shutil.rmtree(DST, ignore_errors=True)
dirs, total = set(), 0
for base, _, files in os.walk(SRC):
    for f in files:
        rel = os.path.relpath(os.path.join(base, f), SRC).replace(os.sep, '/')
        if SKIP.search(rel):
            continue
        out = os.path.join(DST, rel)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        shutil.copy2(os.path.join(base, f), out)
        total += os.path.getsize(out)
        dirs.add(os.path.dirname('assets/web/' + rel) + '/')

block = '  # web-assets-begin（tool/pack_web.py 產生，不要手改）\n  assets:\n' + \
    ''.join(f'    - {d}\n' for d in sorted(dirs)) + '  # web-assets-end\n'
p = os.path.join(ROOT, 'pubspec.yaml')
y = open(p, encoding='utf-8').read()
if '# web-assets-begin' in y:
    y = re.sub(r'  # web-assets-begin.*?# web-assets-end\n', block, y, flags=re.S)
else:
    y = y.replace('  uses-material-design: true\n', '  uses-material-design: true\n' + block, 1)
open(p, 'w', encoding='utf-8').write(y)
print(f'assets/web：{len(dirs)} 個資料夾，{total / 1e6:.1f} MB')
