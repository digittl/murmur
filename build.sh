#!/bin/zsh
# Build "BatchWhisper.app" (native AppKit / Swift) from src/ into dist/.
# Requires the Xcode command line tools (swiftc).

set -e
here="${0:A:h}"
appName="BatchWhisper"
out="$here/dist/$appName.app"

rm -rf "$out"
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"

# Compile the Swift executable.
swiftc -O -swift-version 5 -o "$out/Contents/MacOS/$appName" "$here/src/main.swift"

# Bundle metadata + icon.
cp "$here/src/Info.plist" "$out/Contents/Info.plist"
if [[ -f "$here/assets/AppIcon.icns" ]]; then
  cp "$here/assets/AppIcon.icns" "$out/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc code signature so Gatekeeper treats it as a normal unsigned local app.
codesign --force --sign - "$out" >/dev/null 2>&1 || true

echo "Built: $out"
