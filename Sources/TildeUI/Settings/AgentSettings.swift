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

            NodesSection(nodes: setup.nodes, setup: setup, expanded: $expanded)

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
                    .toggleStyle(.switch)
                    .tint(.accentColor)
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
    let setup: AgentSetup
    @Binding var expanded: Set<String>

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
                NodeRow(nodes: nodes, setup: setup, row: row, isExpanded: Binding {
                    expanded.contains(row.id)
                } set: { isOpen in
                    if isOpen {
                        expanded.insert(row.id)
                    } else {
                        expanded.remove(row.id)
                    }
                })
            }
        }
        .task {
            nodes.refresh()
        }
    }
}

private struct NodeRow: View {
    let nodes: NodeSetup
    let setup: AgentSetup
    let row: NodeSetup.Row
    @Binding var isExpanded: Bool

    private var dotColor: Color {
        switch row.dot {
        case .green: .green
        case .yellow: .yellow
        case .grey: .gray
        case .red: .red
        }
    }

    private var subtitle: String {
        var parts = [row.status.text]
        if let note = row.note {
            parts.append(note)
        }
        if !row.aliases.isEmpty {
            parts.append("Also \(row.aliases.joined(separator: ", "))")
        }
        return parts.joined(separator: ". ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            machine
            if isExpanded {
                ForEach(row.agents) { agent in
                    SettingsDivider()
                    agentRow(agent)
                }
            }
        }
    }

    private func agentRow(_ agent: NodeSetup.Agent) -> some View {
        HStack(spacing: 10) {
            Text(agent.harness.name)
                .font(.system(size: 14))
            if agent.isOnMachine {
                StatusDot(status: agent.status)
            } else {
                Text("Not on this machine")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Toggle(agent.harness.name, isOn: Binding {
                row.status.isInstalled ? agent.status == .installed : agent.isChosen
            } set: { isOn in
                nodes.setInstalled(agent.harness, isOn, on: row.host)
            })
            .toggleStyle(.switch)
            .tint(.accentColor)
            .labelsHidden()
            .disabled(!agent.isOnMachine || row.status.isWorking)
        }
        .padding(.leading, 16 + 12 + 10)
        .padding(.trailing, 16)
        .frame(height: 44)
    }

    private var machine: some View {
        HStack(spacing: 12) {
            // A disclosure on the left that turns down, as for the apps above.
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(row.agents.isEmpty ? .tertiary : .secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)
            Image(systemName: "laptopcomputer")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 8, height: 8)
                        .offset(x: 3, y: -1)
                }
                .help(row.dot.reason)
                .accessibilityLabel(row.dot.reason)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.host)
                    .font(.system(size: 14))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Button {
                if !row.status.isInstalled {
                    nodes.install(row.host)
                } else {
                    nodes.uninstall(row.host)
                }
            } label: {
                // While it works, the button keeps its width and its name.
                ZStack {
                    Text(row.status.isInstalled ? "Remove" : "Install")
                        .opacity(row.status.isWorking ? 0 : 1)
                    if row.status.isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .buttonStyle(SettingsButtonStyle())
            .disabled(row.status.isWorking)
            .accessibilityLabel("\(row.status.isInstalled ? "Remove" : "Install") \(row.host)")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        }
        .help(row.detail ?? "")
    }
}

