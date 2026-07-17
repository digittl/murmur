#!/bin/zsh
# Build "Murmur.app" from the SwiftPM package into dist/.
# Requires Xcode 26 (Swift 6.2). Bundles the local Ollama runtime if present.

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

# Bundle the Ollama runtime so captions work without a separate install.
# Resolve any symlink to the real single-file binary (Ollama has no non-system
# dylibs). At runtime the app prefers an already-running server, then this copy.
ollamaLink="$(command -v ollama || true)"
if [[ -n "$ollamaLink" ]]; then
  ollamaBin="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$ollamaLink")"
  if [[ -f "$ollamaBin" ]]; then
    cp "$ollamaBin" "$out/Contents/Resources/ollama"
    chmod +x "$out/Contents/Resources/ollama"
    echo "Bundled ollama from $ollamaBin"
  fi
else
  echo "note: ollama not found on PATH — building without a bundled runtime"
fi

# Ad-hoc signature so Gatekeeper treats it as a normal unsigned local app.
codesign --force --deep --sign - "$out" >/dev/null 2>&1 || true

echo "Built: $out"
