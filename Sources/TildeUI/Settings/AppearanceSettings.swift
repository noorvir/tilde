import SwiftUI

/// The look of wireframe components: a tile for each style, the components of the chosen style
/// in each state, the colours, and three strengths. The pictures and an open wireframe change
/// at once.
struct AppearanceSettings: View {
    private typealias Key = WireframeLook.Key

    @ObservedObject var previews: WireframePreviews
    @AppStorage(Key.style) private var style = WireframeLook().style
    @AppStorage(Key.fill) private var fill = WireframeLook().fill
    @AppStorage(Key.blur) private var blur = WireframeLook().blur
    @AppStorage(Key.fade) private var fade = WireframeLook().fade
    @AppStorage(Key.colours) private var colours = WireframeLook().colours

    private var look: WireframeLook {
        WireframeLook(style: style, fill: fill, blur: blur, fade: fade, colours: colours)
    }

    private func value(of strength: LookStrength) -> Binding<Double> {
        switch strength {
        case .fill: $fill
        case .blur: $blur
        case .fade: $fade
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsSection("Wireframe style") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 14)], spacing: 14) {
                    ForEach(WireframeLook.Style.allCases) { tile in
                        ChoiceTile(title: tile.title, isSelected: tile == style) {
                            style = tile
                        } picture: {
                            Preview(image: previews.tiles[tile], size: WireframePreviews.tileSize)
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

            SettingsSection("Colours and strength") {
                SettingsRow(title: "Colours", subtitle: "Blue, teal and orange by kind, or all blue") {
                    HStack(spacing: 12) {
                        ForEach(WireframeLook.Colours.allCases) { tile in
                            ChoiceTile(title: tile.title, isSelected: tile == colours) {
                                colours = tile
                            } picture: {
                                ColourSwatch(colours: tile)
                            }
                        }
                    }
                    .frame(width: 234)
                    .padding(.vertical, 6)
                }
                ForEach(LookStrength.allCases) { strength in
                    SettingsDivider()
                    SettingsRow(title: strength.title, subtitle: strength.subtitle) {
                        LookSlider(strength: strength, value: value(of: strength))
                            .frame(width: 234)
                    }
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

/// A choice's picture with its name under it: a button that chooses it, with an accent ring
/// while it is the one chosen. For the styles and the colours.
struct ChoiceTile<Picture: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let picture: Picture

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                picture
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

/// The colours of the components, as three small parts on white: blue, teal and orange by
/// kind, or three blue ones. The colours of the canvas's page, wireframe/look.js.
struct ColourSwatch: View {
    let colours: WireframeLook.Colours

    private static let blue = Color(red: 0x2F / 255, green: 0x7B / 255, blue: 0xF6 / 255)
    private static let teal = Color(red: 0x0E / 255, green: 0x93 / 255, blue: 0x84 / 255)
    private static let orange = Color(red: 0xE0 / 255, green: 0x66 / 255, blue: 0x0F / 255)

    private var parts: [Color] {
        switch colours {
        case .byKind: [Self.blue, Self.teal, Self.orange]
        case .oneColour: [Self.blue, Self.blue, Self.blue]
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(parts.indices, id: \.self) { index in
                Rectangle()
                    .fill(parts[index].opacity(0.12))
                    .overlay(Rectangle().strokeBorder(parts[index], lineWidth: 1.5))
                    .frame(width: 22, height: 14)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

/// A picture of the wireframe at its own proportions, or a plain area of the same shape while
/// it is drawn.
struct Preview: View {
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

/// A strength's slider with its value as text after it. It moves smoothly, without tick
/// marks, and keeps its value to whole steps. Compact: smaller text, for the wireframe bar's
/// Adjust popover.
struct LookSlider: View {
    let strength: LookStrength
    @Binding var value: Double
    var isCompact = false

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: stepped, in: strength.range) {
                Text(strength.title)
            }
            .labelsHidden()
            .accessibilityValue(strength.text(value))
            Text(strength.text(value))
                .font(.system(size: isCompact ? 11 : 13))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: isCompact ? 38 : 44, alignment: .trailing)
        }
    }

    private var stepped: Binding<Double> {
        Binding(get: { value }, set: { value = strength.stepped($0) })
    }
}
