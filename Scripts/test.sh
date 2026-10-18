#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/modules"
swift test --disable-sandbox --package-path Packages/ClipboardCore --scratch-path .build/core --cache-path .build/cache --config-path .build/config --security-path .build/security "$@"
swift test --disable-sandbox --scratch-path .build/platform --cache-path .build/cache --config-path .build/config --security-path .build/security "$@"
