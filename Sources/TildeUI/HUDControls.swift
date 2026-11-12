import SwiftUI

struct HUDButton: View {
    /// An SF Symbol, or an image such as an app icon.
    let image: Image
    /// A label after the icon, such as "Use window picker", which is its accessible name.
    var title: String?
    /// A count after the icon, such as the number of notes; nil for no count. A button with a
    /// count keeps the width of two digits, so the buttons stay put as the count changes.
    var badge: Int?
    /// The smallest width and the height; nil for the surface's button size.
    var size: CGFloat?
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

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isHUDEmbedded) private var isHUDEmbedded
    @Environment(\.pillSize) private var pillSize
    @State private var isHovered = false

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

    var body: some View {
        Button(action: action) {
            label
            .foregroundStyle(foreground)
            .padding(.horizontal, pillSize.scaled(horizontalPadding))
            .frame(minWidth: size ?? pillSize.buttonSize, minHeight: size ?? pillSize.buttonSize)
            .background(RoundedRectangle(cornerRadius: pillSize.scaled(isHUDEmbedded ? 8 : 9)).fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .tildeTooltip(showsTooltip ? help : nil, keys: keys)
        .accessibilityLabel(title ?? help)
        .accessibilityHint(title == nil ? "" : help)
    }

    private var horizontalPadding: CGFloat {
        if title != nil {
            return 10
        }
        return badge == nil ? 0 : 9
    }

    /// The icon, then a slot two digits wide for the count, empty at zero, so the icon stays
    /// put as the count changes.
    private var label: some View {
        HStack(spacing: pillSize.scaled(4)) {
            image
                .font(.system(size: pillSize.font(12), weight: .semibold))
                .symbolEffect(.bounce, value: bounce)
            if let title {
                Text(title)
                    .font(.system(size: pillSize.font(12.5), weight: .medium))
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
