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

    /// A change from the wireframe bar.
    enum Change: Equatable {
        case style(Style)
        case colours(Colours)
        case strength(LookStrength, Double)
    }

    /// The look with `change`; a strength stays in its range, at a whole step.
    mutating func apply(_ change: Change) {
        switch change {
        case .style(let style):
            self.style = style
        case .colours(let colours):
            self.colours = colours
        case .strength(let strength, let value):
            self[strength] = strength.stepped(value)
        }
    }

    subscript(strength: LookStrength) -> Double {
        get {
            switch strength {
            case .fill: fill
            case .blur: blur
            case .fade: fade
            }
        }
        set {
            switch strength {
            case .fill: fill = newValue
            case .blur: blur = newValue
            case .fade: fade = newValue
            }
        }
    }
}

/// One of the look's three strengths, as its slider sets it.
enum LookStrength: String, CaseIterable, Identifiable {
    case fill, blur, fade

    var id: String { rawValue }

    /// Its name in Settings.
    var title: String {
        switch self {
        case .fill: "Fill"
        case .blur: "Blur under"
        case .fade: "Fade under"
        }
    }

    /// Its name in the wireframe bar's Adjust popover, where the rows are short.
    var shortTitle: String {
        switch self {
        case .fill: "Fill"
        case .blur: "Blur"
        case .fade: "Fade"
        }
    }

    var subtitle: String {
        switch self {
        case .fill: "The colour in each component"
        case .blur: "Blurs the app under each component"
        case .fade: "Lightens the app under each component"
        }
    }

    var key: String {
        switch self {
        case .fill: WireframeLook.Key.fill
        case .blur: WireframeLook.Key.blur
        case .fade: WireframeLook.Key.fade
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .fill: WireframeLook.fillRange
        case .blur: WireframeLook.blurRange
        case .fade: WireframeLook.fadeRange
        }
    }

    private var step: Double {
        self == .blur ? 0.5 : 0.01
    }

    /// `value` in the range, at the nearest whole step.
    func stepped(_ value: Double) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return (clamped / step).rounded() * step
    }

    func text(_ value: Double) -> String {
        if self == .blur {
            return "\(value.formatted(.number.precision(.fractionLength(0...1)))) pt"
        }
        return value.formatted(.percent.precision(.fractionLength(0)))
    }
}
