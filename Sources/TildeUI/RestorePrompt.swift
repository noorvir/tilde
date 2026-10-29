import AppKit
import SwiftUI

/// Offers the session that was left unfinished, such as by a crash or a quit, in the HUD's
/// pill style at the top centre of the screen with the pointer. It never takes focus and
/// stays until Restore or Discard.
@MainActor
final class RestorePrompt {
    private let panel: NSPanel
    private let state = RestorePromptState()

    private static let size = NSSize(width: 560, height: HUDMetrics.height + 32)

    init(onRestore: @escaping (SessionRecord) -> Void, onDiscard: @escaping (SessionRecord) -> Void) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false

        let view = RestorePromptView(state: state) { [weak self] record in
            self?.hide()
            onRestore(record)
        } onDiscard: { [weak self] record in
            self?.hide()
            onDiscard(record)
        }
        panel.contentView = FirstMouseHostingView(rootView: view)
    }

    func show(_ record: SessionRecord) {
        state.record = record
        let pointer = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.screens.first {
            let top = HUDPanel.homeTop(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
            panel.setFrameOrigin(NSPoint(x: top.x - Self.size.width / 2, y: top.y - Self.size.height))
        }
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [state] in
            withAnimation(HUDPanel.motion) {
                state.isShown = true
            }
        }
    }

    func hide() {
        withAnimation(HUDPanel.motion) {
            state.isShown = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [panel] in
            panel.orderOut(nil)
        }
    }
}

@MainActor
final class RestorePromptState: ObservableObject {
    @Published var record: SessionRecord?
    @Published var isShown = false
}

struct RestorePromptView: View {
    @ObservedObject var state: RestorePromptState
    var onRestore: (SessionRecord) -> Void = { _ in }
    var onDiscard: (SessionRecord) -> Void = { _ in }

    var body: some View {
        VStack {
            if let record = state.record {
                pill(record)
            }
        }
        .padding(16)
        .fixedSize()
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
    }

    private func pill(_ record: SessionRecord) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: HUDMetrics.iconGap) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.tildeBlue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Restore unfinished session?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(Self.subtitle(record, now: Date()))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.trailing, 8)

            PillTextButton(title: "Discard", isDestructive: false) {
                onDiscard(record)
            }
            PillTextButton(title: "Restore", isDestructive: false) {
                onRestore(record)
            }
        }
        .padding(.leading, HUDMetrics.leadingInset)
        .padding(.trailing, 8)
        .frame(height: HUDMetrics.height)
        .background(Capsule().fill(Color.tildeInk))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
        .scaleEffect(state.isShown ? 1 : 0.5)
        .opacity(state.isShown ? 1 : 0)
    }

    /// "3 notes · for Codex · 12 min ago".
    static func subtitle(_ record: SessionRecord, now: Date) -> String {
        let count = record.notes.count
        let notes = "\(count) \(count == 1 ? "note" : "notes")"
        let age = RelativeDateTimeFormatter().localizedString(for: record.updated, relativeTo: now)
        if record.isLocal {
            return "\(notes) · \(age)"
        }
        return "\(notes) · for \(record.client) · \(age)"
    }
}
