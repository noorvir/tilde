@testable import TildeUI
import Foundation
import TildeCore
import Testing

/// The beta switch for wireframes: off on a new install, on for a user who has used them, and
/// while it is off no wireframe mode starts; on, it starts again at once.
@MainActor
struct WireframeSwitchTests {
    @Test func aNewInstallStartsWithItOff() {
        let defaults = MemoryDefaults()

        WireframeSwitch.migrate(defaults: defaults) { false }

        #expect(WireframeSwitch(defaults: defaults).isOn == false)
    }

    /// A saved tool or look, or a wireframe in History, each turns it on.
    @Test func aUserWhoHasUsedWireframesKeepsThem() {
        let settings: [(String, Any)] = [("WireframeTool", "table"), (WireframeLook.Key.style, "sketch"), (WireframeLook.Key.fill, 0.4)]
        for (key, value) in settings {
            let defaults = MemoryDefaults()
            defaults.set(value, forKey: key)
            WireframeSwitch.migrate(defaults: defaults) { false }
            #expect(WireframeSwitch(defaults: defaults).isOn, "\(key)")
        }

        let defaults = MemoryDefaults()
        WireframeSwitch.migrate(defaults: defaults) { true }
        #expect(WireframeSwitch(defaults: defaults).isOn)
    }

    @Test func laterLaunchesKeepTheUsersChoice() {
        let defaults = MemoryDefaults()
        defaults.set("sketch", forKey: WireframeLook.Key.style)
        WireframeSwitch.migrate(defaults: defaults) { false }
        WireframeSwitch(defaults: defaults).set(false)

        var readHistory = false
        WireframeSwitch.migrate(defaults: defaults) {
            readHistory = true
            return true
        }

        #expect(WireframeSwitch(defaults: defaults).isOn == false)
        #expect(!readHistory)
    }

    @Test func offStartsNoWireframeAndOnStartsItAtOnce() {
        let controller = AnnotationController(store: SessionStore(), browser: BrowserController(), archive: Fixtures.archive(), defaults: MemoryDefaults())
        controller.setStateForTesting(session: Fixtures.session(), mode: .open(SessionFlow.Open()))

        controller.dispatch(.startWireframe, with: [.showCanvas: {}, .showWireframe: {}])
        #expect(!controller.isWireframe)
        #expect(!controller.accepts(.startWireframe))

        controller.wireframes.set(true)
        #expect(controller.accepts(.startWireframe))
        controller.dispatch(.startWireframe, with: [.showCanvas: {}, .showWireframe: {}])
        #expect(controller.isWireframe)
    }
}
