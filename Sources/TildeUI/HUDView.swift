import AppKit
import SwiftUI
import TildeCore

struct HUDView: View {
    /// The width of the pill in every mode. The widest title and a two-digit note count fit in
    /// it (the HUD reserves their space with hidden labels), so changing the mode or adding
    /// notes never moves a button; `everyModeFitsThePillWidth` checks it.
    static let width: CGFloat = 537

    /// The flow, the session and the notes.
    @ObservedObject var controller: AnnotationController
    // The parts of the session whose state the HUD shows.
    @ObservedObject private var hud: HUDPlacement
    @ObservedObject private var notices: Notices
    @ObservedObject private var drawing: DrawingNotes
    @ObservedObject private var wireframe: WireframeMode
    @ObservedObject private var wireframes: WireframeSwitch
    @ObservedObject private var browserOffer: BrowserOffer
    /// What Record records, which the controller reads for the source's name.
    @ObservedObject private var scope: SessionScope
    /// In the toolbar of Tilde's browser instead of the floating panel: the pill alone, which
    /// does not move, and tooltips drawn by the browser.
    let isEmbedded: Bool
    /// Called when a drag of the pill moves.
    let onDrag: () -> Void
    /// Reports the frame of the visible content in the window, top-left origin.
    let onContentFrame: (CGRect) -> Void
    @State private var isPillHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        controller: AnnotationController, isEmbedded: Bool = false, onDrag: @escaping () -> Void = {},
        onContentFrame: @escaping (CGRect) -> Void = { _ in }
    ) {
        self.controller = controller
        hud = controller.hud
        notices = controller.notices
        drawing = controller.drawing
        wireframe = controller.wireframe
        wireframes = controller.wireframes
        browserOffer = controller.browserOffer
        scope = controller.scope
        self.isEmbedded = isEmbedded
        self.onDrag = onDrag
        self.onContentFrame = onContentFrame
    }

    var body: some View {
        if isEmbedded {
            pill
        } else {
            floating
        }
    }

    private var floating: some View {
        VStack(spacing: HUDAccessory.gap) {
            // In Tilde's browser the main bar is on the toolbar, below the canvas.
            if !hud.isInBrowser {
                // Its own width, also above a wider accessory picker.
                pill
                    .fixedSize()
            }
            if hud.isShown, let video = controller.savedVideo {
                SavedVideoToast(video: video)
                    .transition(Self.zoom)
            }
            if controller.isDrawing {
                // Its own width: the HUD's, scaled, or wider for its content.
                drawingAccessoryBar
                    .fixedSize()
                    .transition(.opacity)
            }
            if controller.isRecordMode {
                // The dropdown hangs from the source button, at the bar's leading end.
                VStack(alignment: .leading, spacing: HUDAccessory.gap) {
                    recordingAccessoryBar
                        .fixedSize()
                    if hud.isShown, controller.isPickingWindow, !controller.isSourcePickerOpen {
                        HUDSourceDropdown { controller.dispatch(.openPicker) }
                            .padding(.leading, HUDSourceDropdown.leadingInset)
                            .transition(.scale(scale: 0.5, anchor: .topLeading).combined(with: .opacity))
                    }
                }
                .transition(.opacity)
            }
            if hud.isShown, controller.showsBrowserAccessory {
                HUDAccessoryBrowserBar(onOpen: controller.openBrowserFromAccessory, onDismiss: browserOffer.dismiss)
                    .transition(Self.zoom)
            }
            if hud.isShown, browserOffer.showsToast, !hud.isInBrowser {
                HUDBrowserOfferToast(onNever: browserOffer.neverOffer)
                    .onHover { browserOffer.holdToast($0) }
                    .transition(Self.zoom)
            }
            if hud.isShown, let notice = notices.pause {
                PauseCard(notice: notice, notices: notices)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if hud.isShown, controller.isOpen, hud.showsList, !controller.drafts.isEmpty {
                AnnotationList(controller: controller)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { hud.listFrame = $0 }
                    .onDisappear { hud.listFrame = .zero }
                    .transition(Self.zoom)
            }
            if hud.isShown, controller.isSourcePickerOpen {
                HUDAccessoryPicker(
                    model: controller.sourcePicker, selectedID: controller.clipSource.id, onBack: controller.escapePressed, onChoose: controller.choose
                )
                    .transition(Self.zoom)
            }
        }
        .padding(16)
        .fixedSize()
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: onContentFrame)
        .tildeTooltipHost()
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .animation(.spring(duration: 0.28), value: hud.showsList)
        .animation(.spring(duration: 0.28), value: controller.isPickingWindow)
        .animation(.spring(duration: 0.3, bounce: 0), value: controller.isSourcePickerOpen)
        .animation(.easeOut(duration: 0.15), value: controller.isDrawing)
        .animation(.easeOut(duration: 0.15), value: controller.isRecordMode)
        .animation(.spring(duration: 0.28), value: controller.drafts.count)
        .animation(HUDPanel.motion, value: controller.sentConfirmation)
        .animation(.easeInOut(duration: 0.18), value: controller.confirmation)
        .animation(.easeOut(duration: 0.15), value: notices.pause)
        .animation(.spring(duration: 0.28), value: browserOffer.url)
        .animation(.spring(duration: 0.28), value: browserOffer.showsToast)
        .animation(HUDPanel.motion, value: controller.savedVideo)
    }

    /// How the list appears and goes with the HUD: the same zoom as the pill.
    private static let zoom = AnyTransition.scale(scale: 0.5, anchor: .top).combined(with: .opacity)

    private var pillScale: CGFloat {
        if !hud.isShown {
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
    static let embeddedWidth = width - 2 * PillMetrics.endInset

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
                HStack(spacing: PillMetrics.iconGap) {
                    switch notices.sentStatus {
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

    /// Draw's bar under the pill: its tools, Undo and Redo, then Done. While paused the tools
    /// wait; Done still finishes.
    @ViewBuilder
    private func canvasBarContent(@ViewBuilder tools: () -> some View) -> some View {
        Group {
            tools()
            HUDBarDivider()
            undoRedo
        }
        .disabled(controller.isDrawingPaused)
        Spacer(minLength: 0)
        doneButton
    }

    /// Wireframe's bar under the pill: the tools, Undo and Redo, or in their place the
    /// controls of the look; then the palette button, which switches the two, and Done. The
    /// tools give the place its width and the controls of the look take the same place, so the
    /// bar, the palette button and Done never move; the two groups crossfade.
    @ViewBuilder
    private var wireframeBarContent: some View {
        let isStyling = wireframe.bar.isStyling
        Group {
            HStack(spacing: HUDAccessory.size.scaled(4)) {
                wireframeTools
                HUDBarDivider()
                undoRedo
            }
            .opacity(isStyling ? 0 : 1)
            .allowsHitTesting(!isStyling)
            .accessibilityHidden(isStyling)
            .overlay(alignment: .leading) {
                WireframeStyleControls(wireframe: wireframe)
                    .opacity(isStyling ? 1 : 0)
                    .allowsHitTesting(isStyling)
                    .accessibilityHidden(!isStyling)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? .linear(duration: 0.1) : .easeInOut(duration: 0.2), value: isStyling)
            HUDBarDivider()
            HUDButton(image: Image(systemName: "paintpalette"), isOn: isStyling, help: "Style") {
                _ = wireframe.bar.handle(.palette)
            }
        }
        .disabled(controller.isDrawingPaused)
        .onChange(of: wireframe.bar.isAdjusting) { _, isAdjusting in
            // The popover can take the keyboard; the canvas gets it back after.
            if !isAdjusting, controller.isWireframe {
                controller.takeKeyboard()
            }
        }
        doneButton
    }

    @ViewBuilder
    private var undoRedo: some View {
        HUDButton(image: Image(systemName: "arrow.uturn.backward"), keys: ["⌘Z"], help: "Undo") {
            controller.dispatch(.undoDrawing)
        }
        HUDButton(image: Image(systemName: "arrow.uturn.forward"), keys: ["⇧⌘Z"], help: "Redo") {
            controller.dispatch(.redoDrawing)
        }
    }

    private var doneButton: some View {
        PillTextButton(title: "Done", key: "⌘↩", isDestructive: false) {
            controller.dispatch(.finishDrawing)
        }
        .fixedSize()
    }

    /// Draw's tools and colours. No tool is on after Esc put the tool down.
    @ViewBuilder
    private var drawingTools: some View {
        let size = HUDAccessory.size
        ForEach(Self.drawingTools, id: \.tool) { entry in
            let isOn = drawing.tool == entry.tool && !drawing.isToolDown
            HUDButton(image: Image(systemName: entry.symbol), isOn: isOn, keys: keys(ShortcutStore.Action.allCases.first { $0.drawingTool == entry.tool }), help: entry.help) {
                controller.setDrawingTool(entry.tool)
            }
        }
        HUDBarDivider()
        ForEach(Self.drawingColors, id: \.hex) { entry in
            Button {
                controller.setDrawingColor(entry.hex)
            } label: {
                Circle()
                    .fill(Color(hex: entry.hex))
                    .frame(width: size.swatchSize, height: size.swatchSize)
                    .overlay(Circle().strokeBorder(Color.white.opacity(drawing.color == entry.hex ? 1 : 0.25), lineWidth: drawing.color == entry.hex ? 2 : 1))
                    .padding(1)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .tildeTooltip(entry.name, keys: keys(ShortcutStore.Action.allCases.first { $0.drawingColor?.hex == entry.hex }))
            .accessibilityLabel(entry.name)
        }
    }

    /// Wireframe's tools, each with its own letter.
    private var wireframeTools: some View {
        ForEach(WireframeMode.tools, id: \.tool) { entry in
            let otherKeys = WireframeMode.otherKeys.filter { $0.value == entry.tool }.keys.sorted()
            HUDButton(image: Image(systemName: entry.symbol), isOn: wireframe.tool == entry.tool, keys: ([entry.key] + otherKeys).map { $0.uppercased() }, help: entry.help) {
                controller.setWireframeTool(entry.tool)
            }
        }
    }

    /// The key of an in-app shortcut, for its button's tooltip; none when it has none, and
    /// none for a mode's key while drawing, where it does nothing.
    private func keys(_ action: ShortcutStore.Action?) -> [String] {
        guard let action, !(controller.isDrawing && action.group == .modes), let shortcut = controller.shortcuts.shortcut(for: action) else {
            return []
        }
        return [shortcut.chip]
    }

    nonisolated static let drawingTools = [
        (tool: "arrow", symbol: "arrow.up.right", help: "Arrow"),
        (tool: "rectangle", symbol: "rectangle", help: "Rectangle"),
        (tool: "ellipse", symbol: "circle", help: "Circle"),
        (tool: "freedraw", symbol: "scribble", help: "Freehand"),
        (tool: "text", symbol: "textformat", help: "Text"),
    ]

    nonisolated static let drawingColors = [
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
        .opacity(hud.isShown ? 1 : 0)
        .animation(.spring(duration: 0.25), value: isPillHovered)
        .onHover { isPillHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in onDrag() }
        )
    }

    private var drawingAccessoryBar: some View {
        let size = HUDAccessory.size
        return capsule(HStack(spacing: size.scaled(4)) {
            if controller.isWireframe {
                wireframeBarContent
            } else {
                canvasBarContent { drawingTools }
            }
        }, width: size.scaled(HUDView.width), size: size)
            .opacity(hud.isShown ? 1 : 0)
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { _ in onDrag() }
            )
    }

    /// Record's bar under the pill: the source, then Play or Pause and Stop. It keeps its
    /// width in every state of the clip; only the icon of Play or Pause changes.
    private var recordingAccessoryBar: some View {
        HUDRecordingBar(
            controller: controller, sourceName: controller.clipSourceName, source: controller.clipSource, appIcon: controller.clipSourceAppIcon,
            recordKeys: keys(.pauseOrResume)
        )
            .pillInsets(HUDAccessory.size)
            .pill()
            .opacity(hud.isShown ? 1 : 0)
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { _ in onDrag() }
            )
    }

    /// The button of a canvas's mode: it starts the mode, resumes it when it is paused, and is
    /// Done while it is on.
    private func canvasButton(_ canvas: SessionFlow.Canvas, symbol: String, keys: [String], help: String) -> some View {
        let isOn = controller.flow.session?.canvas == canvas
        let event: SessionFlow.Event
        if isOn {
            event = controller.isDrawingPaused ? .resume : .finishDrawing
        } else {
            event = canvas == .draw ? .startDrawing : .startWireframe
        }
        return HUDButton(image: Image(systemName: symbol), isOn: isOn, keys: keys, help: help) {
            controller.dispatch(event)
        }
        .disabled(!controller.accepts(event))
    }

    /// `width`: the pill's smallest width, which wider content grows, or nil to fit the content.
    private func capsule(_ content: some View, width: CGFloat?, size: PillSize = .regular) -> some View {
        content
            .pillInsets(size)
            .frame(minWidth: width)
            .pill()
    }

    @ViewBuilder
    private var annotatingContent: some View {
        let count = controller.drafts.count
        let status = Self.status(of: controller)

        // The four modes keep their places in every state and work in every state but a busy
        // one; while a source is being chosen, the buttons after them wait. While the report
        // is made, nothing works.
        Group {
            HStack(spacing: PillMetrics.iconGap) {
                // What the session does now, as a dot: no control.
                Circle()
                    .fill(status.dot)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
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
            .padding(.trailing, PillMetrics.iconGap)
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 20)

            // In recording mode another mode's button stops the clip, keeps it, then switches.
            HUDButton(image: Image(systemName: "hand.point.up.left"), isOn: controller.isAnnotating, keys: keys(.annotationMode), help: "Annotate") {
                controller.dispatch(.toggleAnnotating)
            }
            .disabled(!controller.accepts(.toggleAnnotating))

            // Recording mode starts by choosing what to record.
            HUDButton(image: Image(systemName: "rectangle.dashed.badge.record"), isOn: controller.isRecordMode, keys: recordToggleKeys, help: "Record screen") {
                controller.dispatch(.toggleRecordingMode)
            }
            .disabled(status.isBusy)

            canvasButton(.draw, symbol: "pencil.tip", keys: keys(.drawingMode), help: "Draw")
            // While the beta is off it shows only in a wireframe that was open when it went
            // off, for its Done.
            if wireframes.isOn || controller.isWireframe {
                canvasButton(.wireframe, symbol: "squareshape.split.2x2.dotted", keys: controller.isWireframe ? ["⌘↩"] : ["W"], help: "Wireframe")
            }
        }


        Group {
            HUDButton(image: Image(systemName: "list.bullet"), badge: count, isOn: hud.showsList, help: hud.showsList ? "Hide notes" : "Show notes") {
                controller.dispatch(.toggleList)
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { hud.listButtonFrame = $0 }
            .disabled(count == 0)

            HUDButton(image: Image(systemName: "trash"), isDestructive: true, help: "Clear all notes") {
                controller.dispatch(.requestClearAll)
            }
            .disabled(count == 0)

            // A session without an agent copies the report.
            SendButton(copies: controller.session?.isLocal == true, action: { controller.dispatch(.send) })
                .disabled(!controller.canSend)
                .tildeTooltip(sendHelp, keys: ["⌘↩"])
                .accessibilityHint(sendHelp)
            .padding(.leading, 4)

            // Esc closes the session only while paused; elsewhere it pauses or steps back.
            HUDButton(image: Image(systemName: "xmark"), keys: controller.pauses.contains(.user) ? ["Esc"] : [], help: "Close") {
                controller.dispatch(.requestCancel)
            }
        }
        .disabled(controller.isPickingWindow)
    }

    /// Esc leaves recording mode only outside choosing, where it steps back instead.
    private var recordToggleKeys: [String] {
        guard controller.isRecordMode, !controller.isPickingWindow else {
            return keys(.recordingMode)
        }
        return ["Esc"] + keys(.recordingMode)
    }

    private var isSending: Bool {
        if case .sending = controller.mode {
            return true
        }
        return false
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

        HStack(spacing: PillMetrics.iconGap) {
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
            case .deleteNote:
                Text(isAskedNoteAClip ? "Delete the clip?" : "Delete the note?")
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)

        PillTextButton(title: "Cancel", key: "esc", isDestructive: false) {
            controller.dispatch(.dismissConfirmation)
        }
        .tildeTooltip(cancelHelp(confirmation))

        switch confirmation {
        case .clearAll:
            PillTextButton(title: "Clear", key: "↩", isDestructive: true) {
                controller.dispatch(.confirm)
            }
            .tildeTooltip("Delete all notes")
        case .cancelSession:
            PillTextButton(title: "Discard", key: "↩", isDestructive: true) {
                controller.dispatch(.confirm)
            }
            .tildeTooltip("Discard and close")
        case .discardComment:
            EmptyView()
        case .discardRecording:
            PillTextButton(title: "Discard", key: "↩", isDestructive: true) {
                controller.dispatch(.confirm)
            }
            .tildeTooltip("Discard the recording")
        case .restore:
            PillTextButton(title: "Replace", key: "↩", isDestructive: true) {
                controller.dispatch(.confirm)
            }
            .tildeTooltip("Replace the notes")
        case .deleteNote:
            PillTextButton(title: "Delete", key: "↩", isDestructive: true) {
                controller.dispatch(.confirm)
            }
            .tildeTooltip(isAskedNoteAClip ? "Delete the clip" : "Delete the note")
        }
    }

    private func cancelHelp(_ confirmation: SessionFlow.Question) -> String {
        switch confirmation {
        case .discardRecording: "Keep recording"
        case .deleteNote: isAskedNoteAClip ? "Keep the clip" : "Keep the note"
        default: "Keep everything"
        }
    }

    /// The delete question asks about a recording.
    private var isAskedNoteAClip: Bool {
        guard case .recording = controller.drafts.first(where: { $0.id == controller.deleteAsked })?.annotation.target else {
            return false
        }
        return true
    }

    private var sendHelp: String {
        guard let session = controller.session else {
            return "Send"
        }
        if session.isLocal {
            return "Copy"
        }
        let agent = session.node.map { "\(session.client) on \($0)" } ?? session.client
        return "Send to \(agent)"
    }

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

    /// The subtitle on one line: where the report goes, in full, or what to do now. It never
    /// widens the pill: every agent's name fits, and a longer one is cut.
    private var subtitle: some View {
        let part = Self.subtitlePart(
            // A local session's report goes to the clipboard, like an agent's goes to the agent.
            client: controller.session.map { $0.isLocal ? "Clipboard" : $0.client },
            clientIcon: controller.session.flatMap { $0.isLocal ? Self.clipboardIcon : controller.clientIcon($0.client) },
            machine: controller.session?.node.map { Machine(host: $0, dot: controller.machineDot($0)) },
            state: subtitleState
        )
        return SubtitleLine(part: part)
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var subtitleState: SubtitleState {
        if let notice = notices.notice {
            return .notice(notice.rawValue)
        }
        if controller.isPickingWindow {
            return controller.isSourcePickerOpen ? .inPicker : .choosingWindow
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
}

/// After Save video: where the file went, with Show in Finder and Copy.
private struct SavedVideoToast: View {
    let video: URL

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: PillMetrics.iconGap) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Video saved")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Downloads")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            HStack(spacing: 4) {
                PillTextButton(title: "Show in Finder", isDestructive: false) {
                    NSWorkspace.shared.activateFileViewerSelecting([video])
                }
                PillTextButton(title: "Copy", isDestructive: false) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([video as NSURL])
                }
            }
        }
        .pillInsets(.regular, leading: .text)
        .pill()
        .environment(\.colorScheme, .dark)
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

/// The browser accessory bar: under the HUD after the first click in another browser in a
/// session, it opens its page in Tilde's browser. The pill's buttons in an accessory bar, that
/// stays until it is used or dismissed.
struct HUDAccessoryBrowserBar: View {
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            HUDButton(image: Image(systemName: "globe"), title: "Open in Tilde's browser", help: "Pick exact page elements", action: onOpen)
            HUDButton(image: Image(systemName: "xmark"), help: "Dismiss", action: onDismiss)
        }
        .pillInsets(HUDAccessory.size)
        .pill()
        .environment(\.colorScheme, .dark)
    }
}

/// The toast after the browser offer's ×: it only offers to turn the offer off.
struct HUDBrowserOfferToast: View {
    let onNever: () -> Void

    var body: some View {
        HUDButton(image: nil, title: "Don't show again", help: "Never offer Tilde's browser; Settings turns it back on", action: onNever)
            .pillInsets(HUDAccessory.size)
            .pill()
            .environment(\.colorScheme, .dark)
    }
}

/// A card below the HUD after it paused: how to go on. It goes after 10 seconds, or at
/// once on resume, discard or send; the pointer on it keeps it.
struct PauseCard: View {
    let notice: PauseNotice
    let notices: Notices

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
        .onHover { notices.holdPause($0) }
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

private extension Color {
    /// From "#RRGGBB".
    init(hex: String) {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255)
    }
}
