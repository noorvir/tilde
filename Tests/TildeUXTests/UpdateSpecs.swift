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

    /// An update whose zip another key signed is refused after the download, and nothing
    /// changes: the trust check is the EdDSA key, whatever the app's code signature.
    @Test func anUpdateSignedWithAnotherKeyIsRefused() async throws {
        let feed = try UpdateFeed(trusted: false)
        defer { feed.stop() }
        let before = feed.installedBuild
        let app = try await TildeApp.launched(defaults: ["updateFeedURL": feed.url])
        defer { app.quit() }

        try await openUpdates(app)
        try await app.press("Check for updates")
        try await app.waitToSee("Tilde \(feed.version) is available", timeout: 20)
        try await app.press("Install")
        try await app.waitToSee("The update's signature is not valid", timeout: 60)
        try await app.waitToSee("Retry")
        #expect(feed.installedBuild == before)
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
