#!/bin/bash
# The repository's quality checks, the same ones CI runs. With no argument runs all of them in
# order; or name one: format | lint | build | test. `scripts/check.sh fix` rewrites the formatting.
set -euo pipefail

cd "$(dirname "$0")/.."
tools=.build/tools

ensure_tools() { scripts/install-tools.sh; }

case "${1:-all}" in
    format)
        ensure_tools
        "$tools/swiftformat" --lint .
        ;;
    fix)
        ensure_tools
        "$tools/swiftformat" .
        ;;
    lint)
        ensure_tools
        "$tools/swiftlint" lint --strict --quiet
        ;;
    build)
        # Release is what scripts/run-wallpaper.sh ships; any compiler warning fails the build.
        swift build -c release -Xswiftc -warnings-as-errors
        ;;
    test)
        swift test
        ;;
    all)
        "$0" format
        "$0" lint
        "$0" build
        "$0" test
        ;;
    *)
        echo "usage: scripts/check.sh [format|fix|lint|build|test|all]" >&2
        exit 2
        ;;
esac
