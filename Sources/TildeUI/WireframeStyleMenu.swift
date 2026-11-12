import SwiftUI

/// The wireframe bar's Style menu: the four styles as small tiles, then the three strengths.
/// The same settings as the Appearance page, so the two stay the same, and an open wireframe
/// changes at once.
struct WireframeStyleMenu: View {
    @ObservedObject var previews: WireframePreviews
    @AppStorage(WireframeLook.Key.style) private var style = WireframeLook().style
    @AppStorage(WireframeLook.Key.fill) private var fill = WireframeLook().fill
    @AppStorage(WireframeLook.Key.blur) private var blur = WireframeLook().blur
    @AppStorage(WireframeLook.Key.fade) private var fade = WireframeLook().fade

    /// Four tiles and their gaps, and the padding.
    private static let width: CGFloat = 4 * 104 + 3 * 10 + 24

    private var look: WireframeLook {
        WireframeLook(style: style, fill: fill, blur: blur, fade: fade)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            tiles
            ForEach(LookStrength.allCases) { strength in
                HStack(spacing: 10) {
                    Text(strength.title)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 74, alignment: .leading)
                    LookSlider(strength)
                }
            }
        }
        .padding(12)
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.1).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .task(id: look) {
            previews.show(look)
        }
        .onDisappear {
            previews.stop()
        }
    }

    private var tiles: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(WireframeLook.Style.allCases) { tile in
                StyleTile(title: tile.title, image: previews.tiles[tile], size: WireframePreviews.tileSize, isSelected: tile == style) {
                    style = tile
                }
                .frame(width: 104)
            }
        }
    }
}
