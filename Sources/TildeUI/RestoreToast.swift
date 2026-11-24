import AppKit
import SwiftUI

/// A toast that offers the session that was left unfinished, such as by a crash or a quit:
/// a regular pill alone at the top centre of the screen with the pointer. It never takes focus and
/// stays until Restore or Discard.
@MainActor
final class RestoreToast {
    private let panel: NSPanel
    private let state = RestoreToastState()
    private lazy var zoom = ZoomPresenter(panel: panel) { [state] isShown in
        state.isShown = isShown
    }

    private static let size = NSSize(width: 560, height: PillMetrics.height + 32)

    init(onRestore: @escaping (SessionRecord) -> Void, onDiscard: @escaping (SessionRecord) -> Void) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false

        let view = RestoreToastView(state: state) { [weak self] record in
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
        zoom.show()
    }

    func hide() {
        zoom.hide()
    }
}

@MainActor
final class RestoreToastState: ObservableObject {
    @Published var record: SessionRecord?
    @Published var isShown = false
}

struct RestoreToastView: View {
    @ObservedObject var state: RestoreToastState
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
            ToastLabel(symbol: "clock.arrow.circlepath", tint: .tildeBlue, title: "Restore unfinished session?", subtitle: Self.subtitle(record, now: Date()))
                .padding(.trailing, 8)

            PillTextButton(title: "Discard", isDestructive: false) {
                onDiscard(record)
            }
            PillTextButton(title: "Restore", isDestructive: false) {
                onRestore(record)
            }
        }
        .pillInsets(leading: .text)
        .pill()
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
