import TildeInstaller
import SwiftUI

/// The colours of the Settings window, light and dark.
enum SettingsColors {
    static let sidebar = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.95, alpha: 1)
    })
    static let content = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 0.12, alpha: 1) : NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
    })
    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 0.18, alpha: 1) : .white
    })
    /// The selected sidebar row: white in light, a lighter grey than the sidebar in dark.
    static let selection = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 0.27, alpha: 1) : .white
    })
}

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// A header over a card, with an optional control at its right.
struct SettingsSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @ViewBuilder let accessory: Accessory

    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                accessory
            }
            .frame(minHeight: 24)

            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(SettingsColors.card))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A hairline between rows, inset 16 pt on both sides.
struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 16)
    }
}

/// A title, an optional subtitle under it, and a control on the right.
struct SettingsRow<Accessory: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    var subtitleIsError = false
    /// Next to the title, such as a status dot.
    @ViewBuilder var accessory: Accessory
    @ViewBuilder let trailing: Trailing

    init(
        title: String, subtitle: String? = nil, subtitleIsError: Bool = false,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleIsError = subtitleIsError
        self.accessory = accessory()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.system(size: 14))
                    accessory
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(subtitleIsError ? Color.red : Color.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 16)
        .frame(minHeight: subtitle == nil ? 50 : 58)
    }
}

/// Buttons in Settings: white with a hairline border, grey for header actions, or blue for
/// the main action. 13 pt text, 7 pt corners.
struct SettingsButtonStyle: ButtonStyle {
    enum Kind {
        case plain
        case gray
        case primary
    }

    var kind: Kind = .plain

    func makeBody(configuration: Configuration) -> some View {
        SettingsButton(configuration: configuration, kind: kind)
    }

    private struct SettingsButton: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(kind == .primary ? Color.white : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(fill))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.primary.opacity(kind == .plain ? 0.14 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
        }

        private var fill: Color {
            switch kind {
            case .plain: SettingsColors.card
            case .gray: Color.primary.opacity(0.07)
            case .primary: .tildeBlue
            }
        }
    }
}

/// A path on one line in grey: truncated in the middle, in full as a tooltip. A click shows the
/// file in Finder; under the pointer the path gets an underline and a hand.
struct PathText: View {
    let path: String
    let url: URL
    @State private var isHovered = false

    var body: some View {
        Button {
            revealInFinder(url)
        } label: {
            Text(path)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .underline(isHovered)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .help("\(path)\nClick to show in Finder")
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

/// Green: installed. Yellow: partly installed. Red: error. Grey: not installed.
struct StatusDot: View {
    let status: InstallStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .help(status.label)
            .accessibilityLabel(status.label)
    }

    private var color: Color {
        switch status {
        case .installed: .green
        case .partlyInstalled: .yellow
        case .failed: .red
        case .notInstalled, .notFound: Color.secondary.opacity(0.5)
        }
    }
}

extension InstallStatus {
    var label: String {
        switch self {
        case .installed: "Installed"
        case .partlyInstalled: "Partly installed"
        case .notInstalled, .notFound: "Not installed"
        case .failed: "Error"
        }
    }
}

/// A path with the home folder as `~`.
func tildePath(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
    let home = home.path
    let path = url.path
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

/// Shows the file in Finder, or its folder when the file does not exist yet.
func revealInFinder(_ url: URL) {
    if FileManager.default.fileExists(atPath: url.path) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
        NSWorkspace.shared.open(url.deletingLastPathComponent())
    }
}
