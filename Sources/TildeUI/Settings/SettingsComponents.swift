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
    /// Shown as code before the subtitle, such as an address.
    var subtitleCode: String?
    /// Next to the title, such as a status dot.
    @ViewBuilder var accessory: Accessory
    @ViewBuilder let trailing: Trailing

    init(
        title: String, subtitle: String? = nil, subtitleIsError: Bool = false, subtitleCode: String? = nil,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleIsError = subtitleIsError
        self.subtitleCode = subtitleCode
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
                if subtitle != nil || subtitleCode != nil {
                    HStack(spacing: 5) {
                        if let subtitleCode {
                            InlineCode(subtitleCode)
                                .foregroundStyle(Color.secondary)
                        }
                        if let subtitle {
                            // Wraps rather than truncating.
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(subtitleIsError ? Color.red : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 16)
        .frame(minHeight: subtitle == nil && subtitleCode == nil ? 50 : 58)
    }
}

/// A command, path or address in running text: monospaced, on a light rounded chip.
struct InlineCode: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
}

/// The system's bordered button with a slightly darker fill under the pointer, which the
/// system's own does not have.
struct SettingsButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.bordered)
            .modifier(HoverFill())
    }

    private struct HoverFill: ViewModifier {
        @State private var isHovered = false
        @Environment(\.colorScheme) private var colorScheme

        func body(content: Content) -> some View {
            content
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.07))
                        .opacity(isHovered ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .onHover { isHovered = $0 }
        }
    }
}

/// Where one thing that Tilde sets up stands, shown at the right of its row.
enum SetupState: Equatable {
    case ok
    /// A button that sets it up, such as "Set Up" or "Grant".
    case action(String)
    /// It failed; the reason goes in the tooltip, and a button tries again.
    case error(reason: String, action: String)
    /// It does not apply here, such as an app that the machine does not have.
    case notApplicable(String)

    /// The state of an app's entry or skill from its install status.
    static func of(_ status: InstallStatus) -> SetupState {
        switch status {
        case .installed: .ok
        case .notInstalled: .action("Set Up")
        case .failed(let message): .error(reason: message, action: "Retry")
        case .notFound: .notApplicable("Not on this machine")
        }
    }
}

/// The trailing status of a sub-row: a green check, a small button, a red cross with a button,
/// or grey text, all in the column of the switches above.
struct SetupStatus: View {
    let state: SetupState
    let action: () -> Void

    var body: some View {
        switch state {
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Set up")
        case .action(let title):
            Button(title, action: action)
                .controlSize(.small)
        case .error(let reason, let title):
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .help(reason)
                    .accessibilityLabel(reason)
                Button(title, action: action)
                    .controlSize(.small)
            }
        case .notApplicable(let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

/// One thing that Tilde sets up: its plain name at the left, its status at the right. The file,
/// when there is one, is in its context menu.
struct SetupItemRow: View {
    let title: String
    /// Shown as code before the title, such as `/tilde` before "skill".
    var code: String?
    let state: SetupState
    var file: URL?
    /// Whether the file is on this Mac, so Finder can show it.
    var isLocalFile = true
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                if let code {
                    InlineCode(code)
                }
                Text(title)
                    .font(.system(size: 13))
            }
            Spacer(minLength: 16)
            SetupStatus(state: state, action: action)
        }
        .frame(minHeight: 26)
        .contentShape(Rectangle())
        .contextMenu {
            if let file {
                if isLocalFile {
                    Button("Show in Finder") {
                        revealInFinder(file)
                    }
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
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

/// Green: installed. Red: error. Grey: not installed.
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
        case .failed: .red
        case .notInstalled, .notFound: Color.secondary.opacity(0.5)
        }
    }
}

extension InstallStatus {
    var label: String {
        switch self {
        case .installed: "Installed"
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

