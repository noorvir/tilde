import TildeCore
import TildeInstaller
import AppKit
import Combine

/// Status of the local MCP endpoint, shown in Settings.
@MainActor
final class ServerState {
    let port: UInt16
    var status: HTTPServer.Status = .starting

    init(port: UInt16) {
        self.port = port
    }
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let browser = BrowserController()
    private lazy var controller = AnnotationController(store: store, browser: browser, archive: SessionArchive(), defaults: .standard)

    private var mcp: MCPServer?
    private var server: HTTPServer?
    private var nodes: NodeSetup?
    private var serverState = ServerState(port: 7311)
    private var menu: StatusMenu?
    private var settings: SettingsWindow?
    private var toast: InstallToast?
    private var namePromptWindow: NamePromptWindow?
    private var restoreToast: RestoreToast?
    private var updates: Updates?
    private var updateToast: UpdateToast?
    private var updateSession: AnyCancellable?
    private var updateUse: Any?
    private var historyRestore: AnyCancellable?
    private var permissionRequest: AnyCancellable?
    private var hotKeys: HotKeys?
    private var browserEvents: Any?

    override public init() {
        super.init()
    }

    /// Draft saves that wait for changes to stop run first, so the shapes of the last half
    /// second are kept.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.hasWaitingDraftSave else {
            return .terminateNow
        }
        controller.saveWaitingDrafts {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    public func applicationWillTerminate(_ notification: Notification) {
        nodes?.stopLinks()
        controller.saver.saveBeforeQuitting()
    }

    /// An agent waiting again for its session after Tilde restarted gets it back with its
    /// notes; the newest other unfinished session with notes is offered to restore.
    private func offerUnfinishedSession() {
        let controller = self.controller
        let tilde = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tilde")
        controller.archive.prune(olderClips: tilde.appendingPathComponent("recordings"))
        // Reports and sessions saved by older builds become private too, and old reports go
        // as old sessions do.
        let sessions = controller.archive.root
        DispatchQueue.global(qos: .utility).async {
            makePrivate(tree: inboxRoot)
            pruneInbox()
            makePrivate(tree: sessions)
        }
        store.reattach = { id, node in controller.reattach(id, node: node) }

        let toast = RestoreToast { record in
            // An agent may have taken its session back meanwhile.
            guard controller.archive.record(record.id)?.state == .active, controller.session?.id != record.id else {
                return
            }
            controller.restore(record)
        } onDiscard: { record in
            controller.saver.discard(record)
        }
        restoreToast = toast

        // The read decodes every saved session, after the prune: away from the main thread,
        // which has the menu to show. A session that started meanwhile is not left over.
        // After a silent update the user was not here: the toast waits for the next launch.
        let archive = controller.archive
        let silentRelaunch = updates?.isSilentRelaunch == true
        Task {
            let saved = await Task.detached { archive.all() }.value
            let unfinished = saved.filter { $0.state == .active && $0.id != controller.session?.id }
            for empty in unfinished where empty.notes.isEmpty {
                controller.saver.discard(empty)
            }
            if !silentRelaunch, let newest = unfinished.first(where: { !$0.notes.isEmpty }) {
                toast.show(newest)
            }
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        CursorDebug.install()
        DispatchQueue.global(qos: .utility).async {
            PhoneCapture.allowPhones()
        }
        // Before the controller reads the switch.
        WireframeSwitch.migrate(defaults: .standard) {
            SessionArchive().all().contains { $0.notes.contains { $0.chip == WireframeMode.chip } }
        }
        // The note box is for typing: no accent popup, whose input method can hold up a key.
        UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])
        let port = UInt16(ProcessInfo.processInfo.environment["TILDE_PORT"] ?? "") ?? 7311
        serverState = ServerState(port: port)
        let bridge = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/tilde-mcp").path
        let home = FileManager.default.homeDirectoryForCurrentUser
        NodeSetup.migrate(defaults: .standard, store: NodeStore())
        let setup = AgentSetup(
            // Without the token the listener does not start, so entries without it change nothing.
            installer: Installer(environment: (try? .local(home: home, port: String(port), bridgePath: bridge)) ?? .standard(home: home, port: String(port), bridgePath: bridge)),
            nodes: NodeSetup(nodePort: port + 1),
            defaults: .standard
        )
        // After an update: Tilde's skill under an old name, such as `tilde`, moves to the current one.
        Task { await setup.migrate() }
        self.nodes = setup.nodes
        let shortcuts = controller.shortcuts
        let version = SettingsModel.bundleVersion
        let toast = InstallToast { [weak self] in
            self?.settings?.show(.home)
        }
        // An install that found the name taken in an app asks for another name first.
        let namePrompt = NamePrompt()
        namePrompt.onResult = { toast.show($0) }
        setup.namePrompt = namePrompt
        self.namePromptWindow = NamePromptWindow(prompt: namePrompt)
        let onResult: (InstallResult) -> Void = { result in
            if result.conflicts.isEmpty {
                toast.show(result)
            } else {
                setup.askForName(result.conflicts, pending: result)
            }
        }
        let controller = self.controller
        let history = HistoryModel(archive: controller.archive) {
            controller.session?.id
        } onRestore: { record in
            controller.restore(record)
        } icon: { record in
            record.isLocal ? nil : setup.icon(forClient: record.client)
        }
        historyRestore = controller.$flow
            .map { flow in flow.mode == .idle || flow.accepts(.restore, controller.facts) }
            .removeDuplicates()
            .sink { [weak history] takes in history?.takesRestore = takes }
        // The UX specs point the app at a local feed, and wait less for idleness.
        let feed = UserDefaults.standard.string(forKey: "updateFeedURL") ?? SparkleUpdates.feedURL
        let idleTime = UserDefaults.standard.double(forKey: "updateIdleSeconds")
        let updates = Updates(engine: SparkleUpdates(feed: feed), idleTime: idleTime > 0 ? idleTime : 300)
        updates.showsWindow = { NSApp.windows.contains(where: \.isInUse) }
        updateUse = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { [updates] event in
            updates.noteUse()
            return event
        }
        let updateToast = UpdateToast { [updates] in updates.restart() }
        updates.onReady = { updateToast.show(version: $0) }
        updateSession = controller.$flow
            .map { $0.mode != .idle }
            .removeDuplicates()
            .sink { [weak updates] isActive in updates?.isSessionActive = isActive }
        self.updates = updates
        self.updateToast = updateToast
        let model = SettingsModel(
            setup: setup, wireframes: controller.wireframes, shortcuts: shortcuts, browser: browser, history: history, server: serverState, updates: updates, version: version,
            onResult: onResult, onResetHUD: { [controller] in controller.hud.resetPosition() }
        )
        let settings = SettingsWindow(model: model)
        controller.clientIcon = { setup.icon(forClient: $0) }
        controller.machineDot = { host in setup.nodes.rows.first { $0.host == host }?.dot ?? .grey }
        self.toast = toast
        self.settings = settings
        menu = StatusMenu(browser: browser, controller: controller, settings: settings, setup: setup, version: version, onResult: onResult)
        hotKeys = HotKeys(controller: controller, shortcuts: shortcuts)
        NSApp.mainMenu = MainMenu.make(browser: browser, settings: settings)
        browserEvents = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .keyDown]) { [browser] event in
            browser.handle(event) ? nil : event
        }
        startServer()
        setup.nodes.startLinks()
        updates.start()
        offerUnfinishedSession()

        // A launch shows no prompt and takes no picture of the screen: the permissions are
        // asked for when the first session starts, which needs them.
        permissionRequest = controller.$session.compactMap { $0 }.first().sink { _ in
            Self.askForPermissions()
        }
    }

    /// Asks for Screen Recording and Accessibility where Tilde does not have them.
    private static func askForPermissions() {
        if ScreenCapture.isAllowed {
            // macOS asks the user to confirm direct screen capture from time to time; a tiny
            // capture at the session's start shows that consent now instead of in the middle
            // of a note.
            Task {
                _ = await ScreenCapture.png(of: CGRect(x: 0, y: 0, width: 1, height: 1), outline: nil, keeping: [], maxSide: 1024)
            }
        } else {
            CGRequestScreenCaptureAccess()
        }
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func startServer() {
        let state = serverState

        do {
            let token = try LocalToken.load(home: FileManager.default.homeDirectoryForCurrentUser)
            let mcp = MCPServer(
                store: store, localToken: token, clientsFile: SessionArchive.defaultRoot.deletingLastPathComponent().appendingPathComponent("mcp-clients.json")
            )
            self.mcp = mcp
            nodes?.mcp = mcp
            let server = try HTTPServer(port: state.port) { request in
                await mcp.handleLocal(request)
            }
            server.start { status in
                Task { @MainActor in
                    state.status = status
                }
            }
            self.server = server
        } catch {
            state.status = .failed((error as? LocalToken.Failure)?.description ?? error.localizedDescription)
        }
    }
}
