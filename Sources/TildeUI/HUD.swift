import AppKit
import SwiftUI

/// Floating indicator under the menu bar while annotating: status, agent message, tools
/// and the list of annotations, anchored at the top center.
///
/// The panel keeps one size and the content sits at its top. Resizing an NSHostingView
/// while SwiftUI changes its content re-centers the content for a frame, which makes the
/// pill jump. Transparent parts of the panel let mouse events through to the overlay.
@MainActor
final class HUDPanel {
    let window: NSPanel
    private let hosting: NSHostingView<HUDView>

    init(controller: AnnotationController) {
        hosting = NSHostingView(rootView: HUDView(controller: controller))
        hosting.sizingOptions = []
        window = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.contentView = hosting
    }

    /// Shows the HUD on the screen that has the pointer.
    func show() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.screens.first else {
            return
        }

        let visible = screen.visibleFrame
        let width: CGFloat = 560
        let frame = NSRect(x: screen.frame.midX - width / 2, y: visible.minY, width: width, height: visible.height + 4)
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    /// Whether an AppKit screen point is over the visible HUD content.
    func contains(_ point: NSPoint) -> Bool {
        guard window.isVisible else {
            return false
        }
        let size = hosting.fittingSize
        let content = NSRect(x: window.frame.midX - size.width / 2, y: window.frame.maxY - size.height, width: size.width, height: size.height)
        return content.contains(point)
    }
}

/// Borderless panel that can take keyboard focus without activating other windows.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct HUDView: View {
    @ObservedObject var controller: AnnotationController

    var body: some View {
        VStack(spacing: 8) {
            pill
            if controller.phase == .annotating, let message = controller.session?.message, !message.isEmpty {
                MessageBubble(client: controller.session?.client ?? "Agent", message: message)
            }
            if controller.phase == .annotating, controller.showsList, !controller.drafts.isEmpty {
                AnnotationList(controller: controller)
            }
        }
        .padding(16)
        .fixedSize()
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .animation(.spring(duration: 0.28), value: controller.showsList)
        .animation(.spring(duration: 0.28), value: controller.drafts.count)
    }

    @ViewBuilder
    private var pill: some View {
        HStack(spacing: 4) {
            switch controller.phase {
            case .sent(let confirmation):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.tildeBlue)
                Text(confirmation)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.trailing, 6)
            case .annotating, .idle:
                annotatingContent
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(Capsule().fill(Color.tildeInk))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
    }

    @ViewBuilder
    private var annotatingContent: some View {
        let count = controller.drafts.count

        HStack(spacing: 9) {
            PulseDot(isActive: controller.phase == .annotating && !controller.isPaused)
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.isPaused ? "Paused" : "Annotating")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)

        Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 20)

        HUDButton(symbol: "list.bullet", badge: count, isOn: controller.showsList, help: "Show annotations") {
            controller.showsList.toggle()
        }
        .disabled(count == 0)

        HUDButton(symbol: controller.isPaused ? "play.fill" : "pause.fill", isOn: controller.isPaused, help: "Pause to use your apps  \(HotKeys.pauseTitle)") {
            controller.togglePause()
        }

        HUDButton(symbol: "trash", help: "Clear annotations") {
            controller.clearDrafts()
        }
        .disabled(count == 0)

        Button(action: controller.send) {
            HStack(spacing: 5) {
                Text("Send")
                Image(systemName: "arrow.up")
                    .font(.system(size: 10.5, weight: .bold))
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(Color.tildeBlue))
            .opacity(count == 0 && controller.composer == nil ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(count == 0 && controller.composer == nil)
        .help(sendHelp)
        .padding(.leading, 4)

        HUDButton(symbol: "xmark", help: "Cancel") {
            controller.cancel()
        }
    }

    private var sendHelp: String {
        guard let session = controller.session else {
            return "Send  ⌘↩"
        }
        if session.isLocal {
            return "Copy to clipboard  ⌘↩"
        }
        return "Send to \(session.client)  ⌘↩"
    }

    private var subtitle: String {
        if controller.isPaused {
            return "\(HotKeys.pauseTitle) to resume"
        }
        let client = controller.session?.client ?? "Agent"
        let count = controller.drafts.count
        if count == 0 {
            return "for \(client) · click or drag"
        }
        return "for \(client) · \(count) \(count == 1 ? "note" : "notes")"
    }
}

private struct HUDButton: View {
    let symbol: String
    var badge: Int = 0
    var isOn = false
    let help: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundStyle(.white.opacity(isEnabled ? 0.9 : 0.3))
            .padding(.horizontal, badge > 0 ? 9 : 0)
            .frame(minWidth: 30, minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(.white.opacity(isOn ? 0.16 : (isHovered && isEnabled ? 0.09 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

private struct PulseDot: View {
    let isActive: Bool

    var body: some View {
        ZStack {
            if isActive {
                // The animation is scoped to the ring so it never animates the HUD layout.
                PhaseAnimator([false, true]) { expanded in
                    ring
                        .scaleEffect(expanded ? 1 : 0.5)
                        .opacity(expanded ? 0 : 1)
                } animation: { expanded in
                    expanded ? .easeOut(duration: 1.4) : nil
                }
            }
            Circle()
                .fill(isActive ? Color.tildeBlue : Color.white.opacity(0.4))
                .frame(width: 8, height: 8)
        }
        .frame(width: 18, height: 18)
    }

    private var ring: some View {
        Circle()
            .fill(Color.tildeBlue.opacity(0.35))
            .frame(width: 18, height: 18)
    }
}

private struct MessageBubble: View {
    let client: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.tildeBlue)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(client)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.tildeInk))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
    }
}

/// The annotations so far, styled like a context list: thumbnail, type chip, comment.
private struct AnnotationList: View {
    @ObservedObject var controller: AnnotationController

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(controller.drafts.enumerated()), id: \.element.id) { index, draft in
                if index > 0 {
                    Divider().padding(.horizontal, 12)
                }
                AnnotationRow(number: index + 1, draft: draft, controller: controller)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: 16).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 4)
        .environment(\.colorScheme, .light)
    }
}

private struct AnnotationRow: View {
    let number: Int
    let draft: Draft
    @ObservedObject var controller: AnnotationController

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Thumbnail(data: draft.annotation.image)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("\(number)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.tildeBlue))
                    if case .region = draft.annotation.target {
                        Text("Selected region")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(draft.chip)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.06)))
                            .overlay(Capsule().strokeBorder(Color.black.opacity(0.08)))
                    }
                }
                Text(draft.annotation.comment.isEmpty ? "No comment" : draft.annotation.comment)
                    .font(.system(size: 13))
                    .foregroundStyle(draft.annotation.comment.isEmpty ? .secondary : .primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                RowButton(symbol: "pencil") { controller.edit(draft.id) }
                RowButton(symbol: "trash") { controller.deleteDraft(draft.id) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct Thumbnail: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 52, height: 36)
        .background(Color.black.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.black.opacity(0.1)))
    }
}

private struct RowButton: View {
    let symbol: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.black.opacity(isHovered ? 0.8 : 0.45))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(isHovered ? 0.06 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
