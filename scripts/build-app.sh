#!/bin/bash
# Build Gitrasil.app: the release build of GitrasilWallpaper in a proper app bundle, so it opens from
# Finder or Spotlight like any other app (docs/distribution.md).
#
# Writes dist/Gitrasil.app: universal (arm64 and x86_64), with an Info.plist from packaging/ (the
# version from VERSION), the icon, SwiftPM's resources, and a signature: ad-hoc unless
# CODESIGN_IDENTITY names a Developer ID certificate (then with the hardened runtime and a secure
# timestamp, ready to notarize). Nothing is installed unless --install is given.
#
# Usage: scripts/build-app.sh [--native] [--install]
#   --native   build for this Mac's architecture only (quicker; for trying a change)
#   --install  also copy it to /Applications, replacing an earlier copy (quit that one first)
# Environment:
#   CODESIGN_IDENTITY  "-" (ad-hoc, the default) or a Developer ID Application identity
#   RELEASES_REPO      the GitHub repository the update check looks at (default HighDynamics/gitrasil)
set -euo pipefail
cd "$(dirname "$0")/.."

archs=(arm64 x86_64)
install=false
for arg in "$@"; do
    case "$arg" in
        --native) archs=("$(uname -m)") ;;
        --install) install=true ;;
        *) echo "usage: scripts/build-app.sh [--native] [--install]" >&2; exit 64 ;;
    esac
done

version=$(tr -d '[:space:]' < VERSION)
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION should be three numbers, like 1.2.3; it's “$version”" >&2
    exit 1
fi
identity=${CODESIGN_IDENTITY:--}
releases=${RELEASES_REPO:-HighDynamics/gitrasil}
# GitHub's own characters only (which also keeps it from breaking the sed below), and not just dots.
if [[ ! $releases =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || $releases =~ (^|/)\.+(/|$) ]]; then
    echo "RELEASES_REPO should be a GitHub repository, owner/name; it's “$releases”" >&2
    exit 1
fi

build=(swift build -c release --product GitrasilWallpaper)
for arch in "${archs[@]}"; do build+=(--arch "$arch"); done
"${build[@]}"
bin=$("${build[@]}" --show-bin-path)

app=dist/Gitrasil.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/GitrasilWallpaper" "$app/Contents/MacOS/Gitrasil"
sed -e "s|__VERSION__|$version|g" -e "s|__RELEASES_REPOSITORY__|$releases|g" \
    packaging/Info.plist > "$app/Contents/Info.plist"
plutil -lint -s "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"
cp packaging/AppIcon.icns "$app/Contents/Resources/"

# SwiftPM's resources, flat in the app's own Resources (MenuBarIcon looks there first). The bundle is
# laid out as a macOS bundle by the newer build system, and flat by the older one.
resources="$bin/Gitrasil_GitrasilWallpaper.bundle"
[[ -d "$resources/Contents/Resources" ]] && resources+=/Contents/Resources
find "$resources" -mindepth 1 -maxdepth 1 ! -name Info.plist ! -name Contents \
    -exec cp -R {} "$app/Contents/Resources/" \;

# Signing refuses Finder info and other extended attributes left on copied files.
xattr -cr "$app"
sign=(codesign --force --sign "$identity")
[[ $identity != - ]] && sign+=(--options runtime --timestamp)
"${sign[@]}" "$app"
codesign --verify --strict "$app"

echo "Built $app $version ($(lipo -archs "$app/Contents/MacOS/Gitrasil"), signed ${identity/#-/ad-hoc})"

if $install; then
    dest=/Applications/Gitrasil.app
    if pgrep -qf "^$dest/Contents/MacOS/Gitrasil"; then
        echo "Gitrasil is running from $dest; quit it first" >&2
        exit 1
    fi
    # Copied beside it first and then swapped in, so a failed copy leaves the earlier app in place. If
    # the swap doesn't finish, the earlier app goes back; it's only deleted once the new one is there,
    # and never if it can't be put back.
    staged=$(mktemp -d /Applications/.Gitrasil.XXXXXX)
    finish() {
        if [[ -e $staged/Gitrasil-old.app && ! -e $dest ]] && ! mv "$staged/Gitrasil-old.app" "$dest"; then
            echo "Couldn't put the earlier Gitrasil back; it's in $staged" >&2
            return
        fi
        rm -rf "$staged"
    }
    trap finish EXIT
    ditto "$app" "$staged/Gitrasil.app"
    if [[ -e $dest ]]; then
        mv "$dest" "$staged/Gitrasil-old.app"
    fi
    mv "$staged/Gitrasil.app" "$dest"
    echo "Installed $dest"
fi
