import CryptoKit
import Foundation

/// A newer version of the test app on a local update feed, signed with a key made for this run,
/// as a release on GitHub would be. The installed test app trusts the key from now on: its
/// Info.plist gets the public key, as a release build has the real one.
final class UpdateFeed {
    /// The feed's address, for the app's `updateFeedURL` setting.
    let url: String
    let version = "99.0.0"
    let build: String
    let app: URL
    private let server = Process()
    private let folder: URL

    init(port: Int = 7398) throws {
        app = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TILDE_UX_APP"] ?? "build/TildeUX.app")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-ux-feed-\(UUID().uuidString)", isDirectory: true)
        let files = folder.appendingPathComponent("feed", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)

        let key = Curve25519.Signing.PrivateKey()
        try Self.run("/usr/libexec/PlistBuddy", "-c", "Delete :SUPublicEDKey", app.appendingPathComponent("Contents/Info.plist").path, allowFailure: true)
        try Self.run("/usr/libexec/PlistBuddy", "-c", "Add :SUPublicEDKey string \(key.publicKey.rawRepresentation.base64EncodedString())", app.appendingPathComponent("Contents/Info.plist").path)
        try Self.sign(app)
        build = String(Int(try Self.info("CFBundleVersion", of: app))! + 1)

        let newer = folder.appendingPathComponent(app.lastPathComponent)
        try Self.run("/usr/bin/ditto", app.path, newer.path)
        try Self.run(
            "/usr/libexec/PlistBuddy", "-c", "Set :CFBundleVersion \(build)", "-c", "Set :CFBundleShortVersionString \(version)",
            "-c", "Set :SUPublicEDKey \(key.publicKey.rawRepresentation.base64EncodedString())", newer.appendingPathComponent("Contents/Info.plist").path
        )
        try Self.sign(newer)
        let zip = files.appendingPathComponent("TildeUX.zip")
        try Self.run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", newer.path, zip.path)

        let bytes = try Data(contentsOf: zip)
        let signature = try key.signature(for: bytes).base64EncodedString()
        let appcast = try Self.output(
            "scripts/appcast.sh", version, build, "http://127.0.0.1:\(port)/TildeUX.zip", "sparkle:edSignature=\"\(signature)\" length=\"\(bytes.count)\""
        )
        try appcast.write(to: files.appendingPathComponent("appcast.xml"), atomically: true, encoding: .utf8)

        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", files.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        url = "http://127.0.0.1:\(port)/appcast.xml"
        for _ in 0..<50 where (try? Self.run("/usr/bin/nc", "-z", "127.0.0.1", String(port))) == nil {
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    func stop() {
        server.terminate()
        waitForExit(server)
        try? FileManager.default.removeItem(at: folder)
    }

    /// The installed app's build number now.
    var installedBuild: String {
        (try? Self.info("CFBundleVersion", of: app)) ?? ""
    }

    /// As scripts/ux.sh signs the test app.
    private static func sign(_ app: URL) throws {
        try run("/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "dev.tilde.ux", "-r=designated => identifier \"dev.tilde.ux\"", app.path)
    }

    private static func info(_ key: String, of app: URL) throws -> String {
        try output("/usr/libexec/PlistBuddy", "-c", "Print :\(key)", app.appendingPathComponent("Contents/Info.plist").path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private static func output(_ tool: String, _ arguments: String...) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        waitForExit(process, limit: 60)
        guard process.terminationStatus == 0 else {
            throw UXFailure(description: "\(tool) \(arguments.joined(separator: " ")) failed")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func run(_ tool: String, _ arguments: String..., allowFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        waitForExit(process, limit: 60)
        if process.terminationStatus != 0, !allowFailure {
            throw UXFailure(description: "\(tool) \(arguments.joined(separator: " ")) failed")
        }
    }
}
