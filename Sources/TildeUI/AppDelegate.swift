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
    private lazy var mcp = MCPServer(store: store)
    private var server: HTTPServer?
    private var serverState = ServerState(port: 7311)
    private var menu: StatusMenu?
    private var settings: SettingsWindow?
    private var toast: InstallToast?
    private var hotKeys: HotKeys?

    override public init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        CursorDebug.install()
        let port = UInt16(ProcessInfo.processInfo.environment["TILDE_PORT"] ?? "") ?? 7311
        serverState = ServerState(port: port)
        let bridge = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/tilde-mcp").path
        let home = FileManager.default.homeDirectoryForCurrentUser
        let setup = AgentSetup(installer: Installer(environment: .standard(home: home, port: String(port), bridgePath: bridge)))
        let shortcuts = controller.shortcuts
        let version = SettingsModel.bundleVersion
        let toast = InstallToast { [weak self] in
            self?.settings?.show(.agents)
        }
        let model = SettingsModel(
            setup: setup, shortcuts: shortcuts, server: serverState, version: version,
            onResult: { toast.show($0) }, onResetHUD: { [controller] in controller.resetHUDPosition() }
        )
        let settings = SettingsWindow(model: model)
        controller.clientIcon = { setup.icon(forClient: $0) }
        self.toast = toast
        self.settings = settings
        menu = StatusMenu(browser: browser, controller: controller, settings: settings, setup: setup, version: version) { toast.show($0) }
        hotKeys = HotKeys(controller: controller, shortcuts: shortcuts)
        if let folder = UserDefaults.standard.string(forKey: "captureSettings") {
            Task {
                await SettingsCapture.run(settings, model: model, to: URL(fileURLWithPath: (folder as NSString).expandingTildeInPath))
            }
        }
        startServer()

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
        } catch {
            state.status = .failed(error.localizedDescription)
        }
    }
}
