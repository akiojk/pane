#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --show-sdk-path)"
BUILD="$ROOT/.build"
APP="$ROOT/dist/Pane.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD"

for SHIM in "$ROOT"/Shim/*.m; do
  clang -fobjc-arc \
    -isysroot "$SDK" \
    -mmacosx-version-min=14.0 \
    -c "$SHIM" \
    -o "$BUILD/$(basename "$SHIM" .m).o"
done

swiftc \
  -swift-version 5 \
  -parse-as-library \
  -O \
  -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  -import-objc-header "$ROOT/Shim/PanePrivate.h" \
  -framework AppKit \
  -framework SwiftUI \
  -framework ScreenCaptureKit \
  -framework VideoToolbox \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework CoreGraphics \
  -framework ApplicationServices \
  -framework Network \
  -framework Foundation \
  "$ROOT"/Sources/*.swift \
  "$BUILD"/*.o \
  -o "$APP/Contents/MacOS/Pane"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# macOS ties the Screen Recording grant to the signature. An ad-hoc signature changes on every
# build, so the grant is lost each time. A fixed certificate keeps it.
IDENTITY="${PANE_SIGNING_IDENTITY:-Pane Local Signing}"
if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  "$ROOT/setup-signing.sh" || echo "warning: could not create a signing certificate" >&2
fi
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" --identifier app.pane.mac "$APP"
else
  echo "warning: no \"$IDENTITY\" certificate, signing ad-hoc. Screen Recording will need to be granted again after every build." >&2
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
