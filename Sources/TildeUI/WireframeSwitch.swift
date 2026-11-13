import Foundation

/// The beta switch for wireframes, off on a new install. While it is off there is no wireframe
/// mode: no button or W key in the HUD, no Edit Wireframe, and no Appearance page. Turning it
/// on shows them at once.
@MainActor
final class WireframeSwitch: ObservableObject {
    nonisolated static let key = "wireframes"

    @Published private(set) var isOn: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isOn = defaults.bool(forKey: Self.key)
    }

    func set(_ isOn: Bool) {
        defaults.set(isOn, forKey: Self.key)
        self.isOn = isOn
    }

    /// Sets the switch on the first launch that has it: on for a user who has used wireframes,
    /// as a saved tool or look, or a wireframe in History, so that nothing disappears for them;
    /// off on a new install. Later launches keep the user's choice. History is read only when
    /// no setting tells.
    nonisolated static func migrate(defaults: UserDefaults, hasWireframeInHistory: () -> Bool) {
        guard defaults.object(forKey: key) == nil else {
            return
        }

        typealias Look = WireframeLook.Key
        let settings = ["WireframeTool", Look.style, Look.fill, Look.blur, Look.fade, Look.colours]
        let hasUsed = settings.contains { defaults.object(forKey: $0) != nil } || hasWireframeInHistory()
        defaults.set(hasUsed, forKey: key)
    }
}
