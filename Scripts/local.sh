#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
clipboard_arch="$(uname -m)"
xcodebuild -project Clipboard.xcodeproj -scheme Clipboard -configuration Release -destination "platform=macOS,arch=$clipboard_arch" -derivedDataPath .build/local-build ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
clipboard_stage="$(mktemp -d "$PWD/.build/local-stage.XXXXXX")"
trap '[[ -z "$clipboard_stage" ]] || rm -rf "$clipboard_stage"' EXIT
ditto .build/local-build/Build/Products/Release/Clipboard.app "$clipboard_stage/Clipboard.app"
Scripts/sign-app.sh "$clipboard_stage/Clipboard.app"
codesign --verify --strict "$clipboard_stage/Clipboard.app"
ditto -c -k --keepParent "$clipboard_stage/Clipboard.app" "$clipboard_stage/Clipboard.zip"
(
    cd "$clipboard_stage"
    shasum -a 256 Clipboard.zip > Clipboard.zip.sha256
)
python3 - <<'PYCHECK'
from pathlib import Path
import re, subprocess
current = (Path('.build/local') / 'Clipboard.app').resolve()
result = subprocess.run(['pgrep', '-fl', '/Clipboard.app/Contents/MacOS/Clipboard'], capture_output=True, text=True)
if result.returncode not in (0, 1):
    raise SystemExit('Unable to check running copies. Existing local app was preserved.')
paths = re.findall(r'^\d+ (/.+?/Clipboard\.app)/Contents/MacOS/Clipboard(?:\s|$)', result.stdout, re.M)
if any(Path(path).resolve() == current for path in paths):
    raise SystemExit('Quit the current .build/local/Clipboard.app before replacing it. Existing app was preserved.')
PYCHECK
[[ ! -L .build/local ]] || { print 'Refusing to replace a linked output directory.'; exit 1; }
rm -rf .build/local
mv "$clipboard_stage" .build/local
clipboard_stage=""
python3 - <<'PYCLEAN'
from pathlib import Path
import os, re, shutil, subprocess
build = Path('.build').resolve()
current = build / 'local' / 'Clipboard.app'
processes = subprocess.run(['pgrep', '-fl', '/Clipboard.app/Contents/MacOS/Clipboard'], capture_output=True, text=True)
if processes.returncode not in (0, 1):
    raise SystemExit('Local build is ready; unable to verify running copies, so cleanup was skipped.')
running = {Path(match).resolve() for match in re.findall(r'^\d+ (/.+?/Clipboard\.app)/Contents/MacOS/Clipboard(?:\s|$)', processes.stdout, re.M)}
for directory, names, _ in os.walk(build, followlinks=False):
    if 'Clipboard.app' not in names:
        continue
    app = Path(directory) / 'Clipboard.app'
    names.remove('Clipboard.app')
    if app.resolve() == current or app.resolve() in running:
        continue
    if app.is_symlink():
        app.unlink()
    else:
        shutil.rmtree(app)
for name in ('release', 'published'):
    folder = build / name
    if any(app.is_relative_to(folder) for app in running):
        continue
    if folder.is_symlink():
        folder.unlink()
    elif folder.exists():
        shutil.rmtree(folder)
print('Current local app and ZIP are in .build/local. Obsolete generated copies were removed; history and installed apps were untouched.')
PYCLEAN
