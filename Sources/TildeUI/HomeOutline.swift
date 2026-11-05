import AppKit
import SwiftUI

/// Dashed outline of a dragged panel at its home position, such as the HUD's pill. It turns
/// blue while the dragged panel is snapped to home.
@MainActor
final class HomeOutline {
    private let window: NSPanel
    private let model = Model()

    final class Model: ObservableObject {
        @Published var isSnapped = false
    }

    init(cornerRadius: CGFloat) {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OutlineView(model: model, cornerRadius: cornerRadius))
    }

    /// Shows the outline as `frame` (AppKit screen coordinates), just below the window
    /// numbered `windowNumber` so the dragged pill passes over it.
    func show(_ frame: NSRect, isSnapped: Bool, below windowNumber: Int) {
        if window.frame != frame {
            window.setFrame(frame, display: true)
        }
        if model.isSnapped != isSnapped {
            withAnimation(.spring(duration: 0.2)) {
                model.isSnapped = isSnapped
            }
        }
        if !window.isVisible {
            window.order(.below, relativeTo: windowNumber)
        }
    }

    func hide() {
        window.orderOut(nil)
        model.isSnapped = false
    }
}

struct OutlineView: View {
    @ObservedObject var model: HomeOutline.Model
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        shape
            .fill(Color.tildeBlue.opacity(model.isSnapped ? 0.24 : 0.12))
            .overlay(
                shape.strokeBorder(
                    Color.tildeBlue.opacity(model.isSnapped ? 0.95 : 0.6),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.5, 5])
                )
            )
    }
}
