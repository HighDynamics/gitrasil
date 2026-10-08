// swift-tools-version:5.9
import PackageDescription

// GitrasilCore is the platform-agnostic core — deliberately UI-free so most of the logic is
// unit-testable from the CLI (`swift test`). GitrasilWallpaper is the live desktop background drawn
// on top of it. The macOS 14 floor gives the reactive stores the Observation framework.
let package = Package(
    name: "Gitrasil",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GitrasilCore", targets: ["GitrasilCore"]),
        .executable(name: "GitrasilWallpaper", targets: ["GitrasilWallpaper"])
    ],
    targets: [
        .target(name: "GitrasilCore"),
        // The pinned repositories grown as trees on a live desktop background (docs/yggdrasil).
        .executableTarget(name: "GitrasilWallpaper", dependencies: ["GitrasilCore"],
                          resources: [.copy("Resources/MenuBarIcon.pdf")]),
        // Fixture-repo harness that stands up real git repos in temp dirs, so derivations are
        // asserted against actual git output (architecture decision #13).
        .target(name: "GitrasilTestSupport", dependencies: ["GitrasilCore"]),
        .testTarget(
            name: "GitrasilCoreTests",
            dependencies: ["GitrasilCore", "GitrasilTestSupport"]
        ),
        // The drawing's own geometry (what the wood's outline is made of), where it can be asserted
        // without a screen.
        .testTarget(
            name: "GitrasilWallpaperTests",
            dependencies: ["GitrasilWallpaper", "GitrasilCore"]
        )
    ]
)
