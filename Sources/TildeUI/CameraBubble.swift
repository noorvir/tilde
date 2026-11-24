import AppKit
import AVFoundation
import SwiftUI

/// The camera bubble of recording mode: the user's camera in a round or rounded window, with
/// a bar under it for the camera, the microphone, the shape and the size. A clip records the
/// camera as its own file, which the preview places on the saved video. The camera runs only
/// while the bubble shows. The choices stay across launches.
@MainActor
final class CameraBubble: ObservableObject {
    enum Shape: String {
        case circle, rounded
    }

    enum Menu {
        case camera, microphone, size
    }

    static let sizes: [(name: String, side: CGFloat)] = [("Small", 140), ("Medium", 200), ("Large", 280)]

    /// The recording bar's camera button: the bubble shows in recording mode while on.
    @Published private(set) var isOn: Bool
    @Published private(set) var cameraID: String?
    @Published private(set) var isMicrophoneOn: Bool
    @Published private(set) var microphoneID: String?
    @Published private(set) var shape: Shape
    @Published private(set) var sizeIndex: Int
    @Published private(set) var openMenu: Menu?
    /// The camera may not be used: the bubble shows a crossed-out camera.
    @Published private(set) var isDenied = false
    /// A spinner until the first frame; a retry after a failure.
    @Published private(set) var cameraState: CameraCapture.State = .starting

    private let defaults: UserDefaults
    private let capture = CameraCapture()
    private var bubblePanel: BubblePanel?
    private var barPanel: BubblePanel?
    private var bubbleObservers: [Any] = []
    /// Recording mode, also while choosing a source; the bubble shows in it while `isOn`.
    private var isRecordMode = false
    private var showsBar = false
    /// The screen to open on: the HUD's.
    var screen: () -> NSScreen? = { NSScreen.main }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isOn = defaults.bool(forKey: "CameraOn")
        cameraID = defaults.string(forKey: "CameraID")
        isMicrophoneOn = defaults.object(forKey: "CameraMicrophoneOn") as? Bool ?? true
        microphoneID = defaults.string(forKey: "CameraMicrophoneID")
        shape = defaults.string(forKey: "CameraShape").flatMap(Shape.init(rawValue:)) ?? .circle
        sizeIndex = min(max(defaults.object(forKey: "CameraSize") as? Int ?? 1, 0), Self.sizes.count - 1)
        capture.onState = { [weak self] state in
            self?.cameraState = state
        }
    }

    var side: CGFloat {
        Self.sizes[sizeIndex].side
    }

    /// The bubble shows, so a clip that starts now records the camera.
    var isShowing: Bool {
        isRecordMode && isOn
    }

    /// The microphone a clip records, as `AVCaptureDevice.uniqueID`; nil for no sound. Only a
    /// clip with the camera records sound.
    var microphone: String? {
        guard isShowing, isMicrophoneOn else {
            return nil
        }
        return microphoneID ?? AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external], mediaType: .video, position: .unspecified).devices
    }

    var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    /// The camera in use: the chosen one while it is there, else the system's.
    var currentCameraID: String? {
        let all = cameras
        if let cameraID, all.contains(where: { $0.uniqueID == cameraID }) {
            return cameraID
        }
        return CameraCapture.defaultCamera()?.uniqueID ?? all.first?.uniqueID
    }

    var currentMicrophoneID: String? {
        microphoneID ?? AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    // MARK: - Recording

    /// Records the camera into `file` until `stopRecording`.
    func startRecording(to file: URL) {
        capture.startRecording(to: file)
    }

    func pauseRecording() {
        capture.pauseRecording()
    }

    func resumeRecording() {
        capture.resumeRecording()
    }

    /// The finished camera file and when its first frame was captured on the host clock, or
    /// nil when it recorded nothing.
    func stopRecording() async -> CameraRecording? {
        await capture.stopRecording()
    }

    // MARK: - Choices

    func toggle() {
        isOn.toggle()
        defaults.set(isOn, forKey: "CameraOn")
        openMenu = nil
        refresh()
    }

    func toggleMenu(_ menu: Menu) {
        openMenu = openMenu == menu ? nil : menu
        layoutBar()
    }

    func chooseCamera(_ id: String) {
        cameraID = id
        defaults.set(id, forKey: "CameraID")
        openMenu = nil
        capture.use(cameraID: id)
        layoutBar()
    }

    func toggleMicrophone() {
        isMicrophoneOn.toggle()
        defaults.set(isMicrophoneOn, forKey: "CameraMicrophoneOn")
    }

    func chooseMicrophone(_ id: String) {
        microphoneID = id
        isMicrophoneOn = true
        defaults.set(id, forKey: "CameraMicrophoneID")
        defaults.set(true, forKey: "CameraMicrophoneOn")
        openMenu = nil
        layoutBar()
    }

    func toggleShape() {
        shape = shape == .circle ? .rounded : .circle
        defaults.set(shape.rawValue, forKey: "CameraShape")
    }

    /// The bubble keeps the centre of its bottom edge, so its bar stays put.
    func chooseSize(_ index: Int) {
        sizeIndex = index
        defaults.set(index, forKey: "CameraSize")
        openMenu = nil
        if let bubblePanel {
            let frame = bubblePanel.frame
            bubblePanel.setFrame(NSRect(x: frame.midX - side / 2, y: frame.minY, width: side, height: side), display: true)
        }
        layoutBar()
    }

    // MARK: - On screen

    /// Shows the bubble while `isRecordMode` and the camera is on; its bar while `showsBar`,
    /// which is off while a clip records.
    func update(isRecordMode: Bool, showsBar: Bool) {
        guard isRecordMode != self.isRecordMode || showsBar != self.showsBar else {
            return
        }
        self.isRecordMode = isRecordMode
        self.showsBar = showsBar
        if !showsBar {
            openMenu = nil
        }
        refresh()
    }

    private func refresh() {
        guard isShowing else {
            capture.stop()
            barPanel?.orderOut(nil)
            bubblePanel?.orderOut(nil)
            return
        }
        let bubble = bubblePanel ?? makeBubblePanel()
        // Each time it opens, on the HUD's screen; where it was dragged when already there.
        if !bubble.isVisible, let screen = screen(), bubble.screen != screen {
            bubble.setFrameOrigin(homeOrigin(on: screen))
        }
        bubble.orderFrontRegardless()
        startCamera()
        let bar = barPanel ?? makeBarPanel()
        if showsBar {
            // Ordering out detaches a child window.
            if bar.parent == nil {
                bubble.addChildWindow(bar, ordered: .above)
            }
            layoutBar()
            bar.orderFrontRegardless()
        } else {
            bar.orderOut(nil)
        }
    }

    private func startCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isDenied = false
            capture.start(cameraID: currentCameraID)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    self.accessAnswered(granted)
                }
            }
        default:
            isDenied = true
        }
    }

    private func accessAnswered(_ granted: Bool) {
        isDenied = !granted
        if granted, isShowing {
            capture.start(cameraID: currentCameraID)
        }
    }

    /// Bottom-left, with room for its bar under it.
    private func homeOrigin(on screen: NSScreen?) -> NSPoint {
        let visible = screen?.visibleFrame ?? .zero
        return NSPoint(x: visible.minX + 40, y: visible.minY + 24 + HUDAccessory.size.height + 8)
    }

    private func makeBubblePanel() -> BubblePanel {
        let origin = homeOrigin(on: screen())
        let panel = BubblePanel(frame: NSRect(origin: origin, size: NSSize(width: side, height: side)), movesByDrag: true)
        // A drag or a screen change: the bar follows, under or above.
        let center = NotificationCenter.default
        bubbleObservers = [
            center.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.barFollows() }
            },
            center.addObserver(forName: NSWindow.didChangeScreenNotification, object: panel, queue: .main) { [weak self, weak panel] _ in
                MainActor.assumeIsolated {
                    CameraLog.debug("bubble changed screen: \(panel?.screen?.localizedName ?? "none"), frame \(panel.map { NSStringFromRect($0.frame) } ?? "")")
                    self?.barFollows()
                }
            },
        ]
        panel.onDrag = { [weak panel] ended in
            CameraLog.debug("bubble drag \(ended ? "ended" : "began") at \(panel.map { NSStringFromPoint($0.frame.origin) } ?? "")")
        }
        panel.onClick = { [weak self] in
            guard let self, cameraState == .failed else {
                return
            }
            capture.retry()
        }
        panel.contentView = NSHostingView(rootView: CameraBubbleView(bubble: self, display: capture.display))
        bubblePanel = panel
        return panel
    }

    private func makeBarPanel() -> BubblePanel {
        let panel = BubblePanel(frame: .zero, movesByDrag: false)
        panel.contentView = FirstMouseHostingView(rootView: CameraBubbleBar(bubble: self))
        barPanel = panel
        return panel
    }

    /// While a clip records the bar is hidden: a drag of the bubble does no work for it.
    private func barFollows() {
        if showsBar {
            layoutBar()
        }
    }

    /// The bar centred under the bubble, or above it when the bubble is near the screen's
    /// bottom; an open menu grows it upward.
    private func layoutBar() {
        guard let barPanel, let bubblePanel, let content = barPanel.contentView else {
            return
        }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let bubble = bubblePanel.frame
        let bottom = (bubblePanel.screen ?? screen())?.visibleFrame.minY ?? 0
        let below = bubble.minY - 8 - HUDAccessory.size.height
        let y = below >= bottom ? below : bubble.maxY + 8
        let origin = NSPoint(x: (bubble.midX - size.width / 2).rounded(), y: y.rounded())
        barPanel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// A borderless panel that floats over other apps without taking the keyboard. With
/// `movesByDrag` it follows the pointer event by event, as the HUD and the preview do: the
/// main thread stays in its normal loop, which the window server's own drag does not allow.
private final class BubblePanel: NSPanel {
    private let movesByDrag: Bool
    /// A press that did not move the panel.
    var onClick: () -> Void = {}
    /// A drag began (`false`) or ended (`true`).
    var onDrag: (_ ended: Bool) -> Void = { _ in }
    /// Where in the panel the button went down, and whether the panel has moved since.
    private var press: (inPanel: NSPoint, hasMoved: Bool)?

    init(frame: NSRect, movesByDrag: Bool) {
        self.movesByDrag = movesByDrag
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        guard movesByDrag else {
            super.sendEvent(event)
            return
        }
        switch event.type {
        case .leftMouseDown:
            press = (event.locationInWindow, false)
        case .leftMouseDragged:
            guard var press else {
                return
            }
            let pointer = convertPoint(toScreen: event.locationInWindow)
            let origin = NSPoint(x: pointer.x - press.inPanel.x, y: pointer.y - press.inPanel.y)
            if !press.hasMoved {
                guard hypot(origin.x - frame.minX, origin.y - frame.minY) >= 2 else {
                    return
                }
                press.hasMoved = true
                self.press = press
                onDrag(false)
            }
            setFrameOrigin(origin)
        case .leftMouseUp:
            guard let press else {
                return
            }
            self.press = nil
            if press.hasMoved {
                onDrag(true)
            } else {
                onClick()
            }
        default:
            super.sendEvent(event)
        }
    }
}
