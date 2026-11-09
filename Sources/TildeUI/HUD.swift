import AppKit
import TildeCore
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
    /// Where the HUD was before choosing moved it home for the picker's room.
    private var placeBeforePicking: NSPoint?
    private var screenObserver: Any?
    private lazy var zoom = ZoomPresenter(panel: window) { [controller] isShown in
        controller.isHUDShown = isShown
    }
    /// Drags the pill, snapping it home, and remembers where it was dropped on each screen.
    private lazy var snapDrag = SnapDrag(window: window, outlineCornerRadius: HUDMetrics.height / 2, positionsKey: "HUDPositions")
    /// The visible content (pill, message, list) in the panel's SwiftUI coordinates, which
    /// have a top-left origin. The hosting view has no sizing options, so its fitting size
    /// is zero and cannot give this.
    private var contentFrame: CGRect = .zero
    private var clickMonitor: Any?

    /// Room for the widest content (the source picker) and its shadow.
    private static let width: CGFloat = SourcePickerView.sizes.max.width + 2 * 16

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
        hosting.rootView = HUDView(controller: controller) { [weak self] in
            self?.dragPill()
        } onContentFrame: { [weak self] frame in
            self?.contentFrame = frame
        }
        // A drag can take the HUD to another screen; Record and the picker follow it there.
        screenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanged() }
        }
        snapDrag.moved = { [weak self] ended in
            self?.pillMoved(ended: ended)
        }
    }

    /// Shows the HUD on the screen that has the pointer, or with its top centre at `top`.
    func show(top: NSPoint? = nil) {
        place(top: top)
        // Lays the collapsed pill out at its place now. The first time, the hosting view has
        // never been laid out, and its first layout inside the zoom would animate the pill in
        // from the window's left edge.
        hosting.layoutSubtreeIfNeeded()
        zoom.show()
    }

    /// Collapses the pill into its centre, then hides the panel.
    func hide() {
        zoom.hide()
    }

    /// Tells the source picker how much room it has under the pill (or, in Tilde's browser,
    /// under the panel's top) on the panel's screen, so it never leaves the screen. A HUD
    /// too low for the picker goes up to its home while choosing, and back after.
    func fitPicker() {
        guard let screen = screen ?? NSScreen.main else {
            return
        }
        if pickerRoom(on: screen).height < SourcePickerView.sizes.min.height, !controller.isHUDInBrowser, placeBeforePicking == nil {
            placeBeforePicking = window.frame.origin
            let home = Self.homeTop(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
            window.setFrameOrigin(NSPoint(x: home.x - window.frame.width / 2, y: home.y - window.frame.height))
        }
        controller.sourcePicker.space = pickerRoom(on: screen)
    }

    /// Back where the HUD was before choosing moved it home.
    func endPicking() {
        if let place = placeBeforePicking {
            window.setFrameOrigin(place)
            placeBeforePicking = nil
        }
    }

    /// The picker's room under the pill where the panel is now.
    private func pickerRoom(on screen: NSScreen) -> CGSize {
        let pill = controller.isHUDInBrowser ? 0 : HUDMetrics.height + 8
        return room(under: window.frame, pill: pill, in: screen.visibleFrame)
    }

    /// While choosing, the picker's room follows a drag of the pill; a drop too low for it
    /// moves the HUD home until choosing ends, then back to the drop.
    private func pillMoved(ended: Bool) {
        screenChanged()
        guard controller.isPickingWindow, let screen else {
            return
        }
        if ended {
            fitPicker()
        } else {
            controller.sourcePicker.space = pickerRoom(on: screen)
        }
    }

    private func screenChanged() {
        if let display = AnnotationController.displayID(of: screen), display != controller.hudDisplay {
            controller.hudDisplay = display
        }
    }

    /// The screen with the pill. The clear panel is about a screen tall, so most of it can be
    /// on another screen, which `window.screen` would give.
    private var screen: NSScreen? {
        let screens = NSScreen.screens
        return Self.pillScreen(of: window.frame, among: screens.map(\.frame)).map { screens[$0] }
    }

    /// The index of the screen frame with the pill of a panel at `frame`.
    static func pillScreen(of frame: NSRect, among screens: [NSRect]) -> Int? {
        let pill = NSPoint(x: frame.midX, y: frame.maxY - 16 - HUDMetrics.height / 2)
        return screens.firstIndex { $0.contains(pill) }
    }

    private func room(under frame: NSRect, pill: CGFloat, in visible: NSRect) -> CGSize {
        let top = frame.maxY - 16 - pill
        let halfWidth = min(frame.midX - visible.minX, visible.maxX - frame.midX) - 16
        return CGSize(width: 2 * halfWidth, height: top - visible.minY - 16)
    }

    /// Forgets the dragged positions and moves the HUD back to the top centre.
    func resetPosition() {
        snapDrag.forgetAll()
        if window.isVisible {
            place()
        }
    }

    /// Puts the panel on the screen with the pointer, at the saved position for that screen,
    /// or at `top`.
    private func place(top given: NSPoint? = nil) {
        placeBeforePicking = nil
        let point = given ?? NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.screens.first else {
            return
        }

        let home = Self.homeTop(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        let top = given ?? Self.clamped(snapDrag.savedTop(on: screen) ?? home, in: screen.visibleFrame)
        let height = screen.visibleFrame.height + 4
        window.setFrame(NSRect(x: top.x - Self.width / 2, y: top.y - height, width: Self.width, height: height), display: true)
        screenChanged()
    }

    /// Moves the panel with the pointer while the pill is dragged; it snaps to home within
    /// 40 pt, where the outline of the pill shows (below the 16 pt content padding).
    private func dragPill() {
        // The user puts it somewhere else: choosing no longer moves it back.
        placeBeforePicking = nil
        let height = window.frame.height
        snapDrag.begin { screen in
            let top = Self.homeTop(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
            return NSRect(x: top.x - Self.width / 2, y: top.y - height, width: Self.width, height: height)
        } outlineFrame: { home in
            NSRect(x: home.midX - HUDView.width / 2, y: home.maxY - 16 - HUDMetrics.height, width: HUDView.width, height: HUDMetrics.height)
        } clamped: { top, visible in
            Self.clamped(top, in: visible)
        }
    }

    /// Top centre of the panel at home: the top centre of the screen's visible area.
    static func homeTop(screenFrame: NSRect, visibleFrame: NSRect) -> NSPoint {
        NSPoint(x: screenFrame.midX, y: visibleFrame.maxY + 4)
    }

    /// Keeps the pill's top centre where the whole pill is inside the screen's visible area.
    static func clamped(_ top: NSPoint, in visible: NSRect) -> NSPoint {
        let halfWidth = HUDView.width / 2 + 16
        let x = min(max(top.x, visible.minX + halfWidth), visible.maxX - halfWidth)
        let y = min(max(top.y, visible.minY + HUDMetrics.height + 32), visible.maxY + 4)
        return NSPoint(x: x, y: y)
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
    /// The width of the pill in every mode. The widest title and a two-digit note count fit in
    /// it (the HUD reserves their space with hidden labels), so changing the mode or adding
    /// notes never moves a button; `everyModeFitsThePillWidth` checks it.
    static let width: CGFloat = 479

    @ObservedObject var controller: AnnotationController
    /// In the toolbar of Tilde's browser instead of the floating panel: the pill alone, which
    /// does not move, and tooltips drawn by the browser.
    var isEmbedded = false
    /// Called when a drag of the pill moves.
    var onDrag: () -> Void = {}
    /// Reports the frame of the visible content in the window, top-left origin.
    var onContentFrame: (CGRect) -> Void = { _ in }
    @State private var isPillHovered = false
    /// How often recording mode began, which bounces the record button.
    @State private var recordModeEntries = 0

    var body: some View {
        if isEmbedded {
            pill
        } else {
            floating
        }
    }

    private var floating: some View {
        VStack(spacing: 8) {
            // In Tilde's browser the main bar is on the toolbar, below the canvas.
            if !controller.isHUDInBrowser {
                // Its own width, also above the wider source picker.
                pill
                    .fixedSize()
            }
            if controller.isDrawing {
                drawingBar
                    .transition(.opacity)
            }
            if controller.isHUDShown, controller.showsBrowserHint {
                BrowserHint(onOpen: controller.openBrowserHint, onDismiss: controller.dismissBrowserHint)
                    .transition(Self.zoom)
            }
            if controller.isHUDShown, let notice = controller.pauseNotice {
                PauseToast(notice: notice, controller: controller)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if controller.isHUDShown, controller.isOpen, controller.showsList, !controller.drafts.isEmpty {
                AnnotationList(controller: controller)
                    .transition(Self.zoom)
            }
            if controller.isHUDShown, controller.isPickingWindow {
                SourcePickerView(
                    model: controller.sourcePicker, isOpen: controller.isSourcePickerOpen,
                    selectedID: controller.isRecordMode ? controller.clipSource.id : controller.source?.id,
                    onOpen: controller.openSourcePicker, onBack: controller.stepBackInSourcePicker, onChoose: controller.choose
                )
                    .transition(Self.zoom)
            }
        }
        .padding(16)
        .fixedSize()
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: onContentFrame)
        .tildeTooltipHost()
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .animation(.spring(duration: 0.28), value: controller.showsList)
        .animation(.spring(duration: 0.28), value: controller.isPickingWindow)
        .animation(.spring(duration: 0.3, bounce: 0), value: controller.isSourcePickerOpen)
        .animation(.easeOut(duration: 0.15), value: controller.isDrawing)
        .animation(.spring(duration: 0.28), value: controller.drafts.count)
        .animation(HUDPanel.motion, value: controller.sentConfirmation)
        .animation(.easeInOut(duration: 0.18), value: controller.confirmation)
        .animation(.easeOut(duration: 0.15), value: controller.pauseNotice)
        .animation(.spring(duration: 0.28), value: controller.browserHint)
    }

    /// How the list appears and goes with the HUD: the same zoom as the pill.
    private static let zoom = AnyTransition.scale(scale: 0.5, anchor: .top).combined(with: .opacity)

    private var pillScale: CGFloat {
        if !controller.isHUDShown {
            return 0.5
        }
        return isPillHovered ? 1.015 : 1
    }

    /// The pill is `width` wide in every mode; after Send it shrinks to fit the confirmation.
    private var isConfirmingSend: Bool {
        controller.sentConfirmation != nil
    }

    /// The pill's content width, the same in every state; embedded, the same without the
    /// pill's insets.
    static let embeddedWidth = width - HUDMetrics.leadingInset - HUDMetrics.trailingInset

    @ViewBuilder
    private var pill: some View {
        if isEmbedded {
            pillContent
                .frame(minWidth: isConfirmingSend ? nil : Self.embeddedWidth, minHeight: 30, maxHeight: 30)
                .environment(\.isHUDEmbedded, true)
        } else {
            floatingPill
        }
    }

    /// The pill's content on the browser's toolbar: no capsule, and controls with the
    /// toolbar's corners.
    private var pillContent: some View {
        HStack(spacing: 4) {
            if let confirmation = controller.sentConfirmation {
                HStack(spacing: HUDMetrics.iconGap) {
                    switch controller.sentStatus {
                    case .done:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.green)
                    case .failed:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.yellow)
                    }
                    Text(confirmation)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
            } else {
                // Stacked, so the crossfade between the two never lays them out side by side.
                ZStack {
                    if let confirmation = controller.confirmation, confirmation != .discardComment {
                        HStack(spacing: 4) {
                            confirmContent(confirmation)
                        }
                        .transition(.opacity)
                    } else {
                        HStack(spacing: 4) {
                            annotatingContent
                        }
                        .disabled(isSending)
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
        capsule(pillContent, width: isConfirmingSend ? nil : Self.width)
        // Opening and closing zoom the laid-out pill in and out of its centre. Under the
        // pointer it grows a little to show that it can be dragged; a drag that starts on a
        // button moves the HUD and does not press it.
        .scaleEffect(pillScale)
        .opacity(controller.isHUDShown ? 1 : 0)
        .animation(.spring(duration: 0.25), value: isPillHovered)
        .onHover { isPillHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in onDrag() }
        )
    }

    private var drawingBar: some View {
        capsule(HStack(spacing: 4) { drawingContent }, width: HUDView.width)
            .opacity(controller.isHUDShown ? 1 : 0)
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { _ in onDrag() }
            )
    }

    /// `width`: the pill's whole width, or nil to fit the content.
    private func capsule(_ content: some View, width: CGFloat?) -> some View {
        content
            .padding(.leading, HUDMetrics.leadingInset)
            .padding(.trailing, HUDMetrics.trailingInset)
            .frame(width: width)
            .frame(height: HUDMetrics.height)
            .hudPill()
    }

    @ViewBuilder
    private var annotatingContent: some View {
        let count = controller.drafts.count
        let flow = controller.flow
        let status = Self.status(of: controller)

        // While a source is being chosen, only the record toggle works; the others keep their
        // places with the disabled look. While the report is made, nothing works.
        Group {
            HStack(spacing: HUDMetrics.iconGap) {
                // Where the status dot was: in recording mode the record button, else pause and play.
                HUDButton(image: Image(systemName: status.symbol), size: 26, tint: status.tint, bounce: recordModeEntries, help: status.help) {
                    if controller.isRecordMode {
                        controller.toggleRecord()
                    } else if !controller.pauses.isEmpty {
                        controller.resume()
                    } else {
                        controller.togglePause()
                    }
                }
                .disabled(status.isBusy || controller.isPickingWindow)
                // The red record button bounces once on the way into recording mode.
                .onChange(of: controller.isRecordMode) { _, isRecordMode in
                    if isRecordMode {
                        recordModeEntries += 1
                    }
                }
                .padding(.leading, -4)
                VStack(alignment: .leading, spacing: 1) {
                    titleText(status)
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

            // Recording mode starts by choosing what to record.
            HUDButton(image: Image(systemName: "rectangle.dashed.badge.record"), isOn: controller.isRecordMode, help: recordToggleHelp) {
                controller.toggleRecordingMode()
            }
            .disabled(status.isBusy)

            // Recording mode puts Stop where Draw is; the other buttons stay.
            if controller.isRecordMode {
                HUDButton(image: Image(systemName: "stop.fill"), help: "Stop and add the recording to the list") {
                    controller.stopRecording()
                }
                .disabled(controller.recording != .recording && controller.recording != .paused)
            } else {
                HUDButton(image: Image(systemName: "pencil.tip"), isOn: controller.isDrawing, help: "Draw on the screen") {
                    if controller.isDrawing {
                        controller.finishDrawing()
                    } else {
                        controller.startDrawing()
                    }
                }
            }
        }


        Group {
            HUDButton(image: Image(systemName: "list.bullet"), badge: count, isOn: controller.showsList, help: controller.showsList ? "Hide notes" : "Show notes") {
                controller.showNotes()
            }
            .disabled(count == 0)

            HUDButton(image: Image(systemName: "trash"), isDestructive: true, help: "Clear all notes and keep annotating") {
                controller.requestClearAll()
            }
            .disabled(count == 0)

            // A session without an agent copies the report.
            SendButton(copies: controller.session?.isLocal == true, action: controller.send)
                .disabled(!flow.canSend)
                .tildeTooltip(sendHelp)
                .accessibilityHint(sendHelp)
            .padding(.leading, 4)

            // Esc closes the session only while paused; elsewhere it pauses or steps back.
            HUDButton(image: Image(systemName: "xmark"), help: controller.pauses.contains(.user) ? "Cancel and close (Esc)" : "Cancel and close") {
                controller.requestCancel()
            }
        }
        .disabled(controller.isPickingWindow)
    }

    /// Esc leaves recording mode only outside choosing, where it steps back instead.
    private var recordToggleHelp: String {
        guard controller.isRecordMode else {
            return "Record a screen, window or phone"
        }
        return controller.isPickingWindow ? "Back to annotating" : "Back to annotating (Esc)"
    }

    private var isSending: Bool {
        if case .sending = controller.mode {
            return true
        }
        return false
    }

    /// What a cancel would throw away, such as "2 notes and the recording".
    private var lost: String {
        let count = controller.drafts.count
        let notes = count == 1 ? "the note" : "\(count) notes"
        guard controller.flow.holdsClip else {
            return notes
        }
        return count == 0 ? "the recording" : "\(notes) and the recording"
    }

    /// The cancel question names the session's end, unlike leaving recording mode's.
    private var cancelQuestion: String {
        let count = controller.drafts.count
        switch (count, controller.flow.holdsClip) {
        case (0, _): return "Close and discard the recording?"
        case (_, true): return "Close and discard everything?"
        case (1, false): return "Discard the note and close?"
        default: return "Discard \(count) notes and close?"
        }
    }

    /// Replaces the pill's content, at the same size, with a question and two buttons.
    @ViewBuilder
    private func confirmContent(_ confirmation: SessionFlow.Question) -> some View {
        let count = controller.drafts.count
        let all = count == 1 ? "the note" : "all \(count) notes"

        HStack(spacing: HUDMetrics.iconGap) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.red)
            switch confirmation {
            case .clearAll:
                Text("Clear \(all)?")
            case .cancelSession:
                Text(cancelQuestion)
            case .discardComment:
                // Asked on the comment box itself.
                EmptyView()
            case .discardRecording:
                Text("Discard the recording?")
            case .restore:
                Text("Replace \(count == 1 ? "the note" : "\(count) notes") with \(controller.restoreRecord?.notes.count ?? 0) saved?")
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)

        PillTextButton(title: "Cancel", key: "esc", isDestructive: false) {
            controller.dismissConfirmation()
        }
        .tildeTooltip(confirmation == .discardRecording ? "Keep recording" : "Keep everything")

        switch confirmation {
        case .clearAll:
            PillTextButton(title: "Clear", key: "↩", isDestructive: true) {
                controller.confirm()
            }
            .tildeTooltip("Delete all notes")
        case .cancelSession:
            PillTextButton(title: "Discard", key: "↩", isDestructive: true) {
                controller.confirm()
            }
            .tildeTooltip("Discard \(lost) and close")
        case .discardComment:
            EmptyView()
        case .discardRecording:
            PillTextButton(title: "Discard", key: "↩", isDestructive: true) {
                controller.confirm()
            }
            .tildeTooltip("Throw the recording away and go back to annotating")
        case .restore:
            PillTextButton(title: "Replace", key: "↩", isDestructive: true) {
                controller.confirm()
            }
            .tildeTooltip("Replace the notes with the saved session's")
        }
    }

    private var sendHelp: String {
        guard let session = controller.session else {
            return "Send  ⌘↩"
        }
        if session.isLocal {
            return "Copy to clipboard  ⌘↩"
        }
        let agent = session.node.map { "\(session.client) on \($0)" } ?? session.client
        return "Send to \(agent)  ⌘↩"
    }

    /// The title and the leading button of one mode.
    struct Status: Equatable {
        var title: String
        /// The clip's length after the title: running since a date, or stopped.
        var clock: Clock?
        var symbol: String
        var tint: Color?
        var help: String
        /// Starting, saving or sending: the leading button and the record toggle wait.
        var isBusy = false

        enum Clock: Equatable {
            case running(since: Date, before: TimeInterval)
            case stopped(TimeInterval)
        }
    }

    static func status(of controller: AnnotationController) -> Status {
        let shortcut = controller.shortcuts.shortcut(for: .startAnnotation) ?? controller.shortcuts.shortcut(for: .togglePause)
        let clock = controller.clips.clock
        switch controller.mode {
        case .sending(_, let returnTo):
            var status = status(of: returnTo, scopeName: controller.scopeName, shortcut: shortcut, clock: clock)
            status.title = "Sending"
            status.clock = nil
            status.isBusy = true
            return status
        case .open(let open):
            return status(of: open, scopeName: controller.scopeName, shortcut: shortcut, clock: clock)
        case .idle, .sent:
            return status(of: SessionFlow.Open(), scopeName: nil, shortcut: nil, clock: clock)
        }
    }

    /// "Pause (Esc)", and when paused "Annotate (Double-tap ⌃)"; in recording mode the record
    /// button, red to start or resume a clip and pause while it records.
    static func status(of open: SessionFlow.Open, scopeName: String?, shortcut: Shortcut?, clock: (since: Date, before: TimeInterval)) -> Status {
        switch open.activity {
        case .picking(let isRecordMode, _):
            var back = open
            back.activity = isRecordMode ? .recording(.ready) : .annotating
            var status = status(of: back, scopeName: scopeName, shortcut: shortcut, clock: clock)
            status.title = "Choose a window"
            return status
        case .annotating:
            if open.pauses.isEmpty {
                return Status(title: "Annotating", symbol: "pause.fill", help: "Pause (Esc)")
            }
            return Status(title: "Paused", symbol: "play.fill", help: shortcut.map { "Annotate (\($0.title))" } ?? "Annotate")
        case .recording(let clip):
            let start = scopeName.map { "Start recording \($0)" } ?? "Start recording the screen"
            switch clip {
            case .ready:
                return Status(title: "Ready to record", symbol: "circle.fill", tint: .red, help: start)
            case .starting:
                return Status(title: "Starting", symbol: "circle.fill", tint: .red, help: start, isBusy: true)
            case .recording:
                return Status(title: "Recording", clock: .running(since: clock.since, before: clock.before), symbol: "pause.fill", help: "Pause the recording")
            case .paused:
                return Status(title: "Paused", clock: .stopped(clock.before), symbol: "circle.fill", tint: .red, help: "Resume the recording")
            case .finishing:
                return Status(title: "Saving", symbol: "circle.fill", tint: .red, help: start, isBusy: true)
            }
        }
    }

    /// Every title the HUD shows, with the widest clock, for the width of the title column.
    static let titles: [String] = {
        let modes: [SessionFlow.Open] = [
            SessionFlow.Open(), SessionFlow.Open(pauses: [.user]), SessionFlow.Open(activity: .picking(isRecordMode: true, isPickerOpen: false)),
        ] + [SessionFlow.Clip.ready, .starting(operation: 0), .recording, .paused, .finishing(operation: 0, thenSend: false)].map {
            SessionFlow.Open(activity: .recording($0))
        }
        let statuses = modes.map { status(of: $0, scopeName: nil, shortcut: nil, clock: (Date(), 0)) }
        return statuses.map { $0.clock == nil ? $0.title : "\($0.title) 00:00" } + ["Sending"]
    }()

    /// The title. It takes the space of the widest title in every mode, so the pill keeps its
    /// width and the buttons stay put when the mode changes; the time counts up while recording.
    private func titleText(_ status: Status) -> some View {
        ZStack(alignment: .leading) {
            ForEach(Self.titles, id: \.self) { title in
                Text(title).hidden()
            }
            switch status.clock {
            case .running(let since, let before):
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text("\(status.title) \(clipLength(before + context.date.timeIntervalSince(since)))")
                }
            case .stopped(let elapsed):
                Text("\(status.title) \(clipLength(elapsed))")
            case nil:
                Text(status.title)
            }
        }
        .monospacedDigit()
    }

    /// The subtitle on one line: where the report goes, in full, what to do now, or in
    /// recording mode what Record records, which a click chooses again before Record. It never
    /// widens the pill: every agent's name fits, and a longer one is cut.
    private var subtitle: some View {
        let part = Self.subtitlePart(
            // A local session's report goes to the clipboard, like an agent's goes to the agent.
            client: controller.session.map { $0.isLocal ? "Clipboard" : $0.client },
            clientIcon: controller.session.flatMap { $0.isLocal ? Self.clipboardIcon : controller.clientIcon($0.client) },
            machine: controller.session?.node.map { Machine(host: $0, dot: controller.machineDot($0)) },
            state: subtitleState
        )
        return Group {
            if case .source = subtitleState {
                Button(action: controller.toggleWindowPick) {
                    SubtitleLine(part: part).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!controller.flow.accepts(.windowButton))
                .tildeTooltip("Choose what to record")
            } else {
                SubtitleLine(part: part)
            }
        }
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var subtitleState: SubtitleState {
        if let notice = controller.notice {
            return .notice(notice.rawValue)
        }
        if controller.isPickingWindow {
            return controller.isSourcePickerOpen ? .inPicker : .choosingWindow
        }
        if controller.isRecordMode {
            return .source(controller.clipSourceName)
        }
        let pauses = controller.pauses
        if pauses.contains(.user) {
            return .paused(shortcut: controller.shortcuts.shortcut(for: .startAnnotation) ?? controller.shortcuts.shortcut(for: .togglePause))
        }
        if pauses.contains(.hold), let key = controller.shortcuts.holdKey {
            return .holding(key.symbol)
        }
        if pauses.contains(.otherApp) {
            return .waitingForWindow
        }
        return .annotating
    }

    enum SubtitleState: Equatable {
        case annotating
        case choosingWindow
        /// The picker is open, where Esc goes back one level.
        case inPicker
        case paused(shortcut: Shortcut?)
        /// Another app is in front of the window being annotated.
        case waitingForWindow
        /// The hold key is down; its symbol.
        case holding(String)
        case notice(String)
        /// Recording mode: the name of what Record records.
        case source(String)
    }

    /// The subtitle: an optional word, an optional app icon, a name or text, and a remote
    /// agent's machine.
    struct SubtitlePart: Equatable {
        var prefix: String?
        var icon: NSImage?
        var text: String?
        /// A remote agent's machine, as its icon after the name; its host is in the tooltip.
        var machine: Machine?
    }

    /// A remote machine and its status, drawn as on the Agents page.
    struct Machine: Equatable {
        let host: String
        let dot: NodeSetup.Dot
    }

    /// The width the title column has in the fixed pill. Every agent's name fits it in full.
    static let subtitleWidth: CGFloat = 140
    static let clipboardIcon = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard")
    static let subtitleFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)

    /// What the subtitle says: a notice or what to do now, else where the report goes, such as
    /// "for Codex" and the remote machine's icon.
    static func subtitlePart(client: String?, clientIcon: NSImage?, machine: Machine?, state: SubtitleState) -> SubtitlePart {
        switch state {
        case .notice(let text):
            return SubtitlePart(text: text)
        case .holding(let key):
            return SubtitlePart(text: "Release \(key) to annotate")
        case .waitingForWindow:
            return SubtitlePart(text: "Click the window")
        case .choosingWindow:
            return SubtitlePart(text: "Esc cancels")
        case .inPicker:
            return SubtitlePart(text: "Esc goes back")
        case .source(let name):
            return SubtitlePart(text: name)
        // Paused, it still says where the report goes; the button's tooltip has the shortcut.
        case .annotating, .paused:
            break
        }

        guard let client else {
            return SubtitlePart()
        }
        return SubtitlePart(prefix: "for", icon: clientIcon, text: client, machine: machine)
    }

    /// The width of a subtitle in the HUD's subtitle font.
    static func width(of part: SubtitlePart) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: subtitleFont]
        func width(_ words: [String]) -> CGFloat {
            words.map { ($0 as NSString).size(withAttributes: attributes).width }.reduce(0, +)
        }

        let words = [part.prefix, part.text].compactMap { $0 }
        let icon: CGFloat = part.icon == nil ? 0 : 14
        let gaps = CGFloat(max(words.count + (part.icon == nil ? 0 : 1) - 1, 0)) * 3
        // The machine's icon, after a 3 pt gap.
        let machine: CGFloat = part.machine == nil ? 0 : 3 + 14
        return width(words) + icon + gaps + machine
    }
}

/// The subtitle on one line, cut to the space there is.
private struct SubtitleLine: View {
    let part: HUDView.SubtitlePart

    var body: some View {
        HStack(spacing: 3) {
            if let prefix = part.prefix {
                Text(prefix)
            }
            if let icon = part.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
            }
            if let text = part.text {
                Text(text)
            }
            // A remote machine as its icon with the status dot; there is no room for its name.
            if let machine = part.machine {
                MachineIcon(dot: machine.dot, size: 14)
                    .tildeTooltip("On \(machine.host)")
                    .accessibilityLabel("on \(machine.host)")
            }
        }
        .lineLimit(1)
    }
}

struct HUDButton: View {
    /// An SF Symbol, or an image such as an app icon.
    let image: Image
    /// A label after the icon, such as "Use window picker", which is its accessible name.
    var title: String?
    /// In a round card under the HUD: a capsule (a circle for an icon alone), so its fill is
    /// concentric with the card's ends.
    var isRound = false
    /// A count after the icon, such as the number of notes; nil for no count. A button with a
    /// count keeps the width of two digits, so the buttons stay put as the count changes.
    var badge: Int?
    /// The smallest width and the height.
    var size: CGFloat = 30
    /// Selected, such as the window the session is limited to: a grey fill.
    var isOn = false
    /// Doing what it started, such as choosing a window: a Tilde-blue fill.
    var isActive = false
    var isDestructive = false
    /// The icon's colour, such as Tilde blue for the main action.
    var tint: Color?
    /// Bounces the symbol once each time it changes, to draw the eye; the frame stays.
    var bounce = 0
    /// Off while the tooltip would cover what the button opened under it.
    var showsTooltip = true
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
        if isActive {
            return .white
        }
        return .white.opacity(isEnabled ? 0.9 : 0.3)
    }

    private var background: Color {
        if isDestructive {
            return Color.red.opacity(isHovered && isEnabled ? 0.28 : 0.16)
        }
        if isActive {
            return Color.tildeBlue.opacity(isHovered ? 0.85 : 1)
        }
        return .white.opacity(isOn ? 0.16 : (isHovered && isEnabled ? 0.09 : 0))
    }

    var body: some View {
        Button(action: action) {
            label
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(minWidth: size, minHeight: size)
            .background(shape.fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .tildeTooltip(showsTooltip ? help : nil)
        .accessibilityLabel(title ?? help)
        .accessibilityHint(title == nil ? "" : help)
    }

    private var horizontalPadding: CGFloat {
        if title != nil {
            return 14
        }
        return badge == nil ? 0 : 9
    }

    private var shape: AnyShape {
        if isRound {
            return AnyShape(Capsule())
        }
        return AnyShape(RoundedRectangle(cornerRadius: isHUDEmbedded ? 8 : 9))
    }

    /// The icon, then a slot two digits wide for the count, empty at zero, so the icon stays
    /// put as the count changes.
    private var label: some View {
        HStack(spacing: 4) {
            image
                .font(.system(size: 12, weight: .semibold))
                .symbolEffect(.bounce, value: bounce)
            if let title {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
            }
            if let badge {
                ZStack(alignment: .leading) {
                    Text("88").hidden()
                    Text(badge > 0 ? "\(badge)" : "")
                }
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
            }
        }
    }
}

/// Send, or Copy for a session without an agent, in Tilde blue; faded when disabled. Both
/// labels take the space of the wider one, so the pill never shifts.
private struct SendButton: View {
    let copies: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isHUDEmbedded) private var isHUDEmbedded

    var body: some View {
        Button(action: action) {
            ZStack {
                label("Send", symbol: "arrow.up").hidden()
                label("Copy", symbol: "doc.on.doc").hidden()
                label(copies ? "Copy" : "Send", symbol: copies ? "doc.on.doc" : "arrow.up")
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(HUDShape(height: 28, isHUDEmbedded: isHUDEmbedded).fill(Color.tildeBlue))
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }

    /// Icon first, then the label, as in macOS buttons.
    private func label(_ title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
            Text(title)
        }
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

/// Under the HUD after the first click in another browser in a session: opens its page in
/// Tilde's browser. A round card of the pill's buttons, like "Use window picker", that stays
/// until it is used or dismissed.
struct BrowserHint: View {
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            HUDButton(image: Image(systemName: "globe"), title: "Open in Tilde's browser", isRound: true, help: "Pick exact page elements and send their HTML and styles", action: onOpen)
            HUDButton(image: Image(systemName: "xmark"), isRound: true, help: "Dismiss", action: onDismiss)
        }
        .hudButtonCard()
    }
}

extension View {
    /// A round card around a row of round buttons under the HUD: their 30 pt fills sit 6 pt
    /// inside its edge all round, so its 21 pt ends are concentric with theirs.
    func hudButtonCard() -> some View {
        padding(6)
            .hudCard(cornerRadius: 21)
            .environment(\.colorScheme, .dark)
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
        .hudCard(cornerRadius: 12)
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
        .hudCard()
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
            HUDButton(image: Image(systemName: "trash"), size: 26, isDestructive: true, help: "Delete this note") {
                controller.deleteDraft(draft.id)
            }
            .disabled(!controller.canEditNotes)
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
private extension Color {
    /// From "#RRGGBB".
    init(hex: String) {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255)
    }
}
