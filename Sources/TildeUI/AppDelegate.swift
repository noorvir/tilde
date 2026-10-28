import TildeCore
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
    private var hotKeys: HotKeys?

    override public init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let port = UInt16(ProcessInfo.processInfo.environment["TILDE_PORT"] ?? "") ?? 7311
        serverState = ServerState(port: port)
        menu = StatusMenu(server: serverState, browser: browser, controller: controller)
        hotKeys = HotKeys(controller: controller)
        startServer()

        if ScreenCapture.isAllowed {
            // macOS asks the user to confirm direct screen capture from time to time; a tiny
            // capture at launch shows that consent now instead of in the middle of annotating.
            Task {
                _ = await ScreenCapture.png(of: CGRect(x: 0, y: 0, width: 1, height: 1), outline: nil, hiding: [])
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
