import TildeInstaller
import SwiftUI

struct AgentSettings: View {
    @ObservedObject var setup: AgentSetup
    @Binding var expanded: Set<String>
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

            NodesSection(nodes: setup.nodes, open: open)

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
struct AgentRow: View {
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
                    .controlSize(.mini)
                    .tint(Color.tildeBlue)
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
            if !setup.isRemote {
                Button("Show Files in Finder") {
                    if let harness = setup.present(row).first {
                        revealInFinder(setup.installer.configFile(for: harness))
                    }
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
        // MCP configs, then skills. Apps that share a skill folder list it once;
        // a path listed twice would also share its hover underline.
        let harnesses = setup.present(row)
        let ordered = harnesses.map(installer.configFile(for:)) + harnesses.map(installer.skillFile(for:))
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
            if let diagnosis = setup.diagnosis(of: row) {
                DiagnosisLine(diagnosis: diagnosis) {
                    switch diagnosis.fix {
                    case .setUp:
                        onResult(setup.install([row]))
                    case .showFile:
                        if let harness = setup.present(row).first {
                            revealInFinder(setup.installer.configFile(for: harness))
                        }
                    case nil:
                        break
                    }
                }
                .padding(.bottom, 4)
            }
            ForEach(urls, id: \.self) { url in
                if setup.isRemote {
                    Text(tildePath(url, home: home))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    PathText(path: tildePath(url, home: home), url: url)
                }
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

/// Why something is not green, and a button that fixes it.
struct DiagnosisLine: View {
    let reason: String
    let fixTitle: String?
    let fix: () -> Void

    init(diagnosis: Diagnosis, fix: @escaping () -> Void) {
        reason = diagnosis.reason
        fixTitle = switch diagnosis.fix {
        case .setUp: "Set Up"
        case .showFile: "Show File"
        case nil: nil
        }
        self.fix = fix
    }

    init(reason: String, fixTitle: String?, fix: @escaping () -> Void) {
        self.reason = reason
        self.fixTitle = fixTitle
        self.fix = fix
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(reason)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let fixTitle {
                Button(fixTitle, action: fix)
            }
        }
    }
}

/// The machines that an agent can use Tilde from, over ssh: each opens its own page.
private struct NodesSection: View {
    @ObservedObject var nodes: NodeSetup
    let open: (String) -> Void

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
                .accessibilityValue("\(row.status.text). \(row.dot.reason)")
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
            Image(systemName: "laptopcomputer")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
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
            }
        }
        .help(row.detail ?? "")
    }

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
                        Button {
                            if row.status.isInstalled {
                                nodes.uninstall(host)
                            } else {
                                nodes.install(host)
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
                        .disabled(row.status.isWorking)
                        .accessibilityLabel("\(row.status.isInstalled ? "Remove" : "Install") \(host)")
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 58)
                    if let diagnosis = NodeSetup.diagnosis(of: row) {
                        SettingsDivider()
                        DiagnosisLine(reason: diagnosis.reason, fixTitle: diagnosis.fix?.title) {
                            switch diagnosis.fix {
                            case .install:
                                nodes.install(host)
                            case .reconnect:
                                nodes.reconnect(host)
                            case .checkAgain:
                                nodes.refresh()
                            case nil:
                                break
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
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
