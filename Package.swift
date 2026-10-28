// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tilde",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TildeCore"),
        .target(
            name: "TildeUI",
            dependencies: ["TildeCore"],
            swiftSettings: [.unsafeFlags(["-enable-testing"], .when(configuration: .debug))]
        ),
        .executableTarget(name: "Tilde", dependencies: ["TildeUI"]),
        .executableTarget(name: "tilde-mcp"),
        // Drives the real UI in-process with synthesized events; see scripts/e2e.sh.
        .executableTarget(name: "tilde-e2e", dependencies: ["TildeCore", "TildeUI"], exclude: ["fixture.html"]),
        // Posts real input and captures the screen for tests on a real display; see scripts/build-driver.sh.
        .executableTarget(name: "tilde-driver", dependencies: ["TildeCore"]),
        .testTarget(name: "TildeCoreTests", dependencies: ["TildeCore"]),
        // Snapshot and behaviour tests of the UI; they render offscreen and need a logged-in Mac.
        .testTarget(name: "TildeUITests", dependencies: ["TildeCore", "TildeUI"]),
    ],
    swiftLanguageModes: [.v5]
)
