import AppKit

/// The offer, in the bar under the HUD, to open a page of another browser in Tilde's browser.
/// A session makes it at most once.
@MainActor
final class BrowserOffer: ObservableObject {
    /// The page offered, until it is dismissed or opened; nil for no bar.
    @Published private(set) var url: URL?

    private var hasOffered = false
    /// Counts sessions, so that a page read for an earlier session is not offered.
    private var session = 0
    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser",
    ]

    /// A session starts or ends: no offer shows, and the next session can make one.
    func reset() {
        session += 1
        hasOffered = false
        url = nil
    }

    /// The first note on an element in another browser offers its page, when the address the
    /// note reads for its page is a web address.
    func consider(_ window: ElementPicker.WindowInfo, page: Task<PageIdentity?, Never>) {
        guard !hasOffered,
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

    /// The bar's ×.
    func dismiss() {
        url = nil
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
