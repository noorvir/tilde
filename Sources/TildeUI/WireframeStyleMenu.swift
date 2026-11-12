import SwiftUI

/// The wireframe bar's Style menu: the four styles as a row of names, then the three
/// strengths. The same settings as the Appearance page, so the two stay the same; the
/// components on the canvas change at once, so the menu shows no pictures.
struct WireframeStyleMenu: View {
    @AppStorage(WireframeLook.Key.style) private var style = WireframeLook().style

    /// Narrower than the wireframe bar.
    private static let width: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                ForEach(WireframeLook.Style.allCases) { item in
                    StyleItem(title: item.title, isSelected: item == style) {
                        style = item
                    }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
            ForEach(LookStrength.allCases) { strength in
                HStack(spacing: 8) {
                    Text(strength.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 64, alignment: .leading)
                    LookSlider(strength, isCompact: true)
                }
            }
        }
        .padding(10)
        .frame(width: Self.width)
        .hudCard(cornerRadius: 12)
        .environment(\.colorScheme, .dark)
        .controlSize(.small)
    }
}

/// A style's name in the row: a button in the menu's dark style, lighter while chosen.
private struct StyleItem: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .white : .white.opacity(0.75))
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(background))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected {
            return .white.opacity(0.2)
        }
        return isHovered ? .white.opacity(0.1) : .clear
    }
}
