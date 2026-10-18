#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
clipboard_tools="$PWD/.build/sparkle-tools"
mkdir -p "$clipboard_tools"
clipboard_archive="$clipboard_tools/Sparkle-2.10.0.tar.xz"
if [[ ! -f "$clipboard_archive" ]]; then
    curl --fail --location --retry 3 https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz -o "$clipboard_archive"
fi
print "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c  $clipboard_archive" | shasum -a 256 -c -
tar -xJf "$clipboard_archive" -C "$clipboard_tools"
