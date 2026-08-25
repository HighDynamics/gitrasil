// swift-tools-version:5.8
import PackageDescription

// The platform-agnostic core of Gitrasil. Deliberately dependency-free and UI-free
// so ~90% of the app is unit-testable from the CLI (`swift test`) without Xcode or a
// running SwiftUI surface. The SwiftUI app shell (macOS 14+, Observation, SwiftTerm)
// is a separate target added later.
let package = Package(
    name: "Gitrasil",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GitrasilCore", targets: ["GitrasilCore"]),
        .executable(name: "gitrasil-smoke", targets: ["gitrasil-smoke"]),
    ],
    targets: [
        .target(name: "GitrasilCore"),
        // Fixture-repo harness and topology scenario builders, shared by the XCTest suite and the
        // smoke runner so both exercise the identical git states (architecture decision #13).
        .target(name: "GitrasilTestSupport", dependencies: ["GitrasilCore"]),
        .testTarget(
            name: "GitrasilCoreTests",
            dependencies: ["GitrasilCore", "GitrasilTestSupport"]
        ),
        // A dependency-free smoke runner. The canonical test suite is XCTest
        // (`GitrasilCoreTests`), but this repo's current Xcode (14.3) ships an XCTest
        // helper too old for the host macOS and segfaults during discovery. Until Xcode is
        // updated, `swift run gitrasil-smoke` verifies the core end-to-end against real git.
        .executableTarget(name: "gitrasil-smoke", dependencies: ["GitrasilCore", "GitrasilTestSupport"]),
    ]
)
