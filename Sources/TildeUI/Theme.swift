import AppKit
import SwiftUI

extension NSColor {
    static let tildeBlue = NSColor(srgbRed: 0.18, green: 0.47, blue: 1.0, alpha: 1)
    static let tildeInk = NSColor(white: 0.1, alpha: 0.96)
}

/// Spacing shared by the HUD's pill, message and list, so every state lines up.
enum HUDMetrics {
    static let height: CGFloat = 44
    /// The pill's buttons: the pill's height puts them 7 pt from its top and bottom.
    static let buttonSize: CGFloat = 30
    /// Before text at the leading end of a pill or card, such as the install toast's result.
    static let leadingInset: CGFloat = 16
    /// From a button at either end of the pill, such as the HUD's status button and its ×,
    /// to that end.
    static let endInset: CGFloat = 18
    /// Between an icon and its text.
    static let iconGap: CGFloat = 8
    /// Between the HUD and each card under it.
    static let cardGap: CGFloat = 6
    /// The cards under the HUD (the browser hint, "Use window picker" and the picker it grows
    /// into) are compact, so the HUD stays the main surface: the buttons 5 pt from the top and
    /// bottom, and the end inset smaller in the same proportion as the height.
    static let compactHeight: CGFloat = 34
    static let compactButtonSize: CGFloat = 24
    static let compactEndInset: CGFloat = 14
}

/// The size of a surface in the HUD's style, which its buttons, text and spacing follow.
enum HUDSize {
    case regular
    case compact

    var height: CGFloat {
        self == .regular ? HUDMetrics.height : HUDMetrics.compactHeight
    }

    var buttonSize: CGFloat {
        self == .regular ? HUDMetrics.buttonSize : HUDMetrics.compactButtonSize
    }

    var endInset: CGFloat {
        self == .regular ? HUDMetrics.endInset : HUDMetrics.compactEndInset
    }

    /// A regular length at this size, in whole points: every other length in a compact
    /// surface shrinks as its height does.
    func scaled(_ length: CGFloat) -> CGFloat {
        (length * height / HUDMetrics.height).rounded()
    }

    /// A regular font size at this size: one step (1 pt) smaller in a compact surface.
    func font(_ size: CGFloat) -> CGFloat {
        self == .regular ? size : size - 1
    }
}

private struct HUDSizeKey: EnvironmentKey {
    static let defaultValue = HUDSize.regular
}

extension EnvironmentValues {
    /// The size of the surface around a control, which `hudPillInsets(_:leading:)` sets.
    var hudSize: HUDSize {
        get { self[HUDSizeKey.self] }
        set { self[HUDSizeKey.self] = newValue }
    }
}

/// What a pill starts with: a button, such as the HUD's status button, or text, such as the
/// install toast's result.
enum HUDPillEnd {
    case button
    case text
}

extension Color {
    static let tildeBlue = Color(nsColor: .tildeBlue)
    static let tildeInk = Color(nsColor: .tildeInk)
}

extension View {
    /// The HUD's pill, which the install toast and the restore prompt share: Tilde ink in a
    /// capsule, a faint edge and its shadow.
    func hudPill() -> some View {
        clipShape(Capsule())
            .background(Capsule().fill(Color.tildeInk))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
    }

    /// The pill's padding around a row of its controls at `size`: its height, the leading
    /// inset for what `leading` starts with and the end inset after the button at the
    /// trailing end. Its controls take `size` too. Every surface in the pill's shape takes its
    /// padding from here.
    func hudPillInsets(_ size: HUDSize = .regular, leading: HUDPillEnd = .button) -> some View {
        padding(.leading, leading == .text ? size.scaled(HUDMetrics.leadingInset) : size.endInset)
            .padding(.trailing, size.endInset)
            .frame(height: size.height)
            .environment(\.hudSize, size)
    }

    /// A card in the HUD's style: the list, the source picker, the comment box and the pause
    /// note.
    func hudCard(cornerRadius: CGFloat = 16) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        return clipShape(shape)
            .background(shape.fill(Color.tildeInk))
            .overlay(shape.strokeBorder(Color.white.opacity(0.1)).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.22), radius: 14, y: 4)
    }
}

/// Shows and hides a floating panel whose content zooms with `HUDPanel.motion`, as the HUD,
/// the install toast and the restore prompt do: the panel comes on screen and its content
/// grows on the next pass; on hide the content shrinks, then the panel goes.
@MainActor
final class ZoomPresenter {
    private let panel: NSPanel
    private let setShown: (Bool) -> Void
    private var pendingHide: DispatchWorkItem?

    init(panel: NSPanel, setShown: @escaping (Bool) -> Void) {
        self.panel = panel
        self.setShown = setShown
    }

    func show() {
        pendingHide?.cancel()
        panel.orderFrontRegardless()
        // Grow on the next pass, after SwiftUI has laid out the shrunk content.
        DispatchQueue.main.async { [setShown] in
            withAnimation(HUDPanel.motion) {
                setShown(true)
            }
        }
    }

    func hide() {
        withAnimation(HUDPanel.motion) {
            setShown(false)
        }
        let hide = DispatchWorkItem { [panel] in
            panel.orderOut(nil)
        }
        pendingHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: hide)
    }
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
