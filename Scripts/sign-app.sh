#!/bin/zsh
set -euo pipefail
clipboard_app="$1"
clipboard_identity="${CLIPBOARD_SIGN_IDENTITY:--}"
clipboard_options=()
if [[ "$clipboard_identity" != '-' ]]; then clipboard_options=(--options runtime --timestamp); fi
clipboard_framework="$clipboard_app/Contents/Frameworks/Sparkle.framework"
if [[ -d "$clipboard_framework" ]]; then
    while IFS= read -r clipboard_binary; do
        codesign --force "${clipboard_options[@]}" --sign "$clipboard_identity" "$clipboard_binary"
    done < <(find "$clipboard_framework/Versions/B" -type f -perm -111 | while IFS= read -r candidate; do file "$candidate" | rg -q 'Mach-O' && print -r -- "$candidate"; done)
    while IFS= read -r clipboard_bundle; do
        codesign --force "${clipboard_options[@]}" --sign "$clipboard_identity" "$clipboard_bundle"
    done < <(find "$clipboard_framework/Versions/B" -depth -type d \( -name '*.xpc' -o -name '*.app' \))
    codesign --force "${clipboard_options[@]}" --sign "$clipboard_identity" "$clipboard_framework"
fi
clipboard_helper="$clipboard_app/Contents/Helpers/ClipboardPasteCheck.app"
if [[ -d "$clipboard_helper" ]]; then
    codesign --force "${clipboard_options[@]}" --sign "$clipboard_identity" "$clipboard_helper"
fi
codesign --force "${clipboard_options[@]}" --sign "$clipboard_identity" "$clipboard_app"
codesign --verify --deep --strict "$clipboard_app"
