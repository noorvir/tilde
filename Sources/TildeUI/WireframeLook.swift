import Foundation

/// How wireframe components look, for all of them: Tilde's settings, which a change applies at
/// once to an open wireframe.
struct WireframeLook: Equatable {
    enum Style: String, CaseIterable, Identifiable {
        /// A firm border with a hard offset edge at the bottom and the right.
        case technical
        /// Diagonal lines over a light fill.
        case hatched
        /// Dashed lines, corner ticks and crosses for images.
        case construction
        /// Hairlines that run past the corners.
        case blueprint

        var id: String { rawValue }

        var title: String {
            rawValue.capitalized
        }
    }

    /// The colours of the components: by the group of their kind, or all blue.
    enum Colours: String, CaseIterable, Identifiable {
        /// Blue for sections, cards, rectangles and circles, teal for tables and lists, orange
        /// for buttons and dropdowns.
        case byKind
        case oneColour

        var id: String { rawValue }

        var title: String {
            switch self {
            case .byKind: "By kind"
            case .oneColour: "One colour"
            }
        }
    }

    var style = Style.construction
    /// The opacity of the blue fill.
    var fill = 0.06
    /// The blur of the screen under each component, in points.
    var blur = 2.5
    /// The opacity of the white over the screen under each component.
    var fade = 0.58
    var colours = Colours.byKind

    static let fillRange = 0.0...0.6
    static let blurRange = 0.0...8.0
    static let fadeRange = 0.0...0.8

    /// The keys in UserDefaults; Settings binds its controls to them.
    enum Key {
        static let style = "wireframeStyle"
        static let fill = "wireframeFill"
        static let blur = "wireframeBlur"
        static let fade = "wireframeFade"
        static let colours = "wireframeColours"
    }

    /// The look in `defaults`; what is missing or out of range is the default.
    static func saved(in defaults: UserDefaults = .standard) -> WireframeLook {
        var look = WireframeLook()
        if let style = defaults.string(forKey: Key.style).flatMap(Style.init) {
            look.style = style
        }
        if let colours = defaults.string(forKey: Key.colours).flatMap(Colours.init) {
            look.colours = colours
        }
        func value(_ key: String, in range: ClosedRange<Double>) -> Double? {
            (defaults.object(forKey: key) as? Double).map { min(max($0, range.lowerBound), range.upperBound) }
        }
        look.fill = value(Key.fill, in: fillRange) ?? look.fill
        look.blur = value(Key.blur, in: blurRange) ?? look.blur
        look.fade = value(Key.fade, in: fadeRange) ?? look.fade
        return look
    }

    /// What the canvas's page draws with; the blur is Tilde's own.
    var pageValues: [String: Any] {
        ["style": style.rawValue, "fill": fill, "fade": fade, "colours": colours.rawValue]
    }

    var pageJSON: String {
        DrawingPanel.json(pageValues)
    }
}
