#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
SDK="${SPACEBAR_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}"
if [[ ! -d "$SDK" ]]; then SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"; fi
BUILD_ROOT="${SPACEBAR_BUILD_ROOT:-/private/tmp/spacebar-swift-build}"
/bin/mkdir -p "$BUILD_ROOT/clang-cache" "$BUILD_ROOT/package-cache"
export SDKROOT="$SDK"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/clang-cache"
COMMAND="$1"
shift
exec /usr/bin/swift "$COMMAND" --package-path "$PROJECT_DIR" --scratch-path "$BUILD_ROOT/build" --cache-path "$BUILD_ROOT/package-cache" --sdk "$SDK" "$@"
