#!/bin/bash
# Package dist/Gitrasil.app (from scripts/build-app.sh) for a GitHub Release: a zip, a DMG with an
# Applications shortcut to drag it onto, and their SHA-256 sums (docs/distribution.md).
#
# Writes dist/Gitrasil-<version>.zip, dist/Gitrasil-<version>.dmg and dist/SHA256SUMS. When
# CODESIGN_IDENTITY names a Developer ID certificate, the DMG is signed with it too (notarize it
# afterwards with scripts/notarize.sh); otherwise it's left unsigned, which is fine for an ad-hoc app.
#
# Usage: scripts/package-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

app=dist/Gitrasil.app
if [[ ! -d $app ]]; then
    echo "No $app; run scripts/build-app.sh first" >&2
    exit 1
fi
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
codesign --verify --strict "$app"

zip=dist/Gitrasil-$version.zip
dmg=dist/Gitrasil-$version.dmg
rm -f "$zip" "$dmg" dist/SHA256SUMS

# ditto keeps the bundle as signed (permissions, symlinks, extended attributes); Finder unpacks it.
ditto -c -k --keepParent "$app" "$zip"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Gitrasil.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "Gitrasil $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"
identity=${CODESIGN_IDENTITY:--}
if [[ $identity != - ]]; then
    codesign --force --sign "$identity" --timestamp "$dmg"
fi

(cd dist && shasum -a 256 "$(basename "$zip")" "$(basename "$dmg")" > SHA256SUMS)
ls -l "$zip" "$dmg"
cat dist/SHA256SUMS
