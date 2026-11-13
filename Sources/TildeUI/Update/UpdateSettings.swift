import SwiftUI

/// The Updates card of the Configuration page: where the update is, with the one action that
/// fits, and whether updates download by themselves.
struct UpdateSettings: View {
    @ObservedObject var updates: Updates
    /// The running version, such as "0.2.0 (361)".
    let version: String

    var body: some View {
        SettingsSection("Updates") {
            SettingsRow(title: title, subtitle: subtitle, subtitleIsError: isFailed) {
                action
            }
            SettingsDivider()
            SettingsRow(title: "Update automatically", subtitle: "Installs updates and reopens Tilde when you are not using it") {
                Toggle("Update automatically", isOn: $updates.isAutomatic)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Color.tildeBlue)
                    .labelsHidden()
            }
        }
    }

    private var title: String {
        switch updates.status {
        case .idle, .checking, .upToDate, .failed: "Tilde \(version)"
        case .available(let version): "Tilde \(version) is available"
        case .downloading(let version, _): "Downloading Tilde \(version)"
        case .ready(let version): "Tilde \(version) is ready"
        }
    }

    private var subtitle: String {
        switch updates.status {
        case .idle: "Checks for a newer version once a day"
        case .checking: "Checking for updates"
        case .upToDate: "Up to date"
        case .available: "You have \(version)"
        case .downloading(_, let progress?): "\(Int(progress * 100))% downloaded"
        case .downloading(_, nil): "Starting the download"
        case .ready: readySubtitle
        case .failed(let reason): reason
        }
    }

    private var readySubtitle: String {
        if updates.isAutomatic {
            return "Installs when you are not using Tilde"
        }
        if updates.isSessionActive {
            return "Installs when you quit Tilde, or restart after this session"
        }
        return "Installs when you quit Tilde"
    }

    private var isFailed: Bool {
        if case .failed = updates.status {
            return true
        }
        return false
    }

    @ViewBuilder
    private var action: some View {
        switch updates.status {
        case .idle, .upToDate:
            Button("Check for updates", action: updates.check)
        case .checking:
            LoadingButton(title: "Check for updates", isLoading: true) {}
        case .available:
            Button("Install", action: updates.install)
        case .downloading:
            LoadingButton(title: "Install", isLoading: true) {}
        case .ready:
            Button("Restart", action: updates.restart)
                .disabled(!updates.canRestart)
        case .failed:
            Button("Retry", action: updates.check)
        }
    }
}

/// A button whose label gives way to a spinner of the same place while it works; its name stays.
private struct LoadingButton: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(isLoading)
        .accessibilityLabel(title)
    }
}
