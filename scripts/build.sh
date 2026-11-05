#!/bin/bash
# Builds build/Mando.app and build/Mando.driver (universal: arm64 + x86_64).
#
#   ./scripts/build.sh                    # ad-hoc signed, for local testing
#   SIGN_ID="Developer ID Application: …" ./scripts/build.sh   # release signing
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
SIGN_ID="${SIGN_ID:--}"
MIN_OS=14.0
ARCHS=(arm64 x86_64)
OUT=build
rm -rf "$OUT/Mando.app" "$OUT/Mando.driver" "$OUT/obj"
mkdir -p "$OUT/obj"

sign() { # path [entitlements]
  local args=(--force --timestamp --options runtime --sign "$SIGN_ID")
  [[ "$SIGN_ID" == "-" ]] && args=(--force --sign -)
  [[ $# -gt 1 ]] && args+=(--entitlements "$2")
  codesign "${args[@]}" "$1"
}

echo "==> Driver"
DRV="$OUT/Mando.driver/Contents"
mkdir -p "$DRV/MacOS"
clang -std=c11 -O2 -Wall -Wextra -mmacosx-version-min=$MIN_OS ${ARCHS[@]/#/-arch } \
  -bundle -framework CoreFoundation -framework CoreAudio \
  Driver/MandoDriver.c -o "$DRV/MacOS/Mando"
sed "s/__VERSION__/$VERSION/g" Driver/Info.plist > "$DRV/Info.plist"
sign "$OUT/Mando.driver"

echo "==> App"
APP="$OUT/Mando.app/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources"
BIN=()
for arch in "${ARCHS[@]}"; do
  target="$arch-apple-macos$MIN_OS"
  clang -target "$target" -O2 -Wall -c App/Bridge/Router.c -IApp/Bridge -o "$OUT/obj/Router-$arch.o"
  clang -target "$target" -O2 -Wall -fobjc-arc -c App/Bridge/OSD.m -IApp/Bridge -o "$OUT/obj/OSD-$arch.o"
  swiftc -target "$target" -O \
    -import-objc-header App/Bridge/Mando-Bridging-Header.h \
    App/Sources/*.swift "$OUT/obj/Router-$arch.o" "$OUT/obj/OSD-$arch.o" \
    -framework AppKit -framework CoreAudio -framework IOKit -framework ServiceManagement -framework ApplicationServices \
    -o "$OUT/obj/Mando-$arch"
  BIN+=("$OUT/obj/Mando-$arch")
done
lipo -create "${BIN[@]}" -output "$APP/MacOS/Mando"
sed "s/__VERSION__/$VERSION/g" App/Info.plist > "$APP/Info.plist"
[[ -f App/AppIcon.icns ]] && cp App/AppIcon.icns "$APP/Resources/" || true
sign "$OUT/Mando.app" App/Mando.entitlements

echo "==> Done: $OUT/Mando.app, $OUT/Mando.driver (v$VERSION, signed with: $SIGN_ID)"
