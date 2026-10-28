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
