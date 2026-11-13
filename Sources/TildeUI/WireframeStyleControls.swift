import SwiftUI

/// The wireframe bar's controls of the look, in the place of its tools: the style and the
/// colours as native menus, and the three strengths in the popover of the Adjust icon button. The same settings
/// as the Appearance page; a change shows at once on the canvas. They fit the width that the
/// tools give them: a long name takes room from the controls' padding, never from the bar.
struct WireframeStyleControls: View {
    @ObservedObject var wireframe: WireframeMode
    @AppStorage(WireframeLook.Key.style) private var style = WireframeLook().style
    @AppStorage(WireframeLook.Key.colours) private var colours = WireframeLook().colours
    @Environment(\.pillSize) private var pillSize
    /// Where the Adjust button is, for its popover: the row is drawn in one of two paddings.
    @State private var adjustFrame = CGRect.zero

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(padding: 10)
            row(padding: 5)
        }
        .coordinateSpace(.named(Self.space))
        .popover(isPresented: isAdjusting, attachmentAnchor: .rect(.rect(adjustFrame)), arrowEdge: .bottom) {
            WireframeAdjust(wireframe: wireframe)
        }
    }

    private static let space = "WireframeStyleControls"

    private func row(padding: CGFloat) -> some View {
        HStack(spacing: pillSize.scaled(4)) {
            Menu {
                Picker("Wireframe style", selection: Binding(get: { style }, set: { wireframe.change(.style($0)) })) {
                    ForEach(WireframeLook.Style.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HUDButtonLabel(image: nil, title: style.title, opensBelow: true)
                    .modifier(HUDButtonChrome(padding: padding))
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Wireframe style")
            .accessibilityValue(style.title)

            Menu {
                Picker("Colours", selection: Binding(get: { colours }, set: { wireframe.change(.colours($0)) })) {
                    ForEach(WireframeLook.Colours.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HUDButtonLabel(image: nil, title: colours.title, opensBelow: true)
                    .modifier(HUDButtonChrome(padding: padding))
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Colours")
            .accessibilityValue(colours.title)

            Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: pillSize.scaled(20))

            HUDButton(image: Image(systemName: "slider.horizontal.3"), isOn: wireframe.bar.isAdjusting, showsTooltip: !wireframe.bar.isAdjusting, help: "Adjust") {
                _ = wireframe.bar.handle(.adjust)
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.space)) }, action: { adjustFrame = $0 })

            Spacer(minLength: 0)
        }
    }

    /// The popover's own close, such as a click outside it, closes it in the bar too.
    private var isAdjusting: Binding<Bool> {
        Binding(get: { wireframe.bar.isAdjusting }, set: { wireframe.bar.isAdjusting = $0 && wireframe.bar.isStyling })
    }
}

/// The Adjust popover: a row for each strength, with its name, its slider and its value. The
/// canvas follows a slider as it moves.
struct WireframeAdjust: View {
    @ObservedObject var wireframe: WireframeMode
    @AppStorage(WireframeLook.Key.fill) private var fill = WireframeLook().fill
    @AppStorage(WireframeLook.Key.blur) private var blur = WireframeLook().blur
    @AppStorage(WireframeLook.Key.fade) private var fade = WireframeLook().fade

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            ForEach(LookStrength.allCases) { strength in
                GridRow {
                    Text(strength.shortTitle)
                        .font(.system(size: 12, weight: .medium))
                    LookSlider(strength: strength, value: value(of: strength), isCompact: true)
                        .frame(width: 210)
                }
            }
        }
        .padding(14)
        .controlSize(.small)
    }

    private func value(of strength: LookStrength) -> Binding<Double> {
        let look = WireframeLook(fill: fill, blur: blur, fade: fade)
        return Binding(get: { look[strength] }, set: { wireframe.change(.strength(strength, $0)) })
    }
}
