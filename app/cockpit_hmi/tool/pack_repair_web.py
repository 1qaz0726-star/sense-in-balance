"""Bundle the read-only companion without changing the original web UI.

flutter build web -t lib/main_repair_web.dart --output=build/repair_web --release --no-web-resources-cdn --pwa-strategy=none
python tool/pack_repair_web.py
"""
from pathlib import Path
import re
import shutil

from pack_web import update_assets_manifest

root=Path(__file__).resolve().parent.parent
source=root/'build'/'repair_web'
destination=root/'assets'/'repair_web'
assert destination.resolve().is_relative_to(root), 'Output must stay inside this app'
if not (source/'main.dart.js').is_file():
    raise SystemExit('Build main_repair_web.dart to build/repair_web first.')
skip=re.compile(r'(^|/)(skwasm[^/]*|[^/]*\.symbols|NOTICES|flutter_service_worker\.js|\.last_build_id)$|^assets/assets/(?:web|repair_web)/')
dirs=set()
total=0
for file in source.rglob('*'):
    if not file.is_file():continue
    relative=file.relative_to(source)
    if skip.search(relative.as_posix()):continue
    out=destination/relative
    out.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(file,out)
    dirs.add(out.parent.relative_to(root).as_posix()+'/')
    total+=file.stat().st_size
manifest=root/'pubspec.yaml'
content=update_assets_manifest(
    manifest.read_text('utf-8'), 'repair-web-assets', dirs)
manifest.write_text(content,'utf-8')
print(f'Repair web bundled: {len(dirs)} directories, {total/1e6:.1f} MB')
