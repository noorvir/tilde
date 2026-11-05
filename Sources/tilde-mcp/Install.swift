import Foundation
import TildeInstaller

let installUsage = """
Usage: tilde-mcp install [--all | <app>...] [--uninstall] [--dry-run] [--home <dir>]

Adds Tilde's MCP server and `tilde` skill to agent apps, or removes them with --uninstall.
Without an app, lists the apps and their status. --all means every app found on this Mac.
--home uses another home folder and finds only apps inside it.

Apps: \(Harness.allCases.map(\.rawValue).joined(separator: ", ")), and claude for Claude Code
"""

/// Runs `tilde-mcp install ...` and returns the exit status.
func runInstall(_ arguments: [String]) -> Int32 {
    var harnesses: [Harness] = []
    var all = false
    var uninstall = false
    var dryRun = false
    var home: URL?

    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
        switch argument {
        case "--all":
            all = true
        case "--uninstall":
            uninstall = true
        case "--dry-run":
            dryRun = true
        case "--home":
            guard let path = remaining.popFirst() else {
                return fail("--home needs a folder")
            }
            home = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        case "-h", "--help":
            print(installUsage)
            return 0
        default:
            guard let harness = Harness.named(argument) else {
                return fail("unknown app or option: \(argument)")
            }
            harnesses.append(harness)
        }
    }

    let bridge = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    let environment: InstallEnvironment
    do {
        environment = try InstallEnvironment.local(
            home: home ?? FileManager.default.homeDirectoryForCurrentUser,
            port: ProcessInfo.processInfo.environment["TILDE_PORT"] ?? "7311",
            bridgePath: bridge,
            isolated: home != nil
        )
    } catch {
        FileHandle.standardError.write(Data("tilde-mcp install: \(error)\n".utf8))
        return 1
    }
    var installer = Installer(environment: environment)
    installer.dryRun = dryRun

    if all {
        harnesses = Harness.allCases.filter { installer.isPresent($0) }
    }
    guard !harnesses.isEmpty else {
        for harness in Harness.allCases {
            print("\(harness.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) \(label(installer.status(of: harness)))")
        }
        return 0
    }

    var status: Int32 = 0
    for harness in harnesses {
        print(harness.name)
        guard installer.isPresent(harness) else {
            print("  Not found on this Mac; skipped.")
            continue
        }

        let report = uninstall ? installer.uninstall(harness) : installer.install(harness)
        for line in report.summary(home: environment.home) {
            print("  \(line)")
        }
        if report.changes.isEmpty {
            print("  Nothing to remove.")
        }
        if report.changes.contains(where: { if case .failed = $0.action { true } else { false } }) {
            status = 1
        }
    }
    return status
}

private func label(_ status: InstallStatus) -> String {
    switch status {
    case .installed: "installed"
    case .notInstalled: "not installed"
    case .notFound: "not found"
    case .failed(let message): "error: \(message)"
    }
}

private func fail(_ message: String) -> Int32 {
    FileHandle.standardError.write(Data("tilde-mcp install: \(message)\n\n\(installUsage)\n".utf8))
    return 2
}
