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
    ],
    targets: [
        .target(name: "GitrasilCore"),
        // Fixture-repo harness and topology scenario builders that stand up real git repos in
        // temp dirs, so derivations are asserted against actual git output (architecture
        // decision #13).
        .target(name: "GitrasilTestSupport", dependencies: ["GitrasilCore"]),
        .testTarget(
            name: "GitrasilCoreTests",
            dependencies: ["GitrasilCore", "GitrasilTestSupport"]
        ),
    ]
)
