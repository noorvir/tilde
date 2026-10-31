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
    private var clickMonitor: Any?

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
        // A click on the HUD gives Tilde the keyboard, for Esc and ↩.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak window, weak controller] event in
            if event.window === window {
                MainActor.assumeIsolated { controller?.takeKeyboard() }
            }
            return event
        }
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
        // Lays the collapsed pill out at its place now. The first time, the hosting view has
        // never been laid out, and its first layout inside the zoom below would animate the
        // pill in from the window's left edge.
        hosting.layoutSubtreeIfNeeded()
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

        let home = Self.homeTop(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        let top = Self.clamped(savedTop(on: screen) ?? home, in: screen.visibleFrame)
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

        let home = Self.homeTop(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        let isNearHome = Self.snapsHome(top, home: home)
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
        let kept = Self.clamped(top, in: screen.visibleFrame)
        window.setFrameOrigin(NSPoint(x: kept.x - Self.width / 2, y: kept.y - height))
        saveTop(kept, on: screen)
    }

    /// Top centre of the panel at home: the top centre of the screen's visible area.
    static func homeTop(screenFrame: NSRect, visibleFrame: NSRect) -> NSPoint {
        NSPoint(x: screenFrame.midX, y: visibleFrame.maxY + 4)
    }

    /// Whether a dragged panel top centre is close enough to home to snap there.
    static func snapsHome(_ top: NSPoint, home: NSPoint) -> Bool {
        hypot(top.x - home.x, top.y - home.y) < snapDistance
    }

    /// Keeps the pill's top centre inside the screen's visible area.
    static func clamped(_ top: NSPoint, in visible: NSRect) -> NSPoint {
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
        return Self.screenRect(ofContent: contentFrame, inWindow: window.frame).contains(point)
    }

    /// Converts a frame in the panel's SwiftUI space (top-left origin) to AppKit screen
    /// coordinates.
    static func screenRect(ofContent content: CGRect, inWindow frame: NSRect) -> NSRect {
        NSRect(x: frame.minX + content.minX, y: frame.maxY - content.maxY, width: content.width, height: content.height)
    }
}

/// Borderless panel that can take keyboard focus without activating other windows.
class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, insertNewlineOnShiftReturn(event, in: self) {
            return
        }
        super.sendEvent(event)
    }
}

/// Shift-Return and Option-Return add a line in a text field of a panel, as in chat apps; a
/// SwiftUI field would take Shift-Return as Return and submit. Returns whether it did.
func insertNewlineOnShiftReturn(_ event: NSEvent, in window: NSWindow) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard [36, 76].contains(event.keyCode), modifiers == .shift || modifiers == .option, let editor = window.firstResponder as? NSTextView else {
        return false
    }
    editor.insertNewlineIgnoringFieldEditor(nil)
    return true
}

struct HUDView: View {
    @Environment(\.isHUDEmbedded) private var isHUDEmbedded
    static let width: CGFloat = 462

    @ObservedObject var controller: AnnotationController
    /// In the toolbar of Tilde's browser instead of the floating panel: the pill alone, which
    /// does not move, and tooltips drawn by the browser.
    var isEmbedded = false
    /// Called while the pill is dragged; `true` when the drag ends.
    var onDrag: (_ ended: Bool) -> Void = { _ in }
    /// Reports the frame of the visible content in the window, top-left origin.
    var onContentFrame: (CGRect) -> Void = { _ in }
    @State private var isPillHovered = false

    var body: some View {
        if isEmbedded {
            pill
        } else {
            floating
        }
    }

    private var floating: some View {
        VStack(spacing: 8) {
            pill
            if controller.isHUDShown, let notice = controller.pauseNotice {
                PauseToast(notice: notice, controller: controller)
                    .transition(.move(edge: .top).combined(with: .opacity))
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
        .animation(.easeOut(duration: 0.15), value: controller.pauseNotice)
    }

    /// How the list appears and goes with the HUD: the same zoom as the pill.
    private static let zoom = AnyTransition.scale(scale: 0.5, anchor: .top).combined(with: .opacity)

    private var pillScale: CGFloat {
        if !controller.isHUDShown {
            return 0.5
        }
        return isPillHovered ? 1.015 : 1
    }

    /// The pill keeps one width while annotating, so it never jumps between states. After
    /// Send it shrinks to fit the confirmation.
    private var pillContentWidth: CGFloat? {
        if case .sent = controller.phase {
            return nil
        }
        return HUDView.width
    }

    /// The pill's content width, the same in every state; embedded, the same without the
    /// pill's insets.
    static let embeddedWidth = width - HUDMetrics.leadingInset - HUDMetrics.trailingInset

    @ViewBuilder
    private var pill: some View {
        if isEmbedded {
            pillContent
                .frame(width: pillContentWidth.map { _ in Self.embeddedWidth }, height: 30)
                .environment(\.isHUDEmbedded, true)
        } else {
            floatingPill
        }
    }

    /// The pill's content on the browser's toolbar: no capsule, and controls with the
    /// toolbar's corners.
    private var pillContent: some View {
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
                    if let confirmation = controller.confirmation, confirmation != .discardComment {
                        HStack(spacing: 4) {
                            confirmContent(confirmation)
                        }
                        .transition(.opacity)
                    } else if controller.isDrawing {
                        HStack(spacing: 4) {
                            drawingContent
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
    }

    @ViewBuilder
    private var drawingContent: some View {
        ForEach(Self.drawingTools, id: \.tool) { entry in
            HUDButton(image: Image(systemName: entry.symbol), isOn: controller.drawingTool == entry.tool, help: entry.help) {
                controller.setDrawingTool(entry.tool)
            }
        }
        Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 20)
        ForEach(Self.drawingColors, id: \.hex) { entry in
            Button {
                controller.setDrawingColor(entry.hex)
            } label: {
                Circle()
                    .fill(Color(hex: entry.hex))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Color.white.opacity(controller.drawingColor == entry.hex ? 1 : 0.25), lineWidth: controller.drawingColor == entry.hex ? 2 : 1))
                    .padding(1)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.name)
        }
        Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 20)
        HUDButton(image: Image(systemName: "arrow.uturn.backward"), help: "Undo") {
            controller.undoDrawing()
        }
        HUDButton(image: Image(systemName: "arrow.uturn.forward"), help: "Redo") {
            controller.redoDrawing()
        }
        Spacer(minLength: 0)
        PillTextButton(title: "Done", key: "esc", isDestructive: false) {
            controller.finishDrawing()
        }
        .fixedSize()
    }

    private static let drawingTools = [
        (tool: "selection", symbol: "cursorarrow", help: "Select"),
        (tool: "arrow", symbol: "arrow.up.right", help: "Arrow"),
        (tool: "rectangle", symbol: "rectangle", help: "Rectangle"),
        (tool: "ellipse", symbol: "circle", help: "Circle"),
        (tool: "freedraw", symbol: "scribble", help: "Freehand"),
    ]

    private static let drawingColors = [
        (hex: "#2F76FF", name: "Blue"),
        (hex: "#FF3B30", name: "Red"),
        (hex: "#FFCC00", name: "Yellow"),
        (hex: "#34C759", name: "Green"),
        (hex: "#FFFFFF", name: "White"),
        (hex: "#000000", name: "Black"),
    ]

    private var floatingPill: some View {
        pillContent
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
            // Where the status dot was: pause while annotating, Annotate (blue) while paused.
            HUDButton(
                image: controller.isEffectivelyPaused ? Image(nsImage: TildeMark.annotateIcon) : Image(systemName: "pause.fill"),
                size: 26, tint: controller.isEffectivelyPaused ? .tildeBlue : nil, help: pauseHelp
            ) {
                if controller.isEffectivelyPaused {
                    controller.resume()
                } else {
                    controller.togglePause()
                }
            }
            .padding(.leading, -4)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                subtitle
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
        }
        .padding(.trailing, HUDMetrics.iconGap)
        .frame(maxWidth: .infinity, alignment: .leading)

        Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 20)

        HUDButton(image: Image(systemName: "pencil.tip"), help: "Draw on the screen") {
            controller.startDrawing()
        }

        HUDButton(image: Image(systemName: "macwindow"), isOn: controller.scope != nil || controller.isPickingWindow, help: windowHelp) {
            controller.toggleWindowScope()
        }

        HUDButton(image: Image(systemName: "list.bullet"), badge: count, isOn: controller.showsList, help: controller.showsList ? "Hide annotations" : "Show annotations") {
            controller.showNotes()
        }
        .disabled(count == 0)

        HUDButton(image: Image(systemName: "trash"), isDestructive: true, help: "Clear all annotations and keep annotating") {
            controller.requestClearAll()
        }
        .disabled(count == 0)

        // A session without an agent copies the report. Both labels take the space of the wider
        // one, so the pill never shifts.
        let copies = controller.session?.isLocal == true
        Button(action: controller.send) {
            ZStack {
                sendLabel("Send", symbol: "arrow.up").hidden()
                sendLabel("Copy", symbol: "doc.on.doc").hidden()
                sendLabel(copies ? "Copy" : "Send", symbol: copies ? "doc.on.doc" : "arrow.up")
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(HUDShape(height: 28, isHUDEmbedded: isHUDEmbedded).fill(Color.tildeBlue))
            .opacity(count == 0 && controller.composer == nil ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(count == 0 && controller.composer == nil)
        .tildeTooltip(sendHelp)
        .padding(.leading, 4)

        HUDButton(image: Image(systemName: "xmark"), help: "Cancel and close (Esc)") {
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
                Text("Discard and close?")
            case .discardComment:
                // Asked on the comment box itself.
                EmptyView()
            case .restore(let record):
                Text("Replace \(count == 1 ? "the note" : "\(count) notes") with \(record.notes.count) saved?")
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)

        PillTextButton(title: "Cancel", key: "esc", isDestructive: false) {
            controller.dismissConfirmation()
        }
        .tildeTooltip("Keep the annotations")

        switch confirmation {
        case .clearAll:
            PillTextButton(title: "Clear", key: "↩", isDestructive: true) {
                controller.confirm()
            }
            .tildeTooltip("Delete all annotations")
        case .cancelSession:
            PillTextButton(title: "Discard", key: "↩", isDestructive: true) {
                controller.confirm()
            }
            .tildeTooltip("Discard \(all) and close")
        case .discardComment:
            EmptyView()
        case .restore:
            PillTextButton(title: "Replace", key: "↩", isDestructive: true) {
                controller.confirm()
            }
            .tildeTooltip("Replace the notes with the saved session's")
        }
    }

    /// Icon first, then the label, as in macOS buttons.
    private func sendLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
            Text(title)
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

    private var windowHelp: String {
        if let name = controller.scopeName {
            return "Annotating only \(name). Click to annotate all windows"
        }
        if controller.isPickingWindow {
            return "Click a window to annotate only it, or Esc"
        }
        return "Annotate a specific window"
    }

    /// "Pause (Esc)", and when paused "Annotate (Double-tap ⌃)".
    private var pauseHelp: String {
        guard controller.isEffectivelyPaused else {
            return "Pause (Esc)"
        }
        guard let shortcut = controller.shortcuts.shortcut(for: .startAnnotation) ?? controller.shortcuts.shortcut(for: .togglePause) else {
            return "Annotate"
        }
        return "Annotate (\(shortcut.title))"
    }

    private var title: String {
        if controller.isEffectivelyPaused {
            return "Paused"
        }
        return controller.isPickingWindow ? "Choose a window" : "Annotating"
    }

    /// The subtitle: the first candidate that fits the fixed pill, so words drop out and the
    /// text never ends in "…".
    private var subtitle: some View {
        let candidates = Self.subtitleCandidates(
            // A local session's report goes to the clipboard, like an agent's goes to the agent.
            client: controller.session.map { $0.isLocal ? "Clipboard" : $0.client },
            clientIcon: controller.session.flatMap { $0.isLocal ? Self.clipboardIcon : controller.clientIcon($0.client) },
            // The browser's own toolbar needs no "in Tilde Browser".
            scopeName: isEmbedded ? nil : controller.scopeName,
            scopeIcon: controller.scopeIcon,
            notes: controller.drafts.count,
            state: subtitleState
        )
        return ViewThatFits(in: .horizontal) {
            ForEach(Array(candidates.enumerated()), id: \.offset) { _, parts in
                SubtitleLine(parts: parts)
            }
        }
    }

    private var subtitleState: SubtitleState {
        if let notice = controller.notice {
            return .notice(notice)
        }
        if controller.isPaused {
            return .paused(shortcut: controller.shortcuts.shortcut(for: .startAnnotation) ?? controller.shortcuts.shortcut(for: .togglePause))
        }
        if controller.isHoldPaused, let key = controller.shortcuts.holdKey {
            return .holding(key.symbol)
        }
        if controller.isAutoPaused {
            return .waitingForWindow
        }
        return controller.isPickingWindow ? .choosingWindow : .annotating
    }

    enum SubtitleState: Equatable {
        case annotating
        case choosingWindow
        case paused(shortcut: Shortcut?)
        /// Another app is in front of the window being annotated.
        case waitingForWindow
        /// The hold key is down; its symbol.
        case holding(String)
        case notice(String)
    }

    /// One piece of the subtitle: an optional word, an optional app icon, and a name or text.
    struct SubtitlePart: Equatable {
        var prefix: String?
        var icon: NSImage?
        var text: String?
    }

    /// The width the title column has in the fixed pill, for the narrowest layout (the paused
    /// state with its badge). Every subtitle's shortest candidate fits it.
    static let subtitleWidth: CGFloat = 120
    static let clipboardIcon = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard")
    static let subtitleFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)

    /// Subtitles from fullest to shortest, such as "for Codex · in Chrome · 2 notes", then
    /// without the words, then without the names, keeping the icons.
    static func subtitleCandidates(
        client: String?, clientIcon: NSImage?, scopeName: String?, scopeIcon: NSImage?, notes: Int, state: SubtitleState
    ) -> [[SubtitlePart]] {
        switch state {
        case .notice(let text):
            return [[SubtitlePart(text: text)]]
        case .holding(let key):
            return [[SubtitlePart(text: "Release \(key) to annotate")], [SubtitlePart(text: "Release \(key)")]]
        case .waitingForWindow:
            return [[SubtitlePart(text: "Click the window to continue")], [SubtitlePart(text: "Click the window")]]
        case .choosingWindow:
            return [[SubtitlePart(text: "Esc cancels")]]
        // Paused, it still says where the report goes; the button's tooltip has the shortcut.
        case .annotating, .paused:
            break
        }

        let detail = notes == 0 ? nil : "\(notes) \(notes == 1 ? "note" : "notes")"
        let full = [
            client.map { SubtitlePart(prefix: "for", icon: clientIcon, text: $0) },
            scopeName.map { SubtitlePart(prefix: "in", icon: scopeIcon, text: $0) },
            detail.map { SubtitlePart(text: $0) },
        ].compactMap { $0 }

        // Each step drops more: the words, then the names behind icons.
        let steps: [(SubtitlePart) -> SubtitlePart?] = [
            { $0.icon == nil ? $0 : SubtitlePart(icon: $0.icon) },
        ]
        var candidates = [full]
        for step in steps {
            let next = candidates[candidates.count - 1].compactMap(step)
            if next != candidates.last, !next.isEmpty {
                candidates.append(next)
            }
        }
        return candidates
    }

    /// The width of a subtitle candidate in the HUD's subtitle font.
    static func width(of parts: [SubtitlePart]) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: subtitleFont]
        let separator = (" · " as NSString).size(withAttributes: attributes).width
        let widths = parts.map { part in
            let words = [part.prefix, part.text].compactMap { $0 }
            let text = words.map { ($0 as NSString).size(withAttributes: attributes).width }.reduce(0, +)
            let gaps = CGFloat(max(words.count + (part.icon == nil ? 0 : 1) - 1, 0)) * 3
            return text + (part.icon == nil ? 0 : 14) + gaps
        }
        return widths.reduce(0, +) + CGFloat(max(parts.count - 1, 0)) * separator
    }
}

/// A subtitle candidate on one line, laid out at its ideal width so ViewThatFits can measure it.
private struct SubtitleLine: View {
    let parts: [HUDView.SubtitlePart]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text("·")
                }
                if let prefix = part.prefix {
                    Text(prefix)
                }
                if let icon = part.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                if let text = part.text {
                    Text(text)
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

private struct HUDButton: View {
    /// An SF Symbol, or a template image such as `TildeMark.annotateIcon`.
    let image: Image
    var badge: Int = 0
    /// The smallest width and the height.
    var size: CGFloat = 30
    var isOn = false
    var isDestructive = false
    /// The icon's colour, such as Tilde blue for the main action.
    var tint: Color?
    let help: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isHUDEmbedded) private var isHUDEmbedded
    @State private var isHovered = false

    private var foreground: Color {
        if isDestructive {
            return Color.red.opacity(isEnabled ? 1 : 0.4)
        }
        if let tint {
            return tint.opacity(isEnabled ? 1 : 0.4)
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
                image
                    .font(.system(size: 12, weight: .semibold))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, badge > 0 ? 9 : 0)
            .frame(minWidth: size, minHeight: size)
            .background(RoundedRectangle(cornerRadius: isHUDEmbedded ? 8 : 9).fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .tildeTooltip(help)
        .accessibilityLabel(help)
    }
}

/// A text button for the pill's confirm state; destructive ones are red like Delete.
struct PillTextButton: View {
    @Environment(\.isHUDEmbedded) private var isHUDEmbedded
    let title: String
    /// A small key cap after the title, such as "esc", for the key that does the same.
    var key: String?
    let isDestructive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                if let key {
                    KeyHint(key: key)
                }
            }
                .foregroundStyle(isDestructive ? Color.red : .white.opacity(0.9))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(HUDShape(height: 28, isHUDEmbedded: isHUDEmbedded).fill(background))
                .contentShape(Rectangle())
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

/// A short note below the HUD after it paused: how to go on. It goes after 10 seconds, or at
/// once on resume, discard or send; the pointer on it keeps it.
struct PauseToast: View {
    let notice: AnnotationController.PauseNotice
    @ObservedObject var controller: AnnotationController

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.tildeBlue)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: HUDView.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.tildeInk))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
        .fixedSize()
        .onHover { controller.holdPauseNotice($0) }
    }

    private var text: String {
        switch notice {
        case .escape:
            return "Paused"
        case .otherApp:
            return "Paused while another app is in front"
        }
    }
}

/// The key that does the same as a button, after its label: borderless on a faint fill, in
/// the label's colour, centred on it. ↩ is the SF Symbol, which sits centred where the
/// character sits high.
struct KeyHint: View {
    let key: String

    var body: some View {
        Group {
            if key == "↩" {
                Image(systemName: "return")
                    .font(.system(size: 9.5, weight: .semibold))
            } else {
                Text(key)
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .opacity(0.75)
        .padding(.horizontal, 4)
        .frame(minWidth: 18, minHeight: 16, maxHeight: 16)
        .background(RoundedRectangle(cornerRadius: 4).fill(.foreground.opacity(0.15)))
    }
}

private struct HUDEmbeddedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The HUD is on the browser's toolbar, so its controls use the toolbar's corners.
    var isHUDEmbedded: Bool {
        get { self[HUDEmbeddedKey.self] }
        set { self[HUDEmbeddedKey.self] = newValue }
    }
}

/// A pill control's shape: round ends in the floating HUD, the toolbar's corners on it.
private struct HUDShape: Shape {
    let height: CGFloat
    let isHUDEmbedded: Bool

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: isHUDEmbedded ? 8 : height / 2).path(in: rect)
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

private extension Color {
    /// From "#RRGGBB".
    init(hex: String) {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255)
    }
}
