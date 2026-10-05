#!/bin/bash
# Spike: draw a repository's branch graph as a live desktop background on the primary display.
#
# Runs in the foreground and logs each redraw; Ctrl-C (or --quit-after <seconds>) removes it.
# Nothing is installed and the system wallpaper setting is never changed. Unlike the main app, this
# runs fine as a bare executable: an accessory app with a borderless desktop-level window doesn't
# need a .app bundle to be shown.
#
# Usage: scripts/run-wallpaper.sh /path/to/repo [--quit-after <seconds>]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product GitrasilWallpaper
exec "$(swift build --product GitrasilWallpaper --show-bin-path)/GitrasilWallpaper" "$@"
