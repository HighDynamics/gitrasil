#!/bin/bash
# Build GitrasilApp and launch it as a proper macOS .app bundle.
#
# A bare SwiftPM executable does not reliably show a window under LaunchServices; wrapping the
# built binary in a minimal .app bundle and launching it with `open` does. Pass a repository path
# to open it directly, or omit it and use Open Repository… in the window.
#
# Usage: scripts/run.sh [/path/to/repo]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product GitrasilApp

APP=".build/Gitrasil.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/debug/GitrasilApp "$APP/Contents/MacOS/Gitrasil"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Gitrasil</string>
    <key>CFBundleDisplayName</key><string>Gitrasil</string>
    <key>CFBundleIdentifier</key><string>com.gitrasil.app</string>
    <key>CFBundleExecutable</key><string>Gitrasil</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

if [ "$#" -ge 1 ]; then
    open "$APP" --args "$1"
else
    open "$APP"
fi
echo "Launched $APP"
