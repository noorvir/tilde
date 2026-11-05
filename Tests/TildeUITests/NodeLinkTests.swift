@testable import TildeUI
import Foundation
import TildeCore
import Testing

/// What Tilde runs on a node before each link, here in a shell with a temporary home.
struct NodeLinkTests {
    private func prepare(_ home: URL) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", NodeSetup.prepareCommand(socket: home.path + "/.tilde/tilde.sock")]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func mode(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
    }

    private func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-node-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// The folders are made private, a stale socket goes, and the type and the proxy's hash
    /// come back, so that the right file is copied only when the hash differs.
    @Test func itReadiesTheFoldersAndReportsTheProxy() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let tilde = home.appendingPathComponent(".tilde")

        let fresh = prepare(home)
        #expect(fresh.status == 0)
        #expect(fresh.output.split(separator: "\n").count == 1)
        #expect(mode(tilde) == 0o700)
        #expect(mode(tilde.appendingPathComponent("bin")) == 0o700)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tilde.path)
        try Data("stale".utf8).write(to: tilde.appendingPathComponent("tilde.sock"))
        try Data("proxy".utf8).write(to: tilde.appendingPathComponent("bin/tproxy"))
        let again = prepare(home)
        #expect(again.status == 0)
        #expect(mode(tilde) == 0o700)
        #expect(!FileManager.default.fileExists(atPath: tilde.appendingPathComponent("tilde.sock").path))
        let lines = again.output.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.last?.hasPrefix(TProxy.sha256(Data("proxy".utf8))) == true)
    }

    /// A `~/.tilde` that is a link, such as one to another user's folder, is never used.
    @Test func aLinkedFolderIsRefused() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let elsewhere = home.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".tilde"), withDestinationURL: elsewhere)

        #expect(prepare(home).status != 0)
    }
}

