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

        switch state.surface {
        case .toast:
            let toast = InstallToastState()
            toast.result = result(of: state.toast!)
            toast.isShown = true
            return try await hosted(InstallToastView(state: toast), size: size)

        case .settings:
            return try await hosted(SettingsView(model: try settings(state.settings!)), size: size)

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
            let controller = AnnotationController(store: SessionStore(), browser: browser, archive: Fixtures.archive(), defaults: nil)
            try await Task.sleep(for: .milliseconds(20))
            apply(state, drafts: try drafts(state), to: controller)
            let toolbar = BrowserToolbar(browser: browser, controller: controller).background(Color(white: 0.1))
            return try await hosted(toolbar, size: CGSize(width: BrowserMetrics.minWindowWidth, height: BrowserMetrics.toolbarHeight))

        case .hud:
            return try await hosted(HUDView(controller: try await controller(state)), size: size)

        case .comment:
            let controller = try await controller(state)
            let isEditing = state.editing ?? false
            controller.commentText = state.commentText ?? ""
            if isEditing, let draft = controller.drafts.first {
                apply(state, drafts: controller.drafts, composer: .edit(draft.id), to: controller)
                controller.commentText = draft.annotation.comment
            }
            return try await hosted(CommentView(controller: controller, chip: "span", isEditing: isEditing), size: size)

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
        controller.showsList = state.list ?? false
        controller.notices.showSent(state.sent ?? "", status: state.sentStatus == .failed ? .failed : .done)
        if let color = state.drawingColor {
            controller.setDrawingColor(color)
        }
        switch state.enlarged {
        case .closeUp: controller.expandedPreviewImage = .closeUp
        case .context: controller.expandedPreviewImage = .context
        case nil: controller.expandedPreviewImage = nil
        }
        return controller
    }

    /// The state's notes; with `clip`, the first is a recording.
    private static func drafts(_ state: UIState) throws -> [Draft] {
        let drafts = Fixtures.drafts(state.notes ?? 0, withImages: state.images ?? true)
        guard state.clip == true else {
            return drafts
        }
        let video = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-state-clip.mp4")
        return [try Fixtures.clip(in: video)] + drafts.dropFirst()
    }

    private static func apply(_ state: UIState, drafts: [Draft], composer: Composer? = nil, to controller: AnnotationController) {
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
        open.isDrawing = state.drawing ?? false
        open.question = state.confirmation
        if state.preview != nil {
            open.panel = .preview
        } else if composer != nil {
            open.panel = .comment
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
            composer: composer,
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

    private static func settings(_ state: UIState.Settings) throws -> SettingsModel {
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
        }
        let model = try Fixtures.settingsModel(page: page, history: history)
        model.expandedAgents = Set(state.expandedAgents ?? [])
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

    private static func result(of toast: UIState.Toast) -> InstallResult {
        if toast.oneApp {
            return InstallResult(action: .removed, apps: [.init(name: "Cursor", icon: Fixtures.appIcon, failed: false, changed: true)])
        }
        return Fixtures.installResult(failed: toast.failed)
    }
}
