@testable import TildeUI
import AppKit
import Testing

/// A floating panel's show and hide, when one comes before the other has ended: a session
/// can end and the next one start in less time than the HUD takes to zoom out.
@MainActor
struct ZoomPresenterTests {
    /// A panel that only records whether it is on screen; nothing shows.
    private final class Panel: NSPanel {
        var isOnScreen = false

        override func orderFrontRegardless() {
            isOnScreen = true
        }

        override func orderOut(_ sender: Any?) {
            isOnScreen = false
        }
    }

    private final class Content {
        var isShown = false
    }

    private let panel = Panel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
    private let content = Content()
    private let zoom: ZoomPresenter

    init() {
        zoom = ZoomPresenter(panel: panel) { [content] in content.isShown = $0 }
    }

    /// Two hides and then a show, such as a session that ends, the next one that starts in
    /// Tilde's browser, and its window closed at once: the panel stays on screen. The first
    /// hide's end must not take it away.
    @Test func aShowAfterTwoHidesStays() async throws {
        zoom.show()
        try await Task.sleep(for: .milliseconds(50))
        zoom.hide()
        zoom.hide()
        zoom.show()
        await afterTheDelayedSteps()
        #expect(panel.isOnScreen)
        #expect(content.isShown)
    }

    /// A hide in the same turn as a show hides: the show's content must not grow in a panel
    /// that goes.
    @Test func aHideRightAfterAShowHides() async throws {
        zoom.show()
        zoom.hide()
        await afterTheDelayedSteps()
        #expect(!panel.isOnScreen)
        #expect(!content.isShown)
    }

    /// Returns once the main queue has run the steps that the calls before queued: the next
    /// pass, and a hide's end 0.4 s on, which comes before a step queued now for 0.4 s on. A
    /// busy main thread runs them late, but in that order.
    private func afterTheDelayedSteps() async {
        await withCheckedContinuation { done in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { done.resume() }
        }
    }
}
