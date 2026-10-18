#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodebuild -project Clipboard.xcodeproj -scheme Clipboard -configuration Debug -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath .build/xcode CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES ONLY_ACTIVE_ARCH=YES build "$@"
