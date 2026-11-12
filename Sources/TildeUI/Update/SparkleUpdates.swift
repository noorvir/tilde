import Foundation
import Sparkle

/// Updates through Sparkle: an appcast with EdDSA-signed zips of Tilde.app. The EdDSA key in
/// the app's Info.plist (`SUPublicEDKey`) is the trust check, as the app has no Developer ID.
/// Sparkle checks once a day with a single timer, and installs a downloaded update when Tilde
/// quits; it never shows a window of its own.
@MainActor
final class SparkleUpdates: NSObject, UpdateEngine {
    /// The appcast of the latest release. Release assets of a private repository need a token,
    /// so this must point at a public repository.
    static let feedURL = "https://github.com/noorvir/tilde/releases/latest/download/appcast.xml"

    private var updater: SPUUpdater!
    private var report: (UpdateStatus) -> Void = { _ in }
    private var version = ""
    /// Sparkle's question about the update found or ready, until the user answers it.
    private var reply: ((SPUUserUpdateChoice) -> Void)?
    /// Installs an update that was downloaded in the background, and opens the new version.
    private var installNow: (() -> Void)?
    /// The feed of the current check has loaded: a download error after it is the update's.
    private var feedLoaded = false
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0

    /// `bundle`: the app to update, the running one by default.
    init(bundle: Bundle = .main) {
        super.init()
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
    }

    var isAutomatic: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    func start(reporting: @escaping (UpdateStatus) -> Void) {
        report = reporting
        do {
            try updater.start()
        } catch {
            report(.failed(reason: reason(for: error)))
        }
    }

    func check() {
        updater.checkForUpdates()
    }

    func install() {
        answer(.install)
    }

    func restart() {
        if reply != nil {
            answer(.install)
        } else {
            installNow?()
        }
    }

    private func answer(_ choice: SPUUserUpdateChoice) {
        let reply = self.reply
        self.reply = nil
        reply?(choice)
    }

    /// A short reason for the Configuration page.
    private func reason(for error: Error) -> String {
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            return "No connection"
        }
        guard error.domain == SUSparkleErrorDomain else {
            return "Could not install the update"
        }
        switch Int(error.code) {
        case Int(SUError.appcastParseError.rawValue), Int(SUError.appcastError.rawValue), Int(SUError.invalidFeedURLError.rawValue), Int(SUError.insecureFeedURLError.rawValue):
            return "Could not read the update feed"
        case Int(SUError.downloadError.rawValue), Int(SUError.temporaryDirectoryError.rawValue):
            return feedLoaded ? "Could not download the update" : "Could not reach the update feed"
        case Int(SUError.signatureError.rawValue), Int(SUError.validationError.rawValue), Int(SUError.noPublicDSAFoundError.rawValue), Int(SUError.insufficientSigningError.rawValue):
            return "The update's signature is not valid"
        case Int(SUError.runningTranslocated.rawValue), Int(SUError.runningFromDiskImageError.rawValue):
            return "Move Tilde to Applications first"
        default:
            return "Could not install the update"
        }
    }
}

extension SparkleUpdates: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        // The UX specs point the app at a local feed.
        UserDefaults.standard.string(forKey: "updateFeedURL") ?? Self.feedURL
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        feedLoaded = false
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        feedLoaded = true
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        version = item.displayVersionString
    }

    /// A scheduled check found an update and downloads it in the background.
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        version = item.displayVersionString
        report(.downloading(version: version, progress: nil))
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installNow = immediateInstallHandler
        report(.ready(version: item.displayVersionString))
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if (error as NSError).code == Int(SUError.noUpdateError.rawValue) {
            report(.upToDate)
        } else {
            report(.failed(reason: reason(for: error)))
        }
    }
}

extension SparkleUpdates: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        report(.checking)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        version = appcastItem.displayVersionString
        self.reply = reply
        if state.stage == .notDownloaded {
            report(.available(version: version))
        } else {
            report(.ready(version: version))
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        report(.upToDate)
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        report(.failed(reason: reason(for: error)))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = 0
        receivedLength = 0
        report(.downloading(version: version, progress: nil))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        guard expectedLength > 0 else {
            return
        }
        report(.downloading(version: version, progress: min(1, Double(receivedLength) / Double(expectedLength))))
    }

    func showDownloadDidStartExtractingUpdate() {
        report(.downloading(version: version, progress: 1))
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        self.reply = reply
        report(.ready(version: version))
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {}
}
