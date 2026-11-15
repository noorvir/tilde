import SwiftUI

/// The window grid under the recording bar, from the source menu's "Show all windows": a card
/// in the style of the HUD's list, with apps and then their windows. "All apps" and Esc go from
/// an app's windows back to the apps; Esc there closes the grid.
struct HUDWindowGrid: View {
    /// As many columns as fit; tiles past the grid's height scroll.
    private static let columns = [GridItem(.adaptive(minimum: HUDAccessory.size.scaled(150)), spacing: HUDAccessory.size.scaled(12), alignment: .top)]
    /// The grid stays inside the HUD's panel, and inside the room under the pill.
    static let sizes = (
        min: CGSize(width: HUDAccessory.size.scaled(460), height: HUDAccessory.size.scaled(260)),
        max: CGSize(width: HUDAccessory.size.scaled(780), height: HUDAccessory.size.scaled(900))
    )

    @ObservedObject var model: SourcePickerModel
    /// The window that Record records, which shows as chosen.
    let selectedID: String
    /// "All apps", one level back as Esc.
    let onBack: () -> Void
    let onChoose: (RecordingSource) -> Void
    /// The size the user gave it with its corner, saved when the drag ends.
    @AppStorage("SourcePickerWidth") private var savedWidth = Double(HUDAccessory.size.scaled(560))
    /// Two full rows of tiles at the default width.
    @AppStorage("SourcePickerHeight") private var savedHeight = Double(HUDAccessory.size.scaled(390))
    /// The size while its corner is dragged, and the size when the drag began.
    @State private var resizing: (start: CGSize, size: CGSize)?

    private var size: CGSize {
        let largest = CGSize(width: min(Self.sizes.max.width, model.space.width), height: min(Self.sizes.max.height, model.space.height))
        return fitted(resizing?.size ?? CGSize(width: savedWidth, height: savedHeight), min: Self.sizes.min, max: largest)
    }

    var body: some View {
        content
            .padding(.horizontal, HUDAccessory.size.scaled(PillMetrics.leadingInset))
            .padding(.vertical, HUDAccessory.size.scaled(14))
            .frame(width: size.width, height: size.height)
            // It stays centred under the pill, so it grows on both sides.
            .overlay(alignment: .bottomTrailing) {
                ResizeGrip { distance in
                    let start = resizing?.start ?? size
                    resizing = (start, CGSize(width: start.width + 2 * distance.width, height: start.height + distance.height))
                } onEnded: {
                    let final = size
                    savedWidth = final.width
                    savedHeight = final.height
                    resizing = nil
                }
            }
            .hudCard(cornerRadius: HUDAccessory.size.scaled(16))
            .environment(\.pillSize, HUDAccessory.size)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        let openApp = model.apps.first { $0.pid == model.openApp }
        switch model.phase {
        case .listing:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            message("Could not list the windows", "Tilde needs Screen Recording in System Settings → Privacy & Security.")
        case .picturing, .done:
            if let openApp {
                VStack(alignment: .leading, spacing: HUDAccessory.size.scaled(10)) {
                    CardButton(symbol: "chevron.left", title: "All apps", keys: ["Esc"], help: "Back") {
                        onBack()
                    }
                    Text(openApp.name)
                        .font(.system(size: HUDAccessory.size.font(12.5), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    grid {
                        ForEach(openApp.windows) { tile in
                            tileButton(tile)
                        }
                    }
                }
            } else if model.apps.isEmpty {
                message("No windows", "Windows on screen show here.")
            } else {
                grid {
                    ForEach(model.apps) { app in
                        SourceTile(
                            title: app.name, detail: app.windows.count == 1 ? "1 window" : "\(app.windows.count) windows",
                            picture: app.windows.first?.picture, isLoading: model.phase == .picturing, badge: app.icon, isSelected: app.windows.contains { $0.id == selectedID }
                        ) {
                            // An app with one window has nothing more to choose.
                            if app.windows.count == 1 {
                                onChoose(app.windows[0].source)
                            } else {
                                model.openApp = app.pid
                            }
                        }
                    }
                }
            }
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: HUDAccessory.size.scaled(4)) {
            Text(title)
                .font(.system(size: HUDAccessory.size.font(12.5), weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text(detail)
                .font(.system(size: HUDAccessory.size.font(11)))
                .foregroundStyle(.white.opacity(0.5))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tileButton(_ tile: SourcePickerModel.Tile) -> some View {
        SourceTile(
            title: tile.title, detail: tile.detail, picture: tile.picture, isLoading: model.phase == .picturing, badge: nil,
            isSelected: selectedID == tile.id
        ) {
            onChoose(tile.source)
        }
    }

    /// The tiles in the rest of the grid, scrolling when they do not fit.
    private func grid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: HUDAccessory.size.scaled(14), content: content)
        }
        .frame(maxHeight: .infinity)
    }
}

/// A window, or an app, in the grid: its picture in a 16:10 frame, so the titles line up, then its title
/// and a grey detail line.
private struct SourceTile: View {
    let title: String
    let detail: String
    let picture: CGImage?
    /// Its picture is still being taken; once done, a missing one shows as a plain symbol.
    let isLoading: Bool
    /// An app's icon on the picture's corner.
    let badge: NSImage?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.pillSize) private var pillSize

    var body: some View {
        Button(action: action) {
            VStack(spacing: pillSize.scaled(3)) {
                Color.white.opacity(0.06)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay {
                        if let picture {
                            Image(decorative: picture, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: pillSize.scaled(4)))
                                .padding(pillSize.scaled(6))
                        } else if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "eye.slash")
                                .font(.system(size: pillSize.font(14)))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let badge {
                            Image(nsImage: badge)
                                .resizable()
                                .frame(width: pillSize.scaled(24), height: pillSize.scaled(24))
                                .padding(pillSize.scaled(4))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: pillSize.scaled(10)))
                    .overlay(
                        RoundedRectangle(cornerRadius: pillSize.scaled(10))
                            .strokeBorder(isSelected ? Color.tildeBlue : .white.opacity(isHovered && isEnabled ? 0.24 : 0.1), lineWidth: isSelected ? 2 : 1)
                    )
                    .padding(.bottom, pillSize.scaled(4))
                Text(title)
                    .font(.system(size: pillSize.font(12), weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: pillSize.font(10.5), weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(detail)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
