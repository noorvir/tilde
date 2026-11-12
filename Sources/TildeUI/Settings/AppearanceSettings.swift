import SwiftUI

/// The look of wireframe components: a tile for each style, the components of the chosen style
/// in each state, and three strengths. The pictures and an open wireframe change at once.
struct AppearanceSettings: View {
    private typealias Key = WireframeLook.Key

    @ObservedObject var previews: WireframePreviews
    @AppStorage(Key.style) private var style = WireframeLook().style
    @AppStorage(Key.fill) private var fill = WireframeLook().fill
    @AppStorage(Key.blur) private var blur = WireframeLook().blur
    @AppStorage(Key.fade) private var fade = WireframeLook().fade

    private var look: WireframeLook {
        WireframeLook(style: style, fill: fill, blur: blur, fade: fade)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsSection("Wireframe style") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 14)], spacing: 14) {
                    ForEach(WireframeLook.Style.allCases) { tile in
                        StyleTile(title: tile.title, image: previews.tiles[tile], size: WireframePreviews.tileSize, isSelected: tile == style) {
                            style = tile
                        }
                    }
                }
                .padding(16)
            }

            SettingsSection("States") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 14)], alignment: .leading, spacing: 14) {
                    ForEach(WireframePreviews.State.allCases) { state in
                        VStack(alignment: .leading, spacing: 6) {
                            Preview(image: previews.states[state], size: WireframePreviews.stateSize)
                            Text(state.caption)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(state.caption)
                    }
                }
                .padding(16)
            }

            SettingsSection("Strength") {
                LookSlider(title: "Fill", subtitle: "The blue in each component", value: $fill, range: WireframeLook.fillRange, step: 0.01) {
                    $0.formatted(.percent.precision(.fractionLength(0)))
                }
                SettingsDivider()
                LookSlider(title: "Blur under", subtitle: "Blurs the app under each component", value: $blur, range: WireframeLook.blurRange, step: 0.5) {
                    "\($0.formatted(.number.precision(.fractionLength(0...1)))) pt"
                }
                SettingsDivider()
                LookSlider(title: "Fade under", subtitle: "Lightens the app under each component", value: $fade, range: WireframeLook.fadeRange, step: 0.01) {
                    $0.formatted(.percent.precision(.fractionLength(0)))
                }
            }
        }
        .task(id: look) {
            previews.show(look)
        }
        .onDisappear {
            previews.stop()
        }
    }
}

/// A style's picture with its name under it: a button that chooses the style, with an accent
/// ring while it is the one chosen.
private struct StyleTile: View {
    let title: String
    let image: NSImage?
    let size: CGSize
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Preview(image: image, size: size)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 3 : 1)
                    }
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A picture of the wireframe at its own proportions, or a plain area of the same shape while
/// it is drawn.
private struct Preview: View {
    let image: NSImage?
    let size: CGSize

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Color.primary.opacity(0.06)
            }
        }
        .aspectRatio(size.width / size.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

/// A slider with its value as text after it. It moves smoothly, without tick marks, and keeps
/// its value to whole steps.
private struct LookSlider: View {
    let title: String
    let subtitle: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let text: (Double) -> String

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            HStack(spacing: 10) {
                Slider(value: stepped, in: range) {
                    Text(title)
                }
                .labelsHidden()
                .frame(width: 180)
                .accessibilityValue(text(value))
                Text(text(value))
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    private var stepped: Binding<Double> {
        Binding(get: { value }, set: { value = ($0 / step).rounded() * step })
    }
}
