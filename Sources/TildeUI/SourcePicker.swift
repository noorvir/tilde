import SwiftUI

/// Under the HUD while choosing a source: a "Use window picker" button that grows into the picker,
/// in the style of the HUD's list, with screens and a phone on a cable in one tab, apps and
/// then their windows in the other. Its cross shrinks it back to the button.
struct SourcePickerView: View {
    /// As many columns as fit; tiles past the picker's height scroll.
    private static let columns = [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)]
    /// The picker stays inside the HUD's panel.
    private static let sizes = (min: CGSize(width: 420, height: 260), max: CGSize(width: 780, height: 900))

    @ObservedObject var model: SourcePickerModel
    @ObservedObject var controller: AnnotationController
    @State private var isOpenerHovered = false
    /// The picker's size, which its corner changes; Tilde remembers it.
    @AppStorage("SourcePickerWidth") private var width = 560.0
    @AppStorage("SourcePickerHeight") private var height = 340.0
    /// The size when the corner's drag began.
    @State private var resizeStart: CGSize?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: controller.isSourcePickerOpen ? 16 : 18)
        ZStack {
            if controller.isSourcePickerOpen {
                picker
                    .transition(.opacity)
            } else {
                opener
                    .transition(.opacity)
            }
        }
        .background(shape.fill(Color.tildeInk))
        .clipShape(shape)
        // A stroke takes the clicks inside its shape too.
        .overlay(shape.strokeBorder(Color.white.opacity(0.1)).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 4)
        .environment(\.colorScheme, .dark)
    }

    private var opener: some View {
        Button {
            controller.openSourcePicker()
        } label: {
            HStack(spacing: HUDMetrics.iconGap) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12, weight: .semibold))
                Text("Use window picker")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.leading, HUDMetrics.leadingInset)
            .padding(.trailing, HUDMetrics.trailingInset)
            .frame(height: 36)
            .background(Color.white.opacity(isOpenerHovered ? 0.09 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isOpenerHovered = $0 }
        .fixedSize()
    }

    private var picker: some View {
        VStack(spacing: 14) {
            Picker("Source", selection: $model.tab) {
                Text("Screens").tag(SourcePickerModel.Tab.screens)
                Text("Windows").tag(SourcePickerModel.Tab.windows)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                HUDButton(image: Image(systemName: "xmark"), size: 26, help: "Back to clicking on screen") {
                    controller.closeSourcePicker()
                }
            }
            .onChange(of: model.tab) {
                model.openApp = nil
            }

            switch model.tab {
            case .screens:
                grid {
                    ForEach(model.screens) { tile in
                        tileButton(tile)
                    }
                }
            case .windows:
                if let app = model.apps.first(where: { $0.pid == model.openApp }) {
                    VStack(alignment: .leading, spacing: 10) {
                        BackButton(title: app.name) { model.openApp = nil }
                            .padding(.leading, -8)
                        grid {
                            ForEach(app.windows) { tile in
                                tileButton(tile)
                            }
                        }
                    }
                } else {
                    grid {
                        ForEach(model.apps) { app in
                            SourceTile(
                                title: app.name, detail: app.windows.count == 1 ? "1 window" : "\(app.windows.count) windows",
                                picture: app.windows.first?.picture, badge: app.icon, isSelected: controller.scope?.pid == app.pid
                            ) {
                                // An app with one window has nothing more to choose.
                                if app.windows.count == 1 {
                                    controller.choose(app.windows[0].source)
                                } else {
                                    model.openApp = app.pid
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, HUDMetrics.leadingInset)
        .padding(.vertical, 14)
        .frame(width: width, height: height)
        // It stays centred under the pill, so it grows on both sides.
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip { distance in
                let start = resizeStart ?? CGSize(width: width, height: height)
                resizeStart = start
                width = min(max(start.width + 2 * distance.width, Self.sizes.min.width), Self.sizes.max.width)
                height = min(max(start.height + distance.height, Self.sizes.min.height), Self.sizes.max.height)
            } onEnded: {
                resizeStart = nil
            }
        }
    }

    private func tileButton(_ tile: SourcePickerModel.Tile) -> some View {
        SourceTile(title: tile.title, detail: tile.detail, picture: tile.picture, badge: nil, isSelected: controller.source?.id == tile.id) {
            controller.choose(tile.source)
        }
    }

    /// The tiles in the rest of the picker, scrolling when they do not fit.
    private func grid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 14, content: content)
        }
        .frame(maxHeight: .infinity)
    }
}

/// A source in the picker: its picture in a 16:10 frame, so the titles line up, then its title
/// and a grey detail line.
private struct SourceTile: View {
    let title: String
    let detail: String
    let picture: CGImage?
    /// An app's icon on the picture's corner.
    let badge: NSImage?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Color.white.opacity(0.06)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay {
                        if let picture {
                            Image(decorative: picture, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .padding(6)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let badge {
                            Image(nsImage: badge)
                                .resizable()
                                .frame(width: 24, height: 24)
                                .padding(4)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isSelected ? Color.tildeBlue : .white.opacity(isHovered ? 0.24 : 0.1), lineWidth: isSelected ? 2 : 1)
                    )
                    .padding(.bottom, 4)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(detail)
    }
}

/// "‹ App name" above an app's windows, back to the list of apps.
private struct BackButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(isHovered ? 0.09 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
