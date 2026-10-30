import SwiftUI

extension View {
    /// Shows `text` in a dark tooltip under this view after 500 ms of hover. A view up the
    /// tree must call `tildeTooltipHost()` to draw it. Used instead of `.help`, which has a
    /// fixed delay and does not show reliably in Tilde's non-activating panels.
    func tildeTooltip(_ text: String) -> some View {
        modifier(TooltipSource(text: text))
    }

    /// Draws the tooltip of the hovered `tildeTooltip` view inside this view, over its content.
    /// It never takes clicks and does not change this view's size.
    func tildeTooltipHost() -> some View {
        overlayPreferenceValue(TooltipKey.self) { tooltip in
            GeometryReader { proxy in
                if let tooltip {
                    TooltipLayer(text: tooltip.text, target: proxy[tooltip.anchor], bounds: proxy.size)
                }
            }
        }
    }

    /// `tildeTooltipHost` for a view with AppKit content, such as a web view, which would
    /// cover tooltips drawn by SwiftUI; this one draws them above it.
    func tildeTooltipHostAboveAppKit() -> some View {
        overlayPreferenceValue(TooltipKey.self) { tooltip in
            GeometryReader { proxy in
                let target = tooltip.map { proxy[$0.anchor] }
                AboveAppKit {
                    if let tooltip, let target {
                        TooltipLayer(text: tooltip.text, target: target, bounds: proxy.size)
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }
}

private struct Tooltip {
    let text: String
    let anchor: Anchor<CGRect>
}

private struct TooltipKey: PreferenceKey {
    static let defaultValue: Tooltip? = nil

    static func reduce(value: inout Tooltip?, nextValue: () -> Tooltip?) {
        value = value ?? nextValue()
    }
}

private struct TooltipSource: ViewModifier {
    let text: String
    @State private var isShown = false
    @State private var delay: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { isHovered in
                delay?.cancel()
                guard isHovered else {
                    isShown = false
                    return
                }
                delay = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    if !Task.isCancelled {
                        withAnimation(.easeOut(duration: 0.12)) {
                            isShown = true
                        }
                    }
                }
            }
            .anchorPreference(key: TooltipKey.self, value: .bounds) { anchor in
                isShown ? Tooltip(text: text, anchor: anchor) : nil
            }
    }
}

/// A tooltip under its target, moved sideways to stay whole inside the area that draws it.
struct TooltipLayer: View {
    let text: String
    let target: CGRect
    let bounds: CGSize

    var body: some View {
        TooltipBubble(text: text)
            .fixedSize()
            .position(x: Self.centerX(text: text, target: target, width: bounds.width), y: target.maxY + 20)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

extension TooltipLayer {
    /// The bubble's centre: under the target, but at least 4 pt inside both edges.
    static func centerX(text: String, target: CGRect, width: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let half = ((text as NSString).size(withAttributes: [.font: font]).width + 18) / 2
        guard width > 2 * (half + 4) else {
            return width / 2
        }
        return min(max(target.midX, half + 4), width - half - 4)
    }
}

struct TooltipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.16)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
    }
}
