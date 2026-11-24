import TildeInstaller
import SwiftUI

struct AgentSettings: View {
    @ObservedObject var setup: AgentSetup
    @Binding var expanded: Set<String>
    @Binding var commandDraft: String?
    var onResult: (InstallResult) -> Void = { _ in }
    /// Opens a machine's page.
    var open: (String) -> Void = { _ in }

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
                .disabled(rows.isEmpty)
            }

            CommandSection(setup: setup, draft: $commandDraft, onResult: onResult)

            NodesSection(nodes: setup.nodes, open: open)

            SettingsSection("Other agents") {
                SettingsRow(title: "Copy setup", subtitle: "For agents not listed") {
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

/// The command that starts Tilde in every agent: a field and Change, which moves Tilde's
/// skill to the new name in each app that has Tilde.
private struct CommandSection: View {
    @ObservedObject var setup: AgentSetup
    @Binding var draft: String?
    let onResult: (InstallResult) -> Void

    var body: some View {
        let text = draft ?? setup.command
        let name = text.trimmingCharacters(in: .whitespaces)
        let problem = CommandName.problem(name)
        let canChange = name != setup.command && problem == nil

        SettingsSection("Command") {
            SettingsRow(title: "Command name", subtitle: problem ?? "Type /\(setup.command) in an agent to start Tilde; in Codex, $\(setup.command).", subtitleIsError: problem != nil) {
                HStack(spacing: 8) {
                    TextField("Command name", text: Binding { text } set: { draft = $0 }, prompt: Text(CommandName.standard))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .font(.system(size: 13, design: .monospaced))
                        .frame(width: 150)
                        .onSubmit(change)
                    Button("Change", action: change)
                        .disabled(!canChange)
                }
            }
        }
    }

    private func change() {
        let name = (draft ?? setup.command).trimmingCharacters(in: .whitespaces)
        guard name != setup.command, CommandName.problem(name) == nil else {
            return
        }
        draft = nil
        onResult(setup.rename(to: name))
    }
}

/// Icon, name and status dot, a switch (on = installed) and a chevron; open, the files. When
/// the command name is another skill's in the app, a warning under it that asks for another name.
struct AgentRow: View {
    @ObservedObject var setup: AgentSetup
    let row: AgentSetup.Row
    @Binding var isExpanded: Bool
    let onResult: (InstallResult) -> Void

    var body: some View {
        let status = setup.status(of: row)
        let skill = setup.skillStatus(row.harness)

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
                SettingsToggle(row.name, isOn: installed(status))
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

            if case .taken(let conflict) = skill {
                ConflictWarning(conflict: conflict) {
                    setup.askForName([conflict])
                }
                .padding(.leading, 16 + 12 + 10 + 24 + 10)
                .padding(.trailing, 16)
                .padding(.bottom, 12)
            }

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
            if !setup.isRemote {
                Button("Show Files in Finder") {
                    revealInFinder(setup.installer.configFile(for: row.harness))
                }
            }
        }
    }

    /// On when Tilde is in the app; turning it on installs, off uninstalls.
    private func installed(_ status: InstallStatus) -> Binding<Bool> {
        Binding {
            status == .installed
        } set: { isOn in
            onResult(isOn ? setup.install([row]) : setup.uninstall([row]))
        }
    }

    private var files: some View {
        let installer = setup.installer

        return VStack(alignment: .leading, spacing: 2) {
            SetupItemRow(
                title: "MCP server", state: SetupState.of(setup.status(of: row)),
                file: installer.configFile(for: row.harness), isLocalFile: !setup.isRemote
            ) {
                onResult(setup.install([row]))
            }
            SetupItemRow(
                title: row.harness == .gemini ? "command" : "skill", code: installer.invocation(for: row.harness),
                state: SetupState.of(setup.skillStatus(row.harness)),
                file: installer.skillFile(for: row.harness), isLocalFile: !setup.isRemote
            ) {
                onResult(setup.install([row]))
            }
        }
    }
}

/// A yellow warning that the command name is another skill's or command's, and a button that
/// asks for another name.
private struct ConflictWarning: View {
    let conflict: Conflict
    let chooseName: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text("\(conflict.message) Choose another command name.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 16)
            Button("Choose Name", action: chooseName)
                .controlSize(.small)
        }
    }
}

/// While the beta is on (see Configuration), the machines that an agent can use Tilde from,
/// over ssh: each opens its own page.
private struct NodesSection: View {
    @ObservedObject var nodes: NodeSetup
    let open: (String) -> Void

    var body: some View {
        if nodes.isEnabled {
            SettingsSection("Remote machines") {
                NodeRows(nodes: nodes, open: open)
            }
        }
    }
}

private struct NodeRows: View {
    @ObservedObject var nodes: NodeSetup
    let open: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if nodes.rows.isEmpty {
                SettingsRow(title: "No machines found", subtitle: "Machines in your ssh config show here") {
                    EmptyView()
                }
            }
            ForEach(Array(nodes.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    SettingsDivider()
                }
                Button {
                    open(row.host)
                } label: {
                    HStack {
                        MachineLabel(row: row)
                        Spacer(minLength: 16)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 58)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.host)
                .accessibilityValue("\(row.text). \(row.dot.reason)")
            }
        }
        .task {
            nodes.refresh()
        }
    }
}

/// A machine's icon with its status dot, its name, and its status.
struct MachineLabel: View {
    let row: NodeSetup.Row

    var body: some View {
        HStack(spacing: 10) {
            MachineIcon(dot: row.dot)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.host)
                    .font(.system(size: 14))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .help(row.detail ?? "")
    }

    private var subtitle: String {
        var parts = [row.text]
        if row.needsMove {
            parts.append("Not protected (linked by a port): Install again to protect it")
        } else if row.status.isInstalled, !row.isProtected {
            parts.append("Not protected (linked by a port)")
        }
        if let note = row.note {
            parts.append(note)
        }
        if !row.aliases.isEmpty {
            parts.append("Also \(row.aliases.joined(separator: ", "))")
        }
        return parts.joined(separator: ". ")
    }
}

/// One machine: its status with Install or Remove, then its agents in the same rows as the
/// apps on this Mac.
struct MachineSettings: View {
    @ObservedObject var nodes: NodeSetup
    let host: String
    @Binding var expanded: Set<String>
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .frame(width: 14, height: 18)
                }
                .help("Back to Agents")
                .accessibilityLabel("Back")
                Text(host)
                    .font(.system(size: 20, weight: .semibold))
            }
            if let row = nodes.rows.first(where: { $0.host == host }) {
                SettingsSection("Machine") {
                    HStack {
                        MachineLabel(row: row)
                        Spacer(minLength: 16)
                        // A node to move to its socket has one Install for all its apps.
                        let removes = row.status.isInstalled && !row.needsMove
                        Button {
                            if removes {
                                nodes.uninstall(host)
                            } else {
                                nodes.install(host)
                            }
                        } label: {
                            // While it works, the button keeps its width and its name.
                            ZStack {
                                Text(removes ? "Remove" : "Install")
                                    .opacity(row.isWorking ? 0 : 1)
                                if row.isWorking {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(row.isWorking)
                        .accessibilityLabel("\(removes ? "Remove" : "Install") \(host)")
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 58)
                    SettingsDivider()
                    VStack(spacing: 2) {
                        SetupItemRow(title: "Reachable over ssh", state: NodeSetup.reachableState(of: row)) {
                            nodes.refresh()
                        }
                        SetupItemRow(title: "Linked to this Mac", state: NodeSetup.linkState(of: row)) {
                            if row.status.isInstalled {
                                nodes.reconnect(host)
                            } else {
                                nodes.install(host)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            MachineAgents(nodes: nodes, host: host, expanded: $expanded)
        }
        .task {
            await nodes.loadSetup(host)
        }
    }
}

private struct MachineAgents: View {
    @ObservedObject var nodes: NodeSetup
    let host: String
    @Binding var expanded: Set<String>

    var body: some View {
        SettingsSection("Agents") {
            if let setup = nodes.setups[host] {
                MachineAgentRows(setup: setup, host: host, expanded: $expanded)
                    .disabled(nodes.isWorking(host))
            } else {
                SettingsRow(title: "Looking for agents", subtitle: "Over ssh") {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }
}

private struct MachineAgentRows: View {
    @ObservedObject var setup: AgentSetup
    let host: String
    @Binding var expanded: Set<String>

    var body: some View {
        let rows = setup.foundRows
        if rows.isEmpty {
            SettingsRow(title: "No agent apps found", subtitle: "Tilde looks for the same apps as on this Mac") {
                EmptyView()
            }
        }
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            if index > 0 {
                SettingsDivider()
            }
            AgentRow(setup: setup, row: row, isExpanded: Binding {
                expanded.contains("\(host)/\(row.id)")
            } set: { isOpen in
                if isOpen {
                    expanded.insert("\(host)/\(row.id)")
                } else {
                    expanded.remove("\(host)/\(row.id)")
                }
            }, onResult: { _ in })
        }
    }
}
