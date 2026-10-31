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
        let view = CommentView(controller: controller, chip: chip, isEditing: isEditing) { [weak self] change in
            self?.grow(by: change)
        }
        let size = NSHostingView(rootView: view).fittingSize
        // At the top of the window: when the window has grown and the content not yet, the
        // content stays where it is. Centred, it would jump up for one frame.
        let hosting = FittingHostingView(rootView: view.frame(maxHeight: .infinity, alignment: .top))
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

    }

    /// Grows downward, keeping the top edge in place, and upward only when the screen ends.
    /// It runs before the content changes, so the content never has less room than it needs:
    /// it would be cut off at the top until the window caught up.
    private func grow(by change: CGFloat) {
        var frame = window.frame
        frame.size.height += change
        frame.origin.y -= change
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame, frame.minY < visible.minY {
            frame.origin.y = min(visible.minY, visible.maxY - frame.height)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.setFrame(frame, display: false, animate: false)
        CATransaction.commit()
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
    let onHeightChange: (CGFloat) -> Void
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
    }

    /// The width of the text in the box, which never changes.
    static let width: CGFloat = 320 - 28 - 26 - 8

    /// The height of a text in the box, measured apart from the view on screen.
    static func height(of text: String) -> CGFloat {
        let storage = NSTextStorage(string: text.isEmpty ? " " : text, attributes: [.font: font])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let line = ceil(manager.defaultLineHeight(for: font))
        var used = manager.usedRect(for: container).height
        if text.hasSuffix("\n") {
            used = max(used, manager.extraLineFragmentRect.maxY)
        }
        return min(max(line, ceil(used)), maxHeight)
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
            let height = CommentEditor.height(of: text.string)
            if parent.height != height {
                parent.onHeightChange(height - parent.height)
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    parent.height = height
                }
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
    /// "inline" in the box, or "toast" under it: `defaults write dev.tilde.app commentDiscardStyle toast`.
    let discardStyle: String
    /// Called with the change in height just before the box changes size.
    let onHeightChange: (CGFloat) -> Void
    @State private var editorHeight: CGFloat
    @State private var isEmpty: Bool

    init(controller: AnnotationController, chip: String, isEditing: Bool, discardStyle: String? = nil, onHeightChange: @escaping (CGFloat) -> Void = { _ in }) {
        self.controller = controller
        self.chip = chip
        self.isEditing = isEditing
        self.discardStyle = discardStyle ?? UserDefaults.standard.string(forKey: "commentDiscardStyle") ?? "inline"
        self.onHeightChange = onHeightChange
        // The right size from the start, so that nothing has to correct it after the first layout.
        _editorHeight = State(initialValue: CommentEditor.height(of: controller.commentDraft.text))
        _isEmpty = State(initialValue: controller.commentDraft.text.isEmpty)
    }

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
                CommentEditor(draft: controller.commentDraft, height: $editorHeight, isEmpty: $isEmpty, onHeightChange: onHeightChange) {
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

            if isAskingToDiscard, discardStyle != "toast" {
                discardQuestion
            } else {
                HStack(spacing: 12) {
                    hint("↩", "add")
                    hint("⌘↩", "send")
                    hint("esc", "cancel")
                }
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
        .overlay(alignment: .bottom) {
            if isAskingToDiscard, discardStyle == "toast" {
                discardQuestion
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(width: 320)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.tildeInk))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.1)))
                    .offset(y: 44)
            }
        }
        .padding(.bottom, isAskingToDiscard && discardStyle == "toast" ? 44 : 0)
        .padding(18)
        .environment(\.colorScheme, .dark)
        .onExitCommand { controller.escapePressed() }
        .onChange(of: isAskingToDiscard) { _, isAsking in
            if discardStyle == "toast" {
                onHeightChange(isAsking ? 44 : -44)
            }
        }
    }

    private var isAskingToDiscard: Bool {
        controller.confirmation == .discardComment
    }

    /// In the size of the row of hints, so that the box does not move.
    private var discardQuestion: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Text("Discard comment?")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 4)
            Button(action: controller.dismissConfirmation) {
                hint("esc", "cancel")
            }
            .buttonStyle(.plain)
            Button(action: controller.confirm) {
                hint("↩", "discard", color: .red)
            }
            .buttonStyle(.plain)
        }
    }

    private func hint(_ key: String, _ label: String, color: Color = .secondary) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1)))
            Text(label)
                .font(.system(size: 10.5))
        }
        .foregroundStyle(color)
    }
}
