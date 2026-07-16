#!/bin/zsh
# Build "Whisper Chrono Import.app" from src/ into dist/.
# Requires only macOS (osacompile ships with the OS).

set -e
here="${0:A:h}"
appName="Chronus"
out="$here/dist/$appName.app"

rm -rf "$out"
mkdir -p "$here/dist"

# Compile the AppleScript into a droplet .app (the `on open` handler makes it droppable).
osacompile -o "$out" "$here/src/main.applescript"

# Bundle the shell worker so `path to resource "import.sh"` resolves at runtime.
cp "$here/src/import.sh" "$out/Contents/Resources/import.sh"
chmod +x "$out/Contents/Resources/import.sh"

echo "Built: $out"
