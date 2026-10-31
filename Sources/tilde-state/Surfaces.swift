@testable import TildeUI
import TildeCore
import AppKit
import SwiftUI

/// Builds the real view of a state and draws it.
@MainActor
enum Surfaces {
    static func image(of state: UIState) async throws -> CGImage {
        let size = state.size.map { CGSize(width: $0[0], height: $0[1]) } ?? .zero
        let appearance: NSAppearance.Name = state.appearance == "light" ? .aqua : .darkAqua
        func hosted<V: View>(_ view: V, size: CGSize) async throws -> CGImage {
            let hosting = NSHostingView(rootView: view.transaction { $0.disablesAnimations = true })
            return try await Renderer.render(hosting, size: size, appearance: appearance)
        }

        switch state.surface {
        case "toast":
            let toast = ToastState()
            toast.result = result(of: state.toast!)
            toast.isShown = true
            return try await hosted(InstallToastView(state: toast), size: size)

        case "settings":
            return try await hosted(SettingsView(model: try settings(state.settings!)), size: size)

        case "restorePrompt":
            let prompt = RestorePromptState()
            prompt.record = Fixtures.record(notes: 3, updated: Date().addingTimeInterval(-720))
            prompt.isShown = true
            return try await hosted(RestorePromptView(state: prompt), size: size)

        case "tooltip":
            return try await hosted(TooltipBubble(text: state.text ?? "").frame(width: size.width, height: size.height), size: size)

        case "outline":
            let model = HomeOutline.Model()
            model.isSnapped = state.snapped ?? false
            let size = CGSize(width: HUDView.width, height: HUDMetrics.height)
            return try await hosted(OutlineView(model: model).frame(width: size.width, height: size.height), size: size)

        case "notesPanel":
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

        case "toolbar":
            let browser = BrowserController()
            let controller = AnnotationController(store: SessionStore(), browser: browser, archive: Fixtures.archive())
            try await Task.sleep(for: .milliseconds(20))
            apply(state, drafts: Fixtures.drafts(state.notes ?? 0), to: controller)
            let toolbar = BrowserToolbar(browser: browser, controller: controller).background(Color(white: 0.1))
            return try await hosted(toolbar, size: CGSize(width: BrowserMetrics.minWindowWidth, height: BrowserMetrics.toolbarHeight))

        case "hud":
            return try await hosted(HUDView(controller: try await controller(state)), size: size)

        case "comment":
            let controller = try await controller(state)
            let isEditing = state.editing ?? false
            controller.commentText = state.commentText ?? ""
            if isEditing, let draft = controller.drafts.first {
                apply(state, drafts: controller.drafts, composer: .edit(draft.id), to: controller)
                controller.commentText = draft.annotation.comment
            }
            return try await hosted(CommentView(controller: controller, chip: "span", isEditing: isEditing), size: size)

        case "preview":
            let controller = try await controller(state)
            return try await hosted(PreviewView(controller: controller), size: size)

        case "overlay":
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

        default:
            throw NSError(domain: "tilde-state", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown surface \(state.surface)"])
        }
    }

    private static func controller(_ state: UIState) async throws -> AnnotationController {
        let controller = try await Fixtures.controller()
        if let client = state.clientWithIcon {
            controller.clientIcon = { $0 == client ? Fixtures.appIcon : nil }
        }
        apply(state, drafts: Fixtures.drafts(state.notes ?? 0, withImages: state.images ?? true), to: controller)
        controller.showsList = state.list ?? false
        controller.setDrawingForTesting(state.drawing ?? false)
        controller.expandedPreviewImage = state.enlarged == "closeUp" ? .closeUp : state.enlarged == "context" ? .context : nil
        return controller
    }

    private static func apply(_ state: UIState, drafts: [Draft], composer: Composer? = nil, to controller: AnnotationController) {
        let confirmation: Confirmation? = switch state.confirmation {
        case "clearAll": .clearAll
        case "cancelSession": .cancelSession
        case "discardComment": .discardComment
        case "restore": .restore(Fixtures.record(notes: 3))
        default: nil
        }
        let notice: AnnotationController.PauseNotice? = state.pauseNotice == "escape" ? .escape : state.pauseNotice == "otherApp" ? .otherApp : nil
        controller.setStateForTesting(
            session: state.session.map { Fixtures.session(client: $0.client, isLocal: $0.isLocal ?? false) },
            drafts: drafts,
            phase: state.sent.map { .sent(confirmation: $0) } ?? .annotating,
            hover: state.hover == true ? Fixtures.hover() : nil,
            composer: composer,
            isPaused: state.paused ?? false,
            previewID: state.preview.map { drafts[$0].id },
            confirmation: confirmation,
            scope: state.scoped == true ? Fixtures.window : nil,
            isPickingWindow: state.pickingWindow ?? false,
            isHUDInBrowser: state.hudInBrowser ?? false,
            isAutoPaused: state.autoPaused ?? false,
            pauseNotice: notice
        )
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
        case "agents": .agents
        case "shortcuts": .shortcuts
        case "history": .history
        default: .general
        }
        let model = try Fixtures.settingsModel(page: page, history: history)
        model.expandedAgents = Set(state.expandedAgents ?? [])
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
