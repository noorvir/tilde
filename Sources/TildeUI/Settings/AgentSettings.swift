import TildeInstaller
import SwiftUI

struct AgentSettings: View {
    @ObservedObject var setup: AgentSetup
    @Binding var expanded: Set<String>
    var onResult: (InstallResult) -> Void = { _ in }

    var body: some View {
        let rows = setup.foundRows

        VStack(alignment: .leading, spacing: 28) {
            SettingsSection("Apps on this Mac") {
                if rows.isEmpty {
                    SettingsRow(title: "No agent apps found", subtitle: "Use Copy setup below for other agents") {
                        EmptyView()
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        SettingsDivider()
                    }
                    AgentRow(setup: setup, row: row, isExpanded: expandedBinding(row), onResult: onResult)
                }
            } accessory: {
                Button("Install everywhere") {
                    onResult(setup.install(setup.foundRows))
                }
                .buttonStyle(SettingsButtonStyle(kind: .gray))
                .disabled(rows.isEmpty)
            }

            NodesSection(nodes: setup.nodes)

            SettingsSection("Other agents") {
                SettingsRow(title: "Copy setup", subtitle: "For agents not listed or on another machine") {
                    Menu {
                        ForEach(setup.copySetups) { item in
                            Button(item.title) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.text, forType: .string)
                            }
                        }
                    } label: {
                        Text("Copy")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(SettingsButtonStyle())
                    .fixedSize()
                }
            }
        }
    }

    private func expandedBinding(_ row: AgentSetup.Row) -> Binding<Bool> {
        Binding {
            expanded.contains(row.id)
        } set: { isExpanded in
            if isExpanded {
                expanded.insert(row.id)
            } else {
                expanded.remove(row.id)
            }
        }
    }
}

/// Icon, name and status dot, a switch (on = installed) and a chevron; open, the files.
private struct AgentRow: View {
    @ObservedObject var setup: AgentSetup
    let row: AgentSetup.Row
    @Binding var isExpanded: Bool
    let onResult: (InstallResult) -> Void

    var body: some View {
        let status = setup.status(of: row)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // A disclosure on the left that turns down, as in Finder's list view.
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                Image(nsImage: setup.icon(for: row))
                    .resizable()
                    .frame(width: 24, height: 24)
                Text(row.name)
                    .font(.system(size: 14))
                StatusDot(status: status)
                Spacer(minLength: 16)
                Toggle(row.name, isOn: installed(status))
                    .toggleStyle(TildeSwitchStyle())
                    .controlSize(.small)
                    .labelsHidden()
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityHint(isExpanded ? "Hides the files" : "Shows the files")

            if isExpanded {
                files
                    .padding(.leading, 16 + 12 + 10 + 24 + 10)
                    .padding(.trailing, 16)
                    .padding(.bottom, 14)
            }
        }
        .contextMenu {
            Button("Reinstall") {
                onResult(setup.install([row]))
            }
            Button("Show Files in Finder") {
                if let harness = setup.present(row).first {
                    revealInFinder(setup.installer.configFile(for: harness))
                }
            }
        }
    }

    /// On when Tilde is in any of the row's apps; turning it on installs, off uninstalls.
    private func installed(_ status: InstallStatus) -> Binding<Bool> {
        Binding {
            status == .installed || status == .partlyInstalled
        } set: { isOn in
            onResult(isOn ? setup.install([row]) : setup.uninstall([row]))
        }
    }

    private var files: some View {
        let installer = setup.installer
        let home = installer.environment.home
        // MCP configs, then skills, then backups. Apps that share a skill folder list it once;
        // a path listed twice would also share its hover underline.
        let harnesses = setup.present(row)
        let ordered = harnesses.map(installer.configFile(for:)) + harnesses.map(installer.skillFile(for:)) + harnesses.compactMap(installer.latestBackup(for:))
        var urls: [URL] = []
        for url in ordered where !urls.contains(url) {
            urls.append(url)
        }
        let errors = setup.present(row).compactMap { harness -> String? in
            if case .failed(let message) = installer.status(of: harness) {
                return message
            }
            return nil
        }

        return VStack(alignment: .leading, spacing: 4) {
            ForEach(urls, id: \.self) { url in
                PathText(path: tildePath(url, home: home), url: url)
            }
            ForEach(errors, id: \.self) { message in
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }
}

/// The machines that an agent can use Tilde from, over ssh.
private struct NodesSection: View {
    @ObservedObject var nodes: NodeSetup

    var body: some View {
        SettingsSection("Remote machines") {
            if nodes.rows.isEmpty {
                SettingsRow(title: "No machines found", subtitle: "Machines in your ssh config show here") {
                    EmptyView()
                }
            }
            ForEach(Array(nodes.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    SettingsDivider()
                }
                NodeRow(nodes: nodes, row: row)
            }
        }
        .task {
            nodes.refresh()
        }
    }
}

private struct NodeRow: View {
    let nodes: NodeSetup
    let row: NodeSetup.Row

    var body: some View {
        SettingsRow(title: row.host, subtitle: row.note.map { "\(row.status.text). \($0)" } ?? row.status.text) {
            Button {
                if row.status == .notInstalled {
                    nodes.install(row.host)
                } else {
                    nodes.uninstall(row.host)
                }
            } label: {
                // While it works, the button keeps its width and its name.
                ZStack {
                    Text(isInstalled ? "Remove" : "Install")
                        .opacity(row.status == .installing ? 0 : 1)
                    if row.status == .installing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .buttonStyle(SettingsButtonStyle())
            .disabled(row.status == .installing)
            .accessibilityLabel("\(isInstalled ? "Remove" : "Install") \(row.host)")
        }
    }

    private var isInstalled: Bool {
        row.status == .linked || row.status == .unreachable
    }
}

