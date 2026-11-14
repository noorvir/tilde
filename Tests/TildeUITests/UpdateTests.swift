@testable import TildeUI
import TildeCore
import Foundation
import os
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
/// the running one. The feed is served on this Mac, so no network is needed.
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

    /// Before the first release the feed's address gives 404: that is not a signature problem.
    @Test func aMissingFeedFailsWithAShortReason() async throws {
        let status = try await check(running: "361", feedText: nil)
        #expect(status == .failed(reason: "Could not reach the update feed"))
    }

    /// A build made with no update key cannot check what it downloads, so it never looks for
    /// updates: no check, no daily timer, no automatic install. Sparkle itself would start for
    /// a code-signed app with an HTTPS feed, as a release is.
    @Test(arguments: [nil, "not-a-key"])
    func aBuildWithNoValidUpdateKeyHasUpdatesOff(key: String?) async throws {
        let host = try FeedHost(build: "361", key: key, files: [:], secureFeed: true, automaticChecks: true)
        defer { host.stop() }
        host.updates.start()
        host.updates.check()
        host.engine.check()
        host.updates.isAutomatic = true
        try await Task.sleep(for: .milliseconds(500))

        #expect(host.updates.status == .off)
        #expect(!host.updates.canCheck)
        #expect(!host.engine.isAutomatic)
        #expect(host.requests == 0)
    }

    /// Only an update whose download fails the EdDSA check is called a bad signature.
    @Test func aDownloadThatAnotherKeySignedFailsAsABadSignature() async throws {
        let zip = try FeedHost.zip(build: "362")
        let otherSignature = Data((0..<64).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let feed = try appcast(build: "362", signature: #"sparkle:edSignature="\#(otherSignature)" length="\#(zip.count)""#)
        let host = try FeedHost(build: "361", files: ["appcast.xml": feed, "Tilde.zip": zip])
        defer { host.stop() }

        #expect(try await host.check() == .available(version: "0.3.0"))
        host.updates.install()
        for _ in 0..<400 where !isFinal(host.updates.status) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(host.updates.status == .failed(reason: "The update's signature is not valid"))
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
        try await check(running: running, feedText: String(decoding: try appcast(build: build), as: UTF8.self))
    }

    /// Checks as the user's button does, with a feed of `feedText`, or none at all.
    /// `mountedAt`: the app runs from a read-only disk image, mounted at this path.
    private func check(running build: String, feedText: String?, mountedAt mount: String? = nil) async throws -> UpdateStatus {
        let files = feedText.map { ["appcast.xml": Data($0.utf8)] } ?? [:]
        let host = try FeedHost(build: build, files: files, mountedAt: mount)
        defer { host.stop() }
        return try await host.check()
    }

    private func appcast(build: String, signature: String = #"sparkle:edSignature="AAAA" length="10""#) throws -> Data {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../scripts/appcast.sh")
        let process = Process()
        let output = Pipe()
        process.executableURL = script
        process.arguments = ["0.3.0", build, "\(FeedHost.address)/Tilde.zip", signature]
        process.standardOutput = output
        try process.run()
        let feed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return feed
    }

    private func isFinal(_ status: UpdateStatus) -> Bool {
        switch status {
        case .ready, .failed, .upToDate: true
        default: false
        }
    }
}

/// A test copy of Tilde.app for Sparkle to update, and a server on this Mac with its feed.
/// `stop` removes both.
@MainActor
private final class FeedHost {
    /// One port for each test run, as other checkouts may run these tests at the same time.
    static let port = UInt16.random(in: 40000..<50000)
    /// Where the server is; the feed is `appcast.xml` in it.
    static let address = "http://127.0.0.1:\(port)"
    let engine: SparkleUpdates
    let updates: Updates
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-update-\(UUID().uuidString)")
    private let server: HTTPServer
    private let hits = OSAllocatedUnfairLock(initialState: 0)
    private var volume: URL?
    // Sparkle keeps its settings in the host app's domain: one fixed domain, emptied each time.
    private let identifier = "dev.tilde.update-test"

    /// Requests that reached the server.
    var requests: Int {
        hits.withLock { $0 }
    }

    /// `key`: the app's update key, none if nil. `files`: what the server has; other paths
    /// give 404. `mountedAt`: the app runs from a read-only disk image, mounted at this path.
    /// `secureFeed`: the feed's address is HTTPS, which this server does not answer.
    init(
        build: String, key: String? = Data(repeating: 1, count: 32).base64EncodedString(), files: [String: Data], mountedAt mount: String? = nil,
        secureFeed: Bool = false, automaticChecks: Bool = false
    ) throws {
        UserDefaults.standard.removePersistentDomain(forName: identifier)
        let hits = hits
        server = try HTTPServer(port: Self.port) { request in
            hits.withLock { $0 += 1 }
            guard let body = files[String(request.path.dropFirst())] else {
                return HTTPResponse(status: 404)
            }
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/octet-stream"], body: body)
        }
        server.start { _ in }

        let contents = folder.appendingPathComponent("image/Host.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["SUEnableAutomaticChecks": automaticChecks, "SUScheduledCheckInterval": 3600]
        info["SUPublicEDKey"] = key
        try Self.write(info, build: build, to: contents)
        try Self.run("/usr/bin/codesign", "--force", "--sign", "-", contents.deletingLastPathComponent().path)

        var app = folder.appendingPathComponent("image/Host.app")
        if let mount {
            let image = folder.appendingPathComponent("Host.dmg")
            let mountPoint = folder.appendingPathComponent(mount)
            try Self.run("/usr/bin/hdiutil", "makehybrid", "-quiet", "-hfs", "-o", image.path, folder.appendingPathComponent("image").path)
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            try Self.run("/usr/bin/hdiutil", "attach", "-quiet", "-nobrowse", "-readonly", "-mountpoint", mountPoint.path, image.path)
            volume = mountPoint
            app = mountPoint.appendingPathComponent("Host.app")
        }

        let bundle = try #require(Bundle(url: app))
        let address = secureFeed ? Self.address.replacingOccurrences(of: "http:", with: "https:") : Self.address
        engine = SparkleUpdates(feed: "\(address)/appcast.xml", bundle: bundle)
        updates = Updates(engine: engine)
    }

    /// Checks as the user's button does.
    func check() async throws -> UpdateStatus {
        updates.start()
        updates.check()
        for _ in 0..<100 where updates.status == .checking {
            try await Task.sleep(for: .milliseconds(50))
        }
        return updates.status
    }

    func stop() {
        if let volume {
            try? Self.run("/usr/bin/hdiutil", "detach", "-quiet", "-force", volume.path)
        }
        server.stop()
        try? FileManager.default.removeItem(at: folder)
        // Sparkle downloads into the host app's caches.
        try? FileManager.default.removeItem(at: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(identifier))
        UserDefaults.standard.removePersistentDomain(forName: identifier)
    }

    /// A zip of a newer copy of the app, as a release has.
    static func zip(build: String) throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-update-zip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("Host.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try write(["SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()], build: build, to: app.appendingPathComponent("Contents"))
        try run("/usr/bin/codesign", "--force", "--sign", "-", app.path)
        let zip = folder.appendingPathComponent("Host.zip")
        try run("/usr/bin/ditto", "-c", "-k", "--keepParent", app.path, zip.path)
        return try Data(contentsOf: zip)
    }

    private static func write(_ info: [String: Any], build: String, to contents: URL) throws {
        let app: [String: Any] = [
            "CFBundleIdentifier": "dev.tilde.update-test", "CFBundleName": "Tilde", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": build == "362" ? "0.3.0" : "0.2.0", "CFBundleVersion": build,
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: app.merging(info) { $1 }, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private static func run(_ tool: String, _ arguments: String...) throws {
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
