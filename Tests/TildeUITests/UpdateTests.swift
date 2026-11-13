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

    @Test func withoutAutomaticUpdatesAReadyUpdateIsAnnouncedOnceAndRestartsOnRequest() {
        let engine = FakeUpdateEngine()
        engine.isAutomatic = false
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
        engine.isAutomatic = false
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

/// With "Update automatically" on, a ready update installs by itself when Tilde is not in use.
@MainActor
struct SilentUpdateTests {
    @Test func aReadyUpdateInstallsWhenTildeHasHadNoInputForTheIdleTime() {
        let clock = IdleClock()
        let engine = FakeUpdateEngine()
        let updates = clock.updates(engine)
        var announced: [String] = []
        updates.onReady = { announced.append($0) }
        updates.start()

        engine.send(.ready(version: "0.3.0"))
        clock.passes(299)
        #expect(engine.calls.isEmpty)
        clock.passes(1)

        #expect(engine.calls == ["restart"])
        #expect(announced.isEmpty)
    }

    @Test func anUpdateThatIsReadyAfterALongIdleTimeInstallsAtOnce() {
        let clock = IdleClock()
        let engine = FakeUpdateEngine()
        let updates = clock.updates(engine)
        updates.start()

        clock.passes(1000)
        engine.send(.ready(version: "0.3.0"))
        clock.passes(0)

        #expect(engine.calls == ["restart"])
    }

    @Test func inputToTildeMakesTheInstallWait() {
        let clock = IdleClock()
        let engine = FakeUpdateEngine()
        let updates = clock.updates(engine)
        updates.start()

        engine.send(.ready(version: "0.3.0"))
        clock.passes(200)
        updates.noteUse()
        clock.passes(299)
        #expect(engine.calls.isEmpty)
        clock.passes(1)

        #expect(engine.calls == ["restart"])
    }

    @Test func aSessionMakesTheInstallWaitUntilTheIdleTimeAfterItEnds() {
        let clock = IdleClock()
        let engine = FakeUpdateEngine()
        let updates = clock.updates(engine)
        updates.start()
        updates.isSessionActive = true

        engine.send(.ready(version: "0.3.0"))
        clock.passes(1000)
        #expect(engine.calls.isEmpty)
        updates.isSessionActive = false
        clock.passes(299)
        #expect(engine.calls.isEmpty)
        clock.passes(301)

        #expect(engine.calls == ["restart"])
    }

    @Test func anOpenWindowMakesTheInstallWait() {
        let clock = IdleClock()
        let engine = FakeUpdateEngine()
        let updates = clock.updates(engine)
        var showsWindow = true
        updates.showsWindow = { showsWindow }
        updates.start()

        engine.send(.ready(version: "0.3.0"))
        clock.passes(1000)
        #expect(engine.calls.isEmpty)
        showsWindow = false
        clock.passes(300)

        #expect(engine.calls == ["restart"])
    }

    @Test func aSessionThatStartsAsTheInstallBeginsMakesItWait() {
        let clock = IdleClock()
        let engine = FakeUpdateEngine()
        let updates = clock.updates(engine)
        updates.start()
        engine.send(.ready(version: "0.3.0"))
        clock.passes(300)
        #expect(engine.calls == ["restart"])

        updates.isSessionActive = true
        #expect(!engine.asksToRelaunch())
        clock.passes(1000)
        #expect(engine.calls == ["restart"])

        updates.isSessionActive = false
        clock.passes(600)
        #expect(engine.calls == ["restart", "restart"])
        #expect(engine.asksToRelaunch())
    }

    @Test func withTheSettingOffNothingInstallsByItself() {
        let clock = IdleClock()
        let engine = FakeUpdateEngine()
        engine.isAutomatic = false
        let updates = clock.updates(engine)
        var announced: [String] = []
        updates.onReady = { announced.append($0) }
        updates.start()

        engine.send(.ready(version: "0.3.0"))
        clock.passes(10000)

        #expect(engine.calls.isEmpty)
        #expect(announced == ["0.3.0"])
    }

    @Test func theNewVersionKnowsThatASilentInstallOpenedIt() {
        let clock = IdleClock()
        let engine = FakeUpdateEngine()
        let updates = clock.updates(engine)
        updates.start()
        engine.send(.ready(version: "0.3.0"))
        clock.passes(300)
        #expect(engine.asksToRelaunch())
        clock.passes(5)

        #expect(clock.updates(FakeUpdateEngine()).isSilentRelaunch)
        #expect(!clock.updates(FakeUpdateEngine()).isSilentRelaunch)
    }

    @Test func theUsersOwnRestartIsNotSilent() {
        let clock = IdleClock()
        let engine = FakeUpdateEngine()
        let updates = clock.updates(engine)
        updates.start()
        engine.send(.ready(version: "0.3.0"))
        updates.noteUse()
        updates.restart()

        #expect(engine.asksToRelaunch())
        #expect(!clock.updates(FakeUpdateEngine()).isSilentRelaunch)
    }
}

/// Time that a test moves on by hand, and what is due to run in it.
@MainActor
final class IdleClock {
    private var now = Date(timeIntervalSince1970: 0)
    private var due: [(at: Date, run: @MainActor () -> Void)] = []
    private let defaults = MemoryDefaults()

    /// Updates on this clock, with an idle time of 300 s.
    func updates(_ engine: FakeUpdateEngine) -> Updates {
        Updates(engine: engine, idleTime: 300, defaults: defaults, now: { [unowned self] in now }) { [unowned self] delay, run in
            due.append((now.addingTimeInterval(delay), run))
        }
    }

    /// Moves time on, and runs what is due on the way, in order.
    func passes(_ seconds: TimeInterval) {
        let end = now.addingTimeInterval(seconds)
        while let next = due.enumerated().filter({ $0.element.at <= end }).min(by: { $0.element.at < $1.element.at }) {
            due.remove(at: next.offset)
            now = max(now, next.element.at)
            next.element.run()
        }
        now = end
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

    /// macOS runs an app opened from Downloads from a read-only copy in an AppTranslocation
    /// folder, and Sparkle cannot replace it there.
    @Test func aTranslocatedAppAsksToBeMovedToApplications() async throws {
        let status = try await check(running: "361", feedText: nil, mountedAt: "AppTranslocation/1234")
        #expect(status == .failed(reason: "Move Tilde to Applications to get updates"))
    }

    @Test func anAppOpenedFromADiskImageAsksToBeMovedToApplications() async throws {
        let status = try await check(running: "361", feedText: nil, mountedAt: "Tilde")
        #expect(status == .failed(reason: "Move Tilde to Applications to get updates"))
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
    /// `mountedAt`: the app runs from a read-only disk image, mounted at this path in the test's
    /// folder.
    private func check(running build: String, feedText: String?, mountedAt mount: String? = nil) async throws -> UpdateStatus {
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
        var volume: URL?
        defer {
            if let volume {
                try? run("/usr/bin/hdiutil", "detach", "-quiet", "-force", volume.path)
            }
            server.stop()
            try? FileManager.default.removeItem(at: folder)
            UserDefaults.standard.removePersistentDomain(forName: identifier)
        }

        let contents = folder.appendingPathComponent("image/Host.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleName": "Tilde", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": build, "SUEnableAutomaticChecks": false,
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))

        var app = folder.appendingPathComponent("image/Host.app")
        if let mount {
            let image = folder.appendingPathComponent("Host.dmg")
            let mountPoint = folder.appendingPathComponent(mount)
            try run("/usr/bin/hdiutil", "makehybrid", "-quiet", "-hfs", "-o", image.path, folder.appendingPathComponent("image").path)
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            try run("/usr/bin/hdiutil", "attach", "-quiet", "-nobrowse", "-readonly", "-mountpoint", mountPoint.path, image.path)
            volume = mountPoint
            app = mountPoint.appendingPathComponent("Host.app")
        }

        let bundle = try #require(Bundle(url: app))
        let updates = Updates(engine: SparkleUpdates(feed: "http://127.0.0.1:\(port)/appcast.xml", bundle: bundle))
        updates.start()
        updates.check()
        for _ in 0..<100 where updates.status == .checking {
            try await Task.sleep(for: .milliseconds(50))
        }
        return updates.status
    }

    private func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "\(tool) \(arguments.joined(separator: " ")) failed"])
        }
    }
}
