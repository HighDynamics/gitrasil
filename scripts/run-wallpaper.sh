#!/bin/bash
# Draw the pinned repositories' branch graphs as a live desktop background on the primary display.
#
# Runs in the foreground and logs each redraw; Ctrl-C, the menu-bar item's Quit, or
# --quit-after <seconds> removes it. Pin repositories from the menu-bar item (they're saved in the
# com.gitrasil.background defaults; set GITRASIL_BACKGROUND_DEFAULTS_SUITE to use another suite).
# Nothing is installed and the system wallpaper setting is never changed. An accessory app with a
# borderless desktop-level window doesn't need a .app bundle, so the bare executable runs as is.
#
# Usage: scripts/run-wallpaper.sh [--quit-after <seconds>]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product GitrasilWallpaper
exec "$(swift build --product GitrasilWallpaper --show-bin-path)/GitrasilWallpaper" "$@"
