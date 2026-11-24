import AppKit
import TildeCore

/// The offer, in the bar under the HUD, to open a page of another browser in Tilde's browser.
/// A session makes it at most once. Its × hides it for the session and shows a toast whose
/// "Don't show again" turns the offer off, until Settings turns it on.
@MainActor
final class BrowserOffer: ObservableObject {
    /// The page offered, until it is dismissed or opened; nil for no bar.
    @Published private(set) var url: URL?
    /// The toast after ×.
    @Published private(set) var showsToast = false

    /// The setting: the offer shows. On when never set.
    nonisolated static let enabledKey = "OfferTildeBrowser"
    private let defaults: UserDefaults
    private let toastTime = Countdown()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var isEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private var hasOffered = false
    /// Counts sessions, so that a page read for an earlier session is not offered.
    private var session = 0
    private static let browserBundleIDs = Set(ChromiumBrowser.allCases.map(\.bundleID) + ["com.apple.Safari"])

    /// A session starts or ends: no offer shows, and the next session can make one.
    func reset() {
        session += 1
        hasOffered = false
        url = nil
        hideToast()
    }

    /// The first note on an element in another browser offers its page, when the address the
    /// note reads for its page is a web address.
    func consider(_ window: ElementPicker.WindowInfo, page: Task<PageIdentity?, Never>) {
        guard !hasOffered, isEnabled,
              let bundleID = NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier,
              Self.browserBundleIDs.contains(bundleID)
        else {
            return
        }
        let session = self.session
        Task {
            guard let url = await page.value?.url.flatMap(URL.init(string:)), url.scheme == "http" || url.scheme == "https",
                  self.session == session, !hasOffered
            else {
                return
            }
            hasOffered = true
            self.url = url
        }
    }

    /// The bar's ×: no offer for the rest of the session, and the toast.
    func dismiss() {
        url = nil
        showsToast = true
        startToastTime()
    }

    /// The toast's "Don't show again".
    func neverOffer() {
        defaults.set(false, forKey: Self.enabledKey)
        hideToast()
    }

    /// The pointer on the toast keeps it; leaving it gives it 6 seconds again.
    func holdToast(_ isHeld: Bool) {
        toastTime.cancel()
        if !isHeld, showsToast {
            startToastTime()
        }
    }

    private func startToastTime() {
        toastTime.start(6) { [weak self] in
            self?.hideToast()
        }
    }

    private func hideToast() {
        toastTime.cancel()
        showsToast = false
    }

    /// The bar's open button: the offer goes, and its page is the one to open.
    func take() -> URL? {
        let offered = url
        url = nil
        return offered
    }
}

#if DEBUG
extension BrowserOffer {
    func setStateForTesting(url: URL?) {
        self.url = url
    }
}
#endif
