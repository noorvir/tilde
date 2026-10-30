import AppKit
import SwiftUI
import os

/// The comment box that opens next to a new or edited annotation.
@MainActor
final class CommentPanel {
    let window: NSPanel
    private let controller: AnnotationController

    init(controller: AnnotationController) {
        self.controller = controller
        window = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isReleasedWhenClosed = false
    }

    /// Shows the box to the right of `marker`, or below `target` when there is no room on the
    /// right, kept inside the screen. Both are in Quartz coordinates.
    func show(chip: String, isEditing: Bool, near marker: CGPoint, below target: CGRect) {
        // A fresh hosting view resets focus and local state for each comment.
        let hosting = FittingHostingView(rootView: CommentView(controller: controller, chip: chip, isEditing: isEditing))
        let size = hosting.fittingSize
        let anchor = marker.flipped
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        var origin = NSPoint(x: anchor.x + 2, y: anchor.y - size.height + 30)
        if origin.x + size.width > visible.maxX {
            // The panel has 18 pt of transparent padding; align its card with the target's right edge.
            let bottom = target.flipped.minY
            origin = NSPoint(x: anchor.x - size.width + 18, y: bottom - size.height + 12)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)

        window.setFrame(NSRect(origin: origin, size: size), display: false)
        window.makeKeyAndOrderFront(nil)
        // Attach the content once the panel is key, so the text field can take focus on appear.
        window.contentView = hosting

        // Grow downward as the comment wraps, keeping the top edge in place.
        hosting.onSizeChange = { [weak window] size in
            guard let window, window.frame.size != size else {
                return
            }
            let frame = window.frame
            window.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
        }
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }
}

/// The text of the comment being written. Not published: typing changes nothing else on screen.
@MainActor
final class CommentDraft {
    var text = ""
}

/// The comment's text, in a plain text view: a key changes the text and nothing else, and the
/// box changes size only when the number of lines does.
private struct CommentEditor: NSViewRepresentable {
    static let font = NSFont.systemFont(ofSize: 14)
    /// Grows with the text up to about 400 pt, then scrolls.
    static let maxHeight: CGFloat = 400

    let draft: CommentDraft
    @Binding var height: CGFloat
    @Binding var isEmpty: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        let text = FocusedTextView(frame: .zero)
        text.isRichText = false
        text.allowsUndo = true
        text.drawsBackground = false
        text.font = Self.font
        text.textColor = .white
        text.insertionPointColor = .controlAccentColor
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = .width
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.string = draft.text
        text.delegate = context.coordinator
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        // The first layout knows the width, so the text of an edited note gets its height.
        DispatchQueue.main.async {
            if let text = view.documentView as? NSTextView {
                context.coordinator.updateHeight(of: text)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommentEditor
        private let log = Logger(subsystem: "dev.tilde.app", category: "typing")

        init(_ parent: CommentEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView else {
                return
            }
            parent.draft.text = text.string
            if parent.isEmpty != text.string.isEmpty {
                parent.isEmpty = text.string.isEmpty
            }
            updateHeight(of: text)
            if let event = NSApp.currentEvent, event.type == .keyDown {
                let took = ProcessInfo.processInfo.systemUptime - event.timestamp
                if took > 0.016 {
                    log.notice("key took \(Int(took * 1000), privacy: .public) ms")
                }
            }
        }

        func updateHeight(of text: NSTextView) {
            guard let manager = text.layoutManager, let container = text.textContainer else {
                return
            }
            manager.ensureLayout(for: container)
            let line = ceil(manager.defaultLineHeight(for: CommentEditor.font))
            let used = max(line, ceil(manager.usedRect(for: container).height))
            let height = min(used, CommentEditor.maxHeight)
            if parent.height != height {
                parent.height = height
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

private final class FocusedTextView: NSTextView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}

struct CommentView: View {
    @ObservedObject var controller: AnnotationController
    let chip: String
    let isEditing: Bool
    @State private var editorHeight = ceil(NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: 14)))
    @State private var isEmpty = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(chip)
                    .font(.system(size: 11, design: chip == "Region" ? .default : .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                Spacer()
                if isEditing, case .edit(let id) = controller.composer {
                    Button {
                        controller.deleteDraft(id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete annotation")
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                CommentEditor(draft: controller.commentDraft, height: $editorHeight, isEmpty: $isEmpty) {
                    controller.submitComment(thenSend: false)
                } onCancel: {
                    controller.escapePressed()
                }
                .frame(height: editorHeight)
                .overlay(alignment: .topLeading) {
                    if isEmpty {
                        Text("Add a comment")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.vertical, 3)

                Button {
                    controller.submitComment(thenSend: false)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.tildeBlue))
                }
                .buttonStyle(.plain)
                .help("Add  ↩")
            }

            HStack(spacing: 12) {
                hint("↩", "add")
                hint("⌘↩", "send")
                hint("esc", "cancel")
            }
        }
        .background {
            Button("Send") { controller.submitComment(thenSend: true) }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.tildeInk))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.24), radius: 16, y: 6)
        .padding(18)
        .environment(\.colorScheme, .dark)
        .onExitCommand { controller.escapePressed() }
        .onAppear { isEmpty = controller.commentDraft.text.isEmpty }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1)))
            Text(label)
                .font(.system(size: 10.5))
        }
        .foregroundStyle(.secondary)
    }
}
