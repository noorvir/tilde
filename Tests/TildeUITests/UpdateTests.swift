@testable import TildeUI
import TildeCore
import Foundation
import Testing

/// What the user may do with an update, and when: the rules of the Updates card and the toast.
@MainActor
struct UpdateRuleTests {
    @Test func checkingShowsAtOnceAndIsNotStartedTwice() {
        let engine = FakeUpdateEngine()
        let updates = Updates(engine: engine)
        updates.start()

        updates.check()
        updates.check()

        #expect(updates.status == .checking)
        #expect(engine.calls == ["check"])
    }

    @Test func installIsOnlyForAnAvailableUpdate() {
        let engine = FakeUpdateEngine()
        let updates = Updates(engine: engine)
        updates.start()

        updates.install()
        engine.send(.available(version: "0.3.0"))
        updates.install()
        engine.send(.downloading(version: "0.3.0", progress: 0.4))
        updates.install()

        #expect(engine.calls == ["install"])
    }

    @Test func aFailedCheckCanBeTriedAgain() {
        let engine = FakeUpdateEngine()
        let updates = Updates(engine: engine)
        updates.start()

        engine.send(.failed(reason: "No connection"))
        updates.check()

        #expect(updates.status == .checking)
        #expect(engine.calls == ["check"])
    }

    @Test func aReadyUpdateIsAnnouncedOnceAndRestartsOnRequest() {
        let engine = FakeUpdateEngine()
        let updates = Updates(engine: engine)
        var announced: [String] = []
        updates.onReady = { announced.append($0) }
        updates.start()

        engine.send(.ready(version: "0.3.0"))
        engine.send(.ready(version: "0.3.0"))
        updates.restart()

        #expect(announced == ["0.3.0"])
        #expect(engine.calls == ["restart"])
    }

    @Test func anUpdateNeverInstallsInTheMiddleOfASession() {
        let engine = FakeUpdateEngine()
        let updates = Updates(engine: engine)
        var announced: [String] = []
        updates.onReady = { announced.append($0) }
        updates.start()
        updates.isSessionActive = true

        engine.send(.ready(version: "0.3.0"))
        updates.restart()

        #expect(announced.isEmpty)
        #expect(!updates.canRestart)
        #expect(engine.calls.isEmpty)

        // The session ends: the toast offers the update, and Restart works.
        updates.isSessionActive = false
        updates.restart()

        #expect(announced == ["0.3.0"])
        #expect(engine.calls == ["restart"])
    }

    @Test func theAutomaticSettingReachesTheEngine() {
        let engine = FakeUpdateEngine()
        let updates = Updates(engine: engine)

        updates.isAutomatic = false

        #expect(engine.isAutomatic == false)
    }
}

/// Sparkle reads the feed that scripts/appcast.sh writes, and compares its build number with
/// the running one. The feed is a local file, so no network is needed.
@MainActor
@Suite(.serialized)
struct UpdateFeedTests {
    @Test func aNewerBuildIsAvailableWithItsVersion() async throws {
        let status = try await check(running: "361", feed: "362")
        #expect(status == .available(version: "0.3.0"))
    }

    @Test func theSameBuildIsUpToDate() async throws {
        let status = try await check(running: "361", feed: "361")
        #expect(status == .upToDate)
    }

    @Test func anOlderBuildIsUpToDate() async throws {
        let status = try await check(running: "361", feed: "99")
        #expect(status == .upToDate)
    }

    @Test func aBrokenFeedFailsWithAShortReason() async throws {
        let status = try await check(running: "361", feedText: "<rss><channel><item>")
        #expect(status == .failed(reason: "Could not read the update feed"))
    }

    @Test func aMissingFeedFailsWithAShortReason() async throws {
        let status = try await check(running: "361", feedText: nil)
        #expect(status == .failed(reason: "Could not reach the update feed"))
    }

    private func check(running: String, feed build: String) async throws -> UpdateStatus {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../scripts/appcast.sh")
        let process = Process()
        let output = Pipe()
        process.executableURL = script
        process.arguments = ["0.3.0", build, "https://example.test/Tilde-0.3.0.zip", #"sparkle:edSignature="AAAA" length="10""#]
        process.standardOutput = output
        try process.run()
        let feed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try await check(running: running, feedText: String(decoding: feed, as: UTF8.self))
    }

    /// Checks as the user's button does, with a feed of `feedText` over HTTP, or none at all.
    private func check(running build: String, feedText: String?) async throws -> UpdateStatus {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-update-\(UUID().uuidString)")
        // Sparkle keeps its settings in the host app's domain: one fixed domain, emptied each time.
        let identifier = "dev.tilde.update-test"
        UserDefaults.standard.removePersistentDomain(forName: identifier)
        let port = UInt16.random(in: 40000..<50000)
        let body = feedText.map { Data($0.utf8) }
        let server = try HTTPServer(port: port) { _ in
            guard let body else {
                return HTTPResponse(status: 404)
            }
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/xml"], body: body)
        }
        server.start { _ in }
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: folder)
            UserDefaults.standard.removePersistentDomain(forName: identifier)
        }

        let contents = folder.appendingPathComponent("Host.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleName": "Tilde", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": build, "SUEnableAutomaticChecks": false,
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))

        let bundle = try #require(Bundle(url: folder.appendingPathComponent("Host.app")))
        let updates = Updates(engine: SparkleUpdates(feed: "http://127.0.0.1:\(port)/appcast.xml", bundle: bundle))
        updates.start()
        updates.check()
        for _ in 0..<100 where updates.status == .checking {
            try await Task.sleep(for: .milliseconds(50))
        }
        return updates.status
    }
}
