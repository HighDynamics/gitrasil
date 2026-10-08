#!/bin/bash
# Downloads the pinned SwiftLint and SwiftFormat into .build/tools/, verifying their checksums.
# The same binaries run locally and in CI, so a format or lint result never depends on which Xcode
# or Homebrew version a machine has. Safe to re-run: a tool already at the pinned version is kept.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/tool-versions.sh
source "$root/scripts/tool-versions.sh"
bin="$root/.build/tools"
mkdir -p "$bin"

install_tool() { # name version url sha256
    local name=$1 version=$2 url=$3 sha=$4
    if [[ -x "$bin/$name" && "$("$bin/$name" --version)" == "$version" ]]; then
        return
    fi
    local work
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' RETURN
    echo "Installing $name $version"
    curl --fail --silent --show-error --location "$url" --output "$work/$name.zip"
    echo "$sha  $work/$name.zip" | shasum -a 256 --check --quiet
    unzip -q -o "$work/$name.zip" -d "$work/x"
    install -m 755 "$work/x/$name" "$bin/$name"
}

install_tool swiftlint "$SWIFTLINT_VERSION" "$SWIFTLINT_URL" "$SWIFTLINT_SHA256"
install_tool swiftformat "$SWIFTFORMAT_VERSION" "$SWIFTFORMAT_URL" "$SWIFTFORMAT_SHA256"
