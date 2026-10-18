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
    print 'Local ad-hoc build only: not signed for distribution or notarized.'
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
