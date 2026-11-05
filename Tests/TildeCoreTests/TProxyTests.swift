@testable import TildeCore
import Foundation
import Testing

struct TProxyTests {
    @Test func aNodeTypeComesFromUname() {
        #expect(TProxy.Target(uname: "Darwin arm64\n") == .darwinArm64)
        #expect(TProxy.Target(uname: "Darwin x86_64") == .darwinAmd64)
        #expect(TProxy.Target(uname: "Linux x86_64") == .linuxAmd64)
        #expect(TProxy.Target(uname: "Linux aarch64") == .linuxArm64)
        #expect(TProxy.Target(uname: "Linux arm64") == .linuxArm64)
        #expect(TProxy.Target(uname: "FreeBSD amd64") == nil)
        #expect(TProxy.Target(uname: "Linux armv7l") == nil)
        #expect(TProxy.Target(uname: "") == nil)
    }

    /// The built-in hashes are the ones the release workflow checks the build against.
    @Test func theBuiltInHashesAreTheReleaseOnes() throws {
        let sums = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../proxy/SHA256SUMS")
        let lines = try String(contentsOf: sums, encoding: .utf8).split(whereSeparator: \.isNewline)
        let release = Dictionary(uniqueKeysWithValues: lines.map { line in
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            return (String(words[1]), String(words[0]))
        })
        #expect(release == Dictionary(uniqueKeysWithValues: TProxy.Target.allCases.map { ($0.fileName, $0.sha256) }))
    }

    /// A download with another hash is refused and not kept, and so is a cached file that changed.
    @Test func aFileWithAnotherHashIsRefused() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tproxy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let release = folder.appendingPathComponent("release")
        let cache = folder.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("not the proxy".utf8).write(to: release.appendingPathComponent("tproxy-linux-arm64"))
        try Data("changed".utf8).write(to: cache.appendingPathComponent("tproxy-linux-arm64"))

        var refusal: Error?
        do {
            _ = try await TProxy.file(for: .linuxArm64, bundled: nil, cache: cache, release: release)
        } catch {
            refusal = error
        }
        #expect("\(refusal.map(String.init(describing:)) ?? "")".contains("not the one Tilde expects"))
        #expect(try Data(contentsOf: cache.appendingPathComponent("tproxy-linux-arm64")) == Data("changed".utf8))

        await #expect(throws: TProxy.Failure.self) {
            try await TProxy.file(for: .linuxAmd64, bundled: nil, cache: cache, release: release)
        }
    }

    /// A release file with its built-in hash is taken from a local test address and cached.
    /// Needs `proxy/build.sh`, whose files have the release's bytes.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: TProxyTests.dist.appendingPathComponent("tproxy-linux-arm64").path)))
    func aReleaseFileWithItsHashIsTakenAndCached() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("tproxy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }

        for target in TProxy.Target.allCases {
            let file = try await TProxy.file(for: target, bundled: nil, cache: cache, release: Self.dist)
            #expect(file == cache.appendingPathComponent(target.fileName))
            #expect(TProxy.sha256(try Data(contentsOf: file)) == target.sha256)
        }
        // The cache is used from then on, with no download.
        let none = cache.appendingPathComponent("no-release")
        #expect(try await TProxy.file(for: .linuxArm64, bundled: nil, cache: cache, release: none) == cache.appendingPathComponent("tproxy-linux-arm64"))
    }

    /// Tilde.app's own files win over any download: dev builds carry them.
    @Test func bundledFilesAreUsedAsTheyAre() async throws {
        let bundled = URL(fileURLWithPath: "/Applications/Tilde.app/Contents/Resources/tproxy")
        let none = URL(fileURLWithPath: "/nonexistent")
        #expect(try await TProxy.file(for: .darwinArm64, bundled: bundled, cache: none, release: none) == bundled.appendingPathComponent("tproxy-darwin-arm64"))
    }

    static let dist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../proxy/dist").standardizedFileURL
}
