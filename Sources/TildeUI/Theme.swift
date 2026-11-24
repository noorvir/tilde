import AppKit
import SwiftUI

extension NSColor {
    static let tildeBlue = NSColor(srgbRed: 0.18, green: 0.47, blue: 1.0, alpha: 1)
    static let tildeInk = NSColor(white: 0.1, alpha: 0.96)
}

/// The pill's tokens: the shared capsule of the HUD, its accessory bars and the toasts, also
/// used by the cards beside them (the list) so every state lines up.
enum PillMetrics {
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
    /// The compact pill: the buttons 5 pt from the top and bottom, and the end inset smaller in
    /// the same proportion as the height.
    static let compactHeight: CGFloat = 34
    static let compactButtonSize: CGFloat = 24
    static let compactEndInset: CGFloat = 14
    /// A colour to pick, such as the drawing bar's: a dot big enough to hit.
    static let swatchSize: CGFloat = 18
    static let compactSwatchSize: CGFloat = 14
}

/// The size of a pill, which its buttons, text and spacing follow: regular for the HUD and
/// the toasts, compact for the accessory bars.
enum PillSize {
    case regular
    case compact

    var height: CGFloat {
        self == .regular ? PillMetrics.height : PillMetrics.compactHeight
    }

    var buttonSize: CGFloat {
        self == .regular ? PillMetrics.buttonSize : PillMetrics.compactButtonSize
    }

    var endInset: CGFloat {
        self == .regular ? PillMetrics.endInset : PillMetrics.compactEndInset
    }

    var swatchSize: CGFloat {
        self == .regular ? PillMetrics.swatchSize : PillMetrics.compactSwatchSize
    }

    /// A regular length at this size, in whole points: every other length in a compact pill
    /// shrinks as its height does.
    func scaled(_ length: CGFloat) -> CGFloat {
        (length * height / PillMetrics.height).rounded()
    }

    /// A regular font size at this size: one step (1 pt) smaller in a compact pill.
    func font(_ size: CGFloat) -> CGFloat {
        self == .regular ? size : size - 1
    }
}

private struct PillSizeKey: EnvironmentKey {
    static let defaultValue = PillSize.regular
}

extension EnvironmentValues {
    /// The size of the pill around a control, which `pillInsets(_:leading:)` sets.
    var pillSize: PillSize {
        get { self[PillSizeKey.self] }
        set { self[PillSizeKey.self] = newValue }
    }
}

/// What a pill starts with: a button, such as the HUD's status button, or text, such as the
/// install toast's result.
enum PillEnd {
    case button
    case text
}

/// An accessory bar: a compact pill attached under the HUD, such as the drawing bar and the
/// browser accessory bar, and the cards under it, such as the source dropdown and the source
/// picker. It is compact so the HUD stays the main surface.
enum HUDAccessory {
    static let size = PillSize.compact
    /// Between the HUD and an accessory bar or card under it.
    static let gap: CGFloat = 6
}

extension Color {
    static let tildeBlue = Color(nsColor: .tildeBlue)
    static let tildeInk = Color(nsColor: .tildeInk)

    /// From "#RRGGBB", in sRGB.
    init(hex: String) {
        self.init(cgColor: .hex(hex))
    }
}

extension CGColor {
    /// From "#RRGGBB", in sRGB.
    static func hex(_ hex: String) -> CGColor {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        return CGColor(srgbRed: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

extension View {
    /// The pill, which the HUD, its accessory bars and the toasts share: Tilde ink in a
    /// capsule, a faint edge and its shadow.
    func pill() -> some View {
        clipShape(Capsule())
            .background(Capsule().fill(Color.tildeInk))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
    }

    /// The pill's padding around a row of its controls at `size`: its height, the leading
    /// inset for what `leading` starts with and the end inset after the button at the
    /// trailing end. Its controls take `size` too. Every pill takes its padding from here.
    func pillInsets(_ size: PillSize = .regular, leading: PillEnd = .button) -> some View {
        padding(.leading, leading == .text ? size.scaled(PillMetrics.leadingInset) : size.endInset)
            .padding(.trailing, size.endInset)
            .frame(height: size.height)
            .environment(\.pillSize, size)
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
/// the install toast and the restore toast do: the panel comes on screen and its content
/// grows on the next pass; on hide the content shrinks, then the panel goes.
@MainActor
final class ZoomPresenter {
    private let panel: NSPanel
    private let setShown: (Bool) -> Void
    private var pendingHide: DispatchWorkItem?
    /// What the last call asked for.
    private var isShown = false

    init(panel: NSPanel, setShown: @escaping (Bool) -> Void) {
        self.panel = panel
        self.setShown = setShown
    }

    /// Shows or hides the panel as the last call says, also when the calls come sooner than
    /// their delayed steps: a hide that waits for its end never takes a panel shown since.
    func show() {
        isShown = true
        pendingHide?.cancel()
        panel.orderFrontRegardless()
        // Grow on the next pass, after SwiftUI has laid out the shrunk content.
        DispatchQueue.main.async { [weak self] in
            guard let self, isShown else {
                return
            }
            withAnimation(HUDPanel.motion) {
                self.setShown(true)
            }
        }
    }

    func hide() {
        isShown = false
        withAnimation(HUDPanel.motion) {
            setShown(false)
        }
        pendingHide?.cancel()
        let hide = DispatchWorkItem { [panel] in
            panel.orderOut(nil)
        }
        pendingHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: hide)
    }
}
