#!/bin/zsh
# Build "Murmur.app" from the SwiftPM package into dist/.
# Requires Xcode 26 (Swift 6.2, macOS 26 SDK) for WhisperKit + Foundation Models.

set -e
here="${0:A:h}"
appName="Murmur"
out="$here/dist/$appName.app"

echo "Compiling (release)…"
swift build -c release --product "$appName"
binPath="$(swift build -c release --product "$appName" --show-bin-path)/$appName"

rm -rf "$out"
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"

cp "$binPath" "$out/Contents/MacOS/$appName"
cp "$here/Support/Info.plist" "$out/Contents/Info.plist"
if [[ -f "$here/assets/AppIcon.icns" ]]; then
  cp "$here/assets/AppIcon.icns" "$out/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature so Gatekeeper treats it as a normal unsigned local app.
codesign --force --deep --sign - "$out" >/dev/null 2>&1 || true

echo "Built: $out"
