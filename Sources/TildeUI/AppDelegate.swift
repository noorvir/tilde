import TildeCore
import TildeInstaller
import AppKit

/// Status of the local MCP endpoint, shown in the menu.
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
    private lazy var controller = AnnotationController(store: store, browser: browser)
    private lazy var mcp = MCPServer(
        store: store, clientsFile: SessionArchive.defaultRoot.deletingLastPathComponent().appendingPathComponent("mcp-clients.json")
    )
    private var server: HTTPServer?
    private var nodeServer: HTTPServer?
    private var nodes: NodeSetup?
    private var serverState = ServerState(port: 7311)
    private var menu: StatusMenu?
    private var settings: SettingsWindow?
    private var toast: InstallToast?
    private var restorePrompt: RestorePrompt?
    private var hotKeys: HotKeys?
    private var browserEvents: Any?

    override public init() {
        super.init()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        nodes?.stopLinks()
        controller.saveBeforeQuitting()
    }

    /// An agent waiting again for its session after Tilde restarted gets it back with its
    /// notes; the newest other unfinished session with notes is offered to restore.
    private func offerUnfinishedSession() {
        let controller = self.controller
        controller.archive.prune()
        store.reattach = { id in controller.reattach(id) }

        let prompt = RestorePrompt { record in
            // An agent may have taken its session back meanwhile.
            guard controller.archive.record(record.id)?.state == .active, controller.session?.id != record.id else {
                return
            }
            controller.restore(record)
        } onDiscard: { record in
            controller.discard(record)
        }
        restorePrompt = prompt

        let unfinished = controller.archive.all().filter { $0.state == .active }
        for empty in unfinished where empty.notes.isEmpty {
            controller.discard(empty)
        }
        if let newest = unfinished.first(where: { !$0.notes.isEmpty }) {
            prompt.show(newest)
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        CursorDebug.install()
        MainThreadWatch.start()
        // The note box is for typing: no accent popup, whose input method can hold up a key.
        UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])
        let port = UInt16(ProcessInfo.processInfo.environment["TILDE_PORT"] ?? "") ?? 7311
        serverState = ServerState(port: port)
        let bridge = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/tilde-mcp").path
        let home = FileManager.default.homeDirectoryForCurrentUser
        let setup = AgentSetup(
            installer: Installer(environment: .standard(home: home, port: String(port), bridgePath: bridge)),
            nodes: NodeSetup(nodePort: port + 1)
        )
        setup.nodes.onThisMac = { [installer = setup.installer] in
            installer.harnesses.filter { installer.status(of: $0) == .installed }
        }
        setup.nodes.startLinks()
        self.nodes = setup.nodes
        let shortcuts = controller.shortcuts
        let version = SettingsModel.bundleVersion
        let toast = InstallToast { [weak self] in
            self?.settings?.show(.agents)
        }
        let controller = self.controller
        let history = HistoryModel(archive: controller.archive) {
            controller.session?.id
        } onRestore: { record in
            controller.restore(record)
        } icon: { record in
            record.isLocal ? nil : setup.icon(forClient: record.client)
        }
        let model = SettingsModel(
            setup: setup, shortcuts: shortcuts, browser: browser, history: history, server: serverState, version: version,
            onResult: { toast.show($0) }, onResetHUD: { [controller] in controller.resetHUDPosition() }
        )
        let settings = SettingsWindow(model: model)
        controller.clientIcon = { setup.icon(forClient: $0) }
        self.toast = toast
        self.settings = settings
        menu = StatusMenu(browser: browser, controller: controller, settings: settings, setup: setup, version: version) { toast.show($0) }
        hotKeys = HotKeys(controller: controller, shortcuts: shortcuts)
        NSApp.mainMenu = MainMenu.make(browser: browser, settings: settings)
        browserEvents = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .keyDown]) { [browser] event in
            browser.handle(event) ? nil : event
        }
        if let folder = UserDefaults.standard.string(forKey: "captureSettings") {
            Task {
                await SettingsCapture.run(settings, model: model, browser: self.browser, to: URL(fileURLWithPath: (folder as NSString).expandingTildeInPath))
            }
        }
        startServer()
        offerUnfinishedSession()

        if ScreenCapture.isAllowed {
            // macOS asks the user to confirm direct screen capture from time to time; a tiny
            // capture at launch shows that consent now instead of in the middle of annotating.
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
        let mcp = self.mcp
        let state = serverState

        do {
            let server = try HTTPServer(port: state.port) { request in
                await mcp.handle(request)
            }
            server.start { status in
                Task { @MainActor in
                    state.status = status
                }
            }
            self.server = server

            // The door for tunnels from other machines: every request needs a node's token.
            let store = NodeStore()
            let nodeServer = try HTTPServer(port: state.port + 1) { request in
                await mcp.handleFromNode(request, store: store)
            }
            nodeServer.start { _ in }
            self.nodeServer = nodeServer
        } catch {
            state.status = .failed(error.localizedDescription)
        }
    }
}
