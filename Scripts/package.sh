#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/release
xcodebuild -project Clipboard.xcodeproj -scheme Clipboard -configuration Release -destination 'generic/platform=macOS' -derivedDataPath .build/universal 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
clipboard_app="$PWD/.build/universal/Build/Products/Release/Clipboard.app"
if [[ -n "${CLIPBOARD_SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$CLIPBOARD_SIGN_IDENTITY" "$clipboard_app"
    codesign --verify --strict --verbose=2 "$clipboard_app"
else
    codesign --force --sign - "$clipboard_app"
    print 'Ad-hoc signed: not Developer ID signed or notarized.'
fi
clipboard_zip="$PWD/.build/release/Clipboard.zip"
ditto -c -k --keepParent "$clipboard_app" "$clipboard_zip"
if [[ -n "${CLIPBOARD_NOTARY_PROFILE:-}" ]]; then
    [[ -n "${CLIPBOARD_SIGN_IDENTITY:-}" ]] || { print 'A Developer ID signing identity is required for notarization.'; exit 1; }
    xcrun notarytool submit "$clipboard_zip" --keychain-profile "$CLIPBOARD_NOTARY_PROFILE" --wait
    xcrun stapler staple "$clipboard_app"
    xcrun stapler validate "$clipboard_app"
    ditto -c -k --keepParent "$clipboard_app" "$clipboard_zip"
fi
(
    cd .build/release
    shasum -a 256 Clipboard.zip > Clipboard.zip.sha256
)
clipboard_architectures="$(xcrun lipo -archs "$clipboard_app/Contents/MacOS/Clipboard")"
[[ " $clipboard_architectures " == *" arm64 "* && " $clipboard_architectures " == *" x86_64 "* ]] || { print "Missing universal architecture"; exit 1; }
print "Prepared $clipboard_zip"

clipboard_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$clipboard_app/Contents/Info.plist")
[[ "$clipboard_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { print 'Invalid application version'; exit 1; }
clipboard_basename="Clipboard-v${clipboard_version}-universal"
cp "$clipboard_zip" ".build/release/${clipboard_basename}.zip"
clipboard_stage="$(mktemp -d "$PWD/.build/dmg-stage.XXXXXX")"
trap 'rm -rf "$clipboard_stage"' EXIT
ditto "$clipboard_app" "$clipboard_stage/Clipboard.app"
ln -s /Applications "$clipboard_stage/Applications"
print 'Drag Clipboard.app into Applications. This build is ad-hoc signed unless BUILD-INFO.json states otherwise. See the GitHub release notes for signing status and installation guidance.' > "$clipboard_stage/Read me.txt"
hdiutil create -volname "Clipboard $clipboard_version" -srcfolder "$clipboard_stage" -ov -format UDZO ".build/release/${clipboard_basename}.dmg"
hdiutil verify ".build/release/${clipboard_basename}.dmg"
export CLIPBOARD_BUILD_VERSION="$clipboard_version"
python3 - <<'PYINFO'
import json, os, subprocess
from pathlib import Path

def output(*args):
    return subprocess.check_output(args, text=True).strip()

info = {
    "version": os.environ["CLIPBOARD_BUILD_VERSION"],
    "source_commit": output("git", "rev-parse", "HEAD"),
    "working_tree_clean": not bool(output("git", "status", "--porcelain")),
    "architectures": ["arm64", "x86_64"],
    "minimum_macos": "14.0",
    "xcode": output("xcodebuild", "-version"),
    "signing": "developer-id" if os.environ.get("CLIPBOARD_SIGN_IDENTITY") else "ad-hoc",
    "notarized": bool(os.environ.get("CLIPBOARD_NOTARY_PROFILE")),
}
Path(".build/release/BUILD-INFO.json").write_text(json.dumps(info, indent=2) + "\n")
PYINFO
(
    cd .build/release
    shasum -a 256 "${clipboard_basename}.zip" "${clipboard_basename}.dmg" BUILD-INFO.json > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
)
print "Prepared release assets for v$clipboard_version"
