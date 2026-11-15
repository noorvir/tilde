@testable import TildeUI
import TildeCore
import TildeInstaller
import AppKit

/// Fixed data for UI tests: sessions, drafts and generated screenshots that look the same on
/// every run and every Mac.
@MainActor
enum Fixtures {
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

    /// A controller with an empty store, whose reports and copies never reach the user's inbox
    /// or clipboard. Waits for the store's first update, which arrives on the next run loop
    /// pass and would otherwise reset the state a test sets.
    static func controller() async throws -> AnnotationController {
        let controller = AnnotationController(store: SessionStore(), browser: BrowserController(), archive: archive(), defaults: MemoryDefaults())
        controller.wireframes.set(true)
        controller.sender.inbox = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-inbox-\(UUID().uuidString)")
        controller.sender.pasteboard = NSPasteboard(name: NSPasteboard.Name("tilde-tests-\(UUID().uuidString)"))
        await storeUpdated()
        return controller
    }

    /// Returns once the run loop has given a new controller its store's first update, which
    /// comes on the next pass and would otherwise reset the state a test sets: the run loop's
    /// blocks run in the order they came.
    static func storeUpdated() async {
        await withCheckedContinuation { done in
            RunLoop.main.perform { done.resume() }
        }
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

        // More than three repeat them, for counts such as 10.
        return (0..<count).map { index in
            let (target, frame, chip, comment) = all[index % all.count]
            let annotation = Annotation(
                id: id(index + 1), comment: comment, target: target, frame: frame,
                image: withImages ? closeUp(index) : nil, contextImage: withImages ? context(index) : nil
            )
            let marker = CGPoint(x: frame.maxX, y: frame.minY)
            return Draft(annotation: annotation, marker: marker, chip: chip, capture: Task { Captures(image: nil, contextImage: nil) })
        }
    }

    /// A stopped clip of the Safari window, 12 s long, with its video file at `video`.
    static func clip(in video: URL) throws -> Draft {
        try Data([0, 0, 0, 0x18]).write(to: video)
        let target = Target.recording(video: video, seconds: 12, source: "Safari window")
        let annotation = Annotation(id: id(90), comment: "", target: target, frame: window.frame, image: closeUp(0), contextImage: nil)
        return Draft(annotation: annotation, marker: .zero, chip: "Recording \(clipLength(12))", capture: Task { Captures(image: closeUp(0), contextImage: nil) })
    }

    /// The components of the wireframe fixture, in Quartz screen points: a card with a label
    /// and a table, as the canvas reports them.
    static let wireframeShapes: [[String: Any]] = [
        ["id": "a", "type": "card", "label": "Plan", "borders": ["top", "right", "bottom", "left"], "rect": [140, 160, 240, 120]],
        ["id": "b", "type": "table", "borders": ["top", "bottom"], "rows": 3, "columns": 2, "rect": [140, 300, 400, 160]],
    ]

    /// A note of a wireframe on the Safari window, with the comment "Add a plan card".
    static func wireframe() -> Draft {
        let target = Target.drawing(shapes: WireframeMode.report(of: wireframeShapes, origin: window.frame.origin, isOnWindow: true))
        let frame = DrawingShapes.bounds(of: wireframeShapes)
        let annotation = Annotation(id: id(80), comment: "Add a plan card", target: target, frame: frame, image: closeUp(0), contextImage: context(0))
        return Draft(
            annotation: annotation, marker: CGPoint(x: frame.maxX, y: frame.minY), chip: WireframeMode.chip,
            capture: Task { Captures(image: nil, contextImage: nil) }, sourceWindow: window.number
        )
    }

    static func video(of draft: Draft) -> URL? {
        if case .recording(let video, _, _) = draft.annotation.target {
            return video
        }
        return nil
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

    /// A window: a coloured backdrop with a light window on it.
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

    static let phone = Phone(id: "phone", name: "iPhone")
    static let display: CGDirectDisplayID = 9002

    /// Two screens and a phone; Safari (with `window`), Xcode, Terminal, Notes and Finder.
    static func sources() -> (screens: [SourcePickerModel.Tile], apps: [SourcePickerModel.App]) {
        let screens = [
            SourcePickerModel.Tile(source: .screen(9001), title: "Built-in Retina Display", detail: ""),
            SourcePickerModel.Tile(source: .screen(display), title: "Studio Display", detail: ""),
            SourcePickerModel.Tile(source: .phone(phone), title: phone.name, detail: "Cable"),
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
    static func settingsModel(
        page: SettingsWindow.Page, history: HistoryModel? = nil, wireframePreviews: WireframePreviews? = nil, updates: Updates? = nil
    ) throws -> SettingsModel {
        let model = SettingsModel(
            setup: try agentSetup(), wireframes: WireframeSwitch(defaults: MemoryDefaults()), shortcuts: ShortcutStore(defaults: MemoryDefaults()), browser: BrowserController(), history: history ?? HistoryModel(archive: archive()),
            server: ServerState(port: 7311), updates: updates ?? Updates(engine: FakeUpdateEngine()), version: "0.1.0 (42)",
            browserProfiles: { [] }, permissions: { (true, false) }, wireframePreviews: wireframePreviews
        )
        model.page = page
        return model
    }

    static func installResult(failed: Int) -> InstallResult {
        let names = ["Claude", "Codex", "Cursor", "VS Code", "Windsurf (Devin)", "Gemini CLI"]
        let apps = names.enumerated().map { index, name in
            InstallResult.App(name: name, icon: appIcon, failed: index >= names.count - failed, changed: true)
        }
        return InstallResult(action: .installed, apps: apps)
    }
}

/// User defaults in memory, for what Tilde keeps across launches: a test changes no domain of
/// this Mac and leaves no file in ~/Library/Preferences. A suite leaves an empty file there,
/// also after its domain is removed.
final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    override func object(forKey key: String) -> Any? {
        values[key]
    }

    override func set(_ value: Any?, forKey key: String) {
        values[key] = value
    }

    override func removeObject(forKey key: String) {
        values[key] = nil
    }
}

/// An update engine that does what a test tells it: it reports the statuses the test sends,
/// and records what the user asked for.
@MainActor
final class FakeUpdateEngine: UpdateEngine {
    var isAutomatic = true
    private(set) var calls: [String] = []
    /// What it reports when it starts.
    private let initial: UpdateStatus?
    private var report: (UpdateStatus) -> Void = { _ in }
    private var mayRelaunch: () -> Bool = { true }

    init(status: UpdateStatus? = nil) {
        initial = status
    }

    func start(reporting: @escaping (UpdateStatus) -> Void, mayRelaunch: @escaping () -> Bool) {
        report = reporting
        self.mayRelaunch = mayRelaunch
        if let initial {
            reporting(initial)
        }
    }

    func send(_ status: UpdateStatus) {
        report(status)
    }

    /// Asks as Sparkle does just before it quits Tilde to install.
    func asksToRelaunch() -> Bool {
        mayRelaunch()
    }

    func check() {
        calls.append("check")
    }

    func install() {
        calls.append("install")
    }

    func restart() {
        calls.append("restart")
    }
}
