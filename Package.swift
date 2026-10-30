// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tilde",
    platforms: [.macOS(.v14)],
    targets: [
        // The `tilde` skill text: the installer writes it, and the MCP server sends it as instructions.
        .target(name: "TildeSkill"),
        .target(name: "TildeCore", dependencies: ["TildeSkill"]),
        // Adds Tilde's MCP entry and skill to agent apps; used by the menu and `tilde-mcp install`.
        .target(name: "TildeInstaller", dependencies: ["TildeSkill"]),
        .target(
            name: "TildeUI",
            dependencies: ["TildeCore", "TildeInstaller"],
            swiftSettings: [.unsafeFlags(["-enable-testing"], .when(configuration: .debug))]
        ),
        .executableTarget(name: "Tilde", dependencies: ["TildeUI"]),
        .executableTarget(name: "tilde-mcp", dependencies: ["TildeInstaller"]),
        // Writes the app icon from TildeMark; see scripts/build-app.sh.
        .executableTarget(name: "tilde-icon", dependencies: ["TildeUI"]),
        // Drives the real UI in-process with synthesized events; see scripts/e2e.sh.
        .executableTarget(name: "tilde-e2e", dependencies: ["TildeCore", "TildeUI"], exclude: ["fixture.html"]),
        // Posts real input and captures the screen for tests on a real display; see scripts/build-driver.sh.
        .executableTarget(name: "tilde-driver", dependencies: ["TildeCore"]),
        .testTarget(name: "TildeCoreTests", dependencies: ["TildeCore", "TildeSkill"]),
        .testTarget(name: "TildeInstallerTests", dependencies: ["TildeInstaller", "TildeSkill"]),
        // Snapshot and behaviour tests of the UI; they render offscreen and need a logged-in Mac.
        .testTarget(name: "TildeUITests", dependencies: ["TildeCore", "TildeUI"]),
        // Black-box UX specs: they import nothing of Tilde and drive the built app like a user,
        // so they survive a rewrite. They take over the screen; run them with scripts/ux.sh.
        .testTarget(name: "TildeUXTests", exclude: ["README.md", "Baselines"]),
    ],
    swiftLanguageModes: [.v5]
)
