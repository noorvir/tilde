import AppKit
import SwiftUI

/// Floating indicator while annotating: status, agent message, tools and the list of
/// annotations. It sits at the top centre of the screen with the pointer, unless the user
/// dragged the pill somewhere else on that screen; the position is kept per screen.
///
/// The panel keeps one size and the content sits at its top. Resizing an NSHostingView
/// while SwiftUI changes its content re-centers the content for a frame, which makes the
/// pill jump. Transparent parts of the panel let mouse events through to the overlay.
@MainActor
final class HUDPanel {
    static let motion = Animation.spring(duration: 0.3, bounce: 0)

    let window: NSPanel
    private let hosting: FirstMouseHostingView<HUDView>
    private unowned let controller: AnnotationController
    private var pendingHide: DispatchWorkItem?
    /// Pointer and panel origin when a drag of the pill started.
    private var dragStart: (pointer: NSPoint, origin: NSPoint)?
    /// Whether the dragged pill is snapped to its home position.
    private var isSnappedHome = false
    private let homeOutline = HomeOutline()
    /// How close to home, in points, the dragged pill snaps there.
    private static let snapDistance: CGFloat = 40
    /// The visible content (pill, message, list) in the panel's SwiftUI coordinates, which
    /// have a top-left origin. The hosting view has no sizing options, so its fitting size
    /// is zero and cannot give this.
    private var contentFrame: CGRect = .zero

    private static let width: CGFloat = 560
    private static let positionsKey = "HUDPositions"

    init(controller: AnnotationController) {
        self.controller = controller
        hosting = FirstMouseHostingView(rootView: HUDView(controller: controller))
        hosting.sizingOptions = []
        // Not key: clicks on the HUD leave keyboard focus with the overlay for Esc and ⌘↩.
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.rootView = HUDView(controller: controller) { [weak self] ended in
            self?.dragPill(ended: ended)
        } onContentFrame: { [weak self] frame in
            self?.contentFrame = frame
        }
    }

    /// Shows the HUD on the screen that has the pointer.
    func show() {
        pendingHide?.cancel()
        place()
        window.orderFrontRegardless()

        // Grow on the next pass, after SwiftUI has laid out the collapsed pill.
        DispatchQueue.main.async { [controller] in
            withAnimation(Self.motion) {
                controller.isHUDShown = true
            }
        }
    }

    /// Collapses the pill into its centre, then hides the panel.
    func hide() {
        withAnimation(Self.motion) {
            controller.isHUDShown = false
        }
        let hide = DispatchWorkItem { [window] in
            window.orderOut(nil)
        }
        pendingHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: hide)
    }

    /// Forgets the dragged positions and moves the HUD back to the top centre.
    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.positionsKey)
        if window.isVisible {
            place()
        }
    }

    /// Puts the panel on the screen with the pointer, at the saved position for that screen.
    private func place() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.screens.first else {
            return
        }

        let top = Self.clamped(savedTop(on: screen) ?? Self.homeTop(on: screen), on: screen)
        let height = screen.visibleFrame.height + 4
        window.setFrame(NSRect(x: top.x - Self.width / 2, y: top.y - height, width: Self.width, height: height), display: true)
    }

    /// Moves the panel with the pointer while the pill is dragged, showing the home position
    /// and snapping to it when close. At the end, a snapped pill goes back to home; any other
    /// is kept on its screen and its position saved.
    private func dragPill(ended: Bool) {
        let pointer = NSEvent.mouseLocation
        let start = dragStart ?? (pointer, window.frame.origin)
        dragStart = start

        let height = window.frame.height
        var top = NSPoint(x: start.origin.x + pointer.x - start.pointer.x + Self.width / 2, y: start.origin.y + pointer.y - start.pointer.y + height)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(top) }) ?? NSScreen.screens.first(where: { $0.frame.contains(pointer) }) else {
            return
        }

        let home = Self.homeTop(on: screen)
        let isNearHome = hypot(top.x - home.x, top.y - home.y) < Self.snapDistance
        if isNearHome {
            top = home
        }
        let frame = NSRect(x: top.x - Self.width / 2, y: top.y - height, width: Self.width, height: height)
        if isNearHome && !isSnappedHome {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                window.animator().setFrame(frame, display: true)
            }
        } else if !isNearHome || !isSnappedHome {
            window.setFrameOrigin(frame.origin)
        }
        isSnappedHome = isNearHome

        // The outline matches the pill: below the 16 pt content padding, at the pill's width.
        let outline = NSRect(x: home.x - HUDView.width / 2, y: home.y - 16 - HUDMetrics.height, width: HUDView.width, height: HUDMetrics.height)
        homeOutline.show(outline, isSnapped: isNearHome, below: window.windowNumber)
        guard ended else {
            return
        }

        dragStart = nil
        isSnappedHome = false
        homeOutline.hide()
        if isNearHome {
            forgetTop(on: screen)
            return
        }
        let kept = Self.clamped(top, on: screen)
        window.setFrameOrigin(NSPoint(x: kept.x - Self.width / 2, y: kept.y - height))
        saveTop(kept, on: screen)
    }

    /// Top centre of the panel at home: the top centre of the screen's visible area.
    private static func homeTop(on screen: NSScreen) -> NSPoint {
        NSPoint(x: screen.frame.midX, y: screen.visibleFrame.maxY + 4)
    }

    /// Keeps the pill's top centre inside the screen's visible area.
    private static func clamped(_ top: NSPoint, on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        let halfWidth = HUDView.width / 2 + 16
        let x = min(max(top.x, visible.minX + halfWidth), visible.maxX - halfWidth)
        let y = min(max(top.y, visible.minY + HUDMetrics.height + 32), visible.maxY + 4)
        return NSPoint(x: x, y: y)
    }

    /// Saved positions are offsets from each screen's top-left corner, keyed by display ID.
    private func savedTop(on screen: NSScreen) -> NSPoint? {
        let positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: [Double]]
        guard let offset = positions?[Self.key(for: screen)], offset.count == 2 else {
            return nil
        }
        return NSPoint(x: screen.frame.minX + offset[0], y: screen.frame.maxY + offset[1])
    }

    private func saveTop(_ top: NSPoint, on screen: NSScreen) {
        var positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: [Double]] ?? [:]
        positions[Self.key(for: screen)] = [top.x - screen.frame.minX, top.y - screen.frame.maxY]
        UserDefaults.standard.set(positions, forKey: Self.positionsKey)
    }

    private func forgetTop(on screen: NSScreen) {
        var positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: [Double]] ?? [:]
        positions[Self.key(for: screen)] = nil
        UserDefaults.standard.set(positions, forKey: Self.positionsKey)
    }

    private static func key(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.stringValue ?? screen.localizedName
    }

    /// Whether an AppKit screen point is over the visible HUD content.
    func contains(_ point: NSPoint) -> Bool {
        guard window.isVisible, controller.isHUDShown else {
            return false
        }
        let frame = window.frame
        let content = NSRect(
            x: frame.minX + contentFrame.minX, y: frame.maxY - contentFrame.maxY,
            width: contentFrame.width, height: contentFrame.height
        )
        return content.contains(point)
    }
}

/// Borderless panel that can take keyboard focus without activating other windows.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct HUDView: View {
    static let width: CGFloat = 462

    @ObservedObject var controller: AnnotationController
    /// Called while the pill is dragged; `true` when the drag ends.
    var onDrag: (_ ended: Bool) -> Void = { _ in }
    /// Reports the frame of the visible content in the window, top-left origin.
    var onContentFrame: (CGRect) -> Void = { _ in }
    @State private var isPillHovered = false

    var body: some View {
        VStack(spacing: 8) {
            pill
            if controller.isHUDShown, controller.phase == .annotating, let message = controller.session?.message, !message.isEmpty {
                MessageBubble(client: controller.session?.client ?? "Agent", message: message)
                    .transition(Self.zoom)
            }
            if controller.isHUDShown, controller.phase == .annotating, controller.showsList, !controller.drafts.isEmpty {
                AnnotationList(controller: controller)
                    .transition(Self.zoom)
            }
        }
        .padding(16)
        .fixedSize()
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: onContentFrame)
        .tildeTooltipHost()
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .animation(.spring(duration: 0.28), value: controller.showsList)
        .animation(.spring(duration: 0.28), value: controller.drafts.count)
        .animation(HUDPanel.motion, value: controller.phase)
        .animation(.easeInOut(duration: 0.18), value: controller.confirmation)
    }

    /// How the message and list appear and go with the HUD: the same zoom as the pill.
    private static let zoom = AnyTransition.scale(scale: 0.5, anchor: .top).combined(with: .opacity)

    private var pillScale: CGFloat {
        if !controller.isHUDShown {
            return 0.5
        }
        return isPillHovered ? 1.03 : 1
    }

    /// The pill keeps one width while annotating, so it never jumps between states. After
    /// Send it shrinks to fit the confirmation.
    private var pillContentWidth: CGFloat? {
        if case .sent = controller.phase {
            return nil
        }
        return HUDView.width
    }

    @ViewBuilder
    private var pill: some View {
        HStack(spacing: 4) {
            switch controller.phase {
            case .sent(let confirmation):
                HStack(spacing: HUDMetrics.iconGap) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.tildeBlue)
                    Text(confirmation)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
            case .annotating, .idle:
                // Stacked, so the crossfade between the two never lays them out side by side.
                ZStack {
                    if let confirmation = controller.confirmation {
                        HStack(spacing: 4) {
                            confirmContent(confirmation)
                        }
                        .transition(.opacity)
                    } else {
                        HStack(spacing: 4) {
                            annotatingContent
                        }
                        .transition(.opacity)
                    }
                }
            }
        }
        .padding(.leading, HUDMetrics.leadingInset)
        .padding(.trailing, HUDMetrics.trailingInset)
        .frame(width: pillContentWidth, height: HUDMetrics.height)
        .clipShape(Capsule())
        .background(Capsule().fill(Color.tildeInk))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
        // Opening and closing zoom the laid-out pill in and out of its centre. Under the
        // pointer it grows a little to show that it can be dragged; a drag that starts on a
        // button moves the HUD and does not press it.
        .scaleEffect(pillScale)
        .opacity(controller.isHUDShown ? 1 : 0)
        .animation(.spring(duration: 0.25), value: isPillHovered)
        .onHover { isPillHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in onDrag(false) }
                .onEnded { _ in onDrag(true) }
        )
    }

    @ViewBuilder
    private var annotatingContent: some View {
        let count = controller.drafts.count

        HStack(spacing: HUDMetrics.iconGap) {
            PulseDot(isActive: controller.phase == .annotating && !controller.isPaused)
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.isPaused ? "Paused" : "Annotating")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
        }
        .padding(.trailing, HUDMetrics.iconGap)
        .frame(maxWidth: .infinity, alignment: .leading)

        Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 20)

        HUDButton(symbol: "list.bullet", badge: count, isOn: controller.showsList, help: controller.showsList ? "Hide annotations" : "Show annotations") {
            controller.showsList.toggle()
        }
        .disabled(count == 0)

        HUDButton(symbol: controller.isPaused ? "play.fill" : "pause.fill", isOn: controller.isPaused, help: "\(controller.isPaused ? "Resume" : "Pause") annotating (\(HotKeys.pauseTitle))") {
            controller.togglePause()
        }

        HUDButton(symbol: "trash", isDestructive: true, help: "Clear all annotations and keep annotating") {
            controller.requestClearAll()
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
        .tildeTooltip(sendHelp)
        .padding(.leading, 4)

        HUDButton(symbol: "xmark", help: "Cancel: discard everything and close") {
            controller.requestCancel()
        }
    }

    /// Replaces the pill's content, at the same size, with a question and two buttons.
    @ViewBuilder
    private func confirmContent(_ confirmation: Confirmation) -> some View {
        let count = controller.drafts.count
        let all = count == 1 ? "the annotation" : "all \(count) annotations"

        HStack(spacing: HUDMetrics.iconGap) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.red)
            switch confirmation {
            case .clearAll:
                Text("Clear \(all)?")
            case .cancelSession:
                Text("Discard \(all) and close?")
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)

        PillTextButton(title: "Cancel", isDestructive: false) {
            controller.dismissConfirmation()
        }
        .tildeTooltip("Keep the annotations (Esc)")

        switch confirmation {
        case .clearAll:
            PillTextButton(title: "Clear", isDestructive: true) {
                controller.confirm()
            }
            .tildeTooltip("Delete all annotations (↩)")
        case .cancelSession:
            PillTextButton(title: "Discard", isDestructive: true) {
                controller.confirm()
            }
            .tildeTooltip("Discard everything and close (↩)")
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
    var isDestructive = false
    let help: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var foreground: Color {
        if isDestructive {
            return Color.red.opacity(isEnabled ? 1 : 0.4)
        }
        return .white.opacity(isEnabled ? 0.9 : 0.3)
    }

    private var background: Color {
        if isDestructive {
            return Color.red.opacity(isHovered && isEnabled ? 0.28 : 0.16)
        }
        return .white.opacity(isOn ? 0.16 : (isHovered && isEnabled ? 0.09 : 0))
    }

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
            .foregroundStyle(foreground)
            .padding(.horizontal, badge > 0 ? 9 : 0)
            .frame(minWidth: 30, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 9).fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .tildeTooltip(help)
    }
}

/// A text button for the pill's confirm state; destructive ones are red like Delete.
private struct PillTextButton: View {
    let title: String
    let isDestructive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(isDestructive ? Color.red : .white.opacity(0.9))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(background))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isDestructive {
            return Color.red.opacity(isHovered ? 0.28 : 0.16)
        }
        return .white.opacity(isHovered ? 0.16 : 0.09)
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
        HStack(alignment: .top, spacing: HUDMetrics.iconGap) {
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
        .padding(.leading, HUDMetrics.leadingInset)
        .padding(.trailing, HUDMetrics.trailingInset)
        .padding(.vertical, 9)
        .frame(width: HUDView.width, alignment: .leading)
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
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.leading, HUDMetrics.leadingInset).padding(.trailing, HUDMetrics.trailingInset)
                }
                AnnotationRow(number: index + 1, draft: draft, controller: controller)
            }
        }
        .padding(.vertical, 4)
        .frame(width: HUDView.width)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.tildeInk))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 4)
        .environment(\.colorScheme, .dark)
    }
}

private struct AnnotationRow: View {
    let number: Int
    let draft: Draft
    @ObservedObject var controller: AnnotationController
    @State private var isHovered = false

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
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
                    }
                }
                Text(draft.annotation.comment.isEmpty ? "No comment" : draft.annotation.comment)
                    .font(.system(size: 13))
                    .foregroundStyle(draft.annotation.comment.isEmpty ? .secondary : .primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // A button's click does not reach the row's tap gesture, so Delete never opens the preview.
            RowDeleteButton { controller.deleteDraft(draft.id) }
                .tildeTooltip("Delete this annotation")
        }
        .padding(.leading, HUDMetrics.leadingInset)
        .padding(.trailing, HUDMetrics.trailingInset)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(isHovered ? 0.06 : 0)).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { controller.preview(draft.id) }
        .tildeTooltip("Open preview")
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
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1)))
    }
}

/// Trash button of a list row, red like the other delete buttons.
private struct RowDeleteButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.red.opacity(isHovered ? 1 : 0.85))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.red.opacity(isHovered ? 0.26 : 0.12)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
