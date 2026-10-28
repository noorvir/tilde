import AppKit
import SwiftUI

extension NSColor {
    static let tildeBlue = NSColor(srgbRed: 0.18, green: 0.47, blue: 1.0, alpha: 1)
    static let tildeInk = NSColor(white: 0.1, alpha: 0.96)
}

/// Spacing shared by the HUD's pill, message and list, so every state lines up.
enum HUDMetrics {
    static let height: CGFloat = 44
    static let leadingInset: CGFloat = 16
    static let trailingInset: CGFloat = 18
    /// Between an icon and its text.
    static let iconGap: CGFloat = 8
}

extension Color {
    static let tildeBlue = Color(nsColor: .tildeBlue)
    static let tildeInk = Color(nsColor: .tildeInk)
}

/// The HUD's capsule text button for windows in light or dark: Tilde blue for actions, red
/// for destructive ones, with the HUD's metrics (12.5 pt semibold, 28 pt high).
struct TildeButtonStyle: ButtonStyle {
    enum Kind {
        case standard
        case destructive
        /// Filled, for the control that waits for input.
        case active
    }

    var kind: Kind = .standard

    func makeBody(configuration: Configuration) -> some View {
        TildeButton(configuration: configuration, kind: kind)
    }

    private struct TildeButton: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        private var color: Color {
            kind == .destructive ? .red : .tildeBlue
        }

        private var fill: Color {
            if kind == .active {
                return color
            }
            if configuration.isPressed {
                return color.opacity(0.28)
            }
            return color.opacity(isHovered && isEnabled ? 0.16 : 0.08)
        }

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(kind == .active ? Color.white : color)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(color.opacity(kind == .active ? 0 : 0.55)))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovered = $0 }
        }
    }
}
