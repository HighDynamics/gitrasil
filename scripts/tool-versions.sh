# Pinned quality-tool versions, shared by scripts/install-tools.sh and CI. Bump a version and its
# checksum together (shasum -a 256 <the release zip>).
SWIFTLINT_VERSION=0.65.1
SWIFTLINT_URL="https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/portable_swiftlint.zip"
SWIFTLINT_SHA256=c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0

SWIFTFORMAT_VERSION=0.63.1
SWIFTFORMAT_URL="https://github.com/nicklockwood/SwiftFormat/releases/download/${SWIFTFORMAT_VERSION}/swiftformat.zip"
SWIFTFORMAT_SHA256=385ef1a263ba28685157b98c5536b9c9105e124518f28b7ef8a2bee4b167eaeb
