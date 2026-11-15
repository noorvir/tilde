import AppKit
import SwiftUI
import TildeInstaller

/// Asks for another command name when an install finds the name taken in an app: the reason,
/// a field with a free name, and Install or Cancel. Tilde never changes a skill or command
/// that it did not write, so Install changes the command name, in every app, and installs in
/// the apps that waited.
@MainActor
final class NamePrompt: ObservableObject {
    struct Request {
        let conflicts: [Conflict]
        /// This Mac's setup or a machine's: where the apps wait.
        let setup: AgentSetup
        /// What the install did in the other apps, for the toast after Cancel.
        let pending: InstallResult?
    }

    @Published private(set) var request: Request?
    @Published var name = ""
    /// Why Install could not use the name.
    @Published var problem: String?

    /// Shows the prompt's window, or closes it.
    var onShow: (Bool) -> Void = { _ in }
    /// What the user's answer did, for the toast.
    var onResult: (InstallResult) -> Void = { _ in }

    func ask(_ conflicts: [Conflict], setup: AgentSetup, suggestion: String, pending: InstallResult?) {
        request = Request(conflicts: conflicts, setup: setup, pending: pending)
        name = suggestion
        problem = nil
        onShow(true)
    }

    func install() {
        guard let request, let mac = request.setup.thisMac else {
            return
        }
        let name = name.trimmingCharacters(in: .whitespaces)
        if let problem = CommandName.problem(name) {
            self.problem = problem
            return
        }
        // This Mac's apps are asked now; a machine's apps answer through their install, and
        // a name taken there shows on its page.
        if let taken = mac.foundRows.lazy.compactMap({ mac.installer.conflict(named: name, in: $0.harness) }).first {
            problem = taken.message
            return
        }

        let waiting = AgentSetup.rows.filter { row in request.conflicts.contains { $0.harness == row.harness } }
        self.request = nil
        onShow(false)
        if request.setup.isRemote {
            let result = mac.rename(to: name)
            _ = request.setup.install(waiting)
            if !result.apps.isEmpty {
                onResult(result)
            }
        } else {
            onResult(mac.rename(to: name, installing: waiting))
        }
    }

    func cancel() {
        let pending = request?.pending
        request = nil
        onShow(false)
        if let pending {
            onResult(pending)
        }
    }
}

struct NamePromptView: View {
    @ObservedObject var prompt: NamePrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose another command name")
                .font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array((prompt.request?.conflicts ?? []).enumerated()), id: \.offset) { _, conflict in
                    Text(conflict.message)
                        .font(.system(size: 13))
                }
                Text("Tilde never changes a skill or command that it did not write. The new name is used in every agent.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField("Command name", text: $prompt.name, prompt: Text(CommandName.standard))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit(prompt.install)
                    .onChange(of: prompt.name) {
                        prompt.problem = nil
                    }
                // The line keeps its place, so the buttons do not move when a problem shows.
                Text(prompt.problem ?? " ")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .accessibilityHidden(prompt.problem == nil)
            }
            HStack {
                Spacer()
                Button("Cancel", action: prompt.cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Install", action: prompt.install)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// The prompt's own small window, which shows from Settings and from the menu alike.
@MainActor
final class NamePromptWindow: NSObject, NSWindowDelegate {
    private let prompt: NamePrompt
    private var window: NSWindow?

    init(prompt: NamePrompt) {
        self.prompt = prompt
        super.init()
        prompt.onShow = { [weak self] isShown in
            if isShown {
                self?.show()
            } else {
                self?.close()
            }
        }
    }

    private func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        window?.orderOut(nil)
        NSApp.titledWindowWillClose(window)
    }

    /// The close button is Cancel.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        prompt.cancel()
        return false
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Tilde"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        window.contentView = NSHostingView(rootView: NamePromptView(prompt: prompt))
        window.setContentSize(window.contentView?.fittingSize ?? NSSize(width: 400, height: 220))
        return window
    }
}
