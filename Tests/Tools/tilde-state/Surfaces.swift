import TildeInstaller
@testable import TildeUI
import TildeCore
import AppKit
import SwiftUI

/// Builds the real view of a state and draws it.
@MainActor
enum Surfaces {
    static func warmUp() async throws -> CGImage {
        let view = ScrollView { Text("Warm up").frame(width: 100, height: 400) }
        return try await Renderer.render(NSHostingView(rootView: view), size: CGSize(width: 200, height: 200), appearance: .aqua)
    }

    static func image(of state: UIState) async throws -> CGImage {
        let size = state.size.map { CGSize(width: $0[0], height: $0[1]) } ?? .zero
        let appearance: NSAppearance.Name = state.appearance == .light ? .aqua : .darkAqua
        func hosted<V: View>(_ view: V, size: CGSize) async throws -> CGImage {
            let hosting = NSHostingView(rootView: view.transaction { $0.disablesAnimations = true })
            return try await Renderer.render(hosting, size: size, appearance: appearance)
        }

        // Settings and the Style menu read the look from the defaults, as the app does. The
        // registration domain is this process's own: the states are drawn in several at once.
        let look = state.look?.value ?? WireframeLook()
        UserDefaults.standard.register(defaults: [
            WireframeLook.Key.style: look.style.rawValue, WireframeLook.Key.fill: look.fill,
            WireframeLook.Key.blur: look.blur, WireframeLook.Key.fade: look.fade, WireframeLook.Key.colours: look.colours.rawValue,
        ])

        switch state.surface {
        case .toast:
            let toast = InstallToastState()
            toast.result = result(of: state.toast!)
            toast.isShown = true
            return try await hosted(InstallToastView(state: toast), size: size)

        case .updateToast:
            let toast = UpdateToastState()
            toast.version = "0.3.0"
            toast.isShown = true
            return try await hosted(UpdateToastView(state: toast), size: size)

        case .settings:
            let model = try await settings(state.settings!, look: look)
            model.wireframes.set(state.wireframes ?? false)
            return try await hosted(SettingsView(model: model), size: size)

        case .canvas:
            return try await CanvasSurface.image(look: state.look?.value ?? WireframeLook(), chip: state.chip, isNested: state.nested == true)

        case .restorePrompt:
            let restore = RestoreToastState()
            restore.record = Fixtures.record(notes: 3, updated: Date().addingTimeInterval(-720))
            restore.isShown = true
            return try await hosted(RestoreToastView(state: restore), size: size)

        case .tooltip:
            return try await hosted(TooltipBubble(text: state.text ?? "", keys: state.keys ?? []).frame(width: size.width, height: size.height), size: size)

        case .outline:
            let model = HomeOutline.Model()
            model.isSnapped = state.snapped ?? false
            let size = CGSize(width: HUDView.width, height: PillMetrics.height)
            return try await hosted(OutlineView(model: model, cornerRadius: PillMetrics.height / 2).frame(width: size.width, height: size.height), size: size)

        case .notesPanel:
            let controller = try await controller(state)
            var drafts = controller.drafts
            drafts[0].anchor = PageAnchor(url: "https://example.test/docs", selector: "td > .chip", text: "Alex", documentRect: .zero)
            drafts[1].anchor = PageAnchor(url: "https://example.test/docs", selector: "button", text: "Share", documentRect: .zero)
            drafts[2].anchor = PageAnchor(url: "https://example.test/settings", selector: nil, text: nil, documentRect: .zero)
            apply(state, drafts: drafts, to: controller)
            let browser = BrowserController()
            browser.setStateForTesting(pageURL: "https://example.test/docs", anchorRects: [drafts[0].id: CGRect(x: 10, y: 10, width: 80, height: 20)])
            let panel = NotesPanel(controller: controller, browser: browser).frame(width: BrowserMetrics.panelWidth, height: 520)
            return try await hosted(panel.background(Color(white: 0.1)), size: CGSize(width: BrowserMetrics.panelWidth, height: 520))

        case .toolbar:
            let browser = BrowserController()
            let controller = AnnotationController(store: SessionStore(), browser: browser, archive: Fixtures.archive(), defaults: MemoryDefaults())
            try await Task.sleep(for: .milliseconds(20))
            apply(state, drafts: try drafts(state), to: controller)
            let toolbar = BrowserToolbar(browser: browser, controller: controller).background(Color(white: 0.1))
            return try await hosted(toolbar, size: CGSize(width: BrowserMetrics.minWindowWidth, height: BrowserMetrics.toolbarHeight))

        case .hud:
            let controller = try await controller(state)
            controller.wireframe.bar = state.wireframeBar ?? WireframeBar()
            return try await hosted(HUDView(controller: controller), size: size)

        case .wireframeAdjust:
            // The content of the native popover, whose frame, arrow and material AppKit draws;
            // here on the window colour.
            let controller = try await controller(state)
            let content = WireframeAdjust(wireframe: controller.wireframe).frame(width: size.width, height: size.height)
            return try await hosted(content.background(Color(nsColor: .windowBackgroundColor)), size: size)

        case .comment:
            let controller = try await controller(state)
            controller.commentBox.text = state.commentText ?? ""
            return try await hosted(CommentView(controller: controller, chip: "span"), size: size)

        case .preview:
            let controller = try await controller(state)
            return try await hosted(PreviewView(controller: controller), size: size)

        case .overlay:
            let controller = try await controller(state)
            let primaryHeight = NSScreen.screens.first?.frame.height ?? size.height
            if state.pageNotes == true {
                var drafts = controller.drafts
                drafts[0].anchor = PageAnchor(url: "https://example.test/docs", selector: "td > .chip", text: "Alex", documentRect: .zero)
                drafts[1].anchor = PageAnchor(url: "https://example.test/docs", selector: "button", text: "Share", documentRect: .zero)
                apply(state, drafts: drafts, to: controller)
                controller.browser.setStateForTesting(
                    pageURL: "https://example.test/docs",
                    anchorRects: [drafts[0].id: CGRect(x: 40, y: 60, width: 160, height: 40), drafts[1].id: CGRect(x: 260, y: 180, width: 120, height: 60)],
                    pageFrame: CGRect(x: 0, y: primaryHeight - 340, width: 520, height: 340),
                    showsNotes: false
                )
            }
            return try await Renderer.render(OverlayView(controller: controller), size: size, windowOrigin: NSPoint(x: 0, y: primaryHeight - size.height))
        }
    }

    private static func controller(_ state: UIState) async throws -> AnnotationController {
        let controller = try await Fixtures.controller()
        if let client = state.clientWithIcon {
            controller.clientIcon = { $0 == client ? Fixtures.appIcon : nil }
        }
        if let dot = state.machineDot {
            controller.machineDot = { _ in dot }
        }
        apply(state, drafts: try drafts(state), to: controller)
        controller.hud.showsList = state.list ?? false
        controller.notices.showSent(state.sent ?? "", status: state.sentStatus == .failed ? .failed : .done)
        if let color = state.drawingColor {
            controller.setDrawingColor(color)
        }
        if let tool = state.tool {
            setTool(tool, isWireframe: state.wireframe == true, of: controller)
        }
        switch state.enlarged {
        case .closeUp: controller.previewCard.expandedImage = .closeUp
        case .context: controller.previewCard.expandedImage = .context
        case nil: controller.previewCard.expandedImage = nil
        }
        return controller
    }

    private static func setTool(_ tool: String, isWireframe: Bool, of controller: AnnotationController) {
        switch (tool, isWireframe) {
        case ("none", true): controller.wireframe.putToolDown()
        case ("none", false): controller.drawing.putToolDown()
        case (_, true): controller.wireframe.setTool(tool)
        case (_, false): controller.drawing.setTool(tool)
        }
    }

    /// The state's notes; with `wireframeNote`, the last is a wireframe; with `clip`, the first
    /// is a recording.
    private static func drafts(_ state: UIState) throws -> [Draft] {
        var drafts = Fixtures.drafts(state.notes ?? 0, withImages: state.images ?? true)
        if state.wireframeNote == true, !drafts.isEmpty {
            drafts[drafts.count - 1] = Fixtures.wireframe()
        }
        guard state.clip == true else {
            return drafts
        }
        let video = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-state-clip.mp4")
        return [try Fixtures.clip(in: video)] + drafts.dropFirst()
    }

    private static func apply(_ state: UIState, drafts: [Draft], to controller: AnnotationController) {
        controller.wireframes.set(state.wireframes ?? false)
        let notice: PauseNotice? = switch state.pauseNotice {
        case .escape: .escape
        case .otherApp: .otherApp
        case nil: nil
        }
        var open = SessionFlow.Open()
        if state.paused == true {
            open.pauses.insert(.user)
        }
        if state.autoPaused == true {
            open.pauses.insert(.otherApp)
        }
        if state.wireframe == true {
            open.canvas = .wireframe
        } else if state.drawing == true {
            open.canvas = .draw
        }
        open.question = state.confirmation
        if state.preview != nil {
            open.panel = .preview
        }
        let clip: SessionFlow.Clip? = switch state.recording {
        case .ready: .ready
        case .starting: .starting(operation: 0)
        case .recording: .recording
        case .paused: .paused
        case .finishing: .finishing(operation: 0, thenSend: false)
        case nil: nil
        }
        if let clip {
            open.activity = .recording(clip)
        }
        if state.pickingWindow == true {
            open.activity = .picking(isPickerOpen: state.sourcePicker != nil)
        }
        var mode = SessionFlow.Mode.open(open)
        if state.sent != nil {
            mode = .sent(operation: 0)
        } else if state.sending == true {
            mode = .sending(operation: 0, returnTo: open)
        }
        let source: RecordingSource? = switch state.source {
        case .phone: .phone(Fixtures.phone)
        case .display: .screen(Fixtures.display)
        case nil: state.scoped == true ? .window(Fixtures.window) : nil
        }
        // A stand-in for the screen Record records, never the name of the Mac that draws it.
        controller.screenName = { _ in "Studio Display" }
        controller.setStateForTesting(
            session: state.session.map { Fixtures.session(client: $0.client, node: $0.node, isLocal: $0.isLocal ?? false) },
            drafts: drafts,
            mode: mode,
            hover: state.hover == true ? Fixtures.hover() : nil,
            previewID: state.preview.map { drafts[$0].id },
            source: source,
            isHUDInBrowser: state.hudInBrowser ?? false,
            pauseNotice: notice,
            browserAccessoryURL: state.browserAccessory == true ? URL(string: "https://example.com/pricing") : nil,
            restoreRecord: state.confirmation == .restore ? Fixtures.record(notes: 3) : nil,
            sentText: state.sent ?? "",
            notice: state.notice,
            // A clip in progress has run for 12 seconds.
            clipClock: (Date(), 12)
        )
        if let picker = state.sourcePicker {
            var (screens, apps) = Fixtures.sources()
            let phase: SourcePickerModel.Phase
            switch state.pickerPhase {
            case .listing:
                (screens, apps) = ([], [])
                phase = .listing
            case .failed:
                (screens, apps) = ([], [])
                phase = .failed
            case .empty:
                (screens, apps) = ([], [])
                phase = .done
            case .picturing, .noPictures:
                // The tiles are listed, and their pictures are coming, or could not be taken.
                screens = screens.map { tile in var tile = tile; tile.picture = nil; return tile }
                apps = apps.map { app in var app = app; app.windows = app.windows.map { tile in var tile = tile; tile.picture = nil; return tile }; return app }
                phase = state.pickerPhase == .picturing ? .picturing : .done
            case nil:
                phase = .done
            }
            // Opened as the app opens it, so it offers what the app would.
            controller.sourcePicker.injected = (screens, apps, phase)
            controller.dispatch(.openPicker)
            controller.sourcePicker.tab = picker == .screens ? .screens : .windows
            controller.sourcePicker.openApp = picker == .app ? Fixtures.window.pid : nil
        }
    }

    private static func settings(_ state: UIState.Settings, look: WireframeLook) async throws -> SettingsModel {
        var history: HistoryModel?
        if state.savedSessions == true {
            let archive = Fixtures.archive()
            archive.save(Fixtures.record(id: "s1", state: .active, notes: 3))
            archive.save(Fixtures.record(id: "s2", client: "You", isLocal: true, state: .sent, notes: 1, updated: Date(timeIntervalSince1970: 1_792_990_000), pageURL: nil))
            archive.save(Fixtures.record(id: "s3", client: "Claude Code", state: .cancelled, notes: 2, updated: Date(timeIntervalSince1970: 1_792_900_000), pageURL: "http://localhost:3000/"))
            archive.flush()
            history = HistoryModel(archive: archive)
            history?.expanded = ["s1"]
        }
        let page: SettingsWindow.Page = switch state.page {
        case .agents: .home
        case .shortcuts: .shortcuts
        case .history: .history
        case .general: .configuration
        case .appearance: .appearance
        }
        // The Appearance page's pictures, drawn before the page shows, as the page draws them.
        let previews = WireframePreviews(html: { try? CanvasSurface.html() })
        if page == .appearance {
            try await previews.draw(look)
        }
        let model = try Fixtures.settingsModel(page: page, history: history, wireframePreviews: previews, updates: updates(state.update))
        model.expandedAgents = Set(state.expandedAgents ?? [])
        if let name = state.commandName {
            model.setup.setCommand(name, oldCommands: [])
        }
        model.commandDraft = state.commandDraft
        for harness in state.taken ?? [] {
            let skill = model.setup.installer.skillFile(for: harness)
            try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("---\nname: \(model.setup.command)\n---\n\nThe user's own skill.\n".utf8).write(to: skill)
        }
        model.setup.nodes.setEnabledForTesting(state.remoteMachines ?? false)
        if let host = state.machine, let node = state.nodes?.first(where: { $0.host == host }) {
            let machine = AgentSetup(installer: model.setup.installer, placeholderIcon: Fixtures.appIcon, nodes: model.setup.nodes, isRemote: true)
            var statuses: [Harness: InstallStatus] = [:]
            for harness in node.agents ?? [] {
                statuses[harness] = .installed
            }
            for harness in node.agentsOff ?? [] {
                statuses[harness] = .notInstalled
            }
            machine.setRemoteStatusesForTesting(statuses)
            model.setup.nodes.setSetupForTesting(machine, for: host)
            model.machinePath = [host]
        }
        model.setup.nodes.setRowsForTesting((state.nodes ?? []).map { NodeSetup.Row(host: $0.host, status: NodeSetup.Status(name: $0.status.rawValue), isReachable: $0.isReachable, hasFailed: $0.hasFailed ?? false, isProtected: $0.isProtected ?? true, needsMove: $0.needsMove ?? false, isWorking: $0.isWorking ?? false) })
        if state.recording == true {
            model.recordingShortcut = .togglePause
        }
        return model
    }

    private static func updates(_ state: UIState.Update?) -> Updates {
        let status: UpdateStatus = switch state?.status ?? .idle {
        case .idle: .idle
        case .checking: .checking
        case .off: .off
        case .upToDate: .upToDate
        case .available: .available(version: "0.3.0")
        case .downloading: .downloading(version: "0.3.0", progress: 0.4)
        case .ready: .ready(version: "0.3.0")
        case .failed: .failed(reason: state?.reason ?? "Could not reach the update feed")
        }
        let engine = FakeUpdateEngine(status: status)
        engine.isAutomatic = state?.automatic ?? true
        let updates = Updates(engine: engine)
        updates.start()
        updates.isSessionActive = state?.session ?? false
        return updates
    }

    private static func result(of toast: UIState.Toast) -> InstallResult {
        if toast.oneApp {
            return InstallResult(action: .removed, apps: [.init(name: "Cursor", icon: Fixtures.appIcon, failed: false, changed: true)])
        }
        let result = Fixtures.installResult(failed: toast.failed)
        let taken = toast.taken ?? 0
        guard taken > 0 else {
            return result
        }
        // The first apps are skipped: the name is another skill's there.
        let apps = result.apps.enumerated().map { index, app in
            let conflict = index < taken ? "A skill named annotate already exists in \(app.name). Choose another command name." : nil
            return InstallResult.App(name: app.name, icon: app.icon, failed: app.failed, changed: app.changed && conflict == nil, conflict: conflict)
        }
        return InstallResult(action: .installed, apps: apps)
    }
}
