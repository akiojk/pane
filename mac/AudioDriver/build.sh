#!/bin/bash
# Builds PaneAudio.driver, the Core Audio plug-in that adds a "Pane" output device.
# Install with ./install.sh (asks for an administrator password).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --show-sdk-path)"
DRIVER="$ROOT/../dist/PaneAudio.driver"

rm -rf "$DRIVER"
mkdir -p "$DRIVER/Contents/MacOS"
clang -bundle -O2 -Wall -Wextra \
  -isysroot "$SDK" \
  -mmacosx-version-min=14.0 \
  -arch arm64 -arch x86_64 \
  -framework CoreAudio -framework CoreFoundation \
  "$ROOT/PaneAudio.c" \
  -o "$DRIVER/Contents/MacOS/PaneAudio"
cp "$ROOT/Info.plist" "$DRIVER/Contents/Info.plist"

IDENTITY="${PANE_SIGNING_IDENTITY:-Pane Local Signing}"
if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  "$ROOT/../setup-signing.sh" || echo "warning: could not create a signing certificate" >&2
fi
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$DRIVER"
else
  codesign --force --sign - "$DRIVER"
fi
echo "Built $DRIVER"
