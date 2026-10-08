#!/bin/bash
# Notarize a Developer ID signed Gitrasil.app or DMG with Apple, and staple the ticket to it so it
# opens without a network check (docs/distribution.md). Not for an ad-hoc signed app: Apple only
# notarizes Developer ID signatures with the hardened runtime (scripts/build-app.sh with
# CODESIGN_IDENTITY set).
#
# Authenticates with an App Store Connect API key:
#   NOTARY_KEY_PATH   the .p8 file
#   NOTARY_KEY_ID     its key ID
#   NOTARY_ISSUER_ID  the issuer ID (App Store Connect → Users and Access → Integrations)
#
# Usage: scripts/notarize.sh dist/Gitrasil.app | dist/Gitrasil-<version>.dmg
#
# Untested: it needs Daniel's Developer ID certificate and API key, which don't exist yet.
set -euo pipefail

target=${1:?usage: scripts/notarize.sh <Gitrasil.app | .dmg>}
: "${NOTARY_KEY_PATH:?set NOTARY_KEY_PATH to the App Store Connect API key (.p8)}"
: "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}"
: "${NOTARY_ISSUER_ID:?set NOTARY_ISSUER_ID}"

# notarytool takes a zip, DMG or package; an app goes up zipped, and the ticket is stapled to the app.
upload=$target
if [[ $target == *.app ]]; then
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    upload=$work/$(basename "$target" .app).zip
    ditto -c -k --keepParent "$target" "$upload"
fi

xcrun notarytool submit "$upload" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" --wait --timeout 30m
xcrun stapler staple "$target"
xcrun stapler validate "$target"
if [[ $target == *.app ]]; then
    spctl --assess --type execute --verbose "$target"
fi
