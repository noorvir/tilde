import AppKit
import SwiftUI

/// A quiet note that an update is ready: a regular pill alone at the top centre of the screen
/// with the pointer. It never takes focus and goes after 10 seconds or Later; the pointer on it
/// keeps it. Restart installs the update now.
@MainActor
final class UpdateToast {
    private let panel: NSPanel
    private let state = UpdateToastState()
    private var pendingDismiss: DispatchWorkItem?
    private lazy var zoom = ZoomPresenter(panel: panel) { [state] isShown in
        state.isShown = isShown
    }

    private static let size = NSSize(width: 560, height: PillMetrics.height + 32)

    init(onRestart: @escaping () -> Void) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false

        let view = UpdateToastView(state: state) { [weak self] in
            self?.hide()
            onRestart()
        } onLater: { [weak self] in
            self?.hide()
        } onHover: { [weak self] isHovered in
            self?.hoverChanged(isHovered)
        }
        panel.contentView = FirstMouseHostingView(rootView: view)
    }

    func show(version: String) {
        state.version = version
        let pointer = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.screens.first {
            let top = HUDPanel.homeTop(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
            panel.setFrameOrigin(NSPoint(x: top.x - Self.size.width / 2, y: top.y - Self.size.height))
        }
        zoom.show()
        scheduleDismiss()
    }

    func hide() {
        pendingDismiss?.cancel()
        zoom.hide()
    }

    private func scheduleDismiss() {
        pendingDismiss?.cancel()
        let dismiss = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        pendingDismiss = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: dismiss)
    }

    private func hoverChanged(_ isHovered: Bool) {
        if isHovered {
            pendingDismiss?.cancel()
        } else if state.isShown {
            scheduleDismiss()
        }
    }
}

@MainActor
final class UpdateToastState: ObservableObject {
    @Published var version: String?
    @Published var isShown = false
}

struct UpdateToastView: View {
    @ObservedObject var state: UpdateToastState
    var onRestart: () -> Void = {}
    var onLater: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }

    var body: some View {
        VStack {
            if let version = state.version {
                pill(version)
            }
        }
        .padding(16)
        .fixedSize()
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
    }

    private func pill(_ version: String) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: PillMetrics.iconGap) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.tildeBlue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tilde \(version) is ready")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Installs when you quit Tilde")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.trailing, 8)

            PillTextButton(title: "Later", isDestructive: false, action: onLater)
            PillTextButton(title: "Restart", isDestructive: false, action: onRestart)
        }
        .pillInsets(leading: .text)
        .pill()
        .scaleEffect(state.isShown ? 1 : 0.5)
        .opacity(state.isShown ? 1 : 0)
        .onHover(perform: onHover)
    }
}
