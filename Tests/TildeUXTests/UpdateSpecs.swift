import Foundation
import Testing

extension UXSpecs {
    // MARK: - Update

    /// The user checks for updates on the Configuration page and installs the newer version
    /// it finds. It downloads, is checked, and installs when the user quits Tilde; Tilde then
    /// opens as the new version and still has its Screen Recording and Accessibility grants.
    @Test func anUpdateInstallsWhenTildeQuitsAndTildeOpensAsTheNewVersion() async throws {
        let feed = try UpdateFeed()
        defer { feed.stop() }
        let app = try await TildeApp.launched(defaults: ["updateFeedURL": feed.url])

        try await openUpdates(app)
        // Before: both permissions are granted, and nothing asks for them.
        try await app.waitToSee("Set up")
        #expect(try await !app.seen().contains { $0.name == "Grant" })

        try await app.press("Check for updates")
        try await app.waitToSee("Tilde \(feed.version) is available", timeout: 20)
        try await app.press("Install")
        try await app.waitToSee("Tilde \(feed.version) is ready", timeout: 60)
        try await app.waitToSee("Installs when you quit Tilde")
        #expect(feed.installedBuild != feed.build)
        step("downloaded")

        try await app.menu("Quit Tilde")
        let end = Date().addingTimeInterval(60)
        while feed.installedBuild != feed.build, Date() < end {
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(feed.installedBuild == feed.build)
        step("installed")

        let updated = try await TildeApp.relaunched(after: app)
        defer { updated.quit() }
        try await openUpdates(updated)
        try await updated.waitToSee("Tilde \(feed.version) (\(feed.build))")
        try await updated.waitToSee("Set up")
        #expect(try await !updated.seen().contains { $0.name == "Grant" })
    }

    /// With "Update automatically" on, the daily check downloads a newer version by itself. It
    /// does not install while Settings is open or a session is on screen; once Tilde has had
    /// no input for the idle time, it installs, and Tilde opens again as the new version with
    /// its permissions and no toast.
    @Test func anUpdateInstallsByItselfWhenTildeIsNotInUseAndNeverDuringASession() async throws {
        let feed = try UpdateFeed()
        defer { feed.stop() }
        let app = try await TildeApp.launched(defaults: [
            "updateFeedURL": feed.url, "updateIdleSeconds": "4", "SUEnableAutomaticChecks": "YES", "SUHasLaunchedBefore": "YES",
        ])
        defer { app.quit() }
        let first = app.pid

        try await openUpdates(app)
        try await app.waitToSee("Tilde \(feed.version) is ready", timeout: 60)
        try await app.waitToSee("Installs when you are not using Tilde")
        step("downloaded by itself")

        // A session starts as Settings closes: the install waits for the whole session.
        try await app.key(.w, command: true)
        try await app.waitNotToSee("Update automatically")
        try await app.doubleTap("control")
        try await app.waitToSee("Close")
        try await Task.sleep(for: .seconds(10))
        #expect(feed.installedBuild != feed.build)
        #expect(app.pid == first)
        step("waited for the session")

        try await app.press("Close")
        try await app.waitNotToSee("Close")
        let end = Date().addingTimeInterval(60)
        while feed.installedBuild != feed.build || app.pid == first || app.pid == 0, Date() < end {
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(feed.installedBuild == feed.build)
        #expect(app.pid != first)
        step("installed and opened again")

        // The same menu bar item opens Settings; no toast, and the permissions are still granted.
        try await openUpdates(app)
        try await app.waitToSee("Tilde \(feed.version) (\(feed.build))")
        try await app.waitToSee("Set up")
        #expect(try await !app.seen().contains { $0.name == "Grant" || $0.name == "Later" })
    }

    /// Opens Settings on the Configuration page and scrolls to its Updates card.
    private func openUpdates(_ app: TildeApp) async throws {
        try await app.menu("Settings")
        try await app.press("Configuration")
        let first = try await app.waitToSee("Launch at login")
        try await app.scroll(at: CGPoint(x: first.frame.midX, y: first.frame.maxY + 200), by: -20)
        try await app.waitToSee("Update automatically")
    }
}
