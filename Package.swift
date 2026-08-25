// swift-tools-version:5.9
import PackageDescription

// GitrasilCore is the platform-agnostic core — deliberately UI-free so ~90% of the app is
// unit-testable from the CLI (`swift test`). GitrasilApp is the SwiftUI shell on top. The macOS 14
// floor gives the reactive store the Observation framework and the shell mature SwiftUI.
let package = Package(
    name: "Gitrasil",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GitrasilCore", targets: ["GitrasilCore"]),
        .executable(name: "GitrasilApp", targets: ["GitrasilApp"]),
    ],
    targets: [
        .target(name: "GitrasilCore"),
        .executableTarget(name: "GitrasilApp", dependencies: ["GitrasilCore"]),
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
