import TildeCore
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Centred card that shows one annotation's close-up large and its context screenshot as a
/// tile, with its comment editable in place. A click on either image enlarges it to fill the
/// image area, with a Back button. ← and → cycle through the annotations; Esc goes back from
/// an enlarged image, then closes.
/// While the comment is being edited, those keys edit the text; ↩ or Esc ends editing.
/// The panel keeps one size so nothing moves while cycling. Its edges and its corner grip
/// resize it, and Tilde remembers the size for the next preview; the pictures take the extra
/// space. Its header moves it like the HUD's pill: it snaps back to the centre within 40 pt,
/// and a place elsewhere is remembered for that screen.
@MainActor
final class PreviewPanel {
    let window: NSPanel
    private static let defaultSize = NSSize(width: 1000, height: 640)
    /// Room for the header, a picture, the comment box and the buttons.
    static let minSize = NSSize(width: 560, height: 420)
    private static let sizeKey = "PreviewSize"
    private let defaults: UserDefaults
    /// The screen to open on.
    private let screen: () -> NSScreen?
    private var resizeObservers: [Any] = []
    private lazy var snapDrag = SnapDrag(window: window, outlineCornerRadius: 18, positionsKey: "PreviewPositions")
    /// The frame when a drag of the corner grip began.
    private var resizeStart: NSRect?

    init(controller: AnnotationController, defaults: UserDefaults) {
        self.defaults = defaults
        screen = { [unowned controller] in controller.hud.screen }
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: true)
        panel.onKey = { [unowned panel] event in
            let isEditing = panel.firstResponder is NSTextView
            if controller.handleKey(event, in: .preview(isTyping: isEditing)) {
                return true
            }
            // ↩ ends the editing of the comment; ⇧↩ adds a line.
            if Int(event.keyCode) == kVK_Return, isEditing, !event.modifierFlags.contains(.shift) {
                panel.makeFirstResponder(nil)
                return true
            }
            return false
        }

        let hosting = FirstMouseHostingView(rootView: PreviewView(controller: controller))
        hosting.sizingOptions = []

        window = panel
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        // The window's own shadow, from the card's shape, so the card reaches its edges and
        // they resize it.
        window.hasShadow = true
        window.minSize = Self.minSize
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.rootView = PreviewView(controller: controller) { [weak self] in
            self?.drag()
        } onResize: { [weak self] distance in
            self?.resize(by: distance)
        } onResizeEnded: { [weak self] in
            self?.endResize()
        }
        // The size is the user's only once a resize by an edge or the grip ends, never from
        // fitting the card onto a smaller screen.
        let center = NotificationCenter.default
        resizeObservers = [
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.window.invalidateShadow()
                }
            },
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.endResize()
                }
            },
        ]
    }

    /// The card's size on a screen: the remembered size, or the default, kept inside the
    /// screen and above the minimum.
    static func size(on visible: NSRect, defaults: UserDefaults) -> NSSize {
        let saved = defaults.string(forKey: sizeKey).map(NSSizeFromString)
        return fitted(saved ?? defaultSize, min: minSize, max: visible.size)
    }

    /// The top centre of a card of this size centred in the screen's visible area.
    static func homeTop(of size: NSSize, on visible: NSRect) -> NSPoint {
        NSPoint(x: visible.midX, y: visible.midY + size.height / 2)
    }

    /// Keeps the card's top centre where the whole card is inside the visible area.
    static func clamped(_ top: NSPoint, size: NSSize, in visible: NSRect) -> NSPoint {
        let x = min(max(top.x, visible.minX + size.width / 2), visible.maxX - size.width / 2)
        let y = min(max(top.y, visible.minY + size.height), visible.maxY)
        return NSPoint(x: x, y: y)
    }

    static func save(_ size: NSSize, to defaults: UserDefaults) {
        defaults.set(NSStringFromSize(size), forKey: sizeKey)
    }

    /// Shows the card on the screen with the HUD, centred or where it was dropped there, with no
    /// text field focused so the arrow keys navigate.
    func show() {
        guard let screen = screen() ?? NSScreen.screens.first else {
            return
        }

        let visible = screen.visibleFrame
        let size = Self.size(on: visible, defaults: defaults)
        window.maxSize = visible.size
        let top = Self.clamped(snapDrag.savedTop(on: screen) ?? Self.homeTop(of: size, on: visible), size: size, in: visible)
        window.setFrame(NSRect(x: top.x - size.width / 2, y: top.y - size.height, width: size.width, height: size.height), display: true)
        window.makeKeyAndOrderFront(nil)
        // Without this, Esc and the arrows would go to the app in front.
        if !window.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
        }
        window.makeFirstResponder(nil)
    }

    func close() {
        window.orderOut(nil)
    }

    /// Moves the card with the pointer while its header is dragged. Home is the card centred
    /// at its size now; a snap never resizes it.
    private func drag() {
        let size = window.frame.size
        snapDrag.begin { screen in
            let top = Self.homeTop(of: size, on: screen.visibleFrame)
            return NSRect(x: top.x - size.width / 2, y: top.y - size.height, width: size.width, height: size.height)
        } outlineFrame: { home in
            home
        } clamped: { top, visible in
            Self.clamped(top, size: size, in: visible)
        }
    }

    /// Resizes the card from its corner grip; the top left corner stays, and the card stays
    /// on its screen.
    private func resize(by distance: CGSize) {
        let start = resizeStart ?? window.frame
        resizeStart = start
        let visible = window.screen?.visibleFrame ?? start
        let room = CGSize(width: visible.maxX - start.minX, height: start.maxY - visible.minY)
        let size = fitted(CGSize(width: start.width + distance.width, height: start.height + distance.height), min: Self.minSize, max: room)
        window.setFrame(NSRect(x: start.minX, y: start.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    private func endResize() {
        resizeStart = nil
        Self.save(window.frame.size, to: defaults)
    }
}

/// Panel that handles navigation keys before its views, so a focused control cannot take them.
private final class KeyPanel: FloatingPanel {
    var onKey: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true {
            return
        }
        super.sendEvent(event)
    }
}

struct PreviewView: View {
    /// The notes, and the flow for whether they can change.
    @ObservedObject var controller: AnnotationController
    @ObservedObject private var previewCard: PreviewCard
    @ObservedObject private var wireframes: WireframeSwitch
    @ObservedObject private var savedVideos: SavedVideos
    /// Called when a drag of the header moves.
    let onDrag: () -> Void
    /// The corner grip's drag, by its distance since it began, and its end.
    let onResize: (CGSize) -> Void
    let onResizeEnded: () -> Void

    init(
        controller: AnnotationController, onDrag: @escaping () -> Void = {}, onResize: @escaping (CGSize) -> Void = { _ in },
        onResizeEnded: @escaping () -> Void = {}
    ) {
        self.controller = controller
        previewCard = controller.previewCard
        wireframes = controller.wireframes
        savedVideos = controller.savedVideos
        self.onDrag = onDrag
        self.onResize = onResize
        self.onResizeEnded = onResizeEnded
    }

    var body: some View {
        Group {
            if let id = previewCard.id, let index = controller.drafts.firstIndex(where: { $0.id == id }) {
                card(index: index, draft: controller.drafts[index])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tildeTooltipHost()
        .environment(\.colorScheme, .dark)
    }

    private func card(index: Int, draft: Draft) -> some View {
        let annotation = draft.annotation

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.tildeBlue))
                Text(summary(of: annotation))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Text("\(index + 1) of \(controller.drafts.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                CardButton(symbol: "xmark", keys: ["Esc"], help: "Close") {
                    controller.dispatch(.closePreview)
                }
            }
            // The whole strip above the pictures moves the card, margins included, like the
            // HUD's pill; a drag that starts on Close moves it and does not press it.
            .padding([.horizontal, .top], 18)
            .padding(.bottom, 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { _ in onDrag() }
            )

            VStack(alignment: .leading, spacing: 14) {
                images(of: annotation)

                // An enlarged screenshot gets the whole card below the header.
                if previewCard.expandedImage == nil {
                    CommentEditor(controller: controller, id: draft.id, initial: annotation.comment)
                        .id(draft.id)
                    footer(id: draft.id)
                }
            }
            .padding([.horizontal, .bottom], 18)
        }
        // Opaque, unlike the HUD: a large see-through card would mix with the page behind it.
        // It fills the window, which draws the shadow.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.1)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.1)).allowsHitTesting(false))
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip(onChanged: onResize, onEnded: onResizeEnded)
        }
    }

    private func footer(id: Draft.ID) -> some View {
        HStack(spacing: 6) {
            CardButton(symbol: "chevron.left", keys: ["←"], help: "Previous") {
                previewCard.step(-1, in: controller.drafts)
            }
            CardButton(symbol: "chevron.right", keys: ["→"], help: "Next") {
                previewCard.step(1, in: controller.drafts)
            }
            Spacer()
            if wireframes.isOn, controller.drafts.first(where: { $0.id == id })?.isWireframe == true {
                CardButton(symbol: "pencil", title: "Edit Wireframe", help: "Edit the wireframe on the screen") {
                    controller.editWireframe(id)
                }
                .disabled(!controller.canEditNotes)
            }
            if case .recording(let video, _, _) = controller.drafts.first(where: { $0.id == id })?.annotation.target {
                CardButton(
                    symbol: "square.and.arrow.down", title: "Save video", isLoading: savedVideos.saving == video,
                    help: "Save the video with its background to Downloads"
                ) {
                    savedVideos.save(video, camera: controller.cameraTrack(of: video), layout: controller.layout(of: video))
                }
            }
            CardButton(symbol: "trash", title: "Delete", isDestructive: true, help: "Delete this note") {
                controller.askToDelete(id)
            }
            .disabled(!controller.canEditNotes)
        }
    }

    /// The close-up fills the image area, or a recording's clip in the native player, and the
    /// context, when there is one, sits beside it as a tile; a recording has none. An enlarged
    /// screenshot replaces both, under a Back button.
    @ViewBuilder
    private func images(of annotation: Annotation) -> some View {
        switch previewCard.expandedImage {
        case .closeUp:
            enlarged(title: "Close-up", data: annotation.image)
        case .context:
            enlarged(title: "Context", data: annotation.contextImage)
        case nil:
            HStack(alignment: .top, spacing: 12) {
                if case .recording(let video, _, _) = annotation.target {
                    VStack(alignment: .leading, spacing: 6) {
                        SlotTitle(text: "Recording")
                        // A new player for each clip, so the last one stops.
                        ClipComposer(controller: controller, video: video)
                            .id(video)
                    }
                } else {
                    Screenshot(title: "Close-up", data: annotation.image) {
                        previewCard.expandedImage = .closeUp
                    }
                }
                if annotation.contextImage != nil {
                    Screenshot(title: "Context", data: annotation.contextImage) {
                        previewCard.expandedImage = .context
                    }
                    .frame(width: 240, height: 180)
                }
            }
        }
    }

    private func enlarged(title: String, data: Data?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                CardButton(symbol: "chevron.left", title: "Back", keys: ["Esc"], help: "Back") {
                    previewCard.expandedImage = nil
                }
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            ImageSlot(data: data)
        }
    }

    private func summary(of annotation: Annotation) -> String {
        switch annotation.target {
        case .drawing:
            return "Drawing"
        case .recording(_, let seconds, let source):
            return "Recording of \(source), \(clipLength(seconds))"
        case .region:
            return "Region \(Int(annotation.frame.width))×\(Int(annotation.frame.height))"
        case .element(.web(let element)):
            return "<\(element.tag)> on \(element.url)"
        case .element(.native(let element)):
            return "\(friendlyRoleName(element.role)) in \(element.app)"
        }
    }
}

/// A labelled screenshot that enlarges on click.
private struct Screenshot: View {
    let title: String
    let data: Data?
    let enlarge: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SlotTitle(text: title)
            ImageSlot(data: data)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(isHovered ? 0.95 : 0.6))
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.55)))
                        .padding(8)
                }
                .onHover { isHovered = $0 }
                .onTapGesture(perform: enlarge)
                .tildeTooltip("Enlarge")
        }
    }
}

/// The small grey title above a screenshot or a clip.
private struct SlotTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
    }
}

/// A slot that letterboxes one screenshot. Small screenshots grow to at most their pixel size
/// in points, which is twice their size on a Retina screen.
private struct ImageSlot: View {
    let data: Data?
    @StateObject private var decoded = DecodedImage()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05))
            if let image = decoded.image(of: data) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                    .padding(8)
            } else {
                Text("No screenshot")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.1)))
        .contentShape(Rectangle())
    }
}

/// The annotation's comment, saved on every change.
private struct CommentEditor: View {
    @ObservedObject var controller: AnnotationController
    let id: Draft.ID
    @State private var text: String

    init(controller: AnnotationController, id: Draft.ID, initial: String) {
        self.controller = controller
        self.id = id
        _text = State(initialValue: initial)
    }

    var body: some View {
        TextField("Add a comment", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(.white)
            // Grows with the text up to about 400 pt, then scrolls.
            .lineLimit(3...23)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.1)))
            .disabled(!controller.canEditNotes)
            .onChange(of: text) {
                controller.updateCommentSoon(id, text)
            }
    }
}
