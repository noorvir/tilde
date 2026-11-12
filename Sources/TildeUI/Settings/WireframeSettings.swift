import SwiftUI

/// The look of wireframe components: a style and three strengths. An open wireframe changes at
/// once.
struct WireframeSettings: View {
    private typealias Key = WireframeLook.Key

    @AppStorage(Key.style) private var style = WireframeLook().style
    @AppStorage(Key.fill) private var fill = WireframeLook().fill
    @AppStorage(Key.blur) private var blur = WireframeLook().blur
    @AppStorage(Key.fade) private var fade = WireframeLook().fade

    var body: some View {
        SettingsSection("Wireframe") {
            SettingsRow(title: "Style", subtitle: styleSubtitle) {
                Picker("Style", selection: $style) {
                    ForEach(WireframeLook.Style.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SettingsDivider()
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

    private var styleSubtitle: String {
        switch style {
        case .technical: "A firm border with a hard offset edge"
        case .hatched: "Diagonal lines over a light fill"
        case .construction: "Dashed lines, corner ticks and crosses for images"
        case .blueprint: "Hairlines that run past the corners"
        }
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
