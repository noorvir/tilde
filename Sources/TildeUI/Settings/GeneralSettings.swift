import TildeCore
import ServiceManagement
import SwiftUI

struct GeneralSettings: View {
    @ObservedObject var model: SettingsModel
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    private var address: String {
        "http://127.0.0.1:\(model.server.port)/mcp"
    }

    var body: some View {
        let permissions = model.permissions()

        VStack(alignment: .leading, spacing: 28) {
            SettingsSection("Application") {
                SettingsRow(title: "Launch at login", subtitle: launchError, subtitleIsError: launchError != nil) {
                    Toggle("Launch at login", isOn: $launchesAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: launchesAtLogin) { _, isOn in
                            setLaunchAtLogin(isOn)
                        }
                }
                SettingsDivider()
                PermissionRow(title: "Screen Recording", subtitle: "Screenshots of any app", isAllowed: permissions.screenRecording) {
                    CGRequestScreenCaptureAccess()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                SettingsDivider()
                PermissionRow(title: "Accessibility", subtitle: "Element details in native apps", isAllowed: permissions.accessibility) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }

            SettingsSection("Connection") {
                SettingsRow(title: "MCP server", subtitle: "\(address) · \(statusText)") {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address, forType: .string)
                    }
                    .buttonStyle(SettingsButtonStyle())
                }
                SettingsDivider()
                SettingsRow(title: "Feedback inbox", subtitle: tildePath(inboxRoot)) {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(inboxRoot)
                    }
                    .buttonStyle(SettingsButtonStyle())
                }
            }

            SettingsSection("HUD") {
                SettingsRow(title: "Position", subtitle: "Back to the top centre of each screen") {
                    Button("Reset", action: model.onResetHUD)
                        .buttonStyle(SettingsButtonStyle())
                }
            }
        }
    }

    private var statusText: String {
        switch model.server.status {
        case .starting: "Starting"
        case .ready: "Running"
        case .failed: "Port in use"
        }
    }

    private func setLaunchAtLogin(_ isOn: Bool) {
        do {
            if isOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = "Could not change: \(error.localizedDescription)"
        }
    }
}

/// A permission with a green or grey dot after its name, and a button while it is missing.
private struct PermissionRow: View {
    let title: String
    let subtitle: String
    let isAllowed: Bool
    let openSettings: () -> Void

    var body: some View {
        SettingsRow(title: title, subtitle: isAllowed ? subtitle : "Not allowed. \(subtitle) needs it.") {
            Circle()
                .fill(isAllowed ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
                .accessibilityLabel(isAllowed ? "Allowed" : "Not allowed")
        } trailing: {
            if !isAllowed {
                Button("Open Settings", action: openSettings)
                    .buttonStyle(SettingsButtonStyle())
            }
        }
    }
}
