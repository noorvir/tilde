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
    dependencies: [
        // Updates: finds, checks (EdDSA) and installs newer versions; see Sources/TildeUI/Update.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // The `tilde` skill text: the installer writes it, and the MCP server sends it as instructions.
        .target(name: "TildeSkill", swiftSettings: strict),
        .target(name: "TildeCore", dependencies: ["TildeSkill"], swiftSettings: strict),
        // Adds Tilde's MCP entry and skill to agent apps; used by the menu and `tilde-mcp install`.
        .target(name: "TildeInstaller", dependencies: ["TildeSkill"], swiftSettings: strict),
        .target(
            name: "TildeUI",
            dependencies: ["TildeCore", "TildeInstaller", .product(name: "Sparkle", package: "Sparkle")],
            exclude: ["DrawingWeb"],
            swiftSettings: strict + [.unsafeFlags(["-enable-testing"], .when(configuration: .debug))]
        ),
        // The app bundle has Sparkle.framework in Contents/Frameworks.
        .executableTarget(
            name: "Tilde", dependencies: ["TildeUI"], swiftSettings: strict,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "tilde-mcp", dependencies: ["TildeInstaller"], swiftSettings: strict),
        // Test tools, in Tests/Tools; they do not ship.
        // Posts real input and captures the screen for tests on a real display; see scripts/build-driver.sh.
        .executableTarget(name: "tilde-driver", dependencies: ["TildeCore"], path: "Tests/Tools/tilde-driver", swiftSettings: strict),
        // A window whose whole content changes, for the UX specs: stands in for an app that
        // does not describe its contents, such as the iOS Simulator.
        .executableTarget(name: "tilde-ux-fixture", path: "Tests/Tools/tilde-ux-fixture", swiftSettings: strict),
        // A second display for the UX specs, while it runs, where the VM has one.
        .executableTarget(name: "tilde-ux-display", path: "Tests/Tools/tilde-ux-display", linkerSettings: [.linkedFramework("CoreGraphics")]),
        // The contract tests: tilde-state draws a state file with the real views, and
        // tilde-ui-check, which uses no code of Tilde, compares the pictures. See Tests/Contract.
        .executableTarget(
            name: "tilde-state", dependencies: ["TildeCore", "TildeInstaller", "TildeUI"], path: "Tests/Tools/tilde-state",
            swiftSettings: strict
        ),
        .executableTarget(name: "tilde-ui-check", path: "Tests/Tools/tilde-ui-check", swiftSettings: strict),
        .testTarget(name: "TildeCoreTests", dependencies: ["TildeCore", "TildeSkill", "tilde-mcp"]),
        .testTarget(name: "TildeInstallerTests", dependencies: ["TildeInstaller", "TildeSkill"]),
        // Behaviour tests of the UI; they render offscreen and need a logged-in Mac.
        .testTarget(name: "TildeUITests", dependencies: ["TildeCore", "TildeUI"]),
        // Black-box UX specs: they import nothing of Tilde and drive the built app like a user,
        // so they survive a rewrite. They take over the screen; run them with scripts/ux.sh.
        .testTarget(name: "TildeUXTests", exclude: ["README.md"]),
    ],
    swiftLanguageModes: [.v5]
)
