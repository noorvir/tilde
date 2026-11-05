@testable import TildeCore
import Foundation
import Testing

struct TildeProxyTests {
    @Test func aNodeTypeComesFromUname() {
        #expect(TildeProxy.Target(uname: "Darwin arm64\n") == .darwinArm64)
        #expect(TildeProxy.Target(uname: "Darwin x86_64") == .darwinAmd64)
        #expect(TildeProxy.Target(uname: "Linux x86_64") == .linuxAmd64)
        #expect(TildeProxy.Target(uname: "Linux aarch64") == .linuxArm64)
        #expect(TildeProxy.Target(uname: "Linux arm64") == .linuxArm64)
        #expect(TildeProxy.Target(uname: "FreeBSD amd64") == nil)
        #expect(TildeProxy.Target(uname: "Linux armv7l") == nil)
        #expect(TildeProxy.Target(uname: "") == nil)
    }

    /// The built-in hashes are the ones the release workflow checks the build against.
    @Test func theBuiltInHashesAreTheReleaseOnes() throws {
        let sums = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../proxy/SHA256SUMS")
        let lines = try String(contentsOf: sums, encoding: .utf8).split(whereSeparator: \.isNewline)
        let release = Dictionary(uniqueKeysWithValues: lines.map { line in
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            return (String(words[1]), String(words[0]))
        })
        #expect(release == Dictionary(uniqueKeysWithValues: TildeProxy.Target.allCases.map { ($0.fileName, $0.sha256) }))
        #expect(try String(contentsOf: sums.deletingLastPathComponent().appendingPathComponent("main.go"), encoding: .utf8).contains("const version = \"\(TildeProxy.version)\""))
    }

    /// A download with another hash is refused and not kept, and so is a cached file that changed.
    @Test func aFileWithAnotherHashIsRefused() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-proxy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let release = folder.appendingPathComponent("release")
        let cache = folder.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("not the proxy".utf8).write(to: release.appendingPathComponent("tilde-proxy-linux-arm64"))
        try Data("changed".utf8).write(to: cache.appendingPathComponent("tilde-proxy-linux-arm64"))

        var refusal: Error?
        do {
            _ = try await TildeProxy.file(for: .linuxArm64, cache: cache, base: release)
        } catch {
            refusal = error
        }
        #expect("\(refusal.map(String.init(describing:)) ?? "")".contains("not the one Tilde expects"))
        #expect(try Data(contentsOf: cache.appendingPathComponent("tilde-proxy-linux-arm64")) == Data("changed".utf8))

        await #expect(throws: TildeProxy.Failure.self) {
            try await TildeProxy.file(for: .linuxAmd64, cache: cache, base: release)
        }
    }
}
