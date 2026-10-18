#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
Scripts/sparkle-tools.sh
clipboard_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' ClipboardApp/Info.plist)
clipboard_feed="$(mktemp -d "$PWD/.build/feed.XXXXXX")"
trap 'rm -rf "$clipboard_feed"' EXIT
clipboard_zip="Clipboard-v${clipboard_version}-universal.zip"
cp ".build/release/$clipboard_zip" "$clipboard_feed/"
cp "docs/releases/v${clipboard_version}.md" "$clipboard_feed/${clipboard_zip%.zip}.md"
clipboard_args=(--download-url-prefix "https://github.com/aagzamov-dev/Clipboard_macos/releases/download/v${clipboard_version}/" --link https://github.com/aagzamov-dev/Clipboard_macos --embed-release-notes --maximum-deltas 0)
if [[ -n "${SPARKLE_EDDSA_PRIVATE_KEY:-}" ]]; then
    print -rn -- "$SPARKLE_EDDSA_PRIVATE_KEY" | .build/sparkle-tools/bin/generate_appcast --ed-key-file - "${clipboard_args[@]}" "$clipboard_feed"
else
    .build/sparkle-tools/bin/generate_appcast --account local.clipboard.Clipboard "${clipboard_args[@]}" "$clipboard_feed"
fi
cp "$clipboard_feed/appcast.xml" .build/release/appcast.xml
(
    cd .build/release
    shasum -a 256 "Clipboard-v${clipboard_version}-universal.zip" "Clipboard-v${clipboard_version}-universal.dmg" BUILD-INFO.json appcast.xml > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
)

python3 Scripts/verify-updates.py
