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
SKIP = re.compile(r'^assets/assets/(?:web|repair_web)/|(^|/)(skwasm[^/]*|[^/]*\.symbols|NOTICES|flutter_service_worker\.js|\.last_build_id)$')


def update_assets_manifest(content, marker, directories):
    """Replace generated web entries, preserving the one base assets list.

    Original and repair web bundles are mutually exclusive. Older packers put
    an assets key (and sometimes OFL) inside their markers; migrate those base
    entries outside the generated block without touching the fonts section.
    """
    preserved = []
    generated = re.compile(
        r'^  # (web-assets|repair-web-assets)-begin[^\n]*\n'
        r'.*?^  # \1-end[^\n]*(?:\n|$)', re.M | re.S)

    def remove_generated(match):
        for entry in re.findall(r'^    - ([^\n]+)', match.group(), re.M):
            path = entry.strip().strip('\"\x27')
            if not re.match(r'^assets/(?:web|repair_web)(?:/|$)', path):
                if entry not in preserved:
                    preserved.append(entry)
        return ''

    content = generated.sub(remove_generated, content)
    keys = list(re.finditer(r'^  assets:[ \t]*\n', content, re.M))
    if len(keys) > 1:
        raise SystemExit('pubspec.yaml still has multiple Flutter assets keys.')
    if not keys:
        anchor = re.search(r'^  uses-material-design: true[^\n]*\n', content, re.M)
        anchor = anchor or re.search(r'^flutter:[ \t]*\n', content, re.M)
        if anchor is None:
            raise SystemExit('pubspec.yaml has no Flutter section.')
        content = content[:anchor.end()] + '  assets:\n' + content[anchor.end():]
    assets = re.search(
        r'^  assets:[ \t]*\n(?:[ \t]*\n| {4}[^\n]*\n)*', content, re.M)
    existing = set(re.findall(r'^    - ([^\n]+)', content, re.M))
    base = ''.join(f'    - {entry}\n' for entry in preserved if entry not in existing)
    block = f'  # {marker}-begin（packer 產生，不要手改）\n' + \
        ''.join(f'    - {directory}\n' for directory in sorted(directories)) + \
        f'  # {marker}-end\n'
    return content[:assets.end()] + base + block + content[assets.end():]


def main():
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

    p = os.path.join(ROOT, 'pubspec.yaml')
    with open(p, encoding='utf-8') as manifest:
        content = update_assets_manifest(manifest.read(), 'web-assets', dirs)
    with open(p, 'w', encoding='utf-8') as manifest:
        manifest.write(content)
    print(f'assets/web：{len(dirs)} 個資料夾，{total / 1e6:.1f} MB')


if __name__ == '__main__':
    main()
