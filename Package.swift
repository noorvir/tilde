// swift-tools-version: 6.0
import PackageDescription

// With TILDE_STRICT=1 (the test, UX and install scripts), warnings are errors in everything
// that ships: in Swift 5 mode an API newer than macOS 14, such as a 15-only conformance, is
// only a warning, and it crashes at run time on 14. Other builds do not depend on the exact
// compiler's warnings.
let strict: [SwiftSetting] = Context.environment["TILDE_STRICT"] == "1" ? [.unsafeFlags(["-warnings-as-errors"])] : []

let package = Package(
    name: "Tilde",
    platforms: [.macOS(.v14)],
    targets: [
        // The `tilde` skill text: the installer writes it, and the MCP server sends it as instructions.
        .target(name: "TildeSkill", swiftSettings: strict),
        .target(name: "TildeCore", dependencies: ["TildeSkill"], swiftSettings: strict),
        // Adds Tilde's MCP entry and skill to agent apps; used by the menu and `tilde-mcp install`.
        .target(name: "TildeInstaller", dependencies: ["TildeSkill"], swiftSettings: strict),
        .target(
            name: "TildeUI",
            dependencies: ["TildeCore", "TildeInstaller"],
            exclude: ["DrawingWeb"],
            swiftSettings: strict + [.unsafeFlags(["-enable-testing"], .when(configuration: .debug))]
        ),
        .executableTarget(name: "Tilde", dependencies: ["TildeUI"], swiftSettings: strict),
        .executableTarget(name: "tilde-mcp", dependencies: ["TildeInstaller"], swiftSettings: strict),
        // Writes the app icon from TildeMark; see scripts/build-app.sh.
        .executableTarget(name: "tilde-icon", dependencies: ["TildeUI"], swiftSettings: strict),
        // Posts real input and captures the screen for tests on a real display; see scripts/build-driver.sh.
        .executableTarget(name: "tilde-driver", dependencies: ["TildeCore"], swiftSettings: strict),
        // A window whose whole content changes, for the UX specs: stands in for an app that
        // does not describe its contents, such as the iOS Simulator.
        .executableTarget(name: "tilde-ux-fixture", swiftSettings: strict),
        // The contract tests: tilde-state draws a state file with the real views, and
        // tilde-ui-check, which uses no code of Tilde, compares the pictures. See Tests/Contract.
        .executableTarget(name: "tilde-state", dependencies: ["TildeCore", "TildeInstaller", "TildeUI"], swiftSettings: strict),
        .executableTarget(name: "tilde-ui-check", swiftSettings: strict),
        .testTarget(name: "TildeCoreTests", dependencies: ["TildeCore", "TildeSkill", "tilde-mcp"]),
        .testTarget(name: "TildeInstallerTests", dependencies: ["TildeInstaller", "TildeSkill"]),
        // Behaviour tests of the UI; they render offscreen and need a logged-in Mac.
        .testTarget(name: "TildeUITests", dependencies: ["TildeCore", "TildeUI"]),
        // Black-box UX specs: they import nothing of Tilde and drive the built app like a user,
        // so they survive a rewrite. They take over the screen; run them with scripts/ux.sh.
        .testTarget(name: "TildeUXTests"),
    ],
    swiftLanguageModes: [.v5]
)
