import SwiftUI

/// A button of the preview card and the source picker: an icon, an optional title, and its
/// help as the tooltip, with the keys that do the same. Its accessible name is its title, or
/// for an icon alone its help; a titled one has its help as the hint.
struct CardButton: View {
    let symbol: String
    var title: String?
    var isDestructive = false
    var keys: [String] = []
    let help: String
    let action: () -> Void
    @Environment(\.pillSize) private var pillSize
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: pillSize.scaled(5)) {
                Image(systemName: symbol)
                    .font(.system(size: pillSize.font(12), weight: .semibold))
                if let title {
                    Text(title)
                        .font(.system(size: pillSize.font(12.5), weight: .medium))
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, title == nil ? 0 : pillSize.scaled(10))
            .frame(minWidth: pillSize.buttonSize, minHeight: pillSize.buttonSize)
            .background(shape.fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .tildeTooltip(help, keys: keys)
        .accessibilityLabel(title ?? help)
        .accessibilityHint(title == nil ? "" : help)
    }
    /// A button with text is round, as the pill's text buttons are; an icon alone is a
    /// rounded square, as the pill's icons are.
    private var shape: AnyShape {
        title == nil ? AnyShape(RoundedRectangle(cornerRadius: pillSize.scaled(8))) : AnyShape(Capsule())
    }

    private var foreground: Color {
        if isDestructive {
            return Color.red.opacity(isHovered ? 1 : 0.85)
        }
        return .white.opacity(isHovered ? 0.95 : 0.7)
    }

    private var background: Color {
        if isDestructive {
            return Color.red.opacity(isHovered ? 0.26 : 0.16)
        }
        return .white.opacity(isHovered ? 0.14 : 0.07)
    }
}
