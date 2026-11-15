import SwiftUI

struct HUDButton: View {
    /// An SF Symbol, or an image such as an app icon; nil for a title alone.
    let image: Image?
    /// A label after the icon, such as "Use window picker", which is its accessible name.
    var title: String?
    /// A count after the icon, such as the number of notes; nil for no count. A button with a
    /// count keeps the width of two digits, so the buttons stay put as the count changes.
    var badge: Int?
    /// It opens something under it, such as a picker: a chevron after the title.
    var opensBelow = false
    /// The smallest width and the height; nil for the surface's button size.
    var size: CGFloat?
    /// A fixed width in points, for a title that changes: a longer title is cut at its end,
    /// and the chevron stays at the button's end. Nil to fit the label.
    var width: CGFloat?
    /// Selected, such as the window the session is limited to: a grey fill.
    var isOn = false
    /// Doing what it started, such as choosing a window: a Tilde-blue fill.
    var isActive = false
    var isDestructive = false
    /// The icon's colour, such as Tilde blue for the main action.
    var tint: Color?
    /// Bounces the symbol once each time it changes, to draw the eye; the frame stays.
    var bounce = 0
    /// Off while the tooltip would cover what the button opened under it.
    var showsTooltip = true
    /// The keys that press it while Tilde has the keyboard, after the help in its tooltip.
    var keys: [String] = []
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HUDButtonLabel(image: image, title: title, badge: badge, opensBelow: opensBelow, fillsWidth: width != nil, bounce: bounce)
                .modifier(HUDButtonChrome(size: size, width: width, isOn: isOn, isActive: isActive, isDestructive: isDestructive, tint: tint, padding: padding))
        }
        .buttonStyle(.plain)
        .tildeTooltip(showsTooltip ? help : nil, keys: keys)
        .accessibilityLabel(title ?? help)
        .accessibilityHint(title == nil ? "" : help)
    }

    private var padding: CGFloat {
        if title != nil {
            return 10
        }
        return badge == nil ? 0 : 9
    }
}

/// Between groups of buttons in an accessory bar, such as the drawing bar's tools and colours.
struct HUDBarDivider: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: HUDAccessory.size.scaled(20))
    }
}

/// The look of the HUD's buttons around their label, in a plain button: also for the label of
/// a native menu (`Menu` in the button menu style), so that a dropdown looks like the buttons
/// beside it.
struct HUDButtonChrome: ViewModifier {
    /// The smallest width and the height; nil for the surface's button size.
    var size: CGFloat?
    /// A fixed width in points; nil to fit the label.
    var width: CGFloat?
    var isOn = false
    var isActive = false
    var isDestructive = false
    var tint: Color?
    /// At the ends of the label, in the regular pill's points: none for an icon alone.
    var padding: CGFloat = 0
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isHUDEmbedded) private var isHUDEmbedded
    @Environment(\.pillSize) private var pillSize
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(foreground)
            .padding(.horizontal, pillSize.scaled(padding))
            .frame(minWidth: size ?? pillSize.buttonSize, minHeight: size ?? pillSize.buttonSize)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: pillSize.scaled(isHUDEmbedded ? 8 : 9)).fill(background))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        if isDestructive {
            return Color.red.opacity(isEnabled ? 1 : 0.4)
        }
        if let tint {
            return tint.opacity(isEnabled ? 1 : 0.4)
        }
        if isActive {
            return .white
        }
        return .white.opacity(isEnabled ? 0.9 : 0.3)
    }

    private var background: Color {
        if isDestructive {
            return Color.red.opacity(isHovered && isEnabled ? 0.28 : 0.16)
        }
        if isActive {
            return Color.tildeBlue.opacity(isHovered ? 0.85 : 1)
        }
        return .white.opacity(isOn ? 0.16 : (isHovered && isEnabled ? 0.09 : 0))
    }
}

/// A HUD button's content: the icon, the title, a chevron for what opens under it, then a
/// slot two digits wide for the count, empty at zero, so the icon stays put as the count
/// changes.
struct HUDButtonLabel: View {
    let image: Image?
    var title: String?
    var badge: Int?
    /// It opens a menu or a popover under it: a chevron after the title.
    var opensBelow = false
    /// The title takes the width the button gives it, so the chevron is at the button's end.
    var fillsWidth = false
    var bounce = 0
    @Environment(\.pillSize) private var pillSize

    var body: some View {
        HStack(spacing: pillSize.scaled(4)) {
            if let image {
                image
                    .font(.system(size: pillSize.font(12), weight: .semibold))
                    .symbolEffect(.bounce, value: bounce)
            }
            if let title {
                Text(title)
                    .font(.system(size: pillSize.font(12.5), weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            }
            if opensBelow {
                Image(systemName: "chevron.down")
                    .font(.system(size: pillSize.font(9.5), weight: .semibold))
                    .opacity(0.75)
            }
            if let badge {
                ZStack(alignment: .leading) {
                    Text("88").hidden()
                    Text(badge > 0 ? "\(badge)" : "")
                }
                .font(.system(size: pillSize.font(11.5), weight: .semibold).monospacedDigit())
            }
        }
    }
}

/// Send, or Copy for a session without an agent, in Tilde blue; faded when disabled. Both
/// labels take the space of the wider one, so the pill never shifts.
struct SendButton: View {
    let copies: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isHUDEmbedded) private var isHUDEmbedded

    var body: some View {
        Button(action: action) {
            ZStack {
                label("Send", symbol: "arrow.up").hidden()
                label("Copy", symbol: "doc.on.doc").hidden()
                label(copies ? "Copy" : "Send", symbol: copies ? "doc.on.doc" : "arrow.up")
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(HUDShape(height: 28, isHUDEmbedded: isHUDEmbedded).fill(Color.tildeBlue))
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }

    /// Icon first, then the label, as in macOS buttons.
    private func label(_ title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
            Text(title)
        }
    }
}

/// A text button for the pill's confirm state; destructive ones are red like Delete.
struct PillTextButton: View {
    @Environment(\.isHUDEmbedded) private var isHUDEmbedded
    @Environment(\.pillSize) private var pillSize
    let title: String
    /// A small key cap after the title, such as "esc", for the key that does the same.
    var key: String?
    let isDestructive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: pillSize.scaled(6)) {
                Text(title)
                    .font(.system(size: pillSize.font(12.5), weight: .semibold))
                if let key {
                    KeyHint(key: key)
                }
            }
                .foregroundStyle(isDestructive ? Color.red : .white.opacity(0.9))
                .padding(.horizontal, pillSize.scaled(12))
                .frame(height: pillSize.scaled(28))
                .background(HUDShape(height: pillSize.scaled(28), isHUDEmbedded: isHUDEmbedded).fill(background))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isDestructive {
            return Color.red.opacity(isHovered ? 0.28 : 0.16)
        }
        return .white.opacity(isHovered ? 0.16 : 0.09)
    }
}

/// The key that does the same as a button, after its label: borderless on a faint fill, in
/// the label's colour, centred on it. ↩ is the SF Symbol, which sits centred where the
/// character sits high.
struct KeyHint: View {
    let key: String
    @Environment(\.pillSize) private var pillSize

    var body: some View {
        Group {
            if key == "↩" {
                Image(systemName: "return")
                    .font(.system(size: pillSize.font(9.5), weight: .semibold))
            } else {
                Text(key)
                    .font(.system(size: pillSize.font(11), weight: .medium))
            }
        }
        .opacity(0.75)
        .padding(.horizontal, pillSize.scaled(4))
        .frame(minWidth: pillSize.scaled(18), minHeight: pillSize.scaled(16), maxHeight: pillSize.scaled(16))
        .background(RoundedRectangle(cornerRadius: pillSize.scaled(4)).fill(.foreground.opacity(0.15)))
    }
}

private struct HUDEmbeddedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The HUD is on the browser's toolbar, so its controls use the toolbar's corners.
    var isHUDEmbedded: Bool {
        get { self[HUDEmbeddedKey.self] }
        set { self[HUDEmbeddedKey.self] = newValue }
    }
}

/// A pill control's shape: round ends in the floating HUD, the toolbar's corners on it.
private struct HUDShape: Shape {
    let height: CGFloat
    let isHUDEmbedded: Bool

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: isHUDEmbedded ? 8 : height / 2).path(in: rect)
    }
}
