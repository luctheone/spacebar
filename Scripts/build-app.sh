#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
WORK="/private/tmp/spacebar-native-package"
APP="$WORK/SpaceBar.app"
"$SCRIPT_DIR/swift-package.sh" build -c release
BIN="$("$SCRIPT_DIR/swift-package.sh" build -c release --show-bin-path)"
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers" "$WORK/SpaceBar.iconset"
/usr/bin/install -m755 "$BIN/SpaceBar" "$APP/Contents/MacOS/SpaceBar"
/usr/bin/install -m755 "$BIN/spacebar-cli" "$APP/Contents/Helpers/spacebar"
/usr/bin/install -m644 "$PROJECT_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
SDK="${SPACEBAR_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}"
SDKROOT="$SDK" /usr/bin/swift -sdk "$SDK" -module-cache-path /private/tmp/spacebar-swift-build/clang-cache "$SCRIPT_DIR/generate-icon.swift" "$WORK/icon.png"
for n in 16 32 128 256 512; do
  /usr/bin/sips -z "$n" "$n" "$WORK/icon.png" --out "$WORK/SpaceBar.iconset/icon_${n}x${n}.png" >/dev/null
  double=$((n*2))
  /usr/bin/sips -z "$double" "$double" "$WORK/icon.png" --out "$WORK/SpaceBar.iconset/icon_${n}x${n}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$WORK/SpaceBar.iconset" -o "$APP/Contents/Resources/SpaceBar.icns"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/xattr -cr "$APP"
/usr/bin/codesign --force --sign - --timestamp=none "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
print -r -- "$APP"
