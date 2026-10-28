@testable import TildeUI
import TildeCore
import AppKit
import SwiftUI
import Testing

/// Pixel snapshots of every HUD, list, comment box, preview, tooltip, outline and overlay
/// state. See `Snapshot` for how they render and how to record them again.
@MainActor
@Suite(.serialized)
struct SnapshotTests {
    let controller: AnnotationController

    init() async throws {
        controller = try await Fixtures.controller()
    }

    // MARK: - HUD

    private func assertHUD(_ name: String, height: CGFloat = 80, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await Snapshot.assertView(HUDView(controller: controller), size: CGSize(width: 520, height: height), named: name, sourceLocation: sourceLocation)
    }

    @Test func hudAnnotatingEmpty() async throws {
        controller.setStateForTesting(session: Fixtures.session())
        try await assertHUD("hud-annotating-empty")
    }

    @Test func hudAnnotatingWithNotes() async throws {
        controller.setStateForTesting(session: Fixtures.session(), drafts: Fixtures.drafts(3))
        try await assertHUD("hud-annotating-3-notes")
    }

    @Test func hudLocalSession() async throws {
        controller.setStateForTesting(session: Fixtures.session(client: "You", isLocal: true), drafts: Fixtures.drafts(1))
        try await assertHUD("hud-local-1-note")
    }

    @Test func hudPaused() async throws {
        controller.setStateForTesting(session: Fixtures.session(), drafts: Fixtures.drafts(2), isPaused: true)
        try await assertHUD("hud-paused")
    }

    @Test func hudConfirmClear() async throws {
        controller.setStateForTesting(session: Fixtures.session(), drafts: Fixtures.drafts(3), confirmation: .clearAll)
        try await assertHUD("hud-confirm-clear")
    }

    @Test func hudConfirmCancelOne() async throws {
        controller.setStateForTesting(session: Fixtures.session(), drafts: Fixtures.drafts(1), confirmation: .cancelSession)
        try await assertHUD("hud-confirm-cancel-1")
    }

    @Test func hudSent() async throws {
        controller.setStateForTesting(session: nil, phase: .sent(confirmation: "Sent to Codex"))
        try await assertHUD("hud-sent")
    }

    @Test func hudCopied() async throws {
        controller.setStateForTesting(session: nil, phase: .sent(confirmation: "Copied to clipboard"))
        try await assertHUD("hud-copied")
    }

    @Test func hudAgentMessage() async throws {
        controller.setStateForTesting(session: Fixtures.session(message: "Check the documents table: owner chips and spacing."))
        try await assertHUD("hud-agent-message", height: 150)
    }

    @Test func hudListOneRow() async throws {
        controller.setStateForTesting(session: Fixtures.session(), drafts: Fixtures.drafts(1))
        controller.showsList = true
        try await assertHUD("hud-list-1", height: 170)
    }

    @Test func hudListThreeRows() async throws {
        controller.setStateForTesting(session: Fixtures.session(), drafts: Fixtures.drafts(3))
        controller.showsList = true
        try await assertHUD("hud-list-3", height: 330)
    }

    // MARK: - Comment box

    @Test func commentNew() async throws {
        // A new comment starts empty and shows its placeholder.
        controller.setStateForTesting(session: Fixtures.session())
        controller.commentText = ""
        try await Snapshot.assertView(
            CommentView(controller: controller, chip: "span", isEditing: false),
            size: CGSize(width: 360, height: 150), named: "comment-new"
        )
    }

    @Test func commentEditing() async throws {
        let drafts = Fixtures.drafts(1)
        controller.setStateForTesting(session: Fixtures.session(), drafts: drafts, composer: .edit(drafts[0].id))
        controller.commentText = drafts[0].annotation.comment
        try await Snapshot.assertView(
            CommentView(controller: controller, chip: "span", isEditing: true),
            size: CGSize(width: 360, height: 150), named: "comment-editing"
        )
    }

    // MARK: - Preview

    private func assertPreview(_ name: String, drafts: [Draft], shown index: Int, enlarged: PreviewImage? = nil, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        controller.setStateForTesting(session: Fixtures.session(), drafts: drafts, previewID: drafts[index].id)
        controller.expandedPreviewImage = enlarged
        try await Snapshot.assertView(PreviewView(controller: controller), size: CGSize(width: 1000, height: 640), named: name, sourceLocation: sourceLocation)
    }

    @Test func previewNormal() async throws {
        try await assertPreview("preview-normal", drafts: Fixtures.drafts(3), shown: 1)
    }

    @Test func previewEnlargedCloseUp() async throws {
        try await assertPreview("preview-enlarged-close-up", drafts: Fixtures.drafts(3), shown: 0, enlarged: .closeUp)
    }

    @Test func previewEnlargedContext() async throws {
        try await assertPreview("preview-enlarged-context", drafts: Fixtures.drafts(3), shown: 2, enlarged: .context)
    }

    @Test func previewWithoutScreenshots() async throws {
        try await assertPreview("preview-no-screenshots", drafts: Fixtures.drafts(1, withImages: false), shown: 0)
    }

    // MARK: - Small pieces

    @Test func tooltip() async throws {
        try await Snapshot.assertView(
            TooltipBubble(text: "Clear all annotations and keep annotating").frame(width: 300, height: 44),
            size: CGSize(width: 300, height: 44), named: "tooltip"
        )
    }

    @Test func homeOutline() async throws {
        let model = HomeOutline.Model()
        let size = CGSize(width: HUDView.width, height: HUDMetrics.height)
        try await Snapshot.assertView(OutlineView(model: model).frame(width: size.width, height: size.height), size: size, named: "home-outline")
        model.isSnapped = true
        try await Snapshot.assertView(OutlineView(model: model).frame(width: size.width, height: size.height), size: size, named: "home-outline-snapped")
    }

    // MARK: - Overlay

    /// The overlay draws in screen coordinates; its window sits where the screen's top-left
    /// corner maps to the view's top-left corner, so fixture frames land inside it.
    private func assertOverlay(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let size = CGSize(width: 520, height: 340)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? size.height
        try await Snapshot.assertDrawnView(
            OverlayView(controller: controller), size: size,
            windowOrigin: NSPoint(x: 0, y: primaryHeight - size.height), named: name, sourceLocation: sourceLocation
        )
    }

    @Test func overlayHover() async throws {
        controller.setStateForTesting(session: Fixtures.session(), hover: Fixtures.hover())
        try await assertOverlay("overlay-hover")
    }

    @Test func overlayMarkers() async throws {
        controller.setStateForTesting(session: Fixtures.session(), drafts: Fixtures.drafts(3))
        try await assertOverlay("overlay-markers")
    }
}
