import AppKit
import SwiftUI

extension NSColor {
    static let tildeBlue = NSColor(srgbRed: 0.18, green: 0.47, blue: 1.0, alpha: 1)
    static let tildeInk = NSColor(white: 0.1, alpha: 0.96)
}

extension Color {
    static let tildeBlue = Color(nsColor: .tildeBlue)
    static let tildeInk = Color(nsColor: .tildeInk)
}
