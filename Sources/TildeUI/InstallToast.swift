import AppKit
import SwiftUI

/// A short note after an install or uninstall, in the HUD's pill style at the top centre of
/// the screen with the pointer. It zooms in and out like the HUD, never takes focus, and goes
/// after a few seconds, after Esc, or after a click elsewhere. The pointer on it keeps it open.
@MainActor
final class InstallToast {
    private let panel: NSPanel
    private let state = ToastState()
    private var pendingDismiss: DispatchWorkItem?
    private var pendingHide: DispatchWorkItem?
    private var monitors: [Any] = []

    private static let size = NSSize(width: 560, height: HUDMetrics.height + 32)

    init(onDetails: @escaping () -> Void) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false

        let view = InstallToastView(state: state) { [weak self] in
            self?.hide()
            onDetails()
        } onHover: { [weak self] isHovered in
            self?.hoverChanged(isHovered)
        }
        panel.contentView = FirstMouseHostingView(rootView: view)
    }

    func show(_ result: InstallResult) {
        pendingHide?.cancel()
        state.result = result
        place()
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [state] in
            withAnimation(HUDPanel.motion) {
                state.isShown = true
            }
        }
        scheduleDismiss()
        watchForDismissal()
    }

    func hide() {
        pendingDismiss?.cancel()
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []

        withAnimation(HUDPanel.motion) {
            state.isShown = false
        }
        let hide = DispatchWorkItem { [panel] in
            panel.orderOut(nil)
        }
        pendingHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: hide)
    }

    private func place() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.screens.first else {
            return
        }
        let top = HUDPanel.homeTop(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        panel.setFrameOrigin(NSPoint(x: top.x - Self.size.width / 2, y: top.y - Self.size.height))
    }

    /// Errors stay longer, so there is time to open Details.
    private func scheduleDismiss() {
        pendingDismiss?.cancel()
        let dismiss = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        pendingDismiss = dismiss
        let seconds: Double = (state.result?.failures ?? 0) > 0 ? 8 : 4
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: dismiss)
    }

    private func hoverChanged(_ isHovered: Bool) {
        if isHovered {
            pendingDismiss?.cancel()
        } else if state.isShown {
            scheduleDismiss()
        }
    }

    /// Esc anywhere, or a click outside the toast, closes it. Global monitors see other apps'
    /// events without taking focus from them.
    private func watchForDismissal() {
        guard monitors.isEmpty else {
            return
        }
        let escape: (NSEvent) -> Void = { [weak self] event in
            if event.keyCode == 53 {
                self?.hide()
            }
        }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: escape),
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                escape(event)
                return event
            },
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.hide()
            },
        ].compactMap { $0 }
    }
}

final class ToastState: ObservableObject {
    @Published var result: InstallResult?
    @Published var isShown = false
}

struct InstallToastView: View {
    @ObservedObject var state: ToastState
    var onDetails: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }

    var body: some View {
        VStack {
            if let result = state.result {
                pill(result)
            }
        }
        .padding(16)
        .fixedSize()
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
    }

    private func pill(_ result: InstallResult) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: HUDMetrics.iconGap) {
                Image(systemName: Self.symbol(result))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Self.color(result))
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.title(result))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(Self.subtitle(result))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            HStack(spacing: 2) {
                ForEach(Array(result.apps.prefix(7).enumerated()), id: \.offset) { _, app in
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                        .opacity(app.failed ? 0.35 : 1)
                }
            }

            PillTextButton(title: "Details", isDestructive: false, action: onDetails)
        }
        .padding(.leading, HUDMetrics.leadingInset)
        .padding(.trailing, 8)
        .frame(height: HUDMetrics.height)
        .background(Capsule().fill(Color.tildeInk))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
        .scaleEffect(state.isShown ? 1 : 0.5)
        .opacity(state.isShown ? 1 : 0)
        .onHover(perform: onHover)
    }

    static func title(_ result: InstallResult) -> String {
        let count = result.apps.count
        guard let first = result.apps.first else {
            return "No agent apps found"
        }

        let failures = result.failures
        let apps = count == 1 ? first.name : "\(count) apps"
        let done = result.action == .installed ? "Installed in" : "Removed from"
        if failures == 0 {
            return "\(done) \(apps)"
        }
        if failures == count {
            return result.action == .installed ? "Could not install in \(apps)" : "Could not remove from \(apps)"
        }
        return "\(done) \(count - failures) of \(count) apps · \(failures) failed"
    }

    static func subtitle(_ result: InstallResult) -> String {
        if result.apps.isEmpty {
            return "Details show how to set up other apps"
        }
        if result.failures > 0 {
            return "Details show what went wrong"
        }
        if !result.apps.contains(where: \.changed) {
            return result.action == .installed ? "Already up to date" : "Nothing to remove"
        }
        if result.action == .removed {
            return "Restart to finish"
        }
        return result.apps.count == 1 ? "Restart it to load Tilde" : "Restart them to load Tilde"
    }

    private static func symbol(_ result: InstallResult) -> String {
        if result.failures == 0 {
            return "checkmark.circle.fill"
        }
        return result.failures == result.apps.count ? "xmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private static func color(_ result: InstallResult) -> Color {
        if result.failures == 0 {
            return .green
        }
        return result.failures == result.apps.count ? .red : .yellow
    }
}
