import TildeCore
import AppKit
import SwiftUI

/// Centred card that shows one annotation's close-up large and its context screenshot as a
/// tile, with its comment editable in place. A click on either image enlarges it to fill the
/// image area, with a Back button. ← and → cycle through the annotations; Esc goes back from
/// an enlarged image, then closes.
/// While the comment is being edited, those keys edit the text; ↩ or Esc ends editing.
/// The panel keeps one size so nothing moves while cycling.
@MainActor
final class PreviewPanel {
    let window: NSPanel
    private static let size = NSSize(width: 1000, height: 640)

    init(controller: AnnotationController) {
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.onKey = { [unowned panel] event in
            let isEditing = panel.firstResponder is NSTextView
            switch event.keyCode {
            case 53 where isEditing, 36 where isEditing && !event.modifierFlags.contains(.shift):
                panel.makeFirstResponder(nil)
            case 53 where controller.expandedPreviewImage != nil:
                controller.expandedPreviewImage = nil
            case 53:
                controller.closePreview()
            case 123 where !isEditing:
                controller.showAdjacentPreview(-1)
            case 124 where !isEditing:
                controller.showAdjacentPreview(1)
            default:
                return false
            }
            return true
        }

        let hosting = FirstMouseHostingView(rootView: PreviewView(controller: controller))
        hosting.sizingOptions = []

        window = panel
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.contentView = hosting
    }

    /// Shows the card centred on the screen that has the pointer, with no text field focused
    /// so the arrow keys navigate.
    func show() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.screens.first else {
            return
        }

        let visible = screen.visibleFrame
        let size = Self.size
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
    }

    func close() {
        window.orderOut(nil)
    }
}

/// Panel that handles navigation keys before its views, so a focused control cannot take them.
private final class KeyPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true {
            return
        }
        super.sendEvent(event)
    }
}

struct PreviewView: View {
    @ObservedObject var controller: AnnotationController

    var body: some View {
        Group {
            if let id = controller.previewID, let index = controller.drafts.firstIndex(where: { $0.id == id }) {
                card(index: index, draft: controller.drafts[index])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
        .tildeTooltipHost()
        .environment(\.colorScheme, .dark)
    }

    private func card(index: Int, draft: Draft) -> some View {
        let annotation = draft.annotation

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.tildeBlue))
                Text(summary(of: annotation))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Text("\(index + 1) of \(controller.drafts.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                PreviewButton(symbol: "xmark", help: "Close  Esc") {
                    controller.closePreview()
                }
            }

            images(of: annotation)

            // An enlarged screenshot gets the whole card below the header.
            if controller.expandedPreviewImage == nil {
                CommentEditor(controller: controller, id: draft.id, initial: annotation.comment)
                    .id(draft.id)
                footer(id: draft.id)
            }
        }
        .padding(18)
        // Opaque, unlike the HUD: a large see-through card would mix with the page behind it.
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.1)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
    }

    private func footer(id: Draft.ID) -> some View {
        HStack(spacing: 6) {
            PreviewButton(symbol: "chevron.left", help: "Previous  ←") {
                controller.showAdjacentPreview(-1)
            }
            PreviewButton(symbol: "chevron.right", help: "Next  →") {
                controller.showAdjacentPreview(1)
            }
            Spacer()
            PreviewButton(symbol: "trash", title: "Delete", isDestructive: true, help: "Delete this annotation") {
                controller.deleteDraft(id)
            }
        }
    }

    /// The close-up fills the image area and the context sits beside it as a tile. An
    /// enlarged screenshot replaces both, under a Back button.
    @ViewBuilder
    private func images(of annotation: Annotation) -> some View {
        switch controller.expandedPreviewImage {
        case .closeUp:
            enlarged(title: "Close-up", data: annotation.image)
        case .context:
            enlarged(title: "Context", data: annotation.contextImage)
        case nil:
            HStack(alignment: .top, spacing: 12) {
                Screenshot(title: "Close-up", data: annotation.image) {
                    controller.expandedPreviewImage = .closeUp
                }
                Screenshot(title: "Context", data: annotation.contextImage) {
                    controller.expandedPreviewImage = .context
                }
                .frame(width: 240, height: 180)
            }
        }
    }

    private func enlarged(title: String, data: Data?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PreviewButton(symbol: "chevron.left", title: "Back", help: "Back  Esc") {
                    controller.expandedPreviewImage = nil
                }
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            ImageSlot(data: data)
        }
    }

    private func summary(of annotation: Annotation) -> String {
        switch annotation.target {
        case .region:
            return "Region \(Int(annotation.frame.width))×\(Int(annotation.frame.height))"
        case .element(.web(let element)):
            return "<\(element.tag)> on \(element.url)"
        case .element(.native(let element)):
            return "\(element.role) in \(element.app)"
        }
    }
}

/// A labelled screenshot that enlarges on click.
private struct Screenshot: View {
    let title: String
    let data: Data?
    let enlarge: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            ImageSlot(data: data)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(isHovered ? 0.95 : 0.6))
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.55)))
                        .padding(8)
                }
                .onHover { isHovered = $0 }
                .onTapGesture(perform: enlarge)
                .tildeTooltip("Enlarge")
        }
    }
}

/// A slot that letterboxes one screenshot. Small screenshots grow to at most their pixel size
/// in points, which is twice their size on a Retina screen.
private struct ImageSlot: View {
    let data: Data?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05))
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                    .padding(8)
            } else {
                Text("No screenshot")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.1)))
        .contentShape(Rectangle())
    }
}

/// The annotation's comment, saved on every change.
private struct CommentEditor: View {
    @ObservedObject var controller: AnnotationController
    let id: Draft.ID
    @State private var text: String

    init(controller: AnnotationController, id: Draft.ID, initial: String) {
        self.controller = controller
        self.id = id
        _text = State(initialValue: initial)
    }

    var body: some View {
        TextField("Add a comment", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .lineLimit(3, reservesSpace: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.1)))
            .onChange(of: text) {
                controller.updateComment(id, text)
            }
    }
}

private struct PreviewButton: View {
    let symbol: String
    var title: String?
    var isDestructive = false
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                if let title {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, title == nil ? 0 : 10)
            .frame(minWidth: 30, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .tildeTooltip(help)
    }
    private var foreground: Color {
        if isDestructive {
            return Color.red.opacity(isHovered ? 1 : 0.85)
        }
        return .white.opacity(isHovered ? 0.95 : 0.7)
    }

    private var background: Color {
        if isDestructive {
            return Color.red.opacity(isHovered ? 0.26 : 0.16)
        }
        return .white.opacity(isHovered ? 0.14 : 0.07)
    }
}
