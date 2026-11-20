@testable import TildeUI
import CoreGraphics
import Testing

/// The window picker lists windows on screen, and those in full screen on a Space that does not
/// show; not minimized windows, nor those of hidden apps.
struct SourcePickerListTests {
    let main = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    let dell = CGRect(x: 1800, y: -271, width: 2560, height: 1440)

    func isListed(_ frame: CGRect, layer: Int = 0, isOnScreen: Bool = false, isAppHidden: Bool = false) -> Bool {
        SourcePickerModel.isListed(frame: frame, layer: layer, isOnScreen: isOnScreen, isAppHidden: isAppHidden, displays: [main, dell])
    }

    @Test func aWindowOnScreenIsListed() {
        #expect(isListed(CGRect(x: 200, y: 100, width: 800, height: 600), isOnScreen: true))
        #expect(isListed(CGRect(x: 200, y: 100, width: 800, height: 600), layer: Int(CGWindowLevelForKey(.floatingWindow)), isOnScreen: true))
    }

    @Test func aFullScreenWindowOnASpaceThatDoesNotShowIsListed() {
        #expect(isListed(dell))
        #expect(isListed(main))
        // Under the notch of a built-in display.
        #expect(isListed(CGRect(x: 0, y: 38, width: 1800, height: 1131)))
    }

    @Test func otherWindowsOffScreenAreNotListed() {
        // Minimized, or on another Space of the desktop.
        #expect(!isListed(CGRect(x: 200, y: 100, width: 800, height: 600)))
        // Zoomed to fill the display except the menu bar, on another Space.
        #expect(!isListed(CGRect(x: 1800, y: -238, width: 2560, height: 1300)))
        // A hidden app's full-screen window.
        #expect(!isListed(dell, isAppHidden: true))
        // Not a normal window.
        #expect(!isListed(dell, layer: Int(CGWindowLevelForKey(.floatingWindow))))
    }

    @Test func smallAndHighWindowsAreNotListed() {
        #expect(!isListed(CGRect(x: 0, y: 0, width: 90, height: 600), isOnScreen: true))
        #expect(!isListed(CGRect(x: 0, y: 0, width: 800, height: 50), isOnScreen: true))
        #expect(!isListed(CGRect(x: 0, y: 0, width: 800, height: 600), layer: Int(CGWindowLevelForKey(.statusWindow)), isOnScreen: true))
    }
}
