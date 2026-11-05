@testable import TildeUI
import TildeCore
import TildeInstaller
import AppKit

/// Fixed data for UI tests: sessions, drafts and generated screenshots that look the same on
/// every run and every Mac.
@MainActor
enum Fixtures {
    /// A controller with an empty store. Waits for the store's first update, which arrives
    /// on the next run loop pass and would otherwise reset the state a test sets.
    /// An empty archive in a temporary folder.
    static func archive() -> SessionArchive {
        SessionArchive(root: FileManager.default.temporaryDirectory.appendingPathComponent("tilde-sessions-\(UUID().uuidString)", isDirectory: true))
    }

    /// A saved session with the fixture drafts' notes.
    static func record(
        id: String = "a1b2c3d4", client: String = "Codex", isLocal: Bool = false, state: SessionRecord.State = .active,
        notes count: Int = 2, updated: Date = Date(timeIntervalSince1970: 1_793_000_000), pageURL: String? = "https://example.test/docs"
    ) -> SessionRecord {
        let notes = drafts(count, withImages: false).map { draft in
            SessionRecord.Note(
                id: draft.id, comment: draft.annotation.comment, target: draft.annotation.target, frame: draft.annotation.frame,
                marker: draft.marker, chip: draft.chip, anchor: draft.anchor
            )
        }
        return SessionRecord(
            id: id, created: updated.addingTimeInterval(-300), updated: updated, client: client, isLocal: isLocal, state: state,
            pageURL: pageURL, scopeApp: nil, notes: notes, reportFolder: nil
        )
    }

    static func controller() async throws -> AnnotationController {
        let controller = AnnotationController(store: SessionStore(), browser: BrowserController(), archive: archive())
        try await Task.sleep(for: .milliseconds(20))
        return controller
    }

    /// A session from a store the controller does not watch, so no window opens.
    static func session(client: String = "Codex", node: String? = nil, isLocal: Bool = false) -> SessionStore.Session {
        SessionStore().start(client: client, node: node, url: nil, isLocal: isLocal)
    }

    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }

    /// Up to three drafts: a web element, a native element and a region, numbered 1 to 3.
    static func drafts(_ count: Int, withImages: Bool = true) -> [Draft] {
        let web = try! JSONDecoder().decode(WebElement.self, from: Data("""
            {"url":"http://localhost:3000/","title":"Docs","tag":"span","selector":"td > .chip","text":"Alex",
             "html":"<span class=\\"chip\\">Alex</span>","components":["App","OwnerChip"],"source":null,"styles":""}
            """.utf8))
        let native = NativeElement(
            app: "Finder", bundleID: "com.apple.finder", window: "Downloads", role: "AXButton",
            title: "Share", value: nil, label: nil, identifier: nil, url: nil, path: ["AXWindow \"Downloads\"", "AXToolbar", "AXButton"]
        )
        let all: [(Target, CGRect, String, String)] = [
            (.element(.web(web)), CGRect(x: 120, y: 90, width: 84, height: 22), "span", "Avatar and name are not vertically centered"),
            (.element(.native(native)), CGRect(x: 300, y: 60, width: 60, height: 28), "button", "Make this button primary"),
            (.region, CGRect(x: 80, y: 180, width: 320, height: 120), "Region", "Too much empty space under the table"),
        ]

        return all.prefix(count).enumerated().map { index, entry in
            let (target, frame, chip, comment) = entry
            let annotation = Annotation(
                id: id(index + 1), comment: comment, target: target, frame: frame,
                image: withImages ? closeUp(index) : nil, contextImage: withImages ? context(index) : nil
            )
            let marker = CGPoint(x: frame.maxX, y: frame.minY)
            return Draft(annotation: annotation, marker: marker, chip: chip, capture: Task { Captures(image: nil, contextImage: nil) })
        }
    }

    /// The hover highlight on the first draft's web element.
    static func hover() -> Picked {
        let draft = drafts(1)[0]
        guard case .element(let element) = draft.annotation.target else {
            fatalError("the first fixture draft is an element")
        }
        return Picked(frame: CGRect(x: 120, y: 240, width: 140, height: 32), element: element, chip: "button", details: ["button  140×32", "\"Save changes\"", "Finder"])
    }

    // MARK: - Images

    /// A close-up: a light card with a blue-outlined pill, like an annotated chip.
    static func closeUp(_ seed: Int) -> Data {
        image(width: 240, height: 80) { context, size in
            context.setFillColor(CGColor(gray: 0.97, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.95, alpha: 1))
            context.addPath(CGPath(roundedRect: CGRect(x: 30, y: 22, width: 180, height: 36), cornerWidth: 18, cornerHeight: 18, transform: nil))
            context.fillPath()
            context.setStrokeColor(CGColor(red: 0.18, green: 0.47, blue: 1, alpha: 1))
            context.setLineWidth(3)
            context.stroke(CGRect(x: 24 + CGFloat(seed) * 2, y: 16, width: 192, height: 48))
        }
    }

    /// A context screenshot: a window with a title bar, rows and an outlined target.
    static func context(_ seed: Int) -> Data {
        image(width: 640, height: 400) { context, size in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(CGColor(gray: 0.92, alpha: 1))
            context.fill(CGRect(x: 0, y: size.height - 36, width: size.width, height: 36))
            for row in 0..<6 {
                context.setFillColor(CGColor(gray: row % 2 == 0 ? 0.96 : 0.99, alpha: 1))
                context.fill(CGRect(x: 24, y: size.height - 80 - CGFloat(row) * 44, width: size.width - 48, height: 36))
            }
            context.setStrokeColor(CGColor(red: 0.18, green: 0.47, blue: 1, alpha: 1))
            context.setLineWidth(3)
            context.stroke(CGRect(x: 360, y: size.height - 124 - CGFloat(seed) * 44, width: 160, height: 36))
        }
    }

    private static func image(width: Int, height: Int, draw: (CGContext, CGSize) -> Void) -> Data {
        NSBitmapImageRep(cgImage: picture(width: width, height: height, draw: draw)).representation(using: .png, properties: [:])!
    }

    private static func picture(width: Int, height: Int, draw: (CGContext, CGSize) -> Void) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        draw(context, CGSize(width: width, height: height))
        return context.makeImage()!
    }

    // MARK: - Recording sources

    /// A screen or window: a coloured backdrop with a light window on it.
    static func sourcePicture(width: Int, height: Int, seed: Int) -> CGImage {
        picture(width: width, height: height) { context, size in
            let hues: [(CGFloat, CGFloat, CGFloat)] = [(0.22, 0.36, 0.62), (0.45, 0.30, 0.55), (0.20, 0.50, 0.45), (0.62, 0.42, 0.25)]
            let (red, green, blue) = hues[seed % hues.count]
            context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            let window = CGRect(x: size.width * 0.12, y: size.height * 0.12, width: size.width * 0.7, height: size.height * 0.72)
            context.setFillColor(CGColor(gray: 0.97, alpha: 1))
            context.fill(window)
            context.setFillColor(CGColor(gray: 0.86, alpha: 1))
            context.fill(CGRect(x: window.minX, y: window.maxY - size.height * 0.08, width: window.width, height: size.height * 0.08))
        }
    }

    /// A phone's screen: tall, with rows like a list.
    static func phonePicture() -> CGImage {
        picture(width: 118, height: 256) { context, size in
            context.setFillColor(CGColor(gray: 0.98, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            for row in 0..<8 {
                context.setFillColor(CGColor(gray: 0.88, alpha: 1))
                context.fill(CGRect(x: 10, y: size.height - 48 - CGFloat(row) * 26, width: size.width - 20, height: 18))
            }
        }
    }

    static let phone = Phone(id: "phone", name: "iPhone")
    static let display: CGDirectDisplayID = 9002

    /// Two screens and a phone; Safari (with `window`), Xcode, Terminal, Notes and Finder.
    static func sources() -> (screens: [SourcePickerModel.Tile], apps: [SourcePickerModel.App]) {
        let screens = [
            SourcePickerModel.Tile(source: .screen(9001), title: "Built-in Retina Display", detail: "3024 × 1964", picture: sourcePicture(width: 302, height: 196, seed: 0)),
            SourcePickerModel.Tile(source: .screen(display), title: "Studio Display", detail: "5120 × 2880", picture: sourcePicture(width: 320, height: 180, seed: 1)),
            SourcePickerModel.Tile(source: .phone(phone), title: phone.name, detail: "Cable", picture: phonePicture()),
        ]
        let windows: [(pid: pid_t, app: String, titles: [String])] = [
            (window.pid, "Safari", [window.title ?? "", "Pull request", "Downloads"]),
            (2, "Xcode", ["Tilde", "Preview"]),
            (3, "Terminal", ["zsh"]),
            (4, "Notes", ["Ideas"]),
            (5, "Finder", ["Desktop", "Documents"]),
        ]
        let apps = windows.enumerated().map { appIndex, entry in
            let tiles = entry.titles.enumerated().map { index, title in
                let number = entry.pid == window.pid && index == 0 ? window.number : 5000 + appIndex * 10 + index
                let info = ElementPicker.WindowInfo(number: number, pid: entry.pid, app: entry.app, title: title, frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
                return SourcePickerModel.Tile(source: .window(info), title: title, detail: "1200 × 800", picture: sourcePicture(width: 300, height: 200, seed: appIndex + index))
            }
            return SourcePickerModel.App(pid: entry.pid, name: entry.app, icon: appIcon, windows: tiles)
        }
        return (screens, apps)
    }

    /// A window that annotations can be limited to.
    static let window = ElementPicker.WindowInfo(number: 4242, pid: 999_999, app: "Safari", title: "Docs", frame: CGRect(x: 100, y: 100, width: 800, height: 600))

    // MARK: - Agent apps

    /// A blue rounded square in place of the apps' icons.
    static let appIcon = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
        NSColor.tildeBlue.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
        return true
    }

    /// Agent apps in a temporary home: Claude installed, Codex not
    /// installed, Cursor with an invalid config, and Windsurf installed.
    /// VS Code and Gemini are not there.
    static func agentSetup() throws -> AgentSetup {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-ui-\(UUID().uuidString)")
        let files = [
            ".claude.json": #"{ "mcpServers": { "tilde": { "type": "http", "url": "http://127.0.0.1:7311/mcp" } } }"#,
            ".codex/config.toml": "",
            ".cursor/mcp.json": "{ not json",
            ".config/devin/mcp_config.json": #"{ "mcpServers": { "tilde": { "serverUrl": "http://127.0.0.1:7311/mcp" } } }"#,
        ]
        for (path, text) in files {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        let environment = InstallEnvironment.standard(home: home, port: "7311", bridgePath: "/Applications/Tilde.app/Contents/MacOS/tilde-mcp", isolated: true)
        return AgentSetup(installer: Installer(environment: environment), placeholderIcon: appIcon)
    }

    /// Settings with fixed agent apps, default shortcuts and a fixed version.
    static func settingsModel(page: SettingsWindow.Page, history: HistoryModel? = nil) throws -> SettingsModel {
        let defaults = UserDefaults(suiteName: "tilde-tests-\(UUID().uuidString)")!
        let model = SettingsModel(
            setup: try agentSetup(), shortcuts: ShortcutStore(defaults: defaults), browser: BrowserController(), history: history ?? HistoryModel(archive: archive()),
            server: ServerState(port: 7311), version: "0.1.0 (42)",
            browserProfiles: { [] }, permissions: { (true, false) }
        )
        model.page = page
        return model
    }

    static func installResult(failed: Int, action: InstallResult.Action = .installed) -> InstallResult {
        let names = ["Claude", "Codex", "Cursor", "VS Code", "Windsurf (Devin)", "Gemini CLI"]
        let apps = names.enumerated().map { index, name in
            InstallResult.App(name: name, icon: appIcon, failed: index >= names.count - failed, changed: true)
        }
        return InstallResult(action: action, apps: apps)
    }
}
