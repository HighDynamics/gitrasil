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
    dependencies: [
        // Embedded PTY terminal (engineering notes → Embedded terminal). MIT, proven in shipping
        // macOS apps (CodeEdit, La Terminal).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .target(name: "GitrasilCore"),
        .executableTarget(
            name: "GitrasilApp",
            dependencies: ["GitrasilCore", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
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
