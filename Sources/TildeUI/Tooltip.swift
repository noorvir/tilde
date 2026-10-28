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
                    let target = proxy[tooltip.anchor]
                    TooltipBubble(text: tooltip.text)
                        .fixedSize()
                        .position(x: target.midX, y: target.maxY + 20)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
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

private struct TooltipBubble: View {
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
